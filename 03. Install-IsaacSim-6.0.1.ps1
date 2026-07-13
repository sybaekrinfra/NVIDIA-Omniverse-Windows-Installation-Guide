#requires -Version 5.1
<#
.SYNOPSIS
    NVIDIA Isaac Sim 6.0.1 Standalone을 다운로드하고 설치합니다.

.DESCRIPTION
    - 관리자 권한이 없으면 자동으로 권한 상승을 요청합니다.
    - Isaac Sim ZIP 파일을 사용자 Downloads 폴더에 다운로드합니다.
    - C:\isaacsim 폴더에 압축을 해제합니다.
    - post_install.bat를 실행합니다.
    - 바탕화면에 Isaac Sim 바로가기를 생성합니다.
    - 기본적으로 설치 완료 후 isaac-sim.bat를 실행합니다.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File ".\03. Install-IsaacSim-6.0.1.ps1"

.EXAMPLE
    # 설치 후 Isaac Sim을 바로 실행하지 않음
    powershell.exe -ExecutionPolicy Bypass -File ".\03. Install-IsaacSim-6.0.1.ps1" -NoLaunch

.EXAMPLE
    # 기존 다운로드 ZIP 파일을 삭제하고 다시 다운로드
    powershell.exe -ExecutionPolicy Bypass -File ".\03. Install-IsaacSim-6.0.1.ps1" -Redownload
#>

[CmdletBinding()]
param(
    [switch]$NoLaunch,
    [switch]$Redownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$IsaacSimVersion = '6.0.1'
$DownloadUrl = 'https://downloads.isaacsim.nvidia.com/isaac-sim-standalone-6.0.1-windows-x86_64.zip'
$ArchiveName = 'isaac-sim-standalone-6.0.1-windows-x86_64.zip'
$InstallDir = 'C:\isaacsim'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)

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

function Restart-AsAdministrator {
    Write-Host 'C:\isaacsim 설치를 위해 관리자 권한을 요청합니다.' -ForegroundColor Yellow

    $powerShellExe = (Get-Process -Id $PID).Path
    $argumentList = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', "`"$PSCommandPath`""
    )

    if ($NoLaunch) {
        $argumentList += '-NoLaunch'
    }

    if ($Redownload) {
        $argumentList += '-Redownload'
    }

    Start-Process `
        -FilePath $powerShellExe `
        -ArgumentList $argumentList `
        -Verb RunAs

    exit
}

function Get-DownloadsFolder {
    # Windows의 Downloads 알려진 폴더 경로를 레지스트리에서 확인합니다.
    $knownFolderName = '{374DE290-123F-4565-9164-39C4925E467B}'
    $registryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'

    try {
        $path = (Get-ItemProperty -Path $registryPath -Name $knownFolderName).$knownFolderName
        $expandedPath = [Environment]::ExpandEnvironmentVariables($path)

        if (-not [string]::IsNullOrWhiteSpace($expandedPath)) {
            return $expandedPath
        }
    }
    catch {
        # 레지스트리에서 찾지 못하면 일반적인 경로를 사용합니다.
    }

    return (Join-Path $env:USERPROFILE 'Downloads')
}

function Format-ByteSize {
    param(
        [Parameter(Mandatory)]
        [double]$Bytes
    )

    if ($Bytes -ge 1GB) {
        return ('{0:N2} GB' -f ($Bytes / 1GB))
    }

    if ($Bytes -ge 1MB) {
        return ('{0:N1} MB' -f ($Bytes / 1MB))
    }

    if ($Bytes -ge 1KB) {
        return ('{0:N1} KB' -f ($Bytes / 1KB))
    }

    return ('{0:N0} B' -f $Bytes)
}

function Start-BitsDownloadWithProgress {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )

    $activity = "NVIDIA Isaac Sim $IsaacSimVersion 다운로드"
    $bitsJob = $null
    $transferCompleted = $false
    $startedAt = Get-Date
    $previousProgressPreference = $ProgressPreference

    # 스크립트 전역에서는 불필요한 진행 메시지를 숨기지만,
    # 이 BITS 작업의 진행률은 사용자에게 표시합니다.
    $ProgressPreference = 'Continue'

    try {
        $bitsJob = Start-BitsTransfer `
            -Source $Url `
            -Destination $Destination `
            -DisplayName "NVIDIA Isaac Sim $IsaacSimVersion" `
            -Description 'NVIDIA Isaac Sim standalone ZIP download' `
            -Asynchronous `
            -ErrorAction Stop

        while (-not $transferCompleted) {
            $bitsJob = Get-BitsTransfer `
                -JobId $bitsJob.JobId `
                -ErrorAction Stop

            $state = [string]$bitsJob.JobState
            $bytesTransferred = [double]$bitsJob.BytesTransferred
            $bytesTotalValue = $bitsJob.BytesTotal
            $hasKnownTotal = (
                $bytesTotalValue -gt 0 -and
                $bytesTotalValue -ne [UInt64]::MaxValue
            )

            $elapsedSeconds = ((Get-Date) - $startedAt).TotalSeconds
            $bytesPerSecond = 0.0

            if ($elapsedSeconds -gt 0 -and $bytesTransferred -gt 0) {
                $bytesPerSecond = $bytesTransferred / $elapsedSeconds
            }

            $speedText = if ($bytesPerSecond -gt 0) {
                "$(Format-ByteSize -Bytes $bytesPerSecond)/s"
            }
            else {
                '속도 계산 중'
            }

            $stateText = switch ($state) {
                'Queued' { '대기 중' }
                'Connecting' { '서버 연결 중' }
                'Transferring' { '전송 중' }
                'TransientError' { '일시 오류 - 자동 재시도 중' }
                'Suspended' { '일시 중지 - 다시 시작 중' }
                'Transferred' { '전송 완료 처리 중' }
                default { $state }
            }

            if ($hasKnownTotal) {
                $percentage = [Math]::Floor(
                    ($bytesTransferred * 100.0) / [double]$bytesTotalValue
                )
                $percentage = [Math]::Max(0, [Math]::Min(99, $percentage))

                $status = '{0}% | {1} / {2} | {3} | {4}' -f `
                    $percentage,
                    (Format-ByteSize -Bytes $bytesTransferred),
                    (Format-ByteSize -Bytes ([double]$bytesTotalValue)),
                    $speedText,
                    $stateText

                Write-Progress `
                    -Id 1 `
                    -Activity $activity `
                    -Status $status `
                    -PercentComplete $percentage
            }
            else {
                $status = '{0} 다운로드됨 | {1} | {2}' -f `
                    (Format-ByteSize -Bytes $bytesTransferred),
                    $speedText,
                    $stateText

                Write-Progress `
                    -Id 1 `
                    -Activity $activity `
                    -Status $status `
                    -PercentComplete -1
            }

            switch ($state) {
                'Transferred' {
                    Write-Progress `
                        -Id 1 `
                        -Activity $activity `
                        -Status '100% | 다운로드 완료 처리 중' `
                        -PercentComplete 100

                    Complete-BitsTransfer `
                        -BitsJob $bitsJob `
                        -ErrorAction Stop

                    $transferCompleted = $true
                    $bitsJob = $null
                    continue
                }

                'Error' {
                    throw "BITS 다운로드 오류: $($bitsJob.ErrorDescription)"
                }

                'Canceled' {
                    throw 'BITS 다운로드 작업이 취소되었습니다.'
                }

                'Acknowledged' {
                    throw 'BITS 다운로드 작업이 예상보다 일찍 종료되었습니다.'
                }

                'Suspended' {
                    Resume-BitsTransfer `
                        -BitsJob $bitsJob `
                        -Asynchronous `
                        -ErrorAction Stop | Out-Null
                }

                'Queued' { }
                'Connecting' { }
                'Transferring' { }
                'TransientError' { }

                default {
                    throw "알 수 없는 BITS 작업 상태입니다: $state"
                }
            }

            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        if (-not $transferCompleted -and $null -ne $bitsJob) {
            try {
                $remainingJob = Get-BitsTransfer `
                    -JobId $bitsJob.JobId `
                    -ErrorAction SilentlyContinue

                if ($null -ne $remainingJob) {
                    Remove-BitsTransfer `
                        -BitsJob $remainingJob `
                        -Confirm:$false `
                        -ErrorAction SilentlyContinue
                }
            }
            catch {
                # 원래 다운로드 오류를 보존하기 위해 정리 오류는 무시합니다.
            }
        }

        Write-Progress -Id 1 -Activity $activity -Completed
        $ProgressPreference = $previousProgressPreference
    }
}

function Download-File {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )

    $partialFile = "$Destination.part"

    if (Test-Path $partialFile) {
        Remove-Item -LiteralPath $partialFile -Force
    }

    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Write-Host 'BITS를 사용해 다운로드합니다. 진행률이 아래에 표시됩니다.'
            Start-BitsDownloadWithProgress `
                -Url $Url `
                -Destination $partialFile
        }
        elseif (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            Write-Host 'curl.exe를 사용해 다운로드합니다.'
            & curl.exe `
                --fail `
                --location `
                --retry 3 `
                --output $partialFile `
                $Url

            if ($LASTEXITCODE -ne 0) {
                throw "curl.exe 다운로드 실패. 종료 코드: $LASTEXITCODE"
            }
        }
        else {
            Write-Host 'Invoke-WebRequest를 사용해 다운로드합니다.'
            Invoke-WebRequest `
                -Uri $Url `
                -OutFile $partialFile `
                -UseBasicParsing
        }

        if (-not (Test-Path $partialFile)) {
            throw '다운로드 파일이 생성되지 않았습니다.'
        }

        $downloadedFile = Get-Item -LiteralPath $partialFile

        if ($downloadedFile.Length -lt 1MB) {
            throw "다운로드 파일 크기가 비정상적으로 작습니다: $($downloadedFile.Length) bytes"
        }

        Move-Item `
            -LiteralPath $partialFile `
            -Destination $Destination `
            -Force
    }
    catch {
        if (Test-Path $partialFile) {
            Remove-Item -LiteralPath $partialFile -Force
        }

        throw
    }
}

function Expand-IsaacSimArchive {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$Destination
    )

    if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
        Write-Host 'Windows tar.exe를 사용해 ZIP 파일을 압축 해제합니다.'

        # ZIP 파일이므로 gzip 옵션(-z)을 사용하지 않습니다.
        & tar.exe -xf $ArchivePath -C $Destination

        if ($LASTEXITCODE -ne 0) {
            throw "압축 해제에 실패했습니다. tar.exe 종료 코드: $LASTEXITCODE"
        }

        return
    }

    Write-Host 'Expand-Archive를 사용해 ZIP 파일을 압축 해제합니다.'
    Expand-Archive `
        -LiteralPath $ArchivePath `
        -DestinationPath $Destination `
        -Force
}

function Invoke-BatchFile {
    param(
        [Parameter(Mandatory)][string]$BatchFile,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    if (-not (Test-Path -LiteralPath $BatchFile -PathType Leaf)) {
        throw "배치 파일을 찾을 수 없습니다: $BatchFile"
    }

    Push-Location $WorkingDirectory

    try {
        & $env:ComSpec /d /c "`"$BatchFile`""

        if ($LASTEXITCODE -ne 0) {
            throw "$BatchFile 실행에 실패했습니다. 종료 코드: $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

function New-IsaacSimShortcut {
    param(
        [Parameter(Mandatory)][string]$TargetBatchFile,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    $desktopPath = [Environment]::GetFolderPath('Desktop')

    if ([string]::IsNullOrWhiteSpace($desktopPath)) {
        throw '바탕화면 경로를 확인할 수 없습니다.'
    }

    $shortcutPath = Join-Path $desktopPath "NVIDIA Isaac Sim $IsaacSimVersion.lnk"
    $wshShell = New-Object -ComObject WScript.Shell
    $shortcut = $wshShell.CreateShortcut($shortcutPath)

    # cmd.exe를 통해 실행하면 배치 파일 경로의 공백과 연결 프로그램 문제를 피할 수 있습니다.
    $shortcut.TargetPath = $env:ComSpec
    $shortcut.Arguments = "/d /c `"`"$TargetBatchFile`"`""
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = "Isaac Sim $IsaacSimVersion"
    $shortcut.WindowStyle = 1

    $kitExecutable = Join-Path $WorkingDirectory 'kit\kit.exe'

    if (Test-Path -LiteralPath $kitExecutable -PathType Leaf) {
        $shortcut.IconLocation = "$kitExecutable,0"
    }
    else {
        $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,220"
    }

    $shortcut.Save()

    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        throw '바탕화면 바로가기 생성에 실패했습니다.'
    }

    return $shortcutPath
}

if ($env:OS -ne 'Windows_NT') {
    throw '이 스크립트는 Windows에서만 실행할 수 있습니다.'
}

if (-not (Test-IsAdministrator)) {
    Restart-AsAdministrator
}

$downloadsDir = Get-DownloadsFolder
$archivePath = Join-Path $downloadsDir $ArchiveName
$postInstallPath = Join-Path $InstallDir 'post_install.bat'
$isaacSimBatchPath = Join-Path $InstallDir 'isaac-sim.bat'

Write-Step '다운로드 및 설치 경로 확인'

New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

Write-Host "다운로드 URL : $DownloadUrl"
Write-Host "ZIP 파일     : $archivePath"
Write-Host "설치 폴더    : $InstallDir"

Write-Step 'Isaac Sim ZIP 파일 준비'

if ($Redownload -and (Test-Path -LiteralPath $archivePath)) {
    Write-Host '기존 ZIP 파일을 삭제합니다.' -ForegroundColor Yellow
    Remove-Item -LiteralPath $archivePath -Force
}

if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
    $existingArchive = Get-Item -LiteralPath $archivePath

    if ($existingArchive.Length -ge 1MB) {
        Write-Host '기존 다운로드 파일을 사용합니다.' -ForegroundColor Green
    }
    else {
        Write-Host '기존 파일의 크기가 비정상적이므로 다시 다운로드합니다.' -ForegroundColor Yellow
        Remove-Item -LiteralPath $archivePath -Force
        Download-File -Url $DownloadUrl -Destination $archivePath
    }
}
else {
    Download-File -Url $DownloadUrl -Destination $archivePath
}

$archiveInfo = Get-Item -LiteralPath $archivePath
Write-Host ('다운로드 완료: {0:N2} GB' -f ($archiveInfo.Length / 1GB)) -ForegroundColor Green

Write-Step 'Isaac Sim 압축 해제'

Expand-IsaacSimArchive `
    -ArchivePath $archivePath `
    -Destination $InstallDir

if (-not (Test-Path -LiteralPath $postInstallPath -PathType Leaf)) {
    throw @"
압축 해제 후 post_install.bat를 찾을 수 없습니다.

예상 경로:
$postInstallPath

ZIP 내부에 최상위 폴더가 추가되어 있는지 확인하세요.
"@
}

if (-not (Test-Path -LiteralPath $isaacSimBatchPath -PathType Leaf)) {
    throw "압축 해제 후 isaac-sim.bat를 찾을 수 없습니다: $isaacSimBatchPath"
}

Write-Step 'Isaac Sim 후처리 설치 실행'

Invoke-BatchFile `
    -BatchFile $postInstallPath `
    -WorkingDirectory $InstallDir

Write-Host 'post_install.bat 실행이 완료되었습니다.' -ForegroundColor Green

Write-Step '바탕화면 바로가기 생성'

$shortcutPath = New-IsaacSimShortcut `
    -TargetBatchFile $isaacSimBatchPath `
    -WorkingDirectory $InstallDir

Write-Host "바로가기 생성 완료: $shortcutPath" -ForegroundColor Green

if (-not $NoLaunch) {
    Write-Step 'Isaac Sim 실행'

    Start-Process `
        -FilePath $env:ComSpec `
        -ArgumentList @('/d', '/c', "`"$isaacSimBatchPath`"") `
        -WorkingDirectory $InstallDir

    Write-Host 'Isaac Sim 실행을 시작했습니다.' -ForegroundColor Green
}
else {
    Write-Host ''
    Write-Host '-NoLaunch 옵션으로 인해 Isaac Sim 자동 실행을 생략했습니다.' -ForegroundColor Yellow
}

Write-Step '완료'

Write-Host "설치 위치 : $InstallDir" -ForegroundColor Green
Write-Host "실행 파일 : $isaacSimBatchPath" -ForegroundColor Green
Write-Host "바로가기 : $shortcutPath" -ForegroundColor Green
