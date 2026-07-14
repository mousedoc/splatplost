import os
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6 import QtWidgets

from splatplost.gui.plotter import PlotterUI


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
        self.assertTrue(form.windowTitle())
        form.close()
        window.tempdir.cleanup()


if __name__ == "__main__":
    unittest.main()
