"""libnxctrl-compatible native Windows Bluetooth backend."""

from __future__ import annotations

import threading
import time

from libnxctrl.wrapper import Button, NXWrapper

from .protocol import SwitchProtocol
from .transport import WindowsBluetoothTransport


class WindowsBluetoothControl(NXWrapper):
    support_combo = True
    KEEPALIVE_TICKS = 132

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
        self._cached_report_payload = None
        self._ticks_since_write = self.KEEPALIVE_TICKS
        self._report_ready = threading.Event()
        self._handshake_flushed = threading.Event()
        self._cancel_requested = threading.Event()

    def connect(self):
        if self._cancel_requested.is_set():
            raise ConnectionAbortedError("Windows Bluetooth pairing was cancelled.")
        self._error = None
        self._cached_report_payload = None
        self._ticks_since_write = self.KEEPALIVE_TICKS
        self._report_ready.clear()
        self._handshake_flushed.clear()
        try:
            self.transport.open()
            if self._cancel_requested.is_set():
                raise ConnectionAbortedError("Windows Bluetooth pairing was cancelled.")
            address = self.transport.wait_connected(
                self.pairing_timeout,
                cancel_event=self._cancel_requested,
            )
            self.protocol = SwitchProtocol(address)
            self._running.set()
            self._reader = threading.Thread(target=self._reader_loop, daemon=True)
            self._writer = threading.Thread(target=self._writer_loop, daemon=True)
            self._reader.start()
            self._writer.start()

            deadline = time.monotonic() + self.handshake_timeout
            while time.monotonic() < deadline:
                if self._cancel_requested.is_set():
                    raise ConnectionAbortedError(
                        "Windows Bluetooth pairing was cancelled."
                    )
                if self._error is not None:
                    raise self._error
                if (
                    self.protocol.handshake_complete
                    and self._handshake_flushed.is_set()
                ):
                    return
                time.sleep(0.05)
            raise TimeoutError("Switch connected, but the controller handshake did not finish.")
        except Exception as error:
            # disconnect() sets the cancellation event itself, so capture the
            # caller's state before cleanup. CancelIoEx can make an in-flight
            # open/status request surface ERROR_OPERATION_ABORTED; that is a
            # normal user cancellation, not a driver failure to show in the
            # GUI.
            was_cancelled = self._cancel_requested.is_set()
            self.disconnect()
            if was_cancelled and not isinstance(error, ConnectionAbortedError):
                raise ConnectionAbortedError(
                    "Windows Bluetooth pairing was cancelled."
                ) from error
            raise

    def button_hold(self, button_name: Button, duration_ms: int):
        self._ensure_connected()
        self.protocol.set_buttons(button_name)
        time.sleep(max(duration_ms, 1) / 1000)
        self.protocol.set_buttons(Button(0))
        time.sleep(max(self.delay_ms, 0) / 1000)

    def disconnect(self):
        self._cancel_requested.set()
        self._running.clear()
        self._report_ready.set()
        self._handshake_flushed.clear()
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
        if self._error is not None:
            raise self._error
        if not self._running.is_set() or self.protocol is None:
            raise ConnectionError("The native Windows Bluetooth controller is not connected.")

    def _reader_loop(self):
        try:
            while self._running.is_set():
                data = self.transport.read()
                if data:
                    self.protocol.process_switch_report(data)
                    # Wake the writer so a Switch subcommand is acknowledged
                    # immediately instead of waiting for the pre-handshake
                    # one-second idle interval to expire.
                    self._report_ready.set()
        except Exception as error:
            if self._running.is_set():
                self._error = error
                self._running.clear()

    def _writer_loop(self):
        try:
            while self._running.is_set():
                started = time.perf_counter()
                self._report_ready.clear()
                report = self.protocol.next_input_report()
                if self._should_write_report(report):
                    self.transport.write(report)
                    if (
                        self.protocol.handshake_complete
                        and not self.protocol.has_pending_replies
                    ):
                        # connect() must not report success merely because the
                        # final Switch handshake request was received. At least
                        # one successful write after the queue drained proves
                        # that its acknowledgement reached the driver.
                        self._handshake_flushed.set()
                    if self.protocol.handshake_complete:
                        self._cached_report_payload = report[3:]
                        self._ticks_since_write = 0
                if self.protocol.handshake_complete:
                    self._ticks_since_write += 1
                    tick = 1 / 132
                elif self.protocol.device_info_queried:
                    tick = 1 / 15
                else:
                    tick = 1.0
                remaining = tick - (time.perf_counter() - started)
                if remaining > 0:
                    self._report_ready.wait(remaining)
        except Exception as error:
            if self._running.is_set():
                self._error = error
                self._running.clear()

    def _should_write_report(self, report: bytes) -> bool:
        """Mirror NXBT's post-handshake report de-duplication policy."""
        if not self.protocol.handshake_complete:
            return True
        # A 0x21 report acknowledges a Switch subcommand. It must not be
        # suppressed even when the Switch repeats an identical request.
        if len(report) > 1 and report[1] == 0x21:
            return True
        return (
            report[3:] != self._cached_report_payload
            or self._ticks_since_write >= self.KEEPALIVE_TICKS
        )
