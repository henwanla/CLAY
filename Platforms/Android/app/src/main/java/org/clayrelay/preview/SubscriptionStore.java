package org.clayrelay.preview;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.AtomicFile;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.UUID;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** The app's no-backup directory contains ciphertext only. Android Keystore owns the key. */
final class SubscriptionStore {
    static final int LIMIT = 12, MAX_LABEL = 64;
    private static final int IV = 12, TAG = 128, VERSION = 1;
    private static final int MAX_RECORD = SubscriptionDownload.MAX_BYTES + SubscriptionDownload.MAX_URL + 1024;
    private static final String ALIAS = "clay-subscriptions-aes-v1";
    private static final Object FILE_LOCK = new Object();
    private final File directory;

    static final class Info {
        final String id, label;
        final int count;
        final long updated;
        Info(String id, String label, int count, long updated) {
            this.id = id; this.label = label; this.count = count; this.updated = updated;
        }
        boolean readable() { return count > 0; }
    }
    static final class Record implements AutoCloseable {
        final Info info;
        final URI url;
        final byte[] data;
        Record(Info info, URI url, byte[] data) { this.info = info; this.url = url; this.data = data; }
        @Override public void close() { Arrays.fill(data, (byte) 0); }
    }

    SubscriptionStore(Context context) { directory = new File(context.getNoBackupFilesDir(), "subscriptions-v1"); }

    static String label(String input) throws IOException {
        String label = input.trim();
        if (label.isEmpty() || label.length() > MAX_LABEL) throw new IOException("invalid label");
        for (int i = 0; i < label.length(); i++) {
            int kind = Character.getType(label.charAt(i));
            if (kind == Character.CONTROL || kind == Character.FORMAT || kind == Character.LINE_SEPARATOR
                    || kind == Character.PARAGRAPH_SEPARATOR) throw new IOException("invalid label");
        }
        return label;
    }

    List<Info> list() throws Exception {
        synchronized (FILE_LOCK) {
            List<Info> result = new ArrayList<>();
            for (String id : ids()) {
                try (Record entry = readLocked(id)) { result.add(entry.info); }
                catch (Exception unavailable) { result.add(new Info(id, "", 0, 0)); }
            }
            Collections.sort(result, (a, b) -> {
                int time = Long.compare(b.updated, a.updated);
                return time == 0 ? a.id.compareTo(b.id) : time;
            });
            return result;
        }
    }

    Record read(String id) throws Exception { synchronized (FILE_LOCK) { return readLocked(id); } }

    Info add(String label, URI address, SubscriptionDownload.Nodes nodes) throws Exception {
        synchronized (FILE_LOCK) {
            List<String> ids = ids();
            if (ids.size() >= LIMIT) throw new IOException("subscription limit");
            String id = UUID.randomUUID().toString();
            return write(id, label, address, nodes, key(ids.isEmpty()), System.currentTimeMillis());
        }
    }

    // Compare the exact cached revision. A late refresh from a destroyed activity
    // cannot recreate a deleted entry or replace a more recent successful refresh.
    Info refresh(Record original, SubscriptionDownload.Nodes nodes) throws Exception {
        synchronized (FILE_LOCK) {
            try (Record current = readLocked(original.info.id)) {
                if (current.info.updated != original.info.updated) throw new IOException("subscription changed");
            }
            long time = Math.max(System.currentTimeMillis(), original.info.updated + 1);
            return write(original.info.id, original.info.label, original.url, nodes, key(false), time);
        }
    }

    void remove(String id) throws IOException {
        synchronized (FILE_LOCK) {
            File file = file(id);
            new AtomicFile(file).delete();
            if (file.exists() || new File(file.getPath() + ".new").exists() || new File(file.getPath() + ".bak").exists()) {
                throw new IOException("could not remove subscription");
            }
        }
    }

    private List<String> ids() throws IOException {
        List<String> result = new ArrayList<>();
        if (!directory.exists()) return result;
        String[] names = directory.list();
        if (names == null) throw new IOException("subscription storage unavailable");
        // Include files recoverable by AtomicFile even if a crash left only a backup.
        for (String name : names) {
            if (!name.matches("[0-9a-f-]{36}\\.bin(\\.bak|\\.new)?")) continue;
            String id = name.substring(0, 36);
            if (!validID(id) || result.contains(id)) continue;
            result.add(id);
            if (result.size() > LIMIT) throw new IOException("subscription limit");
        }
        return result;
    }

    private static boolean validID(String id) {
        return id != null && id.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}");
    }

    private File file(String id) throws IOException {
        if (!validID(id)) throw new IOException("invalid subscription ID");
        return new File(directory, id + ".bin");
    }

    private static SecretKey key(boolean create) throws Exception {
        KeyStore keys = KeyStore.getInstance("AndroidKeyStore");
        keys.load(null);
        java.security.Key key = keys.getKey(ALIAS, null);
        if (key instanceof SecretKey) return (SecretKey) key;
        if (!create) throw new IOException("subscription key unavailable");
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).setRandomizedEncryptionRequired(true).build());
        return generator.generateKey();
    }

    private static byte[] binding(String id) { return ("CLAY.subscription.v1:" + id).getBytes(StandardCharsets.US_ASCII); }

    private Record readLocked(String id) throws Exception {
        AtomicFile file = new AtomicFile(file(id));
        byte[] sealed;
        try (FileInputStream stream = file.openRead(); ByteArrayOutputStream buffer = new ByteArrayOutputStream()) {
            byte[] block = new byte[8192];
            for (int n; (n = stream.read(block)) != -1;) {
                if (buffer.size() + n > MAX_RECORD) throw new IOException("subscription record too large");
                buffer.write(block, 0, n);
            }
            sealed = buffer.toByteArray();
        }
        if (sealed.length < 1 + IV + TAG / 8 || sealed[0] != VERSION) throw new IOException("invalid subscription record");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key(false), new GCMParameterSpec(TAG, sealed, 1, IV));
        cipher.updateAAD(binding(id));
        byte[] clear = cipher.doFinal(sealed, 1 + IV, sealed.length - 1 - IV);
        try {
            ByteBuffer input = ByteBuffer.wrap(clear);
            String label = label(text(input, MAX_LABEL * 4));
            URI address = SubscriptionDownload.address(text(input, SubscriptionDownload.MAX_URL));
            long updated = input.getLong();
            int count = input.getInt();
            if (updated <= 0 || count < 1 || count > 100 || input.remaining() < 1
                    || input.remaining() > SubscriptionDownload.MAX_BYTES) throw new IOException("invalid subscription record");
            byte[] data = new byte[input.remaining()];
            input.get(data);
            return new Record(new Info(id, label, count, updated), address, data);
        } finally { Arrays.fill(clear, (byte) 0); }
    }

    private static String text(ByteBuffer input, int max) throws IOException {
        int length = input.getInt();
        if (length < 1 || length > max || length > input.remaining()) throw new IOException("invalid subscription record");
        ByteBuffer text = input.slice();
        text.limit(length);
        input.position(input.position() + length);
        return StandardCharsets.UTF_8.newDecoder().decode(text).toString();
    }

    private Info write(String id, String name, URI address, SubscriptionDownload.Nodes nodes, SecretKey key, long now) throws Exception {
        if (Thread.currentThread().isInterrupted()) throw new IOException("subscription operation cancelled");
        String label = label(name);
        byte[] caption = label.getBytes(StandardCharsets.UTF_8);
        byte[] url = SubscriptionDownload.address(address.toASCIIString()).toASCIIString().getBytes(StandardCharsets.US_ASCII);
        if (nodes.count < 1 || nodes.count > 100 || nodes.source.length < 1
                || nodes.source.length > SubscriptionDownload.MAX_BYTES) throw new IOException("invalid subscription record");
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("subscription storage unavailable");
        byte[] clear = ByteBuffer.allocate(20 + caption.length + url.length + nodes.source.length)
                .putInt(caption.length).put(caption).putInt(url.length).put(url).putLong(now).putInt(nodes.count).put(nodes.source).array();
        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, key);
            cipher.updateAAD(binding(id));
            byte[] iv = cipher.getIV();
            if (iv.length != IV) throw new IOException("invalid subscription nonce");
            byte[] ciphertext = cipher.doFinal(clear);
            AtomicFile file = new AtomicFile(file(id));
            FileOutputStream stream = file.startWrite();
            try {
                stream.write(VERSION);
                stream.write(iv);
                stream.write(ciphertext);
                stream.getFD().sync();
                file.finishWrite(stream);
            } catch (Exception failure) { file.failWrite(stream); throw failure; }
            try (Record committed = readLocked(id)) {
                if (committed.info.updated != now) throw new IOException("subscription save was not confirmed");
                return committed.info;
            }
        } finally {
            Arrays.fill(clear, (byte) 0);
            Arrays.fill(url, (byte) 0);
            Arrays.fill(caption, (byte) 0);
        }
    }
}
