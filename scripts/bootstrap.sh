#!/usr/bin/env bash
#
# scripts/bootstrap.sh
#
# One-shot dependency installer for the MRI Pseudo Haptic macOS app.
# Run it from the repo root:
#
#     ./scripts/bootstrap.sh
#
# What it does:
#   1. Sanity-checks that it's running on macOS and that the Xcode
#      command line tools are installed.
#   2. Installs Homebrew (if missing), then xcodegen + cocoapods.
#   3. Installs the Vimba X SDK from a .dmg into ThirdParty/VimbaX/
#      and clears the Gatekeeper quarantine on the dylibs. If no DMG
#      is found the script tells you where to put it and exits.
#   4. Downloads the MediaPipe hand and pose landmarker .task models
#      into Models/.
#   5. Writes a Podfile and runs `pod install` to fetch
#      MediaPipeTasksVision.
#   6. Runs `xcodegen generate` to produce MRIPseudoHaptic.xcodeproj.
#
# The script is idempotent — re-running it skips steps that are
# already done.

set -euo pipefail

# --- Pretty logging -----------------------------------------------------

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

step()    { printf "\n${BOLD}${BLUE}==>${RESET}${BOLD} %s${RESET}\n" "$*"; }
info()    { printf "    %s\n" "$*"; }
ok()      { printf "    ${GREEN}✓${RESET} %s\n" "$*"; }
warn()    { printf "    ${YELLOW}!${RESET} %s\n" "$*"; }
fail()    { printf "\n${RED}✗ %s${RESET}\n" "$*" >&2; exit 1; }

# --- Paths --------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

THIRD_PARTY_DIR="${REPO_ROOT}/ThirdParty"
VIMBA_DIR="${THIRD_PARTY_DIR}/VimbaX"
MODELS_DIR="${REPO_ROOT}/Models"

HAND_MODEL_URL="https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task"
POSE_MODEL_URL="https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task"

# --- 1. Platform sanity checks -----------------------------------------

step "Checking platform"

if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "This script only runs on macOS (uname says $(uname -s))."
fi
ok "macOS $(sw_vers -productVersion) on $(uname -m)"

if ! xcode-select -p >/dev/null 2>&1; then
    warn "Xcode command line tools not found — triggering installer."
    xcode-select --install || true
    fail "Re-run this script after the command line tools finish installing."
fi
ok "Xcode tools at $(xcode-select -p)"

# --- 2. Homebrew + CLI tools -------------------------------------------

step "Ensuring Homebrew is installed"

if ! command -v brew >/dev/null 2>&1; then
    warn "Homebrew not installed — installing now."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi
ok "brew at $(command -v brew)"

step "Installing xcodegen and cocoapods via Homebrew"

for pkg in xcodegen cocoapods; do
    if brew list --formula "${pkg}" >/dev/null 2>&1; then
        ok "${pkg} already installed"
    else
        info "brew install ${pkg}"
        brew install "${pkg}"
        ok "${pkg} installed"
    fi
done

# --- 3. Vimba X SDK ----------------------------------------------------

step "Installing Vimba X SDK"

install_vimba_from_dmg() {
    local dmg="$1"
    info "Mounting ${dmg}"
    local mount_output
    mount_output=$(hdiutil attach -nobrowse -noautoopen "${dmg}")
    local mount_point
    mount_point=$(printf '%s\n' "${mount_output}" \
        | awk -F'\t' '/\/Volumes\// { print $NF; exit }' \
        | sed 's/[[:space:]]*$//')
    if [[ -z "${mount_point}" || ! -d "${mount_point}" ]]; then
        fail "Could not determine mount point for ${dmg}"
    fi
    info "Mounted at ${mount_point}"

    # Find the top-level VimbaX folder inside the mounted image.
    local src
    src=$(find "${mount_point}" -maxdepth 2 -type d \
          \( -iname 'VimbaX' -o -iname 'VimbaX_*' \) -print -quit || true)
    if [[ -z "${src}" ]]; then
        hdiutil detach "${mount_point}" >/dev/null || true
        fail "Could not find a VimbaX folder inside ${dmg}"
    fi
    info "Copying ${src} → ${VIMBA_DIR}"

    mkdir -p "${THIRD_PARTY_DIR}"
    rm -rf "${VIMBA_DIR}"
    cp -R "${src}" "${VIMBA_DIR}"

    info "Ejecting ${mount_point}"
    hdiutil detach "${mount_point}" >/dev/null || true

    info "Clearing com.apple.quarantine on the SDK"
    xattr -dr com.apple.quarantine "${VIMBA_DIR}" 2>/dev/null || true

    ok "Vimba X installed at ${VIMBA_DIR}"
}

if [[ -f "${VIMBA_DIR}/api/include/VmbC/VmbC.h" \
   && -f "${VIMBA_DIR}/api/lib/libVmbC.dylib" ]]; then
    ok "Vimba X already present at ${VIMBA_DIR}"
else
    # Search for a DMG the user has already downloaded.
    candidates=()
    while IFS= read -r line; do
        candidates+=("${line}")
    done < <(
        {
            ls -1 "${REPO_ROOT}"/VimbaX_Setup-*-macOS.dmg 2>/dev/null || true
            ls -1 "${THIRD_PARTY_DIR}"/VimbaX_Setup-*-macOS.dmg 2>/dev/null || true
            ls -1 "${HOME}/Downloads"/VimbaX_Setup-*-macOS.dmg 2>/dev/null || true
        }
    )

    if [[ ${#candidates[@]} -eq 0 ]]; then
        cat <<EOF

${YELLOW}Vimba X SDK not found.${RESET}

The Vimba X SDK for macOS is licensed by Allied Vision and must be
downloaded manually. Please:

  1. Go to: https://www.alliedvision.com/en/products/software/vimba-x-sdk/
  2. Download ${BOLD}Vimba X for macOS${RESET} (filename looks like
     VimbaX_Setup-<version>-macOS.dmg).
  3. Put the DMG in any of:
       ${REPO_ROOT}/
       ${THIRD_PARTY_DIR}/
       ${HOME}/Downloads/
  4. Re-run this script.

EOF
        fail "Place the Vimba X DMG somewhere the script can find it, then rerun."
    fi

    # Prefer the newest candidate if there are several.
    chosen=""
    newest=0
    for dmg in "${candidates[@]}"; do
        if [[ -f "${dmg}" ]]; then
            mtime=$(stat -f '%m' "${dmg}" 2>/dev/null || echo 0)
            if (( mtime > newest )); then
                newest=${mtime}
                chosen="${dmg}"
            fi
        fi
    done
    if [[ -z "${chosen}" ]]; then
        fail "No readable Vimba X DMG found."
    fi
    info "Using ${chosen}"
    install_vimba_from_dmg "${chosen}"
fi

# Final sanity check on the layout the xcconfig expects.
for f in \
    "${VIMBA_DIR}/api/include/VmbC/VmbC.h" \
    "${VIMBA_DIR}/api/lib/libVmbC.dylib"
do
    if [[ ! -f "${f}" ]]; then
        warn "Expected file missing: ${f}"
        warn "Your Vimba X release may have a different internal layout."
        warn "Edit Config/VimbaX.xcconfig to adjust HEADER_SEARCH_PATHS / LIBRARY_SEARCH_PATHS."
    fi
done

if [[ -d "${VIMBA_DIR}/cti" ]]; then
    ok "GenTL transport layers at ${VIMBA_DIR}/cti"
    info "Remember to set GENICAM_GENTL64_PATH=${VIMBA_DIR}/cti in your Xcode scheme."
else
    warn "No cti/ folder inside the SDK. At runtime set GENICAM_GENTL64_PATH"
    warn "to the folder that contains the .cti transport layer bundles."
fi

# --- 4. MediaPipe model files ------------------------------------------

step "Downloading MediaPipe model files"

mkdir -p "${MODELS_DIR}"

download_model() {
    local name="$1"
    local url="$2"
    local dest="${MODELS_DIR}/${name}"
    if [[ -f "${dest}" && -s "${dest}" ]]; then
        ok "${name} already present"
        return
    fi
    info "curl ${url}"
    if ! curl -fL --retry 3 --output "${dest}" "${url}"; then
        rm -f "${dest}"
        fail "Failed to download ${name} from ${url}"
    fi
    ok "${name} saved to ${dest}"
}

download_model "hand_landmarker.task"     "${HAND_MODEL_URL}"
download_model "pose_landmarker_lite.task" "${POSE_MODEL_URL}"

# --- 5. CocoaPods ------------------------------------------------------

step "Installing MediaPipeTasksVision via CocoaPods"

PODFILE="${REPO_ROOT}/Podfile"
if [[ ! -f "${PODFILE}" ]]; then
    info "Writing Podfile"
    cat > "${PODFILE}" <<'POD'
platform :osx, '13.0'
source 'https://cdn.cocoapods.org/'

target 'MRIPseudoHaptic' do
  use_frameworks!
  pod 'MediaPipeTasksVision'
end
POD
fi

info "pod install"
( cd "${REPO_ROOT}" && pod install --silent ) \
    || fail "pod install failed. Check your CocoaPods setup and rerun."
ok "Pods installed"

# --- 6. XcodeGen -------------------------------------------------------

step "Generating Xcode project"

( cd "${REPO_ROOT}" && xcodegen generate ) \
    || fail "xcodegen generate failed. Check project.yml and Config/VimbaX.xcconfig."
ok "MRIPseudoHaptic.xcodeproj generated"

# --- 7. Done -----------------------------------------------------------

cat <<EOF

${GREEN}${BOLD}All set.${RESET}

Next steps:

  1. Open the workspace (not the .xcodeproj) because MediaPipe was
     pulled in via CocoaPods:

         open MRIPseudoHaptic.xcworkspace

  2. In Xcode:
       Product → Scheme → Edit Scheme… → Run → Arguments
         → Environment Variables, add:

         GENICAM_GENTL64_PATH = ${VIMBA_DIR}/cti

     (This tells the Vimba transport layer loader where the GigE
     .cti bundles live. Without it, VmbStartup succeeds but no
     cameras are discovered.)

  3. Build & run the ${BOLD}MRIPseudoHaptic${RESET} scheme. On first launch
     macOS will ask for camera permission — accept it.

  4. Connect a GigE Vision camera, press ${BOLD}Refresh${RESET} in the sidebar,
     select it, press ${BOLD}Start${RESET}, then ${BOLD}Start Server${RESET} to begin
     broadcasting wrist angles on 127.0.0.1:45123.

${DIM}Tip: subscribe to the loopback stream with \`nc 127.0.0.1 45123\`.${RESET}
EOF
