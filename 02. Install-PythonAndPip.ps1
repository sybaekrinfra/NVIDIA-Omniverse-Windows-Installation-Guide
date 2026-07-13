#requires -Version 5.1
<#
.SYNOPSIS
    Windows에서 지정된 Python 버전과 pip를 확인하고, 없는 경우 자동 설치합니다.

.DESCRIPTION
    기본값으로 Python 3.11을 확인하고 설치합니다.

    수행 작업:
    1. 지정된 Python 버전의 실행 파일을 확인합니다.
    2. Python이 없으면 WinGet 또는 Chocolatey로 설치합니다.
    3. ensurepip로 pip를 복구하거나 초기 설치합니다.
    4. pip, setuptools, wheel을 업데이트합니다.
    5. Python 및 Scripts 폴더를 사용자 PATH에 등록합니다.
    6. 최종 Python/pip 버전과 실행 경로를 출력합니다.

    참고:
    Kit-CAE의 repo.bat pip_download는 일반적으로 저장소가 관리하는 Python 환경을
    사용하므로 시스템 Python이 반드시 필요한 것은 아닙니다. 이 스크립트는 별도의
    Python 개발 및 문제 해결 환경까지 준비할 때 사용할 수 있습니다.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File ".\02. Install-PythonAndPip.ps1"

.EXAMPLE
    # Python 3.12 설치
    powershell.exe -ExecutionPolicy Bypass -File ".\02. Install-PythonAndPip.ps1" `
        -PythonVersion 3.12

.EXAMPLE
    # pip 패키지 업데이트 생략
    powershell.exe -ExecutionPolicy Bypass -File ".\02. Install-PythonAndPip.ps1" `
        -SkipPipUpgrade
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('3.11', '3.12', '3.13', '3.14')]
    [string]$PythonVersion = '3.11',

    [Parameter()]
    [switch]$SkipPipUpgrade,

    [Parameter()]
    [switch]$NoPauseOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$pythonTranscriptStarted = $false
$pythonLogPath = $null

trap {
    $errorRecord = $_

    Write-Host ''
    Write-Host 'Python 설치가 중단되었습니다.' -ForegroundColor Red
    Write-Host $errorRecord.Exception.Message -ForegroundColor Red

    if (
        $null -ne $errorRecord.InvocationInfo -and
        $errorRecord.InvocationInfo.PositionMessage
    ) {
        Write-Host $errorRecord.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    }

    if (-not [string]::IsNullOrWhiteSpace($pythonLogPath)) {
        Write-Host "로그 파일: $pythonLogPath" -ForegroundColor Yellow
    }

    if ($pythonTranscriptStarted) {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
        $pythonTranscriptStarted = $false
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

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-WingetUsable {
    if (-not (Test-CommandAvailable 'winget.exe')) {
        return $false
    }

    try {
        & winget.exe --version *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Test-ChocolateyUsable {
    if (-not (Test-CommandAvailable 'choco.exe')) {
        return $false
    }

    try {
        & choco.exe --version *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')

    $parts = @($machinePath, $userPath) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $env:Path = $parts -join ';'

    $compactVersion = $PythonVersion.Replace('.', '')

    $candidatePaths = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python$compactVersion"),
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python$compactVersion\Scripts"),
        (Join-Path $env:LOCALAPPDATA 'Python\bin'),
        (Join-Path $env:APPDATA "Python\Python$compactVersion\Scripts"),
        (Join-Path $env:ProgramFiles "Python$compactVersion"),
        (Join-Path $env:ProgramFiles "Python$compactVersion\Scripts"),
        (Join-Path $env:SystemDrive "Python$compactVersion"),
        (Join-Path $env:SystemDrive "Python$compactVersion\Scripts")
    )

    foreach ($path in $candidatePaths) {
        if (
            (Test-Path -LiteralPath $path -PathType Container) -and
            (($env:Path -split ';') -notcontains $path)
        ) {
            $env:Path = "$path;$env:Path"
        }
    }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string[]]$Arguments = @()
    )

    & $FilePath @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "'$FilePath $($Arguments -join ' ')' 실행에 실패했습니다. 종료 코드: $LASTEXITCODE"
    }
}

function Get-PythonVersion {
    param(
        [Parameter(Mandatory)]
        [string]$PythonExecutable
    )

    try {
        # Windows PowerShell 5.1은 네이티브 명령 인수 안의 큰따옴표를 제거할 수 있으므로
        # 큰따옴표가 필요 없는 Python 코드를 사용합니다.
        $version = & $PythonExecutable -c `
            'import sys; print(sys.version_info.major, sys.version_info.minor, sep=chr(46))' `
            2>$null

        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        return ($version | Select-Object -First 1).Trim()
    }
    catch {
        return $null
    }
}

function Resolve-PythonExecutable {
    $compactVersion = $PythonVersion.Replace('.', '')
    $candidates = [System.Collections.Generic.List[string]]::new()

    if (Test-CommandAvailable 'py.exe') {
        try {
            $pyResult = & py.exe "-$PythonVersion" -c `
                'import sys; print(sys.executable)' `
                2>$null

            if ($LASTEXITCODE -eq 0 -and $pyResult) {
                $candidates.Add(($pyResult | Select-Object -First 1).Trim())
            }
        }
        catch {
            # 다음 후보를 계속 확인합니다.
        }

        try {
            $managerResult = & py.exe "-V:$PythonVersion" -c `
                'import sys; print(sys.executable)' `
                2>$null

            if ($LASTEXITCODE -eq 0 -and $managerResult) {
                $candidates.Add(($managerResult | Select-Object -First 1).Trim())
            }
        }
        catch {
            # 다음 후보를 계속 확인합니다.
        }
    }

    if (Test-CommandAvailable 'python.exe') {
        $pythonCommand = Get-Command 'python.exe' -ErrorAction SilentlyContinue

        if ($pythonCommand -and $pythonCommand.Source) {
            $candidates.Add($pythonCommand.Source)
        }
    }

    $commonCandidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python$compactVersion\python.exe"),
        (Join-Path $env:ProgramFiles "Python$compactVersion\python.exe"),
        (Join-Path $env:ProgramFiles "Python$PythonVersion\python.exe"),
        (Join-Path $env:SystemDrive "Python$compactVersion\python.exe")
    )

    foreach ($candidate in $commonCandidates) {
        $candidates.Add($candidate)
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (
            -not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)
        ) {
            $detectedVersion = Get-PythonVersion -PythonExecutable $candidate

            if ($detectedVersion -eq $PythonVersion) {
                return [IO.Path]::GetFullPath($candidate)
            }
        }
    }

    return $null
}

function Install-Python {
    $wingetPackageId = "Python.Python.$PythonVersion"
    $chocolateyPackageName = "python$($PythonVersion.Replace('.', ''))"
    $wingetAvailable = Test-CommandAvailable 'winget.exe'
    $wingetUsable = $false

    if ($wingetAvailable) {
        $wingetUsable = Test-WingetUsable
    }

    if ($wingetAvailable -and -not $wingetUsable) {
        Write-Host @"
winget.exe 실행 별칭은 있지만 WinGet을 정상 실행할 수 없습니다.
Microsoft App Installer가 없거나 손상된 경우 발생할 수 있습니다.
다른 설치 방법을 확인합니다.
"@ -ForegroundColor Yellow
    }

    if ($wingetUsable) {
        Write-Host "WinGet 패키지로 Python ${PythonVersion}을 설치합니다: $wingetPackageId"

        try {
            Invoke-NativeCommand `
                -FilePath 'winget.exe' `
                -Arguments @(
                    'install',
                    '--id', $wingetPackageId,
                    '--exact',
                    '--source', 'winget',
                    '--silent',
                    '--accept-package-agreements',
                    '--accept-source-agreements',
                    '--disable-interactivity'
                )

            return
        }
        catch {
            Write-Host "WinGet 설치에 실패했습니다: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host 'Chocolatey를 사용할 수 있는지 확인합니다.' -ForegroundColor Yellow
        }
    }

    if (Test-ChocolateyUsable) {
        Write-Host "Chocolatey로 Python ${PythonVersion}을 설치합니다: $chocolateyPackageName"

        Invoke-NativeCommand `
            -FilePath 'choco.exe' `
            -Arguments @(
                'install',
                $chocolateyPackageName,
                '--yes',
                '--no-progress'
            )

        return
    }

    throw @"
Python ${PythonVersion}을 자동 설치할 수 없습니다.

정상적으로 실행되는 WinGet 또는 Chocolatey가 필요합니다.
Windows의 Microsoft App Installer를 설치하여 WinGet을 활성화한 뒤
이 스크립트를 다시 실행하는 방법을 권장합니다.
"@
}

function Add-DirectoryToUserPath {
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return
    }

    $normalizedDirectory = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $currentUserPath = [Environment]::GetEnvironmentVariable(
        'Path',
        [EnvironmentVariableTarget]::User
    )

    $entries = @()

    if (-not [string]::IsNullOrWhiteSpace($currentUserPath)) {
        $entries = $currentUserPath -split ';' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $alreadyExists = $false

    foreach ($entry in $entries) {
        try {
            $normalizedEntry = [Environment]::ExpandEnvironmentVariables($entry)
            $normalizedEntry = [IO.Path]::GetFullPath($normalizedEntry).TrimEnd('\')

            if ($normalizedEntry -ieq $normalizedDirectory) {
                $alreadyExists = $true
                break
            }
        }
        catch {
            if ($entry.TrimEnd('\') -ieq $normalizedDirectory) {
                $alreadyExists = $true
                break
            }
        }
    }

    if (-not $alreadyExists) {
        $newEntries = @($entries) + $normalizedDirectory
        $newPath = $newEntries -join ';'

        [Environment]::SetEnvironmentVariable(
            'Path',
            $newPath,
            [EnvironmentVariableTarget]::User
        )

        Write-Host "사용자 PATH에 추가: $normalizedDirectory" -ForegroundColor Green
    }

    if (($env:Path -split ';') -notcontains $normalizedDirectory) {
        $env:Path = "$normalizedDirectory;$env:Path"
    }
}

if ($env:OS -ne 'Windows_NT') {
    throw '이 스크립트는 Windows에서만 실행할 수 있습니다.'
}

try {
    $logDirectory = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $pythonLogPath = Join-Path $logDirectory (
        '02-Python-{0}-{1}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID
    )

    Start-Transcript -Path $pythonLogPath -Force | Out-Null
    $pythonTranscriptStarted = $true
}
catch {
    Write-Host "설치 로그를 시작하지 못했습니다: $($_.Exception.Message)" -ForegroundColor Yellow
}

# CP949 환경에서도 Python 출력과 패키지 설치 로그가 UTF-8로 처리되도록 합니다.
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

Write-Step "Python $PythonVersion 설치 상태 확인"

Refresh-ProcessPath
$pythonExecutable = Resolve-PythonExecutable

if ($pythonExecutable) {
    $fullVersion = & $pythonExecutable --version
    Write-Host "Python이 이미 설치되어 있습니다: $fullVersion" -ForegroundColor Green
    Write-Host "실행 파일: $pythonExecutable"
}
else {
    Write-Host "Python ${PythonVersion}을 찾을 수 없습니다." -ForegroundColor Yellow

    Install-Python
    Refresh-ProcessPath

    $pythonExecutable = Resolve-PythonExecutable

    if (-not $pythonExecutable) {
        throw @"
Python 설치는 완료되었지만 Python $PythonVersion 실행 파일을 찾지 못했습니다.

새 PowerShell 창을 연 뒤 이 스크립트를 다시 실행하세요.
"@
    }

    $fullVersion = & $pythonExecutable --version
    Write-Host "Python 설치 완료: $fullVersion" -ForegroundColor Green
    Write-Host "실행 파일: $pythonExecutable"
}

Write-Step 'Python 및 Scripts 경로 등록'

$pythonDirectory = Split-Path -Parent $pythonExecutable
$scriptsDirectory = Join-Path $pythonDirectory 'Scripts'

Add-DirectoryToUserPath -Directory $pythonDirectory
Add-DirectoryToUserPath -Directory $scriptsDirectory

Write-Step 'pip 설치 또는 복구'

Invoke-NativeCommand `
    -FilePath $pythonExecutable `
    -Arguments @(
        '-m',
        'ensurepip',
        '--upgrade',
        '--default-pip'
    )

if (-not $SkipPipUpgrade) {
    Write-Step 'pip, setuptools, wheel 업데이트'

    try {
        Invoke-NativeCommand `
            -FilePath $pythonExecutable `
            -Arguments @(
                '-m',
                'pip',
                'install',
                '--upgrade',
                'pip',
                'setuptools',
                'wheel'
            )
    }
    catch {
        Write-Host 'Python과 pip 설치는 완료되었지만 선택적 패키지 업데이트에 실패했습니다.' `
            -ForegroundColor Yellow
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        Write-Host '네트워크 또는 프록시를 확인한 뒤 나중에 다음 명령을 실행할 수 있습니다:' `
            -ForegroundColor Yellow
        Write-Host "`"$pythonExecutable`" -m pip install --upgrade pip setuptools wheel"
    }
}
else {
    Write-Host ''
    Write-Host '-SkipPipUpgrade 옵션으로 pip 패키지 업데이트를 생략했습니다.' `
        -ForegroundColor Yellow
}

Write-Step '최종 설치 결과'

$pythonVersionResult = (& $pythonExecutable --version 2>&1).Trim()
$pipVersionResult = (& $pythonExecutable -m pip --version 2>&1).Trim()

Write-Host "Python : $pythonVersionResult" -ForegroundColor Green
Write-Host "pip    : $pipVersionResult" -ForegroundColor Green
Write-Host "경로   : $pythonExecutable" -ForegroundColor Green
Write-Host ''
Write-Host '새 터미널부터 python 및 pip 명령을 바로 사용할 수 있습니다.' `
    -ForegroundColor Green

if ($pythonTranscriptStarted) {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    $pythonTranscriptStarted = $false
}
