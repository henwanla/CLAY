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
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.Spinner;
import android.widget.TextView;
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
import java.util.Arrays;

final class VpnChecks {
    // Default QEMU IPv6 loopback alias, paired with a host fixture bound only to ::1.
    private static final String IPV6_FIXTURE = "fec0::2";

    static String run(Instrumentation test, Activity activity, Bundle fixture) throws Exception {
        int first = port(fixture, "firstPort"), second = port(fixture, "secondPort"), direct = port(fixture, "directPort");
        int ipv6 = port(fixture, "ipv6Port");
        String proof = fixture.getString("proof", "");
        require(proof.matches("[a-f0-9]{24}"), "synthetic proof");
        String fault = fixture.getString("vpnFault", "");
        if (fault.equals("cancel")) {
            verifyCancel(test, activity, first, second);
            return "CLAY_ANDROID_VPN_CONSENT_CANCEL_PASS";
        }
        require(VpnService.prepare(activity) == null, "isolated emulator VPN permission");
        if (fault.isEmpty()) {
            ServiceInfo service = activity.getPackageManager().getServiceInfo(new ComponentName(activity, ClayVpnTile.class), 0);
            require(service.exported && "android.permission.BIND_QUICK_SETTINGS_TILE".equals(service.permission),
                    "only the system can bind the VPN tile");
            test.runOnMainSync(() -> require(ClayVpnTile.action(ClayVpnService.state()) == ClayVpnTile.Action.OPEN,
                    "idle tile opens app"));
        }
        try {
            if (fault.isEmpty()) require(fetch(IPV6_FIXTURE, ipv6).endsWith(proof + "-V6"),
                    "ordinary IPv6 reachable before starting tunnel");
            start(test, activity, first, second);
            await(test, R.string.vpn_ready, 1, "global", "foreground start");
            require(fetch("198.51.100.42", 18080).endsWith(proof + "-A"), "system TCP uses first node");
            if (!fault.isEmpty()) return verifyFailure(test, activity, fault, direct, proof);
            ClayVpnService.Snapshot[] oldTile = new ClayVpnService.Snapshot[1];
            test.runOnMainSync(() -> {
                oldTile[0] = ClayVpnService.state();
                require(ClayVpnTile.action(oldTile[0]) == ClayVpnTile.Action.STOP, "connected tile offers stop");
            });
            checkIPv6Blocked(ipv6);
            checkDns(proof, 73);
            select(test, activity, 2, 1);
            await(test, R.string.vpn_ready, 2, "global", "confirmed node change");
            require(fetch("198.51.100.42", 18080).endsWith(proof + "-B"), "system TCP uses second node");
            checkDns(proof, 74);
            select(test, activity, 2, 0);
            await(test, R.string.vpn_ready, 2, "rule", "confirmed rule mode");
            require(fetch("10.0.2.2", direct).endsWith(proof + "-D"), "rule mode honors IP bypass");
            require(fetch("198.51.100.42", 18080).endsWith(proof + "-B"), "rule fallback uses node");
            select(test, activity, 2, 2);
            await(test, R.string.vpn_ready, 2, "direct", "confirmed direct mode");
            require(fetch("10.0.2.2", direct).endsWith(proof + "-D"), "direct mode routes to origin");
            checkIPv6Blocked(ipv6);
            select(test, activity, 2, 1);
            await(test, R.string.vpn_ready, 2, "global", "confirmed global mode before leaving");
            test.runOnMainSync(activity::finish);
            for (int i = 0; i < 40 && !activity.isDestroyed(); i++) SystemClock.sleep(50);
            require(activity.isDestroyed(), "foreground Activity destroyed");
            require(fetch("198.51.100.42", 18080).endsWith(proof + "-B"), "VPN stays up after Activity closes");
            PendingIntent stop = null;
            for (StatusBarNotification notice : activity.getSystemService(NotificationManager.class).getActiveNotifications()) {
                Notification.Action[] actions = notice.getNotification().actions;
                if (actions != null && actions.length == 1) stop = actions[0].actionIntent;
            }
            require(stop != null, "notification stop action available");
            stop.send();
            await(test, R.string.vpn_stopped, 0, null, "notification stop cleaned session");
            Intent reopen = new Intent(Intent.ACTION_MAIN).setClassName(test.getTargetContext(), MainActivity.class.getName())
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            Activity returned = test.startActivitySync(reopen);
            try {
                start(test, returned, first, second);
                await(test, R.string.vpn_ready, 1, "global", "restart within same process");
                require(fetch("198.51.100.42", 18080).endsWith(proof + "-A"), "restarted tunnel forwards traffic");
                test.runOnMainSync(() -> require(!ClayVpnService.stopFromTile(oldTile[0]),
                        "outdated tile action cannot stop a new session"));
                require(fetch("198.51.100.42", 18080).endsWith(proof + "-A"), "stale action leaves live route intact");
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
        } finally { test.runOnMainSync(ClayVpnService::stopFromPanel); }
    }

    private static void verifyCancel(Instrumentation test, Activity activity, int first, int second) throws Exception {
        require(VpnService.prepare(activity) != null, "fixture must have no VPN authorization");
        start(test, activity, first, second);
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

    private static String verifyFailure(Instrumentation test, Activity activity, String fault, int direct, String proof) throws Exception {
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

    private static void start(Instrumentation test, Activity activity, int first, int second) {
        test.runOnMainSync(() -> {
            String prefix = "vless://56dc6c3e-8793-4d37-a363-f9f19db29c6d@10.0.2.2:";
            String options = "?encryption=none&security=none&type=tcp#Fixture-";
            edit(activity, MainActivity.ID_NODE_INPUT).setText(prefix + first + options + "A\n" + prefix + second + options + "B");
            edit(activity, MainActivity.ID_PAC_RULES).setText("IP-CIDR,10.0.2.2/32,DIRECT");
            edit(activity, VpnPanel.ID_DNS).setText("198.51.100.53");
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

    private static void checkIPv6Blocked(int port) throws Exception {
        try (Socket socket = new Socket(Proxy.NO_PROXY)) {
            try { socket.connect(new InetSocketAddress(IPV6_FIXTURE, port), 1000); }
            catch (java.io.IOException expected) { return; }
            throw new AssertionError("IPv6 TCP connected outside the IPv4 VPN");
        }
    }

    private static void checkDns(String proof, int lastOctet) throws Exception {
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
            socket.connect(InetAddress.getByAddress(new byte[] {(byte) 198, 51, 100, 53}), 53);
            socket.setSoTimeout(3000);
            socket.send(new DatagramPacket(query, query.length));
            socket.receive(received);
        } catch (java.io.IOException failure) {
            throw new AssertionError("UDP DNS did not return through the selected VLESS node: " + failure.getClass().getSimpleName());
        }
        require(Arrays.equals(answer, Arrays.copyOf(received.getData(), received.getLength())),
                "UDP DNS answer comes from the selected synthetic node");
    }

    private static String fetch(String host, int port) throws Exception {
        try (Socket socket = new Socket(Proxy.NO_PROXY)) {
            socket.connect(new InetSocketAddress(host, port), 2500);
            socket.setSoTimeout(2500);
            socket.getOutputStream().write("GET /clay-vpn HTTP/1.0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
            try (InputStream in = socket.getInputStream(); ByteArrayOutputStream reply = new ByteArrayOutputStream()) {
                for (int ch; reply.size() < 2000 && (ch = in.read()) != -1;) reply.write(ch);
                return new String(reply.toByteArray(), StandardCharsets.US_ASCII);
            }
        }
    }

    private static void select(Instrumentation test, Activity activity, int node, int mode) {
        test.runOnMainSync(() -> {
            edit(activity, VpnPanel.ID_NODE).setText(Integer.toString(node));
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
