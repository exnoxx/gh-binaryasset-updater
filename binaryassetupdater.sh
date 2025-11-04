#!/usr/bin/env bash
# GitHub AppImage and binary auto updater
set -euo pipefail

### --- CONFIGURATION ---
REPO=""                                                           # e.g. "rustdesk/rustdesk"
BASEFILENAME=""                                                   # base executable name e.g. "rustdesk"
PLATFORM=""                                                       # e.g. amd64, arm64, x86_64
EXTENSION=""                                                      # e.g. tar.gz, AppImage, zip
BINARYPATH=""                                                     # directory where binaries are stored e.g. $HOME/.local/bin
KEEP_VERSIONS=3                                                   # how many old versions to keep
NAMING_CONVENTION="${BASEFILENAME}-${PLATFORM}-v.%s.${EXTENSION}" # naming template
MIN_FREE_SPACE_MB=350

### --- GLOBALS ---
TMP_JSON="$(mktemp)"
TMP_DL="$(mktemp)"
LATEST_TAG=""
NEW_FILENAME=""
NEW_PATH=""
SYMLINK_PATH="${BINARYPATH}/${BASEFILENAME}"
ASSET_INFO=""
DOWNLOAD_URL=""
ASSET_STATE=""

### --- CHECK DEPENDENCIES ---
for cmd in curl jq file sha256sum; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Missing dependency: $cmd"
        exit 1
    fi
done

### --- DEFINE FUNCTIONS ---

check_free_space() {
    echo "Checking free space in $BINARYPATH ..."
    local available
    available=$(df -Pm "$BINARYPATH" | awk 'NR==2 {print $4}')
    if (( available < MIN_FREE_SPACE_MB )); then
        echo "Not enough free space: ${available} MB available, need at least ${MIN_FREE_SPACE_MB}MB."
        exit 1
    fi
#    echo "Sufficient free space: ${available} MB available."
}

fetch_release_data() {
    echo "Fetching latest release JSON for $REPO ..."
    curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" -o "$TMP_JSON"
    if ! jq -e '.assets | length > 0' "$TMP_JSON" >/dev/null; then
        echo "No assets found in latest release JSON."
        exit 1
    fi
}

extract_version_info() {
    LATEST_TAG="$(jq -r '.tag_name' "$TMP_JSON")"
    if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
        echo "Could not extract release tag."
        exit 1
    fi
    NEW_FILENAME="$(printf "$NAMING_CONVENTION" "$LATEST_TAG")"
    NEW_PATH="${BINARYPATH}/${NEW_FILENAME}"
    echo "Latest version: $LATEST_TAG"
}

check_current_version() {
    if [[ -L "$SYMLINK_PATH" ]]; then
        CURRENT_TARGET="$(readlink "$SYMLINK_PATH")"
        CURRENT_BASENAME="$(basename "$CURRENT_TARGET")"

        # Derive regex from NAMING_CONVENTION — replace "%s" with capture group
        local pattern
        pattern="$(printf "$NAMING_CONVENTION" "([0-9A-Za-z._-]+)")"
        pattern="${pattern//./\\.}"  # escape dots for regex

        if [[ "$CURRENT_BASENAME" =~ $pattern ]]; then
            CURRENT_VERSION="v.${BASH_REMATCH[1]}"
        else
            CURRENT_VERSION="unknown"
        fi
    else
        CURRENT_VERSION="none"
    fi

    echo "Current version: $CURRENT_VERSION"

    if [[ "$CURRENT_VERSION" == "v.$LATEST_TAG" ]]; then
        echo "Already running the latest version ($LATEST_TAG)."
        cleanup_temp
        exit 0
    fi
}

find_target_asset() {
    ASSET_INFO=$(jq -r --arg ext "$PLATFORM.$EXTENSION" '.assets[] | select(.browser_download_url | endswith($ext))' "$TMP_JSON")

    if [[ -z "$ASSET_INFO" ]]; then
        echo "No asset found ending with .$EXTENSION"
        exit 1
    fi

    DOWNLOAD_URL=$(echo "$ASSET_INFO" | jq -r '.browser_download_url')

    MATCH_COUNT=$(echo "$DOWNLOAD_URL" | wc -l)
    if (( MATCH_COUNT > 1 )); then
        echo "Multiple assets match .${EXTENSION}. Please refine your pattern:"
        echo "$DOWNLOAD_URL"
        exit 1
    fi

    ASSET_STATE=$(echo "$ASSET_INFO" | jq -r '.state')

    if [[ "$ASSET_STATE" != "uploaded" ]]; then
        echo "Target asset not uploaded yet (state=$ASSET_STATE). Skipping."
        exit 0
    fi

    echo "Downloading asset: $DOWNLOAD_URL"
    curl -fsSL -o "$TMP_DL" "$DOWNLOAD_URL"
}

install_and_update_symlink() {
    echo "Installing $NEW_FILENAME ..."

    cp -v "$TMP_DL" "$NEW_PATH" || {
        echo "Failed to copy binary to $NEW_PATH"
        cleanup_temp
        exit 1
    }

    chmod -v 0755 "$NEW_PATH" || {
        echo "Failed to set permissions on $NEW_PATH"
        cleanup_temp
        exit 1
    }

    ln -srfnv "$NEW_PATH" "$SYMLINK_PATH" || {
        echo "Failed to update symlink: $SYMLINK_PATH"
        cleanup_temp
        exit 1
    }

    echo "Updated symlink: $SYMLINK_PATH -> $NEW_PATH"
}

cleanup_old_versions() {
    echo "Cleaning old versions (keeping $KEEP_VERSIONS)..."
    mapfile -t OLD_FILES < <(
        find "$BINARYPATH" -maxdepth 1 -type f -name "${BASEFILENAME}-${PLATFORM}-v.*.${EXTENSION}" \
        -printf "%T@ %p\n" | sort -nr | awk '{print $2}' | tail -n +$((KEEP_VERSIONS+1))
    )
    for old in "${OLD_FILES[@]:-}"; do
        echo "Removing old binary: $old"
        rm -fv "$old"
    done
}

cleanup_temp() {
    rm -f "$TMP_JSON" "$TMP_DL"
}

### --- MAIN EXECUTION FLOW ---
check_free_space
fetch_release_data
extract_version_info
check_current_version
find_target_asset
install_and_update_symlink
cleanup_old_versions
cleanup_temp

echo "Successfully updated to version $LATEST_TAG!"
