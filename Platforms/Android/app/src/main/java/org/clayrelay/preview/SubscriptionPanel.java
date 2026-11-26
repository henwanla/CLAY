package org.clayrelay.preview;

import android.app.Activity;
import android.app.AlertDialog;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.text.InputFilter;
import android.text.InputType;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.Spinner;
import android.widget.TextView;
import java.net.URI;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

final class SubscriptionPanel {
    static final int ID_LABEL = 0x5140, ID_URL = 0x5141, ID_ADD = 0x5142, ID_LIST = 0x5143,
            ID_REFRESH = 0x5144, ID_USE = 0x5145, ID_REMOVE = 0x5146, ID_MANUAL = 0x5147,
            ID_STATUS = 0x5148, ID_SOURCE = 0x5149;
    private enum Job { LIST, ADD, REFRESH, USE, REMOVE }
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Activity activity;
    private final NodeInput nodes;
    private final SubscriptionStore store;
    private final EditText label, url;
    private final Spinner selector;
    private final Button add, refresh, use, remove, manual;
    private final TextView status, source;
    private List<SubscriptionStore.Info> feeds = Collections.emptyList();
    private boolean busy, destroyed;

    SubscriptionPanel(Activity activity, LinearLayout card, NodeInput nodes) {
        this.activity = activity; this.nodes = nodes;
        store = new SubscriptionStore(activity.getApplicationContext());
        TextView description = new TextView(activity);
        description.setText(R.string.subscription_intro);
        card.addView(description);
        label = field(card, ID_LABEL, R.string.subscription_label, InputType.TYPE_CLASS_TEXT, SubscriptionStore.MAX_LABEL);
        url = field(card, ID_URL, R.string.subscription_url,
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD, SubscriptionDownload.MAX_URL);
        add = button(card, ID_ADD, R.string.subscription_add);
        selector = new Spinner(activity);
        selector.setId(ID_LIST); selector.setSaveEnabled(false);
        selector.setContentDescription(activity.getString(R.string.subscription_title));
        card.addView(selector);
        refresh = button(card, ID_REFRESH, R.string.subscription_refresh);
        use = button(card, ID_USE, R.string.subscription_use);
        remove = button(card, ID_REMOVE, R.string.subscription_remove);
        manual = button(card, ID_MANUAL, R.string.subscription_manual);
        status = output(card, ID_STATUS);
        source = output(card, ID_SOURCE);
        selector.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            public void onItemSelected(AdapterView<?> parent, View view, int position, long id) { buttons(); }
            public void onNothingSelected(AdapterView<?> parent) { buttons(); }
        });
        add.setOnClickListener(v -> {
            try {
                String name = SubscriptionStore.label(label.getText().toString());
                URI address = SubscriptionDownload.address(url.getText().toString());
                queue(Job.ADD, null, name, address);
            } catch (Exception e) { status.setText(R.string.subscription_invalid); }
        });
        refresh.setOnClickListener(v -> action(Job.REFRESH));
        use.setOnClickListener(v -> action(Job.USE));
        remove.setOnClickListener(v -> {
            SubscriptionStore.Info selected = current();
            if (selected != null) new AlertDialog.Builder(activity)
                    .setMessage(R.string.subscription_confirm_remove)
                    .setNegativeButton(android.R.string.cancel, null)
                    .setPositiveButton(R.string.subscription_remove, (dialog, choice) -> queue(Job.REMOVE, selected, null, null))
                    .show();
        });
        manual.setOnClickListener(v -> { nodes.clearSubscription(); showSource(); buttons(); });
        showSource();
        queue(Job.LIST, null, null, null);
    }

    private void action(Job job) {
        SubscriptionStore.Info selected = current();
        if (selected != null && selected.readable()) queue(job, selected, null, null);
    }

    private EditText field(LinearLayout parent, int id, int text, int type, int limit) {
        EditText field = new EditText(activity);
        field.setId(id); field.setSaveEnabled(false); field.setSaveFromParentEnabled(false);
        field.setSingleLine(true); field.setInputType(type | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        field.setHint(text); field.setContentDescription(activity.getString(text));
        field.setFilters(new InputFilter[] { new InputFilter.LengthFilter(limit) });
        field.setImeOptions(EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);
        if (Build.VERSION.SDK_INT >= 26) field.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
        parent.addView(field);
        return field;
    }

    private Button button(LinearLayout parent, int id, int text) {
        Button button = new Button(activity);
        button.setId(id); button.setText(text); button.setAllCaps(false); button.setSaveEnabled(false);
        parent.addView(button);
        return button;
    }

    private TextView output(LinearLayout parent, int id) {
        TextView field = new TextView(activity);
        field.setId(id); field.setSaveEnabled(false);
        field.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        parent.addView(field);
        return field;
    }

    private SubscriptionStore.Info current() {
        int position = selector.getSelectedItemPosition();
        return position >= 0 && position < feeds.size() ? feeds.get(position) : null;
    }

    private void buttons() {
        SubscriptionStore.Info selected = current();
        selector.setEnabled(!busy && !feeds.isEmpty());
        add.setEnabled(!busy && feeds.size() < SubscriptionStore.LIMIT);
        label.setEnabled(!busy); url.setEnabled(!busy);
        refresh.setEnabled(!busy && selected != null && selected.readable());
        use.setEnabled(!busy && selected != null && selected.readable());
        remove.setEnabled(!busy && selected != null);
        manual.setEnabled(!busy && nodes.subscriptionID() != null);
    }

    private void reload(List<SubscriptionStore.Info> updated, String selected) {
        feeds = updated;
        ArrayList<String> rows = new ArrayList<>();
        int position = 0;
        for (SubscriptionStore.Info feed : feeds) {
            if (feed.id.equals(selected)) position = rows.size();
            rows.add(feed.readable() ? activity.getString(R.string.subscription_row, feed.label, feed.count)
                    : activity.getString(R.string.subscription_unreadable));
        }
        if (rows.isEmpty()) rows.add(activity.getString(R.string.subscription_empty));
        selector.setAdapter(new ArrayAdapter<>(activity, android.R.layout.simple_spinner_dropdown_item, rows));
        selector.setSelection(position);
    }

    private void showSource() {
        String selected = nodes.subscriptionLabel();
        source.setText(selected == null ? activity.getString(R.string.subscription_using_manual)
                : activity.getString(R.string.subscription_using_feed, selected));
    }

    private void queue(Job job, SubscriptionStore.Info target, String name, URI address) {
        if (destroyed || busy) return;
        busy = true;
        buttons();
        status.setText(job == Job.ADD || job == Job.REFRESH ? R.string.subscription_downloading : R.string.running);
        worker.execute(() -> {
            String id = target == null ? null : target.id;
            List<SubscriptionStore.Info> catalog = null;
            SubscriptionStore.Record loaded = null;
            int message = 0;
            try {
                switch (job) {
                    case ADD:
                        try (SubscriptionDownload.Nodes nodes = SubscriptionDownload.fetch(address)) { id = store.add(name, address, nodes).id; }
                        message = R.string.subscription_saved;
                        break;
                    case REFRESH:
                        try (SubscriptionStore.Record previous = store.read(id);
                             SubscriptionDownload.Nodes nodes = SubscriptionDownload.fetch(previous.url)) { store.refresh(previous, nodes); }
                        message = R.string.subscription_saved;
                        break;
                    case USE:
                        loaded = store.read(id);
                        break;
                    case REMOVE:
                        store.remove(id);
                        message = R.string.subscription_removed;
                        break;
                    case LIST: break;
                }
                if (job != Job.USE) catalog = store.list();
            } catch (SubscriptionDownload.Failure error) { message = failure(error.reason); }
            catch (Exception | LinkageError error) { message = R.string.subscription_failed; }
            SubscriptionStore.Record delivery = loaded;
            List<SubscriptionStore.Info> entries = catalog;
            int statusText = message;
            String selected = id;
            main.post(() -> {
                try (SubscriptionStore.Record record = delivery) {
                    if (destroyed) return;
                    if (entries != null) reload(entries, selected);
                    if (record != null) nodes.use(record);
                    if (job == Job.REMOVE && statusText == R.string.subscription_removed && selected.equals(nodes.subscriptionID())) {
                        nodes.clearSubscription();
                    }
                    if (job == Job.ADD && statusText == R.string.subscription_saved) { label.setText(""); url.setText(""); }
                    status.setText(statusText == 0 ? "" : activity.getString(statusText));
                    showSource();
                    busy = false;
                    buttons();
                }
            });
        });
    }

    private static int failure(SubscriptionDownload.Reason reason) {
        switch (reason) {
            case ADDRESS: return R.string.subscription_invalid;
            case REDIRECT: return R.string.subscription_redirect;
            case SIZE: return R.string.subscription_size;
            case CONTENT: return R.string.subscription_content;
            default: return R.string.subscription_failed;
        }
    }

    void destroy() {
        destroyed = true;
        worker.shutdownNow();
        nodes.clearSubscription();
        url.setText("");
    }
}
