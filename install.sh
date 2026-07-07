#!/bin/sh
# install.sh — build and install a patched libccid driver for the HSIC CCID-Reader
# (USB VID:PID 1d99:0016).
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
# Env (or a .env file next to this script):
#   CCID_VERSION   libccid version to build from source   (default 1.6.2)
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_DIR="$SELF_DIR"
[ -f "$REPO_DIR/.env" ] && . "$REPO_DIR/.env"

CCID_VERSION="${CCID_VERSION:-1.6.2}"
PATCH_SET="${PATCH_SET:-slot}"

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

marker_path() {
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

ensure_build_deps() {
  if   have apt-get; then
    pkg_install meson ninja-build flex gcc pkg-config perl patch wget ca-certificates libusb-1.0-0-dev zlib1g-dev
    [ -f /usr/include/PCSC/pcsclite.h ] || pkg_install libpcsclite-dev
  elif have dnf || have yum; then
    pkg_install meson ninja-build flex gcc pkgconf-pkg-config perl patch wget libusb1-devel zlib-devel
    [ -f /usr/include/PCSC/pcsclite.h ] || pkg_install pcsc-lite-devel
  elif have pacman;  then
    pkg_install meson ninja flex gcc pkgconf perl patch wget libusb zlib
    [ -f /usr/include/PCSC/pcsclite.h ] || pkg_install pcsclite
  elif have zypper;  then
    pkg_install meson ninja flex gcc pkg-config perl patch wget libusb-1_0-devel zlib-devel
    [ -f /usr/include/PCSC/pcsclite.h ] || pkg_install pcsc-lite-devel
  elif have apk;     then
    pkg_install meson ninja flex gcc pkgconfig perl patch wget musl-dev libusb-dev zlib-dev
    [ -f /usr/include/PCSC/pcsclite.h ] || pkg_install pcsc-lite-dev
  fi
}

ensure_ccid_host() {
  set_label="$1"
  ccid_patches=$(patch_files_for_set "$set_label")
  drivers=$(drivers_dir)
  marker=$(marker_path "$set_label")

  if [ -f "$marker" ]; then
    info "patched CCID driver $CCID_VERSION (set: $set_label) already installed ($drivers)"
    return
  fi

  info "building CCID driver $CCID_VERSION from source — patch set '$set_label' ($ccid_patches)…"
  ensure_build_deps

  tmp=$(mktemp -d)
  ( cd "$tmp" \
    && { curl -fsSLo ccid.tar.gz "https://github.com/LudovicRousseau/CCID/archive/refs/tags/${CCID_VERSION}.tar.gz" \
         || wget -qO ccid.tar.gz "https://github.com/LudovicRousseau/CCID/archive/refs/tags/${CCID_VERSION}.tar.gz"; } \
    && tar xf ccid.tar.gz && cd "CCID-${CCID_VERSION}" \
    && for p in $ccid_patches; do
         echo "applying $p"
         patch -p1 < "$REPO_DIR/patches/$p" || exit 1
       done \
    && meson setup builddir \
    && ninja -C builddir && ninja -C builddir install \
  ) || die "failed to build CCID driver $CCID_VERSION from source"
  rm -rf "$tmp"

  rm -f "$drivers/ifd-ccid.bundle/Contents/.hsic-ccid-${CCID_VERSION}-"* 2>/dev/null || true
  touch "$marker" 2>/dev/null || true

  if have apt-mark; then apt-mark hold libccid >/dev/null 2>&1 || true; fi
  if have systemctl; then systemctl restart pcscd 2>/dev/null || true; fi
  info "patched CCID driver $CCID_VERSION (set: $set_label) installed to $drivers"
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
  printf '   %sPatch:%s   %s\n' "$B" "$N" "$set_label"
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
  printf '%sDriver dir:%s %s\n' "$B" "$N" "$drivers"
  found=0
  for set in slot atr all; do
    m=$(marker_path "$set")
    if [ -f "$m" ]; then
      printf '%sInstalled:%s  patched CCID %s (set: %s)\n' "$B" "$N" "$CCID_VERSION" "$set"
      found=1
    fi
  done
  [ "$found" = 1 ] || printf '%sInstalled:%s  none (stock distro driver)\n' "$B" "$N"
  if have pcsc_scan; then
    printf '\n%sTip:%s run `pcsc_scan` to verify the reader is detected.\n' "$B" "$N"
  fi
}

usage() {
  cat <<EOF
${B}HSIC CCID-Reader libccid patch installer${N}

  $0 install [slot|atr|all]   build + install patched driver (default: slot)
  $0 uninstall                remove patch marker and reinstall distro libccid
  $0 status                   show installed patch set

${B}Patch sets:${N}
  slot   base fix (01): card-presence via NotifySlotChange. Recommended default.
  atr    compatibility fix (02): synthesize missing ATR TCK byte.
  all    both patches (01 + 02) for quirky (U)SIMs.

${B}Reader:${N} HSIC CCID-Reader USB 1d99:0016
${B}Builds:${N} libccid $CCID_VERSION from https://github.com/LudovicRousseau/CCID

Env: CCID_VERSION(=$CCID_VERSION) PATCH_SET(=$PATCH_SET)
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
