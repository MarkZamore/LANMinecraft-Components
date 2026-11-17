#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$DownloadDirectory,
      [Parameter(Mandatory)][string]$StagingDirectory,[string]$Tag='desktop-components-1',[string]$SourceCommit='')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/DesktopPacket.ps1"
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$SourceCommit) { $SourceCommit=(& git -C $repository rev-parse HEAD).Trim() }
if ($SourceCommit -cnotmatch '^[0-9a-f]{40}$' -or $Tag -cnotmatch '^desktop-components-[A-Za-z0-9._-]+$') { throw 'Invalid immutable source revision/tag.' }
foreach ($directory in @($OutputDirectory,$DownloadDirectory,$StagingDirectory)) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($directory)) }
$pins=Get-Content "$repository/data/desktop-runtime-sources.json" -Raw | ConvertFrom-Json
$runtime=Join-Path $StagingDirectory 'desktop-runtime'
[void][IO.Directory]::CreateDirectory($runtime)
foreach ($pin in $pins.sources) {
    $archive=Join-Path $DownloadDirectory $pin.fileName
    if (!(Test-Path -LiteralPath $archive)) {
        Invoke-WebRequest -Uri $pin.url -OutFile "$archive.part"
        Move-Item -LiteralPath "$archive.part" -Destination $archive
    }
    if ((Get-Item -LiteralPath $archive).Length -ne $pin.sizeBytes -or (Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash.ToLowerInvariant() -cne $pin.sha512) { throw 'Official Microsoft archive pin mismatch.' }
    $zip=[IO.Compression.ZipFile]::OpenRead($archive)
    try {
        foreach ($entry in $zip.Entries) {
            if (!$entry.Name) { continue }
            Assert-DesktopRelativePath $entry.FullName
            if ($entry.FullName.StartsWith('sdk/') -or $entry.FullName.StartsWith('shared/Microsoft.AspNetCore.App/')) { throw 'Unintended SDK/ASP.NET runtime.' }
            $target=Join-Path $runtime $entry.FullName
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            if (Test-Path -LiteralPath $target) {
                $existing=[IO.File]::OpenRead($target); $incoming=$entry.Open()
                try { if (![Security.Cryptography.CryptographicOperations]::FixedTimeEquals([Security.Cryptography.SHA256]::HashData($existing),[Security.Cryptography.SHA256]::HashData($incoming))) { throw 'Conflicting official runtime archives.' } }
                finally { $existing.Dispose(); $incoming.Dispose() }
            } else { [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$false) }
        }
    } finally { $zip.Dispose() }
}
$runtimes=@(& "$runtime/dotnet.exe" --list-runtimes)
if ($LASTEXITCODE -ne 0 -or $runtimes.Count -ne 2 -or !($runtimes -match '^Microsoft.NETCore.App 10\.0\.14 ') -or !($runtimes -match '^Microsoft.WindowsDesktop.App 10\.0\.14 ')) { throw 'The official private runtime layout is invalid.' }
$assets=Join-Path $StagingDirectory 'assets'; $steam=Join-Path $StagingDirectory 'steam-native'
[void][IO.Directory]::CreateDirectory($assets); [void][IO.Directory]::CreateDirectory($steam)
Copy-Item -LiteralPath "$repository/Program/Assets/Background.png" -Destination "$assets/Background.png" -Force
Copy-Item -LiteralPath "$repository/Program/MinecraftWindowIconAssets.jar" -Destination "$assets/MinecraftWindowIconAssets.jar" -Force
Copy-Item -LiteralPath "$repository/Program/Native/steam_api64.dll","$repository/Program/Native/LICENSE.steamworks-net.txt" -Destination $steam -Force
$definitions=@(
    @{kind='desktop-runtime';id='dotnet-10.0.14-win-x64';entryPath='host/fxr/10.0.14/hostfxr.dll';source=$runtime},
    @{kind='assets';id='launcher-assets-1';entryPath='Background.png';source=$assets},
    @{kind='steam-native';id='steam-native-1';entryPath='steam_api64.dll';source=$steam})
$components=@(); $checks=@()
foreach ($definition in $definitions) {
    $packet=Join-Path $OutputDirectory ($definition.id+'.pak'); $manifest=Join-Path $OutputDirectory ($definition.kind+'.manifest')
    $result=Write-DesktopPacket -SourceDirectory $definition.source -EntryPath $definition.entryPath -PacketPath $packet -ManifestPath $manifest
    $component=[ordered]@{kind=$definition.kind;id=$definition.id;url="https://github.com/MarkZamore/LANMinecraft-Components/releases/download/$Tag/$($definition.id).pak";apiUrl='';entryPath=$definition.entryPath;sizeBytes=$result.sizeBytes;sha256=$result.sha256;manifestSizeBytes=$result.manifestSizeBytes;manifestSha256=$result.manifestSha256}
    if ($definition.kind -eq 'desktop-runtime') { $component.runtimeVersion=$pins.runtimeVersion }
    $checks+=Test-DesktopPacket -Component ([pscustomobject]$component) -PacketPath $packet -ManifestPath $manifest
    $components+=[pscustomobject]$component
}
$catalog=[ordered]@{schemaVersion=1;protocolVersion=1;revision=$Tag;sourceCommit=$SourceCommit;components=$components}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'desktop-components.json'),($catalog|ConvertTo-Json -Depth 10)+"`n",[Text.UTF8Encoding]::new($false))
[pscustomobject]@{catalog=(Join-Path $OutputDirectory 'desktop-components.json');runtimeList=$runtimes;checks=$checks;components=$components}
