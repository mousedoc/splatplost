# Splatplost

[English](../readme.md) · [简体中文](../readme.zh-CN.md)

Splatplost는 320 × 120 이미지를 Splatoon 게시물로 그리기 위한 컨트롤러 입력으로 변환하는 GUI 프로그램입니다. [libnxctrl](https://github.com/Victrid/libnxctrl)을 기반으로 하며, 최적화된 경로 생성, 블록 단위 그리기 제어, 여러 컨트롤러 백엔드를 제공합니다.

이 저장소에는 PyQt6 기반 v0.2 GUI와 Windows x64 포팅 버전이 포함되어 있습니다. Windows 버전은 콘솔 없는 단일 실행파일로 배포되며 Python을 별도로 설치할 필요가 없습니다.

## 주요 기능

- PyQt6 기반 데스크톱 GUI
- Splatoon 2 및 Splatoon 3 입력 매핑
- 320 × 120 해상도의 PNG 및 JPEG 입력
- 최적화된 그리기 경로 생성
- 블록 선택을 통한 부분 그리기 및 지우기
- 캔버스 초기화, 보정 설정 및 안정 모드
- Windows용 Splatplost USB 및 Remote 백엔드
- Linux용 선택적 `nxbt` Bluetooth 백엔드
- 태그 푸시 시 Windows 빌드 및 GitHub Release 자동 발행

## Windows 버전 다운로드

1. [Releases 페이지](https://github.com/mousedoc/splatplost/releases)를 엽니다.
2. 최신 Release에서 `splatplost-windows-x64.zip`을 다운로드합니다.
3. ZIP 파일을 새 폴더에 압축 해제합니다.
4. `splatplost.exe`를 더블클릭합니다.

Release ZIP에는 다음 파일이 들어 있습니다.

```text
splatplost.exe
readme.md
LICENSE
```

현재 GUI 빌드에는 `splatplan.exe`나 `splatplot.exe`가 포함되지 않습니다. 이 파일들은 이전 명령줄 버전의 실행파일입니다. `--order is required` 오류가 나타난다면 현재 GUI Release가 아닌 구 CLI 아티팩트를 실행한 것입니다.

현재 실행파일은 코드 서명되지 않았으므로 Windows에서 게시자 또는 SmartScreen 경고가 나타날 수 있습니다. 반드시 이 저장소의 Releases 페이지에서 받은 파일만 실행하세요.

## GUI 사용 방법

1. **Select**를 클릭하고 정확히 320 × 120 크기인 PNG 또는 JPEG 이미지를 선택합니다.
2. **Load**를 클릭해 그리기 경로를 생성합니다. 검은색 픽셀이 그리기 대상으로 처리됩니다.
3. 이미지 블록을 마우스 왼쪽 버튼으로 선택하거나 오른쪽 버튼으로 선택 해제합니다. **Select All**과 **Deselect All**도 사용할 수 있습니다.
4. **Splatoon 2** 또는 **Splatoon 3**를 선택합니다.
5. 컨트롤러 백엔드를 선택하고 **Connect to Switch**를 클릭합니다.
6. 페어링 창의 안내를 따른 뒤 **Draw selected** 또는 **Erase selected**를 실행합니다.

지우기 작업만 필요하면 **Load an Empty Image**를 사용할 수 있습니다. 그리기 옵션에서는 캔버스 초기화, 단계별 보정 및 안정 모드도 설정할 수 있습니다.

## 컨트롤러 백엔드

| 백엔드           | Windows | Linux | 설명                                                                                                              |
| ---------------- | ------- | ----- | ----------------------------------------------------------------------------------------------------------------- |
| Splatplost USB   | 지원    | 지원  | 호환되는 USB 시리얼 컨트롤러 에뮬레이션 장치와 드라이버가 필요합니다. 일반 USB 케이블만으로는 사용할 수 없습니다. |
| Remote           | 지원    | 지원  | 일반적으로 Linux에서 실행되는 호환 `libnxctrl` 원격 서버에 연결합니다.                                            |
| `nxbt` Bluetooth | 미지원  | 지원  | BlueZ에 의존하므로 Linux 전용입니다. Bluetooth 권한 상승이 필요할 수 있습니다.                                    |

Windows에서는 BlueZ 기반 `nxbt` 백엔드를 직접 사용할 수 없습니다. 호환되는 Splatplost USB 장치 또는 Remote 백엔드를 사용하세요.

## 소스에서 설치

Python 3.9 이상이 필요합니다. Windows Release 워크플로에서는 Python 3.12를 사용합니다.

### Windows

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install .
splatplost
```

### Linux

기본 GUI와 Bluetooth 이외의 백엔드를 설치합니다.

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install .
splatplost
```

Linux 전용 Bluetooth 백엔드를 포함하려면 다음 명령을 사용합니다.

```bash
python3 -m pip install ".[bluetooth]"
```

Bluetooth 사용에는 추가 BlueZ 설정 또는 권한 상승이 필요할 수 있습니다. 사용하는 Linux 환경에 맞는 `libnxctrl`/`nxbt` 설정을 참고하세요.

## 개발

프로젝트를 편집 가능한 형태로 빌드 도구와 함께 설치하고 테스트를 실행합니다.

```powershell
py -m pip install -e ".[build]"
py -m unittest discover -s tests -v
```

테스트에서는 Windows GUI 초기화, 백엔드 로딩, 이미지 변환, 연결 요소 라벨링 및 경로 파일 생성을 확인합니다.

### Windows Release 발행

`.github/workflows/windows-build.yml` 워크플로는 태그가 푸시될 때만 실행되며 다음 작업을 수행합니다.

1. Windows 러너에 프로젝트를 설치합니다.
2. 테스트를 실행합니다.
3. 콘솔 없는 단일 `splatplost.exe`를 빌드합니다.
4. 패키징된 GUI를 스모크 테스트합니다.
5. Windows Actions 아티팩트를 업로드합니다.
6. 해당 태그의 GitHub Release를 만들고 `splatplost-windows-x64.zip`을 첨부합니다.

워크플로 변경이 대상 커밋에 포함된 상태에서 새 태그를 만들고 푸시하세요.

```powershell
git tag v0.2.1
git push origin v0.2.1
```

## 문제 해결

- **콘솔이 나타나고 `--order`가 필요하다는 오류가 표시됨:** 구 v0.1 CLI 아티팩트입니다. `splatplost.exe` 하나가 포함된 최신 Release를 다운로드하세요.
- **Splatplost USB에서 COM 포트가 표시되지 않음:** 호환되는 컨트롤러 에뮬레이션 장치를 연결하고 시리얼 드라이버를 설치하세요. 일반 USB 케이블은 이 백엔드를 제공하지 않습니다.
- **Windows에서 `nxbt`가 표시되지 않음:** 정상 동작입니다. Splatplost USB 또는 Remote를 사용하세요.
- **이미지를 불러올 수 없음:** 이미지를 정확히 320 × 120 크기로 조정하고 PNG 또는 JPEG로 저장하세요.

## 이슈 및 기여

프로그램 또는 Windows 포팅 관련 문제는 이 저장소의 [Issues](https://github.com/mousedoc/splatplost/issues)에 등록해 주세요. 컨트롤러 백엔드나 페어링 문제는 [libnxctrl 이슈 트래커](https://github.com/Victrid/libnxctrl/issues)가 더 적합할 수 있습니다.

기여를 환영합니다. 개발 의존성을 설치하고 테스트를 실행한 뒤 관련 테스트와 함께 Pull Request를 제출해 주세요.

## 크레딧 및 라이선스

Splatplost는 [Victrid](https://github.com/Victrid/splatplost)가 처음 개발했으며 [libnxctrl](https://github.com/Victrid/libnxctrl)을 기반으로 합니다.

이 프로젝트는 GNU General Public License v3.0으로 배포됩니다. 자세한 내용은 [LICENSE](../LICENSE)를 확인하세요.
