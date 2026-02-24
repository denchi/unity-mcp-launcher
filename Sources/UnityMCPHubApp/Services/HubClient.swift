import Foundation

struct HubProjectRecord: Codable {
    let projectID: String
    let name: String
    let projectPath: String
    let unityPath: String
    let tags: [String]
    let status: String
    let lastSeenAt: Date?

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case name
        case projectPath = "project_path"
        case unityPath = "unity_path"
        case tags
        case status
        case lastSeenAt = "last_seen_at"
    }
}

struct HubSessionRecord: Codable {
    let sessionID: String
    let clientID: String
    let projectID: String
    let status: String
    let leaseExpiresAt: Date
    let launchToken: String
    let agentToken: String?
    let agentEndpoint: String?
    let heartbeatAt: Date?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case clientID = "client_id"
        case projectID = "project_id"
        case status
        case leaseExpiresAt = "lease_expires_at"
        case launchToken = "launch_token"
        case agentToken = "agent_token"
        case agentEndpoint = "agent_endpoint"
        case heartbeatAt = "heartbeat_at"
    }
}

struct HubSelectProjectResponse: Codable {
    let session: HubSessionRecord
    let launched: Bool
}

struct HubErrorMessage: Codable {
    let detail: String
}

struct HubProjectUpsertRequest: Codable {
    let projectID: String
    let name: String
    let projectPath: String
    let unityPath: String
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case name
        case projectPath = "project_path"
        case unityPath = "unity_path"
        case tags
    }
}

struct HubSelectProjectRequest: Codable {
    let clientID: String
    let projectID: String?
    let name: String?
    let tags: [String]
    let mostRecent: Bool
    let autoLaunch: Bool
    let launchHeadless: Bool
    let executeMethod: String?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case projectID = "project_id"
        case name
        case tags
        case mostRecent = "most_recent"
        case autoLaunch = "auto_launch"
        case launchHeadless = "launch_headless"
        case executeMethod = "execute_method"
    }
}

private struct HubForwardCallResponse: Decodable {
    let statusCode: Int
    let body: JSONValue

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case body
    }
}

enum HubForwardTarget: String {
    case agent
    case bridge
}

struct HubForwardResult {
    let statusCode: Int
    let body: JSONValue

    var summary: String {
        let previewLimit = 1200
        let rendered = body.displayText
        let preview: String
        if rendered.count > previewLimit {
            preview = String(rendered.prefix(previewLimit)) + "...(truncated)"
        } else {
            preview = rendered
        }
        return "status=\(statusCode) body=\(preview)"
    }
}

enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value"))
        }
    }

    var displayText: String {
        render(depth: 0, maxDepth: 4, maxItems: 20)
    }

    private func render(depth: Int, maxDepth: Int, maxItems: Int) -> String {
        if depth >= maxDepth {
            return "..."
        }

        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .null:
            return "null"
        case .array(let values):
            let limited = values.prefix(maxItems).map { $0.render(depth: depth + 1, maxDepth: maxDepth, maxItems: maxItems) }
            let suffix = values.count > maxItems ? ", ...(\(values.count - maxItems) more)" : ""
            return "[" + limited.joined(separator: ", ") + suffix + "]"
        case .object(let values):
            let sortedKeys = values.keys.sorted()
            let limitedKeys = sortedKeys.prefix(maxItems)
            let parts = limitedKeys.map { key in
                "\(key): \(values[key]?.render(depth: depth + 1, maxDepth: maxDepth, maxItems: maxItems) ?? "null")"
            }
            let suffix = sortedKeys.count > maxItems ? ", ...(\(sortedKeys.count - maxItems) more)" : ""
            return "{ " + parts.joined(separator: ", ") + suffix + " }"
        }
    }
}

enum HubClientError: LocalizedError {
    case invalidBaseURL
    case requestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Hub URL is invalid."
        case .requestFailed(let message):
            return message
        case .invalidResponse:
            return "Hub returned an invalid response."
        }
    }
}

@MainActor
final class HubClient {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session

        let encoder = JSONEncoder()
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func health(baseURL: String) async throws {
        _ = try await request(
            method: "GET",
            baseURL: baseURL,
            path: "/health",
            token: nil,
            body: Optional<Int>.none,
            responseType: EmptyObject.self
        )
    }

    func listProjects(baseURL: String, token: String) async throws -> [HubProjectRecord] {
        try await request(
            method: "GET",
            baseURL: baseURL,
            path: "/projects",
            token: token,
            body: Optional<Int>.none,
            responseType: [HubProjectRecord].self
        )
    }

    func upsertProject(baseURL: String, token: String, payload: HubProjectUpsertRequest) async throws {
        _ = try await request(
            method: "POST",
            baseURL: baseURL,
            path: "/projects",
            token: token,
            body: payload,
            responseType: HubProjectRecord.self
        )
    }

    func deleteProject(baseURL: String, token: String, projectID: String) async throws {
        _ = try await request(
            method: "DELETE",
            baseURL: baseURL,
            path: "/projects/\(projectID)",
            token: token,
            body: Optional<Int>.none,
            responseType: EmptyObject.self
        )
    }

    func selectProject(baseURL: String, token: String, payload: HubSelectProjectRequest) async throws -> HubSelectProjectResponse {
        try await request(
            method: "POST",
            baseURL: baseURL,
            path: "/sessions/select",
            token: token,
            body: payload,
            responseType: HubSelectProjectResponse.self
        )
    }

    func getSession(baseURL: String, token: String, sessionID: String) async throws -> HubSessionRecord {
        try await request(
            method: "GET",
            baseURL: baseURL,
            path: "/sessions/\(sessionID)",
            token: token,
            body: Optional<Int>.none,
            responseType: HubSessionRecord.self
        )
    }

    func killSession(baseURL: String, token: String, sessionID: String) async throws -> HubSessionRecord {
        try await request(
            method: "POST",
            baseURL: baseURL,
            path: "/sessions/\(sessionID)/kill",
            token: token,
            body: Optional<Int>.none,
            responseType: HubSessionRecord.self
        )
    }

    func listSessions(baseURL: String, token: String, clientID: String, includeDead: Bool = false) async throws -> [HubSessionRecord] {
        guard let encodedClientID = clientID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw HubClientError.invalidBaseURL
        }
        let path = "/sessions?client_id=\(encodedClientID)&include_dead=\(includeDead ? "true" : "false")"
        return try await request(
            method: "GET",
            baseURL: baseURL,
            path: path,
            token: token,
            body: Optional<Int>.none,
            responseType: [HubSessionRecord].self
        )
    }

    func forwardHealthCheck(baseURL: String, token: String, sessionID: String) async throws -> String {
        let response = try await forwardRequest(
            baseURL: baseURL,
            token: token,
            sessionID: sessionID,
            method: "GET",
            path: "/mcp/health",
            target: .agent,
            json: [:]
        )
        return response.summary
    }

    func forwardBridgeListTools(baseURL: String, token: String, sessionID: String) async throws -> HubForwardResult {
        try await forwardRequest(
            baseURL: baseURL,
            token: token,
            sessionID: sessionID,
            method: "GET",
            path: "/tools",
            target: .bridge,
            json: [:]
        )
    }

    func forwardBridgeCallTool(
        baseURL: String,
        token: String,
        sessionID: String,
        toolName: String,
        arguments: [String: Any]
    ) async throws -> String {
        try await forwardToolCallRequest(
            baseURL: baseURL,
            token: token,
            sessionID: sessionID,
            method: "POST",
            path: "/tools/call",
            target: .bridge,
            json: [
                "name": toolName,
                "arguments": arguments
            ]
        )
    }

    private func forwardRequest(
        baseURL: String,
        token: String,
        sessionID: String,
        method: String,
        path: String,
        target: HubForwardTarget,
        json: [String: Any]
    ) async throws -> HubForwardResult {
        guard let base = URL(string: normalizedBaseURL(baseURL)),
              let url = URL(string: "/sessions/\(sessionID)/forward", relativeTo: base)
        else {
            throw HubClientError.invalidBaseURL
        }

        let payload: [String: Any] = [
            "method": method,
            "path": path,
            "target": target.rawValue,
            "json": json
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Hub-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HubClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = decodeErrorMessage(data) ?? "Hub request failed with status \(httpResponse.statusCode)."
            throw HubClientError.requestFailed(message)
        }

        let decoded = try decoder.decode(HubForwardCallResponse.self, from: data)
        return HubForwardResult(statusCode: decoded.statusCode, body: decoded.body)
    }

    private func forwardToolCallRequest(
        baseURL: String,
        token: String,
        sessionID: String,
        method: String,
        path: String,
        target: HubForwardTarget,
        json: [String: Any]
    ) async throws -> String {
        guard let base = URL(string: normalizedBaseURL(baseURL)),
              let url = URL(string: "/sessions/\(sessionID)/forward", relativeTo: base)
        else {
            throw HubClientError.invalidBaseURL
        }

        let payload: [String: Any] = [
            "method": method,
            "path": path,
            "target": target.rawValue,
            "json": json
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Hub-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HubClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = decodeErrorMessage(data) ?? "Hub request failed with status \(httpResponse.statusCode)."
            throw HubClientError.requestFailed(message)
        }

        let maxSafeDecodeBytes = 256 * 1024
        if data.count > maxSafeDecodeBytes {
            return "status=200 body=(response too large: \(data.count) bytes, preview disabled)"
        }

        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let envelope = object as? [String: Any]
        else {
            let preview = String(data: data.prefix(1200), encoding: .utf8) ?? "<non-utf8>"
            return "status=200 body=\(preview)"
        }

        let statusCode = envelope["status_code"] as? Int ?? 200
        let bodyValue = envelope["body"]
        let bodyText = renderAnyJSON(bodyValue, depth: 0, maxDepth: 4, maxItems: 20, maxLength: 1400)
        return "status=\(statusCode) body=\(bodyText)"
    }

    private func renderAnyJSON(
        _ value: Any?,
        depth: Int,
        maxDepth: Int,
        maxItems: Int,
        maxLength: Int
    ) -> String {
        if depth >= maxDepth {
            return "..."
        }

        let rendered: String
        switch value {
        case let string as String:
            rendered = string
        case let number as NSNumber:
            rendered = number.stringValue
        case _ as NSNull:
            rendered = "null"
        case let array as [Any]:
            let limited = array.prefix(maxItems).map {
                renderAnyJSON($0, depth: depth + 1, maxDepth: maxDepth, maxItems: maxItems, maxLength: maxLength)
            }
            let suffix = array.count > maxItems ? ", ...(\(array.count - maxItems) more)" : ""
            rendered = "[" + limited.joined(separator: ", ") + suffix + "]"
        case let dict as [String: Any]:
            let keys = dict.keys.sorted()
            let limitedKeys = keys.prefix(maxItems)
            let parts = limitedKeys.map { key in
                let child = renderAnyJSON(dict[key], depth: depth + 1, maxDepth: maxDepth, maxItems: maxItems, maxLength: maxLength)
                return "\(key): \(child)"
            }
            let suffix = keys.count > maxItems ? ", ...(\(keys.count - maxItems) more)" : ""
            rendered = "{ " + parts.joined(separator: ", ") + suffix + " }"
        default:
            rendered = "<empty>"
        }

        if rendered.count > maxLength {
            return String(rendered.prefix(maxLength)) + "...(truncated)"
        }
        return rendered
    }

    private func request<RequestBody: Encodable, ResponseBody: Decodable>(
        method: String,
        baseURL: String,
        path: String,
        token: String?,
        body: RequestBody?,
        responseType: ResponseBody.Type
    ) async throws -> ResponseBody {
        guard let base = URL(string: normalizedBaseURL(baseURL)),
              let url = URL(string: path, relativeTo: base)
        else {
            throw HubClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Hub-Token")
        }
        if let body {
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HubClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = decodeErrorMessage(data) ?? "Hub request failed with status \(httpResponse.statusCode)."
            throw HubClientError.requestFailed(message)
        }

        if ResponseBody.self == EmptyObject.self, data.isEmpty {
            return EmptyObject() as! ResponseBody
        }

        do {
            return try decoder.decode(ResponseBody.self, from: data)
        } catch {
            if ResponseBody.self == EmptyObject.self {
                return EmptyObject() as! ResponseBody
            }
            throw error
        }
    }

    private func decodeErrorMessage(_ data: Data) -> String? {
        guard let message = try? decoder.decode(HubErrorMessage.self, from: data) else {
            return nil
        }
        return message.detail
    }

    private func normalizedBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }
}

private struct EmptyObject: Codable {}
