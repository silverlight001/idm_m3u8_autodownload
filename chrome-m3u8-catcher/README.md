# Video Catcher for m3u8DL

## Install extension

1. Open Chrome: `chrome://extensions`
2. Enable Developer mode.
3. Click Load unpacked.
4. Select `D:\idmm3u8\chrome-m3u8-catcher`.
5. Copy the extension ID shown by Chrome.

## Register native host

Run PowerShell in `D:\idmm3u8`:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-chrome-native-host.ps1 -ExtensionId "PASTE_EXTENSION_ID_HERE"
```

Restart Chrome after registration.

## What it captures

- HLS: `.m3u8`, sent to `N_m3u8DL`.
- Direct video files: `.mp4`, `.m4v`, `.webm`, `.mov`, `.flv`, downloaded directly by the native host.
- DASH and media segments are detected, but support depends on the local downloader and whether the stream is encrypted.

DRM-protected video cannot be bypassed by this extension.

## In-page button

The extension injects a small `m3u8DL 下载` button near the top-right corner of the largest visible video. Click it to submit the currently captured playable resource to the native host.

If the button says only segments were captured, reload the page and start playback from the beginning so the real playlist can be captured.
