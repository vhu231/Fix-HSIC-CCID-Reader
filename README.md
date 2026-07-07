# Fix-HSIC-CCID-Reader

[中文说明](README_ZH.md)

Patches and installer for the **HSIC CCID-Reader** (USB `1d99:0016`) on Linux.

> **Disambiguation:** **HSIC** here refers to [**上海华申智能卡应用系统有限公司**](https://ccid.apdu.fr/ccid/readers/HSIC_CCID-Reader.txt) (Shanghai Huashen Smart Card Application System Co., Ltd.), the manufacturer of this CCID reader — not other organizations that use the same acronym (e.g. High-Speed Inter-Chip, hardware security modules, etc.).

The stock [libccid/ccid](https://github.com/LudovicRousseau/CCID) driver (the pcsc-lite CCID IFD driver — packaged as `libccid` on Debian/Ubuntu and often as `ccid` on other distros) cannot use this reader reliably because its firmware always answers **"no ICC present"** to `GetSlotStatus`, even when a SIM is inserted. The driver therefore never powers the card. Some SIMs also return ATRs with a missing TCK byte, which breaks `SCardConnect`.

This project builds [libccid/ccid](https://github.com/LudovicRousseau/CCID) from source with targeted fixes and installs the patched driver into the pcsc-lite driver directory.

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

```bash
git clone https://github.com/vhu231/Fix-HSIC-CCID-Reader.git
cd Fix-HSIC-CCID-Reader
chmod +x install.sh

# Recommended: base card-presence fix (safe for compliant cards, including eSIM)
sudo ./install.sh install slot

# If SCardConnect still fails with error 607, try the ATR fix too
sudo ./install.sh install all

./install.sh status
```

Replug the reader or restart `pcscd`, then verify with `pcsc_scan`.

## Patch sets

| Set | Patch | What it fixes |
|-----|-------|---------------|
| `slot` | `01_hsic_slot_status.patch` | Debounced `NotifySlotChange` + ATR probe on `IFDHICCPresence` tick instead of broken `GetSlotStatus`. **Recommended default.** |
| `atr` | `02_hsic_malformed_atr.patch` | Synthesizes the missing ATR TCK byte and falls back to default T=0 parameters when needed. |
| `all` | both | Use when your (U)SIM ATR is rejected by the stock driver. |

**Compatibility:** `slot` alone is enough for standards-compliant cards (including physical eSIM). Only use `atr` or `all` if you hit ATR / `SCardConnect` errors.

## Requirements

- Linux with pcsc-lite (`pcscd`) installed
- Root for install/uninstall
- Build tools: meson, ninja, gcc, flex, libusb, zlib (the installer installs these via your package manager)

The driver is built from upstream [libccid/ccid 1.6.2](https://github.com/LudovicRousseau/CCID), which already lists `1d99:0016` in its supported-reader table. Older distro `libccid`/`ccid` packages (< 1.6.2) may not recognize the VID/PID without manual `Info.plist` edits — this build does not need that.

## Configuration

Optional `.env` next to `install.sh`:

```bash
CCID_VERSION=1.6.2   # upstream libccid tag to build
PATCH_SET=slot       # default patch set for `install` with no argument
```

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
