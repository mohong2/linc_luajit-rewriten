#!/usr/bin/env python3
"""Report the CPU architecture(s) of a static library.

A prebuilt LuaJIT that does not match the target it is linked into fails at
link time at best and at run time at worst, so generated artifacts are checked
against the target they were built for instead of being trusted.

Handles ELF objects inside a GNU archive (Linux / Android / MinGW), Mach-O thin
and fat objects (macOS / iOS) including the BSD "#1/<len>" member names Apple's
ar emits, COFF objects inside an MSVC .lib, and thin archives.

Usage: lib_arch.py [--expect ARCH] FILE...
Exit status is non-zero when --expect is given and any file disagrees.
"""

from __future__ import annotations

import struct
import sys

ELF_CLASS = {1: "32", 2: "64"}
ELF_MACHINE = {
    3: "x86",
    8: "mips",
    20: "ppc",
    21: "ppc64",
    40: "armv7",
    62: "x86_64",
    183: "arm64",
}
MACH_CPU = {
    7: "x86",
    12: "armv7",
    0x01000007: "x86_64",
    0x0100000C: "arm64",
}
COFF_MACHINE = {
    0x014C: "x86",
    0x01C4: "armv7",
    0x8664: "x86_64",
    0xAA64: "arm64",
}

FAT_BIG = b"\xca\xfe\xba\xbe"
FAT_LITTLE = b"\xbe\xba\xfe\xca"
MACH_LITTLE_64 = b"\xcf\xfa\xed\xfe"
MACH_LITTLE_32 = b"\xce\xfa\xed\xfe"
MACH_BIG_64 = b"\xfe\xed\xfa\xcf"
MACH_BIG_32 = b"\xfe\xed\xfa\xce"


def _macho(data):
    magic = data[:4]
    if magic in (FAT_BIG, FAT_LITTLE):
        endian = ">" if magic == FAT_BIG else "<"
        count = struct.unpack(endian + "I", data[4:8])[0]
        archs = []
        for index in range(count):
            base = 8 + index * 20
            cpu = struct.unpack(endian + "i", data[base:base + 4])[0]
            name = MACH_CPU.get(cpu & 0xFFFFFFFF)
            if name and name not in archs:
                archs.append(name)
        return archs
    if magic in (MACH_LITTLE_64, MACH_LITTLE_32, MACH_BIG_64, MACH_BIG_32):
        little = magic in (MACH_LITTLE_64, MACH_LITTLE_32)
        cpu = struct.unpack("<i" if little else ">i", data[4:8])[0]
        name = MACH_CPU.get(cpu & 0xFFFFFFFF)
        return [name] if name else []
    return None


def _elf(data):
    if data[:4] != b"\x7fELF":
        return []
    endian = "<" if data[5] == 1 else ">"
    machine = struct.unpack(endian + "H", data[18:20])[0]
    name = ELF_MACHINE.get(machine)
    return [name] if name else []


def _coff(data):
    if len(data) < 20 or data[:2] == b"MZ":
        return []
    name = COFF_MACHINE.get(struct.unpack("<H", data[0:2])[0])
    return [name] if name else []


def member_arch(data):
    """Architectures reported by one archive member, [] for non-objects."""
    found = _macho(data)
    if found:
        return found
    found = _elf(data)
    if found:
        return found
    return _coff(data)


def sniff(data):
    """Architecture string for a whole file, or None when it is not a library."""
    fat = _macho(data)
    if fat and data[:4] in (FAT_BIG, FAT_LITTLE):
        return "fat:" + "+".join(sorted(set(fat)))

    for magic in (b"!<arch>\n", b"!<thin>\n"):
        if data[:8] != magic:
            continue
        found = []
        offset = 8
        while offset + 60 <= len(data):
            head = data[offset:offset + 60]
            if head[58:60] != b"\x60\n":
                break
            name = head[0:16].decode("ascii", "replace").strip()
            try:
                size = int(head[48:58].decode("ascii").strip())
            except ValueError:
                break
            body = offset + 60
            blob = data[body:body + size]
            # BSD ar stores "#1/<len>" and prepends the real name to the data.
            if name.startswith("#1/"):
                try:
                    blob = blob[int(name[3:]):]
                except ValueError:
                    pass
            for arch in member_arch(blob):
                if arch not in found:
                    found.append(arch)
            offset = body + size + (size % 2)
        if not found:
            return None
        return "fat:" + "+".join(sorted(found)) if len(found) > 1 else found[0]

    direct = member_arch(data)
    return direct[0] if direct else None


def matches(arch, expect):
    if arch == expect:
        return True
    return arch.startswith("fat:") and expect in arch[4:].split("+")


def main(argv):
    expects = []
    paths = []
    index = 1
    while index < len(argv):
        arg = argv[index]
        if arg == "--expect":
            index += 1
            expects.append(argv[index])
        else:
            paths.append(arg)
        index += 1

    if not paths:
        print("usage: lib_arch.py [--expect ARCH] FILE...", file=sys.stderr)
        return 2

    status = 0
    for path in paths:
        try:
            with open(path, "rb") as handle:
                data = handle.read()
        except OSError as exc:
            print("%s: cannot read: %s" % (path, exc))
            status = 1
            continue
        arch = sniff(data)
        if arch is None:
            print("%s: not an archive/object (magic %s)" % (path, data[:4].hex()))
            status = 1
            continue
        if not expects:
            print("%s: %s" % (path, arch))
            continue
        missing = [want for want in expects if not matches(arch, want)]
        ok = not missing
        detail = "ok" if ok else "MISSING " + ",".join(missing)
        print("%s: %s  %s" % (path, arch, detail))
        if not ok:
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
