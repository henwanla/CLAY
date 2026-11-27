package org.clayrelay.preview;

import android.app.Activity;
import android.app.Instrumentation;
import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.VpnService;
import android.os.Bundle;
import android.os.SystemClock;
import android.service.notification.StatusBarNotification;
import android.util.Base64;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.Spinner;
import android.widget.TextView;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.lang.reflect.Field;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.cert.CertificateFactory;
import java.util.Arrays;
import java.util.Collections;
import javax.net.ssl.SNIHostName;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManagerFactory;

final class VpnChecks {
    // Default QEMU IPv6 loopback alias, paired with a host fixture bound only to ::1.
    private static final String IPV6_FIXTURE = "fec0::2";
    private static final String DNS4 = "198.51.100.53", DNS6 = "2001:db8::53";

    static String run(Instrumentation test, Activity activity, Bundle fixture) throws Exception {
        int first = port(fixture, "firstPort"), second = port(fixture, "secondPort"), direct = port(fixture, "directPort");
        int ipv6 = port(fixture, "ipv6Port"), tls = port(fixture, "tlsPort");
        int ipv6Origin = port(fixture, "ipv6OriginPort");
        int udp4 = port(fixture, "udp4Port"), udp6 = port(fixture, "udp6Port");
        String proof = fixture.getString("proof", "");
        require(proof.matches("[a-f0-9]{24}"), "synthetic proof");
        String fault = fixture.getString("vpnFault", "");
        String resolver = fixture.getString("resolver", "v4");
        require(resolver.equals("v4") || resolver.equals("v6"), "synthetic resolver family");
        if (fault.equals("cancel")) {
            verifyNumericResolvers();
            verifyCancel(test, activity, first, second);
            return "CLAY_ANDROID_VPN_CONSENT_CANCEL_PASS";
        }
        require(VpnService.prepare(activity) == null, "isolated emulator VPN permission");
        if (fault.equals("forwarding")) {
            verifyForwarding(test, activity, direct, proof, new ForwardingFixture(fixture.getString("forwardingFixture")));
            return "CLAY_ANDROID_VPN_FORWARDING_PASS";
        }
        if (fault.isEmpty()) {
            ServiceInfo service = activity.getPackageManager().getServiceInfo(new ComponentName(activity, ClayVpnTile.class), 0);
            require(service.exported && "android.permission.BIND_QUICK_SETTINGS_TILE".equals(service.permission),
                    "only the system can bind the VPN tile");
            test.runOnMainSync(() -> require(ClayVpnTile.action(ClayVpnService.state()) == ClayVpnTile.Action.OPEN,
                    "idle tile opens app"));
        }
        String step = "ordinary IPv6 reachability";
        try {
            if (fault.isEmpty()) {
                require(fetch(IPV6_FIXTURE, ipv6).endsWith(proof + "-V6"), "ordinary IPv6 reachable before starting tunnel");
                require(fetch(IPV6_FIXTURE, ipv6Origin).endsWith(proof + "-V6-ORIGIN"), "origin-only IPv6 is reachable without the VPN");
            }
            step = "first node in Global mode";
            start(test, activity, first, second, proof, resolver);
            await(test, R.string.vpn_ready, 1, "global", "foreground start");
            require(fetch("198.51.100.42", 18080).endsWith(proof + "-A"), "system TCP uses first node");
            require(fetch(IPV6_FIXTURE, ipv6).endsWith(proof + "-A"), "global IPv6 TCP uses the first node instead of the reachable origin");
            if (!fault.isEmpty()) return verifyFailure(test, activity, fault, direct, ipv6, proof);
            PendingIntent stop = currentNotificationStop(activity);
            ClayVpnService.Snapshot[] oldTile = new ClayVpnService.Snapshot[1];
            test.runOnMainSync(() -> {
                oldTile[0] = ClayVpnService.state();
                require(ClayVpnTile.action(oldTile[0]) == ClayVpnTile.Action.STOP, "connected tile offers stop");
            });
            assertNoIPv6Fallback(ipv6Origin);
            checkDns(DNS4, proof, 73);
            checkDns(DNS6, proof, 73);
            step = "second node in Global mode";
            test.runOnMainSync(() -> edit(activity, MainActivity.ID_NODE_INPUT).setText("changed draft"));
            select(test, activity, 2, 1);
            await(test, R.string.vpn_ready, 2, "global", "confirmed node change");
            require(fetch("198.51.100.42", 18080).endsWith(proof + "-B"), "system TCP uses second node");
            require(fetch(IPV6_FIXTURE, ipv6).endsWith(proof + "-B"), "global IPv6 TCP switches to the IPv6-addressed node");
            checkDns(DNS4, proof, 74);
            checkDns(DNS6, proof, 74);
            step = "Rule mode for IP targets";
            select(test, activity, 2, 0);
            await(test, R.string.vpn_ready, 2, "rule", "confirmed rule mode");
            require(fetch("10.0.2.2", direct).endsWith(proof + "-B"), "rule mode honors the first IPv4 rule");
            require(fetch("198.51.100.42", 18080).endsWith(proof + "-B"), "rule fallback uses node");
            require(fetch(IPV6_FIXTURE, ipv6).endsWith(proof + "-V6"), "rule mode honors the first IPv6 CIDR rule");
            require(fetch("2001:db8::42", ipv6).endsWith(proof + "-B"), "unmatched IPv6 in rule mode uses the selected node");
            step = "system lookup and HTTP rule";
            // These names are answered only at the configured DNS destination.
            String proxyName = fixtureName("proxy", resolver, proof), directName = fixtureName("direct", resolver, proof);
            require(fetchNamed(proxyName, direct).endsWith(proof + "-B"), "HTTP domain rule selects the proxy for a shared IPv4 address");
            require(fetchNamed(directName, direct).endsWith(proof + "-D"), "HTTP domain rule can keep the same IPv4 address direct");
            step = "TLS domain rule";
            SSLContext tlsContext = fixtureTLS(fixture.getString("tlsCert", ""));
            require(fetchTLS(tlsContext, proxyName, tls).endsWith(proof + "-B"), "TLS SNI selects the proxy while retaining the IPv4 destination");
            require(fetchTLS(tlsContext, directName, tls).endsWith(proof + "-TLS-D"), "TLS SNI can keep the same IPv4 destination direct");
            step = "Rule mode with a TCP-only node";
            select(test, activity, 3, 0);
            await(test, R.string.vpn_ready, 3, "rule", "selected a node without UDP");
            require(fetch("10.0.2.2", direct).endsWith(proof + "-A"), "TCP still uses the selected node without UDP");
            require(udpProbe(IPV6_FIXTURE, udp6, "direct-" + proof), "explicit IPv6 DIRECT still forwards UDP");
            require(!udpProbe("10.0.2.2", udp4, "blocked-" + proof), "proxied UDP must not fall through to DIRECT");
            step = "DNS over TCP in Rule mode";
            checkTcpDns(resolver, proof, "rule");
            step = "DNS over TCP in Global mode";
            select(test, activity, 3, 1);
            await(test, R.string.vpn_ready, 3, "global", "selected TCP-only node in Global mode");
            checkTcpDns(resolver, proof, "global");
            step = "Direct mode";
            select(test, activity, 2, 2);
            await(test, R.string.vpn_ready, 2, "direct", "confirmed direct mode");
            require(fetch("10.0.2.2", direct).endsWith(proof + "-D"), "direct mode routes to origin");
            require(udpProbe("10.0.2.2", udp4, "direct-" + proof), "the UDP origin was reachable in intentional Direct mode");
            require(fetch(IPV6_FIXTURE, ipv6Origin).endsWith(proof + "-V6-ORIGIN"),
                    "direct mode can reach the IPv6 origin that Global did not fall back to");
            step = "background Global mode";
            select(test, activity, 2, 1);
            await(test, R.string.vpn_ready, 2, "global", "confirmed global mode before leaving");
            test.runOnMainSync(activity::finish);
            for (int i = 0; i < 40 && !activity.isDestroyed(); i++) SystemClock.sleep(50);
            require(activity.isDestroyed(), "foreground Activity destroyed");
            require(fetch("198.51.100.42", 18080).endsWith(proof + "-B"), "VPN stays up after Activity closes");
            require(fetch(IPV6_FIXTURE, ipv6).endsWith(proof + "-B"), "background VPN continues to route IPv6 through the node");
            require(stop.equals(currentNotificationStop(activity)), "the same session retains its stop action after node and mode changes");
            stop.send();
            await(test, R.string.vpn_stopped, 0, null, "notification stop cleaned session");
            step = "same-process restart and cleanup";
            Intent reopen = new Intent(Intent.ACTION_MAIN).setClassName(test.getTargetContext(), MainActivity.class.getName())
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            Activity returned = test.startActivitySync(reopen);
            try {
                start(test, returned, first, second, proof, resolver);
                await(test, R.string.vpn_ready, 1, "global", "restart within same process");
                require(fetch("198.51.100.42", 18080).endsWith(proof + "-A"), "restarted tunnel forwards traffic");
                require(fetch(IPV6_FIXTURE, ipv6).endsWith(proof + "-A"), "restarted tunnel forwards IPv6");
                test.runOnMainSync(() -> require(!ClayVpnService.stopFromTile(oldTile[0]),
                        "outdated tile action cannot stop a new session"));
                PendingIntent fresh = currentNotificationStop(returned);
                require(!fresh.equals(stop), "each session has a distinct system stop action");
                boolean cancelled = false;
                try { stop.send(); }
                catch (PendingIntent.CanceledException expected) { cancelled = true; }
                require(cancelled, "retired notification action was cancelled");
                require(fetch("198.51.100.42", 18080).endsWith(proof + "-A"), "retired background controls leave the new route intact");
                fresh.send();
                await(test, R.string.vpn_stopped, 0, null, "fresh notification stops the restarted tunnel");
                assertClean(returned);
                start(test, returned, first, second, proof, resolver);
                await(test, R.string.vpn_ready, 1, "global", "restart for quick settings check");
                test.runOnMainSync(() -> {
                    require(ClayVpnService.stopFromTile(ClayVpnService.state()), "current tile can request stop");
                    require(ClayVpnTile.action(ClayVpnService.state()) == ClayVpnTile.Action.WAIT,
                            "tile waits while removing a live tunnel");
                });
                await(test, R.string.vpn_stopped, 0, null, "quick settings stop cleaned session");
                test.runOnMainSync(() -> require(ClayVpnTile.action(ClayVpnService.state()) == ClayVpnTile.Action.OPEN,
                        "tile returns to open after VPN cleanup"));
            } finally { test.runOnMainSync(returned::finish); }
            assertClean(activity);
            require(fetch(IPV6_FIXTURE, ipv6).endsWith(proof + "-V6"), "ordinary IPv6 resumes after stopping VPN");
            return "CLAY_ANDROID_VPN_PASS";
        } catch (java.io.IOException failure) {
            throw new AssertionError(step + ": " + failure.getClass().getSimpleName());
        } finally { test.runOnMainSync(ClayVpnService::stopFromPanel); }
    }

    private static void verifyForwarding(Instrumentation test, Activity activity, int origin, String directProof,
                                         ForwardingFixture fixture) throws Exception {
        require(fetch("10.0.2.2", origin).endsWith(directProof + "-D"), "direct TCP origin reachable before VPN");
        String profile = fixture.profile();
        test.runOnMainSync(() -> {
            edit(activity, MainActivity.ID_NODE_INPUT).setText(profile);
            edit(activity, MainActivity.ID_PAC_RULES).setText("");
            edit(activity, VpnPanel.ID_DNS).setText(DNS4);
            ((CompoundButton) activity.findViewById(MainActivity.ID_PAC_BYPASS)).setChecked(false);
            ((Spinner) activity.findViewById(VpnPanel.ID_MODE)).setSelection(1);
        });
        NodePickerChecks.choose(test, activity, VpnPanel.ID_NODE, 1, fixture.label(1));
        test.runOnMainSync(() -> activity.findViewById(VpnPanel.ID_START).performClick());
        try {
            await(test, R.string.vpn_ready, 1, "global", "forwarding VPN started");
            Process engine = ownedEngine(test);
            require(engine != null && engine.isAlive(), "working VPN engine");
            for (int node = 1; node <= ForwardingFixture.COUNT; node++) {
                if (node != 1) selectForwarding(test, activity, fixture, node);
                require(ownedEngine(test) == engine && engine.isAlive(), "switch retained the running VPN");
                String[] status = new String[1];
                test.runOnMainSync(() -> status[0] = ((TextView) activity.findViewById(VpnPanel.ID_STATE)).getText().toString());
                require(!fixture.hasPrivateData(status[0]), "VPN status omits upstream address and credentials");
                boolean working = node <= ForwardingFixture.WORKING;
                String response;
                try { response = fetchForwarding(origin); }
                catch (java.io.IOException failed) {
                    if (working) throw new AssertionError("system TCP did not reach authenticated upstream " + node + ": " + failed.getClass().getSimpleName());
                    response = "";
                }
                require(working ? response.endsWith(fixture.proof(node)) : response.isEmpty(),
                        working ? "system TCP uses selected upstream " + node : "VPN refuses invalid authentication or pin " + node);
                if (working) {
                    try {
                        requireDnsAnswer("tcp-" + fixture.proof(node) + ".test", 90 + node);
                    } catch (java.net.UnknownHostException failure) {
                        throw new AssertionError("system DNS over TCP through authenticated upstream " + node);
                    }
                }
            }
            selectForwarding(test, activity, fixture, 1);
            require(fetchForwarding(origin).endsWith(fixture.proof(1)), "same VPN recovers after switching to working upstream");
        } finally {
            test.runOnMainSync(ClayVpnService::stopFromPanel);
            await(test, R.string.vpn_stopped, 0, null, "forwarding VPN stopped");
        }
        assertClean(activity);
        require(fetch("10.0.2.2", origin).endsWith(directProof + "-D"), "direct TCP restored after VPN stop");
    }

    private static void selectForwarding(Instrumentation test, Activity activity, ForwardingFixture fixture, int node) {
        NodePickerChecks.choose(test, activity, VpnPanel.ID_NODE, node, fixture.label(node));
        test.runOnMainSync(() -> activity.findViewById(VpnPanel.ID_APPLY).performClick());
        await(test, R.string.vpn_ready, node, "global", "confirmed VPN upstream " + node);
    }

    private static String fetchForwarding(int port) throws java.io.IOException {
        try (Socket socket = new Socket(Proxy.NO_PROXY)) {
            socket.connect(new InetSocketAddress("10.0.2.2", port), 2500);
            socket.setSoTimeout(9000);
            return exchange(socket, "GET /test HTTP/1.0\r\n\r\n");
        }
    }

    private static PendingIntent currentNotificationStop(Activity activity) {
        for (StatusBarNotification entry : activity.getSystemService(NotificationManager.class).getActiveNotifications()) {
            Notification notice = entry.getNotification();
            if (notice.actions == null || notice.actions.length != 1) continue;
            require(notice.visibility == Notification.VISIBILITY_SECRET && notice.publicVersion == null,
                    "notification is secret on the lock screen");
            require(activity.getText(R.string.vpn_title).toString().contentEquals(notice.extras.getCharSequence(Notification.EXTRA_TITLE)),
                    "notification title has no connection details");
            require(activity.getText(R.string.vpn_notification_active).toString().contentEquals(notice.extras.getCharSequence(Notification.EXTRA_TEXT)),
                    "notification describes only confirmed tunnel state without profile information");
            require(activity.getText(R.string.vpn_stop).toString().contentEquals(notice.actions[0].title),
                    "notification has a localized stop action");
            return notice.actions[0].actionIntent;
        }
        throw new AssertionError("notification stop action available");
    }

    private static void verifyCancel(Instrumentation test, Activity activity, int first, int second) throws Exception {
        require(VpnService.prepare(activity) != null, "fixture must have no VPN authorization");
        start(test, activity, first, second, "", "v4");
        // Cancel the actual system-owned consent request using its result contract.
        test.runOnMainSync(() -> activity.finishActivity(VpnPanel.CONSENT));
        for (int attempt = 0; attempt < 100; attempt++) {
            boolean[] denied = new boolean[1];
            test.runOnMainSync(() -> denied[0] = ((TextView) activity.findViewById(VpnPanel.ID_STATE)).getText().toString()
                    .equals(activity.getString(R.string.vpn_denied)));
            if (denied[0]) {
                await(test, R.string.vpn_stopped, 0, null, "cancelled consent did not start service");
                require(VpnService.prepare(activity) != null, "cancelled consent did not authorize VPN");
                assertClean(activity);
                return;
            }
            SystemClock.sleep(50);
        }
        throw new AssertionError("system consent cancellation was not shown");
    }

    private static String verifyFailure(Instrumentation test, Activity activity, String fault, int direct, int ipv6, String proof) throws Exception {
        Process engine = ownedEngine(test);
        require(engine != null && engine.isAlive(), "locate owned engine before fault");
        if (fault.equals("engine")) {
            engine.destroyForcibly();
            await(test, R.string.vpn_ended, 0, null, "service recovered after engine death");
        } else if (fault.equals("revoke")) {
            Bundle signal = new Bundle();
            signal.putString("stream", "\nCLAY_ANDROID_AWAIT_REVOKE\n");
            test.sendStatus(1, signal); // Separate package calls the platform prepare API now.
            await(test, R.string.vpn_revoked, 0, null, "service handled Android revocation");
        } else throw new AssertionError("unknown fault scenario");
        require(!engine.isAlive() && ownedEngine(test) == null, "owned engine exited and service released it");
        require(fetch("10.0.2.2", direct).endsWith(proof + "-D"), "ordinary networking resumed after fault");
        require(fetch(IPV6_FIXTURE, ipv6).endsWith(proof + "-V6"), "ordinary IPv6 resumed after fault");
        assertClean(activity);
        return fault.equals("engine") ? "CLAY_ANDROID_VPN_ENGINE_EXIT_PASS" : "CLAY_ANDROID_VPN_REVOKE_PASS";
    }

    /** Read only CLAY's own handle. The APK exposes no test endpoint or process controls for this. */
    private static Process ownedEngine(Instrumentation test) throws ReflectiveOperationException {
        Field owner = ClayVpnService.class.getDeclaredField("owner");
        Field engine = ClayVpnService.class.getDeclaredField("engine");
        Field child = RelaySession.class.getDeclaredField("child");
        for (Field field : new Field[] {owner, engine, child}) field.setAccessible(true);
        Process[] result = new Process[1];
        test.runOnMainSync(() -> {
            try {
                Object service = owner.get(null);
                if (service != null) result[0] = (Process) child.get(engine.get(service));
            } catch (IllegalAccessException error) { throw new AssertionError("test engine handle"); }
        });
        return result[0];
    }

    private static void assertClean(Activity activity) {
        File[] privateFiles = activity.getNoBackupFilesDir().listFiles((base, name) -> name.matches("v-[a-f0-9]{32}"));
        require(privateFiles != null && privateFiles.length == 0, "runtime directory removed");
        require(activity.getSystemService(NotificationManager.class).getActiveNotifications().length == 0, "foreground notification removed");
    }

    private static void verifyNumericResolvers() {
        require(VpnTransport.parseDns(DNS4) instanceof java.net.Inet4Address, "valid IPv4 resolver");
        require(VpnTransport.parseDns(DNS6) instanceof java.net.Inet6Address, "valid IPv6 resolver");
        require(VpnTransport.parseDns("fd00::53") != null, "IPv6 private resolver remains available");
        for (String invalid : new String[] {"example.test", "198.51.100", "198.051.100.53", "0.0.0.1", "127.0.0.1",
                "198.18.0.1", "224.0.0.53", "[2001:db8::53]", "fe80::1%wlan0", "fe80::53", "ff02::53", "::", "::1",
                "::192.0.2.53", "::ffff:192.0.2.53", "fdfe:dcba:9876::3", "2001::db8::53", "2001:db8::53/64",
                "2001:db8::192.051.0.1"}) {
            require(VpnTransport.parseDns(invalid) == null, "reject invalid DNS fixture " + invalid);
        }
    }

    private static String fixtureName(String action, String resolver, String proof) {
        return action + "-" + resolver + "-" + proof + ".test";
    }

    private static void checkTcpDns(String resolver, String proof, String mode) throws Exception {
        requireDnsAnswer(fixtureName("tcp-" + mode, resolver, proof), 83);
    }

    private static void requireDnsAnswer(String name, int lastOctet) throws java.net.UnknownHostException {
        InetAddress[] answers = InetAddress.getAllByName(name);
        require(answers.length == 1 && answers[0].getHostAddress().equals("203.0.113." + lastOctet),
                "Android retries the configured DNS resolver over TCP through the selected node");
    }

    private static void start(Instrumentation test, Activity activity, int first, int second, String proof, String resolver) {
        test.runOnMainSync(() -> {
            String vless = ", type: vless, uuid: 56dc6c3e-8793-4d37-a363-f9f19db29c6d, network: tcp, udp: ";
            edit(activity, MainActivity.ID_NODE_INPUT).setText("proxies:\n" +
                    "  - {name: Fixture-A, server: 10.0.2.2, port: " + first + vless + "true}\n" +
                    "  - {name: Fixture-B, server: '" + IPV6_FIXTURE + "', port: " + second + vless + "true}\n" +
                    "  - {name: Fixture-C, server: 10.0.2.2, port: " + first + vless + "false}");
            edit(activity, MainActivity.ID_PAC_RULES).setText((proof.isEmpty() ? "" :
                    "DOMAIN," + fixtureName("proxy", resolver, proof) + ",PROXY\n" +
                    "DOMAIN-SUFFIX," + fixtureName("direct", resolver, proof) + ",DIRECT\n") +
                    "IP-CIDR,10.0.2.2/32,PROXY\nIP-CIDR,10.0.2.2/32,DIRECT\n" +
                    "IP-CIDR6,fec0::/126,DIRECT,no-resolve\nIP-CIDR6,fec0::2/128,PROXY");
            edit(activity, VpnPanel.ID_DNS).setText(resolver.equals("v6") ? DNS6 : DNS4);
            ((CompoundButton) activity.findViewById(MainActivity.ID_PAC_BYPASS)).setChecked(false);
            ((CompoundButton) activity.findViewById(MainActivity.ID_PAC_DIRECT)).setChecked(false);
            ((Spinner) activity.findViewById(VpnPanel.ID_MODE)).setSelection(1);
            activity.findViewById(VpnPanel.ID_START).performClick();
        });
    }

    private static int port(Bundle args, String key) {
        int port = Integer.parseInt(args.getString(key, "0"));
        require(port >= 1 && port <= 65535, "fixture port");
        return port;
    }

    private static void assertNoIPv6Fallback(int port) throws Exception {
        String response;
        try { response = fetch(IPV6_FIXTURE, port); }
        catch (java.io.IOException expected) { return; }
        require(response.isEmpty(), "global IPv6 must not fall back to a reachable origin when the node rejects it");
    }

    private static void checkDns(String target, String proof, int lastOctet) throws Exception {
        byte[] label = ("clay-" + proof).getBytes(StandardCharsets.US_ASCII);
        byte[] query = ByteBuffer.allocate(12 + 1 + label.length + 6 + 4)
                .putShort((short) 0x5116).putShort((short) 0x0100).putShort((short) 1).put(new byte[6])
                .put((byte) label.length).put(label).put(new byte[] {4, 't', 'e', 's', 't', 0}).putInt(0x00010001).array();
        byte[] answer = ByteBuffer.allocate(query.length + 16).put(query).putShort((short) 0xc00c)
                .putShort((short) 1).putShort((short) 1).putInt(0).putShort((short) 4)
                .put(new byte[] {(byte) 203, 0, 113, (byte) lastOctet}).array();
        answer[2] = (byte) 0x81; answer[3] = (byte) 0x80; answer[7] = 1;
        DatagramPacket received = new DatagramPacket(new byte[512], 512);
        try (DatagramSocket socket = new DatagramSocket()) {
            socket.connect(InetAddress.getByName(target), 53);
            socket.setSoTimeout(3000);
            socket.send(new DatagramPacket(query, query.length));
            socket.receive(received);
        } catch (java.io.IOException failure) {
            throw new AssertionError("UDP DNS did not return through the selected VLESS node: " + failure.getClass().getSimpleName());
        }
        require(Arrays.equals(answer, Arrays.copyOf(received.getData(), received.getLength())),
                "UDP DNS answer comes from the selected synthetic node");
    }

    private static boolean udpProbe(String target, int port, String message) throws Exception {
        byte[] request = message.getBytes(StandardCharsets.US_ASCII);
        DatagramPacket reply = new DatagramPacket(new byte[64], 64);
        try (DatagramSocket socket = new DatagramSocket()) {
            socket.connect(InetAddress.getByName(target), port);
            socket.setSoTimeout(2000);
            socket.send(new DatagramPacket(request, request.length));
            try { socket.receive(reply); }
            catch (java.net.SocketTimeoutException | java.net.PortUnreachableException expected) { return false; }
        }
        require(Arrays.equals(request, Arrays.copyOf(reply.getData(), reply.getLength())), "UDP fixture returns the synthetic proof");
        return true;
    }

    private static String fetch(String host, int port) throws Exception {
        return fetch(new InetSocketAddress(host, port), "GET /clay-vpn HTTP/1.0\r\n\r\n");
    }

    private static String fetchNamed(String host, int port) throws Exception {
        return fetch(namedEndpoint(host, port), "GET /clay-vpn HTTP/1.1\r\nHost: " + host + ":" + port + "\r\nConnection: close\r\n\r\n");
    }

    private static InetSocketAddress namedEndpoint(String host, int port) {
        InetSocketAddress endpoint = new InetSocketAddress(host, port); // Android's resolver, via the active VPN.
        require(!endpoint.isUnresolved() && endpoint.getAddress().getHostAddress().equals("10.0.2.2"),
                "Android DNS returns the shared synthetic IPv4 address");
        return endpoint;
    }

    private static SSLContext fixtureTLS(String encodedCertificate) throws Exception {
        KeyStore store = KeyStore.getInstance(KeyStore.getDefaultType());
        store.load(null, null);
        try (InputStream pem = new ByteArrayInputStream(Base64.decode(encodedCertificate, Base64.DEFAULT))) {
            store.setCertificateEntry("fixture", CertificateFactory.getInstance("X.509").generateCertificate(pem));
        }
        TrustManagerFactory trust = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        trust.init(store);
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(null, trust.getTrustManagers(), null);
        return context;
    }

    private static String fetchTLS(SSLContext context, String host, int port) throws Exception {
        try (Socket plain = new Socket(Proxy.NO_PROXY)) {
            plain.connect(namedEndpoint(host, port), 2500);
            try (SSLSocket tls = (SSLSocket) context.getSocketFactory().createSocket(plain, host, port, true)) {
                tls.setSoTimeout(2500);
                SSLParameters options = tls.getSSLParameters();
                options.setEndpointIdentificationAlgorithm("HTTPS");
                options.setServerNames(Collections.singletonList(new SNIHostName(host)));
                tls.setSSLParameters(options);
                tls.startHandshake();
                // No HTTP Host header here: only the TLS ClientHello carries the name.
                return exchange(tls, "GET /clay-vpn HTTP/1.0\r\n\r\n");
            }
        }
    }

    private static String fetch(InetSocketAddress endpoint, String request) throws Exception {
        try (Socket socket = new Socket(Proxy.NO_PROXY)) {
            socket.connect(endpoint, 2500);
            socket.setSoTimeout(2500);
            return exchange(socket, request);
        }
    }

    private static String exchange(Socket socket, String request) throws java.io.IOException {
        socket.getOutputStream().write(request.getBytes(StandardCharsets.US_ASCII));
        try (InputStream in = socket.getInputStream(); ByteArrayOutputStream reply = new ByteArrayOutputStream()) {
            for (int ch; reply.size() < 2000 && (ch = in.read()) != -1;) reply.write(ch);
            return new String(reply.toByteArray(), StandardCharsets.US_ASCII);
        }
    }

    private static void select(Instrumentation test, Activity activity, int node, int mode) {
        NodePickerChecks.choose(test, activity, VpnPanel.ID_NODE, node, "Fixture-" + (char) ('A' + node - 1));
        test.runOnMainSync(() -> {
            ((Spinner) activity.findViewById(VpnPanel.ID_MODE)).setSelection(mode);
            activity.findViewById(VpnPanel.ID_APPLY).performClick();
        });
    }
    private static void await(Instrumentation test, int message, int node, String mode, String step) {
        for (int i = 0; i < 180; i++) {
            ClayVpnService.Snapshot[] next = new ClayVpnService.Snapshot[1];
            test.runOnMainSync(() -> next[0] = ClayVpnService.state());
            if (next[0].message == message && next[0].node == node && java.util.Objects.equals(next[0].mode, mode)) {
                SystemClock.sleep(330); // Wait for the screen to reflect the confirmed service state.
                return;
            }
            if (!next[0].busy && next[0].node == 0 && next[0].message != message) break;
            SystemClock.sleep(75);
        }
        throw new AssertionError(step);
    }
    private static EditText edit(Activity activity, int id) { return activity.findViewById(id); }
    private static void require(boolean condition, String step) { if (!condition) throw new AssertionError(step); }
}
