package org.clayrelay.preview;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.Uri;
import android.net.VpnService;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import java.io.File;
import java.net.InetAddress;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/** The consented foreground service owns the session independently of the Activity. */
public final class ClayVpnService extends VpnService {
    private static final String START = "org.clayrelay.vpn.START", STOP = "org.clayrelay.vpn.STOP";
    private static final String CHANNEL = "clay-vpn-session";
    private static final int NOTIFICATION = 591;
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    // Accessed on the UI thread only. No profile bytes are passed to Android intents or saved state.
    private static Draft pending;
    private static ClayVpnService owner;
    private static Snapshot snapshot = new Snapshot(R.string.vpn_stopped, 0, null, false);
    private static final AtomicBoolean CLEANED = new AtomicBoolean();

    static final class Draft {
        final byte[] source;
        final int node, options;
        final String mode, rules;
        final InetAddress dns;
        Draft(byte[] source, int node, String mode, String rules, int options, InetAddress dns) {
            this.source = source; this.node = node; this.mode = mode; this.rules = rules; this.options = options; this.dns = dns;
        }
        void wipe() { Arrays.fill(source, (byte) 0); }
    }

    static final class Snapshot {
        final int message, node;
        final String mode;
        final boolean busy;
        final List<String> labels;
        Snapshot(int message, int node, String mode, boolean busy) {
            this(message, node, mode, busy, Collections.emptyList());
        }
        Snapshot(int message, int node, String mode, boolean busy, List<String> labels) {
            this.message = message; this.node = node; this.mode = mode; this.busy = busy; this.labels = labels;
        }
    }

    static Snapshot state() { return snapshot; }
    static RelaySession.TrafficSource trafficSource() {
        return owner == null || owner.ending || snapshot.busy || snapshot.node == 0 ? null : owner.engine.trafficSource();
    }
    private static void publish(Snapshot next) {
        snapshot = next;
        ClayVpnTile.refresh(next);
        if (owner != null) owner.updateNotification(next.message);
    }
    static void begin(Context context, Draft draft) {
        if (owner != null || pending != null || !BuildFlavor.VPN) { draft.wipe(); return; }
        pending = draft;
        publish(new Snapshot(R.string.vpn_starting, 0, null, true));
        try { context.startForegroundService(new Intent(context, ClayVpnService.class).setAction(START)); }
        catch (RuntimeException failure) { discardPending(draft); return; }
        MAIN.postDelayed(() -> discardPending(draft), 10_000);
    }
    private static void discardPending(Draft draft) {
        if (pending != draft) return;
        pending = null;
        draft.wipe();
        publish(new Snapshot(R.string.vpn_failed, 0, null, false));
    }
    static void apply(int node, String mode) { if (owner != null) owner.change(node, mode); }
    static boolean canStop() { return owner != null && !owner.ending; }
    static void stopFromPanel() { if (owner != null) owner.finish(R.string.vpn_stopped); }

    static boolean stopFromTile(Snapshot shown) {
        // Unlocking may have taken long enough for the session or selection to change.
        if (shown != snapshot || shown.busy || shown.node == 0 || !canStop()) return false;
        stopFromPanel();
        return true;
    }

    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final RelaySession engine = new RelaySession();
    private VpnTransport transport;
    private boolean ending, destroyed, foreground;
    private Uri stopIdentity;
    private PendingIntent notificationStop;
    private int terminalMessage;

    private final Runnable watch = new Runnable() {
        @Override public void run() {
            if (ending || owner != ClayVpnService.this) return;
            if (!engine.running() || !transport.healthy()) { finish(R.string.vpn_ended); return; }
            MAIN.postDelayed(this, 450);
        }
    };

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? null : intent.getAction();
        if (STOP.equals(action)) {
            if (owner == this && stopIdentity != null && stopIdentity.equals(intent.getData())) {
                finish(R.string.vpn_stopped);
            } else if (owner != this && pending == null) stopSelf(startId);
            return START_NOT_STICKY;
        }
        if (START.equals(action) && pending != null && owner == null) {
            Draft draft = pending;
            pending = null;
            owner = this;
            try {
                if (VpnService.prepare(this) != null) throw new SecurityException();
                // Intent data is part of the PendingIntent identity. An action from an older
                // notification must never be rebound to the next session.
                stopIdentity = Uri.fromParts("clay-vpn-stop", UUID.randomUUID().toString(), null);
                notificationStop = PendingIntent.getService(this, 2,
                        new Intent(this, ClayVpnService.class).setAction(STOP).setData(stopIdentity),
                        PendingIntent.FLAG_IMMUTABLE);
                getSystemService(NotificationManager.class).createNotificationChannel(new NotificationChannel(
                        CHANNEL, getString(R.string.vpn_title), NotificationManager.IMPORTANCE_LOW));
                Notification notice = notification(R.string.vpn_starting);
                if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIFICATION, notice, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED);
                else startForeground(NOTIFICATION, notice);
                foreground = true;
            } catch (RuntimeException failure) {
                draft.wipe();
                finish(R.string.vpn_failed);
                return START_NOT_STICKY;
            }
            transport = new VpnTransport(this, draft.dns);
            worker.execute(() -> {
                try {
                    if (CLEANED.compareAndSet(false, true)) {
                        File[] old = getNoBackupFilesDir().listFiles((dir, name) -> name.matches("v-[a-f0-9]{32}"));
                        if (old != null) for (File entry : old) RelaySession.remove(entry);
                    }
                    RelaySession.State ready = engine.start(this, draft.source, draft.node, draft.mode,
                            draft.rules, draft.options, transport);
                    MAIN.post(() -> {
                        if (ending || owner != this) return;
                        if (!transport.healthy()) { finish(R.string.vpn_ended); return; }
                        confirmed(ready);
                        MAIN.postDelayed(watch, 450);
                    });
                } catch (Exception | LinkageError failure) { MAIN.post(() -> finish(R.string.vpn_failed)); }
                finally { draft.wipe(); }
            });
        } else if (owner != this) stopSelf(startId);
        return START_NOT_STICKY;
    }

    private void updateNotification(int state) {
        if (foreground) getSystemService(NotificationManager.class).notify(NOTIFICATION, notification(state));
    }

    private Notification notification(int state) {
        // Only these generic phases may be shown outside CLAY. In particular, vpn_ready
        // is formatted for the app panel and includes selection information.
        int text = state == R.string.vpn_starting || state == R.string.vpn_updating || state == R.string.vpn_stopping
                ? state : R.string.vpn_notification_active;
        PendingIntent open = PendingIntent.getActivity(this, 1, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder notice = new Notification.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.ic_lock_lock)
                .setContentTitle(getString(R.string.vpn_title)).setContentText(getString(text))
                .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_SECRET);
        if (notificationStop != null) {
            notice.addAction(new Notification.Action.Builder(null, getString(R.string.vpn_stop), notificationStop).build());
        }
        return notice.build();
    }

    private void change(int node, String mode) {
        if (ending || snapshot.busy || snapshot.node == 0) return;
        publish(new Snapshot(R.string.vpn_updating, 0, null, true));
        worker.execute(() -> {
            try {
                RelaySession.State current = engine.refresh();
                if (!engine.contains(node)) { MAIN.post(() -> {
                    if (!ending && owner == this) publish(new Snapshot(R.string.relay_invalid, current.node, current.mode, false, current.labels));
                }); return; }
                RelaySession.State confirmed = engine.change(node, mode);
                MAIN.post(() -> { if (!ending && owner == this) confirmed(confirmed); });
            } catch (Exception failure) { MAIN.post(() -> finish(R.string.vpn_failed)); }
        });
    }

    private void confirmed(RelaySession.State state) {
        publish(new Snapshot(R.string.vpn_ready, state.node, state.mode, false, state.labels));
    }

    private void finish(int message) {
        if (ending || owner != this) return;
        ending = true;
        stopIdentity = null;
        if (notificationStop != null) {
            notificationStop.cancel();
            notificationStop = null;
        }
        publish(new Snapshot(R.string.vpn_stopping, 0, null, true));
        MAIN.removeCallbacks(watch);
        if (transport != null) transport.close();
        worker.execute(() -> {
            int result = message;
            try { engine.close(); }
            catch (Exception failure) { result = R.string.vpn_cleanup_failed; }
            final int status = result;
            MAIN.post(() -> {
                if (owner != this) return;
                terminalMessage = status;
                foreground = false;
                stopForeground(STOP_FOREGROUND_REMOVE);
                if (destroyed) publishTerminal();
                else stopSelf();
            });
        });
    }

    @Override public void onRevoke() { MAIN.post(() -> finish(R.string.vpn_revoked)); }

    private void publishTerminal() {
        if (owner == this && terminalMessage != 0) {
            owner = null;
            publish(new Snapshot(terminalMessage, 0, null, false));
        }
    }

    @Override public void onDestroy() {
        destroyed = true;
        publishTerminal();
        finish(R.string.vpn_ended);
        worker.shutdown();
        super.onDestroy();
    }
}
