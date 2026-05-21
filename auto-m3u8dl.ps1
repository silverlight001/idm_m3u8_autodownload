param(
    [switch]$Once,
    [switch]$InspectIdm,
    [string]$ConfigPath = (Join-Path $PSScriptRoot "auto-m3u8dl.config.json"),
    [string]$WorkDir,
    [string]$Title,
    [string]$Url
)

if ([Threading.Thread]::CurrentThread.ApartmentState -ne "STA") {
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", "`"$PSCommandPath`"")
    if ($Once) { $argList += "-Once" }
    if ($InspectIdm) { $argList += "-InspectIdm" }
    if ($ConfigPath) { $argList += @("-ConfigPath", "`"$ConfigPath`"") }
    if ($WorkDir) { $argList += @("-WorkDir", "`"$WorkDir`"") }
    if ($Title) { $argList += @("-Title", "`"$Title`"") }
    if ($Url) { $argList += @("-Url", "`"$Url`"") }
    Start-Process -FilePath "powershell.exe" -ArgumentList $argList
    exit
}

$ErrorActionPreference = "Stop"

function Read-Config {
    param([string]$Path)

    $defaults = [pscustomobject]@{
        downloaderDir      = (Join-Path $PSScriptRoot "N_m3u8DL-CLI_v3.0.2_with_ffmpeg_and_SimpleG")
        cliExe             = "N_m3u8DL-CLI_v3.0.2.exe"
        workDirTemplate    = "D:\Downloads\m3u8\{yyyyMMdd}"
        pollSeconds        = 1
        pollMilliseconds   = 150
        enableDelAfterDone = $true
        takeoverIdmDialogs = $true
        closeIdmDialogAfterSubmit = $true
        consoleCodePage    = 65001
        foregroundKeyboardTakeover = $true
        idmSaveAsTabCount  = 3
        keyboardDelayMs    = 45
        additionalArgs     = @()
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $defaults
    }

    $cfg = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($name in $defaults.PSObject.Properties.Name) {
        if (-not $cfg.PSObject.Properties[$name]) {
            Add-Member -InputObject $cfg -MemberType NoteProperty -Name $name -Value $defaults.$name
        }
    }
    return $cfg
}

function Resolve-TemplatePath {
    param([string]$Template)

    $now = Get-Date
    return $Template.
        Replace("{yyyyMMdd}", $now.ToString("yyyyMMdd")).
        Replace("{yyyy-MM-dd}", $now.ToString("yyyy-MM-dd")).
        Replace("{yyyyMM}", $now.ToString("yyyyMM"))
}

function Initialize-ConsoleEncoding {
    param([object]$Config)

    try {
        if ($Config.consoleCodePage) {
            & chcp.com ([int]$Config.consoleCodePage) | Out-Null
        }
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
        $OutputEncoding = [Text.UTF8Encoding]::new($false)
    } catch {
        # Encoding setup is best effort; download args are still passed as Unicode.
    }
}

function Initialize-Win32Helpers {
    if ("Win32IdmTakeover" -as [type]) { return }

    Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public class Win32IdmTakeover {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWnd, EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder lParam, uint flags, uint timeout, out IntPtr result);
}
"@
}

function Get-WindowTextSafe {
    param([IntPtr]$Handle)

    $text = [Text.StringBuilder]::new(4096)
    [void][Win32IdmTakeover]::GetWindowText($Handle, $text, $text.Capacity)
    $value = $text.ToString()
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }

    $result = [IntPtr]::Zero
    $buffer = [Text.StringBuilder]::new(4096)
    $WM_GETTEXT = 0x000D
    $SMTO_ABORTIFHUNG = 0x0002
    [void][Win32IdmTakeover]::SendMessageTimeout($Handle, $WM_GETTEXT, [IntPtr]$buffer.Capacity, $buffer, $SMTO_ABORTIFHUNG, 80, [ref]$result)
    return $buffer.ToString()
}

function Get-ClassNameSafe {
    param([IntPtr]$Handle)

    $text = [Text.StringBuilder]::new(512)
    [void][Win32IdmTakeover]::GetClassName($Handle, $text, $text.Capacity)
    return $text.ToString()
}

function Get-ChildWindowTexts {
    param([IntPtr]$WindowHandle)

    $items = [Collections.Generic.List[object]]::new()
    [Win32IdmTakeover]::EnumChildWindows($WindowHandle, {
        param($child, $lParam)

        $txt = Get-WindowTextSafe -Handle $child
        if (-not [string]::IsNullOrWhiteSpace($txt)) {
            $items.Add([pscustomobject]@{
                Handle = $child
                ClassName = Get-ClassNameSafe -Handle $child
                Text = $txt.Trim()
            })
        }
        return $true
    }, [IntPtr]::Zero) | Out-Null

    return $items
}

function Get-IdmDownloadDialogs {
    Initialize-Win32Helpers

    $dialogs = [Collections.Generic.List[object]]::new()
    [Win32IdmTakeover]::EnumWindows({
        param($hwnd, $lParam)

        if (-not [Win32IdmTakeover]::IsWindowVisible($hwnd)) { return $true }

        $processId = 0
        [void][Win32IdmTakeover]::GetWindowThreadProcessId($hwnd, [ref]$processId)
        $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
        $procName = if ($proc) { $proc.ProcessName } else { "" }

        $title = Get-WindowTextSafe -Handle $hwnd
        $children = @(Get-ChildWindowTexts -WindowHandle $hwnd)
        $joined = ($children | ForEach-Object { $_.Text }) -join "`n"
        $looksLikeIdm = $procName -match "^(IDMan|IDM|IEMonitor|IDMGrHlp|IDMIntegrator64)$"
        $hasM3u8 = $joined -match "(?i)\.m3u8"
        $hasIdmFields = ($joined -match "(?i)https?://") -and ($joined -match "^[A-Za-z]:\\" -or $joined -match "`n[A-Za-z]:\\")
        if (-not ($hasM3u8 -and ($looksLikeIdm -or $hasIdmFields))) { return $true }

        $dialogs.Add([pscustomobject]@{
            Handle = $hwnd
            Title = $title
            ClassName = Get-ClassNameSafe -Handle $hwnd
            ProcessName = $procName
            Texts = $children
        })
        return $true
    }, [IntPtr]::Zero) | Out-Null

    return $dialogs
}

function ConvertFrom-IdmDialog {
    param([object]$Dialog)

    $texts = @($Dialog.Texts | ForEach-Object { $_.Text } | Where-Object { $_ })
    $m3u8 = $null
    foreach ($text in $texts) {
        $m3u8 = Find-M3u8Url -Text $text
        if ($m3u8) { break }
    }
    if (-not $m3u8) { return $null }

    $paths = @($texts | Where-Object { $_ -match '^[A-Za-z]:\\' })
    $directoryPaths = @($paths | Where-Object {
        ($_ -match "[\\\/]$") -or ((Test-Path -LiteralPath $_ -PathType Container) -and ($_ -notmatch "\.[A-Za-z0-9]{1,8}$"))
    })

    $workDir = $null
    if ($directoryPaths.Count -gt 0) {
        $workDir = $directoryPaths[-1].TrimEnd("\", "/")
    }

    $filePath = $null
    foreach ($path in $paths) {
        $trimmed = $path.TrimEnd("\", "/")
        if ($workDir -and $trimmed -ieq $workDir) { continue }
        if ($trimmed -match '^[A-Za-z]:\\.+[\\/].+') {
            $filePath = $trimmed
            break
        }
    }

    if (-not $workDir -and $filePath) {
        $workDir = Split-Path -Path $filePath -Parent
    }

    if (-not $workDir) {
        $workDir = Resolve-TemplatePath -Template $config.workDirTemplate
    }

    $title = $null
    if ($filePath) {
        $title = [IO.Path]::GetFileNameWithoutExtension($filePath)
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = Split-Path -Path $filePath -Leaf
        }
    }
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = Find-Title -Text ($texts -join "`n") -Url $m3u8
    }

    return [pscustomobject]@{
        Url = $m3u8
        Title = $title
        WorkDir = $workDir
        SourceHandle = $Dialog.Handle
    }
}

function Close-IdmDialog {
    param([IntPtr]$Handle)

    $WM_CLOSE = 0x0010
    [void][Win32IdmTakeover]::PostMessage($Handle, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Get-ForegroundIdmDialog {
    Initialize-Win32Helpers

    $handle = [Win32IdmTakeover]::GetForegroundWindow()
    if ($handle -eq [IntPtr]::Zero) { return $null }

    $title = Get-WindowTextSafe -Handle $handle
    $className = Get-ClassNameSafe -Handle $handle
    $processId = 0
    [void][Win32IdmTakeover]::GetWindowThreadProcessId($handle, [ref]$processId)
    $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue

    $procName = if ($proc) { $proc.ProcessName } else { "" }
    if ($procName -match "^(IDMan|IDM|IEMonitor|IDMGrHlp)$") {
        return [pscustomobject]@{
            Handle = $handle
            Title = $title
            ClassName = $className
            ProcessName = $procName
        }
    }

    return $null
}

function Get-ClipboardTextForKeyboard {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        return [Windows.Forms.Clipboard]::GetText()
    } catch {
        return ""
    }
}

function Set-ClipboardTextSafe {
    param([string]$Text)

    try {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.Clipboard]::SetText($Text)
    } catch {
    }
}

function Copy-ActiveControlText {
    param([int]$DelayMs)

    [Windows.Forms.SendKeys]::SendWait("^a")
    Start-Sleep -Milliseconds $DelayMs
    [Windows.Forms.SendKeys]::SendWait("^c")
    Start-Sleep -Milliseconds $DelayMs
    return Get-ClipboardTextForKeyboard
}

function ConvertFrom-ForegroundIdmDialog {
    param([object]$Dialog, [object]$Config)

    Add-Type -AssemblyName System.Windows.Forms

    $delay = [Math]::Max(30, [int]$Config.keyboardDelayMs)
    $originalClipboard = Get-ClipboardTextForKeyboard

    $urlText = Copy-ActiveControlText -DelayMs $delay
    $m3u8 = Find-M3u8Url -Text $urlText
    if (-not $m3u8) {
        return $null
    }

    $tabCount = [Math]::Max(0, [int]$Config.idmSaveAsTabCount)
    for ($i = 0; $i -lt $tabCount; $i++) {
        [Windows.Forms.SendKeys]::SendWait("{TAB}")
        Start-Sleep -Milliseconds $delay
    }

    $filePathText = Copy-ActiveControlText -DelayMs $delay
    $filePath = ($filePathText -split "\r?\n" | Where-Object { $_ -match '^[A-Za-z]:\\' } | Select-Object -First 1)

    if (-not $filePath) {
        Set-ClipboardTextSafe -Text $originalClipboard
        return [pscustomobject]@{
            Url = $m3u8
            Title = Find-Title -Text $urlText -Url $m3u8
            WorkDir = Resolve-TemplatePath -Template $Config.workDirTemplate
            SourceHandle = $Dialog.Handle
        }
    }

    $filePath = $filePath.Trim()
    $workDir = Split-Path -Path $filePath -Parent
    $title = [IO.Path]::GetFileNameWithoutExtension($filePath)
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = Split-Path -Path $filePath -Leaf
    }

    Set-ClipboardTextSafe -Text $originalClipboard

    return [pscustomobject]@{
        Url = $m3u8
        Title = $title
        WorkDir = $workDir
        SourceHandle = $Dialog.Handle
    }
}

function ConvertTo-SafeFileName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return "video_" + (Get-Date -Format "yyyyMMdd_HHmmss")
    }

    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $chars = foreach ($ch in $Name.Trim().ToCharArray()) {
        if ($invalid -contains $ch) { "_" } else { $ch }
    }
    $safe = (-join $chars) -replace "\s+", " "
    $safe = $safe.Trim(" .")
    if ($safe.Length -gt 120) {
        $safe = $safe.Substring(0, 120).Trim(" .")
    }
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "video_" + (Get-Date -Format "yyyyMMdd_HHmmss")
    }
    return $safe
}

function Find-M3u8Url {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, "https?://[^\s'""<>]+?\.m3u8[^\s'""<>]*", "IgnoreCase")
    if ($match.Success) {
        return $match.Value.Trim().TrimEnd(",", ";", ")")
    }
    return $null
}

function Find-Title {
    param(
        [string]$Text,
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    try {
        $json = $Text | ConvertFrom-Json -ErrorAction Stop
        foreach ($key in @("title", "name", "fileName", "filename", "saveName")) {
            if ($json.PSObject.Properties[$key] -and -not [string]::IsNullOrWhiteSpace([string]$json.$key)) {
                return [string]$json.$key
            }
        }
    } catch {
        # Clipboard text is often plain text; JSON is only a convenience path.
    }

    $lines = $Text -split "\r?\n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and ($_ -notmatch "https?://") }

    foreach ($line in $lines) {
        if ($line -match "^(title|name|filename|fileName|saveName)\s*[:=]\s*(.+)$") {
            return $Matches[2].Trim()
        }
    }

    if ($lines.Count -gt 0) {
        return $lines[0]
    }

    if ($Url -match "/([^/?#]+)\.m3u8") {
        return $Matches[1]
    }

    return $null
}

function Get-ClipboardText {
    try {
        return Get-Clipboard -Raw -Format Text
    } catch {
        return $null
    }
}

function Invoke-M3u8Download {
    param(
        [object]$Config,
        [string]$M3u8Url,
        [string]$SaveTitle,
        [string]$SaveDir,
        [string]$LogPath
    )

    $downloaderDir = [IO.Path]::GetFullPath($Config.downloaderDir)
    $cliPath = Join-Path $downloaderDir $Config.cliExe
    if (-not (Test-Path -LiteralPath $cliPath)) {
        throw "Downloader not found: $cliPath"
    }

    New-Item -ItemType Directory -Force -Path $SaveDir | Out-Null

    $args = @(
        $M3u8Url,
        "--workDir", $SaveDir,
        "--saveName", $SaveTitle
    )

    if ($Config.enableDelAfterDone) {
        $args += "--enableDelAfterDone"
    }

    if ($Config.additionalArgs) {
        $args += @($Config.additionalArgs)
    }

    $line = "[{0}] START title=`"{1}`" workDir=`"{2}`" url=`"{3}`"" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $SaveTitle, $SaveDir, $M3u8Url
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value $line

    Start-Process -FilePath $cliPath -ArgumentList $args -WorkingDirectory $downloaderDir
}

$config = Read-Config -Path $ConfigPath
Initialize-ConsoleEncoding -Config $config
$stateDir = Join-Path $PSScriptRoot ".auto-m3u8dl"
$seenPath = Join-Path $stateDir "seen.txt"
$logPath = Join-Path $stateDir "auto-m3u8dl.log"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $seenPath) {
    Get-Content -LiteralPath $seenPath -Encoding UTF8 | ForEach-Object {
        if ($_ -and $_.Trim()) { [void]$seen.Add($_.Trim()) }
    }
}

Write-Host "auto-m3u8dl started. IDM m3u8 dialogs are taken over automatically; clipboard is the fallback. Press Ctrl+C to stop."
Write-Host "Config: $ConfigPath"
Write-Host "Log: $logPath"

if ($InspectIdm) {
    $detected = @()
    $fg = Get-ForegroundIdmDialog
    if ($fg -and $config.foregroundKeyboardTakeover) {
        $task = ConvertFrom-ForegroundIdmDialog -Dialog $fg -Config $config
        if ($task) { $detected += $task }
    }
    foreach ($dialog in @(Get-IdmDownloadDialogs)) {
        $task = ConvertFrom-IdmDialog -Dialog $dialog
        if ($task) { $detected += $task }
    }
    $detected = @($detected | Where-Object { $_ })
    if ($detected.Count -eq 0) {
        Write-Host "No IDM m3u8 dialog detected."
    } else {
        $detected | Select-Object Url, Title, WorkDir, SourceHandle | Format-List
    }
    exit
}

do {
    $sourceHandle = [IntPtr]::Zero
    $idmTask = $null
    if (-not $Url -and $config.takeoverIdmDialogs) {
        if ($config.foregroundKeyboardTakeover) {
            $fg = Get-ForegroundIdmDialog
            if ($fg) {
                $candidate = ConvertFrom-ForegroundIdmDialog -Dialog $fg -Config $config
                if ($candidate -and -not $seen.Contains($candidate.Url)) {
                    $idmTask = $candidate
                }
            }
        }
        if (-not $idmTask) {
            foreach ($dialog in @(Get-IdmDownloadDialogs)) {
                $idmTask = ConvertFrom-IdmDialog -Dialog $dialog
                if ($idmTask -and -not $seen.Contains($idmTask.Url)) { break }
                $idmTask = $null
            }
        }
    }

    $clip = if ($Url -or $idmTask) { $null } else { Get-ClipboardText }
    $m3u8 = if ($Url) { $Url } elseif ($idmTask) { $idmTask.Url } else { Find-M3u8Url -Text $clip }

    if ($m3u8 -and -not $seen.Contains($m3u8)) {
        $rawTitle = if ($Title) { $Title } elseif ($idmTask) { $idmTask.Title } else { Find-Title -Text $clip -Url $m3u8 }
        $safeTitle = ConvertTo-SafeFileName -Name $rawTitle
        $saveDir = if ($WorkDir) { $WorkDir } elseif ($idmTask) { $idmTask.WorkDir } else { Resolve-TemplatePath -Template $config.workDirTemplate }
        if ($idmTask) { $sourceHandle = $idmTask.SourceHandle }

        try {
            Invoke-M3u8Download -Config $config -M3u8Url $m3u8 -SaveTitle $safeTitle -SaveDir $saveDir -LogPath $logPath
            [void]$seen.Add($m3u8)
            Add-Content -LiteralPath $seenPath -Encoding UTF8 -Value $m3u8
            if ($sourceHandle -ne [IntPtr]::Zero -and $config.closeIdmDialogAfterSubmit) {
                Close-IdmDialog -Handle $sourceHandle
            }
            Write-Host ("Submitted: {0}" -f $safeTitle)
        } catch {
            $err = "[{0}] ERROR {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $_.Exception.Message
            Add-Content -LiteralPath $logPath -Encoding UTF8 -Value $err
            Write-Warning $_.Exception.Message
        }
    }

    if ($Once) { break }
    $sleepMs = if ($config.PSObject.Properties["pollMilliseconds"]) { [int]$config.pollMilliseconds } else { [int]$config.pollSeconds * 1000 }
    Start-Sleep -Milliseconds ([Math]::Max(50, $sleepMs))
} while ($true)
