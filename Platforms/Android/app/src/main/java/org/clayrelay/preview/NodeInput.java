package org.clayrelay.preview;

import android.text.Editable;
import android.text.TextWatcher;
import android.widget.EditText;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

// Main-thread selection for the next preview or session. A running engine owns
// its own snapshot and is not affected by refreshing or deleting a subscription.
final class NodeInput {
    private final EditText manual;
    private byte[] selected;
    private String selectedID, selectedLabel;

    private Runnable listener;

    NodeInput(EditText manual) {
        this.manual = manual;
        manual.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence text, int start, int count, int after) { }
            public void onTextChanged(CharSequence text, int start, int before, int count) { }
            public void afterTextChanged(Editable text) { if (selected == null) changed(); }
        });
    }

    void onChange(Runnable listener) { this.listener = listener; }
    private void changed() { if (listener != null) listener.run(); }
    String subscriptionID() { return selectedID; }
    String subscriptionLabel() { return selectedLabel; }
    boolean available() { return selected != null || manual.length() > 0 && manual.length() <= SubscriptionDownload.MAX_BYTES; }

    void use(SubscriptionStore.Record entry) {
        if (selected != null) Arrays.fill(selected, (byte) 0);
        selected = entry.data.clone();
        selectedID = entry.info.id;
        selectedLabel = entry.info.label;
        changed();
    }

    byte[] snapshot() {
        if (selected != null) return selected.clone();
        if (manual.length() > SubscriptionDownload.MAX_BYTES) return null;
        byte[] data = manual.getText().toString().getBytes(StandardCharsets.UTF_8);
        if (data.length <= SubscriptionDownload.MAX_BYTES) return data;
        Arrays.fill(data, (byte) 0);
        return null;
    }

    void clearSubscription() {
        if (selected == null) return;
        Arrays.fill(selected, (byte) 0);
        selected = null; selectedID = null; selectedLabel = null;
        changed();
    }
}
