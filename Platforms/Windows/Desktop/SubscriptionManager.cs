using System.Security.Cryptography;

namespace Clay.Windows;

internal sealed class SubscriptionManager(string cli, SubscriptionStore store,
    Func<Uri, CancellationToken, Task<byte[]>>? fetch = null)
{
    internal sealed record Selection(SubscriptionStore.Entry Entry, Inspection Inspection, byte[] Source) : IDisposable
    {
        public void Dispose() => CryptographicOperations.ZeroMemory(Source);
    }

    internal async Task<SubscriptionStore.Entry> AddAsync(string name, string url, CancellationToken cancel)
    {
        name = SubscriptionStore.Name(name);
        var address = SubscriptionDownload.Address(url);
        var source = await DownloadAsync(address, cancel);
        try
        {
            var verified = await InspectAsync(source);
            return await Task.Run(() => store.Add(name, address, source, verified.Nodes.Count), cancel);
        }
        finally { CryptographicOperations.ZeroMemory(source); }
    }

    internal async Task RefreshAsync(Guid id, CancellationToken cancel)
    {
        using var old = await Task.Run(() => store.Read(id), cancel);
        var source = await DownloadAsync(old.Address, cancel);
        try
        {
            var verified = await InspectAsync(source);
            await Task.Run(() => store.Refresh(old.Entry, source, verified.Nodes.Count), cancel);
        }
        finally { CryptographicOperations.ZeroMemory(source); }
    }

    internal async Task<Selection> SelectAsync(Guid id, CancellationToken cancel)
    {
        using var data = await Task.Run(() => store.Read(id), cancel);
        var inspection = await InspectAsync(data.Source);
        cancel.ThrowIfCancellationRequested();
        return new(data.Entry, inspection, (byte[])data.Source.Clone());
    }

    private Task<byte[]> DownloadAsync(Uri address, CancellationToken cancel) =>
        fetch is null ? SubscriptionDownload.FetchAsync(address, cancel) : fetch(address, cancel);

    private async Task<Inspection> InspectAsync(byte[] source)
    {
        try { return await PortableSession.InspectAsync(cli, source); }
        catch (BridgeException error) when (error.Step == "inspect-result" && error.ExitCode == 65)
        { throw new SubscriptionException(SubscriptionFailure.Content); }
    }
}
