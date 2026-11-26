package org.clayrelay.preview;

import android.app.Activity;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.Spinner;
import android.widget.TextView;
import java.io.File;
import java.util.Arrays;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

final class RelayPanel {
    static final int ID_NODE = 0x5110, ID_MODE = 0x5111, ID_START = 0x5112,
            ID_APPLY = 0x5113, ID_STOP = 0x5114, ID_STATUS = 0x5115, ID_SHOW = 0x5116, ID_CREDENTIALS = 0x5117;
    private static final String[] MODES = {"rule", "global", "direct"};
    private static final AtomicBoolean CLEANED = new AtomicBoolean();
    private final RelaySession session = new RelaySession();
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Activity activity;
    private final EditText rules;
    private final NodePicker picker;
    private final NodeInput nodes;
    private final Spinner mode;
    private final CheckBox direct, bypass;
    private final Button start, apply, stop, show;
    private final TextView status, credentials;
    private RelaySession.State ready;
    private boolean busy, hasSession, destroyed;

    RelayPanel(Activity activity, LinearLayout card, NodeInput nodes, EditText rules, CheckBox direct, CheckBox bypass) {
        this.activity = activity; this.nodes = nodes; this.rules = rules;
        this.direct = direct; this.bypass = bypass;
        TextView description = new TextView(activity);
        description.setText(R.string.relay_intro);
        card.addView(description);
        picker = new NodePicker(activity, nodes, ID_NODE);
        card.addView(picker);
        mode = new Spinner(activity);
        mode.setId(ID_MODE); mode.setSaveEnabled(false);
        mode.setContentDescription(activity.getString(R.string.relay_mode));
        ArrayAdapter<String> modes = new ArrayAdapter<>(activity, android.R.layout.simple_spinner_dropdown_item,
                new String[] {activity.getString(R.string.relay_rule), activity.getString(R.string.relay_global),
                        activity.getString(R.string.relay_direct)});
        mode.setAdapter(modes);
        card.addView(mode);
        start = button(card, ID_START, R.string.relay_start);
        apply = button(card, ID_APPLY, R.string.relay_apply);
        stop = button(card, ID_STOP, R.string.relay_stop);
        status = new TextView(activity);
        status.setId(ID_STATUS); status.setSaveEnabled(false);
        status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        card.addView(status);
        show = button(card, ID_SHOW, R.string.relay_show);
        credentials = new TextView(activity);
        credentials.setId(ID_CREDENTIALS); credentials.setSaveEnabled(false);
        credentials.setVisibility(View.GONE);
        card.addView(credentials);
        show.setOnClickListener(v -> {
            if (ready == null || credentials.getVisibility() == View.VISIBLE) hideCredentials();
            else {
                credentials.setText(activity.getString(R.string.relay_credentials, RelaySession.USER, ready.password));
                credentials.setVisibility(View.VISIBLE);
            }
        });
        start.setOnClickListener(v -> change(false));
        apply.setOnClickListener(v -> change(true));
        stop.setOnClickListener(v -> run(R.string.relay_stopping, () -> { session.close(); return null; }));
        status.setText(R.string.relay_stopped);
        buttons();
        worker.submit(() -> {
            if (CLEANED.compareAndSet(false, true)) {
                File[] abandoned = activity.getNoBackupFilesDir().listFiles((file, name) -> name.matches("clay-relay-[a-f0-9]{32}"));
                if (abandoned != null) for (File candidate : abandoned) {
                    try { RelaySession.remove(candidate); } catch (Exception ignored) { /* Still in private storage. */ }
                }
            }
        });
        main.postDelayed(watch, 800);
    }

    private final Runnable watch = new Runnable() {
        @Override public void run() {
            if (destroyed) return;
            if (!busy && ready != null && !session.running()) {
                runEnded();
            }
            main.postDelayed(this, 800);
        }
    };

    private void runEnded() { run(R.string.relay_ended, () -> { session.close(); return null; }); }

    private Button button(LinearLayout card, int id, int title) {
        Button result = new Button(activity);
        result.setId(id); result.setText(title); result.setAllCaps(false);
        card.addView(result);
        return result;
    }

    private void buttons() {
        picker.allow(!busy && (!hasSession || session.running()));
        start.setEnabled(!busy && !hasSession);
        apply.setEnabled(!busy && hasSession && session.running());
        stop.setEnabled(!busy && hasSession);
        show.setVisibility(!busy && ready != null ? View.VISIBLE : View.GONE);
    }

    void hidePicker() { picker.hide(); }

    void hideCredentials() {
        credentials.setText(""); credentials.setVisibility(View.GONE);
    }

    private void change(boolean update) {
        if (destroyed || busy) return;
        final int node = picker.selected();
        if (!update && (!nodes.available() || rules.length() > 12_000)) {
            status.setText(R.string.relay_invalid); return;
        }
        String requested = MODES[mode.getSelectedItemPosition()];
        if (update) {
            run(R.string.relay_starting, () -> session.change(node, requested));
        } else {
            byte[] source = nodes.snapshot();
            if (source == null) { status.setText(R.string.relay_invalid); return; }
            String policy = rules.getText().toString();
            int ruleOptions = (direct.isChecked() ? 1 : 0) | (bypass.isChecked() ? 2 : 0);
            run(R.string.relay_starting, () -> {
                try { return session.start(activity, source, node, requested, policy, ruleOptions); }
                finally { Arrays.fill(source, (byte) 0); }
            });
        }
    }

    private interface Action { RelaySession.State perform() throws Exception; }
    private void run(int message, Action action) {
        if (destroyed || busy) return;
        busy = true;
        ready = null;
        hideCredentials();
        status.setText(message);
        buttons();
        worker.submit(() -> {
            RelaySession.State state = null;
            boolean failed = false;
            try { state = action.perform(); }
            catch (Exception | LinkageError error) { failed = true; }
            RelaySession.State confirmed = state;
            boolean error = failed, cleanupPending = session.needsCleanup();
            main.post(() -> {
                if (destroyed) return;
                busy = false; hasSession = cleanupPending;
                if (!hasSession) picker.sessionEnded();
                if (error) status.setText(cleanupPending ? R.string.relay_unconfirmed : R.string.relay_failed);
                else if (confirmed != null) {
                    ready = confirmed;
                    picker.session(confirmed.labels, confirmed.node);
                    status.setText(activity.getString(R.string.relay_ready, confirmed.proxy, confirmed.node,
                            activity.getString(confirmed.mode.equals("rule") ? R.string.relay_rule :
                                    confirmed.mode.equals("global") ? R.string.relay_global : R.string.relay_direct)));
                }
                else status.setText(message == R.string.relay_ended ? R.string.relay_ended : R.string.relay_stopped);
                buttons();
            });
        });
    }

    void destroy() {
        destroyed = true;
        picker.destroy();
        main.removeCallbacks(watch);
        status.setText("");
        ready = null;
        hideCredentials();
        worker.submit(() -> { try { session.close(); } catch (Exception ignored) { } });
        worker.shutdown();
    }
}
