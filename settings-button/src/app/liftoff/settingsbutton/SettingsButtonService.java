package app.liftoff.settingsbutton;

import android.accessibilityservice.AccessibilityService;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.util.Log;
import android.view.KeyEvent;
import android.view.accessibility.AccessibilityEvent;

public final class SettingsButtonService extends AccessibilityService {
    private static final int TCL_SETTINGS_KEY = 4077;
    private static final String TCL_SETTINGS_PACKAGE = "com.tcl.settings";
    private static final String TAG = "LiftoffSettingsButton";

    @Override
    protected boolean onKeyEvent(KeyEvent event) {
        if (event.getKeyCode() != TCL_SETTINGS_KEY) {
            return false;
        }
        if (event.getAction() == KeyEvent.ACTION_UP && !event.isCanceled()) {
            openQuickSettings();
        }
        return true;
    }

    private void openQuickSettings() {
        Intent showMenu = new Intent("com.tcl.settings.SHOW_WINDOW")
                .setClassName(TCL_SETTINGS_PACKAGE, "com.tcl.settings.ShowWindowService")
                .putExtra("Type", "quicksettings");
        try {
            if (startService(showMenu) != null) {
                return;
            }
        } catch (IllegalStateException | SecurityException exception) {
            Log.d(TAG, "Trying the TCL Quick Settings activity", exception);
        }

        try {
            startActivity(new Intent("com.tcl.settings.action.QUICKSETTINGS")
                    .setClassName(TCL_SETTINGS_PACKAGE, "com.tcl.settings.MainActivity")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (ActivityNotFoundException | SecurityException exception) {
            Log.w(TAG, "TCL Quick Settings is unavailable on this firmware", exception);
        }
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) { }

    @Override
    public void onInterrupt() { }
}
