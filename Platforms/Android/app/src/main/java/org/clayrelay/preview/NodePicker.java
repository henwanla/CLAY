package org.clayrelay.preview;

import android.app.Activity;
import android.app.AlertDialog;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONException;

/** Selects from the draft source while stopped or from the session's fixed order while running. */
final class NodePicker extends Button {
    private final Activity activity;
    private final NodeInput source;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private List<String> draft, live;
    private int draftPick = 1, livePick, confirmed, generation;
    private boolean allowed, failed;
    private Future<?> task;
    private AtomicReference<byte[]> pending;
    private AlertDialog dialog;

    NodePicker(Activity activity, NodeInput source, int id) {
        super(activity);
        this.activity = activity; this.source = source;
        setId(id);
        setSaveEnabled(false);
        setAllCaps(false);
        setMaxLines(2);
        setEllipsize(TextUtils.TruncateAt.END);
        source.onChange(this::sourceChanged);
        setOnClickListener(view -> choose());
        paint();
    }

    int selected() { return live == null ? draftPick : livePick; }

    void allow(boolean enabled) {
        if (allowed == enabled) return;
        allowed = enabled;
        if (!allowed) hide();
        paint();
    }

    void session(List<String> choices, int node) {
        if (live == choices && confirmed == node) return;
        hide();
        live = choices;
        livePick = confirmed = node;
        paint();
    }

    void sessionEnded() { session(null, 0); }

    private void sourceChanged() {
        draft = null; draftPick = 1; failed = false;
        if (live == null) hide();
        paint();
    }

    private void choose() {
        if (!isEnabled() || dialog != null || task != null) return;
        List<String> choices = live != null ? live : draft;
        if (choices != null) { show(choices); return; }
        byte[] material = source.snapshot();
        if (material == null) { failed = true; paint(); return; }
        AtomicReference<byte[]> queued = new AtomicReference<>(material);
        pending = queued;
        int version = ++generation;
        task = worker.submit(() -> {
            byte[] data = queued.getAndSet(null);
            if (data == null) return;
            List<String> parsed;
            try { parsed = NativePreview.choices(data); }
            catch (JSONException | LinkageError error) { parsed = null; }
            finally { Arrays.fill(data, (byte) 0); }
            List<String> result = parsed;
            main.post(() -> {
                if (version != generation) return;
                task = null; pending = null;
                failed = result == null || result.isEmpty();
                draft = failed ? null : result;
                paint();
                if (!failed && isEnabled()) show(draft);
            });
        });
        paint();
    }

    private void show(List<String> choices) {
        if (choices.isEmpty()) return;
        AlertDialog created = new AlertDialog.Builder(activity)
                .setTitle(R.string.node_picker_title)
                .setSingleChoiceItems(choices.toArray(new String[0]), selected() - 1, (window, row) -> {
                    if (live == null) draftPick = row + 1;
                    else livePick = row + 1;
                    window.dismiss();
                    paint();
                })
                .setNegativeButton(android.R.string.cancel, null).create();
        Window window = created.getWindow();
        if (window == null) return;
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        created.setOnDismissListener(gone -> { if (dialog == created) dialog = null; });
        dialog = created;
        created.show();
    }

    private void paint() {
        List<String> choices = live != null ? live : draft;
        int node = selected();
        if (task != null) setText(R.string.running);
        else if (choices != null && node >= 1 && node <= choices.size()) {
            setText(activity.getString(R.string.node_picker_selected, node, choices.get(node - 1)));
        } else if (failed) setText(R.string.node_picker_empty);
        else setText(R.string.node_picker_default);
        setEnabled(allowed && task == null && (live != null || source.available()));
    }

    void hide() {
        generation++;
        if (task != null) task.cancel(false);
        if (pending != null) {
            byte[] data = pending.getAndSet(null);
            if (data != null) Arrays.fill(data, (byte) 0);
        }
        task = null; pending = null;
        AlertDialog visible = dialog;
        dialog = null;
        if (visible != null) visible.dismiss();
        paint();
    }

    void destroy() {
        source.onChange(null);
        hide();
        live = null; draft = null;
        worker.shutdownNow();
    }
}
