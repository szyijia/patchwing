#!/usr/bin/env python3
"""Apply Patchwing-only branding to Android engine artifacts.

The Shorebird and Patchwing names have the same byte length. This lets us
replace user-visible strings in prebuilt artifacts without moving binary data
or changing executable logic. ELF dynamic string tables are deliberately left
untouched because they contain the stable updater C ABI and are covered by the
loader's symbol hash tables.
"""

from __future__ import annotations

import argparse
import io
import struct
import sys
import zipfile
from pathlib import Path


REPLACEMENTS = (
    (b"https://api.shorebird.dev", b"https://api.patchwing.net"),
    (b"https://download.shorebird.dev", b"https://download.patchwing.dev"),
    (b"Shorebird", b"Patchwing"),
    (b"SHOREBIRD", b"PATCHWING"),
    (b"shorebird", b"patchwing"),
)

FORBIDDEN_EXPOSURES = (
    b"api.shorebird",
    b"download.shorebird",
    b"cdn.shorebird",
    b"shorebird.dev",
    b"shorebird.yaml",
    b"[shorebird]",
    b"Shorebird",
)


def _replace(data: bytes) -> bytes:
    for old, new in REPLACEMENTS:
        if len(old) != len(new):
            raise ValueError(f"replacement length differs: {old!r} -> {new!r}")
        data = data.replace(old, new)
    return data


def _elf_dynstr_range(data: bytes) -> tuple[int, int]:
    if not data.startswith(b"\x7fELF"):
        raise ValueError("not an ELF file")
    elf_class = data[4]
    endian = data[5]
    if endian != 1:
        raise ValueError("only little-endian ELF files are supported")

    if elf_class == 1:
        header = struct.unpack_from("<16sHHIIIIIHHHHHH", data, 0)
        section_offset, section_entry_size, section_count, names_index = (
            header[6],
            header[11],
            header[12],
            header[13],
        )
        section_format = "<IIIIIIIIII"
    elif elf_class == 2:
        header = struct.unpack_from("<16sHHIQQQIHHHHHH", data, 0)
        section_offset, section_entry_size, section_count, names_index = (
            header[6],
            header[11],
            header[12],
            header[13],
        )
        section_format = "<IIQQQQIIQQ"
    else:
        raise ValueError(f"unsupported ELF class: {elf_class}")

    sections = [
        struct.unpack_from(section_format, data, section_offset + i * section_entry_size)
        for i in range(section_count)
    ]
    names_section = sections[names_index]
    names_offset, names_size = names_section[4], names_section[5]
    names = data[names_offset : names_offset + names_size]

    for section in sections:
        name_start = section[0]
        name_end = names.find(b"\0", name_start)
        if name_end == -1:
            continue
        if names[name_start:name_end] == b".dynstr":
            return section[4], section[5]
    raise ValueError("ELF file has no .dynstr section")


def brand_elf(data: bytes) -> bytes:
    dynstr_offset, dynstr_size = _elf_dynstr_range(data)
    before = _replace(data[:dynstr_offset])
    dynstr = data[dynstr_offset : dynstr_offset + dynstr_size]
    after = _replace(data[dynstr_offset + dynstr_size :])
    return before + dynstr + after


def brand_payload(data: bytes) -> bytes:
    if data.startswith(b"\x7fELF"):
        return brand_elf(data)
    if data.startswith(b"PK\x03\x04"):
        return brand_zip(data)
    return _replace(data)


def brand_zip(data: bytes) -> bytes:
    source = zipfile.ZipFile(io.BytesIO(data), "r")
    output = io.BytesIO()
    with source, zipfile.ZipFile(output, "w") as destination:
        for entry in source.infolist():
            branded_name = _replace(entry.filename.encode()).decode()
            branded_entry = zipfile.ZipInfo(branded_name, (1980, 1, 1, 0, 0, 0))
            branded_entry.compress_type = entry.compress_type
            branded_entry.external_attr = entry.external_attr
            branded_entry.comment = _replace(entry.comment)
            branded_entry.extra = entry.extra
            branded_entry.create_system = entry.create_system
            payload = brand_payload(source.read(entry.filename))
            verify_no_exposure(payload, f"archive entry {entry.filename}")
            destination.writestr(branded_entry, payload)
    return output.getvalue()


def verify_no_exposure(data: bytes, label: str) -> None:
    for forbidden in FORBIDDEN_EXPOSURES:
        if forbidden in data:
            raise ValueError(f"{label}: forbidden exposure remains: {forbidden.decode()}")


def verify_payload(data: bytes, label: str) -> None:
    verify_no_exposure(data, label)
    if not data.startswith(b"PK\x03\x04"):
        return
    with zipfile.ZipFile(io.BytesIO(data), "r") as archive:
        for entry in archive.infolist():
            verify_no_exposure(entry.filename.encode(), f"{label}:{entry.filename}")
            verify_payload(archive.read(entry.filename), f"{label}:{entry.filename}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("input", type=Path)
    parser.add_argument("output", nargs="?", type=Path)
    args = parser.parse_args()

    source = args.input.read_bytes()
    if args.verify_only:
        if args.output is not None:
            parser.error("output is not accepted with --verify-only")
        verify_payload(source, str(args.input))
        return 0
    if args.output is None:
        parser.error("output is required unless --verify-only is used")
    branded = brand_payload(source)
    verify_payload(branded, str(args.output))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(branded)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
