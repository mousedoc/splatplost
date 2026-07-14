# 설치방법

과한 보안 해제를 동반한 설치과정이 내포된 이유는 블루투스 드라이버 관련해서 윈도우 서명을 우회해야 하기 때문에 그렇습니다. 

그리고 **반드시 보안 해제 관련 부분은 설치가 끝난 뒤 다시 활성화 시켜주셔야합니다.**

---

### 메모리 무결성 해제
<img width="535" height="316" alt="image" src="https://github.com/user-attachments/assets/14e4211e-987c-4501-bda0-4722cd0b8895" />

- **설치가 끝난 뒤 반드시 메모리 무결성을 다시 활성화 해주세요**
- Windows 보안 -> 장치 보안 -> 코어 격리 -> 메모리 무결성


### BIOS Secure Boot 해제
- **설치가 끝난 뒤 반드시 Secure Boot를 다시 활성화 해주세요**
- https://www.asus.com/kr/support/faq/1049829/


### 드라이버 설치

<img width="411" height="368" alt="image" src="https://github.com/user-attachments/assets/290feea5-19f2-4812-9030-eebd3a5c0f63" />


- 다운 및 압축 해제 된 폴더 경로의 **관리자 권한 powershell**에서 다음 아래 명령어 입력

```
Set-ExecutionPolicy -Scope Process Bypass

.\install-driver.ps1 -EnableTestSigning
```

- 이후, 재부팅 후 다운 및 압축 해제 된 폴더 경로 **관리자 권한 powershell**에서 아래 명령어 입력
```
.\install-driver.ps1
```
