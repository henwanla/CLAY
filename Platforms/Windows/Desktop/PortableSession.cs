using System.Buffers.Binary;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Clay.Windows;

internal sealed record Node(int Number, string Kind)
{
    public override string ToString() => $"{Number} · {Kind}";
}

internal sealed record Inspection(string? Path, byte[] Digest, IReadOnlyList<Node> Nodes);
internal sealed record Route(string Mode, int Node);
internal sealed class ProfileChangedException : Exception { }
internal sealed class SessionCleanupException : Exception { }
internal sealed class BridgeException(string step, int? exitCode = null) : IOException
{
    internal string Step { get; } = step;
    internal int? ExitCode { get; } = exitCode;
}

internal sealed class PortableSession : IAsyncDisposable
{
    private static readonly Regex NodeLine = new(@"\Anode=([1-9][0-9]{0,2}) ([a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+)\z");
    private static readonly Regex Ready = new(@"\Amihomo=ready proxy=127\.0\.0\.1:([0-9]{1,5}) controller=127\.0\.0\.1:[0-9]{1,5}\z");
    private static readonly Regex Status = new(@"\Amode=(rule|global|direct) node=([1-9][0-9]{0,2})\z");
    private static readonly Regex Sha256 = new(@"\A[0-9a-fA-F]{64}\z");
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
        var digest = await SHA256.HashDataAsync(snapshot);
        return new Inspection(path, digest, await InspectAsync(executable, path, default));
    }

    internal static async Task<Inspection> InspectAsync(string executable, ReadOnlyMemory<byte> source)
    {
        var nodes = await InspectAsync(executable, null, source);
        return new Inspection(null, SHA256.HashData(source.Span), nodes);
    }

    private static async Task<List<Node>> InspectAsync(string executable, string? path, ReadOnlyMemory<byte> source)
    {
        using var process = StartProcess(executable, ["inspect", path ?? "--profile-stdin", "--numbered"]);
        var discard = process.StandardError.BaseStream.CopyToAsync(Stream.Null);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var nodes = new List<Node>();
        try
        {
            if (path is null) await SendFrameAsync(process, source, timeout.Token);
            process.StandardInput.Close();
            while (await process.StandardOutput.ReadLineAsync(timeout.Token) is { } line)
            {
                if (line.Length > 160) throw new IOException();
                var match = NodeLine.Match(line);
                if (!match.Success) continue;
                var node = int.Parse(match.Groups[1].Value);
                if (nodes.Count >= 100 || node != nodes.Count + 1) throw new IOException();
                nodes.Add(new Node(node, match.Groups[2].Value));
            }
            await process.WaitForExitAsync(timeout.Token);
            if (process.ExitCode != 0 || nodes.Count == 0) throw new BridgeException("inspect-result", process.ExitCode);
            return nodes;
        }
        finally
        {
            if (!process.HasExited) process.Kill();
            await discard;
        }
    }

    internal static async Task<PortableSession> StartAsync(string executable, Inspection profile, string engine,
        string sha256, string? rules, string mode, int node, ReadOnlyMemory<byte> source = default)
    {
        if (!Sha256.IsMatch(sha256) || mode is not ("rule" or "global" or "direct") ||
            profile.Nodes.All(item => item.Number != node)) throw new ArgumentException();
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
