param(
    [Parameter(Mandatory = $true)][string]$DownloaderPath,
    [Parameter(Mandatory = $true)][string]$DownloaderDir,
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$SaveDir,
    [Parameter(Mandatory = $true)][string]$SaveTitle,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$LogDir,
    [switch]$EnableDelAfterDone,
    [switch]$ShowProgressWindow,
    [switch]$KeepProgressWindowOpen,
    [string[]]$AdditionalArgs = @()
)

$ErrorActionPreference = "Stop"

function Write-TaskLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $taskLog -Encoding UTF8 -Value $line
}

function Read-NewText {
    param(
        [string]$Path,
        [ref]$Offset
    )

    if (-not (Test-Path -LiteralPath $Path)) { return "" }

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($Offset.Value -gt $stream.Length) {
            $Offset.Value = 0
        }
        $stream.Seek($Offset.Value, [IO.SeekOrigin]::Begin) | Out-Null
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::Default, $true)
        $text = $reader.ReadToEnd()
        $Offset.Value = $stream.Position
        return $text
    } finally {
        $stream.Dispose()
    }
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$taskLog = Join-Path $LogDir ("task-{0}.log" -f $TaskId)
$stdoutLog = Join-Path $LogDir ("task-{0}.stdout.log" -f $TaskId)
$stderrLog = Join-Path $LogDir ("task-{0}.stderr.log" -f $TaskId)

$args = @(
    $Url,
    "--workDir", $SaveDir,
    "--saveName", $SaveTitle
)

if ($EnableDelAfterDone) {
    $args += "--enableDelAfterDone"
}

if ($AdditionalArgs) {
    $args += @($AdditionalArgs)
}

try {
    if ($ShowProgressWindow) {
        $host.UI.RawUI.WindowTitle = "m3u8DL progress - $SaveTitle"
        Write-Host "m3u8DL task started"
        Write-Host "Title: $SaveTitle"
        Write-Host "Save:  $SaveDir"
        Write-Host "Log:   $taskLog"
        Write-Host ""
    }

    Write-TaskLog "START title=`"$SaveTitle`" workDir=`"$SaveDir`""
    $process = Start-Process -FilePath $DownloaderPath `
        -ArgumentList $args `
        -WorkingDirectory $DownloaderDir `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru

    Write-TaskLog "PID $($process.Id)"
    $stdoutOffset = 0L
    $stderrOffset = 0L

    while (-not $process.HasExited) {
        if ($ShowProgressWindow) {
            $stdoutText = Read-NewText -Path $stdoutLog -Offset ([ref]$stdoutOffset)
            if ($stdoutText) { Write-Host $stdoutText -NoNewline }

            $stderrText = Read-NewText -Path $stderrLog -Offset ([ref]$stderrOffset)
            if ($stderrText) { Write-Host $stderrText -NoNewline -ForegroundColor Yellow }
        }
        Start-Sleep -Milliseconds 500
        $process.Refresh()
    }

    if ($ShowProgressWindow) {
        $stdoutText = Read-NewText -Path $stdoutLog -Offset ([ref]$stdoutOffset)
        if ($stdoutText) { Write-Host $stdoutText -NoNewline }

        $stderrText = Read-NewText -Path $stderrLog -Offset ([ref]$stderrOffset)
        if ($stderrText) { Write-Host $stderrText -NoNewline -ForegroundColor Yellow }
    }

    Write-TaskLog "EXIT code=$($process.ExitCode)"

    if ($ShowProgressWindow) {
        Write-Host ""
        Write-Host "m3u8DL task exited with code $($process.ExitCode)"
        if ($KeepProgressWindowOpen) {
            Write-Host "Press Enter to close this progress window..."
            [void][Console]::ReadLine()
        }
    }

    if ($process.ExitCode -ne 0) {
        exit $process.ExitCode
    }
} catch {
    Write-TaskLog "ERROR $($_.Exception.Message)"
    if ($ShowProgressWindow) {
        Write-Host "ERROR $($_.Exception.Message)" -ForegroundColor Red
        if ($KeepProgressWindowOpen) {
            Write-Host "Press Enter to close this progress window..."
            [void][Console]::ReadLine()
        }
    }
    exit 1
}
