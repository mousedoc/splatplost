"""User-mode bridge to the Splatplost Windows Bluetooth profile driver."""

from __future__ import annotations

import ctypes
import os
import struct
import time
from ctypes import wintypes


DRIVER_PATH = r"\\.\SplatplostBluetooth"
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value


def _ctl_code(device_type: int, function: int, method: int = 0, access: int = 0) -> int:
    return (device_type << 16) | (access << 14) | (function << 2) | method


IOCTL_SPLATPLOST_GET_STATUS = _ctl_code(0x22, 0x800)


class WindowsBluetoothTransport:
    def __init__(self, path: str = DRIVER_PATH):
        self.path = path
        self.handle = None
        self._kernel32 = None
        self._bluetooth = None
        self._radio = None
        self._was_connectable = False
        self._was_discoverable = False

    def open(self) -> None:
        if os.name != "nt":
            raise OSError("Native Windows Bluetooth is available only on Windows.")
        self._kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self._configure_api()
        self.handle = self._kernel32.CreateFileW(
            self.path,
            0xC0000000,
            0x00000003,
            None,
            3,
            0,
            None,
        )
        if self.handle == INVALID_HANDLE_VALUE:
            error = ctypes.get_last_error()
            self.handle = None
            if error in (2, 3):
                raise FileNotFoundError(
                    "The Splatplost Windows Bluetooth driver is not installed."
                )
            raise ctypes.WinError(error)
        try:
            self._enable_discovery()
        except Exception:
            self.close()
            raise

    def close(self) -> None:
        if self.handle is not None:
            self._kernel32.CancelIoEx(self.handle, None)
            self._kernel32.CloseHandle(self.handle)
            self.handle = None
        if self._radio is not None:
            if not self._was_discoverable:
                self._bluetooth.BluetoothEnableDiscovery(self._radio, False)
            if not self._was_connectable:
                self._bluetooth.BluetoothEnableIncomingConnections(
                    self._radio,
                    False,
                )
            self._kernel32.CloseHandle(self._radio)
            self._radio = None

    def status(self) -> tuple[int, str]:
        output = ctypes.create_string_buffer(16)
        returned = wintypes.DWORD()
        ok = self._kernel32.DeviceIoControl(
            self.handle,
            IOCTL_SPLATPLOST_GET_STATUS,
            None,
            0,
            output,
            len(output),
            ctypes.byref(returned),
            None,
        )
        if not ok:
            raise ctypes.WinError(ctypes.get_last_error())
        channels, _reserved, address = struct.unpack_from("<IIQ", output.raw)
        address_bytes = address.to_bytes(8, "little")[:6]
        address_text = ":".join(f"{value:02X}" for value in reversed(address_bytes))
        return channels, address_text

    def wait_connected(self, timeout: float = 180.0) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            channels, address = self.status()
            if channels & 0x03 == 0x03:
                return address
            time.sleep(0.1)
        raise TimeoutError("Timed out waiting for the Switch Bluetooth connection.")

    def read(self, size: int = 64) -> bytes:
        buffer = ctypes.create_string_buffer(size)
        read = wintypes.DWORD()
        ok = self._kernel32.ReadFile(
            self.handle, buffer, size, ctypes.byref(read), None
        )
        if not ok:
            raise ctypes.WinError(ctypes.get_last_error())
        return buffer.raw[:read.value]

    def write(self, data: bytes) -> None:
        written = wintypes.DWORD()
        buffer = ctypes.create_string_buffer(data)
        ok = self._kernel32.WriteFile(
            self.handle, buffer, len(data), ctypes.byref(written), None
        )
        if not ok:
            raise ctypes.WinError(ctypes.get_last_error())
        if written.value != len(data):
            raise OSError(f"Driver accepted {written.value} of {len(data)} bytes.")

    def _configure_api(self) -> None:
        """Declare Win32 signatures so 64-bit HANDLE values are not truncated."""
        self._kernel32.CreateFileW.argtypes = (
            wintypes.LPCWSTR,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.LPVOID,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.HANDLE,
        )
        self._kernel32.CreateFileW.restype = wintypes.HANDLE
        self._kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
        self._kernel32.CloseHandle.restype = wintypes.BOOL
        self._kernel32.CancelIoEx.argtypes = (wintypes.HANDLE, wintypes.LPVOID)
        self._kernel32.CancelIoEx.restype = wintypes.BOOL
        self._kernel32.DeviceIoControl.argtypes = (
            wintypes.HANDLE,
            wintypes.DWORD,
            wintypes.LPVOID,
            wintypes.DWORD,
            wintypes.LPVOID,
            wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD),
            wintypes.LPVOID,
        )
        self._kernel32.DeviceIoControl.restype = wintypes.BOOL
        self._kernel32.ReadFile.argtypes = (
            wintypes.HANDLE,
            wintypes.LPVOID,
            wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD),
            wintypes.LPVOID,
        )
        self._kernel32.ReadFile.restype = wintypes.BOOL
        self._kernel32.WriteFile.argtypes = self._kernel32.ReadFile.argtypes
        self._kernel32.WriteFile.restype = wintypes.BOOL

    def _enable_discovery(self) -> None:
        class BLUETOOTH_FIND_RADIO_PARAMS(ctypes.Structure):
            _fields_ = (("dwSize", wintypes.DWORD),)

        self._bluetooth = ctypes.WinDLL("BluetoothApis", use_last_error=True)
        self._bluetooth.BluetoothFindFirstRadio.argtypes = (
            ctypes.POINTER(BLUETOOTH_FIND_RADIO_PARAMS),
            ctypes.POINTER(wintypes.HANDLE),
        )
        self._bluetooth.BluetoothFindFirstRadio.restype = wintypes.HANDLE
        self._bluetooth.BluetoothFindRadioClose.argtypes = (wintypes.HANDLE,)
        self._bluetooth.BluetoothFindRadioClose.restype = wintypes.BOOL
        self._bluetooth.BluetoothIsDiscoverable.argtypes = (wintypes.HANDLE,)
        self._bluetooth.BluetoothIsDiscoverable.restype = wintypes.BOOL
        self._bluetooth.BluetoothIsConnectable.argtypes = (wintypes.HANDLE,)
        self._bluetooth.BluetoothIsConnectable.restype = wintypes.BOOL
        self._bluetooth.BluetoothEnableIncomingConnections.argtypes = (
            wintypes.HANDLE,
            wintypes.BOOL,
        )
        self._bluetooth.BluetoothEnableIncomingConnections.restype = wintypes.BOOL
        self._bluetooth.BluetoothEnableDiscovery.argtypes = (
            wintypes.HANDLE,
            wintypes.BOOL,
        )
        self._bluetooth.BluetoothEnableDiscovery.restype = wintypes.BOOL

        params = BLUETOOTH_FIND_RADIO_PARAMS(ctypes.sizeof(BLUETOOTH_FIND_RADIO_PARAMS))
        radio = wintypes.HANDLE()
        search = self._bluetooth.BluetoothFindFirstRadio(
            ctypes.byref(params),
            ctypes.byref(radio),
        )
        if not search:
            raise OSError("No enabled Windows Bluetooth radio was found.")
        self._bluetooth.BluetoothFindRadioClose(search)
        self._radio = radio
        self._was_connectable = bool(
            self._bluetooth.BluetoothIsConnectable(self._radio)
        )
        self._was_discoverable = bool(
            self._bluetooth.BluetoothIsDiscoverable(self._radio)
        )
        if (
            not self._was_connectable
            and not self._bluetooth.BluetoothEnableIncomingConnections(
                self._radio,
                True,
            )
        ):
            raise ctypes.WinError(ctypes.get_last_error())
        if not self._was_discoverable and not self._bluetooth.BluetoothEnableDiscovery(
            self._radio,
            True,
        ):
            raise ctypes.WinError(ctypes.get_last_error())
