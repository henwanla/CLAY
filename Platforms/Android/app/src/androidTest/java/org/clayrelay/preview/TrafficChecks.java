package org.clayrelay.preview;

import android.app.Activity;
import android.app.Instrumentation;
import android.os.SystemClock;
import android.text.format.Formatter;
import android.view.View;
import android.widget.TextView;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class TrafficChecks {
    static void await(Instrumentation test, Activity activity, int id, boolean nonzero) {
        String zero = Formatter.formatFileSize(activity, 0);
        Pattern totals = row(activity, R.string.session_traffic_totals);
        Pattern rates = row(activity, R.string.session_traffic_rates);
        long deadline = SystemClock.elapsedRealtime() + 6000;
        while (SystemClock.elapsedRealtime() < deadline) {
            String[] lines = new String[1];
            test.runOnMainSync(() -> {
                TextView view = activity.findViewById(id);
                if (view.getVisibility() == View.VISIBLE) lines[0] = view.getText().toString();
            });
            if (lines[0] != null) {
                String[] rows = lines[0].split("\n", -1);
                if (rows.length == 2) {
                    Matcher amounts = totals.matcher(rows[0]);
                    if (amounts.matches() && rates.matcher(rows[1]).matches() &&
                            (!amounts.group(1).equals(zero)) == nonzero && (!amounts.group(2).equals(zero)) == nonzero) return;
                }
            }
            SystemClock.sleep(85);
        }
        throw new AssertionError(nonzero ? "live session did not show traffic in both directions" : "fresh Relay totals were not zero");
    }

    static void cleared(Instrumentation test, Activity activity, int id) {
        test.runOnMainSync(() -> {
            TextView view = activity.findViewById(id);
            if (view.getVisibility() != View.GONE || view.length() != 0) {
                throw new AssertionError("inactive session displayed stale traffic");
            }
        });
    }

    private static Pattern row(Activity activity, int format) {
        String template = activity.getString(format, "{UP}", "{DOWN}");
        return Pattern.compile(Pattern.quote(template).replace("{UP}", "\\E(.+?)\\Q").replace("{DOWN}", "\\E(.+?)\\Q"));
    }
}
