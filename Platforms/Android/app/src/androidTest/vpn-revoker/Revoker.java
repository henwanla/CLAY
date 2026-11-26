package org.clayrelay.vpnrevoker;

import android.app.Activity;
import android.app.Instrumentation;
import android.net.VpnService;
import android.os.Bundle;

/** Transfers VPN authorization to this separate package without establishing a tunnel. */
public final class Revoker extends Instrumentation {
    public static final class Holder extends VpnService { }

    @Override public void onCreate(Bundle args) {
        super.onCreate(args);
        boolean prepared = VpnService.prepare(getTargetContext()) == null;
        Bundle report = new Bundle();
        report.putString("stream", prepared ? "\nCLAY_ANDROID_REPLACEMENT_PREPARED\n" : "\nVPN fixture lacks consent\n");
        finish(prepared ? Activity.RESULT_OK : Activity.RESULT_CANCELED, report);
    }
}
