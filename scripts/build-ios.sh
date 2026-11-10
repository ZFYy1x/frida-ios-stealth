#!/usr/bin/env bash
#
# Build anti-detect frida-server for iOS (roothide Dopamine, rootless, arm64e).
# Runs on a macOS runner. Produces out/frida_<ver>_iphoneos-arm64e.deb
#
set -uo pipefail

WORK="$(pwd)"
INPUT_VERSION="${1:-}"

log() { echo -e "\033[0;32m[build]\033[0m $*"; }
err() { echo -e "\033[0;31m[build]\033[0m $*" >&2; }

# --- resolve frida version ---------------------------------------------------
if [ -n "${INPUT_VERSION}" ]; then
  FRIDA_TAG="${INPUT_VERSION}"
else
  FRIDA_TAG="$(curl -fsSL https://api.github.com/repos/frida/frida/releases/latest \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])')"
fi
[ -z "${FRIDA_TAG}" ] && { err "could not resolve frida version"; exit 1; }
log "Frida version to build: ${FRIDA_TAG}"

# --- clone frida -------------------------------------------------------------
rm -rf "${WORK}/frida"
git clone https://github.com/frida/frida.git "${WORK}/frida"
cd "${WORK}/frida"
git checkout "${FRIDA_TAG}"
git submodule update --init --recursive --depth 1

# --- python venv + build deps ------------------------------------------------
python3 -m venv .venv
# shellcheck source=/dev/null
source .venv/bin/activate
python3 -m pip install --upgrade pip setuptools wheel
python3 -m pip install lief || echo "[build] lief install failed (anti-anti-frida symbol pass may be skipped)"

export PYTHON="$(command -v python3)"
export PYTHONWARNINGS=all

# frida's build post-processes (strips + codesigns) the iOS binaries during the
# build and requires IOS_CERTID. "-" means ad-hoc signing; combined with the
# embedded entitlements this is what a rootless jailbreak (Dopamine) accepts.
export IOS_CERTID="-"

# --- packaging version string ------------------------------------------------
FRIDA_VERSION="$(releng/frida_version.py 2>/dev/null || echo "${FRIDA_TAG#v}")"
# frida_version.py may append commit distance for non-exact checkouts; keep base x.y.z
FRIDA_VERSION="$(echo "${FRIDA_VERSION}" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
export FRIDA_VERSION
log "FRIDA_VERSION=${FRIDA_VERSION}"

# --- apply Florida anti-detect patches ---------------------------------------
bash "${WORK}/scripts/apply-patches.sh" "${WORK}/frida" "${WORK}/patch-report.txt" "${WORK}/patches-ios"

# --- configure + build: ios-arm64e (fat arm64 + arm64e), installed assets ----
# rootless prefix /var/jb/usr ; --host=ios-arm64e emits a fat arm64+arm64e binary.
log "configuring (host=ios-arm64e, prefix=/var/jb/usr)"
./configure \
  --prefix=/var/jb/usr \
  --host=ios-arm64e \
  -- \
  -Dfrida-core:assets=installed

# --- libc++ / Apple clang compatibility -----------------------------------
# Frida's prebuilt iOS SDK ships libc++ headers that apply
# __attribute__((__visibility__("hidden"), __abi_tag__(...))) via
# `#pragma clang attribute`. Every Apple clang on GitHub's macOS images
# (Xcode 15.4 / 16.4 / 26.3 are all clang-17 based) rejects __visibility__
# in that pragma, failing every C++ translation unit with:
#   error: attribute '__visibility__' is not supported by '#pragma clang attribute'
#   error: '#pragma clang attribute pop' with no matching '#pragma clang attribute push'
# Neutralise the two macros in the vendored header. This only removes an
# explicit-instantiation visibility hint, not any runtime behaviour.
python3 - "${WORK}/frida/deps/sdk-ios-arm64e/include/c++/__configuration/namespace.h" <<'PYEOF'
import sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.is_file():
    print("[build] libc++ namespace.h not found; nothing to patch")
    sys.exit(0)
s = p.read_text()
if "clang attribute _LibcxxExplicitABIAnnotations" not in s:
    print("[build] libc++ header has no explicit ABI pragma; nothing to patch")
    sys.exit(0)
# Replace the two macro definitions (which may span backslash-continued
# lines) with empty definitions. Layout-independent: works whether or not
# the clang-based branch is wrapped in an #ifdef.
out = []
skipping = False
macros = ("_LIBCPP_END_EXPLICIT_ABI_ANNOTATIONS", "_LIBCPP_BEGIN_EXPLICIT_ABI_ANNOTATIONS")
for line in s.splitlines(keepends=True):
    if skipping:
        if not line.rstrip().endswith(chr(92)):
            skipping = False
        continue
    stripped = line.lstrip()
    hit = ""
    for macro in macros:
        if stripped.startswith("#define " + macro) or stripped.startswith("# define " + macro):
            hit = macro
            break
    if hit:
        out.append("#define " + hit + chr(10))
        skipping = line.rstrip().endswith(chr(92))
        continue
    out.append(line)
s2 = "".join(out)
if "clang attribute _LibcxxExplicitABIAnnotations" in s2:
    print("[build] ERROR: failed to neutralise libc++ explicit ABI macros")
    sys.exit(1)
p.write_text(s2)
print("[build] patched libc++ namespace.h (explicit ABI pragma disabled)")
PYEOF

NPROC=$(( $(/usr/sbin/sysctl -n hw.logicalcpu) + 1 ))
log "building with -j${NPROC}"
gmake -j"${NPROC}"

rm -rf "${WORK}/dist"
DESTDIR="${WORK}/dist" gmake -j"${NPROC}" install

# --- locate outputs ----------------------------------------------------------
# frida 17.x installs the agent under lib/frida-1.0/ (older frida used lib/frida/).
# Resolve both, with a find fallback so a future layout change does not break us.
SERVER="${WORK}/dist/var/jb/usr/bin/frida-server"
AGENT="${WORK}/dist/var/jb/usr/lib/frida-1.0/frida-agent.dylib"
[ -f "${SERVER}" ] || SERVER="$(find "${WORK}/dist" -path '*/bin/frida-server' -type f | head -1)"
[ -f "${AGENT}" ]  || AGENT="$(find "${WORK}/dist" -name 'frida-agent.dylib' -type f | head -1)"
if [ -z "${SERVER}" ] || [ ! -f "${SERVER}" ]; then
  err "frida-server not found under dist/"
  find "${WORK}/dist" \( -name 'frida-server' -o -name 'frida-agent.dylib' \) | sed 's/^/  found: /'
  exit 2
fi
if [ -z "${AGENT}" ] || [ ! -f "${AGENT}" ]; then
  err "frida-agent.dylib not found under dist/"
  find "${WORK}/dist" -name 'frida-agent.dylib' | sed 's/^/  found: /'
  exit 2
fi
log "server: ${SERVER}"
log "agent:  ${AGENT}"

log "server slices: $(lipo -archs "${SERVER}" 2>/dev/null)"
log "agent  slices: $(lipo -archs "${AGENT}" 2>/dev/null)"

# --- codesign (adhoc, preserve entitlements) ---------------------------------
codesign -vf -s "-" --preserve-metadata=entitlements --timestamp=none "${SERVER}"
codesign -vf -s "-" --preserve-metadata=entitlements --timestamp=none "${AGENT}"
log "codesign done"

# --- package rootless .deb (iphoneos-arm64e, /var/jb) ------------------------
mkdir -p "${WORK}/out"
DEB="${WORK}/out/frida_${FRIDA_VERSION}_iphoneos-arm64e.deb"
FRIDA_VERSION="${FRIDA_VERSION}" bash "${WORK}/tools/package-server-fruity.sh" \
  "iphoneos-arm64e" \
  "${WORK}/dist/var/jb" \
  "${DEB}"

# --- also package a roothide variant (no /var/jb, rootful layout) ------------
DEB_ROOTHIDE="${WORK}/out/frida_${FRIDA_VERSION}_iphoneos-arm64e-roothide.deb"
FRIDA_VERSION="${FRIDA_VERSION}" bash "${WORK}/tools/package-server-roothide.sh" \
  "iphoneos-arm64e" \
  "${WORK}/dist/var/jb" \
  "${DEB_ROOTHIDE}"

echo "${FRIDA_VERSION}" > "${WORK}/out/FRIDA_VERSION.txt"
log "packaged (rootless /var/jb): ${DEB}"
log "packaged (roothide):         ${DEB_ROOTHIDE}"
ls -la "${WORK}/out"
echo "=== rootless deb ==="; dpkg-deb -I "${DEB}" || true; dpkg-deb -c "${DEB}" || true
echo "=== roothide deb ==="; dpkg-deb -I "${DEB_ROOTHIDE}" || true; dpkg-deb -c "${DEB_ROOTHIDE}" || true
