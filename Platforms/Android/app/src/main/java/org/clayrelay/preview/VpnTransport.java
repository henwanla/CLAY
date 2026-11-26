package org.clayrelay.preview;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.system.ErrnoException;
import android.system.Os;
import java.io.File;
import java.io.FileDescriptor;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/** Owns the platform TUN and the private descriptor channel for one engine. */
final class VpnTransport implements AutoCloseable {
    // Match the external TUN configured in CLAYAndroidBridge.
    private static final String IPV6_ADDRESS = "fdfe:dcba:9876::1";
    private static final int IPV6_PREFIX = 126;
    static final String IPV6_TUN_CIDR = IPV6_ADDRESS + "/" + IPV6_PREFIX;
    private final ClayVpnService service;
    private final String dns;
    private ParcelFileDescriptor tun;
    private LocalSocket channel;
    private volatile boolean closed, channelLost;

    VpnTransport(ClayVpnService service, String dns) { this.service = service; this.dns = dns; }

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
