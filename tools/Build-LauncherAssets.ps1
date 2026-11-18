#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory,
      [Parameter(Mandatory)][string]$StagingDirectory,
      [string]$Tag='launcher-assets-2',
      [string]$SourceCommit='')

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/DesktopPacket.ps1"
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$SourceCommit) { $SourceCommit=(& git -C $repository rev-parse HEAD).Trim() }
if ($Tag -cnotmatch '^launcher-assets-[1-9][0-9]*$' -or $SourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid launcher assets tag/source commit.' }
foreach ($directory in @($OutputDirectory,$StagingDirectory)) {
    Assert-DesktopOrdinaryPath $directory
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($directory))
}
. "$PSScriptRoot/LauncherAssetSources.ps1"
Initialize-LauncherAssetStage $repository $StagingDirectory
$packet = Join-Path $OutputDirectory "$Tag.pak"
$manifest = Join-Path $OutputDirectory 'assets.manifest'
$entryPoint = 'Background.png'
$result = Write-DesktopPacket -SourceDirectory $StagingDirectory -EntryPath $entryPoint -PacketPath $packet -ManifestPath $manifest
$component = [ordered]@{
    kind='assets'; id=$Tag; url="https://github.com/MarkZamore/LANMinecraft-Components/releases/download/$Tag/$Tag.pak"; apiUrl=''
    entryPath=$entryPoint; sizeBytes=$result.sizeBytes; sha256=$result.sha256
    manifestSizeBytes=$result.manifestSizeBytes; manifestSha256=$result.manifestSha256
}
$null = Test-DesktopPacket -Component ([pscustomobject]$component) -PacketPath $packet -ManifestPath $manifest
$catalog = [ordered]@{ schemaVersion=1; protocolVersion=1; revision=$Tag; sourceCommit=$SourceCommit; component=$component }
Write-DesktopBytesAtomic (Join-Path $OutputDirectory 'launcher-assets.json') ([Text.UTF8Encoding]::new($false).GetBytes(($catalog|ConvertTo-Json -Depth 6)+"`n"))
[pscustomobject]$component
