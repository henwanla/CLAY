using System.Globalization;
using System.Security.Cryptography;

namespace Clay.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args is ["--smoke", var binary, var fixture])
        {
            try { SmokeAsync(binary, fixture).GetAwaiter().GetResult(); return 0; }
            catch { Console.Error.WriteLine("Windows desktop session check failed."); return 1; }
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
            await File.WriteAllTextAsync(profile, "ss://aes-128-gcm:sample-one@example.invalid:443#hidden-entry\n" +
                                                "ss://aes-128-gcm:sample-two@example.invalid:444#hidden-entry\n");
            await File.WriteAllTextAsync(rule, "DOMAIN-SUFFIX,example.invalid,DIRECT\n");
            var inspection = await PortableSession.InspectAsync(cli, profile);
            if (inspection.Nodes.Count != 2 || inspection.Nodes.Any(n => n.Kind != "ss/tcp/aead" || n.ToString().Contains("hidden-entry")))
                throw new IOException();
            using var engine = File.OpenRead(fixture);
            var digest = Convert.ToHexString(await SHA256.HashDataAsync(engine));
            string address;
            await using (var session = await PortableSession.StartAsync(cli, inspection, fixture, digest, rule, "global", 1))
            {
                address = session.Address;
                if (await session.ApplyAsync(new Route("rule", 2)) != new Route("rule", 2) || session.Address != address)
                    throw new IOException();
            }
            using var probe = new System.Net.Sockets.TcpClient();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            var port = int.Parse(address[(address.LastIndexOf(':') + 1)..]);
            try { await probe.ConnectAsync(System.Net.IPAddress.Loopback, port, timeout.Token); throw new IOException(); }
            catch (System.Net.Sockets.SocketException error) when (error.SocketErrorCode == System.Net.Sockets.SocketError.ConnectionRefused) { }
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
