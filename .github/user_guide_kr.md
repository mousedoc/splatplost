# Windows Bluetooth 드라이버 설치 안내

## 먼저 확인할 사항

Secure Boot와 메모리 무결성을 유지하는 일반 PC에서는 **Microsoft Hardware Dev Center가 반환한 서명 드라이버 패키지만** 사용할 수 있습니다. `SplatplostDevelopment.cer`가 들어 있는 Actions 개발용 패키지와 서명되지 않은 제출용 CAB은 이 조건을 충족하지 않으며, 현재처럼 보안 기능을 끌 수 없는 컴퓨터에는 설치할 수 없습니다.

설치 스크립트는 실행 전에 릴리스 매니페스트, INF·SYS·CAT의 정확한 파일 집합과 SHA-256 해시, Microsoft 하드웨어 서명, 카탈로그 멤버십·EKU 및 SYS 내장 서명을 확인합니다. 서명되지 않았거나 다른 빌드의 파일이 섞인 패키지는 Windows 설정을 변경하기 전에 중단됩니다. 2026년 4월 14일부터 Microsoft의 Attestation 서명은 테스트 시나리오용이며, 일반 사용자에게 배포할 패키지는 WHCP/HLK 경로로 제출해야 합니다. GitHub Actions가 만든 구조용 CAB과 정적 분석 결과만으로는 WHCP에 필요한 HLK 및 정적 도구/CodeQL 근거가 되지 않습니다.

## 일반 설치(Secure Boot 및 메모리 무결성 유지)

필요 조건:

- Windows 10 버전 2004(빌드 19041) 이상 또는 Windows 11 x64
- Bluetooth Classic을 지원하는 **정확히 하나의** 활성 Bluetooth 어댑터
- Microsoft가 서명한 Splatplost Bluetooth 드라이버 패키지
- x64 SignTool이 포함된 현재 Windows SDK(설치 후 런타임 검증에 필요)
- 관리자 권한

Microsoft 서명 패키지가 아직 Release에 게시되지 않았다면 이 절차를 진행할 수 없습니다. 개발용 ZIP으로 대체하지 마세요.

1. 추가 USB 또는 가상 Bluetooth 어댑터를 비활성화하고, 설치에 사용할 어댑터 하나만 켭니다. 설치기는 이 라디오의 주소를 기록하며 설치·실행·제거 때 같은 라디오인지 확인합니다.
2. 이전 Splatplost 드라이버를 설치한 적이 있다면, 원래 설치에 사용한 Bluetooth 어댑터를 켜고 이전 패키지 폴더에서 관리자 권한으로 `uninstall-driver.cmd`를 실행합니다. 재시작을 요구하면 재시작 후 제거기를 다시 실행하여 완료 메시지를 확인합니다.
3. Microsoft가 반환한 서명 패키지를 새 폴더에 완전히 압축 해제합니다. Actions의 `development` ZIP이나 제출용 CAB을 사용하지 않습니다.
4. 해당 폴더에서 `install-driver.cmd`를 관리자 권한으로 실행합니다. `-EnableTestSigning` 옵션은 사용하지 않습니다.
5. 설치기가 현재 패키지와 실제 설치된 SYS의 SHA-256 해시, 정확히 하나인 Driver Store 패키지와 장치 바인딩, PnP 상태를 확인할 때까지 기다립니다. 재시작 안내가 나오면 Windows를 재시작합니다.
6. Windows에 남아 있는 기존 Nintendo Switch/Pro Controller 페어링을 제거합니다. 새 드라이버는 페어링 이벤트에서 Switch 주소를 받아 HID PSM `0x11`과 `0x13`을 그 장치에 한정해 등록하므로, 드라이버 설치 전에 만든 페어링은 다시 생성해야 합니다.
7. Switch에서 **Controllers > Change Grip/Order**를 엽니다.
8. `splatplost.exe`를 실행하고 **Windows Bluetooth**를 선택한 뒤 **Start Pairing**을 누릅니다.
9. 연결된 상태를 유지한 채, Microsoft 서명 드라이버를 압축 해제한 폴더의 별도 관리자 PowerShell에서 다음 명령을 실행합니다.

```powershell
.\verify-runtime.ps1 -PackageDirectory . -RequireConnected
```

검증기는 다음 항목이 모두 확인될 때만 성공합니다.

- Secure Boot 활성
- Windows TESTSIGNING 비활성
- 메모리 무결성(HVCI) 실행
- PnP 문제 코드 0 및 `SplatplostBluetooth` 서비스 실행
- 설치된 SYS와 패키지 SYS의 해시 일치
- Microsoft 하드웨어 서명 유효
- 드라이버 초기화 stage 5, NTSTATUS `0x00000000`
- 설치 시 기록된 로컬 Bluetooth 라디오 주소와 드라이버가 보고하는 주소 일치
- HID Control PSM `0x11`과 Interrupt PSM `0x13` 모두 연결

검증기는 Driver Store에 보존되지 않는 릴리스 매니페스트와 서명 근거까지 비교하므로 `-PackageDirectory .`을 생략할 수 없습니다. PATH에 있는 임의 프로그램이 아니라 Windows Kits 아래의 신뢰 가능한 x64 SignTool만 사용합니다. 결과는 `SplatplostBluetooth-runtime-evidence.json`에 저장됩니다.

## 패키징된 프로그램 승인 검사

위 런타임 검증을 통과한 뒤 GUI를 완전히 닫고, `splatplost.exe`가 있는 폴더의 PowerShell에서 다음 명령을 실행합니다. 승인 검사는 자체 드라이버 연결을 열기 때문에 GUI와 동시에 실행하지 않습니다. Switch는 계속 **Change Grip/Order** 화면에 두고 요청 시 다시 페어링합니다.

```powershell
$acceptance = Start-Process -FilePath .\splatplost.exe -ArgumentList @(
  "--verify-windows-bluetooth",
  "--evidence-path", ".\SplatplostBluetooth-application-evidence.json"
) -Wait -PassThru
$acceptance.ExitCode
```

`splatplost.exe`는 Windows GUI 하위 시스템 실행파일이므로 `Start-Process -Wait -PassThru`로 실제 종료까지 기다립니다. 성공 시 표시한 종료 코드는 0이고 JSON의 `passed`가 `true`입니다. 이 근거에는 다음 항목이 기록됩니다.

- 실행 중인 패키징 실행파일의 Splatplost 버전과 SHA-256 해시
- 드라이버 브리지 및 HID 두 채널 연결
- Switch의 장치 정보 요청, 진동 활성화, 플레이어 번호 할당 핸드셰이크
- 안정화 대기 뒤에도 유지된 양쪽 채널과 같은 로컬 Bluetooth 주소

자동화된 근거의 범위는 다음과 같습니다.

| 근거 | 자동으로 증명하는 범위 | 증명하지 않는 범위 |
| --- | --- | --- |
| `SplatplostBluetooth-runtime-evidence.json` | 보안 정책, Microsoft 서명, 패키지·설치 바이너리 일치, PnP·서비스·드라이버 초기화, HID 두 채널 | 패키징된 GUI의 프로토콜 처리, 실제 게임 입력 |
| `SplatplostBluetooth-application-evidence.json` | 해당 EXE 해시·버전, 양쪽 채널을 통한 Switch 핸드셰이크와 연결 유지 | Splatoon에서 전체 그림 완주 |
| 작은 그림 수동 테스트 | 실제 게임 화면에서 입력과 그리기 경로 동작 | 다른 PC·라디오·드라이버 버전의 결과 |

따라서 두 JSON이 모두 통과한 뒤 Splatoon에서 작은 320 × 120 테스트 이미지를 실제로 한 번 그려야 최종 물리 승인 시험이 끝납니다.

## 개발용 드라이버

`splatplost-windows-bluetooth-development-x64` Actions 아티팩트는 드라이버 개발과 격리된 전용 테스트 PC를 위한 것입니다. Secure Boot, 메모리 무결성 및 TESTSIGNING 정책을 변경해야 하며, 보안 기능을 다시 켜면 개발 서명 드라이버는 더 이상 로드되지 않습니다. Attestation으로 반환된 패키지도 현재 Microsoft 정책상 테스트용이므로 일반 사용자 Release의 대체물이 아닙니다.

따라서 일반 사용자나 보안 설정을 변경할 수 없는 컴퓨터에서는 다음 명령을 실행하지 마세요.

```powershell
.\install-driver.ps1 -EnableTestSigning
```

## 오류별 확인

- **`neither Microsoft hardware-signed ...`**: 서명되지 않은 빌드 또는 개발 인증서가 빠진/섞인 패키지입니다. Microsoft 서명 Release를 사용하세요.
- **`Exactly one enabled Windows Bluetooth radio is required`**: Bluetooth Classic 어댑터 하나만 켜고 추가 USB·가상 Bluetooth 어댑터를 비활성화하세요. 설치 뒤에는 어댑터를 바꾸지 마세요.
- **`-PackageDirectory is required`**: Microsoft 서명 드라이버 ZIP을 완전히 압축 해제한 폴더에서 `-PackageDirectory .`을 지정하세요. Driver Store 폴더만으로는 릴리스 근거를 재구성할 수 없습니다.
- **신뢰 가능한 x64 SignTool을 찾을 수 없음**: 최신 Windows SDK를 설치하세요. 다른 폴더의 `signtool.exe`를 PATH에 추가하는 것으로 대신할 수 없습니다.
- **장치 관리자 코드 52**: Windows 코드 무결성 정책이 서명을 거부했습니다. 패키지를 바꾸지 말고 설치 폴더와 런타임 근거 JSON을 보관하세요.
- **초기화 stage 1**: 설치 때 기록한 Bluetooth 라디오를 찾지 못했거나 라디오 주소가 달라졌습니다. 원래 어댑터 하나만 활성화한 뒤 다시 확인하세요.
- **초기화 stage 2**: 페어링된 장치 주소에 HID PSM을 등록하지 못했습니다. 기존 페어링을 제거하고 다시 페어링한 뒤 근거 JSON을 수집하세요.
- **연결 시간 초과**: Bluetooth가 켜져 있는지, Switch가 Change Grip/Order 화면에 있는지, 기존 페어링을 제거했는지 확인하세요.
- **이전 SYS 사용 오류**: `uninstall-driver.cmd`를 실행하고 재시작한 다음 새 패키지를 다시 설치하세요.
- **`recovery-required` 또는 `uninstall-reboot-required`**: 설치기의 복구 저널이 남아 있습니다. 인증서나 `HKLM\SOFTWARE\Splatplost...` 키를 수동으로 지우지 마세요. 원래 라디오를 켜고 재시작한 뒤 `uninstall-driver.cmd`를 다시 실행하여 완전히 제거한 다음 재설치하세요.

설치기는 전역 작업 잠금과 내구성 있는 복구 저널을 사용합니다. 실패하면 설치 전 장치·Driver Store 패키지·인증서 소유권 스냅샷과 비교해 이번 실행에서 추가한 항목만 되돌리고, 완전한 복구를 증명하지 못하면 상태를 남깁니다.

드라이버 제거 시에는 설치에 사용한 같은 Bluetooth 라디오가 활성화되어 있어야 합니다. 제거기는 로컬 프로필을 그 라디오에서 먼저 해제하고, 활성 여부와 관계없이 검증된 모든 Splatplost `oem*.inf`를 Driver Store에서 제거한 뒤 장치와 패키지가 모두 사라졌는지 다시 확인합니다. PnPUtil이 3010 또는 1641을 반환하거나 잔여 항목이 있으면 인증서·원래 Class of Device·복구 상태를 보존합니다. 이 경우 Windows를 재시작하고 같은 어댑터를 켠 채 `uninstall-driver.cmd`를 다시 실행하세요. 완료 메시지가 나온 뒤에만 재설치합니다.
