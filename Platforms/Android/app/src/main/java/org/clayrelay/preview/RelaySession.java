package org.clayrelay.preview;

import android.content.Context;
import android.os.SystemClock;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** One process and its private runtime files; methods run on a single worker. */
final class RelaySession implements AutoCloseable {
    static final String HOST = "127.0.0.1", USER = "clay";
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final InetAddress LOOPBACK;
    static {
        try { LOOPBACK = InetAddress.getByAddress(new byte[] {127, 0, 0, 1}); }
        catch (IOException impossible) { throw new AssertionError(impossible); }
    }
    private volatile Process child;
    private volatile File directory;
    private volatile TrafficSource traffic;
    private int proxy, control;
    private String secret, password;
    private String[] ids;
    private List<String> labels;
    private boolean vpn;

    static final class State {
        final int proxy, node;
        final String password, mode;
        final List<String> labels;
        State(int proxy, int node, String password, String mode, List<String> labels) {
            this.proxy = proxy; this.node = node; this.password = password; this.mode = mode; this.labels = labels;
        }
    }

    boolean running() {
        Process existing = child;
        if (existing == null) return false;
        try { existing.exitValue(); return false; }
        catch (IllegalThreadStateException running) { return true; }
    }

    boolean needsCleanup() { return directory != null || child != null; }

    State start(Context context, byte[] source, int node, String mode, String rules, int ruleOptions) throws Exception {
        return start(context, source, node, mode, rules, ruleOptions, null);
    }

    State start(Context context, byte[] source, int node, String mode, String rules, int ruleOptions,
                VpnTransport transport) throws Exception {
        if (child != null || directory != null) throw new IOException();
        vpn = transport != null;
        File lib = new File(context.getApplicationInfo().nativeLibraryDir);
        File engine = new File(lib, "libclay_mihomo.so"), launcher = new File(lib, "libclay_launcher.so");
        if (!(vpn ? BuildFlavor.VPN : BuildFlavor.RELAY) || !BuildFlavor.ENGINE_SHA256.equals(sha256(engine))) throw new IOException();
        File target = new File(context.getNoBackupFilesDir(), (vpn ? "v-" : "clay-relay-") + randomHex(16));
        if (!target.mkdir()) throw new IOException();
        directory = target;
        try {
            Os.chmod(directory.getPath(), 0700);
            secret = randomHex(32);
            password = randomHex(32);
            File config = new File(directory, "clay.json");
            try (ServerSocket first = reserve(); ServerSocket second = reserve()) {
                proxy = first.getLocalPort(); control = second.getLocalPort();
                JSONObject request = new JSONObject().put("node", node - 1).put("proxy", proxy).put("controller", control)
                        .put("secret", secret).put("password", password).put("mode", mode).put("rules", rules)
                        .put("ruleOptions", ruleOptions).put("vpn", vpn);
                byte[] options = request.toString().getBytes(StandardCharsets.UTF_8);
                byte[] generated;
                try { generated = NativePreview.config(source, options); }
                finally { Arrays.fill(options, (byte) 0); }
                if (generated == null) throw new IOException();
                try {
                    JSONObject envelope = new JSONObject(new String(generated, StandardCharsets.UTF_8));
                    JSONArray all = envelope.getJSONArray("nodeIDs");
                    labels = NativePreview.labels(envelope.getJSONArray("nodeLabels"));
                    if (labels.size() != all.length()) throw new IOException();
                    ids = new String[all.length()];
                    for (int i = 0; i < ids.length; i++) {
                        ids[i] = all.getString(i);
                        if (!ids[i].matches("node-[a-f0-9-]{36}")) throw new IOException();
                    }
                    byte[] nativeConfig = envelope.getString("engineConfig").getBytes(StandardCharsets.UTF_8);
                    try (FileOutputStream file = new FileOutputStream(config)) {
                        Os.chmod(config.getPath(), 0600);
                        file.write(nativeConfig);
                    } finally { Arrays.fill(nativeConfig, (byte) 0); }
                } finally { Arrays.fill(generated, (byte) 0); }
            }
            ProcessBuilder process = new ProcessBuilder(launcher.getPath(), Integer.toString(android.os.Process.myPid()),
                    engine.getPath(), "-d", directory.getPath(), "-f", config.getPath());
            if (transport != null) {
                transport.establish();
                process.command(launcher.getPath(), Integer.toString(android.os.Process.myPid()), engine.getPath(),
                        directory.getPath(), config.getPath(), "protect");
            }
            Map<String, String> env = process.environment();
            env.clear();
            // The already-established Android TUN carries IPv6 even on an IPv4-only uplink.
            if (transport != null) {
                env.put("SKIP_SYSTEM_IPV6_CHECK", "true");
                env.put("CLAY_VPN_RESOLVER", transport.resolverAddress());
            }
            env.put("HOME", directory.getPath()); env.put("TMPDIR", directory.getPath()); env.put("PATH", "/system/bin");
            child = process.directory(directory).redirectErrorStream(true).redirectOutput(new File("/dev/null")).start();
            child.getOutputStream().close();
            if (transport != null) transport.attach(directory);
            long deadline = SystemClock.elapsedRealtime() + 8_000;
            while (running() && SystemClock.elapsedRealtime() < deadline) {
                try {
                    State state = refresh();
                    if (state.node != node || !state.mode.equals(mode) || !authenticates()) throw new IOException();
                    if (!config.delete()) throw new IOException();
                    traffic = new TrafficSource(control, secret);
                    return state;
                } catch (IOException | JSONException warmingUp) { SystemClock.sleep(90); }
            }
            throw new IOException();
        } catch (Exception | LinkageError failure) {
            close();
            throw failure;
        }
    }

    boolean contains(int node) { return ids != null && node >= 1 && node <= ids.length; }

    State change(int node, String mode) throws Exception {
        if (ids == null || node < 1 || node > ids.length || !Arrays.asList("rule", "global", "direct").contains(mode)) {
            throw new IOException();
        }
        try {
            State before = refresh();
            if (before.node != node) request("PUT", "/proxies/CLAY", new JSONObject().put("name", ids[node - 1]));
            if (!before.mode.equals(mode)) request("PATCH", "/configs", new JSONObject().put("mode", mode));
            if (before.node != node || !before.mode.equals(mode)) request("DELETE", "/connections", null);
            State state = refresh();
            if (state.node != node || !state.mode.equals(mode)) throw new IOException();
            return state;
        } catch (Exception failure) {
            // A partial change could leave the previous mode (including Direct) in effect.
            close();
            throw failure;
        }
    }

    State refresh() throws Exception {
        if (!running() || ids == null) throw new IOException();
        JSONObject config = request("GET", "/configs", null);
        String mode = config.getString("mode");
        if (config.getInt("mixed-port") != proxy || config.getBoolean("allow-lan")
                || (vpn && !confirmsDualStack(config))
                || !Arrays.asList("rule", "global", "direct").contains(mode)) throw new IOException();
        String selected = request("GET", "/proxies/CLAY", null).getString("now");
        int index = Arrays.asList(ids).indexOf(selected);
        if (index < 0 || !running()) throw new IOException();
        return new State(proxy, index + 1, password, mode, labels);
    }

    private static boolean confirmsDualStack(JSONObject config) throws JSONException {
        JSONObject tun = config.getJSONObject("tun");
        JSONArray ipv6 = tun.optJSONArray("inet6-address");
        return tun.getBoolean("enable") && config.getBoolean("ipv6") && ipv6 != null
                && ipv6.length() == 1 && VpnTransport.IPV6_TUN_CIDR.equals(ipv6.getString(0));
    }

    TrafficSource trafficSource() { return traffic; }

    static final class Traffic {
        final long upTotal, downTotal, upRate, downRate;
        Traffic(JSONObject row) throws JSONException {
            upTotal = count(row, "upTotal"); downTotal = count(row, "downTotal");
            upRate = count(row, "up"); downRate = count(row, "down");
        }

        private static long count(JSONObject row, String key) throws JSONException {
            Object count = row.get(key);
            if ((count instanceof Integer || count instanceof Long) && ((Number) count).longValue() >= 0) {
                return ((Number) count).longValue();
            }
            throw new JSONException("invalid traffic counter");
        }
    }

    /** Bound to one running core. Sampling does not queue behind route or stop actions. */
    static final class TrafficSource {
        private final int control;
        private final String secret;

        private TrafficSource(int control, String secret) { this.control = control; this.secret = secret; }

        Traffic read() {
            HttpURLConnection http = null;
            try {
                http = (HttpURLConnection) new URL("http", HOST, control, "/traffic").openConnection(Proxy.NO_PROXY);
                http.setInstanceFollowRedirects(false);
                // Mihomo sends a fresh row about a second after the request.
                http.setConnectTimeout(500); http.setReadTimeout(2300);
                http.setRequestProperty("Authorization", "Bearer " + secret);
                if (http.getResponseCode() != 200) return null;
                try (InputStream input = http.getInputStream(); ByteArrayOutputStream line = new ByteArrayOutputStream()) {
                    // /traffic is an open-ended stream. Only read the first bounded row.
                    for (int value; line.size() < 512 && (value = input.read()) >= 0;) {
                        if (value == '\n') return new Traffic(new JSONObject(new String(line.toByteArray(), StandardCharsets.UTF_8)));
                        line.write(value);
                    }
                }
            } catch (IOException | JSONException ignored) {
                // Traffic is optional and errors can contain controller details.
            } finally { if (http != null) http.disconnect(); }
            return null;
        }
    }

    private JSONObject request(String method, String path, JSONObject object) throws Exception {
        HttpURLConnection http = (HttpURLConnection) new URL("http", HOST, control, path).openConnection(Proxy.NO_PROXY);
        try {
            http.setRequestMethod(method); http.setInstanceFollowRedirects(false);
            http.setConnectTimeout(700); http.setReadTimeout(700);
            http.setRequestProperty("Authorization", "Bearer " + secret);
            if (object != null) {
                byte[] body = object.toString().getBytes(StandardCharsets.UTF_8);
                http.setDoOutput(true); http.setFixedLengthStreamingMode(body.length);
                http.setRequestProperty("Content-Type", "application/json");
                try (java.io.OutputStream output = http.getOutputStream()) { output.write(body); }
            }
            int status = http.getResponseCode();
            if ((object != null || method.equals("DELETE")) && status == 204) return new JSONObject();
            if (status != 200) throw new IOException();
            try (InputStream in = http.getInputStream(); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                byte[] bytes = new byte[4096];
                for (int n; (n = in.read(bytes)) >= 0;) {
                    if (out.size() + n > 256 * 1024) throw new IOException();
                    out.write(bytes, 0, n);
                }
                return new JSONObject(new String(out.toByteArray(), StandardCharsets.UTF_8));
            }
        } finally { http.disconnect(); }
    }

    private boolean authenticates() throws IOException {
        // Verify the proxy requires this session's credentials without dialing any target.
        try (Socket socket = new Socket(Proxy.NO_PROXY)) {
            socket.connect(new InetSocketAddress(LOOPBACK, proxy), 700);
            socket.setSoTimeout(700);
            DataInputStream in = new DataInputStream(socket.getInputStream());
            java.io.OutputStream out = socket.getOutputStream();
            out.write(new byte[] {5, 1, 2});
            if (in.readUnsignedByte() != 5 || in.readUnsignedByte() != 2) return false;
            byte[] pass = password.getBytes(StandardCharsets.US_ASCII);
            try {
                out.write(new byte[] {1, 4, 'c', 'l', 'a', 'y', (byte) pass.length});
                out.write(pass);
                return in.readUnsignedByte() == 1 && in.readUnsignedByte() == 0;
            } finally { Arrays.fill(pass, (byte) 0); }
        }
    }

    @Override public void close() throws IOException {
        traffic = null;
        secret = null; password = null; ids = null; labels = null;
        if (child != null) {
            child.destroy();
            long deadline = SystemClock.elapsedRealtime() + 2500;
            while (running() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(30);
            if (running() && android.os.Build.VERSION.SDK_INT >= 26) {
                child.destroyForcibly();
                deadline = SystemClock.elapsedRealtime() + 1000;
                while (running() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(30);
            }
            if (running()) throw new IOException();
            child = null;
        }
        if (directory != null) {
            remove(directory);
            directory = null;
        }
    }

    static void remove(File file) throws IOException {
        try {
            if (OsConstants.S_ISDIR(Os.lstat(file.getPath()).st_mode)) {
                File[] children = file.listFiles();
                if (children == null) throw new IOException();
                for (File child : children) remove(child);
            }
            if (!file.delete()) throw new IOException();
        } catch (ErrnoException error) {
            if (error.errno != OsConstants.ENOENT) throw new IOException();
        }
    }

    private static ServerSocket reserve() throws IOException {
        ServerSocket socket = new ServerSocket();
        try { socket.bind(new InetSocketAddress(LOOPBACK, 0)); return socket; }
        catch (IOException error) { socket.close(); throw error; }
    }

    private static String randomHex(int length) {
        byte[] bytes = new byte[length];
        RANDOM.nextBytes(bytes);
        try { return hex(bytes); } finally { Arrays.fill(bytes, (byte) 0); }
    }

    private static String sha256(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (FileInputStream in = new FileInputStream(file)) {
            byte[] block = new byte[64 * 1024];
            for (int n; (n = in.read(block)) >= 0;) digest.update(block, 0, n);
        }
        return hex(digest.digest());
    }

    private static String hex(byte[] input) {
        final char[] digits = "0123456789abcdef".toCharArray(), result = new char[2 * input.length];
        for (int i = 0; i < input.length; i++) {
            result[2 * i] = digits[(input[i] & 255) >> 4]; result[2 * i + 1] = digits[input[i] & 15];
        }
        return new String(result);
    }
}
