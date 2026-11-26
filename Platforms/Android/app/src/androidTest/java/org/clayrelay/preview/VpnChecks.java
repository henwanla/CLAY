package org.clayrelay.preview;

import android.app.Activity;
import android.app.Instrumentation;
import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.net.VpnService;
import android.os.Bundle;
import android.os.SystemClock;
import android.service.notification.StatusBarNotification;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.Spinner;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

final class VpnChecks {
    static void run(Instrumentation test, Activity activity, Bundle fixture) throws Exception {
        int first = port(fixture, "firstPort"), second = port(fixture, "secondPort"), direct = port(fixture, "directPort");
        String proof = fixture.getString("proof", "");
        require(proof.matches("[a-f0-9]{24}"), "synthetic proof");
        require(VpnService.prepare(activity) == null, "isolated emulator VPN permission");
        try {
            start(test, activity, first, second);
            await(test, R.string.vpn_ready, 1, "global", "foreground start");
            require(fetch("198.51.100.42", 18080).endsWith(proof + "-A"), "system TCP uses first node");
            select(test, activity, 2, 1);
            await(test, R.string.vpn_ready, 2, "global", "confirmed node change");
            require(fetch("198.51.100.42", 18080).endsWith(proof + "-B"), "system TCP uses second node");
            select(test, activity, 2, 0);
            await(test, R.string.vpn_ready, 2, "rule", "confirmed rule mode");
            require(fetch("10.0.2.2", direct).endsWith(proof + "-D"), "rule mode honors IP bypass");
            require(fetch("198.51.100.42", 18080).endsWith(proof + "-B"), "rule fallback uses node");
            select(test, activity, 2, 2);
            await(test, R.string.vpn_ready, 2, "direct", "confirmed direct mode");
            require(fetch("10.0.2.2", direct).endsWith(proof + "-D"), "direct mode routes to origin");
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
                test.runOnMainSync(() -> returned.findViewById(VpnPanel.ID_STOP).performClick());
                await(test, R.string.vpn_stopped, 0, null, "in-app stop cleaned session");
            } finally { test.runOnMainSync(returned::finish); }
            File[] privateFiles = activity.getNoBackupFilesDir().listFiles((base, name) -> name.matches("v-[a-f0-9]{32}"));
            require(privateFiles != null && privateFiles.length == 0, "runtime directory removed");
        } finally { test.runOnMainSync(ClayVpnService::stopFromPanel); }
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
