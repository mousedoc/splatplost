"""Nintendo Switch controller protocol used by the native Windows backend.

The packet layout follows the NXBT Pro Controller implementation, but is kept
independent from BlueZ so it can run on Windows.
"""

from __future__ import annotations

import random
import time
from collections import deque
from threading import RLock

from libnxctrl.wrapper import Button


class SwitchProtocol:
    REPORT_SIZE = 50

    _RIGHT_BUTTONS = {
        Button.Y: 0x01,
        Button.X: 0x02,
        Button.B: 0x04,
        Button.A: 0x08,
        Button.JCR_SR: 0x10,
        Button.JCR_SL: 0x20,
        Button.SHOULDER_R: 0x40,
        Button.SHOULDER_ZR: 0x80,
    }
    _SHARED_BUTTONS = {
        Button.MINUS: 0x01,
        Button.PLUS: 0x02,
        Button.R_STICK_PRESS: 0x04,
        Button.L_STICK_PRESS: 0x08,
        Button.HOME: 0x10,
        Button.CAPTURE: 0x20,
    }
    _LEFT_BUTTONS = {
        Button.DPAD_DOWN: 0x01,
        Button.DPAD_UP: 0x02,
        Button.DPAD_RIGHT: 0x04,
        Button.DPAD_LEFT: 0x08,
        Button.JCL_SR: 0x10,
        Button.JCL_SL: 0x20,
        Button.SHOULDER_L: 0x40,
        Button.SHOULDER_ZL: 0x80,
    }

    def __init__(self, bluetooth_address: str):
        self.bluetooth_address = bluetooth_address
        self.lock = RLock()
        self.buttons = Button(0)
        self.device_info_queried = False
        self.vibration_enabled = False
        self.player_number = None
        self.imu_enabled = False
        self.timer = 0
        self.timestamp = time.perf_counter()
        self.vibrator_report = random.choice((0xA0, 0xB0, 0xC0, 0x90))
        self._pending_replies: deque[bytes] = deque()

    @property
    def handshake_complete(self) -> bool:
        return self.vibration_enabled and self.player_number is not None

    @property
    def has_pending_replies(self) -> bool:
        with self.lock:
            return bool(self._pending_replies)

    def set_buttons(self, buttons: Button) -> None:
        with self.lock:
            self.buttons = buttons

    def process_switch_report(self, data: bytes) -> None:
        # A Switch output report is 50 bytes. Treat a short transfer as a
        # malformed report instead of acknowledging a partially received
        # subcommand with missing parameters.
        if len(data) < self.REPORT_SIZE or data[0] != 0xA2:
            return

        subcommand = data[11]
        payload = data[12:]
        with self.lock:
            if subcommand == 0x02:
                self.device_info_queried = True
                report = self._subcommand_reply(0x82, subcommand)
                report[16:20] = bytes((0x03, 0x8B, 0x03, 0x02))
                report[20:26] = self._address_bytes()
                report[26:28] = bytes((0x01, 0x01))
            elif subcommand == 0x08:
                report = self._subcommand_reply(0x80, subcommand)
            elif subcommand == 0x10:
                report = self._spi_reply(payload)
            elif subcommand == 0x03:
                report = self._subcommand_reply(0x80, subcommand)
            elif subcommand == 0x04:
                report = self._subcommand_reply(0x83, subcommand)
            elif subcommand == 0x40:
                self.imu_enabled = bool(payload and payload[0] == 0x01)
                report = self._subcommand_reply(0x80, subcommand)
            elif subcommand == 0x48:
                self.vibration_enabled = True
                report = self._subcommand_reply(0x82, subcommand)
            elif subcommand == 0x30:
                lights = payload[0] if payload else 0
                self.player_number = self._player_from_lights(lights)
                report = self._subcommand_reply(0x80, subcommand)
            elif subcommand == 0x22:
                report = self._subcommand_reply(0x80, subcommand)
            elif subcommand == 0x21:
                report = self._subcommand_reply(0xA0, subcommand)
                report[16:24] = bytes((0x01, 0x00, 0xFF, 0x00, 0x08, 0x00, 0x1B, 0x01))
                report[49] = 0xC8
            else:
                return
            self._pending_replies.append(bytes(report))

    def next_input_report(self) -> bytes:
        with self.lock:
            if self._pending_replies:
                return self._pending_replies.popleft()
            return bytes(self._standard_report())

    def _empty_report(self, report_id: int) -> bytearray:
        report = bytearray(self.REPORT_SIZE)
        report[0] = 0xA1
        report[1] = report_id
        return report

    def _standard_report(self) -> bytearray:
        report = self._empty_report(0x30)
        self._fill_standard_fields(report)
        if self.imu_enabled:
            report[14:50] = bytes((
                0x75, 0xFD, 0xFD, 0xFF, 0x09, 0x10, 0x21, 0x00, 0xD5, 0xFF, 0xE0, 0xFF,
                0x72, 0xFD, 0xF9, 0xFF, 0x0A, 0x10, 0x22, 0x00, 0xD5, 0xFF, 0xE0, 0xFF,
                0x76, 0xFD, 0xFC, 0xFF, 0x09, 0x10, 0x23, 0x00, 0xD5, 0xFF, 0xE0, 0xFF,
            ))
        return report

    def _subcommand_reply(self, acknowledgement: int, subcommand: int) -> bytearray:
        self.vibrator_report = random.choice((0xA0, 0xB0, 0xC0, 0x90))
        report = self._empty_report(0x21)
        self._fill_standard_fields(report)
        report[14] = acknowledgement
        report[15] = subcommand
        return report

    def _fill_standard_fields(self, report: bytearray) -> None:
        now = time.perf_counter()
        self.timer = (self.timer + int((now - self.timestamp) * 4000)) & 0xFF
        self.timestamp = now
        report[2] = self.timer
        if not self.device_info_queried:
            return
        report[3] = 0x90
        report[4] = self._button_byte(self._RIGHT_BUTTONS)
        report[5] = self._button_byte(self._SHARED_BUTTONS)
        report[6] = self._button_byte(self._LEFT_BUTTONS)
        report[7:10] = bytes((0x6F, 0xC8, 0x77))
        report[10:13] = bytes((0x16, 0xD8, 0x7D))
        report[13] = self.vibrator_report

    def _button_byte(self, mapping: dict[Button, int]) -> int:
        value = 0
        for button, mask in mapping.items():
            if self.buttons & button:
                value |= mask
        return value

    def _address_bytes(self) -> bytes:
        try:
            values = bytes(int(part, 16) for part in self.bluetooth_address.split(":"))
        except ValueError:
            values = b""
        return values if len(values) == 6 else bytes(6)

    @staticmethod
    def _player_from_lights(value: int) -> int | None:
        if value in (0x01, 0x10):
            return 1
        if value in (0x03, 0x30):
            return 2
        if value in (0x07, 0x70):
            return 3
        if value in (0x0F, 0xF0):
            return 4
        return None

    def _spi_reply(self, payload: bytes) -> bytearray:
        report = self._subcommand_reply(0x90, 0x10)
        payload = payload + bytes(max(0, 6 - len(payload)))
        address_low, address_high = payload[0], payload[1]
        read_length = min(payload[4], 29)
        report[16:20] = payload[:4]
        report[20] = read_length
        report[21:21 + read_length] = self._spi_data(address_high, address_low, read_length)
        return report

    @staticmethod
    def _spi_data(address_high: int, address_low: int, length: int) -> bytes:
        data = bytearray([0xFF] * length)
        if (address_high, address_low) == (0x60, 0x50):
            colours = bytes((0x82, 0x82, 0x82, 0x0F, 0x0F, 0x0F))
            data[:min(length, len(colours))] = colours[:length]
        elif (address_high, address_low) == (0x60, 0x3D):
            calibration = bytes((
                0xBA, 0xF5, 0x62, 0x6F, 0xC8, 0x77, 0xED, 0x95, 0x5B,
                0x16, 0xD8, 0x7D, 0xF2, 0xB5, 0x5F, 0x86, 0x65, 0x5E,
                0xFF, 0x82, 0x82, 0x82, 0x0F, 0x0F, 0x0F,
            ))
            data[:min(length, len(calibration))] = calibration[:length]
        elif (address_high, address_low) == (0x60, 0x80):
            factory_parameters = bytes((
                0x50, 0xFD, 0x00, 0x00, 0xC6, 0x0F, 0x0F, 0x30, 0x61,
                0x96, 0x30, 0xF3, 0xD4, 0x14, 0x54, 0x41, 0x15, 0x54,
                0xC7, 0x79, 0x9C, 0x33, 0x36, 0x63,
            ))
            data[:min(length, len(factory_parameters))] = factory_parameters[:length]
        elif (address_high, address_low) == (0x60, 0x98):
            stick_parameters = bytes((
                0x0F, 0x30, 0x61, 0x96, 0x30, 0xF3, 0xD4, 0x14, 0x54,
                0x41, 0x15, 0x54, 0xC7, 0x79, 0x9C, 0x33, 0x36, 0x63,
            ))
            data[:min(length, len(stick_parameters))] = stick_parameters[:length]
        elif (address_high, address_low) == (0x60, 0x20):
            sensor = bytes((
                0xD3, 0xFF, 0xD5, 0xFF, 0x55, 0x01, 0x00, 0x40, 0x00, 0x40, 0x00, 0x40,
                0x19, 0x00, 0xDD, 0xFF, 0xDC, 0xFF, 0x3B, 0x34, 0x3B, 0x34, 0x3B, 0x34,
            ))
            data[:min(length, len(sensor))] = sensor[:length]
        return bytes(data)
