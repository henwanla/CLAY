using System.Buffers.Binary;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Clay.Windows;

internal sealed record Node(int Number, string Kind, string Label)
{
    public override string ToString() => $"{Number} · {Kind}";
    public string WindowCaption => Label.Length == 0 ? ToString() : $"{Number} · {Label}  [{Kind}]";
}

internal sealed record Inspection(string? Path, byte[] Digest, IReadOnlyList<Node> Nodes);
internal sealed record Route(string Mode, int Node);
internal sealed record RulePreview(string Kind, int Number = 0, bool Direct = false);
internal sealed class ProfileChangedException : Exception { }
internal sealed class SessionCleanupException : Exception { }
internal sealed class BridgeException(string step, int? exitCode = null) : IOException
{
    internal string Step { get; } = step;
    internal int? ExitCode { get; } = exitCode;
}

internal sealed class PortableSession : IAsyncDisposable
{
    private static readonly Regex CountLine = new(@"\Anodes=([1-9][0-9]{0,2})\z");
    private static readonly Regex NodeLine = new(@"\Anode=([1-9][0-9]{0,2}) ([a-z0-9-]{1,24}/[a-z0-9-]{1,16}/[a-z0-9-]{1,16}) ([A-Za-z0-9+/=]{1,344}|-)\z");
    private static readonly Regex IssueLine = new(@"\Askipped\.[a-zA-Z]{1,32}=[0-9]{1,10}\z");
    private static readonly Encoding StrictUtf8 = new UTF8Encoding(false, true);
    private static readonly Regex Ready = new(@"\Amihomo=ready proxy=127\.0\.0\.1:([0-9]{1,5}) controller=127\.0\.0\.1:[0-9]{1,5}\z");
    private static readonly Regex Status = new(@"\Amode=(rule|global|direct) node=([1-9][0-9]{0,2})\z");
    private static readonly Regex PreviewCount = new(@"\Avalid_pac_rules=([0-9]{1,7})\z");
    private static readonly Regex PreviewLine = new(@"\Aerror=rule-line:([1-9][0-9]{0,6})\z");
    private static readonly Regex PreviewDecision = new(@"\Adecision=(DIRECT|PROXY) source=(loopback|local|default|rule:([1-9][0-9]{0,6}))\z");
    private readonly Process cli;
    private readonly Task discardErrors;
    private readonly HashSet<int> nodes;

    private PortableSession(Process cli, IEnumerable<Node> nodes)
    {
        this.cli = cli;
        this.nodes = nodes.Select(node => node.Number).ToHashSet();
        discardErrors = cli.StandardError.BaseStream.CopyToAsync(Stream.Null);
    }

    internal string Address { get; private set; } = "";
    internal bool Ended => cli.HasExited;

    internal static async Task<RulePreview> PreviewRulesAsync(string executable, string path, string target,
        CancellationToken cancel = default)
    {
        if (Encoding.UTF8.GetByteCount(target) > 4096) return new("too-long");
        using var child = StartProcess(executable, ["desktop-rule-preview", path]);
        var discard = child.StandardError.BaseStream.CopyToAsync(Stream.Null);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        try
        {
            await child.StandardInput.BaseStream.WriteAsync(Encoding.UTF8.GetBytes(target), timeout.Token);
            child.StandardInput.Close();
            var buffer = new char[81];
            var length = await child.StandardOutput.ReadBlockAsync(buffer.AsMemory(), timeout.Token);
            if (length is 0 or >= 81 || buffer[length - 1] != '\n') throw new BridgeException("rule-preview-output");
            await child.WaitForExitAsync(timeout.Token);
            if (child.ExitCode != 0) throw new BridgeException("rule-preview", child.ExitCode);
            var end = length > 1 && buffer[length - 2] == '\r' ? length - 2 : length - 1;
            var result = new string(buffer, 0, end);
            if (result == "error=target") return new("target");
            if (result == "error=rules") return new("rules");
            var match = PreviewCount.Match(result);
            if (match.Success) return new("count", int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture));
            match = PreviewLine.Match(result);
            if (match.Success) return new("rule-line", int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture));
            match = PreviewDecision.Match(result);
            if (!match.Success) throw new BridgeException("rule-preview-output");
            var direct = match.Groups[1].Value == "DIRECT";
            return match.Groups[3].Success
                ? new("rule", int.Parse(match.Groups[3].Value, CultureInfo.InvariantCulture), direct)
                : new(match.Groups[2].Value, Direct: direct);
        }
        finally
        {
            if (!child.HasExited) child.Kill();
            await discard;
        }
    }

    internal static async Task<string> DefaultPacAsync(string executable, string address)
    {
        const string loopback = "127.0.0.1:";
        if (!address.StartsWith(loopback, StringComparison.Ordinal) || !ushort.TryParse(address.AsSpan(loopback.Length), out var port) || port == 0)
            throw new IOException();
        // The shared PAC generator keeps literal local/private destinations direct
        // and sends other traffic to Mihomo, which owns the selected mode.
        var emptyRules = Path.GetTempFileName();
        try
        {
            using var child = StartProcess(executable, ["pac-script", emptyRules, port.ToString(System.Globalization.CultureInfo.InvariantCulture)]);
            var discard = child.StandardError.BaseStream.CopyToAsync(Stream.Null);
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            try
            {
                var buffer = new char[8193];
                int length = await child.StandardOutput.ReadBlockAsync(buffer.AsMemory(), limit.Token);
                if (length is 0 or >= 8193) throw new IOException();
                await child.WaitForExitAsync(limit.Token);
                if (child.ExitCode != 0) throw new IOException();
                return new string(buffer, 0, length);
            }
            finally
            {
                if (!child.HasExited) child.Kill();
                await discard;
            }
        }
        finally { File.Delete(emptyRules); }
    }

    internal static async Task<Inspection> InspectAsync(string executable, string path)
    {
        path = Path.GetFullPath(path);
        using var snapshot = OpenProfile(path);
        var source = new byte[(int)snapshot.Length];
        try
        {
            await snapshot.ReadExactlyAsync(source);
            var inspected = await InspectAsync(executable, source);
            return inspected with { Path = path };
        }
        finally { CryptographicOperations.ZeroMemory(source); }
    }

    internal static async Task<Inspection> InspectAsync(string executable, ReadOnlyMemory<byte> source)
    {
        var nodes = await ReadNodesAsync(executable, source);
        return new Inspection(null, SHA256.HashData(source.Span), nodes);
    }

    private static async Task<List<Node>> ReadNodesAsync(string executable, ReadOnlyMemory<byte> source)
    {
        using var process = StartProcess(executable, ["desktop-node-list", "--profile-stdin"]);
        var discard = process.StandardError.BaseStream.CopyToAsync(Stream.Null);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        // The shared bridge emits at most 100 bounded ASCII rows and a few counters.
        var buffer = new char[43_000];
        try
        {
            await SendFrameAsync(process, source, timeout.Token);
            process.StandardInput.Close();
            int length = await process.StandardOutput.ReadBlockAsync(buffer.AsMemory(), timeout.Token);
            if (length == buffer.Length) throw new IOException();
            await process.WaitForExitAsync(timeout.Token);
            if (process.ExitCode != 0) throw new BridgeException("inspect-result", process.ExitCode);
            using var rows = new StringReader(new string(buffer, 0, length));
            var header = CountLine.Match(rows.ReadLine() ?? "");
            if (!header.Success || !int.TryParse(header.Groups[1].Value, out var count) || count > 100) throw new IOException();
            var nodes = new List<Node>(count);
            for (var index = 1; index <= count; index++)
            {
                var match = NodeLine.Match(rows.ReadLine() ?? "");
                if (!match.Success || int.Parse(match.Groups[1].Value) != index) throw new IOException();
                var payload = match.Groups[3].Value;
                var label = payload == "-" ? "" : StrictUtf8.GetString(Convert.FromBase64String(payload));
                if (label.Contains("://", StringComparison.Ordinal) || label.EnumerateRunes().Count() > 64 ||
                    label.EnumerateRunes().Any(r => Rune.GetUnicodeCategory(r) is UnicodeCategory.Control or UnicodeCategory.Format or
                        UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator)) throw new IOException();
                nodes.Add(new Node(index, match.Groups[2].Value, label));
            }
            while (rows.ReadLine() is { } issue)
                if (!IssueLine.IsMatch(issue)) throw new IOException();
            return nodes;
        }
        finally
        {
            Array.Clear(buffer);
            if (!process.HasExited) process.Kill();
            await discard;
        }
    }

    internal static async Task<PortableSession> StartAsync(string executable, Inspection profile, string engine,
        string sha256, string? rules, string mode, int node, ReadOnlyMemory<byte> source = default)
    {
        if (!EngineIdentity.HasFingerprint(sha256) || mode is not ("rule" or "global" or "direct") ||
            profile.Nodes.All(item => item.Number != node)) throw new ArgumentException();
        // Give immediate feedback before startup. The native runtime also verifies its own staged copy.
        await EngineIdentity.VerifyAsync(engine, sha256);
        // Hold the chosen profile read-only through startup, and refuse a changed file.
        using var snapshot = profile.Path is null ? null : OpenProfile(profile.Path);
        var actual = snapshot is null ? SHA256.HashData(source.Span) : await SHA256.HashDataAsync(snapshot);
        if (!CryptographicOperations.FixedTimeEquals(actual, profile.Digest))
            throw new ProfileChangedException();
        List<string> args = ["mihomo-run", profile.Path ?? "--profile-stdin", node.ToString(), Path.GetFullPath(engine), sha256,
                             "--all-nodes", "--interactive", "--mode", mode];
        if (rules is not null) args.AddRange(["--pac-rules", Path.GetFullPath(rules)]);
        var session = new PortableSession(StartProcess(executable, args), profile.Nodes);
        try
        {
            if (snapshot is null)
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(6));
                await SendFrameAsync(session.cli, source, timeout.Token);
            }
            var match = Ready.Match(await session.ReadAsync(TimeSpan.FromSeconds(20)));
            if (!match.Success || !ushort.TryParse(match.Groups[1].Value, out var port) || port == 0) throw new BridgeException("ready-message");
            if (await session.RefreshAsync() != new Route(mode, node)) throw new BridgeException("initial-state");
            session.Address = $"127.0.0.1:{port}";
            return session;
        }
        catch
        {
            try { await session.DisposeAsync(); } catch { /* Preserve the original startup failure. */ }
            throw;
        }
    }

    private static async Task SendFrameAsync(Process process, ReadOnlyMemory<byte> source, CancellationToken cancel)
    {
        if (source.Length is <= 0 or > 2 * 1024 * 1024) throw new IOException();
        byte[] header = new byte[4];
        BinaryPrimitives.WriteInt32BigEndian(header, source.Length);
        var pipe = process.StandardInput.BaseStream;
        await pipe.WriteAsync(header, cancel);
        await pipe.WriteAsync(source, cancel);
        await pipe.FlushAsync(cancel);
    }

    internal async Task<Route> RefreshAsync()
    {
        var match = Status.Match(await ExchangeAsync("status"));
        if (!match.Success || !int.TryParse(match.Groups[2].Value, out var node) || !nodes.Contains(node)) throw new BridgeException("status-message");
        return new Route(match.Groups[1].Value, node);
    }

    internal async Task<Route> ApplyAsync(Route desired)
    {
        if (!nodes.Contains(desired.Node) || desired.Mode is not ("rule" or "global" or "direct")) throw new ArgumentException();
        var before = await RefreshAsync();
        if (before.Node != desired.Node && await ExchangeAsync($"node {desired.Node}") != $"node={desired.Node}") throw new IOException();
        if (before.Mode != desired.Mode && await ExchangeAsync($"mode {desired.Mode}") != $"mode={desired.Mode}") throw new IOException();
        var confirmed = await RefreshAsync();
        if (confirmed != desired) throw new IOException();
        return confirmed;
    }

    private async Task<string> ExchangeAsync(string command)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(7));
        await cli.StandardInput.WriteLineAsync(command.AsMemory(), timeout.Token);
        await cli.StandardInput.FlushAsync(timeout.Token);
        return await ReadAsync(timeout.Token);
    }

    private async Task<string> ReadAsync(TimeSpan timeout)
    {
        using var limit = new CancellationTokenSource(timeout);
        return await ReadAsync(limit.Token);
    }

    private async Task<string> ReadAsync(CancellationToken token)
    {
        var line = await cli.StandardOutput.ReadLineAsync(token);
        return line is { Length: > 0 and <= 160 } ? line : throw new BridgeException("missing-reply", cli.HasExited ? cli.ExitCode : null);
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            if (!cli.HasExited)
            {
                using var quit = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                // EOF is also a graceful stop if the pipe is closed prematurely.
                cli.StandardInput.Close();
                await cli.WaitForExitAsync(quit.Token);
            }
            await discardErrors;
            if (cli.ExitCode != 0) throw new SessionCleanupException();
        }
        catch (Exception error) when (error is IOException or OperationCanceledException)
        {
            if (!cli.HasExited) cli.Kill();  // The CLI's kill-on-close Windows job owns Mihomo.
            await cli.WaitForExitAsync();
            throw new SessionCleanupException();
        }
        finally { cli.Dispose(); }
    }

    private static FileStream OpenProfile(string path)
    {
        var file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length is > 0 and <= 2 * 1024 * 1024) return file;
        file.Dispose();
        throw new IOException();
    }

    private static Process StartProcess(string executable, IEnumerable<string> args)
    {
        executable = Path.GetFullPath(executable);
        var info = new ProcessStartInfo(executable)
        {
            WorkingDirectory = Path.GetDirectoryName(executable)!, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false), StandardOutputEncoding = Encoding.UTF8
        };
        // Only the paths Windows and the Swift runtime need. Do not inherit
        // CLI tokens, developer settings, or the user's HTTP proxy environment.
        info.Environment.Clear();
        foreach (string name in new[] { "SystemRoot", "WINDIR", "PATH", "USERPROFILE", "LOCALAPPDATA", "TEMP", "TMP" })
            if (Environment.GetEnvironmentVariable(name) is { } value) info.Environment[name] = value;
        foreach (string argument in args) info.ArgumentList.Add(argument);
        return Process.Start(info) ?? throw new IOException();
    }
}
