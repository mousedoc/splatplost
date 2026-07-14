"""libnxctrl-compatible native Windows Bluetooth backend."""

from __future__ import annotations

import threading
import time

from libnxctrl.wrapper import Button, NXWrapper

from .protocol import SwitchProtocol
from .transport import WindowsBluetoothTransport


class WindowsBluetoothControl(NXWrapper):
    support_combo = True

    def __init__(
            self,
            press_duration_ms: int = 50,
            delay_ms: int = 80,
            transport=None,
            pairing_timeout: float = 180.0,
            handshake_timeout: float = 60.0,
            ):
        super().__init__(press_duration_ms, delay_ms)
        self.transport = transport or WindowsBluetoothTransport()
        self.pairing_timeout = pairing_timeout
        self.handshake_timeout = handshake_timeout
        self.protocol = None
        self._running = threading.Event()
        self._error = None
        self._reader = None
        self._writer = None

    def connect(self):
        self._error = None
        self.transport.open()
        try:
            address = self.transport.wait_connected(self.pairing_timeout)
            self.protocol = SwitchProtocol(address)
            self._running.set()
            self._reader = threading.Thread(target=self._reader_loop, daemon=True)
            self._writer = threading.Thread(target=self._writer_loop, daemon=True)
            self._reader.start()
            self._writer.start()

            deadline = time.monotonic() + self.handshake_timeout
            while time.monotonic() < deadline:
                if self._error is not None:
                    raise self._error
                if self.protocol.handshake_complete:
                    return
                time.sleep(0.05)
            raise TimeoutError("Switch connected, but the controller handshake did not finish.")
        except Exception:
            self.disconnect()
            raise

    def button_hold(self, button_name: Button, duration_ms: int):
        self._ensure_connected()
        self.protocol.set_buttons(button_name)
        time.sleep(max(duration_ms, 1) / 1000)
        self.protocol.set_buttons(Button(0))
        time.sleep(max(self.delay_ms, 0) / 1000)

    def disconnect(self):
        self._running.clear()
        if self.protocol is not None:
            self.protocol.set_buttons(Button(0))
        self.transport.close()
        current = threading.current_thread()
        for thread in (self._reader, self._writer):
            if thread is not None and thread is not current:
                thread.join(timeout=1)
        self._reader = None
        self._writer = None
        self.protocol = None

    def _ensure_connected(self):
        if not self._running.is_set() or self.protocol is None:
            raise ConnectionError("The native Windows Bluetooth controller is not connected.")
        if self._error is not None:
            raise self._error

    def _reader_loop(self):
        try:
            while self._running.is_set():
                data = self.transport.read()
                if data:
                    self.protocol.process_switch_report(data)
        except Exception as error:
            if self._running.is_set():
                self._error = error
                self._running.clear()

    def _writer_loop(self):
        try:
            while self._running.is_set():
                started = time.perf_counter()
                self.transport.write(self.protocol.next_input_report())
                if self.protocol.handshake_complete:
                    tick = 1 / 132
                elif self.protocol.device_info_queried:
                    tick = 1 / 15
                else:
                    tick = 1.0
                remaining = tick - (time.perf_counter() - started)
                if remaining > 0:
                    time.sleep(remaining)
        except Exception as error:
            if self._running.is_set():
                self._error = error
                self._running.clear()
