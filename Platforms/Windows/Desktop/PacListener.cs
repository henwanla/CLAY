using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Clay.Windows;

/// <summary>Serves a single generated PAC file on an ephemeral loopback port.</summary>
internal sealed class PacListener : IDisposable
{
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource stop = new();
    private readonly SemaphoreSlim slots = new(16);
    private readonly string path = $"/{Guid.NewGuid():N}.pac";
    private readonly string authority;
    private readonly byte[] body;

    internal PacListener(string script)
    {
        body = Encoding.UTF8.GetBytes(script);
        if (body.Length is 0 or > 16_384) throw new IOException();
        listener.ExclusiveAddressUse = true;
        listener.Start(16);
        authority = $"127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}";
        Url = $"http://{authority}{path}";
        _ = ServeAsync(stop.Token);
    }

    internal string Url { get; }

    private async Task ServeAsync(CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(token).ConfigureAwait(false);
                if (slots.Wait(0)) _ = RespondAsync(client, token);
                else client.Dispose();
            }
        }
        catch (Exception error) when (error is OperationCanceledException or SocketException or ObjectDisposedException) { }
    }

    private async Task RespondAsync(TcpClient client, CancellationToken token)
    {
        using (client)
        using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(token))
        {
            deadline.CancelAfter(TimeSpan.FromSeconds(4));
            try
            {
                var stream = client.GetStream();
                var buffer = new byte[8192];
                int used = 0, end = -1;
                while (end < 0 && used < buffer.Length)
                {
                    int count = await stream.ReadAsync(buffer.AsMemory(used), deadline.Token).ConfigureAwait(false);
                    if (count == 0) return;
                    end = buffer.AsSpan(Math.Max(0, used - 3), Math.Min(3, used) + count).IndexOf("\r\n\r\n"u8);
                    if (end >= 0) end += Math.Max(0, used - 3);
                    used += count;
                }
                if (end < 0) return;
                var lines = Encoding.ASCII.GetString(buffer, 0, end).Split("\r\n");
                var request = lines[0].Split(' ');
                var hosts = lines.Skip(1).Where(line => line.StartsWith("Host:", StringComparison.OrdinalIgnoreCase)).ToArray();
                bool found = request is ["GET" or "HEAD", var target, "HTTP/1.0" or "HTTP/1.1"] && target == path &&
                    (hosts.Length == 1 && hosts[0][5..].Trim() == authority || hosts.Length == 0 && request[2] == "HTTP/1.0");
                var status = found ? "200 OK" : "404 Not Found";
                var header = $"HTTP/1.1 {status}\r\nContent-Type: application/x-ns-proxy-autoconfig\r\n" +
                    $"Content-Length: {(found ? body.Length : 0)}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
                await stream.WriteAsync(Encoding.ASCII.GetBytes(header), deadline.Token).ConfigureAwait(false);
                if (found && request[0] == "GET") await stream.WriteAsync(body, deadline.Token).ConfigureAwait(false);
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or SocketException or ObjectDisposedException) { }
            finally { slots.Release(); }
        }
    }

    public void Dispose()
    {
        stop.Cancel();
        listener.Stop();
        stop.Dispose();
    }
}
