#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ArtifactsDirectory)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/DesktopPacket.ps1"
[void][IO.Directory]::CreateDirectory($ArtifactsDirectory)
$source=Join-Path $ArtifactsDirectory 'source'
[void][IO.Directory]::CreateDirectory($source)
[IO.File]::WriteAllText((Join-Path $source 'A.bin'),'first',[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $source 'B.bin'),'second',[Text.UTF8Encoding]::new($false))
$packet=Join-Path $ArtifactsDirectory 'test.pak'; $manifest=Join-Path $ArtifactsDirectory 'test.manifest'
$result=Write-DesktopPacket -SourceDirectory $source -EntryPath A.bin -PacketPath $packet -ManifestPath $manifest
$component=[pscustomobject]@{entryPath='A.bin';sizeBytes=$result.sizeBytes;sha256=$result.sha256;manifestSizeBytes=$result.manifestSizeBytes;manifestSha256=$result.manifestSha256}
$null=Test-DesktopPacket -Component $component -PacketPath $packet -ManifestPath $manifest -ExtractDirectory (Join-Path $ArtifactsDirectory 'extracted')
if ((Get-DesktopSha256 (Join-Path $source 'A.bin')) -cne (Get-DesktopSha256 (Join-Path $ArtifactsDirectory 'extracted/A.bin'))) { throw 'Packet extraction differs from source.' }
$original=[IO.File]::ReadAllBytes($packet); $cases=[Collections.Generic.List[string]]::new()
function Assert-Rejected([string]$Name,[scriptblock]$Mutate,[bool]$Repin) {
    $bytes=[byte[]]$original.Clone(); & $Mutate $bytes
    if ($Repin) {
        $body=[Security.Cryptography.SHA256]::HashData([byte[]]$bytes[72..($bytes.Length-1)])
        [Array]::Copy($body,0,$bytes,40,32)
    }
    $path=Join-Path $ArtifactsDirectory ($Name+'.pak'); [IO.File]::WriteAllBytes($path,$bytes)
    $row=[pscustomobject]@{entryPath=$component.entryPath;sizeBytes=$bytes.Length;sha256=(Get-DesktopSha256 $path);manifestSizeBytes=$component.manifestSizeBytes;manifestSha256=$component.manifestSha256}
    if ($Repin) { $row.manifestSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$bytes[0..($component.manifestSizeBytes-1)])).ToLowerInvariant() }
    $failed=$false
    try { $null=Test-DesktopPacket -Component $row -PacketPath $path -ManifestPath (Join-Path $ArtifactsDirectory ($Name+'.manifest')) }
    catch { $failed=$true }
    if (!$failed) { throw "Unsafe packet was accepted: $Name" }
    $cases.Add($Name)
}
Assert-Rejected 'body-tamper' {param($b) $b[$b.Length-1]=$b[$b.Length-1] -bxor 1} $false
Assert-Rejected 'unsafe-path' {param($b) [Array]::Copy([Text.Encoding]::ASCII.GetBytes('../x!'),0,$b,81,5)} $true
Assert-Rejected 'case-collision' {param($b) [Array]::Copy([Text.Encoding]::ASCII.GetBytes('a.bin'),0,$b,138,5)} $true
Assert-Rejected 'file-hash' {param($b) $b[102]=$b[102] -bxor 1} $true
Assert-Rejected 'empty-count' {param($b) [Array]::Clear($b,12,4)} $true
Assert-Rejected 'reserved-header' {param($b) $b[20]=1} $true
foreach ($name in @('CONIN$','CONOUT$.txt','COM0.dll','LPT0','COM¹.bin')) {
    $rejected=$false
    try { Assert-DesktopRelativePath $name } catch { $rejected=$true }
    if (!$rejected) { throw 'A reserved Windows device path was accepted.' }
    $cases.Add('reserved-'+$name)
}
$shared=Join-Path $ArtifactsDirectory ('shared-'+[Guid]::NewGuid().ToString('N')+'.txt')
[IO.File]::WriteAllText($shared,'unchanged')
$alias=$shared+'.alias'
$null=New-Item -ItemType HardLink -Path $alias -Target $shared
Write-DesktopBytesAtomic $alias ([Text.Encoding]::UTF8.GetBytes('replacement'))
if ([IO.File]::ReadAllText($shared) -cne 'unchanged') { throw 'Atomic byte replacement modified another hard-link name.' }
$cases.Add('atomic-bytes-preserves-hardlink-source')
$copyAlias=$shared+'.copy-alias'
$null=New-Item -ItemType HardLink -Path $copyAlias -Target $shared
Copy-DesktopFileAtomic (Join-Path $source 'A.bin') $copyAlias
if ([IO.File]::ReadAllText($shared) -cne 'unchanged') { throw 'Atomic copy replacement modified another hard-link name.' }
$cases.Add('atomic-copy-preserves-hardlink-source')
$repair=Join-Path $ArtifactsDirectory ('repair-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($repair)
$null=New-Item -ItemType HardLink -Path (Join-Path $repair 'A.bin') -Target $shared
$null=Test-DesktopPacket -Component $component -PacketPath $packet -ManifestPath $manifest -ExtractDirectory $repair
if ([IO.File]::ReadAllText($shared) -cne 'unchanged' -or (Get-DesktopSha256 (Join-Path $repair 'A.bin')) -cne (Get-DesktopSha256 (Join-Path $source 'A.bin'))) { throw 'Extraction repair modified another hard-link name.' }
$cases.Add('atomic-extraction-preserves-hardlink-source')
[pscustomobject]@{status='PASS';roundtrip=$true;rejected=$cases;checks=1+$cases.Count}
