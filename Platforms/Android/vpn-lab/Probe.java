package org.clayrelay.vpnprobe;
import android.content.Intent;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.net.VpnService;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.util.Log;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import org.json.JSONArray;
import org.json.JSONObject;

/** Synthetic TUN data plane fixture; never included in a product APK. */
public final class Probe extends VpnService {
  private volatile java.lang.Process child;
  private volatile ParcelFileDescriptor tun;

  @Override public int onStartCommand(Intent i, int flags, int id) {
    if (i == null || !"org.clayrelay.vpnprobe.RUN".equals(i.getAction())) return START_NOT_STICKY;
    String tag = i.getStringExtra("tag");
    if (tag == null || !tag.matches("ClayVpn[0-9a-f]{12}")) return START_NOT_STICKY;
    new Thread(() -> {
      try { run(i, tag); }
      catch (Exception failure) { Log.e(tag, "test failed", failure); }
    }, "clay-vpn-probe").start();
    return START_NOT_STICKY;
  }
  private void run(Intent intent, String tag) throws Exception {
    if (VpnService.prepare(this) != null) throw new IOException("VPN consent required");
    File directory = new File(getNoBackupFilesDir(), "t-" + UUID.randomUUID().toString().substring(0,8));
    if (!directory.mkdir()) throw new IOException("mkdir");
    int fixturePort = intent.getIntExtra("port", 0);
    if (fixturePort < 1 || fixturePort > 65535) throw new IOException("fixture port missing");
    JSONObject proxy = new JSONObject().put("type","http").put("name","fixture").put("server","10.0.2.2").put("port",fixturePort);
    JSONObject tc = new JSONObject().put("enable",true).put("stack","gvisor").put("auto-route",false)
      .put("auto-detect-interface",false).put("file-descriptor",100).put("mtu",1500)
      .put("inet4-address",new JSONArray().put("198.18.0.1/30"));
    JSONObject cfg = new JSONObject().put("mode","rule").put("log-level","debug").put("geo-auto-update",false).put("tun",tc)
      .put("rules",new JSONArray().put("IP-CIDR,10.0.2.2/32,REJECT,no-resolve").put("MATCH,fixture")).put("proxies",new JSONArray().put(proxy));
    File config = new File(directory,"probe.json");
    try (FileOutputStream out = new FileOutputStream(config)) { out.write(cfg.toString().replace("\\/","/").getBytes(StandardCharsets.UTF_8)); }
    Builder builder = new Builder().setSession("CLAY isolated TUN experiment").setMtu(1500)
      .addAddress("198.18.0.1",30).addRoute("198.51.100.42",32);
    if (intent.getBooleanExtra("captureUpstream", false)) builder.addRoute("10.0.2.2", 32);
    tun = builder.establish();
    if (tun == null) throw new IOException("no tun");
    File lib = new File(getApplicationInfo().nativeLibraryDir);
    ProcessBuilder process = new ProcessBuilder(new File(lib, "liblauncher.so").getPath(),
      Integer.toString(android.os.Process.myPid()), new File(lib, "libmihomo.so").getPath(),
      directory.getPath(), config.getPath());
    process.environment().put("HOME", directory.getPath());
    process.environment().put("PATH", "/system/bin");
    child = process.directory(directory).redirectErrorStream(true).start();
    long deadline = SystemClock.elapsedRealtime() + 3000;
    boolean sent = false;
    while (SystemClock.elapsedRealtime() < deadline) {
      try (LocalSocket sock = new LocalSocket()) {
        sock.connect(new LocalSocketAddress(new File(directory,"t").getPath(), LocalSocketAddress.Namespace.FILESYSTEM));
        if (sock.getPeerCredentials().getUid() != android.os.Process.myUid()) throw new IOException("bad peer");
        sock.setFileDescriptorsForSend(new FileDescriptor[] { tun.getFileDescriptor() });
        sock.getOutputStream().write(42);
        sent = true; break;
      } catch (IOException x) { SystemClock.sleep(40); }
    }
    if (!sent) throw new IOException("failed to send FD");
    Log.i(tag, "fd transfer requested");
    try (BufferedReader lines = new BufferedReader(new InputStreamReader(child.getInputStream(), StandardCharsets.UTF_8))) {
      for (String line; (line = lines.readLine()) != null;) Log.i(tag,line);
    }
  }
  @Override public void onDestroy() {
    if (child != null) child.destroy();
    try { if (tun != null) tun.close(); } catch (IOException ignored) {}
    super.onDestroy();
  }
}
