#!/bin/bash
set -Eeuo pipefail

# ============================================================================
# Codex Desktop for Linux — Installer
# Converts the official macOS Codex Desktop app to run on Linux
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${CODEX_INSTALL_DIR:-$SCRIPT_DIR/codex-app}"
ELECTRON_VERSION="40.0.0"
WORK_DIR="$(mktemp -d)"
ARCH="$(uname -m)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'error "Failed at line $LINENO (exit code $?)"' ERR

# ---- Check dependencies ----
check_deps() {
    local missing=()
    for cmd in node npm npx python3 7z curl unzip perl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -ne 0 ]; then
        error "Missing dependencies: ${missing[*]}
Install them first:
  sudo apt install nodejs npm python3 p7zip-full curl unzip build-essential  # Debian/Ubuntu
  sudo dnf install nodejs npm python3 p7zip curl unzip && sudo dnf groupinstall 'Development Tools'  # Fedora
  sudo pacman -S nodejs npm python p7zip curl unzip base-devel  # Arch"
    fi

    NODE_MAJOR=$(node -v | cut -d. -f1 | tr -d v)
    if [ "$NODE_MAJOR" -lt 20 ]; then
        error "Node.js 20+ required (found $(node -v))"
    fi

    if ! command -v make &>/dev/null || ! command -v g++ &>/dev/null; then
        error "Build tools (make, g++) required:
  sudo apt install build-essential   # Debian/Ubuntu
  sudo dnf groupinstall 'Development Tools'  # Fedora
  sudo pacman -S base-devel          # Arch"
    fi

    # Prefer modern 7-zip if available (required for APFS DMG)
    if command -v 7zz &>/dev/null; then
        SEVEN_ZIP_CMD="7zz"
    else
        SEVEN_ZIP_CMD="7z"
    fi

    if "$SEVEN_ZIP_CMD" | head -n 1 | grep -q "16.02"; then
        error "Your 7-zip is too old to open modern APFS DMGs.
Install a newer 7-zip (7zz), e.g.:
  curl -L -o /tmp/7z.tar.xz https://www.7-zip.org/a/7z2409-linux-x64.tar.xz
  tar -C /tmp -xf /tmp/7z.tar.xz
  sudo install -m 755 /tmp/7zz /usr/local/bin/7zz"
    fi

    info "All dependencies found (using $SEVEN_ZIP_CMD)"
}

# ---- Download or find Codex DMG ----
get_dmg() {
    local dmg_dest="$SCRIPT_DIR/Codex.dmg"

    # Reuse existing DMG
    if [ -s "$dmg_dest" ]; then
        info "Using cached DMG: $dmg_dest ($(du -h "$dmg_dest" | cut -f1))"
        echo "$dmg_dest"
        return
    fi

    info "Downloading Codex Desktop DMG..."
    local dmg_url="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
    info "URL: $dmg_url"

    if ! curl -L --progress-bar --max-time 600 --connect-timeout 30 \
            -o "$dmg_dest" "$dmg_url"; then
        rm -f "$dmg_dest"
        error "Download failed. Download manually and place as: $dmg_dest"
    fi

    if [ ! -s "$dmg_dest" ]; then
        rm -f "$dmg_dest"
        error "Download produced empty file. Download manually and place as: $dmg_dest"
    fi

    info "Saved: $dmg_dest ($(du -h "$dmg_dest" | cut -f1))"
    echo "$dmg_dest"
}

# ---- Extract app from DMG ----
extract_dmg() {
    local dmg_path="$1"
    info "Extracting DMG with 7z..."

    local seven_log="$WORK_DIR/7z.log"
    if ! "$SEVEN_ZIP_CMD" x -y -snl "$dmg_path" -o"$WORK_DIR/dmg-extract" >"$seven_log" 2>&1; then
        if grep -q "Dangerous link path was ignored" "$seven_log"; then
            warn "7-zip reported a dangerous link inside the DMG. Continuing without it."
        else
            cat "$seven_log" >&2
            error "Failed to extract DMG"
        fi
    fi

    local app_dir
    app_dir=$(find "$WORK_DIR/dmg-extract" -maxdepth 3 -name "*.app" -type d | head -1)
    [ -n "$app_dir" ] || error "Could not find .app bundle in DMG"

    info "Found: $(basename "$app_dir")"
    echo "$app_dir"
}

# ---- Build native modules in a clean directory ----
build_native_modules() {
    local app_extracted="$1"

    # Read versions from extracted app
    local bs3_ver npty_ver
    bs3_ver=$(node -p "require('$app_extracted/node_modules/better-sqlite3/package.json').version" 2>/dev/null || echo "")
    npty_ver=$(node -p "require('$app_extracted/node_modules/node-pty/package.json').version" 2>/dev/null || echo "")

    [ -n "$bs3_ver" ] || error "Could not detect better-sqlite3 version"
    [ -n "$npty_ver" ] || error "Could not detect node-pty version"

    info "Native modules: better-sqlite3@$bs3_ver, node-pty@$npty_ver"

    # Build in a CLEAN directory (asar doesn't have full source)
    local build_dir="$WORK_DIR/native-build"
    mkdir -p "$build_dir"
    cd "$build_dir"

    echo '{"private":true}' > package.json

    info "Installing fresh sources from npm..."
    npm install "electron@$ELECTRON_VERSION" --save-dev --ignore-scripts 2>&1 >&2
    npm install "better-sqlite3@$bs3_ver" "node-pty@$npty_ver" --ignore-scripts 2>&1 >&2

    info "Compiling for Electron v$ELECTRON_VERSION (this takes ~1 min)..."
    npx --yes @electron/rebuild -v "$ELECTRON_VERSION" --force 2>&1 >&2

    info "Native modules built successfully"

    # Copy compiled modules back into extracted app
    rm -rf "$app_extracted/node_modules/better-sqlite3"
    rm -rf "$app_extracted/node_modules/node-pty"
    cp -r "$build_dir/node_modules/better-sqlite3" "$app_extracted/node_modules/"
    cp -r "$build_dir/node_modules/node-pty" "$app_extracted/node_modules/"
}

# ---- Patch Linux window backdrop defaults ----
patch_linux_window_backdrop() {
    local build_dir="$1/.vite/build"
    local main_bundle=""
    local bundle_count=0

    [ -d "$build_dir" ] || error "Build directory not found: $build_dir"

    while IFS= read -r path; do
        main_bundle="$path"
        bundle_count=$((bundle_count + 1))
    done < <(find "$build_dir" -maxdepth 1 -type f -name "main-*.js" | sort)

    [ "$bundle_count" -eq 1 ] || error "Expected exactly one main bundle in $build_dir (found $bundle_count)"

    perl -0pi -e '
        BEGIN {
            $patched = qr/function\s+\w+\(\{platform:\w+,appearance:\w+,opaqueWindowsEnabled:\w+,prefersDarkColors:\w+\}\)\{return \w+===["`]win32["`]&&\w+!==["`]hotkeyWindowHome["`]&&\w+!==["`]hotkeyWindowThread["`]\?\w+\?\{backgroundColor:\w+\?\w+:\w+,backgroundMaterial:["`]none["`]\}:\{backgroundColor:\w+,backgroundMaterial:["`]mica["`]\}:\w+===["`]linux["`]&&\w+!==["`]hotkeyWindowHome["`]&&\w+!==["`]hotkeyWindowThread["`]\?\{backgroundColor:\w+\?\w+:\w+,backgroundMaterial:null\}:\{backgroundColor:\w+,backgroundMaterial:null\}\}/s;
            $unpatched = qr/function\s+(\w+)\(\{platform:(\w+),appearance:(\w+),opaqueWindowsEnabled:(\w+),prefersDarkColors:(\w+)\}\)\{return \2===["`]win32["`]&&\3!==["`]hotkeyWindowHome["`]&&\3!==["`]hotkeyWindowThread["`]\?\4\?\{backgroundColor:\5\?(\w+):(\w+),backgroundMaterial:["`]none["`]\}:\{backgroundColor:(\w+),backgroundMaterial:["`]mica["`]\}:\{backgroundColor:\8,backgroundMaterial:null\}\}/s;
        }

        if (/$patched/) {
            $changed = 1;
            next;
        }

        if (s/$unpatched/function $1({platform:$2,appearance:$3,opaqueWindowsEnabled:$4,prefersDarkColors:$5}){return $2===`win32`&&$3!==`hotkeyWindowHome`&&$3!==`hotkeyWindowThread`?$4?{backgroundColor:$5?$6:$7,backgroundMaterial:`none`}:{backgroundColor:$8,backgroundMaterial:`mica`}:$2===`linux`&&$3!==`hotkeyWindowHome`&&$3!==`hotkeyWindowThread`?{backgroundColor:$5?$6:$7,backgroundMaterial:null}:{backgroundColor:$8,backgroundMaterial:null}}/s) {
            $changed = 1;
            next;
        }

        die "Could not locate Linux window backdrop helper in $ARGV\n";

        END {
            die "Failed to patch Linux window backdrop helper in $ARGV\n" if !$changed;
        }
    ' "$main_bundle" || error "Failed to patch Linux window backdrop helper in $main_bundle"
}

# ---- Extract and patch app.asar ----
patch_asar() {
    local app_dir="$1"
    local resources_dir="$app_dir/Contents/Resources"

    [ -f "$resources_dir/app.asar" ] || error "app.asar not found in $resources_dir"

    info "Extracting app.asar..."
    cd "$WORK_DIR"
    npx --yes asar extract "$resources_dir/app.asar" app-extracted

    # Copy unpacked native modules if they exist
    if [ -d "$resources_dir/app.asar.unpacked" ]; then
        cp -r "$resources_dir/app.asar.unpacked/"* app-extracted/ 2>/dev/null || true
    fi

    # Remove macOS-only modules
    rm -rf "$WORK_DIR/app-extracted/node_modules/sparkle-darwin" 2>/dev/null || true
    find "$WORK_DIR/app-extracted" -name "sparkle.node" -delete 2>/dev/null || true

    # Use opaque BrowserWindow backgrounds on Linux to avoid alpha-composited artifacts.
    patch_linux_window_backdrop "$WORK_DIR/app-extracted"

    # Build native modules in clean environment and copy back
    build_native_modules "$WORK_DIR/app-extracted"

    # Repack
    info "Repacking app.asar..."
    cd "$WORK_DIR"
    npx asar pack app-extracted app.asar --unpack "{*.node,*.so,*.dylib}" 2>/dev/null

    info "app.asar patched"
}

# ---- Download Linux Electron ----
download_electron() {
    info "Downloading Electron v${ELECTRON_VERSION} for Linux..."

    local electron_arch
    case "$ARCH" in
        x86_64)  electron_arch="x64" ;;
        aarch64) electron_arch="arm64" ;;
        armv7l)  electron_arch="armv7l" ;;
        *)       error "Unsupported architecture: $ARCH" ;;
    esac

    local url="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-${electron_arch}.zip"

    curl -L --progress-bar -o "$WORK_DIR/electron.zip" "$url"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    unzip -qo "$WORK_DIR/electron.zip"

    info "Electron ready"
}

# ---- Extract webview files ----
extract_webview() {
    local app_dir="$1"
    mkdir -p "$INSTALL_DIR/content/webview"

    # Webview files are inside the extracted asar at webview/
    local asar_extracted="$WORK_DIR/app-extracted"
    if [ -d "$asar_extracted/webview" ]; then
        cp -r "$asar_extracted/webview/"* "$INSTALL_DIR/content/webview/"
        info "Webview files copied"
    else
        warn "Webview directory not found in asar — app may not work"
    fi
}

# ---- Install app.asar ----
install_app() {
    cp "$WORK_DIR/app.asar" "$INSTALL_DIR/resources/"
    if [ -d "$WORK_DIR/app.asar.unpacked" ]; then
        cp -r "$WORK_DIR/app.asar.unpacked" "$INSTALL_DIR/resources/"
    fi
    info "app.asar installed"
}

# ---- Create start script ----
create_start_script() {
    cat > "$INSTALL_DIR/start.sh" << 'SCRIPT'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBVIEW_DIR="$SCRIPT_DIR/content/webview"

pkill -f "http.server 5175" 2>/dev/null
sleep 0.5

if [ -d "$WEBVIEW_DIR" ] && [ "$(ls -A "$WEBVIEW_DIR" 2>/dev/null)" ]; then
    cd "$WEBVIEW_DIR"
    nohup python3 -m http.server 5175 &> /dev/null &
    HTTP_PID=$!
    trap "kill $HTTP_PID 2>/dev/null" EXIT

    # Wait for the HTTP server to be ready (up to 5 seconds)
    echo "Waiting for webview server..."
    for i in $(seq 1 50); do
        if python3 -c "import socket; s=socket.socket(); s.settimeout(0.5); s.connect(('127.0.0.1',5175)); s.close()" 2>/dev/null; then
            echo "Webview server ready."
            break
        fi
        sleep 0.1
    done
fi

export CODEX_CLI_PATH="${CODEX_CLI_PATH:-$(which codex 2>/dev/null)}"

if [ -z "$CODEX_CLI_PATH" ]; then
    echo "Error: Codex CLI not found. Install with: npm i -g @openai/codex"
    exit 1
fi

cd "$SCRIPT_DIR"
exec "$SCRIPT_DIR/electron" --no-sandbox --ozone-platform-hint=auto --disable-gpu-sandbox --enable-features=WaylandWindowDecorations "$@"
SCRIPT

    chmod +x "$INSTALL_DIR/start.sh"
    info "Start script created"
}

# ---- Main ----
main() {
    echo "============================================" >&2
    echo "  Codex Desktop for Linux — Installer"       >&2
    echo "============================================" >&2
    echo ""                                             >&2

    check_deps

    local dmg_path=""
    if [ $# -ge 1 ] && [ -f "$1" ]; then
        dmg_path="$(realpath "$1")"
        info "Using provided DMG: $dmg_path"
    else
        dmg_path=$(get_dmg)
    fi

    local app_dir
    app_dir=$(extract_dmg "$dmg_path")

    patch_asar "$app_dir"
    download_electron
    extract_webview "$app_dir"
    install_app
    create_start_script

    if ! command -v codex &>/dev/null; then
        warn "Codex CLI not found. Install it: npm i -g @openai/codex"
    fi

    echo ""                                             >&2
    echo "============================================" >&2
    info "Installation complete!"
    echo "  Run:  $INSTALL_DIR/start.sh"                >&2
    echo "============================================" >&2
}

main "$@"
