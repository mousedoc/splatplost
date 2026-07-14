# Native Windows Bluetooth backend

This directory builds a Windows KMDF Bluetooth profile driver that makes the PC radio expose the Nintendo Switch Pro Controller HID service. It is the native counterpart to the BlueZ L2CAP sockets used by NXBT/libnxctrl on Linux; it does not use a VM, serial port, or external controller-emulation board.

## Components

- `windows-driver-samples.patch` adapts Microsoft's Bluetooth Echo L2CAP sample to register HID control PSM `0x11` and interrupt PSM `0x13` and expose a `\\.\SplatplostBluetooth` user-mode bridge.
- `switch-controller.xml` is the Pro Controller SDP/HID record used by NXBT.
- `generate_switch_sdp.py` serializes the SDP XML into the static record submitted by the Windows Bluetooth stack.
- `build-driver.ps1` checks out the pinned Microsoft sample commit, applies the patch, and builds the x64 driver plus local-service helper.
- `install-driver.ps1` stages the driver, enables the local profile, and saves/replaces the host Class of Device with Peripheral/Gamepad values.
- `install-driver.cmd` and `uninstall-driver.cmd` launch the PowerShell installers with a process-scoped execution-policy bypass.
- `uninstall-driver.ps1` disables the profile and restores the previous Class of Device values.

The upstream sample is pinned to commit `2ee527bfeb0aeb6be11f0a8b6dce4011b358ce89` so the patch and build are reproducible.

## Build

Visual Studio 2022 with Desktop development for C++, Windows SDK 26100, WDK 26100, and the Visual Studio Driver Kit component are required. The pinned `windows-2022` GitHub Actions runner supplies those components and verifies them before compiling the driver.

```powershell
./native/windows_bluetooth/build-driver.ps1 -Configuration Release -Platform x64
./native/windows_bluetooth/sign-test-driver.ps1 -PackageDirectory ./native/windows_bluetooth/out
```

GitHub Actions performs both commands and packages the result with `splatplost.exe`.

## Driver signing boundary

The Actions package is development-signed for hardware testing. It requires Windows test-signing mode and cannot load while Secure Boot enforces Microsoft signatures. Distribution to ordinary Secure Boot systems requires submitting the generated driver package to Microsoft Hardware Dev Center for attestation or WHQL signing. That final signature cannot be generated from source code or a public GitHub runner because it requires the publisher's Partner Center identity and signing account.

## Attributions

- Bluetooth L2CAP driver foundation: Microsoft Windows Driver Samples.
- Switch HID SDP and controller protocol behavior: Brikwerk/NXBT.
- Splatplost backend interface and input model: Victrid/libnxctrl.
