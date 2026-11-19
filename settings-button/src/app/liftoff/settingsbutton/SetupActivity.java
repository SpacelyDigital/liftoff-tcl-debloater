package app.liftoff.settingsbutton;

import android.app.Activity;
import android.os.Bundle;

public final class SetupActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // A newly installed app stays stopped until Android launches one of its activities.
        finish();
    }
}
