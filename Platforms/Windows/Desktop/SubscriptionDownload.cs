using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;

namespace Clay.Windows;

internal enum SubscriptionFailure { Address, Redirect, Size, Content, Network }
internal sealed class SubscriptionException(SubscriptionFailure reason) : IOException
{
    internal SubscriptionFailure Reason { get; } = reason;
}

internal static class SubscriptionDownload
{
    internal const int MaxBytes = 2 * 1024 * 1024, MaxUrl = 8192;

    internal static Uri Address(string text)
    {
        text = text.Trim();
        if (text.Length is <= 0 or > MaxUrl || text.Any(c => char.IsWhiteSpace(c) || char.IsControl(c)) ||
            text.Contains('\\') || text.Contains('#') || !Uri.TryCreate(text, UriKind.Absolute, out var uri) ||
            !text.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || uri.Host.Length == 0 ||
            text.AsSpan(8).SplitAuthorityContainsUserInfo() || uri.UserInfo.Length != 0 ||
            uri.Port is <= 0 or > 65535 || uri.AbsoluteUri.Length > MaxUrl)
            throw new SubscriptionException(SubscriptionFailure.Address);
        return uri;
    }

    private static bool SplitAuthorityContainsUserInfo(this ReadOnlySpan<char> value)
    {
        int end = value.IndexOfAny('/', '?');
        return (end < 0 ? value : value[..end]).Contains('@');
    }

    internal static Task<byte[]> FetchAsync(Uri address, CancellationToken cancel) => FetchAsync(address, cancel, null);

    // The injected handler is only used by the checks; the app always uses OS TLS trust.
    internal static async Task<byte[]> FetchAsync(Uri address, CancellationToken cancel, HttpMessageHandler? testHandler)
    {
        address = Address(address.AbsoluteUri);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        deadline.CancelAfter(TimeSpan.FromSeconds(25));
        using var http = new HttpClient(testHandler ?? new SocketsHttpHandler
        {
            AllowAutoRedirect = false, UseCookies = false, UseProxy = false, AutomaticDecompression = DecompressionMethods.None,
            ConnectTimeout = TimeSpan.FromSeconds(5), MaxResponseHeadersLength = 32, ActivityHeadersPropagator = null,
            MaxResponseDrainSize = 0
        }) { Timeout = Timeout.InfiniteTimeSpan };
        try
        {
            var current = address;
            for (int hop = 0; hop <= 4; hop++)
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, current);
                request.Headers.UserAgent.ParseAdd("CLAY");
                request.Headers.AcceptEncoding.ParseAdd("gzip, identity");
                using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
                if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308)
                {
                    var location = response.Headers.Location?.OriginalString;
                    if (hop == 4 || string.IsNullOrEmpty(location) || location.Length > MaxUrl || location.Contains('\\') ||
                        !Uri.TryCreate(current, location, out var candidate)) throw new SubscriptionException(SubscriptionFailure.Redirect);
                    try { candidate = Address(candidate.AbsoluteUri); }
                    catch (SubscriptionException) { throw new SubscriptionException(SubscriptionFailure.Redirect); }
                    if (!string.Equals(candidate.IdnHost, current.IdnHost, StringComparison.OrdinalIgnoreCase) || candidate.Port != current.Port)
                        throw new SubscriptionException(SubscriptionFailure.Redirect);
                    current = candidate;
                    continue;
                }
                if (response.StatusCode != HttpStatusCode.OK) throw new SubscriptionException(SubscriptionFailure.Network);
                if (response.Content.Headers.ContentLength > MaxBytes) throw new SubscriptionException(SubscriptionFailure.Size);
                var encodings = response.Content.Headers.ContentEncoding;
                string encoding = encodings.Count == 0 ? "identity" : encodings.Count == 1 ? encodings.First().ToLowerInvariant() : "";
                if (encoding is not ("identity" or "gzip")) throw new SubscriptionException(SubscriptionFailure.Content);
                using var body = await response.Content.ReadAsStreamAsync(deadline.Token);
                var wire = await ReadBoundedAsync(body, deadline.Token);
                if (encoding == "identity") return wire;
                try
                {
                    using var compressed = new MemoryStream(wire, writable: false);
                    using var decoded = new GZipStream(compressed, CompressionMode.Decompress);
                    return await ReadBoundedAsync(decoded, deadline.Token);
                }
                finally { CryptographicOperations.ZeroMemory(wire); }
            }
            throw new SubscriptionException(SubscriptionFailure.Redirect);
        }
        catch (SubscriptionException) { throw; }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested) { throw; }
        catch (InvalidDataException) { throw new SubscriptionException(SubscriptionFailure.Content); }
        catch { throw new SubscriptionException(SubscriptionFailure.Network); }
    }

    private static async Task<byte[]> ReadBoundedAsync(Stream input, CancellationToken cancel)
    {
        using var body = new MemoryStream();
        byte[] chunk = new byte[8192];
        try
        {
            while (true)
            {
                int n = await input.ReadAsync(chunk.AsMemory(0, Math.Min(chunk.Length, MaxBytes + 1 - (int)body.Length)), cancel);
                if (n == 0) return body.ToArray();
                if (body.Length + n > MaxBytes) throw new SubscriptionException(SubscriptionFailure.Size);
                body.Write(chunk, 0, n);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(chunk);
            CryptographicOperations.ZeroMemory(body.GetBuffer().AsSpan(0, (int)body.Length));
        }
    }
}
