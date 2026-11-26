package org.clayrelay.preview;

import android.content.Context;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.cert.Certificate;
import java.util.Arrays;
import java.util.UUID;
import java.util.zip.GZIPOutputStream;
import javax.net.ssl.HttpsURLConnection;

final class SubscriptionChecks {
    private static final String SECRET = "synthetic-feed-token";
    private static final URI URL = URI.create("https://fixture.test/list?key=" + SECRET);
    private static final String LABEL = "演示フィード";

    static void run(Context context) throws Exception {
        byte[] before = text("ss://aes-128-gcm:synthetic-one@127.0.0.1:1#Fixture");
        byte[] after = text("ss://aes-128-gcm:synthetic-two@127.0.0.1:2#Fixture");
        SubscriptionStore store = new SubscriptionStore(context);
        File directory = new File(context.getNoBackupFilesDir(), "subscriptions-v1");
        String id = seed(context, before);
        File file = new File(directory, id + ".bin");
        try (SubscriptionStore.Record stale = store.read(id)) {
            require(Arrays.equals(stale.data, before) && stale.url.equals(URL) && stale.info.label.equals(LABEL),
                    "saved subscription reopens via Keystore");
            byte[] original = read(file);
            String raw = new String(original, StandardCharsets.UTF_8);
            require(!raw.contains(SECRET) && !raw.contains("fixture.test") && !raw.contains(LABEL)
                    && !raw.contains("synthetic-one"), "no private feed fields in stored file");

            fails(SubscriptionDownload.Reason.CONTENT, () -> {
                try (SubscriptionDownload.Nodes bad = SubscriptionDownload.fetch(stale.url,
                        url -> new Response(url, 200, null, null, null, text("unsupported content")))) {
                    store.refresh(stale, bad);
                }
            });
            require(Arrays.equals(original, read(file)), "invalid refresh leaves old cache byte-for-byte");

            int[] hops = {0};
            try (SubscriptionDownload.Nodes refreshed = SubscriptionDownload.fetch(stale.url, url -> {
                if (hops[0]++ == 0) return new Response(url, 302, "https://FIXTURE.test:443/new?key=" + SECRET, null, null, null);
                require(url.getPath().equals("/new"), "same-origin redirect follows only the new location");
                return new Response(url, 200, null, "gzip", null, gzip(after));
            })) {
                SubscriptionStore.Info updated = store.refresh(stale, refreshed);
                require(updated.updated > stale.info.updated && updated.count == 1 && hops[0] == 2, "validated gzip refresh advances revision");
                rejects(() -> store.refresh(stale, refreshed), "stale refresh rejected");
                try (SubscriptionStore.Record reopened = new SubscriptionStore(context).read(id)) {
                    require(Arrays.equals(reopened.data, after), "latest valid payload reopens");
                }
            }

            byte[] changed = read(file);
            require(!Arrays.equals(Arrays.copyOfRange(original, 1, 13), Arrays.copyOfRange(changed, 1, 13)),
                    "rewrites have distinct IVs");
            String other = UUID.randomUUID().toString();
            File copied = new File(directory, other + ".bin");
            try {
                write(copied, changed);
                rejects(() -> { try (SubscriptionStore.Record ignored = store.read(other)) {} }, "ciphertext copied to another ID rejected");
            } finally { store.remove(other); }
            changed[changed.length - 1] ^= 1;
            write(file, changed);
            require(store.list().size() == 1 && !store.list().get(0).readable(), "corrupt entry listed without content");
            rejects(() -> { try (SubscriptionStore.Record ignored = store.read(id)) {} }, "tampered ciphertext rejected");
        } finally { store.remove(id); }
        require(store.list().isEmpty(), "unreadable record can be removed");

        for (String location : new String[] {"http://fixture.test/list", "https://different.test/list", "https://fixture.test:444/list"}) {
            int[] hops = {0};
            fails(SubscriptionDownload.Reason.REDIRECT, () -> SubscriptionDownload.fetch(URL, url -> {
                hops[0]++;
                return new Response(url, 307, location, null, null, null);
            }));
            require(hops[0] == 1, "rejected origin never contacted");
        }
        fails(SubscriptionDownload.Reason.ADDRESS, () -> SubscriptionDownload.address("https://user:password@fixture.test/list"));
        fails(SubscriptionDownload.Reason.ADDRESS, () -> SubscriptionDownload.address("http://fixture.test/list"));
        byte[] oversized = new byte[SubscriptionDownload.MAX_BYTES + 1];
        fails(SubscriptionDownload.Reason.SIZE, () -> SubscriptionDownload.fetch(URL,
                url -> new Response(url, 200, null, null, Integer.toString(oversized.length), null)));
        fails(SubscriptionDownload.Reason.SIZE, () -> SubscriptionDownload.fetch(URL,
                url -> new Response(url, 200, null, null, null, oversized)));
        byte[] compressed = gzip(oversized);
        fails(SubscriptionDownload.Reason.SIZE, () -> SubscriptionDownload.fetch(URL,
                url -> new Response(url, 200, null, "gzip", null, compressed)));
        fails(SubscriptionDownload.Reason.CONTENT, () -> SubscriptionDownload.fetch(URL,
                url -> new Response(url, 200, null, null, null, new byte[] {(byte) 0xc3, 0x28})));
    }

    // The downloader validates the same bytes used by the real subscription-backed Relay session.
    static String seed(Context context, byte[] body) throws Exception {
        try (SubscriptionDownload.Nodes validated = SubscriptionDownload.fetch(URL,
                url -> new Response(url, 200, null, null, null, body))) {
            return new SubscriptionStore(context).add(LABEL, URL, validated).id;
        }
    }

    private interface Attempt { void run() throws Exception; }
    private static void fails(SubscriptionDownload.Reason reason, Attempt attempt) throws Exception {
        try { attempt.run(); }
        catch (SubscriptionDownload.Failure failure) {
            require(failure.reason == reason && failure.getMessage().equals(reason.name()), "expected sanitized download rejection");
            return;
        }
        throw new AssertionError("expected subscription download rejection");
    }

    private static void rejects(Attempt attempt, String step) {
        try { attempt.run(); }
        catch (Exception expected) { return; }
        throw new AssertionError(step);
    }

    private static byte[] text(String value) { return value.getBytes(StandardCharsets.UTF_8); }
    private static byte[] read(File file) throws java.io.IOException {
        try (FileInputStream in = new FileInputStream(file); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            for (int n; (n = in.read(buffer)) != -1;) out.write(buffer, 0, n);
            return out.toByteArray();
        }
    }
    private static void write(File file, byte[] bytes) throws java.io.IOException {
        try (FileOutputStream out = new FileOutputStream(file)) { out.write(bytes); }
    }
    private static byte[] gzip(byte[] content) throws java.io.IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (GZIPOutputStream out = new GZIPOutputStream(bytes)) { out.write(content); }
        return bytes.toByteArray();
    }

    // Only the transport is replaced. Native parsing and Keystore operations run on Android.
    private static final class Response extends HttpsURLConnection {
        private final int status;
        private final String location, encoding, length;
        private final byte[] data;
        Response(URL url, int status, String location, String encoding, String length, byte[] data) {
            super(url); this.status = status; this.location = location; this.encoding = encoding; this.length = length; this.data = data;
        }
        @Override public int getResponseCode() {
            require(!getInstanceFollowRedirects(), "transport auto redirects disabled");
            return status;
        }
        @Override public String getHeaderField(String name) {
            if (name.equals("Location")) return location;
            if (name.equals("Content-Encoding")) return encoding;
            if (name.equals("Content-Length")) return length;
            return null;
        }
        @Override public InputStream getInputStream() {
            require(data != null, "rejected headers do not read a response body");
            return new ByteArrayInputStream(data);
        }
        @Override public void disconnect() {}
        @Override public boolean usingProxy() { return false; }
        @Override public void connect() {}
        @Override public String getCipherSuite() { return ""; }
        @Override public Certificate[] getLocalCertificates() { return null; }
        @Override public Certificate[] getServerCertificates() { return null; }
    }

    private static void require(boolean condition, String step) { if (!condition) throw new AssertionError(step); }
}
