# Native Windows Bluetooth backend

This directory contains an experimental Windows KMDF Bluetooth profile driver and the user-mode bridge used by Splatplost. The goal is to expose the PC as a Nintendo Switch Pro Controller without BlueZ, a VM, or an external controller-emulation board.

## Architecture

- `windows-driver-samples.patch` adapts Microsoft's Bluetooth Echo sample and adds the `\\.\SplatplostBluetooth` bridge.
- `windows-driver-diagnostics.patch` exposes initialization stage, NTSTATUS, local radio address, and the two connected-channel bits even when initialization fails.
- `windows-driver-specific-psm.patch` removes wildcard `BRB_REGISTER_PSM` calls for reserved HID PSMs. It receives a pairing notification, moves work to PASSIVE_LEVEL, then registers `(Switch address, 0x11)` and `(Switch address, 0x13)` L2CAP servers separately.
- `windows-driver-runtime-hardening.patch` hardens request lifetimes, child-list state, status synchronization, report queues, and cleanup/cancellation paths for KMDF verification.
- `switch-controller.xml` and `generate_switch_sdp.py` produce the Pro Controller SDP/HID record.
- `install-driver.ps1` verifies the complete package before mutation, locks concurrent operations, journals recovery state, pins the profile to exactly one radio, installs the INF, and proves the installed device/package identity and SYS hash.
- `uninstall-driver.ps1` unregisters the profile on that exact radio, deletes every verified Splatplost `oem*.inf`, and removes installer-owned certificates/restores the previous Class of Device only after absence is proved.
- `verify-runtime.ps1` writes fail-closed JSON evidence for Secure Boot, HVCI, signing, PnP, driver initialization, and both HID channels.

The upstream sample is pinned to commit `2ee527bfeb0aeb6be11f0a8b6dce4011b358ce89` so patch application is reproducible.

Microsoft documents address-specific L2CAP server registration, but does not explicitly guarantee that an address-specific registration for reserved HID PSMs will coexist with `HidBth`, nor that a PSM-less notification server will receive pairing events without a wildcard PSM registration. The implementation therefore remains experimental until positive evidence is collected on a real Windows radio and Nintendo Switch.

## Build and static validation

The target is Windows 10 version 2004 (build 19041) or later on x64. The supported build environment is Visual Studio 2022 with Desktop development for C++, the Windows SDK/WDK, and the Visual Studio Driver Kit component. The tag workflow verifies WDK 26100 on `windows-2022`, enables MSBuild code analysis, and compiles x64 Release with level-4 warnings treated as errors. Before release, the same sources must also pass InfVerif, Inf2Cat, strict API validation, `/sdl`, and the WDK `DriverRecommended`/`DriverMustFix` rule sets; the current 0.3.1 source passed that validation with zero compiler or analysis warnings.

```powershell
.\build-driver.ps1 -Configuration Release -Platform x64
python -m unittest discover -s ..\..\tests -v
.\test-build-versioning.ps1
.\test-installer-scripts.ps1
.\test-verify-runtime.ps1
.\partner-center\test-packaging-scripts.ps1
```

`prepare-driver.ps1` cleans ignored output below its owned sample directory before applying the four patches. `build-driver.ps1` copies only the exact requested configuration's SYS, INF, PDB, and helper, preventing an old Debug or Release binary from being selected recursively. The build manifest records the exact INF/SYS identity and driver version; a release tag `vX.Y.Z` must match application version `X.Y.Z` and driver version `X.Y.Z.0`.

## Signing and release boundary

A public GitHub runner can compile and development-sign this driver, but it cannot create a normal Secure Boot signature. That requires an organization registered in Microsoft Hardware Dev Center, an accepted EV signing identity, the required Microsoft Entra/organization roles, and the submission path appropriate for the release policy.

1. Build the unsigned package.
2. Create and sign the Hardware Dev Center CAB. `-PrepareOnly` is for structural CI evidence only; it does not create a submit-ready identity signature.

```powershell
.\partner-center\prepare-submission-cab.ps1 `
  -PackageDirectory .\out `
  -SymbolsPath .\out\SplatplostBluetooth.pdb `
  -OutputPath .\SplatplostBluetooth-attestation.cab `
  -SigningCertificateThumbprint <registered-certificate-thumbprint> `
  -TimestampUrl <rfc3161-url>
```

3. Submit the CAB to Hardware Dev Center. Since April 14, 2026, attestation signing is for testing scenarios only; use the HLK/WHCP path for a production release policy. The repository's structural CAB and local static-analysis results are not HLK/WHCP certification evidence; the registered organization must run the required HLK and static-tool/CodeQL tests on qualified hardware.
4. Download the returned `signedPackage`, then verify and assemble it with the matching build's helper and scripts.

```powershell
.\partner-center\verify-signed-package.ps1 `
  -SignedPackagePath <signedPackage.zip> `
  -RunInfVerif

.\partner-center\assemble-signed-release.ps1 `
  -SignedPackagePath <signedPackage.zip> `
  -BuildOutputDirectory .\out
```

The verifier requires a valid Microsoft catalog signature, catalog membership for the INF and SYS, a valid isolated embedded SYS signature, and a Microsoft hardware-signing EKU. The assembler verifies before and after copying, excludes a stale development certificate, and produces a flat ZIP.

The GitHub workflow keeps outputs distinct:

- `splatplost-windows-x64`: application only;
- `splatplost-windows-bluetooth-development-x64`: test-signed driver for isolated driver-development machines;
- `splatplost-windows-bluetooth-attestation-submission`: unsigned structural CAB and manifest for maintainer processing.

## Runtime evidence

On a Windows 10 2004+ x64 target PC, leave exactly one Bluetooth Classic radio enabled. With the returned Microsoft-signed package, install and restart, remove any pre-existing Switch pairing, pair again, and run while both channels are connected. `-PackageDirectory` is mandatory because Driver Store does not retain the release manifest, signature evidence, or support-file hashes. Install a current Windows SDK; the verifier accepts only a trusted x64 SignTool below Windows Kits.

```powershell
.\verify-runtime.ps1 -PackageDirectory . -RequireConnected
```

A pass requires Secure Boot on, TESTSIGNING off, HVCI running, healthy PnP/service state, matching installed binary, Microsoft signing, initialization stage 5 with success status, the installed radio address, and both PSM `0x11` and `0x13` channel bits.

Close the GUI and run the packaged application acceptance separately; it opens its own bridge connection:

```powershell
$acceptance = Start-Process -FilePath .\splatplost.exe -ArgumentList @(
  "--verify-windows-bluetooth",
  "--evidence-path", ".\SplatplostBluetooth-application-evidence.json"
) -Wait -PassThru
$acceptance.ExitCode
```

Exit code `0` plus `"passed": true` binds the evidence to the frozen executable version and SHA-256 hash and proves the device-info, vibration-enable, and player-assignment handshake over both channels, followed by an alive/status check. Neither JSON proves that a complete drawing was accepted by Splatoon; one real drawing remains the final physical acceptance test.

The installer and uninstaller serialize operations through a global mutex and retain a durable recovery journal. The same radio must remain enabled for uninstall. If removal requires a reboot or cannot prove that all matching devices and Driver Store packages are absent, restart and rerun `uninstall-driver.cmd`; do not manually delete certificates, Class of Device values, or the recovery registry keys.

## Microsoft references

- [Accepting L2CAP connections in a Bluetooth profile driver](https://learn.microsoft.com/windows-hardware/drivers/bluetooth/accepting-l2cap-connections-in-a-bluetooth-profile-driver)
- [Driver signing options](https://learn.microsoft.com/windows-hardware/drivers/dashboard/driver-signing-offerings)
- [Attestation signing submission](https://learn.microsoft.com/windows-hardware/drivers/dashboard/code-signing-attestation)
- [Hardware program registration](https://learn.microsoft.com/windows-hardware/drivers/dashboard/hardware-program-register)

## Attributions

- Bluetooth L2CAP driver foundation: Microsoft Windows Driver Samples.
- Switch HID SDP and controller protocol behavior: Brikwerk/NXBT revision `ec4b800ad6c55de96bb6c7f9f84b5bdc59a4c975`.
- Splatplost backend interface and input model: Victrid/libnxctrl.
