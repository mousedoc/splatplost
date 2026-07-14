# Splatplost

[한국어](.github/readme_kr.md) · [简体中文](readme.zh-CN.md)

Splatplost is a GUI application that converts a 320 × 120 image into controller input for drawing a Splatoon post. It is built on [libnxctrl](https://github.com/Victrid/libnxctrl) and provides an optimized route generator, block-based drawing controls, and multiple controller backends.

This repository contains the PyQt6 GUI and a Windows x64 port. The Windows build does not require a local Python installation.

## Features

- Native PyQt6 desktop GUI
- Splatoon 2 and Splatoon 3 input mappings
- PNG and JPEG input at the required 320 × 120 resolution
- Optimized drawing-route generation
- Selectable image blocks for partial drawing or erasing
- Optional canvas clearing, calibration control, and stable mode
- Native Windows Bluetooth controller emulation without a VM or external controller board
- Windows support through Splatplost USB and Remote backends
- Linux Bluetooth support through the optional `nxbt` backend
- Automated Windows builds and GitHub Releases for pushed tags

## Download for Windows

1. Open the [Releases page](https://github.com/mousedoc/splatplost/releases).
2. Download `splatplost-windows-x64.zip` from the latest release.
3. Extract the ZIP into a new folder.
4. Double-click `splatplost.exe`.

The release ZIP contains the application plus the native Bluetooth driver package:

```text
splatplost.exe
SplatplostBluetooth.sys
SplatplostBluetooth.inf
SplatplostBluetooth.cat
SplatplostBluetoothService.exe
SplatplostDevelopment.cer
install-driver.ps1
install-driver.cmd
uninstall-driver.ps1
uninstall-driver.cmd
THIRD_PARTY_NOTICES.md
readme.md
LICENSE
```

The current GUI build does not contain `splatplan.exe` or `splatplot.exe`. Those filenames belong to the old command-line version. If you see an `--order is required` error, you are running an old CLI artifact instead of the current GUI release.

The executable is not code-signed, so Windows may display a publisher or SmartScreen warning. Only run files downloaded from this repository's Releases page.

## Using the GUI

1. Click **Select** and choose a PNG or JPEG image that is exactly 320 × 120 pixels.
2. Click **Load** to generate the drawing route. Black pixels are treated as the foreground to draw.
3. Left-click image blocks to select them or right-click to deselect them. **Select All** and **Deselect All** are also available.
4. Choose **Splatoon 2** or **Splatoon 3**.
5. Select a controller backend and click **Connect to Switch**.
6. Follow the pairing dialog, then use **Draw selected** or **Erase selected**.

Use **Load an Empty Image** when you only need erasing operations. The drawing options also provide canvas clearing, stepwise calibration, and stable-mode controls.

## Controller Backends

| Backend          | Windows | Linux | Notes                                                                                                                      |
| ---------------- | ------- | ----- | -------------------------------------------------------------------------------------------------------------------------- |
| Windows Bluetooth| Yes     | No    | Uses the PC Bluetooth radio directly. Requires the included profile driver and a restart after installation.               |
| Splatplost USB   | Yes     | Yes   | Requires a compatible USB serial controller-emulation device and its serial driver. A regular USB cable is not sufficient. |
| Remote           | Yes     | Yes   | Connects to a compatible remote `libnxctrl` server, typically running on Linux.                                            |
| `nxbt` Bluetooth | No      | Yes   | Linux-only because it depends on BlueZ. It may require elevated Bluetooth permissions.                                     |

Windows does not support the BlueZ-based `nxbt` backend directly. The `Windows Bluetooth` backend implements the same Switch controller protocol over the Windows Bluetooth driver stack.

### Native Windows Bluetooth setup

The Actions artifact currently contains a development-signed driver. Windows can load it only in test-signing mode, which also requires Secure Boot to be disabled. A normal Secure Boot installation requires the same driver package to be signed by Microsoft through Hardware Dev Center attestation or WHQL signing.

1. Extract the complete release ZIP.
2. Open PowerShell as Administrator in the extracted folder.
3. Open an Administrator PowerShell window and run `.\install-driver.cmd -EnableTestSigning`, restart Windows, then run `.\install-driver.cmd` once more. The CMD launcher bypasses PowerShell's script execution policy only for the installer process. It does not change the machine-wide execution policy.
4. Restart Windows after installation.
5. Open the Switch **Controllers > Change Grip/Order** screen.
6. Start Splatplost, select **Windows Bluetooth**, and click **Start Pairing**.

Installation temporarily changes the Windows Bluetooth Class of Device to Peripheral/Gamepad so the Switch can discover the PC as a controller. `uninstall-driver.ps1` disables the local profile and restores the values that were present before installation.

## Install from Source

Python 3.9 or newer is required. Python 3.12 is used by the Windows release workflow.

### Windows

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install .
splatplost
```

### Linux

Install the standard GUI and non-Bluetooth backends:

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install .
splatplost
```

To include the Linux-only Bluetooth backend:

```bash
python3 -m pip install ".[bluetooth]"
```

Bluetooth access may require additional BlueZ configuration or elevated permissions. Refer to the `libnxctrl`/`nxbt` setup for the Linux system you use.

## Development

Install the project in editable mode with build tools and run the test suite:

```powershell
py -m pip install -e ".[build]"
py -m unittest discover -s tests -v
```

The test suite covers Windows GUI initialization, backend loading, image conversion, connected-component labeling, and route-file generation.

### Publishing a Windows Release

The workflow in `.github/workflows/windows-build.yml` can be started manually or by pushing a tag. It:

1. installs the project on a Windows runner;
2. runs the test suite;
3. builds the windowed one-file `splatplost.exe`;
4. smoke-tests the packaged GUI;
5. builds and test-signs the native Windows Bluetooth profile driver;
6. uploads the Windows Actions artifact; and
7. publishes `splatplost-windows-x64.zip` to a GitHub Release for the tag.

Create and push a new tag after the workflow change is present on the target commit:

```powershell
git tag v0.3.0
git push origin v0.3.0
```

## Troubleshooting

- **A console appears and reports that `--order` is required:** you downloaded the old v0.1 CLI artifact. Download a current Release containing only `splatplost.exe`.
- **No COM port appears for Splatplost USB:** connect a compatible controller-emulation device and install its serial driver. A normal USB cable cannot provide this backend.
- **The Windows Bluetooth driver is not installed:** keep all release files together and run `install-driver.ps1` from an Administrator PowerShell window, then restart Windows.
- **Secure Boot blocks the development driver:** development certificates are intentionally not trusted by Secure Boot. Use a Microsoft-attestation-signed release package; disabling Secure Boot is only appropriate on a dedicated development machine.
- **Remote pairing reports an XML-RPC protocol error:** enter the address of a running `libnxctrl` remote server. Host names and IP addresses without a scheme are treated as `http://`; Remote does not connect directly to the Switch IP address.
- **`nxbt` is not listed on Windows:** this is expected. Select **Windows Bluetooth** for the native backend; Splatplost USB and Remote remain optional alternatives.
- **The image will not load:** resize or crop it to exactly 320 × 120 pixels and save it as PNG or JPEG.

## Issues and Contributing

Report application and Windows-port problems in this repository's [Issues](https://github.com/mousedoc/splatplost/issues). Controller backend or pairing problems may belong in the [libnxctrl issue tracker](https://github.com/Victrid/libnxctrl/issues).

Contributions are welcome. Install the development dependencies, run the tests, and include relevant test coverage with your pull request.

## Credits and License

Splatplost was originally created by [Victrid](https://github.com/Victrid/splatplost) and is based on [libnxctrl](https://github.com/Victrid/libnxctrl).

This project is distributed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
