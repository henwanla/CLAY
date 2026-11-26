using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Clay.Windows;

internal enum PacRelease { None, Restored, ExternalChange }
internal sealed class PacRecoveryException : IOException { }

/// <summary>Owns the current user's PAC settings until restored or replaced.</summary>
internal sealed class WindowsPac : IDisposable
{
    private sealed record Recovery(int Version, WinInetPacSettings Original, string OwnedUrl);
    private static readonly Regex LocalUrl = new(@"\Ahttp://127\.0\.0\.1:([1-9][0-9]{0,4})/[0-9a-f]{32}\.pac\z");
    private readonly IWindowsPacSettings settings;
    private readonly FileStream ownership;
    private readonly string journal;
    private PacListener? listener;
    private Recovery? active;

    internal WindowsPac(IWindowsPacSettings settings, string directory)
    {
        this.settings = settings;
        Directory.CreateDirectory(directory);
        journal = Path.Combine(directory, "recovery.dpapi");
        ownership = File.Open(Path.Combine(directory, "owner.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }

    internal static WindowsPac Open() => new(new WinInetPac(), Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CLAY", "WindowsPAC"));

    internal bool Pending => active is not null || File.Exists(journal);
    internal bool Serving => listener is not null;
    private static WinInetPacSettings Applied(string url) => new(WinInetPac.Direct | WinInetPac.AutoConfig, url);

    internal bool Confirmed() => listener is not null && settings.Read() == Applied(listener.Url);

    internal void Enable(string script)
    {
        if (Pending || listener is not null) throw new PacRecoveryException();
        var original = settings.Read();
        if (original.Url.Length > 16_384) throw new IOException();
        listener = new PacListener(script);
        try
        {
            var recovery = new Recovery(1, original, listener.Url);
            Save(recovery);
            active = recovery;
            if (settings.Read() != original) throw new IOException();
            var applied = Applied(listener.Url);
            settings.Write(applied);
            if (settings.Read() != applied) throw new IOException();
        }
        catch
        {
            try { Release(); }
            catch { throw new PacRecoveryException(); }
            throw;
        }
    }

    internal PacRelease Release()
    {
        if (!Pending) { CloseListener(); return PacRelease.None; }
        try
        {
            var recovery = active ?? ReadRecovery();
            var applied = Applied(recovery.OwnedUrl);
            var current = settings.Read();
            var result = PacRelease.Restored;
            if (current == applied)
            {
                settings.Write(recovery.Original);
                if (settings.Read() != recovery.Original) throw new PacRecoveryException();
            }
            else if (current != recovery.Original)
            {
                // If the live URL still names this listener, stop only after the
                // user resolves the conflict. Never overwrite changed flags.
                if (PointsAtListener(current.Url, recovery.OwnedUrl)) throw new PacRecoveryException();
                result = PacRelease.ExternalChange;
            }
            File.Delete(journal);
            active = null;
            CloseListener();
            return result;
        }
        catch (Exception) { throw new PacRecoveryException(); }
    }

    private static bool PointsAtListener(string url, string owned) =>
        Uri.TryCreate(url, UriKind.Absolute, out var candidate) && Uri.TryCreate(owned, UriKind.Absolute, out var current)
        && candidate.Scheme == "http" && candidate.IsLoopback && candidate.Port == current.Port;

    private Recovery ReadRecovery()
    {
        var size = new FileInfo(journal).Length;
        if (size is <= 0 or > 262144) throw new IOException();
        byte[] bytes = UserProtection.Transform(File.ReadAllBytes(journal), protect: false, limit: 262144);
        try
        {
            var recovery = JsonSerializer.Deserialize<Recovery>(bytes);
            if (recovery is not { Version: 1, Original.Url: { Length: <= 16384 }, OwnedUrl: not null }) throw new IOException();
            var match = LocalUrl.Match(recovery.OwnedUrl);
            if (!match.Success || !ushort.TryParse(match.Groups[1].Value, out _)) throw new IOException();
            return recovery;
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    private void Save(Recovery recovery)
    {
        var clear = JsonSerializer.SerializeToUtf8Bytes(recovery);
        var temporary = Path.Combine(Path.GetDirectoryName(journal)!, $".recovery-{Guid.NewGuid():N}");
        try
        {
            var encrypted = UserProtection.Transform(clear, protect: true, limit: 262144);
            using (var writer = File.Open(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                writer.Write(encrypted);
                writer.Flush(flushToDisk: true);
            }
            File.Move(temporary, journal);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clear);
            File.Delete(temporary);
        }
    }

    private void CloseListener() { listener?.Dispose(); listener = null; }

    public void Dispose() { CloseListener(); ownership.Dispose(); }
}
