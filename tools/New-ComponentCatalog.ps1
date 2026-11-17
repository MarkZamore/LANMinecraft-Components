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
$steam = Get-Content -LiteralPath (Join-Path $repository 'data/steam-components.json') -Raw | ConvertFrom-Json
$previousPath = Join-Path $repository 'catalog.json'
if (Test-Path -LiteralPath $previousPath -PathType Leaf) {
    $previous = Get-Content -LiteralPath $previousPath -Raw | ConvertFrom-Json
    $retired = [ordered]@{}
    foreach ($row in @($steam.history) + @($previous.steamCatalog.history) +
        @($previous.steamCatalog.builds) + @($previous.steamCatalog.java8Builds)) {
        if ($null -eq $row) { continue }
        $key = "$($row.fileName.ToLowerInvariant())|$($row.sizeBytes)|$($row.sha256.ToLowerInvariant())"
        $cacheId = if ($row.cacheFileId) { $row.cacheFileId } else {
            [long]::Parse($row.sha256.Substring(0, 15), [Globalization.NumberStyles]::HexNumber,
                [Globalization.CultureInfo]::InvariantCulture) + 1
        }
        $retired[$key] = [ordered]@{
            fileName = $row.fileName; sizeBytes = $row.sizeBytes; sha256 = $row.sha256
            cacheFileId = $cacheId; downloadUrl = $row.downloadUrl
        }
    }
    if ($retired.Count -gt 1024) { throw 'Steam cleanup history exceeds the reader limit.' }
    $steam.history = @($retired.Values)
}
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
    steamCatalog = $steam
}
$catalog | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $output 'catalog.json') -Encoding utf8
Write-Host "Created component catalog $Tag from $SourceCommit."
