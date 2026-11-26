using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Clay.Windows;

internal sealed record WinInetPacSettings(uint Flags, string Url);

internal interface IWindowsPacSettings
{
    WinInetPacSettings Read();
    void Write(WinInetPacSettings value);
}

internal sealed class WinInetPac : IWindowsPacSettings
{
    private const uint PerConnection = 75, Flags = 1, AutoConfigUrl = 4, FlagsUi = 10;
    internal const uint Direct = 1, AutoConfig = 4;

    public WinInetPacSettings Read()
    {
        EnsurePerUser();
        try { return ReadFlags(FlagsUi); }
        catch (Win32Exception error) when (error.NativeErrorCode is 87 or 12009) { return ReadFlags(Flags); }
    }

    private static WinInetPacSettings ReadFlags(uint flagId)
    {
        Option[] options = [new() { Id = flagId }, new() { Id = AutoConfigUrl }];
        try
        {
            UseOptions(options, write: false);
            return new(options[0].Data.Number, Marshal.PtrToStringUni(options[1].Data.Pointer) ?? "");
        }
        finally { if (options[1].Data.Pointer != 0) GlobalFree(options[1].Data.Pointer); }
    }

    public void Write(WinInetPacSettings value)
    {
        EnsurePerUser();
        // Leave the saved manual proxy address and bypass list alone. The flags
        // alone decide which routing mechanisms are active for this connection.
        var url = Marshal.StringToHGlobalUni(value.Url);
        try
        {
            UseOptions([new() { Id = AutoConfigUrl, Data = new() { Pointer = url } },
                        new() { Id = Flags, Data = new() { Number = value.Flags } }], write: true);
        }
        finally { Marshal.ZeroFreeGlobalAllocUnicode(url); }
        SetNotification(0, 39, 0, 0); // INTERNET_OPTION_SETTINGS_CHANGED
        var refreshed = SetNotification(0, 37, 0, 0); // INTERNET_OPTION_REFRESH
        var notified = SetNotification(0, 95, 0, 0); // INTERNET_OPTION_PROXY_SETTINGS_CHANGED
        if (!refreshed && !notified) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    private static void EnsurePerUser()
    {
        const string policy = @"HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings";
        if (Registry.GetValue(policy, "ProxySettingsPerUser", null) is 0) throw new UnauthorizedAccessException();
    }

    private static void UseOptions(Option[] options, bool write)
    {
        var pin = GCHandle.Alloc(options, GCHandleType.Pinned);
        try
        {
            uint size = (uint)Marshal.SizeOf<OptionList>();
            // A null connection name represents the default LAN connection.
            var list = new OptionList { Size = size, Count = (uint)options.Length, Options = pin.AddrOfPinnedObject() };
            bool updated = write ? InternetSetOption(0, PerConnection, ref list, size)
                                 : InternetQueryOption(0, PerConnection, ref list, ref size);
            if (!updated) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally { pin.Free(); }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct OptionList { internal uint Size; internal nint Connection; internal uint Count, Error; internal nint Options; }
    [StructLayout(LayoutKind.Sequential)]
    private struct Option { internal uint Id; internal Value Data; }
    [StructLayout(LayoutKind.Explicit)]
    private struct Value
    {
        [FieldOffset(0)] internal nint Pointer;
        [FieldOffset(0)] internal uint Number;
        [FieldOffset(0)] private System.Runtime.InteropServices.ComTypes.FILETIME timestamp;
    }

    [DllImport("wininet.dll", EntryPoint = "InternetQueryOptionW", SetLastError = true, ExactSpelling = true)]
    private static extern bool InternetQueryOption(nint handle, uint kind, ref OptionList list, ref uint size);
    [DllImport("wininet.dll", EntryPoint = "InternetSetOptionW", SetLastError = true, ExactSpelling = true)]
    private static extern bool InternetSetOption(nint handle, uint kind, ref OptionList list, uint size);
    [DllImport("wininet.dll", EntryPoint = "InternetSetOptionW", SetLastError = true, ExactSpelling = true)]
    private static extern bool SetNotification(nint handle, uint kind, nint buffer, uint size);
    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern nint GlobalFree(nint pointer);
}
