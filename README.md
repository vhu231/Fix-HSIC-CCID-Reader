# Fix-HSIC-CCID-Reader

[中文说明](README_ZH.md)

Patches and installer for the **HSIC CCID-Reader** (USB `1d99:0016`) on Linux.

> **Disambiguation:** **HSIC** here refers to [**上海华申智能卡应用系统有限公司**](https://ccid.apdu.fr/ccid/readers/HSIC_CCID-Reader.txt) (Shanghai Huashen Smart Card Application System Co., Ltd.), the manufacturer of this CCID reader — not other organizations that use the same acronym (e.g. High-Speed Inter-Chip, hardware security modules, etc.).

The stock [libccid/ccid](https://github.com/LudovicRousseau/CCID) driver (the pcsc-lite CCID IFD driver — packaged as `libccid` on Debian/Ubuntu and often as `ccid` on other distros) cannot use this reader reliably because its firmware always answers **"no ICC present"** to `GetSlotStatus`, even when a SIM is inserted. The driver therefore never powers the card. Some SIMs also return ATRs with a missing TCK byte, which breaks `SCardConnect`.

This repository **only ships patches and installer scripts**. At install (and when regenerating patches), [libccid/ccid](https://github.com/LudovicRousseau/CCID) source is downloaded from upstream GitHub tags, patched, built, and installed into the pcsc-lite driver directory. No upstream tree is committed here.

## Reader specifications

Identified on Linux as **HSIC CCID-Reader** (`1d99:0016`). Full CCID descriptor dump: [ccid.apdu.fr — HSIC_CCID-Reader](https://ccid.apdu.fr/ccid/readers/HSIC_CCID-Reader.txt).

| Property | Value |
|----------|-------|
| Vendor ID | `0x1D99` (HSIC) |
| Product ID | `0x0016` |
| Product name | CCID-Reader |
| Firmware (`bcdDevice`) | 1.00 |
| CCID version | 1.10 |
| Slots | 1 (`bMaxSlotIndex: 0`) |
| Voltage | 5.0 V, 3.0 V |
| Protocols | T=0, T=1 |
| Clock | 4.000 MHz (default and maximum) |
| Data rates | 10752, 15625, 31250, 62500, 125000, 250000 bps |
| Features | TPDU level exchange (`dwFeatures: 0x00010000`) |
| Max CCID message | 271 bytes |
| Endpoints | bulk-IN, bulk-OUT, Interrupt-IN |

## Quick start

**One-click** (clone + detect libccid + build + install):

```bash
# Recommended: card-presence fix only
curl -fsSL https://raw.githubusercontent.com/vhu231/Fix-HSIC-CCID-Reader/master/oneclick.sh | sudo sh

# Also apply the ATR / SCardConnect 607 fix
curl -fsSL https://raw.githubusercontent.com/vhu231/Fix-HSIC-CCID-Reader/master/oneclick.sh | sudo sh -s -- all
```

Or from a local clone:

```bash
git clone https://github.com/vhu231/Fix-HSIC-CCID-Reader.git
cd Fix-HSIC-CCID-Reader
sudo ./oneclick.sh          # same as: sudo ./install.sh install slot
sudo ./oneclick.sh all      # slot + ATR
./install.sh status
```

`oneclick` / `install` auto-detects the installed `libccid`/`ccid` package, picks one of the three patch families below, builds that upstream tag, and installs it over the distro driver. Replug the reader or restart `pcscd`, then verify with `pcsc_scan`.

## Patch sets

Each family directory contains the same two patch files:

| Set | Patch | What it fixes |
|-----|-------|---------------|
| `slot` | `01_hsic_slot_status.patch` | Debounced `NotifySlotChange` + ATR probe on `IFDHICCPresence` tick instead of broken `GetSlotStatus`. **Recommended default.** |
| `atr` | `02_hsic_malformed_atr.patch` | Synthesizes the missing ATR TCK byte and falls back to default T=0 parameters when needed. |
| `all` | both | Use when your (U)SIM ATR is rejected by the stock driver. |

**Compatibility:** `slot` alone is enough for standards-compliant cards (including physical eSIM). Only use `atr` or `all` if you hit ATR / `SCardConnect` errors.

## Version families (Ubuntu 20.04+)

Only **three** patch directories are shipped. The installer maps the detected APT `libccid` version onto a family and builds that upstream tag (the whole IFD driver is replaced, so every APT minor does not need its own folder):

| Family dir | Builds upstream | Ubuntu / APT `libccid` | Build system |
|------------|-----------------|------------------------|--------------|
| `patches/1.5.5/` | **1.5.5** | 20.04–24.04 (`1.4.31` … `1.5.5`) | autotools |
| `patches/1.6.2/` | **1.6.2** | 24.10–26.04 (`1.6.1` … `1.7.1`) | meson |
| `patches/1.8.2/` | **1.8.2** | devel / 1.8+ (`1.8.x`) | meson (pointer API) |

Selection rules:

1. Exact `patches/<detected>/` if present  
2. Else family map: `1.4/1.5 → 1.5.5`, `1.6/1.7 → 1.6.2`, `1.8+ → 1.8.2`  
3. Else fall back to **1.6.2**  
4. If patch/build fails on a non-fallback target, retry **1.6.2**

Notes:

- The **1.5.5** family also patches `readers/supported_readers.txt` so `1d99:0016` is recognized (upstream added HSIC in 1.6.2).
- Other distros work the same way as long as the installed package version normalizes to one of the families above.
- Layout: `patches/<family>/` + `install.sh` / `oneclick.sh`. Upstream tarballs are fetched at build time; regenerating patches is `python3 tools/gen_ubuntu_patches.py` (downloads tags into a local `.ccid-src/` cache, gitignored).

## Requirements

- Linux with pcsc-lite (`pcscd`) installed
- Root for install/uninstall
- Build tools (installed automatically): gcc, flex, libusb, zlib, patch; plus **meson/ninja** for the 1.6.2 / 1.8.2 families, or **autoconf/automake** for 1.5.5

## Configuration

Optional `.env` next to `install.sh`:

```bash
# CCID_VERSION=1.5.5          # pin a shipped family (or an APT version that maps to one)
# FALLBACK_CCID_VERSION=1.6.2 # known-good fallback when detect/build fails
PATCH_SET=slot                  # default patch set for `install` with no argument
```

`./install.sh status` shows the detected package version, which family would be built, and any installed patch marker.

## Uninstall

```bash
sudo ./install.sh uninstall
```

Removes the patch marker, unholds the distro `libccid`/`ccid` package (e.g. `libccid` on Debian/Ubuntu, `ccid` on Fedora/Arch), and reinstalls the stock driver.

## Background

These patches were originally developed for the [VoWiFi gateway](https://github.com/pagecat/vowifi_gateway) project and are maintained here as a standalone fix for anyone using the HSIC reader on Linux.

### What each patch does

**01 — Slot status:** The reader's interrupt endpoint sends `RDR_to_PC_NotifySlotChange` messages. Notify only sets a `hsic_presence_pending` flag (debounce). On each `IFDHICCPresence` tick the driver probes with `IccPowerOn`/ATR, updates presence, and restores the previous power state. Initial probe runs on first poll when presence is still unknown.

**02 — Malformed ATR:** HSIC firmware omits the final TCK byte from the ATR. The patch computes it (ISO 7816-3 XOR) at power-on. If parsing still fails, default T=0 protocol parameters are applied so TPDU exchange can proceed.

## License

The patches modify [libccid/ccid](https://github.com/LudovicRousseau/CCID), which is licensed under LGPL-2.1+. See the [upstream CCID project](https://github.com/LudovicRousseau/CCID) for details.
