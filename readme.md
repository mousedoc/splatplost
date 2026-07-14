# Splatplost

[中文](readme.zh-CN.md)

Splatplost is a Splatpost plotter based on [libnxctrl](https://github.com/Victrid/libnxctrl). It can drive a controller through Linux Bluetooth, a compatible USB serial adapter on Windows or Linux, or a remote Linux backend. Its optimized plotting algorithm can reduce printing time by up to one third.

## Basic Usage

### Installation

Splatplost supports Windows and Linux. Image planning works on both platforms. Controller output is available through:

- **Windows:** a Splatplost-compatible USB serial adapter, or a remote `libnxctrl` server running on Linux.
- **Linux:** the Bluetooth `nxbt` backend, USB serial adapter, or a remote server.

Windows cannot use the BlueZ-only `nxbt` backend directly. The USB backend requires compatible controller-emulation hardware connected as a Windows COM port; an ordinary USB cable is not enough.

#### Windows executable

Download the `splatplost-windows-x64` artifact from a GitHub Actions run and extract it. Double-click `splatplost.exe` to start the GUI; no Python installation is needed. Choose an image in the GUI, generate its route, select the USB or Remote backend, and connect to the Switch.

#### Install from source on Windows

Python 3.9 or newer is required.

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install .
```

#### Linux Bluetooth installation

You need to use `sudo`, or root, as altering bluetooth is a privileged operation.

```bash
sudo python3 -m pip install ".[bluetooth]"
```

This will automatically install the required dependencies.

If you need to update the library, you can use `pip install --upgrade splatplost`.

### Use

Start the GUI:

```bash
sudo splatplost
```

In the GUI, select a 320 x 120 image and click **Load** to generate the route. Choose the Splatoon version and controller backend, then click **Connect to Switch** and follow the pairing dialog. Select the image blocks you want to process and use **Draw selected** or **Erase selected**.

## Help needed / I found a bug / Feature request

Click the "Issues" link above to open an issue on the repository.

If you find bugs on connection, please open issues to [libnxctrl](https://github.com/Victrid/libnxctrl).

## Contributing



## License

This project is based on libnxctrl, so it is released under GPLv3.

