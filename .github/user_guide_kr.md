# 설치방법

### Secure Boot 해제
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
