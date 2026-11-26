package org.clayrelay.preview;

import android.app.Activity;
import android.content.res.ColorStateList;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.Arrays;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public final class MainActivity extends Activity {
    static final int ID_NODE_INPUT = 0x5101, ID_NODE_RUN = 0x5102, ID_NODE_RESULT = 0x5103;
    static final int ID_PAC_RULES = 0x5104, ID_PAC_TARGET = 0x5105, ID_PAC_DIRECT = 0x5106;
    static final int ID_PAC_BYPASS = 0x5107, ID_PAC_RUN = 0x5108, ID_PAC_RESULT = 0x5109;
    private static final int MAX_SOURCE = 2 * 1024 * 1024, MAX_TARGET = 16_384;
    private final ExecutorService workers = Executors.newSingleThreadExecutor();
    private RelayPanel relay;
    private VpnPanel vpn;
    private SubscriptionPanel subscription;
    private NodeInput nodeSource;
    private Action nodeAction, pacAction;
    private int ink, muted, accent;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        ink = getColor(R.color.ink);
        muted = getColor(R.color.muted);
        accent = getColor(R.color.accent);

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setSaveEnabled(false);
        if (Build.VERSION.SDK_INT >= 26) {
            scroll.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
        }
        if (Build.VERSION.SDK_INT >= 29) {
            scroll.setImportantForContentCapture(View.IMPORTANT_FOR_CONTENT_CAPTURE_NO_EXCLUDE_DESCENDANTS);
        }
        LinearLayout list = column();
        list.setPadding(dp(18), dp(18), dp(18), dp(22));
        list.setFocusableInTouchMode(true);
        scroll.addView(list);
        setContentView(scroll);
        if (Build.VERSION.SDK_INT >= 30) {
            getWindow().setDecorFitsSystemWindows(false);
            scroll.setOnApplyWindowInsetsListener((view, windowInsets) -> {
                Insets insets = windowInsets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout()
                        | WindowInsets.Type.ime());
                view.setPadding(insets.left, insets.top, insets.right, insets.bottom);
                return windowInsets;
            });
            scroll.requestApplyInsets();
        }
        add(list, label(getString(BuildFlavor.VPN ? R.string.vpn_eyebrow : R.string.eyebrow), 13, accent, true), 0);
        add(list, label(getString(R.string.app_name), 36, ink, true), 4);
        add(list, label(getString(BuildFlavor.VPN ? R.string.vpn_intro_top : R.string.intro), 15, muted, false), 7);

        LinearLayout nodes = card(list, R.string.nodes_title);
        EditText nodeInput = input(nodes, ID_NODE_INPUT, R.string.nodes_label, R.string.nodes_hint, 4);
        nodeSource = new NodeInput(nodeInput);
        nodeAction = new Action(nodes, ID_NODE_RUN, R.string.nodes_run, ID_NODE_RESULT);
        nodeAction.run.setOnClickListener(v -> nodeAction.start(0, nodeInput, null, 0));
        nodeAction.clear.setOnClickListener(v -> { nodeInput.setText(""); nodeAction.reset(); });
        if (BuildFlavor.RELAY || BuildFlavor.VPN) {
            subscription = new SubscriptionPanel(this, card(list, R.string.subscription_title), nodeSource);
        }

        LinearLayout pac = card(list, R.string.pac_title);
        EditText rules = input(pac, ID_PAC_RULES, R.string.pac_rules, R.string.pac_hint, 3);
        EditText target = input(pac, ID_PAC_TARGET, R.string.pac_target, R.string.pac_target_hint, 1);
        CheckBox direct = option(pac, ID_PAC_DIRECT, R.string.pac_direct, false);
        CheckBox bypass = option(pac, ID_PAC_BYPASS, R.string.pac_bypass, true);
        pacAction = new Action(pac, ID_PAC_RUN, R.string.pac_run, ID_PAC_RESULT);
        pacAction.run.setOnClickListener(v -> pacAction.start(1, rules, target,
                (direct.isChecked() ? 1 : 0) | (bypass.isChecked() ? 2 : 0)));
        pacAction.clear.setOnClickListener(v -> { rules.setText(""); target.setText(""); pacAction.reset(); });
        if (BuildFlavor.RELAY) relay = new RelayPanel(this, card(list, R.string.relay_title), nodeSource, rules, direct, bypass);
        if (BuildFlavor.VPN) vpn = new VpnPanel(this, card(list, R.string.vpn_title), nodeSource, rules, direct, bypass);
        list.requestFocus();
    }

    @Override protected void onPause() {
        if (relay != null) { relay.hideCredentials(); relay.hidePicker(); }
        if (vpn != null) vpn.hidePicker();
        super.onPause();
    }

    @Override protected void onActivityResult(int request, int result, android.content.Intent data) {
        super.onActivityResult(request, result, data);
        if (vpn != null && request == VpnPanel.CONSENT) vpn.granted(result == RESULT_OK);
    }

    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(request, permissions, grants);
        if (vpn != null && request == VpnPanel.NOTICES) vpn.requestVpn();
    }

    @Override protected void onDestroy() {
        if (vpn != null) vpn.destroy();
        if (relay != null) relay.destroy();
        if (subscription != null) subscription.destroy();
        if (nodeAction != null) nodeAction.cancel();
        if (pacAction != null) pacAction.cancel();
        workers.shutdownNow();
        super.onDestroy();
    }

    private final class Action {
        final Button run, clear;
        final TextView result;
        private Future<?> task;
        private AtomicReference<byte[]> pending;
        private int generation;

        Action(LinearLayout card, int runId, int runLabel, int resultId) {
            LinearLayout buttons = new LinearLayout(MainActivity.this);
            run = new Button(MainActivity.this);
            run.setId(runId);
            run.setText(runLabel);
            run.setAllCaps(false);
            run.setTextColor(0xFFFFFFFF);
            run.setBackgroundTintList(new ColorStateList(new int[][] {{-android.R.attr.state_enabled}, {}},
                    new int[] {muted, accent}));
            buttons.addView(run, new LinearLayout.LayoutParams(0, -2, 1));
            clear = new Button(MainActivity.this, null, android.R.attr.borderlessButtonStyle);
            clear.setText(R.string.clear);
            clear.setAllCaps(false);
            clear.setTextColor(accent);
            buttons.addView(clear);
            add(card, buttons, 8);
            result = label("", 15, ink, false);
            result.setId(resultId);
            result.setSaveEnabled(false);
            result.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
            result.setVisibility(View.GONE);
            add(card, result, 7);
        }

        void cancel() {
            generation++;
            if (task != null) task.cancel(false);
            if (pending != null) {
                byte[] queued = pending.getAndSet(null);
                if (queued != null) Arrays.fill(queued, (byte) 0);
            }
            task = null;
            pending = null;
        }

        void reset() {
            cancel();
            result.setText("");
            result.setVisibility(View.GONE);
            run.setEnabled(true);
        }

        void start(int operation, EditText sourceField, EditText targetField, int options) {
            final int id = ++generation;
            result.setVisibility(View.VISIBLE);
            if (operation != 0 && (sourceField.length() > MAX_SOURCE || (targetField != null && targetField.length() > MAX_TARGET))) {
                result.setText(R.string.input_too_large);
                return;
            }
            final byte[] nodes = operation == 0 ? nodeSource.snapshot() : null;
            if (operation == 0 && nodes == null) { result.setText(R.string.input_too_large); return; }
            AtomicReference<byte[]> owned = new AtomicReference<>(nodes);
            pending = owned;
            String source = operation == 0 ? "" : sourceField.getText().toString();
            String target = targetField == null ? "" : targetField.getText().toString();
            result.setText(R.string.running);
            run.setEnabled(false);
            task = workers.submit(() -> {
                byte[] material = owned.getAndSet(null);
                if (operation == 0 && material == null) return;
                String resultText;
                try {
                    JSONObject report = new JSONObject(operation == 0 ? NativePreview.describe(material)
                            : NativePreview.run(operation, source, target, options));
                    String error = report.optString("error");
                    if (!error.isEmpty()) resultText = errorText(error, report.optInt("line"));
                    else resultText = operation == 0 ? nodesText(report) : pacText(report);
                } catch (JSONException | RuntimeException | LinkageError ignored) {
                    resultText = getString(R.string.failed);
                } finally { if (material != null) Arrays.fill(material, (byte) 0); }
                final String message = resultText;
                runOnUiThread(() -> {
                    if (id != generation || isDestroyed()) return;
                    task = null;
                    pending = null;
                    result.setText(message);
                    run.setEnabled(true);
                });
            });
        }
    }

    private String errorText(String error, int line) {
        switch (error) {
            case "inputTooLarge": return getString(R.string.input_too_large);
            case "invalidRule": return getString(R.string.pac_invalid_rule, line);
            case "invalidHost": return getString(R.string.pac_invalid_host);
            default: return getString(R.string.failed);
        }
    }

    private String nodesText(JSONObject report) throws JSONException {
        JSONArray nodes = report.getJSONArray("nodes");
        Map<String, Integer> counts = new LinkedHashMap<>();
        for (int i = 0; i < nodes.length(); i++) {
            JSONObject entry = nodes.getJSONObject(i);
            String protocol = entry.getString("protocol"), transport = entry.getString("transport"), security = entry.getString("security");
            String key = protocol + "/" + transport + "/" + security;
            Integer count = counts.get(key);
            counts.put(key, count == null ? 1 : count + 1);
        }
        StringBuilder summary = new StringBuilder(getString(R.string.nodes_count, nodes.length()));
        for (Map.Entry<String, Integer> group : counts.entrySet()) {
            String[] types = group.getKey().split("/", -1);
            if (types.length != 3) continue;
            summary.append('\n').append(getString(R.string.nodes_summary_row,
                    protocolLabel(types[0]), transportLabel(types[1]), securityLabel(types[2]), group.getValue()));
        }
        JSONObject issues = report.getJSONObject("issues");
        Iterator<String> keys = issues.keys();
        while (keys.hasNext()) {
            String key = keys.next();
            summary.append('\n').append(getString(R.string.nodes_issue_row, issueLabel(key), issues.getInt(key)));
        }
        return summary.toString();
    }

    private String protocolLabel(String protocol) {
        switch (protocol) {
            case "vless": return "VLESS";
            case "vmess": return "VMess";
            case "ss": return "Shadowsocks";
            case "trojan": return "Trojan";
            case "hysteria2": return "Hysteria2";
            case "tuic": return "TUIC";
            default: return "—";
        }
    }

    private String transportLabel(String transport) {
        switch (transport) {
            case "tcp": return "TCP";
            case "ws": return "WebSocket";
            case "grpc": return "gRPC";
            case "quic": return "QUIC";
            default: return "—";
        }
    }

    private String securityLabel(String security) {
        switch (security) {
            case "aead": return "AEAD";
            case "aead-2022": return "AEAD 2022";
            case "tls": return "TLS";
            case "reality": return "REALITY";
            case "none": return getString(R.string.security_none);
            default: return "—";
        }
    }

    private String issueLabel(String issue) {
        switch (issue) {
            case "malformed": return getString(R.string.issue_malformed);
            case "unsupportedProtocol": return getString(R.string.issue_protocol);
            case "unsupportedTransport": return getString(R.string.issue_transport);
            case "unsupportedOption": return getString(R.string.issue_option);
            case "invalidAccount": return getString(R.string.issue_account);
            case "notProxyOutbound": return getString(R.string.issue_not_proxy);
            default: return getString(R.string.issue_other);
        }
    }

    private String pacText(JSONObject report) throws JSONException {
        String reason;
        switch (report.getString("reason")) {
            case "rule": reason = getString(R.string.pac_reason_rule, report.getInt("rule")); break;
            case "loopback": reason = getString(R.string.pac_reason_loopback); break;
            case "local": reason = getString(R.string.pac_reason_local); break;
            case "fallback": reason = getString(R.string.pac_reason_fallback); break;
            default: throw new JSONException("unknown PAC reason");
        }
        String decision = report.getString("decision");
        if (!"DIRECT".equals(decision) && !"PROXY".equals(decision)) throw new JSONException("unknown PAC decision");
        return getString(R.string.pac_result, decision, reason, report.getInt("rules"));
    }

    private LinearLayout card(LinearLayout list, int title) {
        LinearLayout box = column();
        box.setBackground(shape(getColor(R.color.card)));
        box.setPadding(dp(16), dp(14), dp(16), dp(15));
        add(box, label(getString(title), 21, ink, true), 0);
        add(list, box, 17);
        return box;
    }

    private EditText input(LinearLayout parent, int id, int title, int hint, int rows) {
        TextView caption = label(getString(title), 14, muted, true);
        caption.setLabelFor(id);
        add(parent, caption, 12);
        EditText field = new EditText(this);
        field.setId(id);
        field.setHint(hint);
        field.setTextSize(15);
        field.setTextColor(ink);
        field.setHintTextColor(muted);
        field.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                | (rows > 1 ? InputType.TYPE_TEXT_FLAG_MULTI_LINE : InputType.TYPE_TEXT_VARIATION_URI));
        if (Build.VERSION.SDK_INT >= 26) {
            field.setImeOptions(field.getImeOptions() | EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);
        }
        field.setTypeface(Typeface.MONOSPACE);
        field.setMinLines(rows);
        field.setMaxLines(rows + 2);
        field.setGravity(android.view.Gravity.TOP | android.view.Gravity.START);
        field.setPadding(dp(10), dp(9), dp(10), dp(9));
        field.setBackground(shape(getColor(R.color.page)));
        field.setSaveEnabled(false);
        field.setSaveFromParentEnabled(false);
        add(parent, field, 5);
        return field;
    }

    private CheckBox option(LinearLayout parent, int id, int title, boolean checked) {
        CheckBox option = new CheckBox(this);
        option.setId(id);
        option.setText(title);
        option.setTextColor(ink);
        option.setChecked(checked);
        option.setSaveEnabled(false);
        add(parent, option, 0);
        return option;
    }

    private TextView label(String value, int size, int color, boolean strong) {
        TextView text = new TextView(this);
        text.setText(value);
        text.setTextSize(size);
        text.setTextColor(color);
        if (strong) text.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        return text;
    }

    private LinearLayout column() {
        LinearLayout result = new LinearLayout(this);
        result.setOrientation(LinearLayout.VERTICAL);
        return result;
    }

    private void add(LinearLayout parent, View child, int top) {
        LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(-1, -2);
        layout.topMargin = dp(top);
        parent.addView(child, layout);
    }

    private GradientDrawable shape(int fill) {
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(fill);
        shape.setCornerRadius(dp(12));
        shape.setStroke(dp(1), getColor(R.color.line));
        return shape;
    }

    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
}
