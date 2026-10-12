package com.androidprompt.clipboard;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import java.io.File;

public final class ShareActivity extends Activity {
    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        File current = new File(getCacheDir(), "clipboard/current.png");
        if (!current.isFile()) {
            finish();
            return;
        }
        Intent send = new Intent(Intent.ACTION_SEND)
            .setType("image/png")
            .putExtra(Intent.EXTRA_STREAM, ImageProvider.URI)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        startActivity(Intent.createChooser(send, "Share Android Prompt image"));
        finish();
    }
}
