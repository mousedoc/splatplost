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
