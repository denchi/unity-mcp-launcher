#if UNITY_EDITOR
using System;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using UnityEditor;
using UnityEngine;

[InitializeOnLoad]
public static class UnityMcpHubAgentRuntime
{
    private static readonly HttpClient Http = new HttpClient();

    private static bool _started;
    private static bool _registering;
    private static bool _registered;
    private static bool _heartbeatInFlight;

    private static string _hubUrl;
    private static string _hubToken;
    private static string _sessionId;
    private static string _launchToken;
    private static string _agentToken;
    private static string _agentEndpoint;
    private static int _heartbeatSeconds;
    private static double _nextHeartbeatAt;

    static UnityMcpHubAgentRuntime()
    {
        EditorApplication.delayCall += TryStartFromEnvironment;
    }

    public static void StartFromExecuteMethod()
    {
        TryStartFromEnvironment();
    }

    private static void TryStartFromEnvironment()
    {
        if (_started)
        {
            return;
        }

        _hubUrl = ReadEnv("UNITY_MCP_HUB_URL");
        _hubToken = ReadEnv("UNITY_MCP_HUB_TOKEN");
        _sessionId = ReadEnv("UNITY_MCP_SESSION_ID");
        _launchToken = ReadEnv("UNITY_MCP_LAUNCH_TOKEN");
        _agentEndpoint = ReadEnv("UNITY_MCP_AGENT_ENDPOINT");
        var heartbeatText = ReadEnv("UNITY_MCP_HEARTBEAT_SECONDS");

        if (string.IsNullOrEmpty(_hubUrl) || string.IsNullOrEmpty(_hubToken) ||
            string.IsNullOrEmpty(_sessionId) || string.IsNullOrEmpty(_launchToken))
        {
            return;
        }

        if (string.IsNullOrEmpty(_agentEndpoint))
        {
            _agentEndpoint = "http://127.0.0.1:7072";
        }

        if (!int.TryParse(heartbeatText, out _heartbeatSeconds) || _heartbeatSeconds < 3)
        {
            _heartbeatSeconds = 10;
        }

        _started = true;
        _nextHeartbeatAt = EditorApplication.timeSinceStartup + 2.0;
        EditorApplication.update += OnEditorUpdate;

        _ = RegisterAgentAsync();
    }

    private static void OnEditorUpdate()
    {
        if (!_registered || string.IsNullOrEmpty(_agentToken))
        {
            return;
        }

        if (EditorApplication.timeSinceStartup < _nextHeartbeatAt || _heartbeatInFlight)
        {
            return;
        }

        _heartbeatInFlight = true;
        _nextHeartbeatAt = EditorApplication.timeSinceStartup + _heartbeatSeconds;
        _ = SendHeartbeatAsync();
    }

    private static async Task RegisterAgentAsync()
    {
        if (_registering || _registered)
        {
            return;
        }

        _registering = true;
        try
        {
            var payload = new RegisterAgentRequest
            {
                session_id = _sessionId,
                launch_token = _launchToken,
                endpoint = _agentEndpoint,
                tool_manifest = new ToolManifest
                {
                    source = "unity-editor",
                    mcp_url = JoinUrl(_agentEndpoint, "mcp"),
                    health_url = JoinUrl(_agentEndpoint, "mcp/health")
                }
            };

            var response = await PostJsonAsync("/agents/register", JsonUtility.ToJson(payload));
            var body = await response.Content.ReadAsStringAsync();
            if (!response.IsSuccessStatusCode)
            {
                Debug.LogWarning("[UnityMcpHubAgentRuntime] register failed: " + (int)response.StatusCode + " " + body);
                return;
            }

            var model = JsonUtility.FromJson<RegisterAgentResponse>(body);
            if (model == null || !model.accepted || string.IsNullOrEmpty(model.agent_token))
            {
                Debug.LogWarning("[UnityMcpHubAgentRuntime] register response missing agent token.");
                return;
            }

            _agentToken = model.agent_token;
            _registered = true;
            _nextHeartbeatAt = EditorApplication.timeSinceStartup + _heartbeatSeconds;

            Debug.Log("[UnityMcpHubAgentRuntime] registered with hub for session " + _sessionId);
        }
        catch (Exception ex)
        {
            Debug.LogWarning("[UnityMcpHubAgentRuntime] register error: " + ex.Message);
        }
        finally
        {
            _registering = false;
        }
    }

    private static async Task SendHeartbeatAsync()
    {
        try
        {
            var payload = new HeartbeatRequest
            {
                session_id = _sessionId,
                agent_token = _agentToken
            };

            var response = await PostJsonAsync("/agents/heartbeat", JsonUtility.ToJson(payload));
            if (!response.IsSuccessStatusCode)
            {
                var body = await response.Content.ReadAsStringAsync();
                Debug.LogWarning("[UnityMcpHubAgentRuntime] heartbeat failed: " + (int)response.StatusCode + " " + body);
            }
        }
        catch (Exception ex)
        {
            Debug.LogWarning("[UnityMcpHubAgentRuntime] heartbeat error: " + ex.Message);
        }
        finally
        {
            _heartbeatInFlight = false;
        }
    }

    private static Task<HttpResponseMessage> PostJsonAsync(string path, string json)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, JoinUrl(_hubUrl, path));
        request.Content = new StringContent(json, Encoding.UTF8, "application/json");
        request.Headers.Add("X-Hub-Token", _hubToken);
        return Http.SendAsync(request);
    }

    private static string JoinUrl(string baseUrl, string path)
    {
        var b = (baseUrl ?? string.Empty).TrimEnd('/');
        var p = (path ?? string.Empty).TrimStart('/');
        return b + "/" + p;
    }

    private static string ReadEnv(string name)
    {
        return Environment.GetEnvironmentVariable(name) ?? string.Empty;
    }

    [Serializable]
    private class RegisterAgentRequest
    {
        public string session_id;
        public string launch_token;
        public string endpoint;
        public ToolManifest tool_manifest;
    }

    [Serializable]
    private class ToolManifest
    {
        public string source;
        public string mcp_url;
        public string health_url;
    }

    [Serializable]
    private class RegisterAgentResponse
    {
        public bool accepted;
        public string agent_token;
    }

    [Serializable]
    private class HeartbeatRequest
    {
        public string session_id;
        public string agent_token;
    }
}
#endif
