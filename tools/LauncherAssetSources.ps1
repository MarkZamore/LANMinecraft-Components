#requires -Version 7.2

function Initialize-LauncherAssetStage([string]$Repository, [string]$StagingDirectory) {
    $repository = [IO.Path]::GetFullPath($Repository)
    Assert-DesktopOrdinaryPath $StagingDirectory
    [void][IO.Directory]::CreateDirectory($StagingDirectory)
    $inputs = Get-Content -LiteralPath "$repository/data/launcher-assets-sources.json" -Raw | ConvertFrom-Json
    if ($inputs.schemaVersion -ne 1 -or !$inputs.files) { throw 'Invalid launcher assets inventory.' }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$expected.Add('Background.png')
    [void]$expected.Add('MinecraftWindowIconAssets.jar')
    foreach ($entry in $inputs.files) {
        Assert-DesktopRelativePath $entry.path
        if ($entry.path -cnotmatch '^(Icons/(back|chevron|requirements-dot|trash)\.svg|LibrarySeed/[a-z0-9][a-z0-9_-]{0,79}\.zip)$' -or
            $entry.sizeBytes -le 0 -or $entry.sizeBytes -gt 16MB -or $entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or !$expected.Add($entry.path)) {
            throw 'Invalid or repeated launcher asset inventory path.'
        }
        $source = Join-Path "$repository/Program/Assets/LauncherDesktop" $entry.path
        $target = Join-Path $StagingDirectory $entry.path
        Assert-DesktopOrdinaryPath $source
        Assert-DesktopOrdinaryPath $target
        if ((Get-Item -LiteralPath $source).Length -ne $entry.sizeBytes -or (Get-DesktopSha256 $source) -cne $entry.sha256) {
            throw "Launcher asset source differs from its pin: $($entry.path)"
        }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($target)))
        Copy-DesktopFileAtomic $source $target
    }
    foreach ($icon in @('back','chevron','requirements-dot','trash')) {
        if (!$expected.Contains("Icons/$icon.svg")) { throw "Missing launcher SVG: $icon" }
    }
    Copy-DesktopFileAtomic "$repository/Program/Assets/Background.png" (Join-Path $StagingDirectory 'Background.png')
    Copy-DesktopFileAtomic "$repository/Program/MinecraftWindowIconAssets.jar" (Join-Path $StagingDirectory 'MinecraftWindowIconAssets.jar')
    $staging = [IO.Path]::GetFullPath($StagingDirectory)
    $actual = @(Get-ChildItem -LiteralPath $staging -Recurse -File | ForEach-Object {
        [IO.Path]::GetRelativePath($staging,$_.FullName).Replace('\','/')
    })
    if (!$expected.SetEquals([string[]]$actual)) { throw 'Launcher asset staging contains unintended files.' }
}
