package org.clayrelay.preview;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.text.format.Formatter;
import android.widget.TextView;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Samples one confirmed core while the panel is in the foreground. Main-thread state only. */
final class SessionTrafficView extends TextView {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private RelaySession.TrafficSource source;
    private boolean reading;
    private int generation;
    private final Runnable poll = this::poll;

    SessionTrafficView(Context context, int id) {
        super(context);
        setId(id);
        setSaveEnabled(false);
        setVisibility(GONE);
    }

    void setSource(RelaySession.TrafficSource next) {
        if (source == next) return;
        source = next;
        generation++;
        main.removeCallbacks(poll);
        setVisibility(next == null ? GONE : VISIBLE);
        if (next == null) setText("");
        else {
            setText(R.string.session_traffic_waiting);
            poll();
        }
    }

    private void poll() {
        if (source == null || reading) return;
        RelaySession.TrafficSource expected = source;
        int request = generation;
        reading = true;
        worker.execute(() -> {
            RelaySession.Traffic counts = expected.read();
            main.post(() -> {
                reading = false;
                if (source == null) return;
                if (generation != request) { poll(); return; }
                render(counts);
                main.postDelayed(poll, 1000);
            });
        });
    }

    private void render(RelaySession.Traffic counts) {
        if (counts == null) {
            setText(R.string.session_traffic_unavailable);
            return;
        }
        Context context = getContext();
        String totals = context.getString(R.string.session_traffic_totals,
                Formatter.formatFileSize(context, counts.upTotal), Formatter.formatFileSize(context, counts.downTotal));
        String rates = context.getString(R.string.session_traffic_rates,
                Formatter.formatFileSize(context, counts.upRate), Formatter.formatFileSize(context, counts.downRate));
        setText(totals + "\n" + rates);
    }

    void destroy() {
        setSource(null);
        worker.shutdownNow();
    }
}
