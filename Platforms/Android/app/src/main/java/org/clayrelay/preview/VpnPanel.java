package org.clayrelay.preview;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.VpnService;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.view.View;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.Spinner;
import android.widget.TextView;
import java.nio.charset.StandardCharsets;

final class VpnPanel {
    static final int CONSENT = 590, NOTICES = 592;
    static final int ID_START = 0x5120, ID_STOP = 0x5121, ID_APPLY = 0x5122, ID_STATE = 0x5123,
            ID_DNS = 0x5124, ID_NODE = 0x5125, ID_MODE = 0x5126;
    private static final String[] MODES = {"rule", "global", "direct"};
    private static final int[] MODE_TEXT = {R.string.relay_rule, R.string.relay_global, R.string.relay_direct};
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Activity activity;
    private final EditText source, rules, index, dns;
    private final CheckBox direct, bypass;
    private final Spinner mode;
    private final Button start, apply, stop;
    private final TextView status;
    private ClayVpnService.Snapshot last;
    private boolean asks, askedNotifications;

    VpnPanel(Activity activity, LinearLayout card, EditText source, EditText rules, CheckBox direct, CheckBox bypass) {
        this.activity = activity; this.source = source; this.rules = rules; this.direct = direct; this.bypass = bypass;
        TextView prompt = new TextView(activity);
        prompt.setText(R.string.vpn_intro);
        card.addView(prompt);
        dns = field(card, ID_DNS, R.string.vpn_dns, InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        index = field(card, ID_NODE, R.string.relay_index, InputType.TYPE_CLASS_NUMBER);
        index.setText("1");
        mode = new Spinner(activity);
        mode.setId(ID_MODE); mode.setSaveEnabled(false);
        mode.setContentDescription(activity.getString(R.string.relay_mode));
        mode.setAdapter(new ArrayAdapter<>(activity, android.R.layout.simple_spinner_dropdown_item,
                new String[] {activity.getString(MODE_TEXT[0]), activity.getString(MODE_TEXT[1]), activity.getString(MODE_TEXT[2])}));
        card.addView(mode);
        start = button(card, ID_START, R.string.vpn_start);
        apply = button(card, ID_APPLY, R.string.relay_apply);
        stop = button(card, ID_STOP, R.string.vpn_stop);
        status = new TextView(activity);
        status.setId(ID_STATE); status.setSaveEnabled(false);
        status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        card.addView(status);
        start.setOnClickListener(v -> start());
        apply.setOnClickListener(v -> {
            int node = selected();
            if (node == 0) status.setText(R.string.relay_invalid);
            else ClayVpnService.apply(node, MODES[mode.getSelectedItemPosition()]);
        });
        stop.setOnClickListener(v -> ClayVpnService.stopFromPanel());
        render();
        main.postDelayed(tick, 250);
    }

    private final Runnable tick = new Runnable() {
        @Override public void run() { render(); main.postDelayed(this, 250); }
    };
    void destroy() { main.removeCallbacks(tick); }

    private void render() {
        ClayVpnService.Snapshot next = ClayVpnService.state();
        boolean connected = next.node > 0;
        start.setEnabled(!asks && !next.busy && !connected);
        dns.setEnabled(!asks && !next.busy && !connected);
        apply.setEnabled(!next.busy && connected);
        stop.setEnabled(ClayVpnService.canStop());
        if (next == last) return;
        last = next;
        if (connected) {
            index.setText(Integer.toString(next.node));
            int position = next.mode.equals("rule") ? 0 : next.mode.equals("global") ? 1 : 2;
            mode.setSelection(position);
            String active = activity.getString(R.string.vpn_ready, next.node, activity.getString(MODE_TEXT[position]));
            status.setText(next.message == R.string.vpn_ready ? active : active + "\n" + activity.getString(next.message));
        } else status.setText(next.message);
    }

    private EditText field(LinearLayout card, int id, int title, int type) {
        EditText field = new EditText(activity);
        field.setId(id); field.setSaveEnabled(false); field.setSingleLine(true); field.setInputType(type);
        field.setImeOptions(android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);
        field.setHint(title); field.setContentDescription(activity.getString(title));
        if (Build.VERSION.SDK_INT >= 26) field.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
        card.addView(field);
        return field;
    }

    private Button button(LinearLayout card, int id, int title) {
        Button button = new Button(activity);
        button.setId(id); button.setText(title); button.setAllCaps(false);
        card.addView(button);
        return button;
    }

    private int selected() {
        try {
            int value = Integer.parseInt(index.getText().toString().trim());
            return value >= 1 && value <= 100 ? value : 0;
        } catch (NumberFormatException invalid) { return 0; }
    }

    private void start() {
        if (!validRequest()) { status.setText(R.string.vpn_invalid); return; }
        if (Build.VERSION.SDK_INT >= 33 && !askedNotifications && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            asks = true; askedNotifications = true;
            activity.requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, NOTICES);
            render();
        } else requestVpn();
    }

    void requestVpn() {
        asks = false;
        try {
            Intent approval = VpnService.prepare(activity);
            if (approval == null) granted(true);
            else {
                asks = true;
                activity.startActivityForResult(approval, CONSENT);
            }
        } catch (RuntimeException failure) { asks = false; status.setText(R.string.vpn_failed); }
        render();
    }

    void granted(boolean allowed) {
        asks = false;
        if (!allowed) status.setText(R.string.vpn_denied);
        else if (!validRequest()) status.setText(R.string.vpn_invalid);
        else ClayVpnService.begin(activity, new ClayVpnService.Draft(source.getText().toString().getBytes(StandardCharsets.UTF_8),
                selected(), MODES[mode.getSelectedItemPosition()], rules.getText().toString(),
                (direct.isChecked() ? 1 : 0) | (bypass.isChecked() ? 2 : 0), dns.getText().toString().trim()));
        render();
    }

    private boolean validRequest() {
        String server = dns.getText().toString().trim();
        if (!server.matches("(0|[1-9][0-9]{0,2})(\\.(0|[1-9][0-9]{0,2})){3}")) return false;
        String[] parts = server.split("\\.");
        for (String part : parts) if (Integer.parseInt(part) > 255) return false;
        int first = Integer.parseInt(parts[0]);
        return first > 0 && first != 127 && first < 224 && !server.startsWith("198.18.0.") && selected() != 0
                && source.length() > 0 && source.length() <= 2 * 1024 * 1024 && rules.length() <= 12_000;
    }
}
