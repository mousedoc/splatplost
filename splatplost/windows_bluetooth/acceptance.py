"""Application-level acceptance evidence for the native Windows backend."""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from splatplost.version import __version__

from .backend import WindowsBluetoothControl


EVIDENCE_TYPE = "splatplost-windows-bluetooth-application"


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_evidence_path(value: str | os.PathLike[str]) -> Path:
    path = Path(value).expanduser().resolve()
    if path.suffix.lower() != ".json":
        raise ValueError("Windows Bluetooth acceptance evidence must use a .json file.")
    if path.is_dir():
        raise IsADirectoryError(f"Evidence path is a directory: {path}")
    if path.exists():
        try:
            previous = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise FileExistsError(
                f"Refusing to overwrite a file that is not prior Splatplost evidence: {path}"
            ) from error
        if not (
            isinstance(previous, dict)
            and previous.get("schemaVersion") == 1
            and previous.get("evidenceType") == EVIDENCE_TYPE
        ):
            raise FileExistsError(
                f"Refusing to overwrite a file that is not prior Splatplost evidence: {path}"
            )
    return path


def _write_evidence(path: Path, evidence: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(evidence, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def verify_windows_bluetooth_application(
    evidence_path: str | os.PathLike[str],
    *,
    pairing_timeout: float = 180.0,
    handshake_timeout: float = 60.0,
    settle_seconds: float = 1.0,
    backend_factory: Callable[..., WindowsBluetoothControl] = WindowsBluetoothControl,
) -> dict:
    """Run a real bridge/channel/Switch handshake and persist fail-closed JSON."""

    path = _safe_evidence_path(evidence_path)
    generated_at = datetime.now(timezone.utc)
    frozen = bool(getattr(sys, "frozen", False))
    executable_name = Path(sys.executable).name if sys.executable else None
    evidence = {
        "schemaVersion": 1,
        "evidenceType": EVIDENCE_TYPE,
        "generatedAtUtc": generated_at.isoformat().replace("+00:00", "Z"),
        "backend": "Windows Bluetooth",
        "application": {
            "version": __version__,
            "frozenExecutable": frozen,
            "executableName": executable_name,
            "executableSha256": None,
        },
        "parameters": {
            "pairingTimeoutSeconds": pairing_timeout,
            "handshakeTimeoutSeconds": handshake_timeout,
            "settleSeconds": settle_seconds,
        },
        "passed": False,
        "checks": {
            "packagedExecutable": False,
            "bridgeAndChannels": False,
            "deviceInfoQuery": False,
            "vibrationEnable": False,
            "playerAssignment": False,
            "connectionStayedAlive": False,
        },
        "localControllerBluetoothAddress": None,
        "finalDriverChannelMask": None,
        "playerNumber": None,
        "failureType": None,
        "failure": None,
        "limitations": [
            "A pass proves the packaged application exchanged the controller handshake over both driver channels.",
            "It does not prove that a complete drawing was accepted by a game.",
        ],
    }

    backend: WindowsBluetoothControl | None = None
    failure: Exception | None = None
    try:
        if not frozen:
            raise RuntimeError(
                "Windows Bluetooth application acceptance must be run from the "
                "packaged splatplost.exe; a source Python process cannot produce "
                "executable-bound pass evidence."
            )
        executable_path = Path(sys.executable).resolve(strict=True)
        if not executable_path.is_file():
            raise FileNotFoundError(
                "The packaged Splatplost executable is not a regular file: "
                f"{executable_path}"
            )
        executable_sha256 = _sha256_file(executable_path)
        if re.fullmatch(r"[0-9a-f]{64}", executable_sha256) is None:
            raise RuntimeError(
                "The packaged Splatplost executable did not produce a valid "
                "SHA-256 identity."
            )
        evidence["application"]["executableName"] = executable_path.name
        evidence["application"]["executableSha256"] = executable_sha256
        evidence["checks"]["packagedExecutable"] = True

        backend = backend_factory(
            pairing_timeout=pairing_timeout,
            handshake_timeout=handshake_timeout,
        )
        backend.connect()
        evidence["checks"]["bridgeAndChannels"] = True
        protocol = backend.protocol
        if protocol is None:
            raise RuntimeError("The Windows Bluetooth backend returned without a protocol session.")

        evidence["localControllerBluetoothAddress"] = protocol.bluetooth_address
        evidence["playerNumber"] = protocol.player_number
        evidence["checks"]["deviceInfoQuery"] = protocol.device_info_queried is True
        evidence["checks"]["vibrationEnable"] = protocol.vibration_enabled is True
        evidence["checks"]["playerAssignment"] = protocol.player_number in (1, 2, 3, 4)
        if not all(evidence["checks"].values()):
            # connectionStayedAlive is populated after the settling interval.
            required = (
                evidence["checks"]["deviceInfoQuery"],
                evidence["checks"]["vibrationEnable"],
                evidence["checks"]["playerAssignment"],
            )
            if not all(required):
                raise RuntimeError("The Nintendo Switch controller handshake was incomplete.")

        time.sleep(max(0.0, settle_seconds))
        backend._ensure_connected()
        channels, final_local_address = backend.transport.status()
        evidence["finalDriverChannelMask"] = channels
        if channels & 0x03 != 0x03:
            raise ConnectionError(
                "Both Windows Bluetooth HID channels did not remain connected "
                f"(driver channel mask 0x{channels:04X})."
            )
        if final_local_address != protocol.bluetooth_address:
            raise ConnectionError(
                "The driver local Bluetooth address changed during acceptance."
            )
        evidence["checks"]["connectionStayedAlive"] = True
        evidence["passed"] = all(evidence["checks"].values())
    except Exception as error:  # Evidence must record operational failures.
        failure = error
    finally:
        if backend is not None:
            try:
                backend.disconnect()
            except Exception as disconnect_error:
                if failure is None:
                    failure = disconnect_error
                    evidence["passed"] = False

    if failure is not None:
        evidence["failureType"] = type(failure).__name__
        evidence["failure"] = str(failure)
    evidence["completedAtUtc"] = datetime.now(timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )
    evidence["evidencePath"] = str(path)
    _write_evidence(path, evidence)
    return evidence
