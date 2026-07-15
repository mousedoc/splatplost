# Splatplost

[한국어](.github/readme_kr.md) · [简体中文](readme.zh-CN.md)

Splatplost is a GUI application that converts a 320 × 120 image into controller input for drawing a Splatoon post. It is built on [libnxctrl](https://github.com/Victrid/libnxctrl) and provides an optimized route generator, block-based drawing controls, and multiple controller backends.

This repository contains the PyQt6 GUI and the Windows x64 port for Splatplost 0.3.1. The Windows build does not require a local Python installation.

## Features

- Native PyQt6 desktop GUI
- Splatoon 2 and Splatoon 3 input mappings
- PNG and JPEG input at the required 320 × 120 resolution
- Optimized drawing-route generation
- Selectable image blocks for partial drawing or erasing
- Optional canvas clearing, calibration control, and stable mode
- Experimental native Windows Bluetooth controller emulation without a VM or external controller board
- Windows support through Splatplost USB and Remote backends
- Linux Bluetooth support through the optional `nxbt` backend
- Automated Windows builds and GitHub Releases for pushed tags

## Download for Windows

1. Open the [Releases page](https://github.com/mousedoc/splatplost/releases).
2. Download `splatplost-windows-x64.zip` from the latest release.
3. Extract the ZIP into a new folder.
4. Double-click `splatplost.exe`.

If the Releases page is empty, no Windows binary has been published yet. Wait for a successful canonical `vX.Y.Z` tag build; an Actions development-driver artifact is not a substitute for a Microsoft-signed end-user driver.

The normal release ZIP contains the application:

```text
splatplost.exe
readme.md
LICENSE
```

The native Bluetooth driver is kept separate because an ordinary Secure Boot installation requires a package returned with a Microsoft Hardware Dev Center signature. The workflow also produces a clearly named **development-only** driver artifact and an unsigned submission CAB; neither is a Microsoft-signed end-user driver. Do not use the development package on a computer where Secure Boot or Memory Integrity must remain enabled. Since April 14, 2026, attestation-signed drivers are intended for testing scenarios; a production package should use the WHCP/HLK submission path.

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
| Windows Bluetooth| Experimental | No | Uses the PC Bluetooth radio directly. A Microsoft hardware-signed profile-driver package and a restart are required.       |
| Splatplost USB   | Yes     | Yes   | Requires a compatible USB serial controller-emulation device and its serial driver. A regular USB cable is not sufficient. |
| Remote           | Yes     | Yes   | Connects to a compatible remote `libnxctrl` server, typically running on Linux.                                            |
| `nxbt` Bluetooth | No      | Yes   | Linux-only because it depends on BlueZ. It may require elevated Bluetooth permissions.                                     |

Windows does not support the BlueZ-based `nxbt` backend directly. The `Windows Bluetooth` backend implements the same Switch controller protocol over the Windows Bluetooth driver stack.

### Native Windows Bluetooth setup

The native driver requires Windows 10 version 2004 (build 19041) or later, x64, and exactly one enabled Windows Bluetooth Classic radio. Disable additional Bluetooth adapters before installation. For an end-user installation, obtain the complete package returned by Microsoft, extract it into a new folder, run `install-driver.cmd` as Administrator without `-EnableTestSigning`, and restart Windows when instructed. Remove any pairing created before the new driver was installed, open the Switch **Controllers > Change Grip/Order** screen, then select **Windows Bluetooth** and click **Start Pairing**.

While connected, run the packaged verifier from an Administrator PowerShell window. The Windows SDK must be installed because the verifier deliberately uses a trusted x64 Windows Kits copy of SignTool:

```powershell
.\verify-runtime.ps1 -PackageDirectory . -RequireConnected
```

It succeeds only when Secure Boot and Memory Integrity are active, TESTSIGNING is off, the Microsoft signature and installed binary match, the driver initialized successfully, and both HID L2CAP channels are connected.

Then close the GUI and run the packaged application acceptance command. It opens its own connection, so keep the Switch on **Change Grip/Order** and pair when prompted:

```powershell
$acceptance = Start-Process -FilePath .\splatplost.exe -ArgumentList @(
  "--verify-windows-bluetooth",
  "--evidence-path", ".\SplatplostBluetooth-application-evidence.json"
) -Wait -PassThru
$acceptance.ExitCode
```

Exit code `0` plus `"passed": true` in the application evidence file binds the result to the executable version and SHA-256 hash and proves the Switch handshake over both driver channels. It does not prove that Splatoon accepted an entire drawing; perform one small drawing manually as the final physical acceptance test. See the [Korean driver guide](.github/user_guide_kr.md) and the [native backend documentation](native/windows_bluetooth/README.md) for the complete evidence boundary and development-only path.

Installation changes the Windows Bluetooth Class of Device to Peripheral/Gamepad so the Switch can discover the PC. The installer journals every mutation and rolls back exact Splatplost package identities on failure. To uninstall, re-enable the same Bluetooth radio used for installation and run `uninstall-driver.cmd` as Administrator. If removal reports that a restart is required, restart and run the uninstaller again; it retains recovery state, certificates, and the original Class of Device values until it can prove that the device and every matching Driver Store package are gone.

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

The test suite covers Windows GUI initialization and shutdown, backend loading, the native Bluetooth protocol and concurrent device I/O, application evidence, driver patch application, image conversion, connected-component labeling, and route-file generation. Separate PowerShell suites exercise version stamping, install/rollback/uninstall recovery, runtime evidence, and Partner Center package assembly. Release CI runs the installer-related suites under both PowerShell 7 and the Windows PowerShell 5.1 host used by the `.cmd` entry points.

### Publishing a Windows Release

The workflow in `.github/workflows/windows-build.yml` can be started manually or by pushing a tag. It:

1. installs the project on a Windows runner;
2. runs the test suite;
3. builds the windowed one-file `splatplost.exe`;
4. smoke-tests the packaged GUI;
5. builds and statically validates the native Windows Bluetooth profile driver and a Hardware Dev Center submission CAB;
6. creates a separate, explicitly development-only test-signed driver artifact;
7. uploads the application, development driver, and submission artifacts; and
8. publishes the application ZIP and development-only driver ZIP to a GitHub Release for the tag.

The workflow cannot create a Microsoft production signature. A registered organization must sign the submission CAB with its accepted code-signing identity, submit through the appropriate Hardware Dev Center program, verify the returned package, and assemble the end-user driver ZIP with the scripts in `native/windows_bluetooth/partner-center`. Use WHCP/HLK for a production policy; attestation is testing-only under Microsoft's current policy. The CI build and structural CAB are not substitutes for the required HLK and static-tool/CodeQL evidence.

Create and push a new tag after the workflow change is present on the target commit:

```powershell
git tag v0.3.1
git push origin v0.3.1
```

## Troubleshooting

- **A console appears and reports that `--order` is required:** you downloaded the old v0.1 CLI artifact. Download a current Release containing only `splatplost.exe`.
- **No COM port appears for Splatplost USB:** connect a compatible controller-emulation device and install its serial driver. A normal USB cable cannot provide this backend.
- **The Windows Bluetooth driver is not installed:** use a complete Microsoft-signed driver package, run `install-driver.cmd` as Administrator, and restart Windows.
- **The installer says the package is not Microsoft hardware-signed:** you have an unsigned build or the development artifact. It cannot be used as a normal Secure Boot driver.
- **The development driver is blocked:** development certificates are intentionally not trusted as an ordinary Secure Boot release. Use a Microsoft-signed package; security changes are only appropriate on an isolated driver-development machine.
- **The installer reports zero or multiple Bluetooth radios:** enable exactly one Bluetooth Classic adapter and disable additional USB or virtual Bluetooth adapters. Use that same adapter when uninstalling.
- **The installer reports `recovery-required` or `uninstall-reboot-required`:** do not delete certificates or registry state manually. Restart Windows and rerun `uninstall-driver.cmd` with the original Bluetooth adapter enabled, then install again.
- **The runtime verifier requires `-PackageDirectory` or SignTool:** run it from the fully extracted Microsoft-signed driver folder with `-PackageDirectory .`, and install a current Windows SDK containing the x64 SignTool.
- **Pairing times out after a driver update:** remove the old Nintendo/Switch pairing, reopen **Change Grip/Order**, and pair again so the driver receives the device address.
- **Remote pairing reports an XML-RPC protocol error:** enter the address of a running `libnxctrl` remote server. Host names and IP addresses without a scheme are treated as `http://`; Remote does not connect directly to the Switch IP address.
- **`nxbt` is not listed on Windows:** this is expected. Select **Windows Bluetooth** for the native backend; Splatplost USB and Remote remain optional alternatives.
- **The image will not load:** resize or crop it to exactly 320 × 120 pixels and save it as PNG or JPEG.

## Issues and Contributing

Report application and Windows-port problems in this repository's [Issues](https://github.com/mousedoc/splatplost/issues). Controller backend or pairing problems may belong in the [libnxctrl issue tracker](https://github.com/Victrid/libnxctrl/issues).

Contributions are welcome. Install the development dependencies, run the tests, and include relevant test coverage with your pull request.

## Credits and License

Splatplost was originally created by [Victrid](https://github.com/Victrid/splatplost) and is based on [libnxctrl](https://github.com/Victrid/libnxctrl).

This project is distributed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
