import unittest

from splatplost.plot import create_connection


class UsbStyleBackend:
    def __init__(self, serial_port, press_duration_ms=30):
        self.serial_port = serial_port
        self.press_duration_ms = press_duration_ms


class RemoteStyleBackend:
    def __init__(self, conn_str, press_duration_ms=50, delay_ms=120):
        self.conn_str = conn_str
        self.press_duration_ms = press_duration_ms
        self.delay_ms = delay_ms


class CreateConnectionTests(unittest.TestCase):
    def test_usb_backend_does_not_receive_unsupported_delay(self):
        connection = create_connection(
            UsbStyleBackend,
            press_duration_ms=80,
            delay_ms=90,
            backend_options={"serial_port": "COM7"},
        )
        self.assertEqual(connection.serial_port, "COM7")
        self.assertEqual(connection.press_duration_ms, 80)

    def test_remote_backend_receives_connection_and_timing(self):
        connection = create_connection(
            RemoteStyleBackend,
            press_duration_ms=80,
            delay_ms=90,
            backend_options={"conn_str": "http://127.0.0.1:15973"},
        )
        self.assertEqual(connection.conn_str, "http://127.0.0.1:15973")
        self.assertEqual(connection.press_duration_ms, 80)
        self.assertEqual(connection.delay_ms, 90)


if __name__ == "__main__":
    unittest.main()
