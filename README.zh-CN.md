# IDM m3u8DL 自动接管下载

[English](README.md) | 简体中文

## 项目简介

这是一个 Windows 自动化小工具，用来接管 Internet Download Manager（IDM）的“下载文件信息”弹窗，并把 IDM 已经识别出的 m3u8 下载任务交给 `N_m3u8DL-CLI` 执行。

推荐主流程：

1. 保持 `start-auto-m3u8dl.bat` 运行。
2. 让 IDM 的浏览器集成正常识别网页视频，并弹出“下载文件信息”窗口。
3. 脚本自动读取弹窗字段：
   - m3u8 地址
   - 保存目录
   - 文件名
4. 脚本使用同样的 URL、文件名和工作目录启动 `N_m3u8DL-CLI_v3.0.2.exe`。
5. 脚本默认关闭 IDM 弹窗，避免 IDM 自己重复下载同一个任务。

`chrome-m3u8-catcher/` 目录中的 Chrome 插件是实验方案。当前更可靠的方案是 IDM 弹窗接管，因为 IDM 已经完成了最难的视频识别工作。

## 文件说明

- `auto-m3u8dl.ps1`：主 PowerShell 监听脚本。
- `start-auto-m3u8dl.bat`：双击启动入口。
- `inspect-idm-dialog.bat`：诊断工具，用于检查当前打开的 IDM 弹窗能否被识别。
- `auto-m3u8dl.config.example.json`：配置文件示例。
- `chrome-m3u8-catcher/`：实验性 Chrome 插件。
- `native-host/`：实验性 Chrome Native Messaging 主机源码。

## 环境要求

- Windows
- PowerShell 5+
- 已启用浏览器集成的 Internet Download Manager
- 本地已有 `N_m3u8DL-CLI_v3.0.2.exe`

本仓库不包含 IDM、ffmpeg 或 N_m3u8DL 的二进制文件。

## 法律声明

本项目仅用于个人自动化、研究学习，以及对你有权访问和下载的内容进行工具衔接。使用者应自行遵守版权法、网站服务条款以及所在地法律法规。

请勿使用本项目下载未经授权的受版权保护内容、绕过 DRM 或访问控制、传播受保护媒体，或违反相关平台的使用条款。以美国为例，DMCA 对规避技术保护措施有专门限制；其他国家和地区也可能存在类似规定。

本项目作者不托管任何媒体内容，不提供下载源，不附带第三方下载器二进制文件，也不鼓励任何侵权行为。使用本软件所产生的风险由使用者自行承担。

## 安装与配置

如果需要自定义路径，先复制示例配置：

```powershell
Copy-Item .\auto-m3u8dl.config.example.json .\auto-m3u8dl.config.json
```

编辑 `auto-m3u8dl.config.json`：

```json
{
  "downloaderDir": "D:\\idmm3u8\\N_m3u8DL-CLI_v3.0.2_with_ffmpeg_and_SimpleG",
  "cliExe": "N_m3u8DL-CLI_v3.0.2.exe",
  "workDirTemplate": "D:\\srep\\{yyyyMMdd}",
  "pollMilliseconds": 150,
  "keyboardDelayMs": 45
}
```

启动：

```powershell
.\start-auto-m3u8dl.bat
```

保持这个窗口打开。当 IDM 弹出下载窗口时，脚本会自动接管。

## 诊断 IDM 弹窗

先打开一个 IDM“下载文件信息”弹窗，然后运行：

```powershell
.\inspect-idm-dialog.bat
```

如果检测成功，会输出：

- `Url`
- `Title`
- `WorkDir`

## 速度调优

通常比较快且稳定的配置：

```json
{
  "pollMilliseconds": 150,
  "keyboardDelayMs": 45
}
```

如果机器较慢，偶尔读取字段不准，可以改得更稳一点：

```json
{
  "pollMilliseconds": 250,
  "keyboardDelayMs": 80
}
```

## 注意事项

- 已提交过的 URL 会记录在 `.auto-m3u8dl/seen.txt`。
- 日志写入 `.auto-m3u8dl/`。
- 剪贴板监听只是兜底逻辑；正常情况下不需要手动复制 IDM 弹窗里的链接。
- 如果 IDM 没有先识别出视频下载任务，本脚本也无法凭空生成正确的 m3u8 地址。
