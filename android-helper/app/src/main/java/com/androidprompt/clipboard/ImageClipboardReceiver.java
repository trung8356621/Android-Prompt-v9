package com.androidprompt.clipboard;

import android.content.BroadcastReceiver;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

public final class ImageClipboardReceiver extends BroadcastReceiver {
    private static final String SET = "com.androidprompt.clipboard.SET_IMAGE";
    private static final String SHARE = "com.androidprompt.clipboard.SHARE_LAST";

    @Override public void onReceive(Context context, Intent intent) {
        try {
            if (SET.equals(intent.getAction())) setImage(context, intent.getStringExtra("filename"));
            else if (SHARE.equals(intent.getAction())) share(context);
            else throw new IllegalArgumentException("Unsupported action");
            setResultCode(1); setResultData("OK");
        } catch (Exception error) {
            setResultCode(2); setResultData(error.getClass().getSimpleName() + ": " + error.getMessage());
        }
    }

    private void setImage(Context context, String filename) throws Exception {
        if (filename == null || !filename.matches("clip-[a-f0-9]{32}\\.png")) throw new IllegalArgumentException("Invalid filename");
        File incoming = new File(context.getExternalFilesDir("incoming"), filename);
        if (!incoming.isFile() || incoming.length() < 1 || incoming.length() > 20L * 1024 * 1024) throw new IllegalArgumentException("Invalid image file");
        File directory = new File(context.getCacheDir(), "clipboard");
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IllegalStateException("Cannot create clipboard cache");
        File current = new File(directory, "current.png");
        try (FileInputStream input = new FileInputStream(incoming); FileOutputStream output = new FileOutputStream(current, false)) {
            byte[] buffer = new byte[65536]; int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
        } finally { incoming.delete(); }
        ClipboardManager clipboard = (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
        clipboard.setPrimaryClip(ClipData.newUri(context.getContentResolver(), "Android Prompt image", ImageProvider.URI));
        File statusDirectory = new File(context.getExternalFilesDir(null), "status");
        if (!statusDirectory.isDirectory() && !statusDirectory.mkdirs()) throw new IllegalStateException("Cannot create status directory");
        try (FileOutputStream ack = new FileOutputStream(new File(statusDirectory, filename + ".ok"), false)) {
            ack.write(sha256(current).getBytes(StandardCharsets.US_ASCII));
        }
    }

    private String sha256(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (FileInputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[65536]; int count;
            while ((count = input.read(buffer)) != -1) digest.update(buffer, 0, count);
        }
        StringBuilder result = new StringBuilder(64);
        for (byte value : digest.digest()) result.append(String.format("%02x", value & 0xff));
        return result.toString();
    }

    private void share(Context context) {
        File current = new File(context.getCacheDir(), "clipboard/current.png");
        if (!current.isFile()) throw new IllegalStateException("No transferred image");
        Intent send = new Intent(Intent.ACTION_SEND).setType("image/png")
            .putExtra(Intent.EXTRA_STREAM, ImageProvider.URI)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
        context.startActivity(Intent.createChooser(send, "Share Android Prompt image").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    }
}
