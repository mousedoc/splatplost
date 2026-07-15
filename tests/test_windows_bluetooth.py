import ctypes
import hashlib
import json
import os
import struct
import tempfile
import threading
import time
import unittest
from ctypes import wintypes
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

from libnxctrl.wrapper import Button

from splatplost.windows_bluetooth.backend import WindowsBluetoothControl
import splatplost.windows_bluetooth.acceptance as acceptance_module
from splatplost.windows_bluetooth.acceptance import verify_windows_bluetooth_application
from splatplost.windows_bluetooth.protocol import SwitchProtocol
from splatplost.windows_bluetooth.transport import (
    ERROR_IO_PENDING,
    ERROR_OPERATION_ABORTED,
    FILE_FLAG_OVERLAPPED,
    WindowsBluetoothTransport,
    _BLUETOOTH_ADDRESS,
    _BLUETOOTH_RADIO_INFO,
    _OVERLAPPED,
    _decode_status,
    _format_bluetooth_address,
)


def switch_subcommand(command: int, payload: bytes = b"") -> bytes:
    if len(payload) > 38:
        raise ValueError("Switch subcommand payload is too large")
    report = bytearray(50)
    report[0] = 0xA2
    report[11] = command
    report[12:12 + len(payload)] = payload
    return bytes(report)


class ProtocolTests(unittest.TestCase):
    def test_handshake_and_button_report(self):
        protocol = SwitchProtocol("01:23:45:67:89:AB")
        protocol.process_switch_report(switch_subcommand(0x02))
        device_reply = protocol.next_input_report()
        self.assertEqual(device_reply[0:2], b"\xA1\x21")
        self.assertEqual(device_reply[20:26], bytes.fromhex("0123456789AB"))

        protocol.process_switch_report(switch_subcommand(0x48, b"\x01"))
        protocol.next_input_report()
        protocol.process_switch_report(switch_subcommand(0x30, b"\x01"))
        protocol.next_input_report()
        self.assertTrue(protocol.handshake_complete)

        protocol.set_buttons(Button.A | Button.DPAD_LEFT)
        report = protocol.next_input_report()
        self.assertEqual(report[4] & 0x08, 0x08)
        self.assertEqual(report[6] & 0x08, 0x08)

    def test_spi_read_is_bounded_to_report(self):
        protocol = SwitchProtocol("00:00:00:00:00:00")
        protocol.process_switch_report(
            switch_subcommand(0x10, bytes((0x3D, 0x60, 0, 0, 0xFF)))
        )
        report = protocol.next_input_report()
        self.assertEqual(len(report), SwitchProtocol.REPORT_SIZE)
        self.assertEqual(report[20], 29)

    def test_rejects_truncated_subcommand_instead_of_acknowledging_it(self):
        protocol = SwitchProtocol("00:00:00:00:00:00")
        protocol.process_switch_report(bytes((0xA2,)) + bytes(11))
        self.assertEqual(protocol.next_input_report()[1], 0x30)
        self.assertFalse(protocol.device_info_queried)

    def test_all_supported_subcommands_match_expected_acknowledgements(self):
        cases = (
            (0x02, b"", 0x82),
            (0x08, b"", 0x80),
            (0x03, b"\x30", 0x80),
            (0x04, b"", 0x83),
            (0x40, b"\x01", 0x80),
            (0x48, b"\x01", 0x82),
            (0x30, b"\x01", 0x80),
            (0x22, b"", 0x80),
            (0x21, b"", 0xA0),
        )
        for command, payload, acknowledgement in cases:
            with self.subTest(command=command):
                protocol = SwitchProtocol("01:23:45:67:89:AB")
                protocol.process_switch_report(switch_subcommand(command, payload))
                report = protocol.next_input_report()
                self.assertEqual(report[0:2], b"\xA1\x21")
                self.assertEqual(report[14], acknowledgement)
                self.assertEqual(report[15], command)

    def test_every_button_maps_to_the_pro_controller_report_bit(self):
        expected = {
            Button.Y: (4, 0x01),
            Button.X: (4, 0x02),
            Button.B: (4, 0x04),
            Button.A: (4, 0x08),
            Button.JCR_SR: (4, 0x10),
            Button.JCR_SL: (4, 0x20),
            Button.SHOULDER_R: (4, 0x40),
            Button.SHOULDER_ZR: (4, 0x80),
            Button.MINUS: (5, 0x01),
            Button.PLUS: (5, 0x02),
            Button.R_STICK_PRESS: (5, 0x04),
            Button.L_STICK_PRESS: (5, 0x08),
            Button.HOME: (5, 0x10),
            Button.CAPTURE: (5, 0x20),
            Button.DPAD_DOWN: (6, 0x01),
            Button.DPAD_UP: (6, 0x02),
            Button.DPAD_RIGHT: (6, 0x04),
            Button.DPAD_LEFT: (6, 0x08),
            Button.JCL_SR: (6, 0x10),
            Button.JCL_SL: (6, 0x20),
            Button.SHOULDER_L: (6, 0x40),
            Button.SHOULDER_ZL: (6, 0x80),
        }
        for button, (offset, mask) in expected.items():
            with self.subTest(button=button):
                protocol = SwitchProtocol("00:00:00:00:00:00")
                protocol.device_info_queried = True
                protocol.set_buttons(button)
                report = protocol.next_input_report()
                self.assertEqual(report[offset], mask)
                other_offsets = {4, 5, 6} - {offset}
                self.assertTrue(all(report[index] == 0 for index in other_offsets))


class TransportStatusTests(unittest.TestCase):
    def test_formats_windows_bth_addr_in_display_order(self):
        self.assertEqual(
            _format_bluetooth_address(0x0123456789AB),
            "01:23:45:67:89:AB",
        )

    @unittest.skipUnless(os.name == "nt", "Windows ABI assertion")
    def test_bluetooth_radio_info_matches_x64_windows_sdk_layout(self):
        self.assertEqual(ctypes.sizeof(_BLUETOOTH_ADDRESS), 8)
        self.assertEqual(ctypes.sizeof(_BLUETOOTH_RADIO_INFO), 520)
        self.assertEqual(ctypes.sizeof(_OVERLAPPED), 32)
        self.assertEqual(_OVERLAPPED.hEvent.offset, 24)

    def test_decodes_ready_driver_status(self):
        data = struct.pack("<IIQ", (5 << 16) | 0x03, 0, 0x0123456789AB)
        self.assertEqual(_decode_status(data), (0x03, "01:23:45:67:89:AB"))

    def test_reports_driver_initialization_stage_and_status(self):
        data = struct.pack("<IIQ", 2 << 16, 0xC000000D, 0)
        with self.assertRaisesRegex(
            OSError,
            r"device-specific HID PSM registration after pairing "
            r"\(stage 2, NTSTATUS 0xC000000D\)",
        ):
            _decode_status(data)

    def test_rejects_nonzero_informational_initialization_status(self):
        data = struct.pack("<IIQ", (5 << 16) | 0x03, 0x00000001, 0x0123456789AB)
        with self.assertRaisesRegex(
            OSError,
            r"ready-state validation \(stage 5, NTSTATUS 0x00000001\)",
        ):
            _decode_status(data)

    def test_wait_connected_translates_cancelled_status_io(self):
        transport = WindowsBluetoothTransport()
        cancelled = threading.Event()

        def cancelled_status():
            cancelled.set()
            error = OSError("The I/O operation has been aborted.")
            error.winerror = ERROR_OPERATION_ABORTED
            raise error

        transport.status = cancelled_status
        with self.assertRaises(ConnectionAbortedError) as raised:
            transport.wait_connected(timeout=1, cancel_event=cancelled)
        self.assertEqual(raised.exception.__cause__.winerror, ERROR_OPERATION_ABORTED)

    def test_wait_connected_prefers_cancel_over_a_racing_ready_status(self):
        transport = WindowsBluetoothTransport()
        cancelled = threading.Event()

        def ready_after_cancel():
            cancelled.set()
            return 0x03, "01:23:45:67:89:AB"

        transport.status = ready_after_cancel
        with self.assertRaises(ConnectionAbortedError):
            transport.wait_connected(timeout=1, cancel_event=cancelled)

    def test_rejects_incomplete_or_not_ready_status(self):
        with self.assertRaisesRegex(OSError, r"truncated status record"):
            _decode_status(bytes(15))
        with self.assertRaisesRegex(OSError, r"not ready.*stage 4"):
            _decode_status(struct.pack("<IIQ", 4 << 16, 0, 0x0123456789AB))
        with self.assertRaisesRegex(OSError, r"not ready.*local address 0x000000000000"):
            _decode_status(struct.pack("<IIQ", 5 << 16, 0, 0))


class TransportOverlappedTests(unittest.TestCase):
    class FakeKernel32:
        def __init__(self):
            self.created_event = 0x2222
            self.closed_handles = []
            self.overlapped_results = []
            self.create_file_arguments = None
            self.cancelled_handles = []

        def CreateEventW(self, *_args):
            return self.created_event

        def CloseHandle(self, handle):
            self.closed_handles.append(handle)
            return True

        def GetOverlappedResult(self, handle, overlapped, transferred, wait):
            self.overlapped_results.append((handle, overlapped, wait))
            ctypes.cast(
                transferred, ctypes.POINTER(wintypes.DWORD)
            ).contents.value = 11
            return True

        def CreateFileW(self, *arguments):
            self.create_file_arguments = arguments
            return 0x1111

        def CancelIoEx(self, handle, _overlapped):
            self.cancelled_handles.append(handle)
            return True

    def test_open_requests_an_overlapped_device_handle(self):
        kernel32 = self.FakeKernel32()
        transport = WindowsBluetoothTransport()
        with patch(
            "splatplost.windows_bluetooth.transport.os.name", "nt"
        ), patch.object(
            ctypes, "WinDLL", return_value=kernel32, create=True
        ), patch.object(
            transport, "_configure_api"
        ), patch.object(
            transport,
            "status",
            return_value=(0, "01:23:45:67:89:AB"),
        ), patch.object(
            transport, "_enable_discovery"
        ):
            transport.open()
        try:
            self.assertEqual(
                kernel32.create_file_arguments[5],
                FILE_FLAG_OVERLAPPED,
            )
        finally:
            transport.close()

    def test_immediate_overlapped_completion_uses_reported_byte_count(self):
        kernel32 = self.FakeKernel32()
        transport = WindowsBluetoothTransport()
        transport._kernel32 = kernel32
        transport.handle = 0x1111

        def submit(handle, transferred, overlapped):
            self.assertEqual(handle, transport.handle)
            self.assertEqual(
                ctypes.cast(
                    overlapped, ctypes.POINTER(_OVERLAPPED)
                ).contents.hEvent,
                kernel32.created_event,
            )
            ctypes.cast(
                transferred, ctypes.POINTER(wintypes.DWORD)
            ).contents.value = 7
            return True

        self.assertEqual(transport._overlapped_io(submit), 7)
        self.assertEqual(kernel32.overlapped_results, [])
        self.assertEqual(kernel32.closed_handles, [kernel32.created_event])

    def test_pending_overlapped_completion_waits_for_its_event(self):
        kernel32 = self.FakeKernel32()
        transport = WindowsBluetoothTransport()
        transport._kernel32 = kernel32
        transport.handle = 0x1111

        with patch.object(
            ctypes,
            "get_last_error",
            return_value=ERROR_IO_PENDING,
            create=True,
        ):
            transferred = transport._overlapped_io(
                lambda _handle, _transferred, _overlapped: False
            )

        self.assertEqual(transferred, 11)
        self.assertEqual(len(kernel32.overlapped_results), 1)
        self.assertTrue(kernel32.overlapped_results[0][2])
        self.assertEqual(kernel32.closed_handles, [kernel32.created_event])

    @unittest.skipUnless(os.name == "nt", "Windows cancellation error assertion")
    def test_close_cancels_pending_io_before_closing_the_device(self):
        class BlockingKernel32(self.FakeKernel32):
            def __init__(self):
                super().__init__()
                self.pending = threading.Event()
                self.cancelled = threading.Event()
                self.call_order = []

            def ReadFile(
                self,
                _handle,
                _buffer,
                _size,
                _transferred,
                _overlapped,
            ):
                self.pending.set()
                return False

            def GetOverlappedResult(
                self,
                _handle,
                _overlapped,
                transferred,
                _wait,
            ):
                if not self.cancelled.wait(1):
                    raise TimeoutError("CancelIoEx was not called")
                ctypes.cast(
                    transferred, ctypes.POINTER(wintypes.DWORD)
                ).contents.value = 0
                return False

            def CancelIoEx(self, handle, _overlapped):
                self.call_order.append(("cancel", handle))
                self.cancelled.set()
                return True

            def CloseHandle(self, handle):
                self.call_order.append(("close", handle))
                return super().CloseHandle(handle)

        kernel32 = BlockingKernel32()
        transport = WindowsBluetoothTransport()
        transport._kernel32 = kernel32
        transport.handle = 0x1111
        errors = []

        def read_pending():
            try:
                transport.read()
            except Exception as error:
                errors.append(error)

        reader = threading.Thread(target=read_pending)
        with patch.object(
            ctypes,
            "get_last_error",
            side_effect=lambda: (
                ERROR_OPERATION_ABORTED
                if kernel32.cancelled.is_set()
                else ERROR_IO_PENDING
            ),
            create=True,
        ):
            reader.start()
            self.assertTrue(kernel32.pending.wait(0.5))
            transport.close()
            reader.join(1)

        self.assertFalse(reader.is_alive())
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0].winerror, ERROR_OPERATION_ABORTED)
        self.assertEqual(
            kernel32.call_order,
            [
                ("cancel", 0x1111),
                ("close", kernel32.created_event),
                ("close", 0x1111),
            ],
        )


class FakeTransport:
    def __init__(self, report_delay=0.0):
        self.opened = False
        self.closed = False
        self.writes = []
        self.report_delay = report_delay
        self._reports = [
            switch_subcommand(0x02),
            switch_subcommand(0x48, b"\x01"),
            switch_subcommand(0x30, b"\x01"),
        ]
        self._lock = threading.Lock()

    def open(self):
        self.opened = True

    def wait_connected(self, timeout, cancel_event=None):
        if cancel_event is not None and cancel_event.is_set():
            raise ConnectionAbortedError("cancelled")
        return "01:23:45:67:89:AB"

    def read(self, size=64):
        with self._lock:
            if self._reports:
                if self.report_delay:
                    time.sleep(self.report_delay)
                return self._reports.pop(0)
        if self.closed:
            raise OSError("closed")
        time.sleep(0.002)
        return b""

    def write(self, data):
        self.writes.append(data)

    def close(self):
        self.closed = True


class BackendTests(unittest.TestCase):
    def test_backend_connects_and_generates_reports(self):
        transport = FakeTransport()
        backend = WindowsBluetoothControl(
            transport=transport,
            pairing_timeout=0.1,
            handshake_timeout=0.5,
        )
        backend.connect()
        self.assertTrue(transport.opened)
        self.assertTrue(backend.protocol.handshake_complete)
        self.assertTrue(transport.writes)
        backend.disconnect()
        self.assertTrue(transport.closed)

    def test_backend_suppresses_unchanged_reports_after_handshake(self):
        backend = WindowsBluetoothControl(transport=FakeTransport())
        protocol = SwitchProtocol("01:23:45:67:89:AB")
        protocol.device_info_queried = True
        protocol.vibration_enabled = True
        protocol.player_number = 1
        backend.protocol = protocol

        report = protocol.next_input_report()
        self.assertTrue(backend._should_write_report(report))
        backend._cached_report_payload = report[3:]
        backend._ticks_since_write = 0
        self.assertFalse(backend._should_write_report(protocol.next_input_report()))

        backend._ticks_since_write = backend.KEEPALIVE_TICKS
        self.assertTrue(backend._should_write_report(protocol.next_input_report()))

        backend._ticks_since_write = 0
        protocol.set_buttons(Button.A)
        self.assertTrue(backend._should_write_report(protocol.next_input_report()))

        repeated_reply = bytearray(report)
        repeated_reply[1] = 0x21
        backend._cached_report_payload = bytes(repeated_reply[3:])
        self.assertTrue(backend._should_write_report(bytes(repeated_reply)))

    def test_subcommand_wakes_pre_handshake_writer_immediately(self):
        transport = FakeTransport(report_delay=0.05)
        backend = WindowsBluetoothControl(
            transport=transport,
            pairing_timeout=0.1,
            # Without the report-ready wakeup, the writer sleeps for one
            # second after its initial pre-handshake report and this expires.
            handshake_timeout=0.4,
        )
        started = time.monotonic()
        backend.connect()
        elapsed = time.monotonic() - started
        try:
            self.assertLess(elapsed, 0.4)
            replies = [report for report in transport.writes if report[1] == 0x21]
            self.assertGreaterEqual(len(replies), 3)
        finally:
            backend.disconnect()

    def test_connect_waits_until_the_final_handshake_ack_is_written(self):
        class GatedTransport(FakeTransport):
            def __init__(self):
                super().__init__()
                self.final_ack_started = threading.Event()
                self.release_final_ack = threading.Event()

            def write(self, data):
                if len(data) > 15 and data[1] == 0x21 and data[15] == 0x30:
                    self.final_ack_started.set()
                    if not self.release_final_ack.wait(1):
                        raise TimeoutError("test did not release final ACK")
                super().write(data)

        transport = GatedTransport()
        backend = WindowsBluetoothControl(
            transport=transport,
            pairing_timeout=0.1,
            handshake_timeout=1,
        )
        errors = []
        connect_thread = threading.Thread(
            target=lambda: self._capture_thread_error(backend.connect, errors)
        )
        connect_thread.start()
        self.assertTrue(transport.final_ack_started.wait(0.5))
        self.assertTrue(connect_thread.is_alive())
        transport.release_final_ack.set()
        connect_thread.join(1)
        try:
            self.assertFalse(connect_thread.is_alive())
            self.assertEqual(errors, [])
            acknowledgement_order = [
                report[15]
                for report in transport.writes
                if len(report) > 15 and report[1] == 0x21
            ]
            self.assertEqual(acknowledgement_order, [0x02, 0x48, 0x30])
        finally:
            backend.disconnect()

    def test_ensure_connected_preserves_the_worker_io_error(self):
        backend = WindowsBluetoothControl(transport=FakeTransport())
        backend.protocol = SwitchProtocol("01:23:45:67:89:AB")
        backend._error = OSError("driver read failed")
        backend._running.clear()
        with self.assertRaisesRegex(OSError, "driver read failed"):
            backend._ensure_connected()

    def test_disconnect_cancels_pairing_before_a_switch_connects(self):
        class WaitingTransport(FakeTransport):
            def __init__(self):
                super().__init__()
                self.wait_started = threading.Event()

            def wait_connected(self, timeout, cancel_event=None):
                self.wait_started.set()
                self.assert_cancel_event = cancel_event
                while not cancel_event.wait(0.01):
                    pass
                raise ConnectionAbortedError("cancelled")

        transport = WaitingTransport()
        backend = WindowsBluetoothControl(transport=transport, pairing_timeout=10)
        errors = []
        connect_thread = threading.Thread(
            target=lambda: self._capture_thread_error(backend.connect, errors)
        )
        connect_thread.start()
        self.assertTrue(transport.wait_started.wait(0.5))
        backend.disconnect()
        connect_thread.join(1)
        self.assertFalse(connect_thread.is_alive())
        self.assertTrue(transport.closed)
        self.assertEqual(len(errors), 1)
        self.assertIsInstance(errors[0], ConnectionAbortedError)

    def test_disconnect_normalizes_cancelled_status_io(self):
        class CancelledIoTransport(FakeTransport):
            def __init__(self):
                super().__init__()
                self.wait_started = threading.Event()

            def wait_connected(self, timeout, cancel_event=None):
                self.wait_started.set()
                if not cancel_event.wait(1):
                    raise TimeoutError("test cancellation was not requested")
                error = OSError("The I/O operation has been aborted.")
                error.winerror = ERROR_OPERATION_ABORTED
                raise error

        transport = CancelledIoTransport()
        backend = WindowsBluetoothControl(transport=transport, pairing_timeout=10)
        errors = []
        connect_thread = threading.Thread(
            target=lambda: self._capture_thread_error(backend.connect, errors)
        )
        connect_thread.start()
        self.assertTrue(transport.wait_started.wait(0.5))
        backend.disconnect()
        connect_thread.join(1)
        self.assertFalse(connect_thread.is_alive())
        self.assertEqual(len(errors), 1)
        self.assertIsInstance(errors[0], ConnectionAbortedError)
        self.assertEqual(errors[0].__cause__.winerror, ERROR_OPERATION_ABORTED)

    @staticmethod
    def _capture_thread_error(action, errors):
        try:
            action()
        except Exception as error:
            errors.append(error)


class ApplicationAcceptanceTests(unittest.TestCase):
    class FakeProtocol:
        bluetooth_address = "01:23:45:67:89:AB"
        player_number = 1
        device_info_queried = True
        vibration_enabled = True

    class FakeBackend:
        def __init__(self, *, connect_error=None, channel_mask=0x03, **_kwargs):
            self.connect_error = connect_error
            self.channel_mask = channel_mask
            self.protocol = None
            self.transport = self
            self.connected = False
            self.disconnected = False

        def connect(self):
            if self.connect_error:
                raise self.connect_error
            self.connected = True
            self.protocol = ApplicationAcceptanceTests.FakeProtocol()

        def _ensure_connected(self):
            if not self.connected:
                raise ConnectionError("not connected")

        def disconnect(self):
            self.connected = False
            self.disconnected = True

        def status(self):
            return self.channel_mask, "01:23:45:67:89:AB"

    @staticmethod
    @contextmanager
    def _packaged_application(temporary):
        executable = Path(temporary, "splatplost-test.exe")
        payload = b"packaged-splatplost-test-executable"
        executable.write_bytes(payload)
        with patch.object(
            acceptance_module.sys,
            "frozen",
            True,
            create=True,
        ), patch.object(
            acceptance_module.sys,
            "executable",
            str(executable),
        ):
            yield executable, hashlib.sha256(payload).hexdigest()

    def test_application_acceptance_persists_a_successful_handshake(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "application-evidence.json")
            backend = self.FakeBackend()
            with self._packaged_application(temporary) as (executable, sha256):
                result = verify_windows_bluetooth_application(
                    path,
                    settle_seconds=0,
                    backend_factory=lambda **_kwargs: backend,
                )
            persisted = json.loads(path.read_text(encoding="utf-8"))
            self.assertTrue(result["passed"])
            self.assertTrue(persisted["passed"])
            self.assertTrue(persisted["checks"]["packagedExecutable"])
            self.assertTrue(persisted["application"]["frozenExecutable"])
            self.assertEqual(
                persisted["application"]["executableName"], executable.name
            )
            self.assertEqual(persisted["application"]["executableSha256"], sha256)
            self.assertEqual(
                persisted["localControllerBluetoothAddress"],
                "01:23:45:67:89:AB",
            )
            self.assertTrue(all(persisted["checks"].values()))
            self.assertEqual(persisted["finalDriverChannelMask"], 0x03)
            self.assertEqual(persisted["evidencePath"], str(path.resolve()))
            self.assertTrue(backend.disconnected)

    def test_application_acceptance_records_connection_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "application-evidence.json")
            backend = self.FakeBackend(connect_error=OSError("bridge unavailable"))
            with self._packaged_application(temporary):
                result = verify_windows_bluetooth_application(
                    path,
                    settle_seconds=0,
                    backend_factory=lambda **_kwargs: backend,
                )
            persisted = json.loads(path.read_text(encoding="utf-8"))
            self.assertFalse(result["passed"])
            self.assertEqual(persisted["failureType"], "OSError")
            self.assertIn("bridge unavailable", persisted["failure"])
            self.assertTrue(backend.disconnected)

    def test_application_acceptance_rejects_a_dropped_driver_channel(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "application-evidence.json")
            backend = self.FakeBackend(channel_mask=0x01)
            with self._packaged_application(temporary):
                result = verify_windows_bluetooth_application(
                    path,
                    settle_seconds=0,
                    backend_factory=lambda **_kwargs: backend,
                )
            persisted = json.loads(path.read_text(encoding="utf-8"))
            self.assertFalse(result["passed"])
            self.assertEqual(persisted["finalDriverChannelMask"], 0x01)
            self.assertFalse(persisted["checks"]["connectionStayedAlive"])
            self.assertIn("Both Windows Bluetooth HID channels", persisted["failure"])

    def test_application_acceptance_records_backend_construction_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "application-evidence.json")

            def fail_to_construct(**_kwargs):
                raise RuntimeError("backend construction failed")

            with self._packaged_application(temporary):
                result = verify_windows_bluetooth_application(
                    path,
                    settle_seconds=0,
                    backend_factory=fail_to_construct,
                )
            persisted = json.loads(path.read_text(encoding="utf-8"))
            self.assertFalse(result["passed"])
            self.assertEqual(persisted["failureType"], "RuntimeError")
            self.assertIn("construction failed", persisted["failure"])

    def test_application_acceptance_rejects_a_source_python_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "application-evidence.json")
            backend_constructed = False

            def construct_backend(**_kwargs):
                nonlocal backend_constructed
                backend_constructed = True
                return self.FakeBackend()

            with patch.object(
                acceptance_module.sys,
                "frozen",
                False,
                create=True,
            ):
                result = verify_windows_bluetooth_application(
                    path,
                    settle_seconds=0,
                    backend_factory=construct_backend,
                )
            persisted = json.loads(path.read_text(encoding="utf-8"))
            self.assertFalse(result["passed"])
            self.assertFalse(backend_constructed)
            self.assertFalse(persisted["checks"]["packagedExecutable"])
            self.assertIsNone(persisted["application"]["executableSha256"])
            self.assertEqual(persisted["failureType"], "RuntimeError")
            self.assertIn("packaged splatplost.exe", persisted["failure"])

    def test_application_acceptance_rejects_a_non_file_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "application-evidence.json")
            with patch.object(
                acceptance_module.sys,
                "frozen",
                True,
                create=True,
            ), patch.object(
                acceptance_module.sys,
                "executable",
                temporary,
            ):
                result = verify_windows_bluetooth_application(
                    path,
                    settle_seconds=0,
                    backend_factory=lambda **_kwargs: self.FakeBackend(),
                )
            persisted = json.loads(path.read_text(encoding="utf-8"))
            self.assertFalse(result["passed"])
            self.assertFalse(persisted["checks"]["packagedExecutable"])
            self.assertEqual(persisted["failureType"], "FileNotFoundError")
            self.assertIn("not a regular file", persisted["failure"])

    def test_application_acceptance_refuses_to_overwrite_unrelated_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "unrelated.json")
            original = '{"important": true}\n'
            path.write_text(original, encoding="utf-8")
            with self.assertRaisesRegex(FileExistsError, "Refusing to overwrite"):
                verify_windows_bluetooth_application(
                    path,
                    settle_seconds=0,
                    backend_factory=lambda **_kwargs: self.FakeBackend(),
                )
            self.assertEqual(path.read_text(encoding="utf-8"), original)


if __name__ == "__main__":
    unittest.main()
