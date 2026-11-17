# LANMinecraft Components

Canonical Java components and runtime catalogs for [LANMinecraft](https://github.com/MarkZamore/LANMinecraft). The launcher downloads only the artifacts selected by the compatibility rules, verifies their exact size and SHA-256, and shares cached content across packs.

`catalog.json` on `main` is the current catalog. Each `components-*` release contains its own immutable `catalog.json`, the identity adapter, notice overlay, native interoperability agent and legacy Forge installer class. Its `sourceCommit` names the exact component source revision. Component API 1 and the minimum launcher release determine reader compatibility.

Java archive locations remain exact Adoptium releases. Steam transport locations remain exact e4steam releases. `data/java-catalog.json` owns Java pins and Minecraft selection rules. `data/steam-components.json` owns Steam compatibility, historical cleanup pins and reviewed coverage. Pack content, personal settings and worlds belong to their existing owners.

## Build and verification

Use PowerShell 7 on Windows and a real JDK 25.0.2 with `java`, `javac` and `jar`. Published artifacts are built with Temurin 25.0.2 in CI. Other JDK distributions can add different `Created-By` metadata, so integration fixtures fetch the exact published artifacts and their hashes. Sources retain their `Program` directory so component tests and the ASM relocator have stable relative paths.

```powershell
$env:JAVA_HOME = 'C:\Tools\jdk-25.0.2'
./tools/Build-Components.ps1 -OutputDirectory artifacts/component-release/assets -VerifyReproducible
./Program/NoticeOverlay/Test-NoticeOverlay.ps1 -JarPath artifacts/component-release/assets/launcher-notice-agent.jar
```

Manual build runs use an owned `artifacts/agent-runs/<task-id>` directory with a `RUN.json` describing ownership, purpose, expected size and cleanup deadline. The build scripts place temporary classes beside the selected outputs and delete staging in `finally`. JAR timestamps are fixed so identical sources rebuild to identical bytes. The identity adapter targets Java 17, the other delivered helpers target Java 8.

## Publication

Commit reviewed sources and data to `main`, then create a new immutable `components-*` tag at that commit. GitHub Actions builds and verifies the four artifacts, uploads all payloads and the release catalog, then updates `main/catalog.json` last. Existing release tags and assets are never overwritten. The launcher can continue using the last verified catalog and its locally available components while offline.

Catalog generation carries forward the previous published Steam builds and historical exact-file pins as cleanup history. Updating a current Steam entry therefore retains the evidence needed to recognize its previously installed bytes. This history contains metadata, while release assets contain the selected components.

The first source import preserves the tracked Java trees and catalog data from the LANMinecraft repository. Historical Steam metadata records hashes for recognizing old installed files; historical payloads are not republished.

## Launcher compatibility contract

Before publishing a component candidate, CI checks it against `MarkZamore/LANMinecraft` at `main`. The candidate catalog references the current component source commit, and the exact candidate source is checked out under the launcher's isolated test source directory. `LANMINECRAFT_COMPONENT_TEST_CANDIDATE` selects the newly built payloads for Release with adapters and the full adapter matrix. A failing contract prevents release publication. Successful branch checks exercise the same candidate path without publishing assets or changing the current catalog.

`Program/IdentityAdapters/Common/Verify-IdentityAdapter.ps1` replays a prepared game's saved aliases. It reads only the current `Minecraft/Launcher/Components/configurations` tree and resolves the saved adapter from the shared `Components/objects/<sha256>` cache. Use `-InstallRoot` for the Minecraft data directory, `-JavaHome` for the chosen JDK and `-StateJson` to select a particular pack's saved state. The optional `-LauncherSourceRoot` locates the launcher's modern authlib semantic verifier when the component sources live outside the usual `LocalSources` checkout.
