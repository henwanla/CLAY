using System.Net;
using System.Runtime.InteropServices;
using System.Text;

namespace Clay.Windows;

internal static class PacChecks
{
    private sealed class Fixture(WinInetPacSettings initial) : IWindowsPacSettings
    {
        internal WinInetPacSettings Value = initial;
        public WinInetPacSettings Read() => Value;
        public void Write(WinInetPacSettings value) => Value = value;
    }

    internal static async Task RunAsync(string cli)
    {
        const string proxy = "127.0.0.1:18790";
        var script = await PortableSession.DefaultPacAsync(cli, proxy);
        var scratch = Directory.CreateTempSubdirectory("clay-pac-check-");
        try
        {
            await CheckRecoveryAsync(scratch.FullName, script);
            var wininet = new WinInetPac();
            var original = wininet.Read();
            using var lease = new WindowsPac(wininet, Path.Combine(scratch.FullName, "native"));
            try
            {
                lease.Enable(script);
                Check(lease.Confirmed(), "wininet-enabled-readback");
                var actual = wininet.Read();
                Check(IsActiveUserPac(actual.Url), "effective-windows-configuration");
                CheckNativePac(actual.Url, proxy);
                Check(lease.Release() == PacRelease.Restored && wininet.Read() == original && !lease.Pending, "wininet-restored-readback");
            }
            finally
            {
                // Only restore a configuration this fixture still owns. No
                // real PAC URL or local account data is written to the logs.
                lease.Release();
            }
            Console.WriteLine("PASS Windows: WinINet applied and restored, WinHTTP resolved the installed PAC for public and local hosts");
        }
        finally { if (!File.Exists(Path.Combine(scratch.FullName, "native", "recovery.dpapi"))) scratch.Delete(recursive: true); }
    }

    private static async Task CheckRecoveryAsync(string directory, string script)
    {
        const string marker = "synthetic-existing-secret";
        var original = new WinInetPacSettings(13, $"https://old.invalid/{marker}.pac");
        var settings = new Fixture(original);
        var path = Path.Combine(directory, "model");
        using (var lease = new WindowsPac(settings, path))
        {
            lease.Enable(script);
            Check(lease.Confirmed() && lease.Pending, "model-configured");
            var bytes = File.ReadAllBytes(Path.Combine(path, "recovery.dpapi"));
            Check(!Encoding.UTF8.GetString(bytes).Contains(marker) && !Encoding.Unicode.GetString(bytes).Contains(marker), "journal-private");
            try { using var second = new WindowsPac(settings, path); throw new BridgeException("double-owner"); }
            catch (IOException error) when (error is not BridgeException) { }
            using var http = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(5) };
            var live = settings.Value;
            Check(await http.GetStringAsync(live.Url) == script, "loopback-pac-response");
            using var missing = await http.GetAsync(new Uri(new Uri(live.Url), "/not-the-script.pac"));
            Check(missing.StatusCode == HttpStatusCode.NotFound, "loopback-pac-path");
            settings.Value = live with { Flags = 7 };
            try { lease.Release(); throw new BridgeException("edited-flags-overwritten"); }
            catch (PacRecoveryException) { }
            Check(lease.Pending && lease.Serving && settings.Value.Flags == 7, "conflicted-listener-kept");
            Check(await http.GetStringAsync(live.Url) == script, "conflicted-listener-response");
            settings.Value = live;
            // Dispose simulates the original process disappearing before it can restore.
        }
        using var reopened = new WindowsPac(settings, path);
        Check(reopened.Pending && reopened.Release() == PacRelease.Restored && settings.Value == original && !reopened.Pending, "startup-recovery");
        reopened.Enable(script);
        var external = new WinInetPacSettings(5, "https://new.invalid/local.pac");
        settings.Value = external;
        Check(reopened.Release() == PacRelease.ExternalChange && settings.Value == external && !reopened.Pending && !reopened.Serving, "external-change-preserved");
        Console.WriteLine("PASS Windows PAC journal: encrypted snapshot, competing owner refused, conflict keeps listener, restart restores, external settings preserved");
    }

    private static bool IsActiveUserPac(string url)
    {
        if (!WinHttpGetIEProxyConfigForCurrentUser(out var current)) return false;
        try { return !current.AutoDetect && Marshal.PtrToStringUni(current.AutoUrl) == url && current.Proxy == 0; }
        finally { Free(current.AutoUrl); Free(current.Proxy); Free(current.Bypass); }
    }

    private static void CheckNativePac(string url, string expectedProxy)
    {
        nint session = WinHttpOpen("CLAY PAC smoke", 1, 0, 0, 0); // WINHTTP_ACCESS_TYPE_NO_PROXY
        Check(session != 0, "winhttp-open");
        nint pac = 0;
        try
        {
            pac = Marshal.StringToHGlobalUni(url);
            var options = new AutoProxyOptions { Flags = 2, AutoConfigUrl = pac }; // WINHTTP_AUTOPROXY_CONFIG_URL
            Verify("http://public.example.invalid/", false);
            Verify("http://192.168.46.12/", true);
            Verify("http://router.local/", true);

            void Verify(string destination, bool local)
            {
                if (!WinHttpGetProxyForUrl(session, destination, ref options, out var decision))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                try
                {
                    if (local) Check(decision.AccessType == 1, "winhttp-local-direct");
                    else Check(decision.AccessType == 3 && Marshal.PtrToStringUni(decision.Proxy) == expectedProxy, "winhttp-public-proxy");
                }
                finally { Free(decision.Proxy); Free(decision.Bypass); }
            }
        }
        finally { if (pac != 0) Marshal.FreeHGlobal(pac); WinHttpCloseHandle(session); }
    }

    private static void Check(bool condition, string step) { if (!condition) throw new BridgeException(step); }
    private static void Free(nint value) { if (value != 0) GlobalFree(value); }

    [StructLayout(LayoutKind.Sequential)]
    private struct UserProxy
    {
        [MarshalAs(UnmanagedType.Bool)] internal bool AutoDetect;
        internal nint AutoUrl, Proxy, Bypass;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct AutoProxyOptions
    {
        internal uint Flags, AutoDetectFlags;
        internal nint AutoConfigUrl, Reserved;
        internal uint ReservedFlags;
        [MarshalAs(UnmanagedType.Bool)] internal bool AutoLogin;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProxyDecision { internal uint AccessType; internal nint Proxy, Bypass; }
    [DllImport("winhttp.dll", ExactSpelling = true, SetLastError = true)]
    private static extern bool WinHttpGetIEProxyConfigForCurrentUser(out UserProxy config);
    [DllImport("winhttp.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern nint WinHttpOpen(string agent, uint access, nint proxy, nint bypass, uint flags);
    [DllImport("winhttp.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern bool WinHttpGetProxyForUrl(nint session, string url, ref AutoProxyOptions options, out ProxyDecision decision);
    [DllImport("winhttp.dll", ExactSpelling = true)]
    private static extern bool WinHttpCloseHandle(nint handle);
    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern nint GlobalFree(nint pointer);
}
