# RimeDepot

RimeDepot is a standalone AutoHotkey v2 catalog browser and staged installer
for Rime packages. It uses the Rime Plum Package Index (RPPI), stores a local
cache, and never deploys installed files automatically.

## Run

Run the application from this directory:

```powershell
AutoHotkey.exe RimeDepotApp.ahk
```

Copy `RimeDepot.ini.example` to `RimeDepot.ini` before editing settings. The
GUI and INI use the same six fields:

| Field | Meaning |
| --- | --- |
| `CachePath` | RPPI index, archive, and Git cache directory |
| `RimeDirectory` | Rime user directory used as the installation destination |
| `RppiIndexUrl` | Root RPPI index URL |
| `Proxy` | Optional HTTP(S) proxy |
| `UseGit` | Direct-install default: explicitly enable the Git path (`0`/`1`); RPPI catalog installs always use archives |
| `GitPath` | Direct-install `git.exe` path; empty resolves through `PATH` |

API values override INI values. Git path resolution is API, then INI, then
`PATH`; only a direct `git.exe` is accepted. The standalone GUI has an RPPI
catalog mode and a Direct install mode. Direct mode accepts an owner/repository,
a GitHub repository/tree/commit URL, a GitHub browser or raw recipe URL, or an
explicit HTTP(S) `.zip` URL. Its optional ref field is used when the source does
not already identify a ref, or to disambiguate a slash-containing ref in a
recipe URL. A repository source checks only its root `recipe.yaml`; it does not
search subdirectories. A recipe URL selects its exact repository-relative path.
When no root recipe exists, direct installation uses the ordinary data-file
policy. RPPI selections always call the archive path, regardless of the
direct-install `UseGit` preference. Git operations use argument arrays and never
invoke a command shell, shell evaluation, or recipe commands. Branches, tags,
and commit SHAs are supported.

## Public API

Include `RimeDepot.ahk` for the facade. `RimeDepotService` exposes these
asynchronous operations:

- `LoadCatalog`
- `RefreshCatalog`
- `InstallEntry`
- `InstallDirect`
- `Cancel`

Catalog and direct installation intentionally have separate APIs. Direct calls
accept a locator string or `RimeDepotDirectInstallRequest`; structured requests
use `locator`, optional `ref`/`ref_kind`, optional `recipe_path`, `transport`
(`auto`, `archive`, or `git`), and recipe `parameters`. URL and path parsing is
owned by RimeDepot rather than its host application.

Each operation returns a cancellable job and reports progress, completion, and
errors through `RimeDepotCallbacks`. HTTP requests, archive extraction, and
Git processes are asynchronous so the GUI remains responsive; conflicting
controls are disabled while a job is active and cancellation is available.

## Catalog, cache, and installation safety

RPPI parent categories and child recipe indexes are loaded recursively. The
GUI keeps category display paths and provides searchable, filterable entries.
The cache commits each validated JSON body as a generation file, then atomically
replaces metadata that points to it. Reads verify the body filename, generation,
hash, URL, and cache directory; incomplete or mismatched pairs are rejected.
A failed refresh can fall back to the last complete generation with a visible
warning.

For the default `raw.githubusercontent.com` RPPI index, a normal catalog load
also probes GitHub's commits API and records the resulting full commit SHA in a
separate generation-backed normalized catalog snapshot. If the SHA is
unchanged, the complete catalog (including dependency-derived reverse links)
is restored locally without fetching the root or child indexes. A 40-character
SHA in the raw URL is already immutable and skips the probe. RefreshCatalog
always walks every raw index; custom index URLs retain the regular HTTP-cache
behavior. Snapshot bodies are written before their metadata pointer and are
accepted only when the root URL, schema, source list, generation path, and
hashes all validate. Probe failures use a valid prior snapshot with a warning;
without one, the normal full load remains the fallback. No GitHub token or
additional INI setting is required.

Installations are staged under the configured cache directory and are limited
to the configured Rime directory. Relative paths, archive ZIP names, recipe
globs, and Git refs are validated against traversal, absolute paths, and
reparse-point escapes. The supported recipe subset is data-only: safe
downloads, file globs, patches, scalar/default parameters, and nested mapping
or list patch data. Shell, executable, `eval`, command substitution, and
unsafe recipe forms are rejected.

RimeDepot does not deploy Rime data, resolve scheme conflicts, or provide an
uninstall operation. Real network access, Git credentials, and Windows Shell
ZIP extraction should be manually verified in an appropriate environment.

## Local tests

The tests use fake HTTP, Git, archive, and GUI dependencies; they do not use
the network, clone a repository, or show a GUI:

```powershell
AutoHotkey.exe /ErrorStdOut tests\RimeDepotLoadHarness.ahk
AutoHotkey.exe /ErrorStdOut tests\RimeDepotCoreProbe.ahk
AutoHotkey.exe /ErrorStdOut tests\RimeDepotGuiLoadHarness.ahk
AutoHotkey.exe /ErrorStdOut tests\integration\RimeDepotGuiMiniProbe.ahk
AutoHotkey.exe /ErrorStdOut tests\integration\RimeDepotGuiSmokeTest.ahk
```

The full GPL license text is in [`LICENSE`](LICENSE).
