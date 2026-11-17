[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [switch]$VerifyReproducible
)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
if ([string]::IsNullOrWhiteSpace($env:JAVA_HOME)) { throw 'JAVA_HOME must select JDK 25.0.2.' }
foreach ($tool in @('java', 'javac', 'jar')) {
    if (-not (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME "bin/$tool.exe") -PathType Leaf)) {
        throw "The selected JDK is missing $tool."
    }
}

function Build-All {
    & (Join-Path $repository 'Program/IdentityAdapters/Common/Build-IdentityAdapter.ps1') `
        -AdapterName Minecraft-1.21.1-NeoForge -OutputPath (Join-Path $output 'portable-identity-adapter.jar')
    & (Join-Path $repository 'Program/NoticeOverlay/Build-NoticeOverlay.ps1') `
        -OutputPath (Join-Path $output 'launcher-notice-agent.jar')
    & (Join-Path $repository 'Program/NativeInterop/Build-NativeInterop.ps1') `
        -OutputPath (Join-Path $output 'launcher-native-interop-agent.jar')
    & (Join-Path $repository 'Program/LegacyForgeInstaller/Build-LegacyForgeInstaller.ps1') `
        -OutputPath (Join-Path $output 'LegacyForgeClientInstaller.class')
}

Build-All
if ($VerifyReproducible) {
    $before = @{}
    Get-ChildItem -LiteralPath $output -File | Where-Object Extension -in @('.jar', '.class') |
        ForEach-Object { $before[$_.Name] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    Build-All
    foreach ($name in $before.Keys) {
        if ((Get-FileHash -LiteralPath (Join-Path $output $name) -Algorithm SHA256).Hash -ne $before[$name]) {
            throw "Rebuilding changed component bytes: $name"
        }
    }
}
& (Join-Path $PSScriptRoot 'Test-Components.ps1') -OutputDirectory $output
