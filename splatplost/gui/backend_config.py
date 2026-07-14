from urllib.parse import urlsplit

from PyQt6 import uic

from splatplost.gui.bundler import ui_path

Form_nxbt, _ = uic.loadUiType(ui_path("nxbt.ui"))

Form_SUSB, _ = uic.loadUiType(ui_path("splatplost_USB.ui"))

Form_Remote, _ = uic.loadUiType(ui_path("remote.ui"))


def normalize_remote_server_address(address: str) -> str:
    """Return an XML-RPC URL accepted by ``xmlrpc.client.ServerProxy``."""
    address = address.strip()
    if not address:
        raise ValueError(
                "Enter the address of a running libnxctrl remote server. "
                "Remote does not connect directly to the Switch IP address."
                )

    if "://" not in address:
        address = f"http://{address}"

    parsed = urlsplit(address)
    if parsed.scheme.lower() not in {"http", "https"}:
        raise ValueError("Remote server address must use http:// or https://.")
    if not parsed.hostname:
        raise ValueError("Enter a valid remote server host name or IP address.")

    try:
        parsed.port
    except ValueError as error:
        raise ValueError("Enter a valid remote server port number.") from error

    return address


class NxbtConfigWidget(Form_nxbt):
    def get_connection_args(self):
        return {
            "press_duration_ms": int(self.press_ms.value()),
            "delay_ms":          int(self.delay_ms.value()),
            }


# noinspection PyPep8Naming
class SplatplostUSBConfigWidget(Form_SUSB):
    def setupUi(self, config_widget):
        super().setupUi(config_widget)
        # Get available serial ports
        from serial.tools.list_ports import comports
        for port in comports():
            self.serial_port.addItem(port.device)

    def get_connection_args(self):
        serial_port = self.serial_port.currentText().strip()
        if not serial_port:
            raise ValueError(
                    "No compatible serial port was found. Connect a Splatplost USB device and try again."
                    )
        return {
            "serial_port":       serial_port,
            "press_duration_ms": int(self.press_ms.value()),
            }


class RemoteConfigWidget(Form_Remote):
    def get_connection_args(self):
        return {
            "conn_str":          normalize_remote_server_address(self.server_addr.text()),
            "press_duration_ms": int(self.press_ms.value()),
            "delay_ms":          int(self.delay_ms.value()),
            }
