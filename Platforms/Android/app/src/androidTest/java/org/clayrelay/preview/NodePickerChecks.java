package org.clayrelay.preview;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.Instrumentation;
import android.os.SystemClock;
import android.view.WindowManager;
import android.widget.ListView;
import java.lang.reflect.Field;

final class NodePickerChecks {
    static void choose(Instrumentation test, Activity activity, int id, int number, String name) {
        final Field dialog;
        try { dialog = NodePicker.class.getDeclaredField("dialog"); dialog.setAccessible(true); }
        catch (ReflectiveOperationException e) { throw new AssertionError("locate in-app picker dialog", e); }
        NodePicker picker = activity.findViewById(id);
        test.runOnMainSync(() -> {
            require(picker.isEnabled(), "node picker is available");
            picker.performClick();
        });
        boolean[] picked = new boolean[1];
        for (int attempt = 0; attempt < 100 && !picked[0]; attempt++) {
            test.runOnMainSync(() -> {
                AlertDialog shown;
                try { shown = (AlertDialog) dialog.get(picker); }
                catch (ReflectiveOperationException e) { throw new AssertionError("read picker dialog", e); }
                if (shown == null) return;
                require((shown.getWindow().getAttributes().flags & WindowManager.LayoutParams.FLAG_SECURE) != 0,
                        "node list requires a protected window");
                ListView rows = shown.getListView();
                require(rows.getCount() >= number, "node exists in the current list");
                String label = rows.getItemAtPosition(number - 1).toString();
                require(label.contains(name) && !label.contains("://") && !label.contains("127.0.0.1"),
                        "local node name is shown without a structured endpoint");
                require(rows.performItemClick(null, number - 1, rows.getItemIdAtPosition(number - 1)), "node choice applied in dialog");
                require(picker.selected() == number && picker.getText().toString().contains(name), "button reflects the chosen node");
                picked[0] = true;
            });
            if (!picked[0]) SystemClock.sleep(50);
        }
        require(picked[0], "node list opened");
    }

    private static void require(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
