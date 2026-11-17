#requires -Version 7.2
Set-StrictMode -Version Latest

function Assert-DesktopRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [Text.Encoding]::UTF8.GetByteCount($Path) -gt 1024 -or
        $Path.Contains('\') -or $Path.StartsWith('/') -or $Path.Contains(':') -or $Path -match '[\x00-\x1f\x7f]') { throw "Unsafe component path: $Path" }
    foreach ($part in $Path.Split('/')) {
        if (!$part -or $part -in @('.','..') -or $part.StartsWith(' ') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or
            $part.Length -gt 255 -or $part -match '[<>"|?*]' -or
            $part -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[0-9\u00b9\u00b2\u00b3]|LPT[0-9\u00b9\u00b2\u00b3])(?:\..*)?$') { throw "Unsafe component path: $Path" }
    }
}

function Get-DesktopSha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Assert-DesktopOrdinaryPath([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while ($cursor) {
        try { if ([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) { throw "Component path contains a reparse point: $cursor" } }
        catch [IO.FileNotFoundException] { }
        catch [IO.DirectoryNotFoundException] { }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}

function Write-DesktopBytesAtomic([string]$Path,[byte[]]$Bytes) {
    Assert-DesktopOrdinaryPath $Path
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    $output=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $output.Write($Bytes); $output.Flush($true) } finally { $output.Dispose() }
    Assert-DesktopOrdinaryPath $Path
    [IO.File]::Move($temporary,$Path,$true)
}

function Copy-DesktopFileAtomic([string]$Source,[string]$Target) {
    Assert-DesktopOrdinaryPath $Target
    $temporary=$Target+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    $output=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $input=[IO.File]::OpenRead($Source)
    try { $input.CopyTo($output); $output.Flush($true) } finally { $input.Dispose(); $output.Dispose() }
    Assert-DesktopOrdinaryPath $Target
    [IO.File]::Move($temporary,$Target,$true)
}

function Write-DesktopPacket {
    param([string]$SourceDirectory, [string]$EntryPath, [string]$PacketPath, [string]$ManifestPath)
    Assert-DesktopRelativePath $EntryPath
    $source = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\','/')
    $files = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($source)
    while ($pending.Count) {
        $directory = $pending.Pop()
        if ([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) { throw 'Component directory is a reparse point.' }
        foreach ($item in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $attributes = [IO.File]::GetAttributes($item)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Component entry is a reparse point.' }
            if ($attributes -band [IO.FileAttributes]::Directory) { $pending.Push($item); continue }
            $path = [IO.Path]::GetRelativePath($source,$item).Replace('\','/')
            Assert-DesktopRelativePath $path
            if ($files.ContainsKey($path)) { throw 'Case-insensitive component path collision.' }
            $files.Add($path,[pscustomobject]@{ Source=$item; Length=([IO.FileInfo]$item).Length; Sha256=(Get-DesktopSha256 $item) })
        }
    }
    if ($files.Count -lt 1 -or $files.Count -gt 4096 -or !$files.ContainsKey($EntryPath)) { throw 'Invalid component entry/file count.' }
    $paths = [string[]]@($files.Keys); [Array]::Sort($paths,[StringComparer]::Ordinal)
    $table = [IO.MemoryStream]::new(); $tableWriter = [IO.BinaryWriter]::new($table,[Text.Encoding]::UTF8,$true)
    $entry = [Text.Encoding]::UTF8.GetBytes($EntryPath); $tableWriter.Write($entry); $dataLength = [long]0
    try {
        foreach ($path in $paths) {
            $file=$files[$path]; $name=[Text.Encoding]::UTF8.GetBytes($path)
            $tableWriter.Write([uint32]$name.Length); $tableWriter.Write($name)
            $tableWriter.Write([uint64]$dataLength); $tableWriter.Write([uint64]$file.Length)
            $tableWriter.Write([Convert]::FromHexString($file.Sha256)); $dataLength += $file.Length
        }
        $tableWriter.Flush()
        if ($table.Length -gt 8MB -or 72+$table.Length+$dataLength -gt 512MB) { throw 'Component packet exceeds bounds.' }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($PacketPath)))
        $stream=[IO.FileStream]::new($PacketPath,[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $writer=[IO.BinaryWriter]::new($stream,[Text.Encoding]::UTF8,$true)
        $bodyHash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
        try {
            $writer.Write([Text.Encoding]::ASCII.GetBytes('LMHOST01')); $writer.Write([uint32]1)
            $writer.Write([uint32]$paths.Length); $writer.Write([uint32]$entry.Length); $writer.Write([uint32]0)
            $writer.Write([uint64]$table.Length); $writer.Write([uint64]$dataLength); $writer.Write([byte[]]::new(32))
            $bytes=$table.ToArray(); $writer.Write($bytes); $bodyHash.AppendData($bytes)
            $buffer=[byte[]]::new(65536)
            foreach ($path in $paths) {
                $file=$files[$path]; $input=[IO.File]::OpenRead($file.Source)
                $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256); $copied=[long]0
                try {
                    while (($count=$input.Read($buffer,0,$buffer.Length)) -gt 0) {
                        if ($count -gt $file.Length-$copied) { throw 'Component source grew while packaging.' }
                        $writer.Write($buffer,0,$count); $bodyHash.AppendData($buffer,0,$count); $hash.AppendData($buffer,0,$count); $copied+=$count
                    }
                    if ($copied -ne $file.Length -or [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant() -cne $file.Sha256) { throw 'Component source changed while packaging.' }
                } finally { $input.Dispose(); $hash.Dispose() }
            }
            $writer.Flush(); $stream.Position=40; $writer.Write($bodyHash.GetHashAndReset()); $writer.Flush(); $stream.Flush($true)
            $stream.Position=0; $prefix=[byte[]]::new([int](72+$table.Length)); $stream.ReadExactly($prefix)
            [IO.File]::WriteAllBytes($ManifestPath,$prefix)
        } finally { $bodyHash.Dispose(); $writer.Dispose(); $stream.Dispose() }
    } finally { $tableWriter.Dispose(); $table.Dispose() }
    [pscustomobject]@{ sizeBytes=([IO.FileInfo]$PacketPath).Length; sha256=(Get-DesktopSha256 $PacketPath); manifestSizeBytes=([IO.FileInfo]$ManifestPath).Length; manifestSha256=(Get-DesktopSha256 $ManifestPath); fileCount=$paths.Length; dataLength=$dataLength }
}

function Test-DesktopPacket {
    param([Parameter(Mandatory)]$Component,[Parameter(Mandatory)][string]$PacketPath,[Parameter(Mandatory)][string]$ManifestPath,[string]$ExtractDirectory)
    Assert-DesktopOrdinaryPath $PacketPath
    Assert-DesktopOrdinaryPath $ManifestPath
    if ($ExtractDirectory) { Assert-DesktopOrdinaryPath $ExtractDirectory }
    if (([IO.FileInfo]$PacketPath).Length -ne [long]$Component.sizeBytes -or (Get-DesktopSha256 $PacketPath) -cne $Component.sha256) { throw 'Component packet pin mismatch.' }
    if ($Component.sizeBytes -gt 512MB -or $Component.manifestSizeBytes -gt 8MB -or $Component.manifestSizeBytes -lt 72) { throw 'Component size is out of bounds.' }
    $stream=[IO.File]::OpenRead($PacketPath); $reader=[IO.BinaryReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true)
    try {
        $prefix=$reader.ReadBytes([int]$Component.manifestSizeBytes)
        if ($prefix.Length -ne $Component.manifestSizeBytes -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($prefix)).ToLowerInvariant() -cne $Component.manifestSha256) { throw 'Component manifest pin mismatch.' }
        $header=[IO.MemoryStream]::new($prefix,$false); $table=[IO.BinaryReader]::new($header,[Text.UTF8Encoding]::new($false,$true),$true)
        try {
            if ([Text.Encoding]::ASCII.GetString($table.ReadBytes(8)) -cne 'LMHOST01' -or $table.ReadUInt32() -ne 1) { throw 'Invalid component format.' }
            $count=$table.ReadUInt32(); $entryLength=$table.ReadUInt32(); $reserved=$table.ReadUInt32(); $tableLength=$table.ReadUInt64(); $dataLength=$table.ReadUInt64(); $bodySha=$table.ReadBytes(32)
            if ($count -lt 1 -or $count -gt 4096 -or $entryLength -gt 1024 -or $reserved -ne 0 -or 72+$tableLength -ne $prefix.Length -or $prefix.Length+$dataLength -ne $stream.Length) { throw 'Invalid component header bounds.' }
            $stream.Position=72
            if (![Security.Cryptography.CryptographicOperations]::FixedTimeEquals($bodySha,[Security.Cryptography.SHA256]::HashData($stream))) { throw 'Invalid component body hash.' }
            $entry=[Text.UTF8Encoding]::new($false,$true).GetString($table.ReadBytes([int]$entryLength)); Assert-DesktopRelativePath $entry
            if ($entry -cne $Component.entryPath) { throw 'Component entry mismatch.' }
            $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); $offset=[long]0; $lastPath=''; $found=$false
            for ($i=0;$i -lt $count;$i++) {
                $nameLength=$table.ReadUInt32()
                if ($nameLength -lt 1 -or $nameLength -gt 1024) { throw 'Invalid component path length.' }
                $name=[Text.UTF8Encoding]::new($false,$true).GetString($table.ReadBytes([int]$nameLength)); Assert-DesktopRelativePath $name
                $start=$table.ReadUInt64(); $length=$table.ReadUInt64(); $digest=$table.ReadBytes(32)
                if ($digest.Length -ne 32 -or !$seen.Add($name) -or ($i -gt 0 -and [StringComparer]::Ordinal.Compare($lastPath,$name) -ge 0) -or
                    $start -ne $offset -or $length -gt $dataLength-$offset) { throw 'Invalid component file table.' }
                $lastPath=$name; $offset+=[long]$length; if ($name -ceq $entry) { $found=$true }
                $stream.Position=$prefix.Length+[long]$start
                $fileHash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
                $output=$null; $temporary=''; $remaining=[long]$length
                try {
                    if ($ExtractDirectory) {
                        $target=Join-Path $ExtractDirectory $name
                        Assert-DesktopOrdinaryPath $target
                        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                        if ((Test-Path -LiteralPath $target) -and ([IO.File]::GetAttributes($target) -band [IO.FileAttributes]::ReparsePoint)) { throw 'Component extraction target is a reparse point.' }
                        $matches=(Test-Path -LiteralPath $target -PathType Leaf) -and ([IO.FileInfo]$target).Length -eq $length -and
                            (Get-DesktopSha256 $target) -ceq [Convert]::ToHexString($digest).ToLowerInvariant()
                        if (!$matches) { $temporary=$target+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'; $output=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None) }
                    }
                    $buffer=[byte[]]::new(65536)
                    while ($remaining -gt 0) {
                        $read=$stream.Read($buffer,0,[int][Math]::Min($buffer.Length,$remaining)); if (!$read) { throw 'Truncated component file.' }
                        $fileHash.AppendData($buffer,0,$read); if ($output) { $output.Write($buffer,0,$read) }; $remaining-=$read
                    }
                    if (![Security.Cryptography.CryptographicOperations]::FixedTimeEquals($digest,$fileHash.GetHashAndReset())) { throw "Component file hash mismatch: $name" }
                    if ($output) { $output.Flush($true); $output.Dispose(); $output=$null; Assert-DesktopOrdinaryPath $target; [IO.File]::Move($temporary,$target,$true) }
                } finally { $fileHash.Dispose(); if ($output) { $output.Dispose() } }
            }
            if (!$found -or $offset -ne $dataLength -or $header.Position -ne $prefix.Length) { throw 'Invalid complete component table.' }
        } finally { $table.Dispose(); $header.Dispose() }
        Write-DesktopBytesAtomic $ManifestPath $prefix
        [pscustomobject]@{ fileCount=$count; entryPath=$entry; dataLength=$dataLength }
    } finally { $reader.Dispose(); $stream.Dispose() }
}
