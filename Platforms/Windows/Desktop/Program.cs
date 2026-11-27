using System.Globalization;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace Clay.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args is ["--smoke-subscriptions", var subscriptionCli, var subscriptionFixture])
        {
            try { SubscriptionChecks.RunAsync(subscriptionCli, subscriptionFixture).GetAwaiter().GetResult(); return 0; }
            catch (BridgeException error) { Console.Error.WriteLine($"Windows subscription check failed at {error.Step} (exit code {error.ExitCode?.ToString() ?? "unknown"})."); return 1; }
            catch (Exception error) { Console.Error.WriteLine($"Windows subscription check failed: {error.GetType().Name}."); return 1; }
        }
        if (args is ["--smoke-pac", var portable])
        {
            try { PacChecks.RunAsync(portable).GetAwaiter().GetResult(); return 0; }
            catch (BridgeException error) { Console.Error.WriteLine($"Windows PAC check failed at {error.Step}."); return 1; }
            catch (System.ComponentModel.Win32Exception error) { Console.Error.WriteLine($"Windows PAC check failed with Windows error {error.NativeErrorCode}."); return 1; }
            catch (Exception error) { Console.Error.WriteLine($"Windows PAC check failed: {error.GetType().Name}."); return 1; }
        }
        if (args is ["--smoke", var binary, var fixture])
        {
            try { SmokeAsync(binary, fixture).GetAwaiter().GetResult(); return 0; }
            catch (BridgeException error)
            {
                // Report fixed labels only. Never dump a process stream or exception message.
                Console.Error.WriteLine($"Windows desktop session check failed at {error.Step} (exit code {error.ExitCode?.ToString() ?? "unknown"}).");
                return 1;
            }
            catch (Exception error) { Console.Error.WriteLine($"Windows desktop session check failed: {error.GetType().Name}."); return 1; }
        }

        ApplicationConfiguration.Initialize();
        var cli = args is ["--cli", var path] ? Path.GetFullPath(path) : Path.Combine(AppContext.BaseDirectory, "clay-portable.exe");
        if (!File.Exists(cli))
        {
            var message = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName switch
            {
                "zh" => "找不到 clay-portable.exe。将它放在 CLAY 旁边，或用 --cli 指定路径。",
                "ja" => "clay-portable.exe が見つかりません。CLAY と同じフォルダーに配置するか、--cli で指定してください。",
                _ => "Could not find clay-portable.exe. Put it next to CLAY or provide its path with --cli."
            };
            MessageBox.Show(message, "CLAY", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 64;
        }
        using var window = new MainWindow(cli);
        Application.Run(window);
        return 0;
    }

    private static async Task SmokeAsync(string cli, string fixture)
    {
        var scratch = Directory.CreateTempSubdirectory("CLAY Windows desktop ");
        try
        {
            var profile = Path.Combine(scratch.FullName, "profile テスト.txt");
            var rule = Path.Combine(scratch.FullName, "rule.txt");
            await File.WriteAllTextAsync(profile, "ss://aes-128-gcm:sample-one@example.invalid:443#hidden-entry-one\n" +
                                                "ss://aes-128-gcm:sample-two@example.invalid:444#テスト%20节点\n");
            await File.WriteAllTextAsync(rule, "# Fixture\nIP-CIDR6,2001:db8::/32,DIRECT\n");
            if (await PortableSession.PreviewRulesAsync(cli, rule, "") != new RulePreview("count", 1) ||
                await PortableSession.PreviewRulesAsync(cli, rule, "https://[2001:db8::42]/private?token=fixtures-only") != new RulePreview("rule", 1, true))
                throw new BridgeException("rule-preview-match");
            await File.AppendAllTextAsync(rule, "\nINVALID,hidden.example.test,PROXY\n");
            if (await PortableSession.PreviewRulesAsync(cli, rule, "") != new RulePreview("rule-line", 4))
                throw new BridgeException("rule-preview-invalid-line");
            Console.WriteLine("Windows desktop check: offline rule preview passed");
            await File.WriteAllTextAsync(rule, "DOMAIN-SUFFIX,example.invalid,DIRECT\n");
            var inspection = await PortableSession.InspectAsync(cli, profile);
            if (inspection.Nodes.Count != 2 || inspection.Nodes[0].WindowCaption != "1 · hidden-entry-one  [ss/tcp/aead]" ||
                inspection.Nodes[1].WindowCaption != "2 · テスト 节点  [ss/tcp/aead]" ||
                inspection.Nodes.Any(n => n.ToString() != $"{n.Number} · ss/tcp/aead"))
                throw new IOException();
            Console.WriteLine("Windows desktop check: profile inspection passed");
            using var engine = File.OpenRead(fixture);
            var digest = Convert.ToHexString(await SHA256.HashDataAsync(engine));
            var localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var before = Directory.EnumerateDirectories(localData, "clay-win-*").ToHashSet(StringComparer.OrdinalIgnoreCase);
            string address;
            int port;
            await using (var session = await PortableSession.StartAsync(cli, inspection, fixture, digest, rule, "global", 1))
            {
                Console.WriteLine("Windows desktop check: no-console session started");
                address = session.Address;
                if (await session.ApplyAsync(new Route("rule", 2)) != new Route("rule", 2) || session.Address != address)
                    throw new IOException();
                Console.WriteLine("Windows desktop check: combined switch confirmed");
                port = int.Parse(address[(address.LastIndexOf(':') + 1)..]);
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                using var probe = new TcpClient();
                await probe.ConnectAsync(IPAddress.Loopback, port, timeout.Token);
                using var stream = probe.GetStream();
                await stream.WriteAsync("GET http://example.invalid/ HTTP/1.1\r\nHost: example.invalid\r\n\r\n"u8.ToArray(), timeout.Token);
                using var response = new StreamReader(stream, Encoding.ASCII);
                if (!(await response.ReadToEndAsync(timeout.Token)).EndsWith("\r\n\r\nfixture", StringComparison.Ordinal))
                    throw new BridgeException("loopback-response");
            }
            // Windows may silently time out instead of rejecting a connect to a
            // closed port. Check the OS listen table and the private state directly.
            if (IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Any(listener => listener.Port == port))
                throw new BridgeException("listener-still-present");
            if (!before.SetEquals(Directory.EnumerateDirectories(localData, "clay-win-*")))
                throw new BridgeException("private-directory-still-present");
            Console.WriteLine("Windows desktop check: listener and private directory removed");
            await File.AppendAllTextAsync(profile, "# locally changed\n");
            try
            {
                await using var stale = await PortableSession.StartAsync(cli, inspection, fixture, digest, rule, "global", 1);
                throw new IOException();
            }
            catch (ProfileChangedException) { }
            Console.WriteLine("Windows desktop session check passed: redacted import, readback, same address, EOF cleanup, changed profile refused");
        }
        finally { scratch.Delete(recursive: true); }
    }
}
