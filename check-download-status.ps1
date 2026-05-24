param(
    [string]$Path,
    [int]$Top = 50
)

$ErrorActionPreference = "Stop"

if (-not $Path) {
    $configPath = Join-Path $PSScriptRoot "auto-m3u8dl.config.json"
    if (Test-Path -LiteralPath $configPath) {
        $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $template = [string]$cfg.workDirTemplate
        $today = Get-Date -Format "yyyyMMdd"
        $Path = $template.Replace("{yyyyMMdd}", $today)
    } else {
        $Path = Join-Path $PSScriptRoot "Downloads"
    }
}

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Path not found: $Path"
}

$items = Get-ChildItem -LiteralPath $Path -Force | ForEach-Object {
    if (-not $_.PSIsContainer) {
        [pscustomobject]@{
            Status        = "merged"
            Name          = $_.Name
            Files         = 1
            SizeMB        = [math]::Round($_.Length / 1MB, 1)
            LastWriteTime = $_.LastWriteTime
        }
        return
    }

    $files = @(Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue)
    $size = ($files | Measure-Object Length -Sum).Sum
    $tsCount = @($files | Where-Object { $_.Extension -ieq ".ts" }).Count
    $status = if ($files.Count -eq 0) {
        "empty-folder"
    } elseif ($tsCount -gt 0) {
        "segments-only"
    } else {
        "unfinished"
    }

    [pscustomobject]@{
        Status        = $status
        Name          = $_.Name
        Files         = $files.Count
        SizeMB        = [math]::Round(($size / 1MB), 1)
        LastWriteTime = $_.LastWriteTime
    }
}

$items |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First $Top |
    Format-Table -AutoSize
