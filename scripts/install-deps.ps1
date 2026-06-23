param(
    [switch]$Install,
    [switch]$Ffmpeg,
    [ValidateSet("auto", "winget", "choco")]
    [string]$Manager = "auto"
)

$ErrorActionPreference = "Stop"

function Test-CommandAvailable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Resolve-Manager {
    param([string]$Requested)

    if ($Requested -ne "auto") {
        return $Requested
    }

    if (Test-CommandAvailable "winget") {
        return "winget"
    }

    if (Test-CommandAvailable "choco") {
        return "choco"
    }

    return "manual"
}

if (-not $Ffmpeg) {
    $Ffmpeg = $true
}

$resolvedManager = Resolve-Manager $Manager
$tasks = New-Object System.Collections.Generic.List[object]

if ($Ffmpeg) {
    $installed = Test-CommandAvailable "ffmpeg"
    $command = switch ($resolvedManager) {
        "winget" { "winget install --id Gyan.FFmpeg -e --source winget" }
        "choco" { "choco install ffmpeg -y" }
        default { "手动安装：https://www.gyan.dev/ffmpeg/builds/ ，并将 bin 目录加入 PATH。" }
    }

    $tasks.Add([pscustomobject]@{
        name = "ffmpeg"
        installed = $installed
        manager = $resolvedManager
        command = $command
        required = $false
        purpose = "视频合成、音频混合、字幕烧录、输出 mp4。"
    })
}

Write-Host "依赖安装计划"
Write-Host "Install 参数：$Install"
Write-Host "包管理器：$resolvedManager"
Write-Host ""

foreach ($task in $tasks) {
    $status = if ($task.installed) { "已安装" } else { "未安装" }
    Write-Host "$($task.name)：$status"
    Write-Host "用途：$($task.purpose)"
    Write-Host "命令：$($task.command)"
    Write-Host ""
}

if (-not $Install) {
    Write-Host "未传入 -Install，当前只显示计划，不会安装任何内容。"
    Write-Host "如需安装 ffmpeg，请显式运行："
    if ($resolvedManager -eq "manual") {
        Write-Host "  请按上方手动安装说明操作。"
    } else {
        Write-Host "  .\scripts\install-deps.ps1 -Install -Ffmpeg -Manager $resolvedManager"
    }
    exit 0
}

foreach ($task in $tasks) {
    if ($task.installed) {
        Write-Host "$($task.name) 已安装，跳过。"
        continue
    }

    if ($task.manager -eq "manual") {
        Write-Host "$($task.name) 需要手动安装：$($task.command)"
        continue
    }

    Write-Host "开始安装 $($task.name)..."
    if ($task.manager -eq "winget") {
        winget install --id Gyan.FFmpeg -e --source winget
    } elseif ($task.manager -eq "choco") {
        choco install ffmpeg -y
    }

    if ($LASTEXITCODE -ne 0) {
        throw "$($task.name) 安装失败，退出码：$LASTEXITCODE"
    }
}

Write-Host "安装流程结束。请重新打开终端或刷新 PATH 后再运行 .\scripts\check-env.ps1。"

