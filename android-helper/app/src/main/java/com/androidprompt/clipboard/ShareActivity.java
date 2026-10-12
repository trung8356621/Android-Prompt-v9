package com.androidprompt.clipboard;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

public final class ShareActivity extends Activity {
    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        String value = getSharedPreferences(ImageClipboardReceiver.PREFS, MODE_PRIVATE)
            .getString(ImageClipboardReceiver.LAST_URI, "");
        if (value.isEmpty()) {
            finish();
            return;
        }
        android.net.Uri uri = android.net.Uri.parse(value);
        Intent send = new Intent(Intent.ACTION_SEND)
            .setType("image/png")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        startActivity(Intent.createChooser(send, "Share Android Prompt image"));
        finish();
    }
}
