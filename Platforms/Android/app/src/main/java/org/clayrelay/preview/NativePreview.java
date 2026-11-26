package org.clayrelay.preview;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

final class NativePreview {
    static byte[] config(byte[] source, byte[] request) { return Library.config(source, request); }
    static String describe(byte[] source) {
        return new String(Library.call(0, source, new byte[0], 0), StandardCharsets.UTF_8);
    }

    static List<String> choices(byte[] source) throws JSONException {
        byte[] data = Library.call(2, source, new byte[0], 0);
        try { return labels(new JSONObject(new String(data, StandardCharsets.UTF_8)).getJSONArray("nodeLabels")); }
        finally { Arrays.fill(data, (byte) 0); }
    }

    static List<String> labels(JSONArray items) throws JSONException {
        if (items.length() > 100) throw new JSONException("invalid node list");
        List<String> names = new ArrayList<>(items.length());
        for (int i = 0; i < items.length(); i++) names.add(items.getString(i));
        return Collections.unmodifiableList(names);
    }

    static String run(int operation, String source, String target, int options) {
        try {
            return new String(Library.call(operation, source.getBytes(StandardCharsets.UTF_8),
                    target.getBytes(StandardCharsets.UTF_8), options), StandardCharsets.UTF_8);
        } catch (LinkageError e) {
            return "{\"error\":\"previewFailed\"}";
        }
    }

    private static class Library {
        static { System.loadLibrary("claypreview"); }
        private static native byte[] call(int operation, byte[] source, byte[] target, int options);
        private static native byte[] config(byte[] source, byte[] request);
    }
}
