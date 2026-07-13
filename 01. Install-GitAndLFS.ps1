#requires -Version 5.1
<#
.SYNOPSIS
    Windows에서 Git과 Git LFS 설치 여부를 확인하고, 없는 경우 자동으로 설치합니다.

.DESCRIPTION
    1. Git 명령을 확인합니다.
    2. Git이 없으면 WinGet 또는 Chocolatey를 사용해 Git for Windows를 설치합니다.
    3. Git LFS 명령을 확인합니다.
    4. Git LFS가 없으면 WinGet 또는 Chocolatey를 사용해 별도로 설치합니다.
    5. git lfs install을 실행하고 최종 버전을 출력합니다.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File ".\01. Install-GitAndLFS.ps1"

.EXAMPLE
    pwsh.exe -File ".\01. Install-GitAndLFS.ps1"
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')

    $paths = @($machinePath, $userPath) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $env:Path = $paths -join ';'

    # Git 설치 직후 환경 변수 반영이 늦는 경우를 대비한 일반적인 설치 경로
    $gitPaths = @(
        (Join-Path $env:ProgramFiles 'Git\cmd'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd')
    )

    if (${env:ProgramFiles(x86)}) {
        $gitPaths += Join-Path ${env:ProgramFiles(x86)} 'Git\cmd'
    }

    foreach ($path in $gitPaths) {
        if ((Test-Path $path) -and (($env:Path -split ';') -notcontains $path)) {
            $env:Path = "$path;$env:Path"
        }
    }
}

function Test-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)

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

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @()
    )

    & $FilePath @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "'$FilePath $($Arguments -join ' ')' 실행에 실패했습니다. 종료 코드: $LASTEXITCODE"
    }
}

function Install-WithWinget {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$DisplayName
    )

    Write-Host "$DisplayName 설치를 시작합니다. WinGet 패키지: $PackageId"

    Invoke-NativeCommand -FilePath 'winget.exe' -Arguments @(
        'install',
        '--id', $PackageId,
        '--exact',
        '--source', 'winget',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
}

function Install-WithChocolatey {
    param(
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(Mandatory)][string]$DisplayName
    )

    Write-Host "$DisplayName 설치를 시작합니다. Chocolatey 패키지: $PackageName"

    Invoke-NativeCommand -FilePath 'choco.exe' -Arguments @(
        'install',
        $PackageName,
        '--yes',
        '--no-progress'
    )
}

function Install-Package {
    param(
        [Parameter(Mandatory)][string]$WingetId,
        [Parameter(Mandatory)][string]$ChocolateyName,
        [Parameter(Mandatory)][string]$DisplayName
    )

    $wingetAvailable = Test-CommandAvailable 'winget.exe'
    $wingetUsable = $false

    if ($wingetAvailable) {
        $wingetUsable = Test-WingetUsable
    }

    if ($wingetAvailable -and -not $wingetUsable) {
        Write-Host 'winget.exe 별칭은 있지만 WinGet을 정상 실행할 수 없어 다른 설치 방법을 확인합니다.' `
            -ForegroundColor Yellow
    }

    if ($wingetUsable) {
        try {
            Install-WithWinget -PackageId $WingetId -DisplayName $DisplayName
            return
        }
        catch {
            Write-Host "WinGet 설치에 실패했습니다: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host 'Chocolatey를 사용할 수 있는지 확인합니다.' -ForegroundColor Yellow
        }
    }

    if (Test-ChocolateyUsable) {
        Install-WithChocolatey -PackageName $ChocolateyName -DisplayName $DisplayName
        return
    }

    throw @"
${DisplayName}을 자동 설치할 수 없습니다.
    정상적으로 실행되는 WinGet 또는 Chocolatey가 필요합니다.

권장 방법:
- Microsoft App Installer를 설치하여 WinGet을 활성화한 뒤 이 스크립트를 다시 실행하세요.
"@
}

if ($env:OS -ne 'Windows_NT') {
    throw '이 스크립트는 Windows에서만 실행할 수 있습니다.'
}

Write-Step 'Git 설치 상태 확인'

Refresh-ProcessPath

if (Test-CommandAvailable 'git') {
    $gitVersion = (& git --version).Trim()
    Write-Host "Git이 이미 설치되어 있습니다: $gitVersion" -ForegroundColor Green
}
else {
    Write-Host 'Git이 설치되어 있지 않습니다.' -ForegroundColor Yellow
    Install-Package `
        -WingetId 'Git.Git' `
        -ChocolateyName 'git' `
        -DisplayName 'Git for Windows'

    Refresh-ProcessPath

    if (-not (Test-CommandAvailable 'git')) {
        throw 'Git 설치가 완료되었지만 현재 PowerShell에서 git 명령을 찾지 못했습니다. 터미널을 다시 연 뒤 스크립트를 재실행하세요.'
    }

    $gitVersion = (& git --version).Trim()
    Write-Host "Git 설치 완료: $gitVersion" -ForegroundColor Green
}

Write-Step 'Git LFS 설치 상태 확인'

$lfsInstalled = $false

try {
    & git lfs version *> $null
    $lfsInstalled = ($LASTEXITCODE -eq 0)
}
catch {
    $lfsInstalled = $false
}

if ($lfsInstalled) {
    $lfsVersion = (& git lfs version).Trim()
    Write-Host "Git LFS가 이미 설치되어 있습니다: $lfsVersion" -ForegroundColor Green
}
else {
    Write-Host 'Git LFS가 설치되어 있지 않습니다.' -ForegroundColor Yellow

    Install-Package `
        -WingetId 'GitHub.GitLFS' `
        -ChocolateyName 'git-lfs' `
        -DisplayName 'Git LFS'

    Refresh-ProcessPath

    try {
        & git lfs version *> $null
        $lfsInstalled = ($LASTEXITCODE -eq 0)
    }
    catch {
        $lfsInstalled = $false
    }

    if (-not $lfsInstalled) {
        throw 'Git LFS 설치가 완료되었지만 git lfs 명령을 찾지 못했습니다. 터미널을 다시 연 뒤 스크립트를 재실행하세요.'
    }

    $lfsVersion = (& git lfs version).Trim()
    Write-Host "Git LFS 설치 완료: $lfsVersion" -ForegroundColor Green
}

Write-Step 'Git LFS 사용자 설정 적용'

Invoke-NativeCommand -FilePath 'git' -Arguments @('lfs', 'install')

Write-Step '설치 결과'

$gitVersion = (& git --version).Trim()
$lfsVersion = (& git lfs version).Trim()

Write-Host "Git     : $gitVersion" -ForegroundColor Green
Write-Host "Git LFS : $lfsVersion" -ForegroundColor Green
Write-Host ''
Write-Host 'Git과 Git LFS를 사용할 준비가 완료되었습니다.' -ForegroundColor Green
