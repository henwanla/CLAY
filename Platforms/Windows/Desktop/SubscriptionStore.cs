using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Clay.Windows;

internal sealed class SubscriptionStore(string directory)
{
    internal const int Limit = 12, MaxName = 64;
    private const int MaxRecord = 3 * 1024 * 1024;

    internal sealed record Entry(Guid Id, Guid Revision, string Name, int Count, long Updated)
    {
        internal bool Readable => Count > 0;
    }

    internal sealed record Data(Entry Entry, Uri Address, byte[] Source) : IDisposable
    {
        public void Dispose() => CryptographicOperations.ZeroMemory(Source);
    }

    private sealed record Record(int Format, Entry Entry, string Address, byte[] Source);

    internal static SubscriptionStore Open() => new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "CLAY", "Subscriptions-v1"));

    internal static string Name(string text)
    {
        text = text.Trim();
        if (text.Length is <= 0 or > MaxName || text.EnumerateRunes().Any(r => Rune.GetUnicodeCategory(r) is
            UnicodeCategory.Control or UnicodeCategory.Format or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator))
            throw new ArgumentException();
        return text;
    }

    internal IReadOnlyList<Entry> List()
    {
        using var ownership = Lock();
        var result = new List<Entry>();
        foreach (var id in Ids())
        {
            try { using var data = ReadLocked(id); result.Add(data.Entry); }
            catch (Exception error) when (error is IOException or ArgumentException or JsonException or System.ComponentModel.Win32Exception)
            { result.Add(new(id, Guid.Empty, "", 0, 0)); }
        }
        return result.OrderByDescending(entry => entry.Updated).ThenBy(entry => entry.Id).ToArray();
    }

    internal Data Read(Guid id)
    {
        using var ownership = Lock();
        return ReadLocked(id);
    }

    internal Entry Add(string name, Uri address, byte[] source, int count)
    {
        using var ownership = Lock();
        if (Ids().Count >= Limit) throw new IOException();
        var entry = new Entry(Guid.NewGuid(), Guid.NewGuid(), Name(name), count, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        return Save(entry, address, source, replace: false);
    }

    internal Entry Refresh(Entry previous, byte[] source, int count)
    {
        using var ownership = Lock();
        using var current = ReadLocked(previous.Id);
        if (current.Entry.Revision != previous.Revision) throw new IOException();
        var entry = current.Entry with { Revision = Guid.NewGuid(), Count = count,
            Updated = Math.Max(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), previous.Updated + 1) };
        return Save(entry, current.Address, source, replace: true);
    }

    internal void Remove(Guid id)
    {
        using var ownership = Lock();
        File.Delete(FileName(id));
    }

    private FileStream Lock()
    {
        Directory.CreateDirectory(directory);
        return File.Open(Path.Combine(directory, "owner.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }

    private List<Guid> Ids()
    {
        var ids = new List<Guid>();
        foreach (var file in Directory.EnumerateFiles(directory, "*.dpapi"))
        {
            if (!Guid.TryParseExact(Path.GetFileNameWithoutExtension(file), "N", out var id) || id == Guid.Empty) continue;
            if (ids.Count >= Limit) throw new IOException();
            ids.Add(id);
        }
        return ids;
    }

    private string FileName(Guid id) => id == Guid.Empty ? throw new IOException() : Path.Combine(directory, $"{id:N}.dpapi");
    private static byte[] Binding(Guid id) => Encoding.ASCII.GetBytes($"CLAY.Windows.Subscriptions.v1:{id:N}");

    private Data ReadLocked(Guid id)
    {
        using var input = File.Open(FileName(id), FileMode.Open, FileAccess.Read, FileShare.Read);
        var size = input.Length;
        if (size is <= 0 or > MaxRecord) throw new IOException();
        var encrypted = new byte[(int)size];
        input.ReadExactly(encrypted);
        var clear = UserProtection.Transform(encrypted, protect: false, MaxRecord, Binding(id));
        Record? record = null;
        try
        {
            record = JsonSerializer.Deserialize<Record>(clear);
            if (record is not { Format: 1, Entry: { Name: not null }, Address: not null, Source: not null } ||
                record.Entry.Id != id || record.Entry.Revision == Guid.Empty || record.Entry.Updated <= 0 ||
                record.Entry.Name != Name(record.Entry.Name)) throw new IOException();
            ValidateSource(record.Source, record.Entry.Count);
            var result = new Data(record.Entry, SubscriptionDownload.Address(record.Address), record.Source);
            record = null;
            return result;
        }
        finally
        {
            if (record?.Source is { } source) CryptographicOperations.ZeroMemory(source);
            CryptographicOperations.ZeroMemory(clear);
        }
    }

    private Entry Save(Entry entry, Uri address, byte[] source, bool replace)
    {
        ValidateSource(source, entry.Count);
        address = SubscriptionDownload.Address(address.AbsoluteUri);
        var clear = JsonSerializer.SerializeToUtf8Bytes(new Record(1, entry, address.AbsoluteUri, source));
        string staging = Path.Combine(directory, $".pending-{Guid.NewGuid():N}");
        try
        {
            var encrypted = UserProtection.Transform(clear, protect: true, MaxRecord, Binding(entry.Id));
            using (var writer = File.Open(staging, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                writer.Write(encrypted);
                writer.Flush(flushToDisk: true);
            }
            File.Move(staging, FileName(entry.Id), overwrite: replace);
            using var confirmed = ReadLocked(entry.Id);
            if (confirmed.Entry != entry) throw new IOException();
            return confirmed.Entry;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clear);
            File.Delete(staging);
        }
    }

    private static void ValidateSource(byte[] source, int count)
    {
        if (source.Length is <= 0 or > SubscriptionDownload.MaxBytes || count is < 1 or > 100) throw new IOException();
    }
}
