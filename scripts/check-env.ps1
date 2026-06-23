param(
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Test-CommandAvailable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-CommandPath {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    return ""
}

function Test-SystemSpeech {
    try {
        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $voices = @($synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name })
        $synth.Dispose()
        return @{
            ok = $true
            voices = $voices
            message = "Windows 系统语音可用。"
        }
    } catch {
        return @{
            ok = $false
            voices = @()
            message = "Windows 系统语音不可用：$($_.Exception.Message)"
        }
    }
}

$root = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $root "config\appsettings.json"
$textApiReady = $false

if (Test-Path $configPath) {
    try {
        $config = Get-Content -Raw -Encoding UTF8 -Path $configPath | ConvertFrom-Json
        if ($config.api -and -not [string]::IsNullOrWhiteSpace($config.api.textEndpoint) -and -not [string]::IsNullOrWhiteSpace($config.api.textApiKey)) {
            $textApiReady = $true
        }
    } catch {}
}

$speech = Test-SystemSpeech
$result = [pscustomobject]@{
    checkedAt = (Get-Date).ToString("s")
    root = $root
    checks = @(
        [pscustomobject]@{
            name = "PowerShell"
            required = $true
            ok = $true
            value = $PSVersionTable.PSVersion.ToString()
            message = "本地服务运行环境可用。"
        },
        [pscustomobject]@{
            name = "Windows 系统语音"
            required = $false
            ok = [bool]$speech.ok
            value = ($speech.voices -join ", ")
            message = $speech.message
        },
        [pscustomobject]@{
            name = "ffmpeg"
            required = $false
            ok = (Test-CommandAvailable "ffmpeg")
            value = (Get-CommandPath "ffmpeg")
            message = "用于输出 mp4、字幕烧录和音视频混合。缺失时仍可生成脚本、音频、字幕和渲染计划。"
        },
        [pscustomobject]@{
            name = "AI 文本接口"
            required = $false
            ok = $textApiReady
            value = $configPath
            message = "未配置时使用本地规则生成脚本。"
        },
        [pscustomobject]@{
            name = "winget"
            required = $false
            ok = (Test-CommandAvailable "winget")
            value = (Get-CommandPath "winget")
            message = "可用于自动安装 ffmpeg。"
        },
        [pscustomobject]@{
            name = "choco"
            required = $false
            ok = (Test-CommandAvailable "choco")
            value = (Get-CommandPath "choco")
            message = "可用于自动安装 ffmpeg。"
        }
    )
    installCommands = @(
        ".\scripts\install-deps.ps1",
        ".\scripts\install-deps.ps1 -Install -Ffmpeg -Manager winget",
        ".\scripts\install-deps.ps1 -Install -Ffmpeg -Manager choco"
    )
}

if ($Json) {
    $result | ConvertTo-Json -Depth 10
    exit 0
}

Write-Host "运行环境检查"
Write-Host "根目录：$($result.root)"
Write-Host ""

foreach ($check in $result.checks) {
    $status = if ($check.ok) { "OK" } else { "MISSING" }
    $required = if ($check.required) { "必需" } else { "可选" }
    Write-Host ("[{0}] {1} ({2})" -f $status, $check.name, $required)
    if (-not [string]::IsNullOrWhiteSpace($check.value)) {
        Write-Host "  $($check.value)"
    }
    Write-Host "  $($check.message)"
}

Write-Host ""
Write-Host "安装脚本默认不会安装任何内容。查看计划："
Write-Host "  .\scripts\install-deps.ps1"
Write-Host "显式安装 ffmpeg："
Write-Host "  .\scripts\install-deps.ps1 -Install -Ffmpeg -Manager winget"

