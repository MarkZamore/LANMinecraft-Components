[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][ValidatePattern('^components-[A-Za-z0-9._-]+$')][string]$Tag,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,
    [int]$MinimumLauncherRelease = 1
)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$output = [IO.Path]::GetFullPath($OutputDirectory)
$artifacts = @(foreach ($entry in @(
    @{ Id = 'identity-adapter'; File = 'portable-identity-adapter.jar' },
    @{ Id = 'notice-overlay'; File = 'launcher-notice-agent.jar' },
    @{ Id = 'native-interop'; File = 'launcher-native-interop-agent.jar' },
    @{ Id = 'legacy-forge-installer'; File = 'LegacyForgeClientInstaller.class' }
)) {
    $file = Get-Item -LiteralPath (Join-Path $output $entry.File)
    [ordered]@{
        id = $entry.Id
        fileName = $entry.File
        url = "https://github.com/MarkZamore/LANMinecraft-Components/releases/download/$Tag/$($entry.File)"
        sizeBytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
$catalog = [ordered]@{
    schemaVersion = 1
    componentApiVersion = 1
    revision = $Tag
    sourceCommit = $SourceCommit
    minimumLauncherRelease = $MinimumLauncherRelease
    artifacts = $artifacts
    componentRules = @(
        @{ runtimeKind = 'java'; minimumJavaMajorVersion = 17; minimumMinecraftVersion = '1.7'; componentIds = @('identity-adapter') },
        @{ runtimeKind = 'java'; minimumJavaMajorVersion = 8; componentIds = @('notice-overlay') },
        @{ runtimeKind = 'java'; minimumJavaMajorVersion = 8; exclusiveMaximumMinecraftVersion = '1.13'; componentIds = @('native-interop') },
        @{ runtimeKind = 'java'; loaders = @('forge'); exclusiveMaximumMinecraftVersion = '1.7.0'; componentIds = @('legacy-forge-installer') }
    )
    javaCatalog = Get-Content -LiteralPath (Join-Path $repository 'data/java-catalog.json') -Raw | ConvertFrom-Json
    steamCatalog = Get-Content -LiteralPath (Join-Path $repository 'data/steam-components.json') -Raw | ConvertFrom-Json
}
$catalog | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $output 'catalog.json') -Encoding utf8
Write-Host "Created component catalog $Tag from $SourceCommit."
