param(
    [Parameter(Mandatory = $true)][string]$DownloaderPath,
    [Parameter(Mandatory = $true)][string]$DownloaderDir,
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$SaveDir,
    [Parameter(Mandatory = $true)][string]$SaveTitle,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$LogDir,
    [switch]$EnableDelAfterDone,
    [string[]]$AdditionalArgs = @()
)

$ErrorActionPreference = "Stop"

function Write-TaskLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $taskLog -Encoding UTF8 -Value $line
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
    Write-TaskLog "START title=`"$SaveTitle`" workDir=`"$SaveDir`""
    $process = Start-Process -FilePath $DownloaderPath `
        -ArgumentList $args `
        -WorkingDirectory $DownloaderDir `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru `
        -WindowStyle Hidden

    Write-TaskLog "PID $($process.Id)"
    $process.WaitForExit()
    Write-TaskLog "EXIT code=$($process.ExitCode)"

    if ($process.ExitCode -ne 0) {
        exit $process.ExitCode
    }
} catch {
    Write-TaskLog "ERROR $($_.Exception.Message)"
    exit 1
}
