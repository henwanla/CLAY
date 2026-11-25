package org.clayrelay.preview;

import java.nio.charset.StandardCharsets;

final class NativePreview {
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
    }
}
