#!/bin/sh
# oneclick.sh — one-shot install of the HSIC CCID-Reader libccid fix.
#
# Local (from a clone):
#   sudo ./oneclick.sh              # slot fix (recommended)
#   sudo ./oneclick.sh all          # slot + ATR fix
#
# Remote (no clone needed):
#   curl -fsSL https://raw.githubusercontent.com/vhu231/Fix-HSIC-CCID-Reader/master/oneclick.sh | sudo sh
#   curl -fsSL .../oneclick.sh | sudo sh -s -- all
#
# Env:
#   REPO_URL   git clone URL (default: https://github.com/vhu231/Fix-HSIC-CCID-Reader.git)
#   BRANCH     git branch/tag     (default: master)
#   WORK_DIR   where to clone     (default: /tmp/Fix-HSIC-CCID-Reader)
#   PATCH_SET  slot|atr|all       (default: slot; overridden by first arg)
set -eu

REPO_URL="${REPO_URL:-https://github.com/vhu231/Fix-HSIC-CCID-Reader.git}"
BRANCH="${BRANCH:-master}"
WORK_DIR="${WORK_DIR:-/tmp/Fix-HSIC-CCID-Reader}"
PATCH_SET="${1:-${PATCH_SET:-slot}}"

case "$PATCH_SET" in
  slot|atr|all) ;;
  -h|--help|help)
    printf 'Usage: %s [slot|atr|all]\n' "${0##*/}"
    exit 0
    ;;
  *)
    printf 'xx unknown patch set: %s (use: slot | atr | all)\n' "$PATCH_SET" >&2
    exit 1
    ;;
esac

# Re-exec under root when needed (keeps args).
if [ "$(id -u)" -ne 0 ]; then
  # curl|sh has no real script path — must be invoked as: curl … | sudo sh
  case "$0" in
    sh|bash|dash|*/sh|*/bash|*/dash|-sh|-bash)
      printf 'xx need root — re-run as:\n' >&2
      printf '   curl -fsSL …/oneclick.sh | sudo sh\n' >&2
      printf '   curl -fsSL …/oneclick.sh | sudo sh -s -- %s\n' "$PATCH_SET" >&2
      exit 1
      ;;
  esac
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E env REPO_URL="$REPO_URL" BRANCH="$BRANCH" WORK_DIR="$WORK_DIR" \
      -- "$0" "$PATCH_SET"
  fi
  printf 'xx need root — re-run with: sudo %s %s\n' "$0" "$PATCH_SET" >&2
  exit 1
fi

info() { printf '==> %s\n' "$*"; }
die()  { printf 'xx %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve repo root: prefer the directory that contains this script when it
# already has install.sh + patches/; otherwise clone into WORK_DIR.
resolve_repo() {
  script_path=""
  case "$0" in
    /*) script_path=$0 ;;
    */*) script_path=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/$(basename -- "$0") ;;
  esac

  if [ -n "$script_path" ] && [ -f "$script_path" ]; then
    here=$(CDPATH= cd -- "$(dirname -- "$script_path")" && pwd -P)
    if [ -f "$here/install.sh" ] && [ -d "$here/patches" ]; then
      printf '%s' "$here"
      return
    fi
  fi

  # Piped via curl|sh — $0 is often "sh" / "bash"; clone fresh.
  have git || die "git is required to download the installer"
  info "cloning $REPO_URL ($BRANCH) → $WORK_DIR"
  rm -rf "$WORK_DIR"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$WORK_DIR" \
    || die "git clone failed"
  printf '%s' "$WORK_DIR"
}

REPO=$(resolve_repo)
info "repo: $REPO"
info "patch set: $PATCH_SET"

chmod +x "$REPO/install.sh" 2>/dev/null || true
"$REPO/install.sh" install "$PATCH_SET"
"$REPO/install.sh" status

printf '\n'
info "done — replug the HSIC reader (or restart pcscd), then run: pcsc_scan"
