#if UNITY_EDITOR
public static class UnityMcpHubBootstrap
{
    // Optional launch target for Unity -executeMethod UnityMcpHubBootstrap.Start
    public static void Start()
    {
        UnityMcpHubAgentRuntime.StartFromExecuteMethod();
    }
}
#endif
