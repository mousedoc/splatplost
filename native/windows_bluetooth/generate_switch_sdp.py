"""Convert the NXBT SDP XML dialect to a Windows-driver C byte array."""

from __future__ import annotations

import argparse
import xml.etree.ElementTree as ET
from pathlib import Path


TYPE_UINT = 1
TYPE_UUID = 3
TYPE_TEXT = 4
TYPE_BOOL = 5
TYPE_SEQUENCE = 6


def _fixed(kind: int, size_descriptor: int, value: int, size: int) -> bytes:
    return bytes(((kind << 3) | size_descriptor,)) + value.to_bytes(size, "big")


def _variable(kind: int, payload: bytes) -> bytes:
    length = len(payload)
    if length <= 0xFF:
        return bytes(((kind << 3) | 5, length)) + payload
    if length <= 0xFFFF:
        return bytes(((kind << 3) | 6,)) + length.to_bytes(2, "big") + payload
    return bytes(((kind << 3) | 7,)) + length.to_bytes(4, "big") + payload


def encode_element(element: ET.Element) -> bytes:
    value = element.get("value", "")
    if element.tag == "uint8":
        return _fixed(TYPE_UINT, 0, int(value, 0), 1)
    if element.tag == "uint16":
        return _fixed(TYPE_UINT, 1, int(value, 0), 2)
    if element.tag == "uuid":
        return _fixed(TYPE_UUID, 1, int(value, 0), 2)
    if element.tag == "boolean":
        return _fixed(TYPE_BOOL, 0, int(value.lower() == "true"), 1)
    if element.tag == "text":
        payload = bytes.fromhex(value) if element.get("encoding") == "hex" else value.encode("utf-8")
        return _variable(TYPE_TEXT, payload)
    if element.tag == "sequence":
        return _variable(TYPE_SEQUENCE, b"".join(encode_element(child) for child in element))
    raise ValueError(f"Unsupported SDP element: {element.tag}")


def encode_record(path: Path) -> bytes:
    root = ET.parse(path).getroot()
    if root.tag != "record":
        raise ValueError("Expected an SDP <record> document.")
    attributes = bytearray()
    for attribute in root:
        if attribute.tag != "attribute" or len(attribute) != 1:
            raise ValueError("Each SDP attribute must contain exactly one value.")
        attributes.extend(_fixed(TYPE_UINT, 1, int(attribute.get("id", ""), 0), 2))
        attributes.extend(encode_element(attribute[0]))
    return _variable(TYPE_SEQUENCE, bytes(attributes))


def write_header(record: bytes, destination: Path) -> None:
    rows = []
    for offset in range(0, len(record), 12):
        rows.append("    " + ", ".join(f"0x{value:02X}" for value in record[offset:offset + 12]))
    body = ",\n".join(rows)
    destination.write_text(
        "#pragma once\n\n"
        "static UCHAR g_SwitchSdpRecord[] = {\n"
        f"{body}\n"
        "};\n\n"
        "static const ULONG g_SwitchSdpRecordLength = sizeof(g_SwitchSdpRecord);\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    write_header(encode_record(args.source), args.destination)


if __name__ == "__main__":
    main()
