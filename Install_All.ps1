#requires -Version 5.1
<#
.SYNOPSIS
    NVIDIA Omniverse 개발 환경 설치 스크립트 01~04를 순서대로 실행합니다.

.DESCRIPTION
    - 스크립트가 있는 폴더를 기준으로 01~04 파일을 찾습니다.
    - 시작 전에 모든 파일의 존재 여부와 PowerShell 구문을 검사합니다.
    - 필요한 경우 관리자 권한으로 자신을 다시 실행하고 완료될 때까지 기다립니다.
    - 각 단계를 별도 PowerShell 프로세스에서 실행하고 실패 시 즉시 중단합니다.
    - 설치 중 자원 경합을 피하기 위해 Isaac Sim과 Kit-CAE 자동 실행은 생략합니다.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install_All.ps1
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$NoPauseOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

if ($env:OS -ne 'Windows_NT') {
    throw '이 스크립트는 Windows에서만 실행할 수 있습니다.'
}

$powerShellExe = (Get-Process -Id $PID).Path
$steps = @(
    [pscustomobject]@{
        Number = 1
        Name = 'Git 및 Git LFS 설치'
        Path = Join-Path $PSScriptRoot '01. Install-GitAndLFS.ps1'
        Arguments = @()
    }
    [pscustomobject]@{
        Number = 2
        Name = 'Python 및 pip 설치'
        Path = Join-Path $PSScriptRoot '02. Install-PythonAndPip.ps1'
        Arguments = @('-NoPauseOnError')
    }
    [pscustomobject]@{
        Number = 3
        Name = 'NVIDIA Isaac Sim 6.0.1 설치'
        Path = Join-Path $PSScriptRoot '03. Install-IsaacSim-6.0.1.ps1'
        Arguments = @('-NoLaunch')
    }
    [pscustomobject]@{
        Number = 4
        Name = 'NVIDIA Omniverse Kit-CAE 3.0.0 설치'
        Path = Join-Path $PSScriptRoot '04. Install-KitCAE-3.0.0.ps1'
        Arguments = @('-NoLaunch')
    }
)

Write-Step '설치 스크립트 사전 검사'

foreach ($step in $steps) {
    if (-not (Test-Path -LiteralPath $step.Path -PathType Leaf)) {
        throw "설치 스크립트를 찾을 수 없습니다: $($step.Path)"
    }

    $tokens = $null
    $parseErrors = $null

    [Management.Automation.Language.Parser]::ParseFile(
        $step.Path,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors.Count -gt 0) {
        $details = $parseErrors | ForEach-Object {
            "줄 $($_.Extent.StartLineNumber): $($_.Message)"
        }

        throw "PowerShell 구문 오류가 있습니다: $($step.Path)`n$($details -join [Environment]::NewLine)"
    }

    Write-Host "확인 완료: $([IO.Path]::GetFileName($step.Path))" -ForegroundColor Green
}

if (-not (Test-IsAdministrator)) {
    Write-Step '관리자 권한 요청'
    Write-Host '전체 설치를 위해 Windows 관리자 권한을 요청합니다.' -ForegroundColor Yellow

    $elevationArguments = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', "`"$PSCommandPath`""
    )

    if ($NoPauseOnError) {
        $elevationArguments += '-NoPauseOnError'
    }

    try {
        $elevatedProcess = Start-Process `
            -FilePath $powerShellExe `
            -ArgumentList $elevationArguments `
            -Verb RunAs `
            -Wait `
            -PassThru
    }
    catch {
        throw "관리자 권한으로 다시 실행하지 못했습니다: $($_.Exception.Message)"
    }

    exit $elevatedProcess.ExitCode
}

$installTranscriptStarted = $false
$installLogPath = $null

try {
    $logDirectory = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $installLogPath = Join-Path $logDirectory (
        'Install_All-{0}-{1}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID
    )

    Start-Transcript -Path $installLogPath -Force | Out-Null
    $installTranscriptStarted = $true
}
catch {
    Write-Host "설치 로그를 시작하지 못했습니다: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '설치를 시작합니다. 각 단계는 완료될 때까지 순서대로 실행됩니다.' -ForegroundColor Green
Write-Host '참고: 04번에는 Visual Studio C++ 워크로드와 Windows SDK가 필요합니다.' -ForegroundColor Yellow

$stopwatch = [Diagnostics.Stopwatch]::StartNew()

try {
    foreach ($step in $steps) {
        Write-Step "[$($step.Number)/$($steps.Count)] $($step.Name)"
        Write-Host "스크립트: $($step.Path)"

        $childArguments = @(
            '-NoLogo'
            '-NoProfile'
            '-ExecutionPolicy', 'Bypass'
            '-File', $step.Path
        ) + $step.Arguments

        & $powerShellExe @childArguments
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            throw "[$($step.Number)/$($steps.Count)] $($step.Name) 실패 (종료 코드: $exitCode)"
        }

        Write-Host "[$($step.Number)/$($steps.Count)] 완료" -ForegroundColor Green
    }
}
catch {
    $stopwatch.Stop()

    Write-Host ''
    Write-Host '전체 설치가 중단되었습니다.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host '문제를 해결한 뒤 Install_All.ps1을 다시 실행하세요.' -ForegroundColor Yellow

    if (-not [string]::IsNullOrWhiteSpace($installLogPath)) {
        Write-Host "로그 파일: $installLogPath" -ForegroundColor Yellow
    }

    if ($installTranscriptStarted) {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
        $installTranscriptStarted = $false
    }

    if (-not $NoPauseOnError -and [Environment]::UserInteractive) {
        try {
            Read-Host '오류 내용을 확인한 뒤 Enter 키를 누르세요'
        }
        catch {
            # 입력을 받을 수 없는 호스트에서는 바로 종료합니다.
        }
    }

    exit 1
}

$stopwatch.Stop()

Write-Step '전체 설치 완료'
Write-Host ('소요 시간: {0:hh\:mm\:ss}' -f $stopwatch.Elapsed) -ForegroundColor Green
Write-Host '바탕화면 바로가기를 사용해 Isaac Sim과 Kit-CAE를 실행할 수 있습니다.' -ForegroundColor Green

if ($installTranscriptStarted) {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    $installTranscriptStarted = $false
}

exit 0
