# IDM m3u8DL Takeover

English | [简体中文](README.zh-CN.md)

## Bilingual Summary

EN: A Windows helper that automatically takes over IDM video download dialogs and sends the same m3u8 URL, file name, and save folder to `N_m3u8DL-CLI`.

ZH: 一个 Windows 小工具，自动接管 IDM 的视频下载弹窗，并把相同的 m3u8 地址、文件名和保存目录交给 `N_m3u8DL-CLI` 下载。

Automatically takes over Internet Download Manager's "Download File Info" dialog and submits the detected m3u8 task to `N_m3u8DL-CLI`.

The main and recommended workflow is:

1. Keep `start-auto-m3u8dl.bat` running.
2. Let IDM's Chrome integration detect a video and show its download dialog.
3. This script reads the dialog fields automatically:
   - m3u8 URL
   - save folder
   - file name
4. It starts `N_m3u8DL-CLI_v3.0.2.exe` with the same URL, save name, and working directory.
5. It closes the IDM dialog so IDM does not download the same task.

The Chrome extension in `chrome-m3u8-catcher/` is experimental. The IDM-dialog takeover script is currently the more reliable path because IDM already performs the hard video detection step.

## Files

- `auto-m3u8dl.ps1` - main PowerShell watcher.
- `start-auto-m3u8dl.bat` - double-click launcher.
- `inspect-idm-dialog.bat` - diagnostic helper for an open IDM dialog.
- `auto-m3u8dl.config.example.json` - example configuration.
- `chrome-m3u8-catcher/` - experimental Chrome extension.
- `native-host/` - experimental Chrome native messaging host source.

## Requirements

- Windows
- PowerShell 5+
- Internet Download Manager with browser integration enabled
- `N_m3u8DL-CLI_v3.0.2.exe` available locally

This repository does not ship IDM, ffmpeg, or N_m3u8DL binaries.

## Setup

Copy the example config if you want to customize paths:

```powershell
Copy-Item .\auto-m3u8dl.config.example.json .\auto-m3u8dl.config.json
```

Edit `auto-m3u8dl.config.json`:

```json
{
  "downloaderDir": "D:\\idmm3u8\\N_m3u8DL-CLI_v3.0.2_with_ffmpeg_and_SimpleG",
  "cliExe": "N_m3u8DL-CLI_v3.0.2.exe",
  "workDirTemplate": "D:\\srep\\{yyyyMMdd}",
  "pollMilliseconds": 150,
  "keyboardDelayMs": 45
}
```

Then start:

```powershell
.\start-auto-m3u8dl.bat
```

Keep that window open. When IDM opens its download dialog, the script should take over automatically.

## Diagnostics

Open an IDM download dialog, then run:

```powershell
.\inspect-idm-dialog.bat
```

If detection works, it prints:

- `Url`
- `Title`
- `WorkDir`

## Tuning Speed

The fastest useful settings are usually:

```json
{
  "pollMilliseconds": 150,
  "keyboardDelayMs": 45
}
```

If fields are read incorrectly on a slower machine, use safer values:

```json
{
  "pollMilliseconds": 250,
  "keyboardDelayMs": 80
}
```

## Notes

- Already submitted URLs are recorded under `.auto-m3u8dl/seen.txt`.
- Logs are written under `.auto-m3u8dl/`.
- The script has a clipboard fallback, but normal IDM dialog takeover should not require manual copying.
