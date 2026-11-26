package org.clayrelay.preview;

import android.app.PendingIntent;
import android.content.Intent;
import android.os.Build;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
import java.lang.ref.WeakReference;

/** An optional Quick Settings entry point; never starts a VPN from cached data. */
public final class ClayVpnTile extends TileService {
    enum Action { OPEN, WAIT, STOP }

    // Like VpnService, TileService delivers these callbacks on the main thread.
    // Use passive listening so System UI rebinds and reads fresh state after process death.
    private static WeakReference<ClayVpnTile> listening = new WeakReference<>(null);

    private ClayVpnService.Snapshot presented;

    static Action action(ClayVpnService.Snapshot state) {
        return state.busy ? Action.WAIT : state.node > 0 ? Action.STOP : Action.OPEN;
    }

    static void refresh(ClayVpnService.Snapshot state) {
        ClayVpnTile tile = listening.get();
        if (tile != null) tile.render(state);
    }

    @Override public void onStartListening() {
        super.onStartListening();
        listening = new WeakReference<>(this);
        render(ClayVpnService.state());
    }

    @Override public void onStopListening() {
        if (listening.get() == this) listening.clear();
        presented = null;
        super.onStopListening();
    }

    @Override public void onDestroy() {
        if (listening.get() == this) listening.clear();
        super.onDestroy();
    }

    @Override public void onClick() {
        super.onClick();
        ClayVpnService.Snapshot shown = presented;
        if (shown == null) return;
        Action requested = action(shown);
        if (requested == Action.WAIT) return;
        unlockAndRun(() -> {
            if (requested == Action.STOP) ClayVpnService.stopFromTile(shown);
            else showApp();
        });
    }

    private void showApp() {
        Intent open = new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 3, open, PendingIntent.FLAG_IMMUTABLE));
        } else startActivityAndCollapse(open);
    }

    private void render(ClayVpnService.Snapshot state) {
        Tile tile = getQsTile();
        if (tile == null) return;
        Action action = action(state);
        String title = getString(R.string.vpn_tile_title);
        String detail = getString(action == Action.STOP ? R.string.vpn_stop :
                action == Action.WAIT ? R.string.vpn_tile_waiting : R.string.vpn_tile_open);
        String label = getString(R.string.vpn_tile_detail, title, detail);
        tile.setState(action == Action.STOP ? Tile.STATE_ACTIVE :
                action == Action.WAIT ? Tile.STATE_UNAVAILABLE : Tile.STATE_INACTIVE);
        tile.setLabel(Build.VERSION.SDK_INT >= 29 ? title : label);
        if (Build.VERSION.SDK_INT >= 29) tile.setSubtitle(detail);
        tile.setContentDescription(label);
        tile.updateTile();
        presented = state;
    }
}
