param(
    [Parameter(Mandatory = $true)]
    [string]$ExtensionId
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$hostDir = Join-Path $root "native-host"
$nativeHostPath = Join-Path $hostDir "m3u8dl-native-host.exe"
$nativeHostSource = Join-Path $hostDir "M3u8DlNativeHost.cs"
$manifestPath = Join-Path $hostDir "com.local.m3u8dl.json"

Add-Type `
    -TypeDefinition (Get-Content -LiteralPath $nativeHostSource -Raw) `
    -ReferencedAssemblies @("System.Web.Extensions") `
    -OutputAssembly $nativeHostPath `
    -OutputType ConsoleApplication

$manifest = [ordered]@{
    name = "com.local.m3u8dl"
    description = "Native bridge for m3u8DL Catcher"
    path = $nativeHostPath
    type = "stdio"
    allowed_origins = @("chrome-extension://$ExtensionId/")
}

$json = $manifest | ConvertTo-Json -Depth 5
Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value $json

$regPath = "HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.local.m3u8dl"
New-Item -Path $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name "(default)" -Value $manifestPath

Write-Host "Installed native host: $manifestPath"
Write-Host "Allowed extension: $ExtensionId"
