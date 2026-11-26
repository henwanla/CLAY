package org.clayrelay.vpnprobe;
import android.app.Instrumentation;
import android.content.Intent;
import android.net.VpnService;
import android.os.Bundle;
import android.os.SystemClock;
public final class Check extends Instrumentation {
  private Bundle options;
  @Override public void onCreate(Bundle args) { super.onCreate(args); options = args; start(); }
  @Override public void onStart() {
    if (getTargetContext() == null || VpnService.prepare(getTargetContext()) != null) {
      Bundle r = new Bundle(); r.putString("stream", "consent not set"); finish(0, r); return;
    }
    Intent intent = new Intent(getTargetContext(), Probe.class).setAction("org.clayrelay.vpnprobe.RUN");
    intent.putExtra("tag", options.getString("tag"));
    intent.putExtra("port", Integer.parseInt(options.getString("port")));
    intent.putExtra("captureUpstream", Boolean.parseBoolean(options.getString("captureUpstream")));
    getTargetContext().startService(intent);
    SystemClock.sleep(8500);
    getTargetContext().stopService(intent);
    SystemClock.sleep(1200);
    finish(-1,new Bundle());
  }
}
