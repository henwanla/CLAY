package org.clayrelay.vpnprobe;
import android.content.Intent;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.net.VpnService;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.system.ErrnoException;
import android.system.Os;
import android.util.Log;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import org.json.JSONArray;
import org.json.JSONObject;

/** Synthetic TUN data plane fixture; never included in a product APK. */
public final class Probe extends VpnService {
  private volatile java.lang.Process child;
  private volatile ParcelFileDescriptor tun;
  private volatile LocalSocket control;
  private volatile boolean stopping;

  @Override public int onStartCommand(Intent i, int flags, int id) {
    if (i == null || !"org.clayrelay.vpnprobe.RUN".equals(i.getAction())) return START_NOT_STICKY;
    String tag = i.getStringExtra("tag");
    if (tag == null || !tag.matches("ClayVpn[0-9a-f]{12}")) return START_NOT_STICKY;
    new Thread(() -> {
      try { run(i, tag); }
      catch (Exception failure) { if (!stopping) Log.e(tag, "test failed", failure); }
    }, "clay-vpn-probe").start();
    return START_NOT_STICKY;
  }
  private void run(Intent intent, String tag) throws Exception {
    if (VpnService.prepare(this) != null) throw new IOException("VPN consent required");
    File directory = new File(getNoBackupFilesDir(), "t-" + UUID.randomUUID().toString().substring(0,8));
    if (!directory.mkdir()) throw new IOException("mkdir");
    String protection = intent.getStringExtra("protection");
    if (!"off".equals(protection) && !"deny".equals(protection) && !"on".equals(protection)) {
      throw new IOException("invalid test mode");
    }
    int fixturePort = intent.getIntExtra("port", 0);
    int dnsPort = intent.getIntExtra("dnsPort", 0);
    if (fixturePort < 1 || fixturePort > 65535 || dnsPort < 1 || dnsPort > 65535) throw new IOException("fixture port missing");
    JSONObject proxy = new JSONObject().put("type","http").put("name","fixture").put("server","10.0.2.2").put("port",fixturePort);
    JSONObject tc = new JSONObject().put("enable",true).put("stack","gvisor").put("auto-route",false)
      .put("auto-detect-interface",false).put("file-descriptor",100).put("mtu",1500)
      .put("inet4-address",new JSONArray().put("198.18.0.1/30"));
    String resolver = "udp://10.0.2.2:" + dnsPort;
    JSONObject dns = new JSONObject().put("enable", true).put("enhanced-mode", "redir-host")
      .put("nameserver", new JSONArray().put(resolver)).put("default-nameserver", new JSONArray().put(resolver));
    JSONObject cfg = new JSONObject().put("mode","rule").put("log-level","debug").put("geo-auto-update",false).put("tun",tc).put("dns", dns)
      .put("rules",new JSONArray().put("IP-CIDR,10.0.2.2/32,REJECT,no-resolve").put("MATCH,fixture")).put("proxies",new JSONArray().put(proxy));
    File config = new File(directory,"probe.json");
    try (FileOutputStream out = new FileOutputStream(config)) { out.write(cfg.toString().replace("\\/","/").getBytes(StandardCharsets.UTF_8)); }
    Builder builder = new Builder().setSession("CLAY isolated TUN experiment").setMtu(1500)
      .addAddress("198.18.0.1",30).addRoute("198.51.100.42",32).addRoute("10.0.2.2", 32)
      .addRoute("198.18.0.2", 32).addDnsServer("198.18.0.2");
    tun = builder.establish();
    if (tun == null) throw new IOException("no tun");
    File lib = new File(getApplicationInfo().nativeLibraryDir);
    ProcessBuilder process = new ProcessBuilder(new File(lib, "liblauncher.so").getPath(),
      Integer.toString(android.os.Process.myPid()), new File(lib, "libmihomo.so").getPath(),
      directory.getPath(), config.getPath(), "off".equals(protection) ? "off" : "protect");
    process.environment().put("HOME", directory.getPath());
    process.environment().put("PATH", "/system/bin");
    java.lang.Process engine = process.directory(directory).redirectErrorStream(true).start();
    child = engine;
    Thread logs = new Thread(() -> {
      try (BufferedReader lines = new BufferedReader(new InputStreamReader(engine.getInputStream(), StandardCharsets.UTF_8))) {
        for (String line; (line = lines.readLine()) != null;) Log.i(tag, line);
      } catch (IOException failure) { if (!stopping) Log.e(tag, "test failed", failure); }
    }, "clay-vpn-probe-log");
    logs.start();
    try (LocalSocket sock = connectEngine(directory)) {
      control = sock;
      if (stopping) return;
      sock.setFileDescriptorsForSend(new FileDescriptor[] { tun.getFileDescriptor() });
      sock.getOutputStream().write(42);
      sock.setFileDescriptorsForSend(null);
      if (!"off".equals(protection)) protectSockets(sock, "deny".equals(protection), tag);
    } catch (IOException failure) {
      engine.destroy();
      throw failure;
    } finally {
      control = null;
    }
    // PR_SET_PDEATHSIG observes the Linux thread that spawned the launcher.
    // Keep this worker alive even when the descriptor channel isn't in use.
    engine.waitFor();
  }

  private LocalSocket connectEngine(File directory) throws IOException {
    long deadline = SystemClock.elapsedRealtime() + 3000;
    LocalSocketAddress endpoint = new LocalSocketAddress(new File(directory, "t").getPath(), LocalSocketAddress.Namespace.FILESYSTEM);
    while (!stopping && SystemClock.elapsedRealtime() < deadline) {
      LocalSocket socket = new LocalSocket();
      try { socket.connect(endpoint); }
      catch (IOException warmingUp) { socket.close(); SystemClock.sleep(40); continue; }
      try {
        if (socket.getPeerCredentials().getUid() == android.os.Process.myUid()) return socket;
      } catch (IOException invalidPeer) { socket.close(); throw invalidPeer; }
      socket.close();
      throw new IOException("bad peer");
    }
    throw new IOException("engine descriptor channel unavailable");
  }

  private void protectSockets(LocalSocket socket, boolean deny, String tag) throws IOException {
    InputStream input = socket.getInputStream();
    OutputStream output = socket.getOutputStream();
    for (int message; !stopping && (message = input.read()) != -1;) {
      FileDescriptor[] fds = socket.getAncillaryFileDescriptors();
      boolean valid = message == 0x50 && fds != null && fds.length == 1;
      boolean protectedSocket = false;
      try {
        if (valid && !deny) {
          try (ParcelFileDescriptor duplicate = ParcelFileDescriptor.dup(fds[0])) {
            protectedSocket = protect(duplicate.getFd());
          }
        }
      } finally {
        if (fds != null) for (FileDescriptor fd : fds) {
          try { Os.close(fd); } catch (ErrnoException invalid) { protectedSocket = false; }
        }
      }
      if (!valid) throw new IOException("invalid protection request");
      Log.i(tag, protectedSocket ? "CLAY_PROBE_PROTECT_OK" : "CLAY_PROBE_PROTECT_REJECTED");
      output.write(protectedSocket ? 1 : 0);
    }
  }

  @Override public void onDestroy() {
    stopping = true;
    LocalSocket socket = control;
    if (socket != null) {
      try { socket.shutdownInput(); } catch (IOException ignored) {}
      try { socket.close(); } catch (IOException ignored) {}
    }
    if (child != null) child.destroy();
    try { if (tun != null) tun.close(); } catch (IOException ignored) {}
    super.onDestroy();
  }
}
