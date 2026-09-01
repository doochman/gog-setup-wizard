# GOG Companion for Heroic

**A single bash script that reverse-engineers how Heroic actually runs your
GOG games — then fixes the ones that are broken, automatically.**

Not "install some packages and hope." This script reads Heroic's own
`GamesConfig`, matches the *exact* Proton build it configured per game,
replicates Heroic's on-disk prefix layout byte-for-byte, and works around
three separate real-world Wine/Winetricks/Flatpak bugs it took actual
reverse-engineering to find (see [below](#under-the-hood)). If you've ever
wondered *why* winetricks silently does nothing on your Proton prefix, or why
Flathub randomly throws `GPG verification enabled, but no summary found` —
you'll want to read that section.

It's built to be the companion the [Heroic Games
Launcher](https://heroicgameslauncher.com/) doesn't ship with: a CLI that
knows what's installed, what's ready, and what to run next.

## What it does

1. **System setup** — installs Wine, Winetricks, DOSBox, ScummVM, 32-bit
   graphics/audio libraries, Flatpak/Flathub, Heroic/Lutris, ProtonUp-Qt, and
   `cnc-ddraw` for the classic DirectDraw black-screen bug.
2. **Game registry & doctor** — scans your GOG install directory, cross
   references Heroic's own config to find each game's real Wine/Proton
   prefix, classifies each game's runtime (Wine vs. native DOSBox/ScummVM),
   and tells you exactly what's ready and what isn't.
3. **Autonomous patching** — creates missing Wine prefixes from scratch using
   the *exact* Proton build Heroic already picked, then installs missing
   redistributables into them. No manual `winecfg` fiddling.

Run against a real 52-game Heroic library, it took games from "haven't been
launched once" to fully verified and dependency-complete without touching
Heroic itself.

## Quick start

```bash
chmod +x gog-setup.sh

# First run: install everything, then scan + verify your games
./gog-setup.sh

# See what's ready and what isn't, with next-step suggestions
./gog-setup.sh list

# Auto-create missing Wine prefixes and install missing dependencies
./gog-setup.sh patch
```

## Commands

| Command  | What it does |
|----------|---------------|
| `all`    | System setup, then scan + verify your games (default when no command is given) |
| `setup`  | Install/refresh system packages, Wine, launchers and tools only |
| `scan`   | Scan the games directory and (re)build the game registry |
| `verify` | Check each registered game's executable, Wine prefix and dependencies |
| `patch`  | Scan, auto-create missing Wine prefixes, install missing dependencies, then list |
| `list`   | Print the current game registry with a colorized ready/status table + progress bar |
| `doctor` | Scan + verify + list, without touching system packages |
| `logs`   | Show the last 200 lines of the companion log |
| `help`   | Show usage |

## Options

| Option | Description |
|--------|-------------|
| `-d, --games-dir <path>` | Games directory to scan (default: `~/Games/Heroic`) |
| `-y, --yes` | Non-interactive mode (assume yes / pick sensible defaults) |
| `-f, --fix` | Auto-install missing Winetricks components during `verify` |
| `-h, --help` | Show usage |

## Architecture

```mermaid
flowchart LR
    A[installed.json] -->|authoritative install list| D[Game Registry]
    B["goggame-&lt;id&gt;.info"] -->|name + primary exe| D
    C["GamesConfig/&lt;id&gt;.json"] -->|Wine prefix + Proton build| D
    D --> E{engine?}
    E -->|wine| F[check exe / prefix / winetricks verbs]
    E -->|dosbox or scummvm| G[check emulator installed + game data present]
    F -->|patch| H[create prefix with Heroic's exact Proton build]
    H --> I[flatten compatdata layout to match Heroic]
    F -->|patch| J[install missing verbs via matching Wine build]
```

Every game is classified by **engine**, detected from its manifest's primary
launch task:

- **`wine`** — a Windows game running under Wine/Proton. Verified by
  checking the executable, the Wine prefix, and a set of common
  redistributables (`corefonts`, `vcrun2019`, `d3dx9`, `xact`, `xact_x64`).
- **`dosbox` / `scummvm`** — classic titles Heroic runs with its bundled
  emulator, never touching Wine at all. The script only checks the emulator
  binary is installed and the game data is present — trying to verify a Wine
  prefix for these produces nothing but false negatives.

## Under the hood

This is the part that was actually fun. Getting `patch` to reliably work
required reverse-engineering three independent, undocumented failure modes:

### 1. Winetricks can't find `wineserver` on Debian/Ubuntu

Debian/Ubuntu's `wine` package installs `wineserver` at
`/usr/lib/x86_64-linux-gnu/wine/wineserver` — a path that isn't in
winetricks' hardcoded search list (which only checks `.../wine/bin/wineserver`,
with a `/bin/`). Every winetricks call aborted with `warning: wineserver not
found!` and quietly did nothing. Fix: resolve the real binary ourselves and
pass it through winetricks' own `WINESERVER=` override.

### 2. Proton's `explorer.exe` deadlocks `winetricks list-installed`

`STEAM_COMPAT_DATA_PATH=... proton run wineboot --init` leaves a persistent
`explorer.exe /desktop` session running (normal Proton session behavior).
`winetricks list-installed` calls `wineserver -w` — *wait for every wine
process in this prefix to exit* — and hangs forever, because that
`explorer.exe` is designed to never exit. Fix: kill it with the matching
`wineserver -k` immediately after every prefix operation, and wrap every
winetricks/Proton call in `timeout` as defense in depth.

### 3. System Wine can't run programs inside a Proton-created prefix

Even after fixing the above, `vcrun2015` failed with `Library shlwapi.dll ...
not found` — a *real* DLL loader failure, not a config issue. Proton's
bundled Wine build populates a prefix's `system32` with its own builtin DLL
set; running the *system* wine binary against that prefix causes symbol
resolution failures because the two builds' internal DLL implementations
don't match. Fix: resolve each game's exact Proton build from Heroic's
`GamesConfig/<id>.json` and point winetricks' `WINE=` override at
`<proton_dir>/files/bin/wine` — the *same* binary Heroic itself would use.

### 4. Proton's prefix layout vs. Heroic's layout

A vanilla `proton run wineboot --init` produces
`$STEAM_COMPAT_DATA_PATH/{config_info,tracked_files,version,pfx/{drive_c,system.reg,...}}`.
Heroic's real prefixes instead have `drive_c`/`system.reg` **directly** at the
top level, with `pfx` as a self-symlink (`pfx -> .`). This was reverse
engineered by diffing a sandboxed test prefix against a real
Heroic-launched one, byte for byte. `init_wine_prefix()` replicates the
flattening step so a script-created prefix is indistinguishable from one
Heroic created itself.

### 5. Flathub's summary/GPG errors

A `flathub` remote added with the wrong URL (`https://flathub.org` instead of
the real repo `https://dl.flathub.org/repo/`) or missing its GPG key makes
`remote-add --if-not-exists` silently keep the broken config forever —
`flatpak install` then fails with `GPG verification enabled, but no summary
found`, crashing the whole script under `set -e`. Fix: verify the remote
actually resolves a single-branch ref (`com.heroicgameslauncher.hgl` — using
`org.freedesktop.Platform` here gives a false negative since it has multiple
branches), and if not, `remote-delete --force` + re-add from the official
`.flatpakrepo` bootstrap.

### 6. Killing wineserver too eagerly causes its own race

The fix for #2 (kill wineserver after a prefix operation) initially ran after
*every single* winetricks call, not just prefix creation. That forced a
wineserver cold-start on almost every verb, and its startup banner
(`wineserver: using server-side synchronization.`) would occasionally get
captured by winetricks' own internal `%AppData%` detection instead of the
real value, making `corefonts` fail non-deterministically — confirmed by
diffing dozens of runs in the log: identical prefix, identical verb,
different outcome, only the timing changed. Fix: only kill wineserver once,
right after prefix creation (where the *real* problem — Proton's persistent
`explorer.exe` — actually lives), and let it stay warm for the rest of a
game's verify pass. A one-shot automatic retry on failure was added on top,
since even a reduced cold-start rate doesn't make the race impossible.

### 7. `vcrun2019` "failing" right after `vcrun2015` succeeds

Every single time `vcrun2015` installed successfully, the very next verb —
`vcrun2019` — failed. Every time. That's not a race, that's a rule:
winetricks refuses to install `vcrun2019` over an existing `vcrun2015`
(`vcrun2019 conflicts with vcrun2015, which is already installed`) because
`vcrun2019` is a strict superset redistributable. Requesting both was simply
a bug in the default verb list. Fix: drop `vcrun2015` from the wanted list,
and treat an already-installed `vcrun2015` (from a prefix patched before this
fix) as satisfying the requirement instead of trying, and failing, to install
`vcrun2019` over it.

### 8. `vc_redist.x86.exe` exits with status 102 — missing 32-bit libgnutls

`vcrun2019`'s installer would run and then abort with
`command ... vc_redist.x86.exe /q returned status 102`, with
`err:winediag:gnutls_process_attach failed to load libgnutls, no support for
encryption` a few lines above it in the log. The 64-bit `libgnutls30` was
installed system-wide, but `vc_redist.x86.exe` runs 32-bit under Wine's WoW64
layer and needs the **i386** build, which apt never pulls in on its own.
Fix: `setup` now also installs `libgnutls30t64:i386` (falling back to
`libgnutls30:i386` on older Ubuntu releases without the `t64` transition).

### 9. Microsoft silently updates `vc_redist.x86.exe`, breaking winetricks' pinned checksum

`vcrun2019` would fail with `SHA256 mismatch! ... This is often the result of
an updated package such as vcrun2019.` — a well-known, common winetricks/MSVC
redistributable issue: Microsoft's `aka.ms/vs/16/release/vc_redist.x86.exe`
"latest" link is a moving target, and this winetricks release's pinned hash
had gone stale. The file is still a legitimate download over HTTPS from
Microsoft's own CDN, so this is safe to bypass rather than treat as fatal.
Fix: after 2 normal attempts, a 3rd automatic attempt adds winetricks'
`--force` flag, which skips just that checksum check.

### 10. One prefix stayed broken even with every fix above — it was corrupted, not cursed

After all of the above, 51/52 games installed cleanly — but Worms 2 kept
failing `vcrun2019` with exit status 102 (installer-level failure, not a
checksum or missing-library issue this time). The difference: that exact
prefix had been touched dozens of times during the debugging above — by
system Wine before the `WINE=` override fix, by concurrent patch runs before
the lock existed, and by a manual `kill -9` during the very first hang
investigation. Renaming the prefix out of the way
(`mv "Prefixes/Worms 2" "Prefixes/Worms 2.bak"`) and letting `patch` recreate
it from scratch fixed it immediately — `vcrun2019` installed clean on the
first try. Lesson for future debugging: if one game keeps failing after every
other game succeeds with the same fix, suspect prefix corruption (especially
a prefix that was manually poked at) before chasing a new script bug.

## How the registry is built

`scan` writes `~/.config/gog-companion/registry.json`, one entry per game,
combining:

- **Heroic's `gog_store/installed.json`** — authoritative install list
  (`appName` = GOG id, `install_path`).
- **`goggame-<id>.info`** manifests — name and primary executable
  (case-insensitive fallback lookup, since manifests and actual files
  sometimes disagree on case).
- **Heroic's `GamesConfig/<id>.json`** — the exact Wine prefix and
  Proton/Wine build Heroic is configured to use.

Every action — scans, verifies, prefix creation, winetricks installs — is
logged to the terminal *and* to `~/.config/gog-companion/gog-companion.log`,
so a `patch` run left going in the background overnight is fully auditable
with `./gog-setup.sh logs`.

## Requirements

- Ubuntu or a Debian-based distro with `apt`, run as a regular (non-root) user
  with `sudo` access.
- An internet connection for package/Flatpak/Winetricks downloads.

## Notes & known quirks

- Running `patch` across many games can take a while — winetricks downloads
  and installs real redistributables per prefix (a single `corefonts` run can
  take ~2 minutes). It's safe to run in the background
  (`nohup ./gog-setup.sh patch & disown`) and check progress later with
  `./gog-setup.sh list` or `logs`.
- Don't run two `patch`/`verify` instances at the same time — they both
  read-modify-write `registry.json` and could both grab the same Wine prefix
  concurrently.
- A Winetricks verb can still occasionally fail on experimental Wine/Proton
  WoW64 builds even after the fixes above (a one-shot automatic retry
  handles most of these); a persistent failure is logged as a warning and
  the script moves on rather than stopping.
- Prefix auto-creation only works for Proton runners (which is what every
  Heroic-managed GOG install currently uses). A game configured with plain
  Wine falls back to "launch it once in Heroic" guidance.

## Roadmap

Ideas worth doing next, roughly in order of "would make this more magical":

- [x] ~~**Concurrency lock**~~ — done: `flock` on `~/.config/gog-companion/companion.lock`,
      held for the process's lifetime; `scan`/`verify`/`patch`/`doctor`/`all`
      refuse to run twice at once instead of racing.
- [ ] **Plain-Wine runner support** — extend `init_wine_prefix` beyond
      Proton (`wine`/`wineboot` directly) for non-Proton Heroic configs.
- [ ] **Per-game verb overrides** — some games need extra Winetricks verbs
      (`dxvk`, `d3dcompiler_47`, `faudio`) beyond the generic set; let a game
      declare its own list, keyed by GOG id, instead of one-size-fits-all.
      Possibly seeded from community-maintained fix data (à la
      [ProtonDB](https://www.protondb.com/) or Heroic's own
      `protonfixes`/`ProtonFixesRoot`).
- [ ] **`--only <game>` filter** — patch/verify a single game instead of the
      whole library, for fast iteration.
- [ ] **Parallel patching** — process independent prefixes concurrently
      (bounded by CPU/network) instead of strictly serial.
- [ ] **JSON/`--quiet` output mode** — machine-readable `list` output for
      scripting or a future TUI/GUI front-end.
- [ ] **Steam/non-GOG source support** — generalize the registry beyond
      `goggame-*.info` manifests to cover sideloaded and Amazon-store titles
      Heroic also manages.
- [ ] **Self-test suite** — a `bats`/shellspec test harness around the pure
      logic (manifest parsing, engine detection, prefix flattening) so
      regressions like the ones documented above get caught automatically.
- [ ] **Health-check command for Heroic itself** — detect a broken Heroic
      install/config (corrupt `GamesConfig`, missing Proton builds) and
      offer to repair it, the same way `setup` repairs Flathub.

Contributions, bug reports, and "I found a fourth undocumented Wine/Proton
gotcha" reports are all welcome.

## License

MIT

# gog-setup-wizard
