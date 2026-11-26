package org.clayrelay.preview;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.SystemClock;
import android.widget.Button;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.TextView;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/** Exercises the native Activity and Swift core using synthetic offline inputs. */
public final class PreviewInstrumentation extends Instrumentation {
    private Bundle arguments;

    @Override public void onCreate(Bundle args) {
        arguments = args;
        super.onCreate(args);
        start();
    }

    @Override public void onStart() {
        Bundle report = new Bundle();
        Activity activity = null;
        int result = Activity.RESULT_CANCELED;
        Context context = getTargetContext();
        String feed = null;
        try (RelayChecks.ShadowsocksFixture fixture = BuildFlavor.RELAY ? new RelayChecks.ShadowsocksFixture(context) : null) {
            boolean online = BuildFlavor.RELAY || BuildFlavor.VPN;
            if (online) SubscriptionChecks.run(context);
            if (fixture != null) feed = SubscriptionChecks.seed(context, fixture.nodes().getBytes(StandardCharsets.UTF_8));
            Intent intent = new Intent(Intent.ACTION_MAIN).setClassName(context, MainActivity.class.getName());
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity = startActivitySync(intent);
            exercise(activity);
            require((activity.findViewById(SubscriptionPanel.ID_ADD) != null) == online, "subscription UI restricted to online flavors");
            if (fixture != null) RelayChecks.run(this, activity, fixture);
            String vpnReport = BuildFlavor.VPN ? VpnChecks.run(this, activity, arguments) + "\n" : "";
            report.putString("stream", "\nCLAY_ANDROID_PREVIEW_PASS\n" + (BuildFlavor.RELAY ? "CLAY_ANDROID_RELAY_PASS\n" : "")
                    + (online ? "CLAY_ANDROID_SUBSCRIPTIONS_PASS\n" : "") + vpnReport);
            result = Activity.RESULT_OK;
        } catch (Exception | AssertionError e) {
            // The only data reported are test step labels, never runtime input.
            report.putString("stream", "\nCLAY_ANDROID_PREVIEW_FAIL: " +
                    (e instanceof AssertionError ? e.getMessage() : e.getClass().getSimpleName()) + "\n");
        } finally {
            if (feed != null) {
                try { new SubscriptionStore(context).remove(feed); }
                catch (java.io.IOException e) { result = Activity.RESULT_CANCELED; }
            }
            if (activity != null) runOnMainSync(activity::finish);
            finish(result, report);
        }
    }

    private void exercise(Activity activity) throws Exception {
        String credential = "56dc6c3e-8793-4d37-a363-f9f19db29c6d";
        String source = "vless://" + credential + "@example.test:443?type=ws&security=tls#機密テスト👋";
        String raw = NativePreview.run(0, source, "", 0);
        JSONObject node = new JSONObject(raw).getJSONArray("nodes").getJSONObject(0);
        require("vless".equals(node.getString("protocol")) && "ws".equals(node.getString("transport")) &&
                "tls".equals(node.getString("security")), "native node classification");
        require(!raw.contains(credential) && !raw.contains("example.test") && !raw.contains("機密"),
                "JNI redaction");
        runOnMainSync(() -> {
            edit(activity, MainActivity.ID_NODE_INPUT).setText(source);
            button(activity, MainActivity.ID_NODE_RUN).performClick();
        });
        String nodes = await(activity, MainActivity.ID_NODE_RUN, MainActivity.ID_NODE_RESULT);
        require(nodes.contains("VLESS") && !nodes.contains(credential) && !nodes.contains("機密"),
                "native Activity node preview and redaction");

        runOnMainSync(() -> {
            edit(activity, MainActivity.ID_PAC_RULES).setText("DOMAIN-SUFFIX,example.test,PROXY\nDOMAIN,host.example.test,DIRECT");
            edit(activity, MainActivity.ID_PAC_TARGET).setText("https://host.example.test/private");
            ((CompoundButton) activity.findViewById(MainActivity.ID_PAC_DIRECT)).setChecked(true);
            ((CompoundButton) activity.findViewById(MainActivity.ID_PAC_BYPASS)).setChecked(true);
            button(activity, MainActivity.ID_PAC_RUN).performClick();
        });
        String route = await(activity, MainActivity.ID_PAC_RUN, MainActivity.ID_PAC_RESULT);
        require(route.contains("PROXY") && !route.contains("host.example.test"), "PAC Activity first match");
        runOnMainSync(() -> {
            edit(activity, MainActivity.ID_PAC_TARGET).setText("https://unmatched.test");
            button(activity, MainActivity.ID_PAC_RUN).performClick();
        });
        require(await(activity, MainActivity.ID_PAC_RUN, MainActivity.ID_PAC_RESULT).contains("DIRECT"),
                "PAC Activity configurable fallback");
        JSONObject local = new JSONObject(NativePreview.run(1, "", "192.168.1.3", 2));
        require("DIRECT".equals(local.getString("decision")) && "local".equals(local.getString("reason")),
                "PAC native local bypass");
        JSONObject invalid = new JSONObject(NativePreview.run(1, "# sample\nBAD,sensitive.test,PROXY", "example.test", 0));
        require("invalidRule".equals(invalid.getString("error")) && invalid.getInt("line") == 2 &&
                !invalid.toString().contains("sensitive.test"), "PAC native sanitized parse failure");
    }

    private String await(Activity activity, int buttonId, int resultId) {
        long deadline = SystemClock.elapsedRealtime() + 10000;
        while (SystemClock.elapsedRealtime() < deadline) {
            String[] value = new String[1];
            runOnMainSync(() -> {
                TextView display = activity.findViewById(resultId);
                if (button(activity, buttonId).isEnabled()) value[0] = display.getText().toString();
            });
            if (value[0] != null) return value[0];
            SystemClock.sleep(25);
        }
        throw new AssertionError("preview timed out");
    }

    private static EditText edit(Activity activity, int id) { return activity.findViewById(id); }
    private static Button button(Activity activity, int id) { return activity.findViewById(id); }
    private static void require(boolean condition, String step) { if (!condition) throw new AssertionError(step); }
}
