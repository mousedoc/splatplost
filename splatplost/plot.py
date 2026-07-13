import inspect
from typing import Dict, Optional, Type, Union

import tqdm
from libnxctrl.wrapper import Button, NXWrapper


def reset(direction=None) -> list[tuple[Button, int]]:
    direction_map = {
        'up':    Button.DPAD_UP,
        'down':  Button.DPAD_DOWN,
        'left':  Button.DPAD_LEFT,
        'right': Button.DPAD_RIGHT,
        }
    if direction is None:
        direction = ['left', 'up']
    return [(direction_map[d], 8000) for d in direction]


def create_connection(backend: Type[NXWrapper], press_duration_ms: int, delay_ms: int,
                      backend_options: Optional[Dict] = None) -> NXWrapper:
    """Instantiate backends with their differing constructor signatures."""
    options = dict(backend_options or {})
    parameters = inspect.signature(backend).parameters
    if "press_duration_ms" in parameters:
        options["press_duration_ms"] = press_duration_ms
    if "delay_ms" in parameters:
        options["delay_ms"] = delay_ms
    return backend(**options)


def plot(order_list: list[str], backend: Type[NXWrapper], delay_ms: int = 100, press_duration_ms: int = 100,
         stable_mode: bool = False, backend_options: Optional[Dict] = None):
    connection = create_connection(backend, press_duration_ms, delay_ms, backend_options)
    connected = False
    try:
        print("Open the Change Grip/Order menu on the Switch.")
        connection.connect()
        connected = True

        t = "Placeholder"
        while t.strip() != "":
            t = input("Press <enter> to draw, or type anything and press <enter> to send A: ")
            if t.strip() == "":
                break
            connection.button_press(Button.A)

        # Goto (0,0) point and clear
        command_list: list[Union[Button, tuple[Button, int]]] = []

        reset_command = reset(['left', 'up'])

        if stable_mode:
            command_list += reset_command
            command_list.append(Button.MINUS)
        else:
            for button, press_time in reset_command:
                connection.button_hold(button, duration_ms=press_time)
            connection.button_press(Button.MINUS)

        for order in tqdm.tqdm(order_list) if not stable_mode else order_list:
            order = order.strip()
            reset_map = {
                'lu': lambda: reset(['left', 'up']),
                'ru': lambda: reset(['right', 'up']),
                'ld': lambda: reset(['left', 'down']),
                'rd': lambda: reset(['right', 'down']),
                }
            button_map = {
                "up":    Button.DPAD_UP,
                "down":  Button.DPAD_DOWN,
                "left":  Button.DPAD_LEFT,
                "right": Button.DPAD_RIGHT,
                "a":     Button.A,
                "b":     Button.B,
                "x":     Button.X,
                "y":     Button.Y,
                }
            if order in reset_map:
                reset_command = reset_map[order]()
                if stable_mode:
                    command_list += reset_command
                else:
                    for button, press_time in reset_command:
                        connection.button_hold(button, duration_ms=press_time)
            elif order in button_map:
                if stable_mode:
                    command_list.append(button_map[order])
                else:
                    connection.button_press(button_map[order])

        if stable_mode:
            connection.series_press(command_list)

    finally:
        if connected:
            connection.disconnect()
