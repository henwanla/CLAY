using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace Clay.Windows;

internal sealed class EngineReadException : IOException { }
internal sealed class EngineMismatchException : IOException { }

internal static class EngineIdentity
{
    // Extracted from the verified upstream amd64-compatible ZIP. See docs/RELEASING.md.
    internal const string OfficialSha256 = "5a0231811a80b27477ebdee15684b41946d01afbd2114534e9a4b256125ca147";
    private static readonly Regex Fingerprint = new(@"\A[0-9a-fA-F]{64}\z");
    internal static bool HasFingerprint(string value) => Fingerprint.IsMatch(value);

    internal static async Task<bool> RecognizesAsync(string path) =>
        RuntimeInformation.ProcessArchitecture == Architecture.X64 &&
        string.Equals(await HashAsync(path), OfficialSha256, StringComparison.OrdinalIgnoreCase);

    internal static async Task VerifyAsync(string path, string expected)
    {
        if (!HasFingerprint(expected) || !string.Equals(await HashAsync(path), expected, StringComparison.OrdinalIgnoreCase))
            throw new EngineMismatchException();
    }

    private static async Task<string> HashAsync(string path)
    {
        try
        {
            if (!string.Equals(Path.GetExtension(path), ".exe", StringComparison.OrdinalIgnoreCase) ||
                (File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.ReparsePoint | FileAttributes.Device)) != 0)
                throw new EngineReadException();
            await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            if (file.Length is <= 0 or > 512 * 1024 * 1024) throw new EngineReadException();
            return Convert.ToHexString(await SHA256.HashDataAsync(file));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            throw new EngineReadException();
        }
    }
}
