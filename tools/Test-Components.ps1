[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$output = [IO.Path]::GetFullPath($OutputDirectory)
$checks = 0
foreach ($name in @('portable-identity-adapter.jar', 'launcher-notice-agent.jar', 'launcher-native-interop-agent.jar')) {
    $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $output $name))
    try {
        if (-not $archive.GetEntry('META-INF/MANIFEST.MF')) { throw "Manifest missing in $name" }
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.StartsWith('org/objectweb/asm/', [StringComparison]::Ordinal)) {
                throw "Public ASM escaped into $name"
            }
            if (-not $entry.FullName.EndsWith('.class', [StringComparison]::Ordinal)) { continue }
            $stream = $entry.Open()
            try {
                $header = New-Object byte[] 8
                if ($stream.Read($header, 0, 8) -ne 8 -or $header[0] -ne 0xca -or $header[1] -ne 0xfe) {
                    throw "Invalid class in $name"
                }
                $maximum = if ($name -eq 'portable-identity-adapter.jar') { 61 } else { 52 }
                if ((256 * [int]$header[6] + [int]$header[7]) -gt $maximum) {
                    throw "Java class version exceeds the runtime floor in $name"
                }
                $checks++
            } finally { $stream.Dispose() }
        }
        if ($name -eq 'portable-identity-adapter.jar' -and -not $archive.GetEntry('portable-identity-hooks.jar')) {
            throw 'Identity bootstrap hooks are missing.'
        }
        if ($name -eq 'launcher-notice-agent.jar' -and -not $archive.GetEntry('portable-notice-hooks.jar')) {
            throw 'Notice bootstrap hooks are missing.'
        }
    } finally { $archive.Dispose() }
}
$installer = [IO.File]::ReadAllBytes((Join-Path $output 'LegacyForgeClientInstaller.class'))
if ($installer.Length -lt 8 -or $installer[0] -ne 0xca -or $installer[1] -ne 0xfe -or $installer[6] -ne 0 -or $installer[7] -ne 52) {
    throw 'Legacy Forge installer must remain a Java 8 class.'
}
Write-Host "Component packaging checks passed for $checks classes and the legacy installer."
