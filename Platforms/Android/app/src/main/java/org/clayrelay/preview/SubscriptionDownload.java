package org.clayrelay.preview;

import java.io.IOException;
import java.io.FilterInputStream;
import java.io.InputStream;
import java.net.Proxy;
import java.net.URI;
import java.net.URL;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Locale;
import java.util.concurrent.TimeUnit;
import java.util.zip.GZIPInputStream;
import javax.net.ssl.HttpsURLConnection;
import org.json.JSONObject;

final class SubscriptionDownload {
    static final int MAX_BYTES = 2 * 1024 * 1024;
    static final int MAX_URL = 8192;
    private static final int REDIRECTS = 4;

    enum Reason { ADDRESS, REDIRECT, NETWORK, SIZE, CONTENT }
    static final class Failure extends IOException {
        final Reason reason;
        Failure(Reason reason) { super(reason.name()); this.reason = reason; }
    }

    static URI address(String input) throws Failure {
        try {
            String trimmed = input.trim();
            if (trimmed.isEmpty() || trimmed.length() > MAX_URL) throw new Failure(Reason.ADDRESS);
            URI uri = new URI(trimmed);
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null || uri.getRawUserInfo() != null
                    || uri.getRawFragment() != null || uri.getPort() == 0 || uri.getPort() > 65535
                    || uri.toASCIIString().length() > MAX_URL) throw new Failure(Reason.ADDRESS);
            return uri;
        } catch (java.net.URISyntaxException | RuntimeException e) {
            throw new Failure(Reason.ADDRESS);
        }
    }

    static final class Nodes implements AutoCloseable {
        final byte[] source;
        final int count;
        Nodes(byte[] source, int count) { this.source = source; this.count = count; }
        @Override public void close() { Arrays.fill(source, (byte) 0); }
    }

    static Nodes fetch(URI address) throws Failure {
        return fetch(address, url -> (HttpsURLConnection) url.openConnection(Proxy.NO_PROXY));
    }

    interface Transport { HttpsURLConnection connect(URL url) throws IOException; }

    static Nodes fetch(URI initial, Transport transport) throws Failure {
        URI current = address(initial.toASCIIString());
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20);
        try {
            for (int hop = 0; hop <= REDIRECTS; hop++) {
                HttpsURLConnection conn = transport.connect(current.toURL());
                try {
                    conn.setInstanceFollowRedirects(false);
                    conn.setConnectTimeout(timeout(deadline));
                    conn.setReadTimeout(timeout(deadline));
                    conn.setUseCaches(false);
                    conn.setRequestMethod("GET");
                    conn.setRequestProperty("Accept-Encoding", "gzip, identity");
                    conn.setRequestProperty("User-Agent", "CLAY");
                    int status = conn.getResponseCode();
                    if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308) {
                        String location = conn.getHeaderField("Location");
                        if (hop == REDIRECTS || location == null || location.length() > MAX_URL) throw new Failure(Reason.REDIRECT);
                        try {
                            URI next = address(current.resolve(location).toASCIIString());
                            if (!sameOrigin(current, next)) throw new Failure(Reason.REDIRECT);
                            current = next;
                        } catch (IllegalArgumentException | Failure invalid) { throw new Failure(Reason.REDIRECT); }
                        continue;
                    }
                    if (status != 200) throw new Failure(Reason.NETWORK);
                    String size = conn.getHeaderField("Content-Length");
                    if (size != null && Long.parseLong(size.trim()) > MAX_BYTES) throw new Failure(Reason.SIZE);
                    String encoding = conn.getHeaderField("Content-Encoding");
                    encoding = encoding == null ? "identity" : encoding.trim().toLowerCase(Locale.ROOT);
                    if (!encoding.equals("identity") && !encoding.equals("gzip")) throw new Failure(Reason.CONTENT);
                    try (InputStream wire = new Bounded(conn.getInputStream(), deadline)) {
                        if (encoding.equals("identity")) return read(wire, deadline);
                        try (InputStream decoded = new GZIPInputStream(wire)) { return read(decoded, deadline); }
                    }
                } finally { conn.disconnect(); }
            }
        } catch (Failure e) { throw e; }
        catch (Exception | LinkageError ignored) { throw new Failure(Reason.NETWORK); }
        throw new Failure(Reason.REDIRECT);
    }

    private static int timeout(long deadline) throws Failure {
        long remaining = deadline - System.nanoTime();
        if (remaining <= 0 || Thread.currentThread().isInterrupted()) throw new Failure(Reason.NETWORK);
        return (int) Math.max(1, Math.min(5000, TimeUnit.NANOSECONDS.toMillis(remaining)));
    }

    private static final class Bounded extends FilterInputStream {
        private final long deadline;
        private int size;
        Bounded(InputStream source, long deadline) { super(source); this.deadline = deadline; }
        @Override public int read() throws IOException {
            timeout(deadline);
            int next = in.read();
            if (next >= 0 && ++size > MAX_BYTES) throw new Failure(Reason.SIZE);
            return next;
        }
        @Override public int read(byte[] target, int offset, int length) throws IOException {
            timeout(deadline);
            int n = in.read(target, offset, Math.min(length, MAX_BYTES + 1 - size));
            if (n > 0 && (size += n) > MAX_BYTES) throw new Failure(Reason.SIZE);
            return n;
        }
    }

    private static Nodes read(InputStream input, long deadline) throws IOException {
        byte[] buffer = new byte[MAX_BYTES + 1];
        try {
            int count = 0;
            while (count < buffer.length) {
                timeout(deadline);
                int n = input.read(buffer, count, Math.min(8192, buffer.length - count));
                if (n < 0) break;
                count += n;
            }
            if (count > MAX_BYTES) throw new Failure(Reason.SIZE);
            byte[] data = Arrays.copyOf(buffer, count);
            try {
                // Require lossless UTF-8 before handing this untrusted document to the native importer.
                StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(data));
                JSONObject report = new JSONObject(NativePreview.describe(data));
                if (!report.has("nodes") || report.getJSONArray("nodes").length() < 1) throw new Failure(Reason.CONTENT);
                return new Nodes(data, report.getJSONArray("nodes").length());
            } catch (Exception | LinkageError ignored) {
                Arrays.fill(data, (byte) 0);
                throw new Failure(Reason.CONTENT);
            }
        } finally { Arrays.fill(buffer, (byte) 0); }
    }

    private static boolean sameOrigin(URI a, URI b) {
        int portA = a.getPort() < 0 ? 443 : a.getPort();
        int portB = b.getPort() < 0 ? 443 : b.getPort();
        return a.getHost().equalsIgnoreCase(b.getHost()) && portA == portB;
    }
}
