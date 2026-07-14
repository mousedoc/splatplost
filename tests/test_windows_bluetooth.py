import threading
import time
import unittest
import struct

from libnxctrl.wrapper import Button

from splatplost.windows_bluetooth.backend import WindowsBluetoothControl
from splatplost.windows_bluetooth.protocol import SwitchProtocol
from splatplost.windows_bluetooth.transport import _decode_status


def switch_subcommand(command: int, payload: bytes = b"") -> bytes:
    report = bytearray(12 + len(payload))
    report[0] = 0xA2
    report[11] = command
    report[12:] = payload
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


class TransportStatusTests(unittest.TestCase):
    def test_decodes_ready_driver_status(self):
        data = struct.pack("<IIQ", (5 << 16) | 0x03, 0, 0x0123456789AB)
        self.assertEqual(_decode_status(data), (0x03, "01:23:45:67:89:AB"))

    def test_reports_driver_initialization_stage_and_status(self):
        data = struct.pack("<IIQ", 2 << 16, 0xC000000D, 0)
        with self.assertRaisesRegex(
            OSError,
            r"HID PSM registration \(stage 2, NTSTATUS 0xC000000D\)",
        ):
            _decode_status(data)


class FakeTransport:
    def __init__(self):
        self.opened = False
        self.closed = False
        self.writes = []
        self._reports = [
            switch_subcommand(0x02),
            switch_subcommand(0x48, b"\x01"),
            switch_subcommand(0x30, b"\x01"),
        ]
        self._lock = threading.Lock()

    def open(self):
        self.opened = True

    def wait_connected(self, timeout):
        return "01:23:45:67:89:AB"

    def read(self, size=64):
        with self._lock:
            if self._reports:
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


if __name__ == "__main__":
    unittest.main()
