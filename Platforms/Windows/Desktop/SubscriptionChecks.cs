using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace Clay.Windows;

internal static class SubscriptionChecks
{
    private const string Url = "https://feed.example.invalid/path?secret=synthetic-subscription";
    private const string Label = "订阅テスト";
    private const string First = "ss://aes-128-gcm:synthetic-node-one@example.invalid:443#fixture\r\n";
    private const string Second = "ss://aes-128-gcm:synthetic-node-two@example.invalid:444#other\r\n";

    internal static async Task RunAsync(string cli, string fixture)
    {
        await CheckDownloadAsync();
        var scratch = Directory.CreateTempSubdirectory("clay-subscription-check-");
        try
        {
            var store = new SubscriptionStore(scratch.FullName);
            string response = "\uFEFF" + First + Second;
            var manager = new SubscriptionManager(cli, store, (uri, cancel) => SubscriptionDownload.FetchAsync(uri, cancel,
                new Transport(_ => Payload(Encoding.UTF8.GetBytes(response)))));
            var entry = await manager.AddAsync(Label, Url, default);
            var file = Path.Combine(scratch.FullName, $"{entry.Id:N}.dpapi");
            var original = File.ReadAllBytes(file);
            foreach (var privateText in new[] { Label, "synthetic-subscription", "synthetic-node-one", "feed.example.invalid" })
                Check(!Encoding.UTF8.GetString(original).Contains(privateText) && !Encoding.Unicode.GetString(original).Contains(privateText), "dpapi-no-cleartext");
            using (var reopened = new SubscriptionStore(scratch.FullName).Read(entry.Id))
                Check(reopened.Entry == entry && reopened.Address.AbsoluteUri == Url && reopened.Source.AsSpan().SequenceEqual(Encoding.UTF8.GetBytes(response)),
                    "dpapi-reopen");

            using var selection = await manager.SelectAsync(entry.Id, default);
            Check(selection.Inspection.Path is null && selection.Inspection.Nodes.Count == 2 &&
                selection.Inspection.Nodes.All(n => n.Kind == "ss/tcp/aead"), "in-memory-subscription-inspection");
            response = "This is not a proxy configuration.";
            await RejectAsync(() => manager.RefreshAsync(entry.Id, default), SubscriptionFailure.Content);
            Check(File.ReadAllBytes(file).AsSpan().SequenceEqual(original), "failed-refresh-keeps-old-record");

            response = Second;
            await manager.RefreshAsync(entry.Id, default);
            using (var replacement = await manager.SelectAsync(entry.Id, default))
                Check(replacement.Entry.Revision != entry.Revision && replacement.Entry.Count == 1 &&
                    selection.Inspection.Nodes.Count == 2 && selection.Source.AsSpan().SequenceEqual(Encoding.UTF8.GetBytes("\uFEFF" + First + Second)),
                    "refresh-keeps-selected-snapshot");
            try { store.Refresh(entry, selection.Source, 2); throw new BridgeException("stale-refresh-overwrote-cache"); }
            catch (IOException error) when (error is not BridgeException) { }
            var duplicate = Guid.NewGuid();
            File.Copy(file, Path.Combine(scratch.FullName, $"{duplicate:N}.dpapi"));
            Check(store.List().Single(item => item.Id == duplicate).Readable == false, "dpapi-bound-to-record-id");
            store.Remove(duplicate);
            File.WriteAllBytes(file, original[..(original.Length / 2)]);
            Check(!store.List().Single().Readable, "corrupt-entry-fails-closed");
            store.Remove(entry.Id);
            Check(store.List().Count == 0 && !Directory.EnumerateFiles(scratch.FullName, ".pending-*").Any(), "cache-removal");

            using var trustedEngine = File.OpenRead(fixture);
            string sha = Convert.ToHexString(await SHA256.HashDataAsync(trustedEngine));
            await using var session = await PortableSession.StartAsync(cli, selection.Inspection, fixture, sha, null, "global", 1, selection.Source);
            var endpoint = session.Address;
            Check(await session.ApplyAsync(new Route("rule", 2)) == new Route("rule", 2) && session.Address == endpoint, "cached-session-node-and-mode");
            using var timer = new CancellationTokenSource(TimeSpan.FromSeconds(4));
            using var probe = new TcpClient();
            await probe.ConnectAsync(IPAddress.Loopback, int.Parse(endpoint[(endpoint.LastIndexOf(':') + 1)..]), timer.Token);
            using var stream = probe.GetStream();
            await stream.WriteAsync("GET http://example.invalid/ HTTP/1.1\r\nHost: example.invalid\r\n\r\n"u8.ToArray(), timer.Token);
            using var reader = new StreamReader(stream, Encoding.ASCII);
            Check((await reader.ReadToEndAsync(timer.Token)).EndsWith("\r\n\r\nfixture", StringComparison.Ordinal), "cached-session-loopback");
            Console.WriteLine("PASS Windows subscriptions: HTTPS redirect and size policy, encrypted cache and recovery, profile pipe and live routing");
        }
        finally { scratch.Delete(recursive: true); }
    }

    internal static async Task CheckDownloadAsync()
    {
        var origin = SubscriptionDownload.Address(Url);
        int calls = 0;
        var compressed = Zip(Encoding.UTF8.GetBytes(First));
        var payload = await SubscriptionDownload.FetchAsync(origin, default, new Transport(request =>
        {
            if (++calls == 1) return Redirect("https://FEED.example.invalid:443/cache");
            Check(request.RequestUri?.AbsolutePath == "/cache", "same-origin-next-path");
            return Payload(compressed, "gzip");
        }));
        Check(calls == 2 && payload.AsSpan().SequenceEqual(Encoding.UTF8.GetBytes(First)), "same-origin-gzip");

        foreach (string blocked in new[] { "http://feed.example.invalid/path", "https://other.example.invalid/path", "https://feed.example.invalid:444/path", "https://@feed.example.invalid/path" })
        {
            calls = 0;
            await RejectAsync(() => SubscriptionDownload.FetchAsync(origin, default, new Transport(_ => { calls++; return Redirect(blocked); })),
                SubscriptionFailure.Redirect);
            Check(calls == 1, "redirect-not-contacted");
        }
        await RejectAsync(() => SubscriptionDownload.FetchAsync(origin, default, new Transport(_ => Redirect("/again"))), SubscriptionFailure.Redirect);
        var tooLarge = new byte[SubscriptionDownload.MaxBytes + 1];
        foreach (var (bytes, encoding, advertisedLength) in new (byte[], string?, long)[]
                 { ([], null, tooLarge.Length), (tooLarge, null, 1), (Zip(tooLarge), "gzip", 1) })
        {
            await RejectAsync(() => SubscriptionDownload.FetchAsync(origin, default, new Transport(_ =>
            {
                var reply = Payload(bytes, encoding);
                reply.Content.Headers.ContentLength = advertisedLength;
                return reply;
            })), SubscriptionFailure.Size);
        }
    }

    private static async Task RejectAsync(Func<Task> run, SubscriptionFailure reason)
    {
        try { await run(); }
        catch (SubscriptionException error) when (error.Reason == reason) { return; }
        throw new BridgeException("expected-subscription-rejection");
    }

    private static HttpResponseMessage Payload(byte[] body, string? encoding = null)
    {
        var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(body) };
        if (encoding is not null) response.Content.Headers.ContentEncoding.Add(encoding);
        return response;
    }

    private static HttpResponseMessage Redirect(string location)
    {
        var response = new HttpResponseMessage(HttpStatusCode.TemporaryRedirect);
        response.Headers.Location = new Uri(location, UriKind.RelativeOrAbsolute);
        return response;
    }

    private static byte[] Zip(byte[] body)
    {
        using var target = new MemoryStream();
        using (var zip = new GZipStream(target, CompressionMode.Compress, leaveOpen: true)) zip.Write(body);
        return target.ToArray();
    }

    private sealed class Transport(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(send(request));
    }

    private static void Check(bool result, string step) { if (!result) throw new BridgeException(step); }
}
