package com.androidprompt.clipboard;

import android.app.Activity;
import android.os.Bundle;

public final class BootstrapActivity extends Activity {
    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        finish();
    }
}
