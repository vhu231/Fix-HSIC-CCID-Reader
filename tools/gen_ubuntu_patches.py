#!/usr/bin/env python3
"""Generate HSIC CCID patches from upstream LudovicRousseau/CCID tags.

This repo only ships patches/ + installer scripts. Upstream source is never
committed — this tool downloads tags on demand (cached under .ccid-src/, gitignored).

  python3 tools/gen_ubuntu_patches.py          # all shipped families
  python3 tools/gen_ubuntu_patches.py 1.6.2    # one tag
"""
from __future__ import annotations

import difflib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SRC_ROOT = REPO / ".ccid-src"  # download cache only (gitignored)
PATCHES = REPO / "patches"
UPSTREAM_TAG_URL = (
    "https://github.com/LudovicRousseau/CCID/archive/refs/tags/{version}.tar.gz"
)

# Shipped build targets (families). Ubuntu APT minors map onto these in install.sh:
#   1.4.x / 1.5.x → 1.5.5   (20.04–24.04)
#   1.6.x / 1.7.x → 1.6.2   (24.10–26.04)
#   1.8.x+        → 1.8.2
VERSIONS = [
    "1.5.5",
    "1.6.2",
    "1.8.2",
]

HSIC_FIELDS = """\
\t/*
\t * HSIC CCID-Reader slot status management
\t * GetSlotStatus always reports "no ICC present".  Presence is verified
\t * by IccPowerOn/ATR on the IFDHICCPresence tick.  NotifySlotChange only
\t * sets hsic_presence_pending (debounce); the tick clears it and probes.
\t * notified_presence: -1 = not yet probed, 0 = absent, 1 = present
\t */
\tint notified_presence;
\tunsigned char hsic_presence_pending;

"""

HSIC_DEFINE = "#define HSIC_CCID_READER\t\t0x1D990016\n"
HSIC_SUPPORTED = "\n# HSIC\n0x1D99:0x0016:HSIC CCID-Reader\n"


def ver_tuple(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in v.split("."))


def is_ptr_api(v: str) -> bool:
    return ver_tuple(v) >= (1, 8, 0)


def needs_supported_readers(v: str) -> bool:
    return ver_tuple(v) < (1, 6, 2)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="\n")


def insert_after_match(text: str, pattern: str, insertion: str) -> str:
    m = re.search(pattern, text)
    if not m:
        raise ValueError(f"pattern not found: {pattern!r}")
    return text[: m.end()] + insertion + text[m.end() :]


def insert_before_match(text: str, pattern: str, insertion: str) -> str:
    m = re.search(pattern, text)
    if not m:
        raise ValueError(f"pattern not found: {pattern!r}")
    return text[: m.start()] + insertion + text[m.start() :]


def patch_descriptor_fields(text: str) -> str:
    if "hsic_presence_pending" in text:
        return text
    m = re.search(r"(\tint dwSlotStatus;\n)", text)
    if not m:
        raise ValueError("dwSlotStatus field not found")
    return text[: m.end()] + "\n" + HSIC_FIELDS + text[m.end() :]


def patch_hsic_define(text: str) -> str:
    if "HSIC_CCID_READER" in text:
        return text
    for pat in (
        r"#define ACS_ACR122U\s+0x072[fF]2200\n",
        r"#define KAPELSE_KAPECV\s+0x29470112\n",
        r"#define DIEBOLDNIXDORF_PN7362AU\s+0x2F7C6007\n",
        r"#define SAFENET_ETOKEN_5100\s+0x05290620\n",
        r"#define FUJITSU_D323\s+0x0BF81024[^\n]*\n",
    ):
        m = re.search(pat, text)
        if m:
            return text[: m.end()] + HSIC_DEFINE + text[m.end() :]
    m = re.search(r"#define VENDOR_(?:KAPELSE|GEMALTO)\b", text)
    if m:
        return text[: m.start()] + HSIC_DEFINE + text[m.start() :]
    raise ValueError("cannot insert HSIC_CCID_READER define")


def patch_supported_readers(text: str) -> str:
    if "0x1D99:0x0016" in text or "HSIC CCID-Reader" in text:
        return text
    # Insert before a late vendor section if present, else append.
    for marker in ("\n# id3 Semiconductors\n", "\n# VMware\n", "\n# XIRING\n"):
        if marker in text:
            return text.replace(marker, HSIC_SUPPORTED + marker, 1)
    if not text.endswith("\n"):
        text += "\n"
    return text + HSIC_SUPPORTED


def patch_ccid_usb_c(text: str, version: str) -> str:
    ptr = is_ptr_api(version)

    if ptr:
        init_re = r"(usb_device->ccid\.dwSlotStatus\s*=\s*IFD_ICC_PRESENT;\n)"
        init_ins = (
            "\t\t\t\tusb_device->ccid.notified_presence = -1;\n"
            "\t\t\t\tusb_device->ccid.hsic_presence_pending = 0;\n"
        )
        notify_new = (
            "\t\t\t\t\t\t/* HSIC: debounce slot-change notifies; the\n"
            "\t\t\t\t\t\t * IFDHICCPresence tick verifies by ATR */\n"
            "\t\t\t\t\t\tif (HSIC_CCID_READER == usb_device->ccid.readerID)\n"
            "\t\t\t\t\t\t\tusb_device->ccid.hsic_presence_pending = 1;\n"
        )
        notify_old = None
    else:
        init_re = (
            r"(usbDevice\[reader_index\]\.ccid\.dwSlotStatus\s*=\s*IFD_ICC_PRESENT;\n)"
        )
        init_ins = (
            "\t\t\t\tusbDevice[reader_index].ccid.notified_presence = -1;\n"
            "\t\t\t\tusbDevice[reader_index].ccid.hsic_presence_pending = 0;\n"
        )
        notify_new = (
            "\t\t\t\t\t\t/* HSIC: debounce slot-change notifies; the\n"
            "\t\t\t\t\t\t * IFDHICCPresence tick verifies by ATR */\n"
            "\t\t\t\t\t\tif (HSIC_CCID_READER ==\n"
            "\t\t\t\t\t\t\tusbDevice[reader_index].ccid.readerID)\n"
            "\t\t\t\t\t\t\tusbDevice[reader_index].ccid.hsic_presence_pending = 1;\n"
        )
        # Pre-1.6.2: InterruptRead logs NotifySlotChange for any completed transfer.
        notify_old = (
            "\t\t\t/* HSIC: debounce slot-change notifies; the\n"
            "\t\t\t * IFDHICCPresence tick verifies by ATR */\n"
            "\t\t\tif (HSIC_CCID_READER ==\n"
            "\t\t\t\tusbDevice[reader_index].ccid.readerID)\n"
            "\t\t\t\tusbDevice[reader_index].ccid.hsic_presence_pending = 1;\n"
        )

    if "hsic_presence_pending = 0" not in text:
        text = insert_after_match(text, init_re, init_ins)

    if "hsic_presence_pending = 1" in text:
        return text

    m = re.search(
        r"(case RDR_to_PC_NotifySlotChange:\n"
        r"[ \t]+DEBUG_XXD\(\"NotifySlotChange: \".*?\n)"
        r"([ \t]+break;\n)",
        text,
    )
    if m:
        return text[: m.end(1)] + notify_new + text[m.start(2) :]

    # Older InterruptRead: completed transfer always treated as NotifySlotChange.
    m = re.search(
        r"(case LIBUSB_TRANSFER_COMPLETED:\n"
        r"[ \t]+DEBUG_XXD\(\"NotifySlotChange: \".*?\n)"
        r"([ \t]+break;\n)",
        text,
    )
    if m and notify_old is not None:
        return text[: m.end(1)] + notify_old + text[m.start(2) :]

    raise ValueError("NotifySlotChange hook point not found")


def hsic_update_presence_helper(version: str) -> str:
    if is_ptr_api(version):
        return """\
/*
 * HSIC CCID-Reader: GetSlotStatus lies; probe presence with IccPowerOn/ATR.
 * Saves whether the card was powered, restores that state afterwards.
 */
static void hsic_update_presence(CcidDesc *ccid_reader,
	_ccid_descriptor *ccid_descriptor)
{
	unsigned char atr_probe[MAX_ATR_SIZE];
	unsigned int atr_probe_len = sizeof(atr_probe);
	int was_powered;

	was_powered = ccid_reader->bPowerFlags & MASK_POWERFLAGS_PUP;
	ccid_descriptor->hsic_presence_pending = 0;

	if (IFD_SUCCESS == CmdPowerOn(ccid_reader, &atr_probe_len,
			atr_probe, VOLTAGE_AUTO))
		ccid_descriptor->notified_presence = 1;
	else
		ccid_descriptor->notified_presence = 0;

	if (!was_powered)
		(void)CmdPowerOff(ccid_reader);
}


"""
    return """\
/*
 * HSIC CCID-Reader: GetSlotStatus lies; probe presence with IccPowerOn/ATR.
 * Saves whether the card was powered, restores that state afterwards.
 */
static void hsic_update_presence(unsigned int reader_index,
	_ccid_descriptor *ccid_descriptor)
{
	unsigned char atr_probe[MAX_ATR_SIZE];
	unsigned int atr_probe_len = sizeof(atr_probe);
	int was_powered;

	was_powered = CcidSlots[reader_index].bPowerFlags & MASK_POWERFLAGS_PUP;
	ccid_descriptor->hsic_presence_pending = 0;

	if (IFD_SUCCESS == CmdPowerOn(reader_index, &atr_probe_len,
			atr_probe, VOLTAGE_AUTO))
		ccid_descriptor->notified_presence = 1;
	else
		ccid_descriptor->notified_presence = 0;

	if (!was_powered)
		(void)CmdPowerOff(reader_index);
}


"""


def presence_hook(version: str) -> str:
    args = "ccid_reader" if is_ptr_api(version) else "reader_index"
    return f"""\
	if ((HSIC_CCID_READER == ccid_descriptor->readerID)
		&& (IFD_ICC_NOT_PRESENT == return_value))
	{{
		/* Broken GetSlotStatus: verify presence on tick via IccPowerOn/ATR.
		 * NotifySlotChange only sets hsic_presence_pending; initial probe
		 * runs when notified_presence is still unknown (-1). */
		if (ccid_descriptor->hsic_presence_pending
			|| (-1 == ccid_descriptor->notified_presence))
			hsic_update_presence({args}, ccid_descriptor);

		if (1 == ccid_descriptor->notified_presence)
			return_value = IFD_ICC_PRESENT;
	}}

"""


def patch_ifdhandler_slot(text: str, version: str) -> str:
    helper = hsic_update_presence_helper(version)
    hook = presence_hook(version)

    if "hsic_update_presence" not in text:
        text = insert_before_match(
            text,
            r"EXTERNAL RESPONSECODE IFDHICCPresence\(DWORD Lun\)\n",
            helper,
        )

    if "Broken GetSlotStatus" in text:
        return text

    m = re.search(
        r"(\n)(#if 0\n\t/\* SCR331-DI contactless reader \*/)",
        text,
    )
    if m:
        return text[: m.start(1)] + "\n" + hook + text[m.start(2) :]

    # 1.8.x and some versions: insert before the common end label / final return.
    start = text.find("EXTERNAL RESPONSECODE IFDHICCPresence(DWORD Lun)\n")
    end = text.find("} /* IFDHICCPresence */", start)
    if start < 0 or end < 0:
        raise ValueError("cannot bound IFDHICCPresence")
    body = text[start:end]

    for anchor in ("\nend:\n", "\n\treturn return_value;\n"):
        idx = body.rfind(anchor)
        if idx >= 0:
            body = body[:idx] + "\n" + hook + body[idx:]
            return text[:start] + body + text[end:]

    raise ValueError("cannot find insertion point in IFDHICCPresence")


def repair_atr_helper(version: str) -> str:
    if is_ptr_api(version):
        return """\
#define HSIC_CCID_READER 0x1D990016

/*
 * HSIC CCID-Reader firmware drops the final TCK byte from the ATR.
 * Synthesize it (ISO 7816-3: XOR of T0 through last historical byte) so
 * downstream ATR parsing and PTS negotiation proceed normally.
 */
static void hsic_repair_atr(CcidDesc *ccid_reader, unsigned char *buffer,
	unsigned int *length)
{
	ATR_t atr;
	unsigned char tck;
	unsigned int i, len;

	if (HSIC_CCID_READER != ccid_reader->device.ccid.readerID)
		return;

	len = *length;
	if (len < 2 || len >= MAX_ATR_SIZE)
		return;

	if (ATR_InitFromArray(&atr, buffer, len) == ATR_OK)
		return;

	tck = 0;
	for (i = 1; i < len; i++)
		tck ^= buffer[i];

	buffer[len] = tck;
	if (ATR_InitFromArray(&atr, buffer, len + 1) != ATR_OK)
	{
		DEBUG_COMM("HSIC CCID-Reader: TCK repair failed, keeping raw ATR");
		return;
	}

	*length = len + 1;
	DEBUG_COMM2("HSIC CCID-Reader: appended missing TCK 0x%02X", tck);
}

"""
    return """\
#define HSIC_CCID_READER 0x1D990016

/*
 * HSIC CCID-Reader firmware drops the final TCK byte from the ATR.
 * Synthesize it (ISO 7816-3: XOR of T0 through last historical byte) so
 * downstream ATR parsing and PTS negotiation proceed normally.
 */
static void hsic_repair_atr(unsigned int reader_index, unsigned char *buffer,
	unsigned int *length)
{
	ATR_t atr;
	unsigned char tck;
	unsigned int i, len;

	if (HSIC_CCID_READER != get_ccid_descriptor(reader_index)->readerID)
		return;

	len = *length;
	if (len < 2 || len >= MAX_ATR_SIZE)
		return;

	if (ATR_InitFromArray(&atr, buffer, len) == ATR_OK)
		return;

	tck = 0;
	for (i = 1; i < len; i++)
		tck ^= buffer[i];

	buffer[len] = tck;
	if (ATR_InitFromArray(&atr, buffer, len + 1) != ATR_OK)
	{
		DEBUG_COMM("HSIC CCID-Reader: TCK repair failed, keeping raw ATR");
		return;
	}

	*length = len + 1;
	DEBUG_COMM2("HSIC CCID-Reader: appended missing TCK 0x%02X", tck);
}

"""


def atr_fallback_block(version: str) -> str:
    if is_ptr_api(version):
        set_params = (
            "(void)SetParameters(ccid_reader, 0, sizeof(t0_default_param),\n"
            "\t\t\t\tt0_default_param);"
        )
    else:
        set_params = (
            "(void)SetParameters(reader_index, 0, sizeof(t0_default_param),\n"
            "\t\t\t\tt0_default_param);"
        )
    return f"""\
		/*
		 * Fallback when CmdPowerOn TCK repair did not yield a parseable ATR.
		 * Apply default T=0 parameters so the TPDU engine is armed.
		 */
		if (0x1D990016 == ccid_desc->readerID)	/* HSIC CCID-Reader VID:PID */
		{{
			unsigned char t0_default_param[] = {{
				0x11,	/* Fi/Di = 372/1 (default speed) */
				0x00,	/* TCCKS: T=0, direct convention */
				0x00,	/* extra guard time */
				0x0A,	/* WI (waiting integer) */
				0x00	/* clock stop */
			}};
			DEBUG_INFO1("HSIC CCID-Reader: malformed ATR accepted, applying default T=0 parameters");
			{set_params}
			ccid_desc->readTimeout = DEFAULT_COM_READ_TIMEOUT;
			ccid_desc->cardProtocol = Protocol;
			return IFD_SUCCESS;
		}}
"""


def patch_commands_atr(text: str, version: str) -> str:
    if '#include "towitoko/atr.h"' not in text:
        text = insert_after_match(text, r'#include "utils\.h"\n', '#include "towitoko/atr.h"\n')

    if "hsic_repair_atr" not in text:
        helper = repair_atr_helper(version)
        m = re.search(r"\nRESPONSECODE CmdPowerOn\(", text)
        if not m:
            raise ValueError("CmdPowerOn not found")
        text = text[: m.start()] + "\n" + helper + text[m.start() :]

    if re.search(r"hsic_repair_atr\([^)]+\);\n\n\treturn return_value;", text):
        return text

    call = (
        "\n\thsic_repair_atr(ccid_reader, buffer, nlength);\n"
        if is_ptr_api(version)
        else "\n\thsic_repair_atr(reader_index, buffer, nlength);\n"
    )
    # 1.6.1+: memcpy(buffer, resp+10/CCID_HEADER_SIZE, ...)
    # older:   memmove(buffer, buffer+10, ...)
    m = re.search(
        r"((?:memcpy|memmove)\(buffer,\s*"
        r"(?:resp(?:\s*\+\s*10|\s*\+\s*CCID_HEADER_SIZE)|buffer\s*\+\s*10),\s*"
        r"atr_len\);\n)"
        r"(\n\treturn return_value;\n\} /\* CmdPowerOn \*/)",
        text,
    )
    if not m:
        raise ValueError("CmdPowerOn ATR memcpy/return pattern not found")
    return text[: m.end(1)] + call + text[m.start(2) :]


def patch_ifdhandler_atr(text: str, version: str) -> str:
    if "malformed ATR accepted" in text:
        return text
    fallback = atr_fallback_block(version)
    # Variable may be ccid_desc (common) — ensure present in function; patches use ccid_desc.
    # Older code uses ccid_desc; 1.8 uses ccid_desc too after assignment.
    pat = re.compile(
        r"(if \(ATR_MALFORMED == atr_ret\)\n)"
        r"(\t\treturn IFD_PROTOCOL_NOT_SUPPORTED;\n)"
    )
    m = pat.search(text)
    if not m:
        raise ValueError("ATR_MALFORMED handling not found")
    # On 1.8 the local is still named via ccid_desc = &ccid_reader->device.ccid
    # but some versions use ccid_descriptor — normalize fallback target.
    local = "ccid_desc"
    window = text[max(0, m.start() - 800) : m.start()]
    if "ccid_desc =" not in window and "ccid_desc=" not in window:
        if re.search(r"_ccid_descriptor \*ccid_desc(?:riptor)?\b", window):
            if "ccid_descriptor" in window and "ccid_desc =" not in window:
                local = "ccid_descriptor"
        elif "ccid_descriptor =" in window:
            local = "ccid_descriptor"
    fallback = fallback.replace("ccid_desc->", f"{local}->")

    block = (
        m.group(1)
        + "\t{\n"
        + fallback
        + "\t\treturn IFD_PROTOCOL_NOT_SUPPORTED;\n"
        + "\t}\n"
    )
    return text[: m.start()] + block + text[m.end() :]


def make_diff(old_root: Path, new_root: Path, rel: str) -> str:
    old = (old_root / rel).read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    new = (new_root / rel).read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    return "".join(
        difflib.unified_diff(old, new, fromfile=f"a/{rel}", tofile=f"b/{rel}", lineterm="\n")
    )


SLOT_FILES = [
    "src/ccid.h",
    "src/defs.h",
    "src/ccid_usb.c",
    "src/ifdhandler.c",
    "readers/supported_readers.txt",
]
ATR_FILES = ["src/commands.c", "src/ifdhandler.c"]


def stage_files(src: Path, dst: Path, rels: list[str]) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    for rel in rels:
        s = src / rel
        if not s.exists():
            continue
        d = dst / rel
        d.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(s, d)


def apply_slot(src: Path, dst: Path, version: str) -> list[str]:
    stage_files(src, dst, SLOT_FILES)
    changed: list[str] = []

    if is_ptr_api(version):
        defs = dst / "src/defs.h"
        write(defs, patch_descriptor_fields(read(defs)))
        changed.append("src/defs.h")
    else:
        hdr = dst / "src/ccid.h"
        write(hdr, patch_descriptor_fields(read(hdr)))
        changed.append("src/ccid.h")

    hdr = dst / "src/ccid.h"
    write(hdr, patch_hsic_define(read(hdr)))
    if "src/ccid.h" not in changed:
        changed.append("src/ccid.h")

    usb = dst / "src/ccid_usb.c"
    write(usb, patch_ccid_usb_c(read(usb), version))
    changed.append("src/ccid_usb.c")

    ifd = dst / "src/ifdhandler.c"
    write(ifd, patch_ifdhandler_slot(read(ifd), version))
    changed.append("src/ifdhandler.c")

    if needs_supported_readers(version):
        sr = dst / "readers" / "supported_readers.txt"
        if sr.exists():
            write(sr, patch_supported_readers(read(sr)))
            changed.append("readers/supported_readers.txt")

    return changed


def apply_atr(src: Path, dst: Path, version: str) -> list[str]:
    stage_files(src, dst, ATR_FILES)
    write(dst / "src/commands.c", patch_commands_atr(read(dst / "src/commands.c"), version))
    write(dst / "src/ifdhandler.c", patch_ifdhandler_atr(read(dst / "src/ifdhandler.c"), version))
    return ["src/commands.c", "src/ifdhandler.c"]


def try_apply(work: Path, patch_file: Path) -> None:
    errors = []
    r = subprocess.run(
        ["git", "apply", "--verbose", "-p1", str(patch_file)],
        cwd=work,
        capture_output=True,
        text=True,
    )
    if r.returncode == 0:
        return
    errors.append(f"git apply: {r.stdout}\n{r.stderr}")

    r2 = subprocess.run(
        ["patch", "-p1", "--batch", "-i", str(patch_file)],
        cwd=work,
        capture_output=True,
        text=True,
    )
    if r2.returncode == 0:
        return
    errors.append(f"patch: {r2.stdout}\n{r2.stderr}")
    raise RuntimeError(f"apply failed {patch_file.name} on {work.name}:\n" + "\n".join(errors))


def stage_for_verify(src: Path, work: Path, rels: list[str]) -> None:
    stage_files(src, work, rels)


def fetch_upstream(version: str) -> Path:
    """Download + extract upstream CCID-<version> into SRC_ROOT (cached)."""
    dest = SRC_ROOT / f"CCID-{version}"
    if dest.is_dir() and (dest / "src").is_dir():
        print(f"cache hit {dest}")
        return dest

    SRC_ROOT.mkdir(parents=True, exist_ok=True)
    url = UPSTREAM_TAG_URL.format(version=version)
    tar_path = SRC_ROOT / f"{version}.tar.gz"
    print(f"fetch {url}")
    urllib.request.urlretrieve(url, tar_path)

    if dest.exists():
        shutil.rmtree(dest)
    subprocess.run(
        ["tar", "xf", str(tar_path), "-C", str(SRC_ROOT)],
        check=True,
    )
    tar_path.unlink(missing_ok=True)

    if not dest.is_dir():
        raise FileNotFoundError(f"extract failed: expected {dest}")
    return dest


def generate_for_version(version: str) -> None:
    src = fetch_upstream(version)

    out = PATCHES / version
    out.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        slot_dst = td_path / "slot"
        atr_dst = td_path / "atr"
        slot_files = apply_slot(src, slot_dst, version)
        atr_files = apply_atr(src, atr_dst, version)

        # Diff against original files staged beside the modified tree.
        orig_slot = td_path / "orig_slot"
        orig_atr = td_path / "orig_atr"
        stage_files(src, orig_slot, slot_files)
        stage_files(src, orig_atr, atr_files)

        slot_parts = []
        for rel in slot_files:
            d = make_diff(orig_slot, slot_dst, rel)
            if not d.strip():
                raise RuntimeError(f"{version}: empty slot diff for {rel}")
            slot_parts.append(d)

        atr_parts = []
        for rel in atr_files:
            d = make_diff(orig_atr, atr_dst, rel)
            if not d.strip():
                raise RuntimeError(f"{version}: empty atr diff for {rel}")
            atr_parts.append(d)

        write(out / "01_hsic_slot_status.patch", "".join(slot_parts))
        write(out / "02_hsic_malformed_atr.patch", "".join(atr_parts))

    # verify individually + combined against a minimal tree of touched files
    all_rels = sorted(set(SLOT_FILES + ATR_FILES))
    for name, needed in (
        ("01_hsic_slot_status.patch", SLOT_FILES),
        ("02_hsic_malformed_atr.patch", ATR_FILES),
    ):
        with tempfile.TemporaryDirectory() as td:
            work = Path(td) / "tree"
            stage_for_verify(src, work, needed)
            try_apply(work, out / name)

    with tempfile.TemporaryDirectory() as td:
        work = Path(td) / "tree"
        stage_for_verify(src, work, all_rels)
        try_apply(work, out / "01_hsic_slot_status.patch")
        try_apply(work, out / "02_hsic_malformed_atr.patch")

    print(f"OK {version} -> {out} (slot files: {', '.join(slot_files)})")


def main() -> int:
    versions = sys.argv[1:] or VERSIONS
    failed = []
    for v in versions:
        try:
            generate_for_version(v)
        except Exception as e:
            print(f"FAIL {v}: {e}", file=sys.stderr)
            failed.append(v)
    if failed:
        print("Failed:", ", ".join(failed), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
