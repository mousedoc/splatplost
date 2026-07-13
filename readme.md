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

Download the `splatplost-windows-x64` artifact from a GitHub Actions run and extract it. No Python installation is needed.

Generate a plotting plan:

```powershell
.\splatplan.exe -i .\image.png -o .\order.txt
```

List serial ports and print through a USB adapter:

```powershell
.\splatplot.exe --list-ports
.\splatplot.exe --backend usb --serial-port COM3 --order .\order.txt
```

Alternatively, connect to a Linux machine running the `libnxctrl` server:

```powershell
.\splatplot.exe --backend remote --remote-server http://192.168.1.10:15973 --order .\order.txt
```

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

Generate a plotting plan with:

```bash
splatplan -i <your image> -o <output filename>
```

Start the printer:

```bash
sudo splatplot --backend nxbt --order <output filename>
```

You may check the printer's option (for example, stable mode, customizing delay and press time, etc.) with:

```bash
sudo splatplot --help
```

When "Open the pairing menu on switch." shows on the screen, go to the pairing menu, and the switch will be paired.

Then you may enter the game and enter splatpost interface using your own controller. Remember to set the brush to minimum one.

When everything is prepaired, disconnect your own controller, (for example, press the tiny pairing button on the top of the controller), and you'll enter the "connect to controller" menu.

Press enter or "A" button on your computer as instructed, the plotting will begin. You may see the progress and ETA time while printing.

## Help needed / I found a bug / Feature request

Click the "Issues" link above to open an issue on the repository.

If you find bugs on connection, please open issues to [libnxctrl](https://github.com/Victrid/libnxctrl).

## Contributing



## License

This project is based on libnxctrl, so it is released under GPLv3.

