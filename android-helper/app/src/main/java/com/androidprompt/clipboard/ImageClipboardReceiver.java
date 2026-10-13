package com.androidprompt.clipboard;

import android.content.BroadcastReceiver;
import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.UUID;

public final class ImageClipboardReceiver extends BroadcastReceiver {
    private static final String SET = "com.androidprompt.clipboard.SET_IMAGE";
    private static final String DELETE_TEST = "com.androidprompt.clipboard.DELETE_TEST";
    static final String PREFS = "images";
    static final String LAST_URI = "last_uri";

    @Override public void onReceive(Context context, Intent intent) {
        try {
            if (SET.equals(intent.getAction())) importImage(context, intent.getStringExtra("filename"));
            else if (DELETE_TEST.equals(intent.getAction())) deleteTest(context, intent.getStringExtra("uri"));
            else throw new IllegalArgumentException("Unsupported action");
            setResultCode(1); setResultData("OK");
        } catch (Exception error) {
            setResultCode(2); setResultData(error.getClass().getSimpleName() + ": " + error.getMessage());
        }
    }

    private void importImage(Context context, String incomingName) throws Exception {
        if (incomingName == null || !incomingName.matches("clip-[a-f0-9]{32}\\.png")) throw new IllegalArgumentException("Invalid filename");
        File incoming = new File(context.getExternalFilesDir("incoming"), incomingName);
        if (!incoming.isFile() || incoming.length() < 1 || incoming.length() > 20L * 1024 * 1024) throw new IllegalArgumentException("Invalid image file");

        String stamp = new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(new Date());
        String displayName = "AndroidPrompt-" + stamp + "-" + UUID.randomUUID().toString().replace("-", "") + ".png";
        ContentResolver resolver = context.getContentResolver();
        ContentValues values = new ContentValues();
        values.put(MediaStore.Images.Media.DISPLAY_NAME, displayName);
        values.put(MediaStore.Images.Media.MIME_TYPE, "image/png");
        if (Build.VERSION.SDK_INT >= 29) {
            values.put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/AndroidPrompt");
            values.put(MediaStore.Images.Media.IS_PENDING, 1);
        }
        Uri uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values);
        if (uri == null) throw new IllegalStateException("MediaStore insert failed");
        boolean complete = false;
        try {
            try (InputStream input = new FileInputStream(incoming); OutputStream output = resolver.openOutputStream(uri, "w")) {
                if (output == null) throw new IllegalStateException("MediaStore output unavailable");
                byte[] buffer = new byte[65536]; int count;
                while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            }
            if (Build.VERSION.SDK_INT >= 29) {
                ContentValues ready = new ContentValues(); ready.put(MediaStore.Images.Media.IS_PENDING, 0);
                if (resolver.update(uri, ready, null, null) != 1) throw new IllegalStateException("MediaStore finalize failed");
            }
            String hash;
            try (InputStream stored = resolver.openInputStream(uri)) {
                if (stored == null) throw new IllegalStateException("MediaStore image unreadable");
                hash = sha256(stored);
            }
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(LAST_URI, uri.toString()).apply();
            File statusDirectory = new File(context.getExternalFilesDir(null), "status");
            if (!statusDirectory.isDirectory() && !statusDirectory.mkdirs()) throw new IllegalStateException("Cannot create status directory");
            try (FileOutputStream ack = new FileOutputStream(new File(statusDirectory, incomingName + ".ok"), false)) {
                ack.write((hash + "|" + uri + "|" + displayName).getBytes(StandardCharsets.UTF_8));
            }
            complete = true;
        } finally {
            incoming.delete();
            if (!complete) resolver.delete(uri, null, null);
        }
    }

    private String sha256(InputStream input) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] buffer = new byte[65536]; int count;
        while ((count = input.read(buffer)) != -1) digest.update(buffer, 0, count);
        StringBuilder result = new StringBuilder(64);
        for (byte value : digest.digest()) result.append(String.format("%02x", value & 0xff));
        return result.toString();
    }

    private void deleteTest(Context context, String value) {
        Uri uri = Uri.parse(value == null ? "" : value);
        if (!"content".equals(uri.getScheme()) || !"media".equals(uri.getAuthority())) throw new IllegalArgumentException("Invalid MediaStore URI");
        long id = ContentUris.parseId(uri);
        if (id < 1) throw new IllegalArgumentException("Invalid MediaStore id");
        context.getContentResolver().delete(uri, null, null);
        String last = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(LAST_URI, "");
        if (uri.toString().equals(last)) context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(LAST_URI).apply();
    }
}
