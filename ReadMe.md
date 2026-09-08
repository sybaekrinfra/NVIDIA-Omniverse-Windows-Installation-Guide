# NVIDIA Omniverse Installation Guide

## 전체 설치 (권장)

아래 명령은 01~04 스크립트를 순서대로 실행합니다. 필요한 경우 Windows 관리자 권한 확인 창이 표시됩니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install_All.ps1
```

설치 중 자원 경합을 피하기 위해 전체 설치에서는 Isaac Sim과 Kit-CAE를 자동 실행하지 않습니다. 설치가 끝나면 생성된 바탕화면 바로가기로 실행하세요.

Isaac Sim ZIP 파일을 BITS로 다운로드할 때는 진행률(%), 받은 용량, 전체 용량과 평균 속도가 표시됩니다.

오류가 발생하면 창을 바로 닫지 않고 내용을 확인할 때까지 기다리며, 상세 로그는 `logs` 폴더에 저장됩니다.

> **사전 요구사항:** 04번 Kit-CAE 빌드에는 Visual Studio 2019, 2022 또는 2026의 **Desktop development with C++** 워크로드와 Windows SDK가 필요합니다.

## 개별 설치

필요한 단계만 실행하려면 다음 명령을 사용하세요.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\01. Install-GitAndLFS.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\02. Install-PythonAndPip.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\03. Install-IsaacSim-6.0.1.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\04. Install-KitCAE-3.0.0.ps1"
```
