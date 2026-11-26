using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Clay.Windows;

/// <summary>Current Windows user's DPAPI, without interactive prompts or machine scope.</summary>
internal static class UserProtection
{
    internal static byte[] Transform(byte[] input, bool protect, int limit, byte[]? binding = null)
    {
        if (input.Length is <= 0 || input.Length > limit) throw new IOException();
        GCHandle pin = default, bindingPin = default;
        nint entropy = 0;
        Blob output = default;
        try
        {
            pin = GCHandle.Alloc(input, GCHandleType.Pinned);
            var source = new Blob { Size = input.Length, Data = pin.AddrOfPinnedObject() };
            if (binding is not null)
            {
                bindingPin = GCHandle.Alloc(binding, GCHandleType.Pinned);
                entropy = Marshal.AllocHGlobal(Marshal.SizeOf<Blob>());
                Marshal.StructureToPtr(new Blob { Size = binding.Length, Data = bindingPin.AddrOfPinnedObject() }, entropy, false);
            }
            const uint noUi = 1;
            var success = protect ? CryptProtectData(ref source, 0, entropy, 0, 0, noUi, out output)
                : CryptUnprotectData(ref source, 0, entropy, 0, 0, noUi, out output);
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (output.Size is <= 0 || output.Size > limit) throw new IOException();
            var bytes = new byte[output.Size];
            Marshal.Copy(output.Data, bytes, 0, bytes.Length);
            return bytes;
        }
        finally
        {
            if (output.Data != 0)
            {
                if (!protect && output.Size > 0 && output.Size <= limit)
                {
                    byte[] zero = new byte[4096];
                    for (int offset = 0; offset < output.Size; offset += zero.Length)
                        Marshal.Copy(zero, 0, output.Data + offset, Math.Min(zero.Length, output.Size - offset));
                }
                LocalFree(output.Data);
            }
            if (entropy != 0) Marshal.FreeHGlobal(entropy);
            if (bindingPin.IsAllocated) bindingPin.Free();
            if (pin.IsAllocated) pin.Free();
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Blob { internal int Size; internal nint Data; }
    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern bool CryptProtectData(ref Blob input, nint description, nint entropy, nint reserved,
        nint prompt, uint flags, out Blob output);
    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern bool CryptUnprotectData(ref Blob input, nint description, nint entropy, nint reserved,
        nint prompt, uint flags, out Blob output);
    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern nint LocalFree(nint pointer);
}
