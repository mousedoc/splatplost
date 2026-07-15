import os
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6 import QtWidgets

from splatplost.gui.backend_config import normalize_remote_server_address
from splatplost.gui.plotter import PlotterUI, available_backends


class GuiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def test_main_window_and_windows_backend_load(self):
        form = QtWidgets.QMainWindow()
        window = PlotterUI(self.app, form)
        window.setupUi(form)
        backends = [window.backend_selector.itemText(i) for i in range(window.backend_selector.count())]
        self.assertIn("Splatplost USB", backends)
        self.assertEqual(window.backend_selector.currentIndex(), -1)
        self.assertTrue(form.windowTitle())
        form.close()
        window.tempdir.cleanup()

    def test_native_bluetooth_is_available_on_windows(self):
        from unittest.mock import patch

        with patch("splatplost.gui.plotter.sys.platform", "win32"):
            self.assertEqual(available_backends()[0], "Windows Bluetooth")

    def test_shutdown_disconnects_active_and_pending_connections(self):
        class FakeConnection:
            def __init__(self):
                self.disconnect_count = 0

            def disconnect(self):
                self.disconnect_count += 1

        form = QtWidgets.QMainWindow()
        window = PlotterUI(self.app, form)
        window.setupUi(form)
        active = FakeConnection()
        pending = FakeConnection()
        window.connection = active
        window._pending_connection = pending

        window.shutdown()

        self.assertEqual(active.disconnect_count, 1)
        self.assertEqual(pending.disconnect_count, 1)
        self.assertIsNone(window.connection)
        self.assertIsNone(window._pending_connection)

    def test_rejecting_pairing_cancels_and_disconnects_unconfirmed_connection(self):
        import threading

        class FakeConnection:
            def __init__(self):
                self.disconnected = False

            def disconnect(self):
                self.disconnected = True

        form = QtWidgets.QMainWindow()
        window = PlotterUI(self.app, form)
        window.setupUi(form)
        connection = FakeConnection()
        cancel_event = threading.Event()
        window.connection = connection
        window._unconfirmed_connection = connection
        window._pairing_cancel_event = cancel_event

        window.cancel_pending_pairing()

        self.assertTrue(cancel_event.is_set())
        self.assertTrue(connection.disconnected)
        self.assertIsNone(window.connection)
        window.shutdown()

    def test_remote_server_address_adds_default_protocol(self):
        self.assertEqual(
                normalize_remote_server_address("192.168.1.10:8000"),
                "http://192.168.1.10:8000",
                )

    def test_remote_server_address_preserves_valid_url(self):
        self.assertEqual(
                normalize_remote_server_address(" https://controller.local:8443/RPC2 "),
                "https://controller.local:8443/RPC2",
                )

    def test_remote_server_address_rejects_missing_or_unsupported_url(self):
        for address in ("", "   ", "ftp://controller.local"):
            with self.subTest(address=address):
                with self.assertRaises(ValueError):
                    normalize_remote_server_address(address)


if __name__ == "__main__":
    unittest.main()
