package org.clayrelay.preview;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import java.io.File;
import java.io.FileDescriptor;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;

/** Owns the platform TUN and the private descriptor channel for one engine. */
final class VpnTransport implements AutoCloseable {
    // Match the external TUN configured in CLAYAndroidBridge.
    private static final String IPV6_ADDRESS = "fdfe:dcba:9876::1";
    private static final int IPV6_PREFIX = 126;
    static final String IPV6_TUN_CIDR = IPV6_ADDRESS + "/" + IPV6_PREFIX;
    private static final byte[] IPV6_TUN_BYTES = Os.inet_pton(OsConstants.AF_INET6, IPV6_ADDRESS).getAddress();
    private final ClayVpnService service;
    private final InetAddress dns;
    private ParcelFileDescriptor tun;
    private LocalSocket channel;
    private volatile boolean closed, channelLost;

    VpnTransport(ClayVpnService service, InetAddress dns) { this.service = service; this.dns = dns; }

    static InetAddress parseDns(String literal) {
        // Numeric-only parsing: no DNS requests, interface zones, brackets, or host:port.
        if (literal.length() > 45 || !literal.matches("[0-9a-fA-F:.]+")) return null;
        int lastColon = literal.lastIndexOf(':');
        // Android's native parser allows padded IPv4 octets. Preserve CLAY's
        // existing canonical dotted-decimal requirement, including IPv6 tails.
        if (literal.indexOf('.') >= 0 && !literal.substring(lastColon + 1)
                .matches("(0|[1-9][0-9]{0,2})(\\.(0|[1-9][0-9]{0,2})){3}")) return null;
        if (lastColon >= 0) {
            InetAddress address = Os.inet_pton(OsConstants.AF_INET6, literal);
            if (!(address instanceof Inet6Address) || ((Inet6Address) address).isIPv4CompatibleAddress()
                    || address.isLinkLocalAddress() || address.isMulticastAddress()) return null;
            byte[] bytes = address.getAddress();
            if (isMappedIPv4(bytes) || inTunSubnet(bytes)) return null;
            return address;
        }
        InetAddress address = Os.inet_pton(OsConstants.AF_INET, literal);
        if (!(address instanceof Inet4Address)) return null;
        byte[] bytes = address.getAddress();
        int first = bytes[0] & 255;
        return first == 0 || first == 127 || first >= 224 || (first == 198 && bytes[1] == 18 && bytes[2] == 0)
                ? null : address;
    }

    private static boolean inTunSubnet(byte[] address) {
        for (int i = 0; i < address.length; i++) {
            int bits = Math.min(8, Math.max(0, IPV6_PREFIX - 8 * i));
            int mask = 0xff << (8 - bits) & 0xff;
            if (((address[i] ^ IPV6_TUN_BYTES[i]) & mask) != 0) return false;
        }
        return true;
    }

    private static boolean isMappedIPv4(byte[] address) {
        for (int i = 0; i < 10; i++) if (address[i] != 0) return false;
        return address[10] == -1 && address[11] == -1;
    }

    synchronized void establish() throws IOException {
        if (closed || tun != null) throw new IOException();
        // Claim both families; allowing a family without its route would bypass the VPN.
        tun = service.new Builder().setSession(service.getString(R.string.vpn_title)).setMtu(1500)
                .addAddress("198.18.0.1", 30).addRoute("0.0.0.0", 0)
                .addAddress(IPV6_ADDRESS, IPV6_PREFIX).addRoute("::", 0).addDnsServer(dns).establish();
        if (tun == null) throw new IOException();
    }

    void attach(File directory) throws IOException {
        LocalSocketAddress address = new LocalSocketAddress(new File(directory, "t").getPath(),
                LocalSocketAddress.Namespace.FILESYSTEM);
        long limit = SystemClock.elapsedRealtime() + 2500;
        while (!closed && SystemClock.elapsedRealtime() < limit) {
            LocalSocket socket = new LocalSocket();
            try { socket.connect(address); }
            catch (IOException notReady) { socket.close(); SystemClock.sleep(40); continue; }
            try {
                synchronized (this) {
                    if (closed || tun == null || socket.getPeerCredentials().getUid() != android.os.Process.myUid()) {
                        throw new IOException();
                    }
                    socket.setFileDescriptorsForSend(new FileDescriptor[] { tun.getFileDescriptor() });
                    socket.getOutputStream().write(42);
                    socket.setFileDescriptorsForSend(null);
                    channel = socket;
                }
            } catch (IOException failure) { socket.close(); throw failure; }
            new Thread(() -> protectSockets(socket), "clay-vpn-protect").start();
            return;
        }
        throw new IOException();
    }

    boolean healthy() { return !closed && !channelLost; }

    private void protectSockets(LocalSocket socket) {
        try (LocalSocket owned = socket) {
            InputStream input = owned.getInputStream();
            OutputStream output = owned.getOutputStream();
            for (int message; !closed && (message = input.read()) != -1;) {
                FileDescriptor[] received = owned.getAncillaryFileDescriptors();
                boolean valid = message == 0x50 && received != null && received.length == 1;
                boolean accepted = false;
                try {
                    if (valid && !closed) {
                        try (ParcelFileDescriptor duplicate = ParcelFileDescriptor.dup(received[0])) {
                            accepted = service.protect(duplicate.getFd());
                        }
                    }
                } finally {
                    if (received != null) for (FileDescriptor fd : received) {
                        try { Os.close(fd); } catch (ErrnoException error) { accepted = false; }
                    }
                }
                if (!valid) throw new IOException();
                output.write(accepted && !closed ? 1 : 0);
            }
        } catch (IOException | RuntimeException ignored) {
            // Health monitoring tears down the tunnel; never log upstream addresses or descriptors.
        } finally { channelLost = true; }
    }

    @Override public synchronized void close() {
        closed = true;
        if (channel != null) {
            try { channel.shutdownInput(); } catch (IOException ignored) { }
            try { channel.close(); } catch (IOException ignored) { }
            channel = null;
        }
        if (tun != null) {
            try { tun.close(); } catch (IOException ignored) { }
            tun = null;
        }
    }
}
