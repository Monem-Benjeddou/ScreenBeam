#!/bin/bash
# Installs (or updates) the latest ScreenBeam release into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/Monem-Benjeddou/ScreenBeam/main/install.sh | bash
#
# Files downloaded with curl aren't quarantined by macOS (only browsers mark downloads), so the
# app opens normally even though it isn't notarized. Read this script before running it.
#   INSTALL_DIR=~/Applications   install somewhere else
#   NO_OPEN=1                    don't launch the app afterwards
#
# Everything runs inside main(), called on the last line: bash reads the whole script before
# running any of it, so a cut-off download can't execute half an installer.
set -euo pipefail

APP="ScreenBeam"
REPO="Monem-Benjeddou/ScreenBeam"
MIN_MACOS="14.2"
DEST="${INSTALL_DIR:-/Applications}"
BASE_URL="https://github.com/$REPO/releases/latest/download"
SUDO=""
TMP=""

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Is version $1 >= version $2? (dotted, numeric)
version_at_least() {
    local -a a b
    IFS=. read -ra a <<< "$1"
    IFS=. read -ra b <<< "$2"
    local i
    for i in 0 1 2; do
        (( ${a[i]:-0} > ${b[i]:-0} )) && return 0
        (( ${a[i]:-0} < ${b[i]:-0} )) && return 1
    done
    return 0
}

cleanup() {
    # Only ever remove the directory mktemp created.
    if [[ -n "$TMP" && -d "$TMP" && "$TMP" == *"/$APP-install."* ]]; then
        $SUDO rm -rf -- "$TMP"
    fi
}

main() {
    [[ "$(uname -s)" == Darwin ]] || die "$APP only runs on macOS."
    local os_version
    os_version="$(sw_vers -productVersion)"
    version_at_least "$os_version" "$MIN_MACOS" \
        || die "$APP needs macOS $MIN_MACOS or later (this Mac has $os_version)."

    TMP="$(mktemp -d "${TMPDIR:-/tmp}/$APP-install.XXXXXX")"
    trap cleanup EXIT

    say "Downloading the latest $APP release..."
    curl -fL --progress-bar -o "$TMP/$APP-mac.zip" "$BASE_URL/$APP-mac.zip" \
        || die "Download failed. Check your connection, or download it from https://github.com/$REPO/releases/latest"

    if curl -fsL -o "$TMP/$APP-mac.zip.sha256" "$BASE_URL/$APP-mac.zip.sha256"; then
        local expected actual
        expected="$(awk '{print $1}' "$TMP/$APP-mac.zip.sha256")"
        actual="$(shasum -a 256 "$TMP/$APP-mac.zip" | awk '{print $1}')"
        [[ -n "$expected" && "$expected" == "$actual" ]] \
            || die "Checksum mismatch: the download is corrupt or was tampered with. Nothing was installed."
        say "Checksum verified."
    else
        say "This release has no published checksum, so it can't be verified."
    fi

    ditto -x -k "$TMP/$APP-mac.zip" "$TMP/unzipped"
    local new_app="$TMP/unzipped/$APP.app"
    [[ -d "$new_app" ]] || die "The download doesn't contain $APP.app. Nothing was installed."
    codesign --verify --deep --strict "$new_app" 2>/dev/null \
        || die "$APP.app's code signature is invalid. Nothing was installed."

    # Quit a running copy so it can be replaced.
    if pgrep -xq "$APP"; then
        say "Quitting the running $APP..."
        osascript -e "quit app \"$APP\"" >/dev/null 2>&1 || true
        local _
        for _ in {1..20}; do pgrep -xq "$APP" || break; sleep 0.25; done
        ! pgrep -xq "$APP" || die "$APP is still running. Quit it, then run this again."
    fi

    mkdir -p "$DEST" 2>/dev/null || true
    if [[ ! -w "$DEST" ]]; then
        say "Installing into $DEST needs your administrator password."
        SUDO="sudo"
    fi

    local target="$DEST/$APP.app"
    say "Installing to $target..."
    # Move any existing copy aside instead of deleting it, so a failed copy can be rolled back.
    if [[ -e "$target" ]]; then
        $SUDO mv "$target" "$TMP/previous.app"
    fi
    if ! $SUDO ditto "$new_app" "$target"; then
        [[ -e "$TMP/previous.app" ]] && $SUDO mv "$TMP/previous.app" "$target"
        die "Couldn't copy $APP.app into $DEST. Your previous version was left in place."
    fi
    $SUDO xattr -dr com.apple.quarantine "$target" 2>/dev/null || true

    local version
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist" 2>/dev/null || echo "?")"
    say "Installed $APP $version."
    [[ -n "${NO_OPEN:-}" ]] || open "$target"
}

# Subcommands get /dev/null as stdin so nothing can read from the pipe the script arrived on.
main "$@" < /dev/null
