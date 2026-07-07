# Fix-HSIC-CCID-Reader

Patches and installer for the **HSIC CCID-Reader** (USB `1d99:0016`) on Linux.

The stock [libccid](https://github.com/LudovicRousseau/CCID) driver cannot use this reader reliably because its firmware always answers **"no ICC present"** to `GetSlotStatus`, even when a SIM is inserted. The driver therefore never powers the card. Some SIMs also return ATRs with a missing TCK byte, which breaks `SCardConnect`.

This project builds libccid from source with targeted fixes and installs the patched driver into the pcsc-lite driver directory.

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
| `slot` | `01_hsic_slot_status.patch` | Tracks card presence from `NotifySlotChange` interrupts instead of broken `GetSlotStatus`. **Recommended default.** |
| `atr` | `02_hsic_malformed_atr.patch` | Synthesizes the missing ATR TCK byte and falls back to default T=0 parameters when needed. |
| `all` | both | Use when your (U)SIM ATR is rejected by the stock driver. |

**Compatibility:** `slot` alone is enough for standards-compliant cards (including physical eSIM). Only use `atr` or `all` if you hit ATR / `SCardConnect` errors.

## Requirements

- Linux with pcsc-lite (`pcscd`) installed
- Root for install/uninstall
- Build tools: meson, ninja, gcc, flex, libusb, zlib (the installer installs these via your package manager)

The driver is built from **libccid 1.6.2**, which already lists `1d99:0016` in its supported-reader table. Older distro packages (< 1.6.2) may not recognize the VID/PID without manual `Info.plist` edits — this build does not need that.

## Configuration

Optional `.env` next to `install.sh`:

```bash
CCID_VERSION=1.6.2   # libccid tag to build
PATCH_SET=slot       # default patch set for `install` with no argument
```

## Uninstall

```bash
sudo ./install.sh uninstall
```

Removes the patch marker, unholds the distro `libccid` package (on apt), and reinstalls the stock driver.

## Background

These patches were originally developed for the [VoWiFi gateway](https://github.com/vhu231/vowifi_gateway) project and are maintained here as a standalone fix for anyone using the HSIC reader on Linux.

### What each patch does

**01 — Slot status:** The reader's interrupt endpoint sends correct `RDR_to_PC_NotifySlotChange` messages. The patch records that state and uses it in `IFDHICCPresence` when `GetSlotStatus` lies. On first use it probes by attempting power-on.

**02 — Malformed ATR:** HSIC firmware omits the final TCK byte from the ATR. The patch computes it (ISO 7816-3 XOR) at power-on. If parsing still fails, default T=0 protocol parameters are applied so TPDU exchange can proceed.

## License

The patches modify libccid, which is licensed under LGPL-2.1+. See the upstream CCID project for details.
