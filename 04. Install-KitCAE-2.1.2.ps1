#requires -Version 5.1
<#
.SYNOPSIS
    NVIDIA Omniverse Kit-CAE v2.1.2를 복제, 빌드하고 바탕화면 바로가기를 생성합니다.

.DESCRIPTION
    기본 작업:
    1. https://github.com/NVIDIA-Omniverse/kit-cae 저장소를 복제합니다.
    2. v2.1.2 태그를 detached HEAD 상태로 체크아웃합니다.
    3. repo.bat build -r 명령으로 릴리스 빌드를 수행합니다.
    4. VTK 지원을 위해 repo.bat pip_download를 수행합니다.
    5. 다음 바탕화면 바로가기를 생성합니다.
       - CAE KIT          : repo.bat launch -n omni.cae.kit
       - CAE KIT with VTK : repo.bat launch -n omni.cae_vtk.kit
    6. CAE KIT을 한 번 실행합니다.

    기본 설치 위치:
    %USERPROFILE%\kit-cae

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File ".\04. Install-KitCAE-2.1.2.ps1"

.EXAMPLE
    # 설치 폴더 변경
    powershell.exe -ExecutionPolicy Bypass -File ".\04. Install-KitCAE-2.1.2.ps1" `
        -InstallDir C:\NVIDIA\kit-cae

.EXAMPLE
    # VTK 선택적 패키지 설치 생략
    powershell.exe -ExecutionPolicy Bypass -File ".\04. Install-KitCAE-2.1.2.ps1" `
        -SkipOptionalDependencies

.EXAMPLE
    # 설치 후 CAE KIT 자동 실행 생략
    powershell.exe -ExecutionPolicy Bypass -File ".\04. Install-KitCAE-2.1.2.ps1" `
        -NoLaunch
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'kit-cae'),

    [Parameter()]
    [switch]$SkipOptionalDependencies,

    [Parameter()]
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryUrl = 'https://github.com/NVIDIA-Omniverse/kit-cae.git'
$RepositoryName = 'NVIDIA-Omniverse/kit-cae'
$TargetTag = 'v2.1.2'

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')

    $pathParts = @($machinePath, $userPath) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $env:Path = $pathParts -join ';'

    $commonGitPaths = @(
        (Join-Path $env:ProgramFiles 'Git\cmd'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd')
    )

    if (${env:ProgramFiles(x86)}) {
        $commonGitPaths += Join-Path ${env:ProgramFiles(x86)} 'Git\cmd'
    }

    foreach ($gitPath in $commonGitPaths) {
        if (
            (Test-Path -LiteralPath $gitPath -PathType Container) -and
            (($env:Path -split ';') -notcontains $gitPath)
        ) {
            $env:Path = "$gitPath;$env:Path"
        }
    }
}

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-GitLfsAvailable {
    try {
        & git.exe lfs version *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Get-VisualStudioCppInstallation {
    $vswhereCandidates = @()

    if (${env:ProgramFiles(x86)}) {
        $vswhereCandidates += Join-Path ${env:ProgramFiles(x86)} `
            'Microsoft Visual Studio\Installer\vswhere.exe'
    }

    if ($env:ProgramFiles) {
        $vswhereCandidates += Join-Path $env:ProgramFiles `
            'Microsoft Visual Studio\Installer\vswhere.exe'
    }

    $vswhere = $vswhereCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1

    if (-not $vswhere) {
        return $null
    }

    $installationPath = & $vswhere `
        -latest `
        -products '*' `
        -version '[16.0,19.0)' `
        -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' `
        -property installationPath

    if ($LASTEXITCODE -ne 0 -or -not $installationPath) {
        return $null
    }

    return ($installationPath | Select-Object -First 1).Trim()
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string[]]$Arguments = @(),

        [Parameter()]
        [string]$WorkingDirectory
    )

    $previousLocation = $null

    try {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $previousLocation = Get-Location
            Set-Location -LiteralPath $WorkingDirectory
        }

        & $FilePath @Arguments

        if ($LASTEXITCODE -ne 0) {
            throw "'$FilePath $($Arguments -join ' ')' 실행에 실패했습니다. 종료 코드: $LASTEXITCODE"
        }
    }
    finally {
        if ($null -ne $previousLocation) {
            Set-Location -LiteralPath $previousLocation
        }
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter()]
        [string]$WorkingDirectory
    )

    Invoke-NativeCommand `
        -FilePath 'git.exe' `
        -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory
}

function Get-GitOutput {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter()]
        [string]$WorkingDirectory
    )

    $previousLocation = $null

    try {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $previousLocation = Get-Location
            Set-Location -LiteralPath $WorkingDirectory
        }

        $output = & git.exe @Arguments 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "'git $($Arguments -join ' ')' 실행에 실패했습니다.`n$($output -join [Environment]::NewLine)"
        }

        return ($output -join [Environment]::NewLine).Trim()
    }
    finally {
        if ($null -ne $previousLocation) {
            Set-Location -LiteralPath $previousLocation
        }
    }
}

function Invoke-RepoCommand {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$RepositoryDirectory
    )

    $repoBat = Join-Path $RepositoryDirectory 'repo.bat'

    if (-not (Test-Path -LiteralPath $repoBat -PathType Leaf)) {
        throw "repo.bat를 찾을 수 없습니다: $repoBat"
    }

    # 한국어 Windows에서 Python 기본 인코딩이 CP949로 선택되는 문제를 방지합니다.
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'

    $quotedRepoBat = '"' + $repoBat + '"'
    $commandText = "chcp 65001 > nul && call $quotedRepoBat $($Arguments -join ' ')"
    $previousLocation = Get-Location

    try {
        Set-Location -LiteralPath $RepositoryDirectory
        & $env:ComSpec /d /s /c $commandText

        if ($LASTEXITCODE -ne 0) {
            throw "repo.bat $($Arguments -join ' ') 실행에 실패했습니다. 종료 코드: $LASTEXITCODE"
        }
    }
    finally {
        Set-Location -LiteralPath $previousLocation
    }
}

function Assert-CleanRepository {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryDirectory
    )

    $status = Get-GitOutput `
        -Arguments @('status', '--porcelain') `
        -WorkingDirectory $RepositoryDirectory

    $scriptOwnedFiles = @(
        '?? _launch_omni.cae.kit.cmd'
        '?? _launch_omni.cae_vtk.kit.cmd'
    )

    $unexpectedChanges = @(
        $status -split '\r?\n' |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                $_ -notin $scriptOwnedFiles
            }
    )

    if ($unexpectedChanges.Count -gt 0) {
        throw @"
기존 Kit-CAE 폴더에 커밋되지 않은 변경 사항이 있습니다.

폴더:
$RepositoryDirectory

작업 내용을 커밋하거나 백업한 뒤 다시 실행하세요.
이 스크립트는 기존 변경 사항을 강제로 삭제하지 않습니다.

감지된 변경 사항:
$($unexpectedChanges -join [Environment]::NewLine)
"@
    }
}

function Get-NormalizedGitRemoteUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    $normalizedUrl = $Url.Trim().ToLowerInvariant()
    $normalizedUrl = $normalizedUrl -replace '^git@github\.com:', 'https://github.com/'
    $normalizedUrl = $normalizedUrl -replace '\.git/?$', ''

    return $normalizedUrl.TrimEnd('/')
}

function Set-KitCaeTag {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryDirectory
    )

    Assert-CleanRepository -RepositoryDirectory $RepositoryDirectory

    $originUrl = Get-GitOutput `
        -Arguments @('remote', 'get-url', 'origin') `
        -WorkingDirectory $RepositoryDirectory

    $expectedRemote = Get-NormalizedGitRemoteUrl -Url $RepositoryUrl
    $actualRemote = Get-NormalizedGitRemoteUrl -Url $originUrl

    if ($expectedRemote -ne $actualRemote) {
        throw @"
기존 폴더의 origin 저장소가 Kit-CAE 저장소와 다릅니다.

기대 저장소:
$RepositoryUrl

현재 origin:
$originUrl

다른 -InstallDir 경로를 지정하거나 기존 폴더를 확인하세요.
"@
    }

    Write-Host "태그를 가져옵니다: $TargetTag"

    Invoke-Git `
        -Arguments @(
            'fetch',
            'origin',
            "--force",
            "refs/tags/${TargetTag}:refs/tags/${TargetTag}"
        ) `
        -WorkingDirectory $RepositoryDirectory

    Invoke-Git `
        -Arguments @('checkout', '--detach', $TargetTag) `
        -WorkingDirectory $RepositoryDirectory
}

function New-KitCaeLauncher {
    param(
        [Parameter(Mandatory)]
        [string]$KitName,

        [Parameter(Mandatory)]
        [string]$RepositoryDirectory
    )

    $safeKitName = $KitName -replace '[^a-zA-Z0-9._-]', '_'
    $launcherPath = Join-Path $RepositoryDirectory "_launch_${safeKitName}.cmd"

    # %~dp0를 사용하므로 사용자 경로에 공백이 있어도 안전합니다.
    # 내용은 ASCII 문자만 사용하여 CMD 파일 자체의 인코딩 문제도 방지합니다.
    $launcherContent = @"
@echo off
setlocal
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
chcp 65001 > nul
cd /d "%~dp0"
call "%~dp0repo.bat" launch -n $KitName
set "KIT_CAE_EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %KIT_CAE_EXIT_CODE%
"@

    [IO.File]::WriteAllText(
        $launcherPath,
        $launcherContent,
        [Text.Encoding]::ASCII
    )

    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw "실행용 CMD 파일 생성에 실패했습니다: $launcherPath"
    }

    return $launcherPath
}

function New-KitCaeShortcut {
    param(
        [Parameter(Mandatory)]
        [string]$ShortcutName,

        [Parameter(Mandatory)]
        [string]$KitName,

        [Parameter(Mandatory)]
        [string]$RepositoryDirectory
    )

    $desktopDirectory = [Environment]::GetFolderPath('Desktop')

    if ([string]::IsNullOrWhiteSpace($desktopDirectory)) {
        throw '바탕화면 경로를 확인할 수 없습니다.'
    }

    $launcherPath = New-KitCaeLauncher `
        -KitName $KitName `
        -RepositoryDirectory $RepositoryDirectory

    $shortcutPath = Join-Path $desktopDirectory "$ShortcutName.lnk"

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)

    $shortcut.TargetPath = $env:ComSpec
    $shortcut.Arguments = '/d /s /c ""{0}""' -f $launcherPath
    $shortcut.WorkingDirectory = $RepositoryDirectory
    $shortcut.Description = "$ShortcutName - $KitName"
    $shortcut.WindowStyle = 1

    $kitExeCandidates = @(
        (Join-Path $RepositoryDirectory '_build\windows-x86_64\release\kit\kit.exe'),
        (Join-Path $RepositoryDirectory '_build\windows-x86_64\release\kit.exe')
    )

    $kitExecutable = $kitExeCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1

    if ($kitExecutable) {
        $shortcut.IconLocation = "$kitExecutable,0"
    }
    else {
        $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,220"
    }

    $shortcut.Save()

    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        throw "바로가기 생성에 실패했습니다: $shortcutPath"
    }

    return $shortcutPath
}

function Start-KitCae {
    param(
        [Parameter(Mandatory)]
        [string]$KitName,

        [Parameter(Mandatory)]
        [string]$RepositoryDirectory
    )

    $launcherPath = New-KitCaeLauncher `
        -KitName $KitName `
        -RepositoryDirectory $RepositoryDirectory

    $arguments = '/d /s /c ""{0}""' -f $launcherPath

    Start-Process `
        -FilePath $env:ComSpec `
        -ArgumentList $arguments `
        -WorkingDirectory $RepositoryDirectory
}

if ($env:OS -ne 'Windows_NT') {
    throw '이 스크립트는 Windows에서만 실행할 수 있습니다.'
}

Refresh-ProcessPath

Write-Step '필수 프로그램 확인'

if (-not (Test-CommandAvailable 'git.exe')) {
    throw @"
Git을 찾을 수 없습니다.

먼저 Git과 Git LFS 설치 스크립트를 실행하거나 Git for Windows를 설치한 뒤
새 PowerShell 창에서 이 스크립트를 다시 실행하세요.
"@
}

$gitVersion = (& git.exe --version).Trim()
Write-Host "Git: $gitVersion" -ForegroundColor Green

$visualStudioPath = Get-VisualStudioCppInstallation

if (-not $visualStudioPath) {
    throw @"
Visual Studio 2019/2022/2026 C++ 빌드 도구를 찾을 수 없습니다.

Visual Studio Installer에서 다음 워크로드를 설치하세요.
- Desktop development with C++
- Windows 10 또는 Windows 11 SDK

설치 후 이 스크립트를 다시 실행하세요.
"@
}

Write-Host "Visual Studio C++ 도구: $visualStudioPath" -ForegroundColor Green

$resolvedInstallDir = [Environment]::ExpandEnvironmentVariables($InstallDir)
$resolvedInstallDir = [IO.Path]::GetFullPath($resolvedInstallDir)
$installParent = Split-Path -Parent $resolvedInstallDir

Write-Step 'Kit-CAE 저장소 준비'

Write-Host "저장소 : $RepositoryName"
Write-Host "태그   : $TargetTag"
Write-Host "경로   : $resolvedInstallDir"

if (-not (Test-Path -LiteralPath $installParent -PathType Container)) {
    New-Item -ItemType Directory -Path $installParent -Force | Out-Null
}

if (Test-Path -LiteralPath $resolvedInstallDir) {
    if (Test-Path -LiteralPath (Join-Path $resolvedInstallDir '.git') -PathType Container) {
        Write-Host '기존 Kit-CAE 저장소를 재사용합니다.' -ForegroundColor Yellow
        Set-KitCaeTag -RepositoryDirectory $resolvedInstallDir
    }
    else {
        $existingItems = @(Get-ChildItem -LiteralPath $resolvedInstallDir -Force)

        if ($existingItems.Count -gt 0) {
            throw @"
설치 경로가 이미 존재하지만 Kit-CAE Git 저장소가 아니며 폴더가 비어 있지 않습니다.

경로:
$resolvedInstallDir

다른 -InstallDir 경로를 지정하거나 기존 폴더를 이동한 뒤 다시 실행하세요.
"@
        }

        Write-Host '비어 있는 기존 폴더에 Kit-CAE 저장소를 복제합니다.'

        Invoke-Git `
            -Arguments @(
                'clone',
                '--branch', $TargetTag,
                '--single-branch',
                $RepositoryUrl,
                $resolvedInstallDir
            )

        Set-KitCaeTag -RepositoryDirectory $resolvedInstallDir
    }
}
else {
    Write-Host 'Kit-CAE 저장소를 복제합니다.'

    Invoke-Git `
        -Arguments @(
            'clone',
            '--branch', $TargetTag,
            '--single-branch',
            $RepositoryUrl,
            $resolvedInstallDir
        )

    Set-KitCaeTag -RepositoryDirectory $resolvedInstallDir
}

$currentCommit = Get-GitOutput `
    -Arguments @('rev-parse', '--short', 'HEAD') `
    -WorkingDirectory $resolvedInstallDir

$currentTag = Get-GitOutput `
    -Arguments @('describe', '--tags', '--exact-match', 'HEAD') `
    -WorkingDirectory $resolvedInstallDir

Write-Host "체크아웃 완료: $currentTag ($currentCommit)" -ForegroundColor Green

if (Test-GitLfsAvailable) {
    Write-Step 'Git LFS 파일 확인'

    Invoke-Git `
        -Arguments @('lfs', 'install') `
        -WorkingDirectory $resolvedInstallDir

    Invoke-Git `
        -Arguments @('lfs', 'pull') `
        -WorkingDirectory $resolvedInstallDir
}
else {
    Write-Host ''
    Write-Host 'Git LFS 명령을 찾지 못했습니다. 저장소에 LFS 파일이 있으면 빌드가 실패할 수 있습니다.' -ForegroundColor Yellow
}

Write-Step 'Kit-CAE 릴리스 빌드'

Invoke-RepoCommand `
    -Arguments @('build', '-r') `
    -RepositoryDirectory $resolvedInstallDir

Write-Host '릴리스 빌드가 완료되었습니다.' -ForegroundColor Green

if (-not $SkipOptionalDependencies) {
    Write-Step 'VTK 및 선택적 Python 의존성 설치'

    Invoke-RepoCommand `
        -Arguments @('pip_download') `
        -RepositoryDirectory $resolvedInstallDir

    Write-Host 'VTK 선택적 의존성 설치가 완료되었습니다.' -ForegroundColor Green
}
else {
    Write-Host ''
    Write-Host '-SkipOptionalDependencies 옵션으로 VTK 선택적 의존성 설치를 생략했습니다.' -ForegroundColor Yellow
    Write-Host 'CAE KIT with VTK 실행 시 VTK 기능이 비활성화될 수 있습니다.' -ForegroundColor Yellow
}

Write-Step '바탕화면 바로가기 생성'

$basicShortcut = New-KitCaeShortcut `
    -ShortcutName 'CAE KIT' `
    -KitName 'omni.cae.kit' `
    -RepositoryDirectory $resolvedInstallDir

$vtkShortcut = New-KitCaeShortcut `
    -ShortcutName 'CAE KIT with VTK' `
    -KitName 'omni.cae_vtk.kit' `
    -RepositoryDirectory $resolvedInstallDir

Write-Host "생성 완료: $basicShortcut" -ForegroundColor Green
Write-Host "생성 완료: $vtkShortcut" -ForegroundColor Green

if (-not $NoLaunch) {
    Write-Step 'CAE KIT 최초 실행'

    Start-KitCae `
        -KitName 'omni.cae.kit' `
        -RepositoryDirectory $resolvedInstallDir

    Write-Host 'CAE KIT 실행을 시작했습니다.' -ForegroundColor Green
}
else {
    Write-Host ''
    Write-Host '-NoLaunch 옵션으로 최초 실행을 생략했습니다.' -ForegroundColor Yellow
}

Write-Step '완료'

Write-Host "설치 경로       : $resolvedInstallDir" -ForegroundColor Green
Write-Host "체크아웃 태그   : $currentTag" -ForegroundColor Green
Write-Host "CAE KIT         : $basicShortcut" -ForegroundColor Green
Write-Host "CAE KIT with VTK: $vtkShortcut" -ForegroundColor Green
