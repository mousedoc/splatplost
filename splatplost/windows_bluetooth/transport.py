"""User-mode bridge to the Splatplost Windows Bluetooth profile driver."""

from __future__ import annotations

import ctypes
import os
import struct
import threading
import time
from ctypes import wintypes


DRIVER_PATH = r"\\.\SplatplostBluetooth"
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
FILE_FLAG_OVERLAPPED = 0x40000000
ERROR_IO_PENDING = 997
ERROR_OPERATION_ABORTED = 995


class _OVERLAPPED(ctypes.Structure):
    """Win32 OVERLAPPED ABI used for concurrent bridge I/O."""

    _fields_ = (
        ("Internal", ctypes.c_size_t),
        ("InternalHigh", ctypes.c_size_t),
        ("Offset", wintypes.DWORD),
        ("OffsetHigh", wintypes.DWORD),
        ("hEvent", wintypes.HANDLE),
    )


class _BLUETOOTH_ADDRESS(ctypes.Union):
    _fields_ = (
        ("ullLong", ctypes.c_ulonglong),
        ("rgBytes", ctypes.c_ubyte * 6),
    )


class _BLUETOOTH_RADIO_INFO(ctypes.Structure):
    _fields_ = (
        ("dwSize", wintypes.DWORD),
        ("address", _BLUETOOTH_ADDRESS),
        ("szName", wintypes.WCHAR * 248),
        ("ulClassofDevice", wintypes.ULONG),
        ("lmpSubversion", wintypes.USHORT),
        ("manufacturer", wintypes.USHORT),
    )


def _ctl_code(device_type: int, function: int, method: int = 0, access: int = 0) -> int:
    return (device_type << 16) | (access << 14) | (function << 2) | method


IOCTL_SPLATPLOST_GET_STATUS = _ctl_code(0x22, 0x800)
INITIALIZATION_STAGE_NAMES = {
    1: "local Bluetooth radio query",
    2: "device-specific HID PSM registration after pairing",
    3: "pairing-notification server registration",
    4: "HID SDP record publication",
    5: "ready-state validation",
}


def _format_bluetooth_address(address: int) -> str:
    address_bytes = address.to_bytes(8, "little")[:6]
    return ":".join(f"{value:02X}" for value in reversed(address_bytes))


def _decode_status(data: bytes) -> tuple[int, str]:
    if len(data) < 16:
        raise OSError(
            "Windows Bluetooth driver returned a truncated status record "
            f"({len(data)} of 16 bytes). Reinstall the matching driver package."
        )
    channels_and_stage, initialization_status, address = struct.unpack_from(
        "<IIQ", data
    )
    stage = channels_and_stage >> 16
    # The driver contract and runtime verifier require STATUS_SUCCESS exactly.
    # Do not treat an unexpected informational/warning NTSTATUS as readiness;
    # accepting anything nonzero would make the GUI less fail-closed than the
    # installation evidence path.
    if initialization_status != 0:
        stage_name = INITIALIZATION_STAGE_NAMES.get(
            stage, "unknown initialization stage"
        )
        raise OSError(
            "Windows Bluetooth driver initialization failed during "
            f"{stage_name} (stage {stage}, "
            f"NTSTATUS 0x{initialization_status:08X})."
        )
    if stage != 5 or address == 0:
        stage_name = INITIALIZATION_STAGE_NAMES.get(
            stage, "unknown initialization stage"
        )
        raise OSError(
            "Windows Bluetooth driver is not ready during "
            f"{stage_name} (stage {stage}, local address 0x{address:012X}). "
            "Restart Windows after installing the matching driver package."
        )
    return channels_and_stage & 0xFFFF, _format_bluetooth_address(address)


class WindowsBluetoothTransport:
    def __init__(self, path: str = DRIVER_PATH):
        self.path = path
        self.handle = None
        self._kernel32 = None
        self._bluetooth = None
        self._radio = None
        self._was_connectable = False
        self._was_discoverable = False
        self._io_condition = threading.Condition(threading.RLock())
        self._active_io = 0
        self._closing = False
        self._close_lock = threading.RLock()

    def open(self) -> None:
        if os.name != "nt":
            raise OSError("Native Windows Bluetooth is available only on Windows.")
        self._kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self._configure_api()
        # The driver deliberately keeps ReadFile pending while its packet FIFO
        # is empty. A synchronous Win32 handle serializes that read with every
        # WriteFile/DeviceIoControl on the same handle, which would deadlock the
        # controller handshake. All three operations therefore use OVERLAPPED.
        self.handle = self._kernel32.CreateFileW(
            self.path,
            0xC0000000,
            0x00000003,
            None,
            3,
            FILE_FLAG_OVERLAPPED,
            None,
        )
        if self.handle == INVALID_HANDLE_VALUE:
            error = ctypes.get_last_error()
            self.handle = None
            if error in (2, 3):
                raise FileNotFoundError(
                    "The Splatplost Windows Bluetooth driver bridge is unavailable "
                    f"(Windows error {error}). Re-run install-driver.ps1 as "
                    "Administrator and restart Windows. The driver may be missing, "
                    "blocked by signature enforcement, or waiting for a restart."
                )
            raise ctypes.WinError(error)
        try:
            _, local_address = self.status()
            self._enable_discovery(local_address)
        except Exception:
            self.close()
            raise

    def close(self) -> None:
        # disconnect(), an in-flight connect failure, and application shutdown
        # may converge here. Serialize the complete handle/radio restoration so
        # two callers cannot close the selected radio handle twice.
        with self._close_lock:
            self._close_resources()

    def _close_resources(self) -> None:
        handle = None
        kernel32 = self._kernel32
        with self._io_condition:
            if self.handle is not None:
                handle = self.handle
                # Prevent a new operation from being submitted after the
                # cancellation sweep. Operations submit while holding this
                # condition, so every active request is now visible to
                # CancelIoEx.
                self.handle = None
                self._closing = True
                kernel32.CancelIoEx(handle, None)
                while self._active_io:
                    self._io_condition.wait()
        if handle is not None:
            kernel32.CloseHandle(handle)
            with self._io_condition:
                self._closing = False
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
        returned = self._overlapped_io(
            lambda handle, transferred, overlapped: self._kernel32.DeviceIoControl(
                handle,
                IOCTL_SPLATPLOST_GET_STATUS,
                None,
                0,
                output,
                len(output),
                transferred,
                overlapped,
            )
        )
        if returned < len(output):
            raise OSError(
                "Windows Bluetooth driver returned a truncated status record "
                f"({returned} of {len(output)} bytes). Reinstall the "
                "matching driver package."
            )
        return _decode_status(output.raw[:returned])

    def wait_connected(self, timeout: float = 180.0, cancel_event=None) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if cancel_event is not None and cancel_event.is_set():
                raise ConnectionAbortedError("Windows Bluetooth pairing was cancelled.")
            try:
                channels, address = self.status()
            except OSError as error:
                # close() deliberately cancels outstanding status I/O. If
                # cancellation was requested while DeviceIoControl waited,
                # translate WinError 995 (and equivalent close races) into the
                # public cancellation result instead of a spurious GUI error.
                if cancel_event is not None and cancel_event.is_set():
                    raise ConnectionAbortedError(
                        "Windows Bluetooth pairing was cancelled."
                    ) from error
                raise
            if cancel_event is not None and cancel_event.is_set():
                raise ConnectionAbortedError("Windows Bluetooth pairing was cancelled.")
            if channels & 0x03 == 0x03:
                return address
            time.sleep(0.1)
        raise TimeoutError("Timed out waiting for the Switch Bluetooth connection.")

    def read(self, size: int = 64) -> bytes:
        buffer = ctypes.create_string_buffer(size)
        read = self._overlapped_io(
            lambda handle, transferred, overlapped: self._kernel32.ReadFile(
                handle,
                buffer,
                size,
                transferred,
                overlapped,
            )
        )
        return buffer.raw[:read]

    def write(self, data: bytes) -> None:
        buffer = ctypes.create_string_buffer(data)
        written = self._overlapped_io(
            lambda handle, transferred, overlapped: self._kernel32.WriteFile(
                handle,
                buffer,
                len(data),
                transferred,
                overlapped,
            )
        )
        if written != len(data):
            raise OSError(f"Driver accepted {written} of {len(data)} bytes.")

    def _overlapped_io(self, submit) -> int:
        """Submit one operation and wait for its independent completion event."""
        kernel32 = self._kernel32
        if kernel32 is None:
            raise OSError("The Windows Bluetooth driver bridge is not open.")

        event = kernel32.CreateEventW(None, True, False, None)
        if not event:
            raise ctypes.WinError(ctypes.get_last_error())

        overlapped = _OVERLAPPED()
        overlapped.hEvent = event
        transferred = wintypes.DWORD()
        active = False
        try:
            # Keep submission serialized with close(). This closes the race in
            # which CancelIoEx could otherwise run just before a new pending
            # ReadFile is issued, leaving close() waiting forever.
            with self._io_condition:
                if self.handle is None or self._closing:
                    raise OSError("The Windows Bluetooth driver bridge is not open.")
                handle = self.handle
                self._active_io += 1
                active = True
                completed = submit(
                    handle,
                    ctypes.byref(transferred),
                    ctypes.byref(overlapped),
                )
                error = 0 if completed else ctypes.get_last_error()

            if not completed:
                if error != ERROR_IO_PENDING:
                    raise ctypes.WinError(error)
                completed = kernel32.GetOverlappedResult(
                    handle,
                    ctypes.byref(overlapped),
                    ctypes.byref(transferred),
                    True,
                )
                if not completed:
                    raise ctypes.WinError(ctypes.get_last_error())
            return transferred.value
        finally:
            kernel32.CloseHandle(event)
            if active:
                with self._io_condition:
                    self._active_io -= 1
                    self._io_condition.notify_all()

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
        self._kernel32.CreateEventW.argtypes = (
            wintypes.LPVOID,
            wintypes.BOOL,
            wintypes.BOOL,
            wintypes.LPCWSTR,
        )
        self._kernel32.CreateEventW.restype = wintypes.HANDLE
        self._kernel32.GetOverlappedResult.argtypes = (
            wintypes.HANDLE,
            ctypes.POINTER(_OVERLAPPED),
            ctypes.POINTER(wintypes.DWORD),
            wintypes.BOOL,
        )
        self._kernel32.GetOverlappedResult.restype = wintypes.BOOL
        self._kernel32.DeviceIoControl.argtypes = (
            wintypes.HANDLE,
            wintypes.DWORD,
            wintypes.LPVOID,
            wintypes.DWORD,
            wintypes.LPVOID,
            wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD),
            ctypes.POINTER(_OVERLAPPED),
        )
        self._kernel32.DeviceIoControl.restype = wintypes.BOOL
        self._kernel32.ReadFile.argtypes = (
            wintypes.HANDLE,
            wintypes.LPVOID,
            wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD),
            ctypes.POINTER(_OVERLAPPED),
        )
        self._kernel32.ReadFile.restype = wintypes.BOOL
        self._kernel32.WriteFile.argtypes = self._kernel32.ReadFile.argtypes
        self._kernel32.WriteFile.restype = wintypes.BOOL

    def _enable_discovery(self, expected_address: str) -> None:
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
        self._bluetooth.BluetoothFindNextRadio.argtypes = (
            wintypes.HANDLE,
            ctypes.POINTER(wintypes.HANDLE),
        )
        self._bluetooth.BluetoothFindNextRadio.restype = wintypes.BOOL
        self._bluetooth.BluetoothGetRadioInfo.argtypes = (
            wintypes.HANDLE,
            ctypes.POINTER(_BLUETOOTH_RADIO_INFO),
        )
        self._bluetooth.BluetoothGetRadioInfo.restype = wintypes.DWORD
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
        selected_radio = None
        enumeration_error = 0
        try:
            while True:
                info = _BLUETOOTH_RADIO_INFO()
                info.dwSize = ctypes.sizeof(_BLUETOOTH_RADIO_INFO)
                result = int(
                    self._bluetooth.BluetoothGetRadioInfo(radio, ctypes.byref(info))
                )
                if result == 0 and _format_bluetooth_address(
                    int(info.address.ullLong)
                ) == expected_address:
                    selected_radio = radio
                    break
                if result != 0:
                    enumeration_error = result
                self._kernel32.CloseHandle(radio)
                radio = wintypes.HANDLE()
                if not self._bluetooth.BluetoothFindNextRadio(
                    search, ctypes.byref(radio)
                ):
                    next_error = ctypes.get_last_error()
                    if next_error not in (0, 259):
                        enumeration_error = next_error
                    break
        except Exception:
            if radio:
                self._kernel32.CloseHandle(radio)
            raise
        finally:
            self._bluetooth.BluetoothFindRadioClose(search)

        if selected_radio is None:
            detail = (
                f" (Windows error {enumeration_error})" if enumeration_error else ""
            )
            raise OSError(
                "The driver Bluetooth radio "
                f"{expected_address} is not enabled or could not be opened{detail}."
            )

        self._radio = selected_radio
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
