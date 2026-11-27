package org.clayrelay.preview;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.os.SystemClock;
import android.view.View;
import android.widget.EditText;
import android.widget.CompoundButton;
import android.widget.Spinner;
import android.widget.TextView;
import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

final class RelayChecks {
    static void run(Instrumentation test, Activity activity, ShadowsocksFixture fixture, String forwarding) throws Exception {
        InetAddress local = InetAddress.getByAddress(new byte[] {127, 0, 0, 1});
        String marker = UUID.randomUUID().toString();
        AtomicInteger originConnections = new AtomicInteger();
        try (ServerSocket origin = new ServerSocket(0, 2, local)) {
            Thread server = new Thread(() -> {
                while (!origin.isClosed()) {
                    try (Socket peer = origin.accept()) {
                        originConnections.incrementAndGet();
                        peer.setSoTimeout(3000);
                        InputStream in = peer.getInputStream();
                        byte[] suffix = {13, 10, 13, 10};
                        ByteArrayOutputStream request = new ByteArrayOutputStream();
                        for (int matched = 0, count = 0, value;
                             matched < 4 && count < 8192 && (value = in.read()) >= 0; count++) {
                            matched = value == suffix[matched] ? matched + 1 : 0;
                            request.write(value);
                        }
                        if (new String(request.toByteArray(), StandardCharsets.US_ASCII).toLowerCase(Locale.ROOT)
                                .contains("proxy-authorization:")) continue;
                        byte[] bytes = ("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: " +
                                marker.length() + "\r\n\r\n" + marker).getBytes(StandardCharsets.US_ASCII);
                        peer.getOutputStream().write(bytes);
                    } catch (java.io.IOException ended) { if (origin.isClosed()) return; }
                }
            });
            server.setDaemon(true); server.start();
            await(test, activity, SubscriptionPanel.ID_USE, SubscriptionPanel.ID_SOURCE, "saved subscription listed");
            test.runOnMainSync(() -> activity.findViewById(SubscriptionPanel.ID_USE).performClick());
            String selected = await(test, activity, SubscriptionPanel.ID_MANUAL, SubscriptionPanel.ID_SOURCE, "saved subscription selected");
            require(!selected.equals(activity.getString(R.string.subscription_using_manual)), "UI reports subscription source");
            test.runOnMainSync(() -> {
                ((EditText) activity.findViewById(MainActivity.ID_NODE_INPUT)).setText("manual input must not be used yet");
                ((EditText) activity.findViewById(MainActivity.ID_PAC_RULES)).setText("");
                ((CompoundButton) activity.findViewById(MainActivity.ID_PAC_DIRECT)).setChecked(false);
                ((CompoundButton) activity.findViewById(MainActivity.ID_PAC_BYPASS)).setChecked(false);
                ((Spinner) activity.findViewById(RelayPanel.ID_MODE)).setSelection(2);
            });
            NodePickerChecks.choose(test, activity, RelayPanel.ID_NODE, 1, "Fixture-A");
            test.runOnMainSync(() -> activity.findViewById(RelayPanel.ID_START).performClick());
            String status = await(test, activity, RelayPanel.ID_APPLY, RelayPanel.ID_STATUS, "relay ready");
            Matcher address = Pattern.compile("127\\.0\\.0\\.1:([0-9]{1,5})").matcher(status);
            require(address.find(), "reported loopback address");
            int port = Integer.parseInt(address.group(1));
            test.runOnMainSync(() -> activity.findViewById(RelayPanel.ID_SHOW).performClick());
            String text = await(test, activity, RelayPanel.ID_APPLY, RelayPanel.ID_CREDENTIALS, "credentials shown on demand");
            Matcher authentication = Pattern.compile("[a-f0-9]{64}").matcher(text);
            require(authentication.find() && !status.contains(authentication.group()), "proxy auth redacted from status");
            String password = authentication.group();
            require(fetch(local, port, origin.getLocalPort(), null, "missing authentication").startsWith("HTTP/1.1 407"),
                    "proxy requires authentication");
            String denied = fetch(local, port, origin.getLocalPort(), "invalid-test-credential", "wrong authentication");
            require((denied.startsWith("HTTP/1.1 403") || denied.startsWith("HTTP/1.1 407")) && !denied.contains(marker),
                    "proxy rejects wrong credentials");
            require(fetch(local, port, origin.getLocalPort(), password, "direct forwarding").contains(marker),
                    "authenticated HTTP traffic forwarded");
            // Change the draft source to an invalid manual input while the cached session runs.
            test.runOnMainSync(() -> activity.findViewById(SubscriptionPanel.ID_MANUAL).performClick());
            select(test, activity, 2, 1);
            status = await(test, activity, RelayPanel.ID_APPLY, RelayPanel.ID_STATUS, "node and mode read back");
            require(status.contains("127.0.0.1:" + port) && status.contains("2 · " + activity.getString(R.string.relay_global)),
                    "node and mode changed without replacing proxy");
            require(!fetch(local, port, origin.getLocalPort(), password, "unavailable node").contains(marker),
                    "failed node did not fall back to direct");
            select(test, activity, 1, 1);
            status = await(test, activity, RelayPanel.ID_APPLY, RelayPanel.ID_STATUS, "global Shadowsocks selection");
            require(status.contains("127.0.0.1:" + port) && status.contains("1 · " + activity.getString(R.string.relay_global)),
                    "live node selected on the same port");
            require(fetch(local, port, origin.getLocalPort(), password, "global Shadowsocks forwarding").contains(marker),
                    "global traffic uses live Shadowsocks fixture from saved subscription");
            select(test, activity, 2, 0);
            status = await(test, activity, RelayPanel.ID_APPLY, RelayPanel.ID_STATUS, "rule mode selection");
            require(status.contains("2 · " + activity.getString(R.string.relay_rule)), "rule mode and node confirmed");
            require(fetch(local, port, origin.getLocalPort(), password, "rule forwarding").contains(marker),
                    "rule mode honors built-in loopback bypass");
            test.runOnMainSync(() -> activity.findViewById(RelayPanel.ID_STOP).performClick());
            require(await(test, activity, RelayPanel.ID_START, RelayPanel.ID_STATUS, "stop finished")
                    .equals(activity.getString(R.string.relay_stopped)), "stopped cleanly");
            require(activity.getNoBackupFilesDir().listFiles((dir, name) -> name.startsWith("clay-relay-")).length == 0,
                    "private runtime directory removed");
            try (Socket attempt = new Socket()) {
                attempt.connect(new InetSocketAddress(local, port), 700);
                throw new AssertionError("proxy listener remained after stop");
            } catch (java.io.IOException closed) { /* Expected. */ }

            test.runOnMainSync(() -> {
                ((EditText) activity.findViewById(MainActivity.ID_NODE_INPUT)).setText(fixture.nodes());
            });
            NodePickerChecks.choose(test, activity, RelayPanel.ID_NODE, 2, "Fixture-B");
            test.runOnMainSync(() -> {
                String firstOnly = fixture.nodes().split(String.valueOf((char) 10), 2)[0];
                ((EditText) activity.findViewById(MainActivity.ID_NODE_INPUT)).setText(firstOnly);
                NodePicker picker = activity.findViewById(RelayPanel.ID_NODE);
                require(picker.selected() == 1 && !picker.getText().toString().contains("Fixture-B"),
                        "editing the source invalidates the previous draft selection");
                activity.findViewById(RelayPanel.ID_START).performClick();
            });
            require(await(test, activity, RelayPanel.ID_APPLY, RelayPanel.ID_STATUS, "manual relay ready")
                    .contains("127.0.0.1:"), "manual node input still starts Relay");
            test.runOnMainSync(() -> activity.findViewById(RelayPanel.ID_STOP).performClick());
            require(await(test, activity, RelayPanel.ID_START, RelayPanel.ID_STATUS, "manual relay stopped")
                    .equals(activity.getString(R.string.relay_stopped)), "manual session stopped cleanly");
            verifyUpstreams(test, activity, local, origin.getLocalPort(), originConnections, forwarding);
        }
    }

    private static void verifyUpstreams(Instrumentation test, Activity activity, InetAddress local, int origin,
                                        AtomicInteger direct, String fixture) throws Exception {
        ForwardingFixture forwarding = new ForwardingFixture(fixture);
        String source = forwarding.profile();
        test.runOnMainSync(() -> {
            ((EditText) activity.findViewById(MainActivity.ID_NODE_INPUT)).setText(source);
            ((Spinner) activity.findViewById(RelayPanel.ID_MODE)).setSelection(1);
        });
        NodePickerChecks.choose(test, activity, RelayPanel.ID_NODE, 1, "HTTP CONNECT");
        test.runOnMainSync(() -> activity.findViewById(RelayPanel.ID_START).performClick());
        String status = await(test, activity, RelayPanel.ID_APPLY, RelayPanel.ID_STATUS, "forwarding session ready");
        Matcher address = Pattern.compile("127\\.0\\.0\\.1:([0-9]{1,5})").matcher(status);
        require(address.find(), "forwarding session loopback address");
        int port = Integer.parseInt(address.group(1));
        test.runOnMainSync(() -> activity.findViewById(RelayPanel.ID_SHOW).performClick());
        String credentials = await(test, activity, RelayPanel.ID_APPLY, RelayPanel.ID_CREDENTIALS, "forwarding session credentials");
        Matcher password = Pattern.compile("[a-f0-9]{64}").matcher(credentials);
        require(password.find() && !status.contains(password.group()), "forwarding session credentials remain hidden in status");
        int before = direct.get();
        for (int number = 1; number <= ForwardingFixture.COUNT; number++) {
            if (number != 1) {
                NodePickerChecks.choose(test, activity, RelayPanel.ID_NODE, number, forwarding.label(number));
                test.runOnMainSync(() -> activity.findViewById(RelayPanel.ID_APPLY).performClick());
                status = await(test, activity, RelayPanel.ID_APPLY, RelayPanel.ID_STATUS, "confirm forwarding node " + number);
            }
            require(status.contains("127.0.0.1:" + port) && status.contains(number + " · " + activity.getString(R.string.relay_global)),
                    "forwarding node confirmed in the same Global session");
            require(!forwarding.hasPrivateData(status),
                    "forwarding status omits upstream address and credentials");
            // Allow Mihomo's five-second dial retry budget to finish on expected failures.
            String response = fetch(local, port, origin, password.group(), "forwarding node " + number, number <= ForwardingFixture.WORKING ? 5000 : 9000);
            if (number <= ForwardingFixture.WORKING) require(response.equals(forwarding.proof(number)), "selected upstream answered: " + number);
            else require(response.startsWith("HTTP/1.1 5"), "invalid authentication or pin rejected: " + number);
            require(direct.get() == before, "Global forwarded traffic never contacted the direct origin");
        }
        NodePickerChecks.choose(test, activity, RelayPanel.ID_NODE, 1, "HTTP CONNECT");
        test.runOnMainSync(() -> activity.findViewById(RelayPanel.ID_APPLY).performClick());
        await(test, activity, RelayPanel.ID_APPLY, RelayPanel.ID_STATUS, "switch back to a working node");
        require(fetch(local, port, origin, password.group(), "recovered forwarding").equals(forwarding.proof(1)) && direct.get() == before,
                "same listener recovers when a working node is selected");
        test.runOnMainSync(() -> activity.findViewById(RelayPanel.ID_STOP).performClick());
        require(await(test, activity, RelayPanel.ID_START, RelayPanel.ID_STATUS, "forwarding session stopped")
                .equals(activity.getString(R.string.relay_stopped)), "forwarding session stopped cleanly");
        require(activity.getNoBackupFilesDir().listFiles((dir, name) -> name.startsWith("clay-relay-")).length == 0,
                "forwarding session removed its private runtime directory");
    }

    private static void select(Instrumentation test, Activity activity, int node, int mode) {
        NodePickerChecks.choose(test, activity, RelayPanel.ID_NODE, node, node == 1 ? "Fixture-A" : "Fixture-B");
        test.runOnMainSync(() -> {
            ((Spinner) activity.findViewById(RelayPanel.ID_MODE)).setSelection(mode);
            activity.findViewById(RelayPanel.ID_APPLY).performClick();
        });
    }

    /** An independent loopback Shadowsocks inbound with synthetic credentials. */
    static final class ShadowsocksFixture implements AutoCloseable {
        final String password = UUID.randomUUID().toString();
        final int port;
        final File directory;
        private Process core;

        ShadowsocksFixture(Context context) throws Exception {
            InetAddress local = InetAddress.getByAddress(new byte[] {127, 0, 0, 1});
            try (ServerSocket reserved = new ServerSocket(0, 1, local)) { port = reserved.getLocalPort(); }
            directory = new File(context.getCacheDir(), "clay-test-ss-" + UUID.randomUUID());
            require(directory.mkdir(), "create Shadowsocks fixture directory");
            try {
                File config = new File(directory, "fixture.json");
                try (FileOutputStream out = new FileOutputStream(config)) {
                    JSONObject listener = new JSONObject().put("name", "fixture").put("type", "shadowsocks")
                            .put("listen", "127.0.0.1").put("port", port).put("cipher", "aes-128-gcm").put("password", password);
                    out.write(new JSONObject().put("mode", "direct").put("log-level", "silent").put("geo-auto-update", false)
                            .put("listeners", new JSONArray().put(listener)).toString().getBytes(StandardCharsets.UTF_8));
                }
                File lib = new File(context.getApplicationInfo().nativeLibraryDir);
                core = new ProcessBuilder(new File(lib, "libclay_launcher.so").getPath(),
                        Integer.toString(android.os.Process.myPid()), new File(lib, "libclay_mihomo.so").getPath(),
                        "-d", directory.getPath(), "-f", config.getPath())
                        .redirectErrorStream(true).redirectOutput(new File("/dev/null")).start();
                long deadline = SystemClock.elapsedRealtime() + 4000;
                while (SystemClock.elapsedRealtime() < deadline) {
                    try (Socket probe = new Socket()) {
                        probe.connect(new InetSocketAddress(local, port), 500);
                        return;
                    } catch (IOException warmingUp) { SystemClock.sleep(60); }
                }
                throw new AssertionError("Shadowsocks fixture did not start");
            } catch (Exception | AssertionError failure) {
                close();
                throw failure;
            }
        }

        String nodes() {
            return "ss://aes-128-gcm:" + password + "@127.0.0.1:" + port + "#Fixture-A\n" +
                    "ss://aes-128-gcm:fixture-b@127.0.0.1:1#Fixture-B";
        }

        @Override public void close() throws IOException {
            if (core != null) core.destroy();
            RelaySession.remove(directory);
        }
    }

    private static String fetch(InetAddress address, int proxy, int origin, String password, String step) {
        return fetch(address, proxy, origin, password, step, 5000);
    }

    private static String fetch(InetAddress address, int proxy, int origin, String password, String step, int timeout) {
        try (Socket client = new Socket()) {
            client.connect(new InetSocketAddress(address, proxy), 1200); client.setSoTimeout(timeout);
            String auth = password == null ? "" : "Proxy-Authorization: Basic " + android.util.Base64.encodeToString(
                    ("clay:" + password).getBytes(StandardCharsets.US_ASCII), android.util.Base64.NO_WRAP) + "\r\n";
            byte[] query = ("GET http://127.0.0.1:" + origin + "/test HTTP/1.1\r\nHost: 127.0.0.1:" + origin +
                    "\r\nConnection: close\r\n" + auth + "\r\n").getBytes(StandardCharsets.US_ASCII);
            client.getOutputStream().write(query);
            BufferedReader in = new BufferedReader(new InputStreamReader(client.getInputStream(), StandardCharsets.US_ASCII));
            String status = in.readLine();
            require(status != null && status.startsWith("HTTP/1.1 "), step + ": HTTP status received");
            if (!status.startsWith("HTTP/1.1 200")) return status;
            int length = -1;
            for (int count = 0; count < 64; count++) {
                String header = in.readLine();
                if (header == null || header.isEmpty()) break;
                if (header.regionMatches(true, 0, "Content-Length:", 0, 15)) length = Integer.parseInt(header.substring(15).trim());
            }
            require(length >= 0 && length <= 1024, step + ": expected test response length");
            char[] response = new char[length];
            for (int offset = 0; offset < length;) {
                int read = in.read(response, offset, length - offset);
                require(read > 0, step + ": complete response received");
                offset += read;
            }
            return new String(response);
        } catch (IOException | NumberFormatException failure) { throw new AssertionError(step + ": " + failure.getClass().getSimpleName()); }
    }

    private static String await(Instrumentation test, Activity activity, int control, int result, String step) {
        long deadline = SystemClock.elapsedRealtime() + 12000;
        while (SystemClock.elapsedRealtime() < deadline) {
            String[] value = new String[1];
            boolean[] failed = new boolean[1];
            test.runOnMainSync(() -> {
                View button = activity.findViewById(control);
                if (button != null && button.isEnabled()) value[0] = ((TextView) activity.findViewById(result)).getText().toString();
                if (value[0] == null && control != RelayPanel.ID_START) {
                    String status = ((TextView) activity.findViewById(RelayPanel.ID_STATUS)).getText().toString();
                    failed[0] = status.equals(activity.getString(R.string.relay_failed));
                }
            });
            require(!failed[0], step + " failed");
            if (value[0] != null) return value[0];
            SystemClock.sleep(30);
        }
        throw new AssertionError(step + " timed out");
    }

    private static void require(boolean check, String label) { if (!check) throw new AssertionError(label); }
}
