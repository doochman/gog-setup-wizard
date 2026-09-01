#!/usr/bin/env bash
# ==============================================================================
#  GOG Gaming Suite & Compatibility Patcher for Ubuntu / Debian-based Linux
#  The perfect companion to the Heroic Games Launcher.
#
#  Adds a persistent game registry that scans your GOG install directory,
#  tracks each game's Wine prefix (via Heroic's own config) and verifies
#  that common runtime dependencies are installed.
#
#  Author: Open Source Community / Made for Linux Gaming Enthusiasts
#  License: MIT
# ==============================================================================

set -e

# --- Color Formatting ---
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Game Registry / Companion Settings ---
GAMES_DIR="${GOG_GAMES_DIR:-$HOME/Games/Heroic}"
CONFIG_DIR="$HOME/.config/gog-companion"
REGISTRY_FILE="$CONFIG_DIR/registry.json"
LOG_FILE="$CONFIG_DIR/gog-companion.log"
STEAM_FAKE_CLIENT_DIR="$CONFIG_DIR/fake-steam-client"
HEROIC_GAMES_CONFIG_DIR="$HOME/.config/heroic/GamesConfig"
HEROIC_INSTALLED_FILE="$HOME/.config/heroic/gog_store/installed.json"
LOCK_FILE="$CONFIG_DIR/companion.lock"
COMMAND="all"

# Every log_* call is echoed to the console (colored) and appended to
# LOG_FILE (plain, timestamped) so runs can be reviewed after the fact.
_log_to_file() {
    mkdir -p "$CONFIG_DIR"
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"
}

log_info() { echo -e "${BLUE}${BOLD}→${NC} $1"; _log_to_file "INFO" "$1"; }
log_success() { echo -e "${GREEN}${BOLD}✔${NC} $1"; _log_to_file "SUCCESS" "$1"; }
log_warn() { echo -e "${YELLOW}${BOLD}⚠${NC} $1"; _log_to_file "WARN" "$1"; }
log_error() { echo -e "${RED}${BOLD}✖${NC} $1"; _log_to_file "ERROR" "$1"; }
ASSUME_YES=false
AUTO_FIX=false
FLATPAK_OK=true

# scan/verify/patch/doctor/all all read-modify-write registry.json and can
# grab the same Wine prefix + shared winetricks download cache; refuse to
# run a second instance instead of silently racing (held for this process's
# lifetime via fd 200, released automatically on exit/crash).
acquire_lock() {
    mkdir -p "$CONFIG_DIR"
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log_error "Another '$SCRIPT_NAME' instance is already running (scan/verify/patch/doctor touch the same registry and Wine prefixes)."
        log_info "  If you're sure nothing is running, remove $LOCK_FILE and try again."
        exit 1
    fi
}

# Colored horizontal rule, sized to the terminal (capped so it stays readable).
# Built via printf's arg-cycling trick rather than tr, which mangles the
# multi-byte box-drawing character when substituting byte-by-byte.
repeat() {
    local char="$1" count="$2" out
    [ "$count" -le 0 ] && { echo ""; return 0; }
    printf -v out -- "${char}%.0s" $(seq 1 "$count")
    echo "$out"
}

hr() {
    local color="${1:-$CYAN}" width
    width=$(tput cols 2>/dev/null || echo 70)
    [ "$width" -gt 88 ] && width=88
    echo -e "${color}$(repeat '─' "$width")${NC}"
}

# Recommended Winetricks components most GOG/classic Windows games need.
# vcrun2019 is a superset of vcrun2015's redistributables and winetricks
# refuses to install both ("vcrun2019 conflicts with vcrun2015, which is
# already installed"), so only the newer one is requested here.
WANTED_VERBS=(corefonts vcrun2019 d3dx9 xact xact_x64)

# Debian/Ubuntu's wine package ships wineserver outside winetricks' own search
# path (e.g. /usr/lib/x86_64-linux-gnu/wine/wineserver, no /bin/ subdir), which
# makes winetricks abort with "wineserver not found!". Resolve it ourselves.
resolve_wineserver() {
    local c candidates=(
        "$(command -v wineserver 2>/dev/null)"
        /usr/lib/x86_64-linux-gnu/wine/wineserver
        /usr/lib/x86_64-linux-gnu/wine/bin/wineserver
        /usr/lib/i386-linux-gnu/wine/wineserver
        /usr/lib/wine/wineserver
    )
    for c in "${candidates[@]}"; do
        [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
    done
    echo ""
}

# All games in this Heroic library use a Proton runner, and Proton's bundled
# wine build populates each prefix's system32 with its own DLL set. Running
# winetricks with the *system* wine against a Proton-created prefix causes
# loader failures (missing builtin DLLs, wrong WoW64 layout), so whenever a
# game's runner is Proton we must point WINE/WINESERVER at that exact build.
# Prints "wine_bin<TAB>wineserver_bin", or two empty fields if not Proton.
resolve_proton_tools() {
    local id="$1" cfg="$HEROIC_GAMES_CONFIG_DIR/$id.json" runner_type proton_bin proton_dir wine_bin ws_bin

    if [ -f "$cfg" ]; then
        runner_type=$(jq -r --arg id "$id" '.[$id].wineVersion.type // empty' "$cfg" 2>/dev/null || true)
        proton_bin=$(jq -r --arg id "$id" '.[$id].wineVersion.bin // empty' "$cfg" 2>/dev/null || true)
    fi

    if [ "$runner_type" = "proton" ] && [ -n "$proton_bin" ]; then
        proton_dir=$(dirname "$proton_bin")
        wine_bin="$proton_dir/files/bin/wine"
        ws_bin="$proton_dir/files/bin/wineserver"
        if [ -x "$wine_bin" ] && [ -x "$ws_bin" ]; then
            printf '%s\t%s\n' "$wine_bin" "$ws_bin"
            return 0
        fi
    fi
    printf '\t\n'
}

print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
  ____  ___   ____   ____       _       _
 / ___|/ _ \ / ___| |  _ \ __ _| |_ ___| |__   ___ _ __
| |  _| | | | |  _  | |_) / _` | __/ __| '_ \ / _ \ '__|
| |_| | |_| | |_| | |  __/ (_| | || (__| | | |  __/ |
 \____|\___/ \____| |_|   \__,_|\__\___|_| |_|\___|_|
EOF
    echo -e "${NC}${DIM}      The perfect companion to the Heroic Games Launcher${NC}"
    echo ""
}

check_root() {
    if [ "$EUID" -eq 0 ]; then
        log_error "Please do NOT run this script as root/sudo directly."
        log_info "The script will prompt for sudo access when necessary."
        exit 1
    fi
}

enable_32bit() {
    log_info "Enabling 32-bit architecture (i386)..."
    sudo dpkg --add-architecture i386
    log_success "32-bit architecture enabled."
}

update_and_install_deps() {
    log_info "Updating package lists..."
    sudo apt-get update -y

    log_info "Installing core gaming libraries, 32-bit graphics/sound drivers, and utilities..."
    sudo apt-get install -y \
        software-properties-common \
        wget \
        curl \
        git \
        p7zip-full \
        unzip \
        cabextract \
        zenity \
        mesa-vulkan-drivers \
        mesa-vulkan-drivers:i386 \
        libgl1-mesa-dri:i386 \
        libgl1:i386 \
        libvulkan1 \
        libvulkan1:i386 \
        libasound2-plugins:i386 \
        libpulse0:i386 \
        gamemode \
        mangohud \
        flatpak \
        jq

    # 32-bit libgnutls is needed by some Winetricks-installed programs (e.g.
    # vcrun2019's vc_redist.x86.exe) for crypto support; without it they fail
    # with "failed to load libgnutls, no support for encryption" (exit 102).
    # Package name varies by Ubuntu release (t64 time_t transition), so try both.
    sudo apt-get install -y libgnutls30t64:i386 2>/dev/null \
        || sudo apt-get install -y libgnutls30:i386 2>/dev/null \
        || log_warn "Could not install 32-bit libgnutls; some Winetricks verbs may fail with encryption errors."

    log_success "Core packages and 32-bit dependencies installed."
}

setup_flatpak_flathub() {
    log_info "Configuring Flatpak and Flathub repository..."
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

    # A pre-existing "flathub" remote with the wrong URL (e.g. just
    # "https://flathub.org" instead of the real repo) or a missing GPG key
    # makes --if-not-exists silently keep the broken config, and every later
    # install fails with "Unable to load summary from remote flathub". Detect
    # that and repair it by re-adding the remote from the official bootstrap.
    if ! flatpak remote-info flathub com.heroicgameslauncher.hgl >/dev/null 2>&1; then
        log_warn "Flathub repo looks broken (wrong URL or missing GPG key); repairing..."
        sudo flatpak remote-delete flathub --force >/dev/null 2>&1 || true
        sudo flatpak remote-add flathub https://flathub.org/repo/flathub.flatpakrepo || true
    fi

    if flatpak remote-info flathub com.heroicgameslauncher.hgl >/dev/null 2>&1; then
        FLATPAK_OK=true
        log_success "Flathub configured."
    else
        FLATPAK_OK=false
        log_warn "Could not verify Flathub after repair. Heroic/Lutris/ProtonUp-Qt installs will be skipped."
        log_info "  Next step: check your internet connection, then re-run '$SCRIPT_NAME setup'."
    fi
}

install_wine_and_tools() {
    log_info "Installing Wine and Winetricks..."
    sudo apt-get install -y wine winetricks
    log_success "Wine/Winetricks installed."
}

install_native_emulators() {
    log_info "Installing native runners (DOSBox Staging, ScummVM)..."
    sudo apt-get install -y dosbox-staging scummvm 2>/dev/null || sudo apt-get install -y dosbox scummvm
    log_success "DOSBox & ScummVM installed."
}

install_launchers() {
    local choice
    if [ "$FLATPAK_OK" != true ]; then
        log_warn "Skipping game launcher install: Flathub isn't usable right now."
        return 0
    fi

    if [ "$ASSUME_YES" = true ]; then
        log_info "Non-interactive mode: installing Heroic Games Launcher by default."
        choice=1
    else
        echo ""
        echo -e "${YELLOW}Do you want to install Game Launchers via Flatpak?${NC}"
        echo "1) Heroic Games Launcher (GOG, Epic, Amazon)"
        echo "2) Lutris"
        echo "3) Both"
        echo "4) Skip"
        read -rp "Enter choice [1-4]: " choice
    fi

    case $choice in
        1)
            flatpak install -y flathub com.heroicgameslauncher.hgl || log_warn "Heroic install failed; try 'flatpak install flathub com.heroicgameslauncher.hgl' manually."
            ;;
        2)
            flatpak install -y flathub net.lutris.Lutris || log_warn "Lutris install failed; try 'flatpak install flathub net.lutris.Lutris' manually."
            ;;
        3)
            flatpak install -y flathub com.heroicgameslauncher.hgl || log_warn "Heroic install failed; try 'flatpak install flathub com.heroicgameslauncher.hgl' manually."
            flatpak install -y flathub net.lutris.Lutris || log_warn "Lutris install failed; try 'flatpak install flathub net.lutris.Lutris' manually."
            ;;
        *)
            log_info "Skipping game launchers installation."
            ;;
    esac
}

install_protonup() {
    if [ "$FLATPAK_OK" != true ]; then
        log_warn "Skipping ProtonUp-Qt install: Flathub isn't usable right now."
        return 0
    fi

    log_info "Installing ProtonUp-Qt (for downloading Wine-GE, GE-Proton, Boxtron, etc.)..."
    if flatpak install -y flathub net.davidotek.pupgui2; then
        log_success "ProtonUp-Qt installed! You can use it to manage custom runners."
    else
        log_warn "ProtonUp-Qt install failed; try 'flatpak install flathub net.davidotek.pupgui2' manually."
    fi
}

download_retro_fixes() {
    FIXES_DIR="$HOME/GOG_Fixes"
    mkdir -p "$FIXES_DIR/cnc-ddraw"
    log_info "Downloading latest cnc-ddraw (Fixes retro 2D/DirectDraw games like Worms 2)..."
    
    # Get latest release of cnc-ddraw from GitHub
    LATEST_CNC_URL=$(curl -s https://api.github.com/repos/FunkyFr3sh/cnc-ddraw/releases/latest | grep "browser_download_url.*cnc-ddraw.zip" | cut -d '"' -f 4)
    
    if [ -n "$LATEST_CNC_URL" ]; then
        curl -sL "$LATEST_CNC_URL" -o "$FIXES_DIR/cnc-ddraw/cnc-ddraw.zip"
        unzip -o -q "$FIXES_DIR/cnc-ddraw/cnc-ddraw.zip" -d "$FIXES_DIR/cnc-ddraw/"
        rm "$FIXES_DIR/cnc-ddraw/cnc-ddraw.zip"
        log_success "cnc-ddraw downloaded to: $FIXES_DIR/cnc-ddraw/"
        echo -e "   ${YELLOW}Tip:${NC} Copy 'ddraw.dll' and 'ddraw.ini' into any 90s DirectX/DirectDraw game folder if you experience black screens."
    else
        log_warn "Could not fetch cnc-ddraw automatically. Download manually from: https://github.com/FunkyFr3sh/cnc-ddraw/releases"
    fi
}

run_system_setup() {
    if [ "$ASSUME_YES" != true ]; then
        echo -e "${YELLOW}This script will optimize your Ubuntu environment for GOG games.${NC}\n"
        read -rp "Press [Enter] to continue or Ctrl+C to abort..."
    fi

    enable_32bit
    update_and_install_deps
    setup_flatpak_flathub
    install_wine_and_tools
    install_native_emulators
    install_protonup
    install_launchers
    download_retro_fixes
}

print_next_steps() {
    echo ""
    hr "$GREEN"
    echo -e "${GREEN}${BOLD}  Setup & Installation Completed Successfully!${NC}"
    hr "$GREEN"
    echo -e "${BOLD}Next steps:${NC}"
    echo -e "  ${CYAN}1.${NC} Open ProtonUp-Qt to install 'Wine-GE' (recommended for classic GOG titles)."
    echo -e "  ${CYAN}2.${NC} If a game uses DirectDraw (like Worms 2), copy 'ddraw.dll' and 'ddraw.ini' from ~/GOG_Fixes/cnc-ddraw into the game folder."
    echo -e "  ${CYAN}3.${NC} In Heroic/Lutris, set the executable to 'frontend.exe' or the main game .exe (avoid GOGLauncher.exe under Wine)."
    echo -e "  ${CYAN}4.${NC} Run ${BOLD}$SCRIPT_NAME list${NC} any time to see your game registry, or ${BOLD}$SCRIPT_NAME doctor${NC} to re-scan and re-verify."
    echo ""
}

# ==============================================================================
#  Game Registry - scans a GOG games directory, cross-references Heroic's own
#  per-game config for the Wine prefix, and verifies common dependencies.
# ==============================================================================

ensure_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        log_info "Installing jq (required for the game registry)..."
        sudo apt-get update -y
        sudo apt-get install -y jq
    fi
}

init_registry() {
    mkdir -p "$CONFIG_DIR"
    [ -f "$REGISTRY_FILE" ] || echo '[]' > "$REGISTRY_FILE"
}

# Best-effort lookup of the Wine/Proton prefix + runner Heroic uses for a game,
# preferring the direct GamesConfig/<id>.json file, falling back to a name scan.
find_heroic_config() {
    local id="$1" name="$2" cfg="$HEROIC_GAMES_CONFIG_DIR/$id.json" f prefix="" runner=""

    if [ -f "$cfg" ]; then
        prefix=$(jq -r --arg id "$id" '.[$id].winePrefix // empty' "$cfg" 2>/dev/null || true)
        runner=$(jq -r --arg id "$id" '.[$id].wineVersion.name // empty' "$cfg" 2>/dev/null || true)
    fi

    if [ -z "$prefix" ] && [ -d "$HEROIC_GAMES_CONFIG_DIR" ]; then
        for f in "$HEROIC_GAMES_CONFIG_DIR"/*.json; do
            [ -e "$f" ] || continue
            prefix=$(jq -r --arg name "$name" \
                'to_entries[]? | select(.value.gameName? == $name or .value.title? == $name) | (.value.winePrefix // empty)' \
                "$f" 2>/dev/null | head -n1 || true)
            if [ -n "$prefix" ] && [ "$prefix" != "null" ]; then
                runner=$(jq -r --arg name "$name" \
                    'to_entries[]? | select(.value.gameName? == $name or .value.title? == $name) | (.value.wineVersion.name // empty)' \
                    "$f" 2>/dev/null | head -n1 || true)
                break
            fi
        done
    fi

    printf '%s\t%s\n' "$prefix" "$runner"
}

# Create a Wine prefix at the exact path Heroic already recorded for this game,
# using the exact Proton build Heroic configured, then flatten the compatdata
# layout (pfx/* -> prefix root, pfx kept as a self-symlink) to match Heroic's
# own on-disk format. Only ever creates a prefix that doesn't exist yet.
# Create a Wine prefix at the exact path Heroic already recorded for this game,
# using the exact Proton build Heroic configured, then flatten the compatdata
# layout (pfx/* -> prefix root, pfx kept as a self-symlink) to match Heroic's
# own on-disk format. Only ever creates a prefix that doesn't exist yet.
init_wine_prefix() {
    local id="$1" prefix="$2" cfg="$HEROIC_GAMES_CONFIG_DIR/$id.json" runner_type proton_bin proton_wineserver

    [ -f "$cfg" ] || return 1
    runner_type=$(jq -r --arg id "$id" '.[$id].wineVersion.type // empty' "$cfg" 2>/dev/null || true)
    proton_bin=$(jq -r --arg id "$id" '.[$id].wineVersion.bin // empty' "$cfg" 2>/dev/null || true)

    if [ "$runner_type" != "proton" ] || [ -z "$proton_bin" ] || [ ! -x "$proton_bin" ]; then
        log_warn "  Don't know how to auto-create this prefix (runner: ${runner_type:-unknown}). Launch it once in Heroic instead."
        return 1
    fi

    mkdir -p "$prefix" "$STEAM_FAKE_CLIENT_DIR"
    log_info "  Creating Wine prefix with $(basename "$(dirname "$proton_bin")") (this can take a moment)..."

    if ! timeout 180 bash -c '
        echo "----- init_wine_prefix: $1 ($(date "+%Y-%m-%d %H:%M:%S")) -----"
        STEAM_COMPAT_DATA_PATH="$1" STEAM_COMPAT_CLIENT_INSTALL_PATH="$2" "$3" run wineboot --init
    ' _ "$prefix" "$STEAM_FAKE_CLIENT_DIR" "$proton_bin" >> "$LOG_FILE" 2>&1; then
        log_warn "  Prefix creation failed or timed out; see $LOG_FILE for details."
    fi

    # Proton leaves a persistent "explorer.exe /desktop" session running after
    # wineboot; kill it now so later tools (winetricks) don't hang waiting on it.
    proton_wineserver="$(dirname "$proton_bin")/files/bin/wineserver"
    if [ -x "$proton_wineserver" ]; then
        timeout 15 env WINEPREFIX="$prefix" "$proton_wineserver" -k >> "$LOG_FILE" 2>&1 || true
    fi

    if [ -d "$prefix/pfx" ] && [ ! -L "$prefix/pfx" ]; then
        cp -a "$prefix/pfx/." "$prefix/"
        rm -rf "$prefix/pfx"
        ln -s . "$prefix/pfx"
    fi

    if [ -f "$prefix/system.reg" ]; then
        log_success "  Wine prefix created: $prefix"
        return 0
    fi
    log_warn "  Prefix creation did not produce a valid system.reg; see $LOG_FILE."
    return 1
}

# Insert or update a single registry entry, keyed by game id.
upsert_registry_entry() {
    local id="$1" name="$2" path="$3" info_file="$4" exe="$5" prefix="$6" runner="$7" engine="$8" wrapper="$9"
    local now tmp new_entry
    now=$(date -Iseconds)
    new_entry=$(jq -n \
        --arg id "$id" --arg name "$name" --arg path "$path" \
        --arg info_file "$info_file" --arg exe "$exe" --arg prefix "$prefix" --arg runner "$runner" \
        --arg engine "$engine" --argjson wrapper "$wrapper" --arg now "$now" \
        '{id:$id, name:$name, path:$path, info_file:$info_file, executable:$exe,
          wine_prefix:$prefix, runner:$runner, engine:$engine, wrapper_present:$wrapper,
          status:"unverified", missing_dependencies:[],
          last_scanned:$now, last_verified:null}')

    tmp=$(mktemp)
    jq --argjson entry "$new_entry" \
        '(map(.id) | index($entry.id)) as $idx
         | if $idx != null then .[$idx] = (.[$idx] * $entry) else . + [$entry] end' \
        "$REGISTRY_FILE" > "$tmp" && mv "$tmp" "$REGISTRY_FILE"
}

# Parse a goggame-<id>.info manifest, printing "name<TAB>raw_relative_path".
parse_manifest() {
    local info_file="$1" game_dir="$2" name primary_exe
    name=$(jq -r '.name // empty' "$info_file" 2>/dev/null || true)
    [ -z "$name" ] && name=$(basename "$game_dir")
    primary_exe=$(jq -r '[.playTasks[]? | select(.isPrimary==true)][0].path // empty' "$info_file" 2>/dev/null || true)
    printf '%s\t%s\n' "$name" "$primary_exe"
}

# GOG manifests describe DOSBox/ScummVM games via a Windows-only wrapper exe;
# classify by the wrapper's name so verify_games knows Wine isn't involved.
detect_engine() {
    local relpath_lc="${1,,}"
    case "$relpath_lc" in
        *dosbox*) echo "dosbox" ;;
        *scummvm*) echo "scummvm" ;;
        *) echo "wine" ;;
    esac
}

# Case-insensitive lookup of a manifest-relative exe path under the install dir
# (GOG manifests and the actual installed files often differ only in case).
resolve_executable() {
    local game_dir="$1" relpath="$2" candidate base
    [ -n "$relpath" ] || { echo ""; return 0; }
    candidate="$game_dir/${relpath//\\//}"
    if [ -f "$candidate" ]; then
        echo "$candidate"
        return 0
    fi
    base=$(basename "$candidate")
    find "$game_dir" -maxdepth 3 -iname "$base" -print -quit 2>/dev/null || true
}

# Whether a DOSBox/ScummVM wrapper folder exists directly under the game dir.
has_wrapper_dir() {
    local game_dir="$1" engine="$2"
    [ "$engine" = "wine" ] && { echo "false"; return 0; }
    if find "$game_dir" -maxdepth 1 -type d -iname "$engine" -print -quit 2>/dev/null | grep -q .; then
        echo "true"
    else
        echo "false"
    fi
}

# Register a single game given its GOG id and install directory.
process_game() {
    local id="$1" game_dir="$2" info_file manifest name raw_exe exe_path prefix runner engine wrapper

    info_file="$game_dir/goggame-$id.info"
    [ -f "$info_file" ] || info_file=$(find "$game_dir" -maxdepth 1 -iname "goggame-*.info" -print -quit 2>/dev/null || true)

    if [ -n "$info_file" ] && [ -f "$info_file" ]; then
        manifest=$(parse_manifest "$info_file" "$game_dir")
        IFS=$'\t' read -r name raw_exe <<< "$manifest"
    else
        info_file=""
        name=$(basename "$game_dir")
        raw_exe=""
    fi

    engine=$(detect_engine "$raw_exe")
    exe_path=$(resolve_executable "$game_dir" "$raw_exe")
    wrapper=$(has_wrapper_dir "$game_dir" "$engine")

    IFS=$'\t' read -r prefix runner <<< "$(find_heroic_config "$id" "$name")"

    log_info "Found game: $name"
    upsert_registry_entry "$id" "$name" "$game_dir" "$info_file" "$exe_path" "$prefix" "$runner" "$engine" "$wrapper"
}

# Scan for games in two passes: Heroic's own installed.json (authoritative for
# anything installed through Heroic), then a manifest filesystem scan to catch
# anything sideloaded or not yet tracked by Heroic.
scan_games() {
    local games_dir="$1" found=0
    declare -A seen_ids=()

    if [ ! -d "$games_dir" ]; then
        log_error "Games directory does not exist: $games_dir"
        return 1
    fi

    log_info "Scanning $games_dir for installed GOG games..."

    if [ -f "$HEROIC_INSTALLED_FILE" ]; then
        while IFS=$'\t' read -r id install_path; do
            [ -n "$id" ] || continue
            case "$install_path" in
                "$games_dir"/*|"$games_dir") ;;
                *) continue ;;
            esac
            if [ ! -d "$install_path" ]; then
                log_warn "Heroic lists '$install_path' as installed but the folder is missing."
                continue
            fi
            process_game "$id" "$install_path"
            seen_ids["$id"]=1
            found=$((found + 1))
        done < <(jq -r '.installed[]? | [.appName, .install_path] | @tsv' "$HEROIC_INSTALLED_FILE" 2>/dev/null)
    fi

    while IFS= read -r -d '' info_file; do
        local id game_dir
        game_dir=$(dirname "$info_file")
        id=$(jq -r '.gameId // empty' "$info_file" 2>/dev/null || true)
        [ -n "$id" ] || id="$game_dir"
        [ -n "${seen_ids[$id]:-}" ] && continue
        process_game "$id" "$game_dir"
        seen_ids["$id"]=1
        found=$((found + 1))
    done < <(find "$games_dir" -maxdepth 4 -iname "goggame-*.info" -print0 2>/dev/null)

    if [ "$found" -eq 0 ]; then
        log_warn "No GOG games found under $games_dir"
    else
        log_success "Scan complete. $found game(s) processed."
    fi
}

# Verify each registered game: executable present, Wine prefix present, and
# recommended Winetricks components installed (optionally auto-installing them).
verify_games() {
    local count i

    if [ ! -f "$REGISTRY_FILE" ]; then
        log_warn "No registry found. Run '$SCRIPT_NAME scan' first."
        return 1
    fi

    count=$(jq 'length' "$REGISTRY_FILE")
    if [ "$count" -eq 0 ]; then
        log_warn "Registry is empty. Run '$SCRIPT_NAME scan' first."
        return 0
    fi

    if ! command -v winetricks >/dev/null 2>&1; then
        log_warn "winetricks not found; dependency checks will be skipped. Run '$SCRIPT_NAME setup' first."
    fi

    i=0
    while [ "$i" -lt "$count" ]; do
        local entry id name exe prefix engine wrapper status missing_json installed_list missing verb wine_bin wineserver_bin
        entry=$(jq -c ".[$i]" "$REGISTRY_FILE")
        id=$(echo "$entry" | jq -r '.id')
        name=$(echo "$entry" | jq -r '.name')
        exe=$(echo "$entry" | jq -r '.executable')
        prefix=$(echo "$entry" | jq -r '.wine_prefix')
        engine=$(echo "$entry" | jq -r '.engine // "wine"')
        wrapper=$(echo "$entry" | jq -r '.wrapper_present // false')

        log_info "Verifying: $name"
        status="ok"
        missing_json="[]"

        if [ "$engine" != "wine" ]; then
            # DOSBox/ScummVM titles run through the emulators installed by
            # '$SCRIPT_NAME setup' and never touch Wine, so skip prefix/deps checks.
            if [ -n "$exe" ] && [ "$exe" != "null" ] && [ -f "$exe" ]; then
                log_success "  Native $engine title, launcher found."
            elif [ "$wrapper" = "true" ]; then
                log_warn "  Expected a $engine executable inside the game folder but couldn't find one."
                status="missing_exe"
            else
                log_success "  Native $engine title (Heroic runs this with its bundled $engine, no wrapper needed)."
            fi

            if ! command -v "$engine" >/dev/null 2>&1 && ! command -v "${engine}-staging" >/dev/null 2>&1; then
                log_warn "  '$engine' does not appear to be installed. Run '$SCRIPT_NAME setup'."
                [ "$status" = "ok" ] && status="needs_deps"
            fi

            local tmp
            tmp=$(mktemp)
            jq --argjson i "$i" --arg status "$status" --argjson missing "$missing_json" --arg now "$(date -Iseconds)" \
                '.[$i].status=$status | .[$i].missing_dependencies=$missing | .[$i].last_verified=$now' \
                "$REGISTRY_FILE" > "$tmp" && mv "$tmp" "$REGISTRY_FILE"
            i=$((i + 1))
            continue
        fi

        if [ -z "$exe" ] || [ "$exe" = "null" ] || [ ! -f "$exe" ]; then
            log_warn "  Executable not found: ${exe:-<none>}"
            status="missing_exe"
        fi

        if [ -z "$prefix" ] || [ "$prefix" = "null" ]; then
            log_warn "  No Wine prefix on record; open the game once in Heroic, then re-run verify."
            [ "$status" = "ok" ] && status="unknown_prefix"
        elif [ ! -d "$prefix" ]; then
            if [ "$AUTO_FIX" = true ] && init_wine_prefix "$id" "$prefix"; then
                : # prefix now exists; leave status as set by the executable check above
            else
                log_warn "  Wine prefix path does not exist: $prefix"
                [ "$AUTO_FIX" = true ] || log_info "  Tip: run '$SCRIPT_NAME patch' to auto-create it, or launch the game once in Heroic."
                [ "$status" = "ok" ] && status="missing_prefix"
            fi
        fi

        if [ -d "$prefix" ] && command -v winetricks >/dev/null 2>&1; then
            local env_args
            IFS=$'\t' read -r wine_bin wineserver_bin <<< "$(resolve_proton_tools "$id")"
            [ -n "$wineserver_bin" ] || wineserver_bin=$(resolve_wineserver)
            if [ -z "$wineserver_bin" ]; then
                log_warn "  Could not locate a matching wineserver; skipping dependency checks."
            fi

            env_args=(WINEPREFIX="$prefix" WINESERVER="$wineserver_bin")
            [ -n "$wine_bin" ] && env_args+=(WINE="$wine_bin")

            installed_list=$(timeout 60 env "${env_args[@]}" winetricks list-installed 2>/dev/null || true)
            missing=()
            for verb in "${WANTED_VERBS[@]}"; do
                # A prefix patched before vcrun2015 was dropped from WANTED_VERBS
                # may already have it installed; winetricks refuses to install
                # vcrun2019 on top of it ("conflicts with vcrun2015"), so treat
                # the older redistributable as already satisfying the need.
                if [ "$verb" = "vcrun2019" ] && grep -qw "vcrun2015" <<< "$installed_list"; then
                    continue
                fi
                grep -qw "$verb" <<< "$installed_list" || missing+=("$verb")
            done

            if [ "${#missing[@]}" -gt 0 ]; then
                log_warn "  Missing recommended components: ${missing[*]}"
                [ "$status" = "ok" ] && status="needs_deps"
                missing_json=$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s .)

                if [ "$AUTO_FIX" = true ]; then
                    local still_missing=()
                    for verb in "${missing[@]}"; do
                        log_info "  Installing missing component: $verb"
                        local attempt ok=false
                        for attempt in 1 2 3; do
                            # Wine/Proton's "using server-side synchronization" cold-start
                            # banner occasionally races with winetricks' own %AppData%
                            # detection and makes an otherwise-fine verb report failure;
                            # a single immediate retry (wineserver now warm) clears it up.
                            # Microsoft also updates some redistributable installers
                            # (vcrun2019's vc_redist.x86.exe) in place without bumping
                            # winetricks' pinned checksum, so a 3rd attempt bypasses
                            # that specific check with --force rather than giving up.
                            local force_flag=""
                            [ "$attempt" -eq 3 ] && force_flag="--force"
                            if timeout 300 bash -c '
                                verb="$1"; wp="$2"; ws="$3"; wb="$4"; force="$6"
                                echo "----- winetricks $verb -> $wp (wine=${wb:-system}, attempt $5${force:+, forced}) -----"
                                args=(WINEPREFIX="$wp" WINESERVER="$ws")
                                [ -n "$wb" ] && args+=(WINE="$wb")
                                env "${args[@]}" winetricks -q ${force} "$verb"
                            ' _ "$verb" "$prefix" "$wineserver_bin" "$wine_bin" "$attempt" "$force_flag" >> "$LOG_FILE" 2>&1; then
                                ok=true
                                break
                            fi
                            [ "$attempt" -lt 3 ] && log_warn "  $verb failed on attempt $attempt, retrying..."
                        done
                        if [ "$ok" = true ]; then
                            log_success "  Installed $verb"
                        else
                            log_warn "  Failed to install $verb after 3 attempts (see $LOG_FILE)"
                            still_missing+=("$verb")
                        fi
                    done
                    if [ "${#still_missing[@]}" -eq 0 ]; then
                        [ "$status" = "needs_deps" ] && status="ok"
                        missing_json="[]"
                        log_success "  All recommended components now installed."
                    else
                        missing_json=$(printf '%s\n' "${still_missing[@]}" | jq -R . | jq -s .)
                    fi
                fi
            else
                log_success "  All recommended components present."
            fi

            # One cleanup at the end of this game's winetricks work, not between
            # every call - killing wineserver mid-sequence forces repeated cold
            # starts, and wineserver's startup banner races with winetricks'
            # internal %AppData% detection, causing intermittent verb failures.
            [ -n "$wineserver_bin" ] && timeout 15 env WINEPREFIX="$prefix" "$wineserver_bin" -k >> "$LOG_FILE" 2>&1 || true
        fi

        local tmp
        tmp=$(mktemp)
        jq --argjson i "$i" --arg status "$status" --argjson missing "$missing_json" --arg now "$(date -Iseconds)" \
            '.[$i].status=$status | .[$i].missing_dependencies=$missing | .[$i].last_verified=$now' \
            "$REGISTRY_FILE" > "$tmp" && mv "$tmp" "$REGISTRY_FILE"

        i=$((i + 1))
    done
}

list_games() {
    local total ready name_w=34 ready_w=9 status_w=15 runner_w=20

    if [ ! -f "$REGISTRY_FILE" ] || [ "$(jq 'length' "$REGISTRY_FILE")" -eq 0 ]; then
        log_warn "No games registered yet. Run '$SCRIPT_NAME scan' first."
        return 0
    fi

    echo ""
    echo -e "${BOLD}${CYAN}Your GOG Games${NC}"
    printf "${BOLD}%-${name_w}s %-${ready_w}s %-${status_w}s %-${runner_w}s %s${NC}\n" \
        "NAME" "READY" "STATUS" "RUNNER" "WINE PREFIX"
    hr "$GRAY"

    jq -r '.[] | [.name, (if .status=="ok" then "YES" else "no" end), .status,
                  (if .engine=="wine" then (.runner // "unknown") else (.engine // "unknown") + " (native)" end),
                  (if .engine=="wine" then (.wine_prefix // "unknown") else "n/a" end)] | @tsv' "$REGISTRY_FILE" |
        while IFS=$'\t' read -r n r s rn p; do
            local rcolor scolor prefix_w=42
            [ "${#n}" -gt $((name_w - 1)) ] && n="${n:0:$((name_w - 2))}…"
            [ "${#p}" -gt "$prefix_w" ] && p="…${p: -$((prefix_w - 1))}"
            if [ "$r" = "YES" ]; then rcolor="$GREEN"; else rcolor="$RED"; fi
            case "$s" in
                ok) scolor="$GREEN" ;;
                needs_deps) scolor="$YELLOW" ;;
                missing_exe|missing_prefix) scolor="$RED" ;;
                *) scolor="$GRAY" ;;
            esac
            printf "%-${name_w}s ${rcolor}%-${ready_w}s${NC} ${scolor}%-${status_w}s${NC} ${GRAY}%-${runner_w}s %s${NC}\n" \
                "$n" "$r" "$s" "$rn" "$p"
        done

    total=$(jq 'length' "$REGISTRY_FILE")
    ready=$(jq '[.[] | select(.status=="ok")] | length' "$REGISTRY_FILE")
    local needs_deps missing_prefix missing_exe other bar_w=30 filled bar pct
    needs_deps=$(jq '[.[] | select(.status=="needs_deps")] | length' "$REGISTRY_FILE")
    missing_prefix=$(jq '[.[] | select(.status=="missing_prefix")] | length' "$REGISTRY_FILE")
    missing_exe=$(jq '[.[] | select(.status=="missing_exe")] | length' "$REGISTRY_FILE")
    other=$((total - ready - needs_deps - missing_prefix - missing_exe))

    pct=0; filled=0
    if [ "$total" -gt 0 ]; then
        pct=$((ready * 100 / total))
        filled=$((bar_w * ready / total))
    fi
    bar="$(repeat '█' "$filled")$(repeat '░' $((bar_w - filled)))"

    echo ""
    hr "$GRAY"
    echo -e "${BOLD}Progress:${NC} ${GREEN}${bar}${NC} ${BOLD}${pct}%${NC} ($ready/$total ready to launch)"
    echo ""

    if [ "$ready" -eq "$total" ]; then
        echo -e "${GREEN}${BOLD}✔ All $total games are ready to launch. Fire up Heroic and enjoy!${NC}"
    else
        echo -e "${BOLD}What's next:${NC}"
        [ "$needs_deps" -gt 0 ] && echo -e "  ${YELLOW}•${NC} $needs_deps game(s) just need missing dependencies installed → run ${BOLD}$SCRIPT_NAME patch${NC}"
        [ "$missing_prefix" -gt 0 ] && echo -e "  ${YELLOW}•${NC} $missing_prefix game(s) need a Wine prefix created → run ${BOLD}$SCRIPT_NAME patch${NC} (or launch once in Heroic)"
        [ "$missing_exe" -gt 0 ] && echo -e "  ${RED}•${NC} $missing_exe game(s) are missing their executable → check the install in Heroic"
        [ "$other" -gt 0 ] && echo -e "  ${GRAY}•${NC} $other game(s) haven't been verified yet → run ${BOLD}$SCRIPT_NAME verify${NC}"
    fi
    echo ""
}

usage() {
    local text
    text=$(cat << EOF
${BOLD}Usage:${NC} $SCRIPT_NAME [command] [options]

${BOLD}${CYAN}Commands:${NC}
  ${GREEN}all${NC}         Run system setup, then scan and verify your games (default)
  ${GREEN}setup${NC}       Install/refresh system packages, Wine, launchers and tools only
  ${GREEN}scan${NC}        Scan the games directory and (re)build the game registry
  ${GREEN}verify${NC}      Verify Wine prefixes and dependencies for registered games
  ${GREEN}list${NC}        Print the current game registry (name, ready/status, runner, prefix)
  ${GREEN}patch${NC}       scan + auto-create missing Wine prefixes + install missing deps + list
  ${GREEN}doctor${NC}      scan + verify + list, without touching system packages
  ${GREEN}logs${NC}        Show the companion log file (every scan/verify/patch action, timestamped)
  ${GREEN}help${NC}        Show this help message

${BOLD}${CYAN}Options:${NC}
  ${YELLOW}-d, --games-dir <path>${NC}   Games directory to scan (default: $GAMES_DIR)
  ${YELLOW}-y, --yes${NC}                Non-interactive mode (assume yes / pick defaults)
  ${YELLOW}-f, --fix${NC}                Auto-install missing Winetricks components during verify
  ${YELLOW}-h, --help${NC}               Show this help message
EOF
)
    echo -e "$text"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            all|setup|scan|verify|list|patch|doctor|logs|help)
                COMMAND="$1"; shift ;;
            -d|--games-dir)
                GAMES_DIR="$2"; shift 2 ;;
            -y|--yes)
                ASSUME_YES=true; shift ;;
            -f|--fix)
                AUTO_FIX=true; shift ;;
            -h|--help)
                COMMAND="help"; shift ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1 ;;
        esac
    done

    case "$COMMAND" in
        help)
            usage
            ;;
        setup)
            check_root
            print_banner
            run_system_setup
            print_next_steps
            ;;
        scan)
            acquire_lock
            ensure_jq
            init_registry
            scan_games "$GAMES_DIR"
            echo ""
            log_info "Next: run '$SCRIPT_NAME verify' to check each game, or '$SCRIPT_NAME patch' to scan + fix in one go."
            ;;
        verify)
            acquire_lock
            ensure_jq
            init_registry
            verify_games
            list_games
            ;;
        list)
            list_games
            ;;
        patch)
            acquire_lock
            ensure_jq
            init_registry
            scan_games "$GAMES_DIR"
            AUTO_FIX=true
            verify_games
            list_games
            ;;
        doctor)
            acquire_lock
            ensure_jq
            init_registry
            scan_games "$GAMES_DIR"
            verify_games
            list_games
            ;;
        logs)
            if [ -f "$LOG_FILE" ]; then
                echo -e "${BOLD}${CYAN}Last 200 lines of${NC} ${DIM}$LOG_FILE${NC}"
                hr "$GRAY"
                tail -n 200 "$LOG_FILE"
            else
                log_warn "No log file yet at $LOG_FILE."
            fi
            ;;
        all)
            acquire_lock
            check_root
            print_banner
            run_system_setup
            ensure_jq
            init_registry
            scan_games "$GAMES_DIR"
            verify_games
            list_games
            print_next_steps
            ;;
    esac
}

SCRIPT_NAME="$(basename "$0")"
main "$@"