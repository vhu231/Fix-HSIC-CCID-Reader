#!/bin/sh
# install.sh — build and install a patched libccid driver for the HSIC CCID-Reader
# (USB VID:PID 1d99:0016).
#
# This repo only ships patches/ + scripts. Upstream CCID source is always
# downloaded from https://github.com/LudovicRousseau/CCID (tag tarball), then
# patched and built locally — nothing from upstream is committed here.
#
# The stock driver never powers the SIM because the reader firmware always answers
# "no ICC present" to GetSlotStatus. These patches fix that and optionally repair
# malformed ATRs (missing TCK byte).
#
# Usage:
#   sudo ./install.sh install [slot|atr|all]   # build + install (default: slot)
#   sudo ./install.sh uninstall                # remove patched driver, restore distro
#   ./install.sh status
#
# Version selection (patches live under patches/<family>/):
#   1. If CCID_VERSION is set → map/pin to a shipped family
#   2. Else detect installed distro libccid/ccid → map to family
#   3. Else fall back to FALLBACK_CCID_VERSION (default 1.6.2)
#   4. If patch/build fails on a non-fallback target → retry fallback
#
# Env (or a .env file next to this script):
#   CCID_VERSION            pin upstream tag / family (disables auto-detect)
#   FALLBACK_CCID_VERSION   known-good fallback tag (default 1.6.2)
#   PATCH_SET               default patch set (slot|atr|all)
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_DIR="$SELF_DIR"
[ -f "$REPO_DIR/.env" ] && . "$REPO_DIR/.env"

# Empty = auto-detect. Keep the raw pin separate from the resolved build target.
CCID_VERSION_PIN="${CCID_VERSION:-}"
FALLBACK_CCID_VERSION="${FALLBACK_CCID_VERSION:-1.6.2}"
PATCH_SET="${PATCH_SET:-slot}"

# Filled by resolve_ccid_target()
CCID_VERSION=""
CCID_PATCH_DIR=""
CCID_DETECTED=""
CCID_RESOLVE_REASON=""

if [ -t 1 ]; then
  B=$(printf '\033[1m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m'); R=$(printf '\033[31m'); N=$(printf '\033[0m')
else
  B=; G=; Y=; R=; N=
fi
info() { printf '%s==>%s %s\n' "$G$B" "$N" "$*"; }
warn() { printf '%s!!%s %s\n'  "$Y$B" "$N" "$*"; }
err()  { printf '%sxx%s %s\n'  "$R$B" "$N" "$*" >&2; }
die()  { err "$@"; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "this command needs root — re-run with: sudo $0 $CMD"
}

have() { command -v "$1" >/dev/null 2>&1; }

pkg_install() {
  if   have apt-get; then apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif have dnf;     then dnf install -y "$@"
  elif have yum;     then yum install -y "$@"
  elif have pacman;  then pacman -Sy --noconfirm "$@"
  elif have zypper;  then zypper install -y "$@"
  elif have apk;     then apk add --no-cache "$@"
  else die "no supported package manager found (apt/dnf/yum/pacman/zypper/apk)"
  fi
}

drivers_dir() {
  d=$(pkg-config libpcsclite --variable usbdropdir 2>/dev/null || true)
  [ -n "$d" ] || d=/usr/lib/pcsc/drivers
  printf '%s' "$d"
}

# Normalize distro package versions to upstream X.Y.Z tags.
# Examples: 1:1.6.2-2 → 1.6.2 ; 1.8.2-1.fc42 → 1.8.2 ; 1.6.2-r0 → 1.6.2
normalize_ccid_version() {
  # Strip Debian epoch, then packaging suffix, then keep X.Y.Z.
  printf '%s' "$1" \
    | sed 's/^[0-9][0-9]*://; s/[-+_].*$//' \
    | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

# Best-effort: what libccid/ccid is installed on this host right now.
detect_installed_ccid_version() {
  ver=""

  if have dpkg-query; then
    ver=$(dpkg-query -W -f='${Version}' libccid 2>/dev/null || true)
  fi
  if [ -z "$ver" ] && have rpm; then
    ver=$(rpm -q --qf '%{VERSION}' ccid 2>/dev/null || true)
    [ -n "$ver" ] || ver=$(rpm -q --qf '%{VERSION}' pcsc-ccid 2>/dev/null || true)
  fi
  if [ -z "$ver" ] && have pacman; then
    ver=$(pacman -Q ccid 2>/dev/null | awk '{print $2}' || true)
  fi
  if [ -z "$ver" ] && have apk; then
    ver=$(apk info -e -v ccid 2>/dev/null | sed -n 's/^ccid-\(.*\)$/\1/p' | head -n1 || true)
  fi

  # Fallback: Info.plist shipped with the installed IFD bundle
  if [ -z "$ver" ]; then
    plist="$(drivers_dir)/ifd-ccid.bundle/Contents/Info.plist"
    if [ -f "$plist" ]; then
      ver=$(sed -n 's/.*<string>\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)<\/string>.*/\1/p' "$plist" | head -n1 || true)
    fi
  fi

  [ -n "$ver" ] || return 0
  normalize_ccid_version "$ver"
}

# List build-target directories under patches/ (X.Y.Z), one per line, sorted.
list_patch_versions() {
  for d in "$REPO_DIR"/patches/*/; do
    [ -d "$d" ] || continue
    base=$(basename "$d")
    case "$base" in
      [0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$base" ;;
    esac
  done | sort -t. -k1,1n -k2,2n -k3,3n
}

patch_dir_for_version() {
  printf '%s/patches/%s' "$REPO_DIR" "$1"
}

has_patch_dir() {
  [ -d "$(patch_dir_for_version "$1")" ]
}

# Map an installed/detected libccid version onto one of the few shipped
# build targets (we replace the whole IFD driver, so matching the APT minor
# exactly is unnecessary — only the source-tree family matters):
#   1.4.x / 1.5.x  → 1.5.5   (Ubuntu 20.04–24.04; autotools)
#   1.6.x / 1.7.x  → 1.6.2   (Ubuntu 24.10–26.04; meson, array API)
#   1.8.x+         → 1.8.2   (pointer API)
# Returns empty if no mapping / no patch dir.
map_detected_to_build_target() {
  detected="$1"
  major=$(printf '%s' "$detected" | cut -d. -f1)
  minor=$(printf '%s' "$detected" | cut -d. -f2)
  target=""
  case "$major.$minor" in
    1.4|1.5) target=1.5.5 ;;
    1.6|1.7) target=1.6.2 ;;
    1.8|1.9) target=1.8.2 ;;
    *)
      # Future 2.x etc.: prefer highest shipped patch dir if any, else empty
      target=""
      ;;
  esac
  [ -n "$target" ] && has_patch_dir "$target" || return 0
  printf '%s' "$target"
}

# Resolve CCID_VERSION + CCID_PATCH_DIR (+ reason / detected).
resolve_ccid_target() {
  CCID_DETECTED=$(detect_installed_ccid_version || true)
  CCID_VERSION=""
  CCID_PATCH_DIR=""
  CCID_RESOLVE_REASON=""

  if [ -n "$CCID_VERSION_PIN" ]; then
    CCID_VERSION=$(normalize_ccid_version "$CCID_VERSION_PIN")
    # Allow pinning either an exact patch dir, or a detected-style version
    # that maps onto a family target.
    if ! has_patch_dir "$CCID_VERSION"; then
      mapped=$(map_detected_to_build_target "$CCID_VERSION" || true)
      [ -n "$mapped" ] || die "no patch directory for pinned CCID_VERSION=$CCID_VERSION; available: $(list_patch_versions | tr '\n' ' ')"
      CCID_VERSION="$mapped"
    fi
    CCID_PATCH_DIR=$(patch_dir_for_version "$CCID_VERSION")
    CCID_RESOLVE_REASON="pinned via CCID_VERSION → $CCID_VERSION"
    return
  fi

  if [ -n "$CCID_DETECTED" ]; then
    # Exact dir wins (e.g. patches/1.6.2 when APT is 1.6.2)
    if has_patch_dir "$CCID_DETECTED"; then
      CCID_VERSION="$CCID_DETECTED"
      CCID_PATCH_DIR=$(patch_dir_for_version "$CCID_VERSION")
      CCID_RESOLVE_REASON="detected installed libccid $CCID_DETECTED (exact patch dir)"
      return
    fi
    mapped=$(map_detected_to_build_target "$CCID_DETECTED" || true)
    if [ -n "$mapped" ]; then
      CCID_VERSION="$mapped"
      CCID_PATCH_DIR=$(patch_dir_for_version "$CCID_VERSION")
      CCID_RESOLVE_REASON="detected libccid $CCID_DETECTED → build family $CCID_VERSION"
      return
    fi
    warn "installed libccid looks like $CCID_DETECTED, no matching patch family — falling back to $FALLBACK_CCID_VERSION"
  else
    warn "could not detect installed libccid version — falling back to $FALLBACK_CCID_VERSION"
  fi

  CCID_VERSION=$(normalize_ccid_version "$FALLBACK_CCID_VERSION")
  has_patch_dir "$CCID_VERSION" \
    || die "fallback patch directory missing: $(patch_dir_for_version "$CCID_VERSION")"
  CCID_PATCH_DIR=$(patch_dir_for_version "$CCID_VERSION")
  CCID_RESOLVE_REASON="fallback to $CCID_VERSION"
}

marker_path() {
  # $1 = set label; uses current CCID_VERSION
  printf '%s/ifd-ccid.bundle/Contents/.hsic-ccid-%s-%s' "$(drivers_dir)" "$CCID_VERSION" "$1"
}

patch_files_for_set() {
  case "$1" in
    slot) printf '%s' "01_hsic_slot_status.patch" ;;
    atr)  printf '%s' "02_hsic_malformed_atr.patch" ;;
    all)  printf '%s' "01_hsic_slot_status.patch 02_hsic_malformed_atr.patch" ;;
    *) die "invalid patch set '$1' (use: slot | atr | all)" ;;
  esac
}

# $1 = ccid version being built (optional). Pre-1.6.1 needs autotools; 1.6.1+ uses meson.
ensure_build_deps() {
  version="${1:-}"
  need_autotools=0
  need_meson=1
  case "$version" in
    1.4.*|1.5.*) need_autotools=1; need_meson=0 ;;
    1.6.0)       need_autotools=1; need_meson=0 ;;
    "")          need_autotools=1; need_meson=1 ;; # unknown: install both
    *)           need_autotools=0; need_meson=1 ;;
  esac

  if have apt-get; then
    pkgs="flex gcc pkg-config perl patch wget ca-certificates libusb-1.0-0-dev zlib1g-dev"
    [ "$need_meson" = 1 ] && pkgs="$pkgs meson ninja-build"
    [ "$need_autotools" = 1 ] && pkgs="$pkgs autoconf automake libtool make"
    # shellcheck disable=SC2086
    pkg_install $pkgs
    [ -f /usr/include/PCSC/pcsclite.h ] || pkg_install libpcsclite-dev
  elif have dnf || have yum; then
    pkgs="flex gcc pkgconf-pkg-config perl patch wget libusb1-devel zlib-devel"
    [ "$need_meson" = 1 ] && pkgs="$pkgs meson ninja-build"
    [ "$need_autotools" = 1 ] && pkgs="$pkgs autoconf automake libtool make"
    # shellcheck disable=SC2086
    pkg_install $pkgs
    [ -f /usr/include/PCSC/pcsclite.h ] || pkg_install pcsc-lite-devel
  elif have pacman; then
    pkgs="flex gcc pkgconf perl patch wget libusb zlib"
    [ "$need_meson" = 1 ] && pkgs="$pkgs meson ninja"
    [ "$need_autotools" = 1 ] && pkgs="$pkgs autoconf automake libtool make"
    # shellcheck disable=SC2086
    pkg_install $pkgs
    [ -f /usr/include/PCSC/pcsclite.h ] || pkg_install pcsclite
  elif have zypper; then
    pkgs="flex gcc pkg-config perl patch wget libusb-1_0-devel zlib-devel"
    [ "$need_meson" = 1 ] && pkgs="$pkgs meson ninja"
    [ "$need_autotools" = 1 ] && pkgs="$pkgs autoconf automake libtool make"
    # shellcheck disable=SC2086
    pkg_install $pkgs
    [ -f /usr/include/PCSC/pcsclite.h ] || pkg_install pcsc-lite-devel
  elif have apk; then
    pkgs="flex gcc pkgconfig perl patch wget musl-dev libusb-dev zlib-dev"
    [ "$need_meson" = 1 ] && pkgs="$pkgs meson ninja"
    [ "$need_autotools" = 1 ] && pkgs="$pkgs autoconf automake libtool make"
    # shellcheck disable=SC2086
    pkg_install $pkgs
    [ -f /usr/include/PCSC/pcsclite.h ] || pkg_install pcsc-lite-dev
  fi
}

# Download, patch, and install one upstream tag. Returns 0 on success, 1 on failure
# (caller may fall back). Does not die — leaves diagnostics on stderr.
build_ccid_version() {
  version="$1"
  set_label="$2"
  patch_dir=$(patch_dir_for_version "$version")
  ccid_patches=$(patch_files_for_set "$set_label")

  for p in $ccid_patches; do
    [ -f "$patch_dir/$p" ] || { err "missing patch file: $patch_dir/$p"; return 1; }
  done

  info "building CCID driver $version from source — patch set '$set_label' from patches/$version/ ($ccid_patches)…"
  ensure_build_deps "$version"

  tmp=$(mktemp -d)

  if ! (
    cd "$tmp" \
      && { curl -fsSLo ccid.tar.gz "https://github.com/LudovicRousseau/CCID/archive/refs/tags/${version}.tar.gz" \
           || wget -qO ccid.tar.gz "https://github.com/LudovicRousseau/CCID/archive/refs/tags/${version}.tar.gz"; } \
      && tar xf ccid.tar.gz && cd "CCID-${version}" \
      && for p in $ccid_patches; do
           echo "applying $p"
           patch -p1 < "$patch_dir/$p" || exit 1
         done \
      && if [ -f meson.build ]; then
           meson setup builddir \
             && ninja -C builddir && ninja -C builddir install
         else
           # Pre-1.6.1 upstream: autotools only
           ./bootstrap \
             && ./configure \
             && make -j"$(nproc 2>/dev/null || echo 2)" \
             && make install
         fi
  ); then
    rm -rf "$tmp"
    err "build/patch failed for CCID $version (set: $set_label)"
    return 1
  fi
  rm -rf "$tmp"
  return 0
}

finalize_install() {
  set_label="$1"
  drivers=$(drivers_dir)
  marker=$(marker_path "$set_label")

  rm -f "$drivers/ifd-ccid.bundle/Contents/.hsic-ccid-"* 2>/dev/null || true
  touch "$marker" 2>/dev/null || true

  if have apt-mark; then apt-mark hold libccid >/dev/null 2>&1 || true; fi
  if have systemctl; then systemctl restart pcscd 2>/dev/null || true; fi
  info "patched CCID driver $CCID_VERSION (set: $set_label) installed to $drivers"
}

ensure_ccid_host() {
  set_label="$1"
  resolve_ccid_target
  drivers=$(drivers_dir)
  marker=$(marker_path "$set_label")

  info "target CCID $CCID_VERSION — $CCID_RESOLVE_REASON"
  if [ -n "$CCID_DETECTED" ]; then
    info "detected installed libccid: $CCID_DETECTED"
  fi

  if [ -f "$marker" ]; then
    info "patched CCID driver $CCID_VERSION (set: $set_label) already installed ($drivers)"
    return
  fi

  primary="$CCID_VERSION"
  if build_ccid_version "$primary" "$set_label"; then
    finalize_install "$set_label"
    return
  fi

  # Patch/build failed on a non-fallback target → retry known-good.
  if [ "$primary" != "$FALLBACK_CCID_VERSION" ] && has_patch_dir "$FALLBACK_CCID_VERSION"; then
    warn "retrying with fallback CCID $FALLBACK_CCID_VERSION"
    CCID_VERSION=$(normalize_ccid_version "$FALLBACK_CCID_VERSION")
    CCID_PATCH_DIR=$(patch_dir_for_version "$CCID_VERSION")
    CCID_RESOLVE_REASON="fallback after failed build of $primary"
    marker=$(marker_path "$set_label")
    if [ -f "$marker" ]; then
      info "patched CCID driver $CCID_VERSION (set: $set_label) already installed ($drivers)"
      return
    fi
    if build_ccid_version "$CCID_VERSION" "$set_label"; then
      finalize_install "$set_label"
      return
    fi
  fi

  if [ "$primary" != "$FALLBACK_CCID_VERSION" ]; then
    die "failed to build CCID driver (tried $primary and fallback $FALLBACK_CCID_VERSION)"
  fi
  die "failed to build CCID driver $primary from source"
}

cmd_install() {
  need_root
  set_label="${PATCH_SET_ARG:-$PATCH_SET}"
  case "$set_label" in slot|atr|all) ;; *) die "invalid patch set '$set_label' (use: slot | atr | all)" ;; esac
  info "HSIC CCID-Reader fix — patch set: ${B}$set_label${N}"
  ensure_ccid_host "$set_label"
  printf '\n'
  info "install complete"
  printf '   %sReader:%s  HSIC CCID-Reader (1d99:0016)\n' "$B" "$N"
  printf '   %sCCID:%s    %s (%s)\n' "$B" "$N" "$CCID_VERSION" "$CCID_RESOLVE_REASON"
  printf '   %sPatch:%s   %s (from patches/%s/)\n' "$B" "$N" "$set_label" "$CCID_VERSION"
  printf '   %sCheck:%s   %s status\n' "$B" "$N" "$0"
  printf '   Replug the reader or restart pcscd, then test with: pcsc_scan\n'
}

cmd_uninstall() {
  need_root
  drivers=$(drivers_dir)
  bundle="$drivers/ifd-ccid.bundle"

  info "removing patched CCID driver…"
  rm -f "$bundle/Contents/.hsic-ccid-"* 2>/dev/null || true

  if have apt-mark; then apt-mark unhold libccid >/dev/null 2>&1 || true; fi

  if have apt-get; then
    pkg_install libccid >/dev/null 2>&1 || apt-get install --reinstall -y libccid 2>/dev/null || true
  elif have dnf; then
    dnf reinstall -y ccid 2>/dev/null || true
  elif have yum; then
    yum reinstall -y ccid 2>/dev/null || true
  elif have pacman; then
    pacman -S --noconfirm ccid 2>/dev/null || true
  elif have zypper; then
    zypper install -f pcsc-ccid 2>/dev/null || true
  elif have apk; then
    apk add --force-overwrite ccid 2>/dev/null || true
  fi

  if have systemctl; then systemctl restart pcscd 2>/dev/null || true; fi
  info "uninstall complete — distro libccid restored (if available)"
}

cmd_status() {
  drivers=$(drivers_dir)
  detected=$(detect_installed_ccid_version || true)
  resolve_ccid_target

  printf '%sDriver dir:%s     %s\n' "$B" "$N" "$drivers"
  printf '%sDetected libccid:%s %s\n' "$B" "$N" "${detected:-unknown}"
  printf '%sWould build:%s     %s (%s)\n' "$B" "$N" "$CCID_VERSION" "$CCID_RESOLVE_REASON"
  printf '%sPatch dirs:%s      %s\n' "$B" "$N" "$(list_patch_versions | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

  found=0
  for m in "$drivers"/ifd-ccid.bundle/Contents/.hsic-ccid-*; do
    [ -f "$m" ] || continue
    base=$(basename "$m")
    # .hsic-ccid-<version>-<set>  (set is slot|atr|all)
    rest=${base#.hsic-ccid-}
    case "$rest" in
      *-slot) ver=${rest%-slot}; pset=slot ;;
      *-atr)  ver=${rest%-atr};  pset=atr  ;;
      *-all)  ver=${rest%-all};  pset=all  ;;
      *)      ver=$rest; pset=unknown ;;
    esac
    printf '%sInstalled:%s       patched CCID %s (set: %s)\n' "$B" "$N" "$ver" "$pset"
    found=1
  done
  [ "$found" = 1 ] || printf '%sInstalled:%s       none (stock distro driver)\n' "$B" "$N"

  if have pcsc_scan; then
    printf '\n%sTip:%s run `pcsc_scan` to verify the reader is detected.\n' "$B" "$N"
  fi
}

usage() {
  cat <<EOF
${B}HSIC CCID-Reader libccid patch installer${N}

  $0 install [slot|atr|all]   build + install patched driver (default: slot)
  $0 uninstall                remove patch marker and reinstall distro libccid
  $0 status                   show detected version, target, and installed patch set

${B}Patch sets:${N}
  slot   base fix (01): card-presence via NotifySlotChange. Recommended default.
  atr    compatibility fix (02): synthesize missing ATR TCK byte.
  all    both patches (01 + 02) for quirky (U)SIMs.

${B}Version selection:${N}
  Patch dirs: $(list_patch_versions | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  Detected APT libccid is mapped to a family:
    1.4/1.5 → 1.5.5 (Ubuntu 20.04–24.04) | 1.6/1.7 → 1.6.2 | 1.8+ → 1.8.2
  Else fall back to $FALLBACK_CCID_VERSION; retry fallback on build failure.
  Pin with CCID_VERSION=<tag>. Build: meson for >=1.6.1, autotools for 1.5.x.

${B}Reader:${N} HSIC CCID-Reader USB 1d99:0016
${B}Upstream:${N} https://github.com/LudovicRousseau/CCID

Env: CCID_VERSION(=auto) FALLBACK_CCID_VERSION(=$FALLBACK_CCID_VERSION) PATCH_SET(=$PATCH_SET)
EOF
}

CMD="${1:-}"; [ $# -gt 0 ] && shift || true
PATCH_SET_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    slot|atr|all) PATCH_SET_ARG="$1" ;;
    -h|--help|help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

case "$CMD" in
  install|"") cmd_install ;;
  uninstall)  cmd_uninstall ;;
  status)     cmd_status ;;
  -h|--help|help) usage ;;
  *) err "unknown command: $CMD"; usage; exit 1 ;;
esac
