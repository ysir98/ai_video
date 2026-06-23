param(
    [int]$Port = 8765,
    [switch]$SelfTest,
    [switch]$SelfTestVoice
)

$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot
$WwwRoot = Join-Path $Root "www"
$ProjectsRoot = Join-Path $Root "projects"
$ConfigRoot = Join-Path $Root "config"
$ConfigPath = Join-Path $ConfigRoot "appsettings.json"
$ScriptsRoot = Join-Path $Root "scripts"
$VoiceProfilesRoot = Join-Path $Root "voice_profiles"

New-Item -ItemType Directory -Force -Path $ProjectsRoot, $ConfigRoot, $VoiceProfilesRoot | Out-Null

if (-not (Test-Path $ConfigPath)) {
    $example = Join-Path $ConfigRoot "appsettings.example.json"
    if (Test-Path $example) {
        Copy-Item $example $ConfigPath
    }
}

function Read-AppConfig {
    if (Test-Path $ConfigPath) {
        return Get-Content -Raw -Encoding UTF8 -Path $ConfigPath | ConvertFrom-Json
    }
    return [pscustomobject]@{}
}

function Save-AppConfig {
    param($Config)

    New-Item -ItemType Directory -Force -Path $ConfigRoot | Out-Null
    Set-Content -Encoding UTF8 -Path $ConfigPath -Value ($Config | ConvertTo-Json -Depth 20)
    return Read-AppConfig
}

# 需要脱敏的密钥字段，避免明文回传到前端。
$script:SecretFields = @("textApiKey", "ttsApiKey", "voiceCloneApiKey", "videoApiKey")
$script:MaskedSecretValue = "********"

function Get-ConfigForClient {
    # 返回给前端展示用的配置：已设置的密钥替换为掩码，不泄露明文。
    $config = Read-AppConfig
    if ($config.api) {
        foreach ($field in $script:SecretFields) {
            $value = [string]$config.api.$field
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $config.api.$field = $script:MaskedSecretValue
            }
        }
    }
    return $config
}

function Merge-ConfigSecrets {
    param($Incoming)
    # 保存时若密钥字段仍是掩码，说明用户未修改，保留磁盘上的原值。
    $existing = Read-AppConfig
    if ($Incoming.api -and $existing.api) {
        foreach ($field in $script:SecretFields) {
            $incomingValue = [string]$Incoming.api.$field
            if ($incomingValue -eq $script:MaskedSecretValue) {
                $Incoming.api.$field = $existing.api.$field
            }
        }
    }
    return $Incoming
}

function ConvertFrom-ModelJson {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        throw "模型返回内容为空。"
    }

    $text = $Content.Trim()

    # 剥离 Markdown 代码围栏，例如 ```json ... ``` 或 ``` ... ```
    if ($text.StartsWith('```')) {
        $text = [regex]::Replace($text, '^```[a-zA-Z]*\s*', '')
        $text = [regex]::Replace($text, '\s*```$', '')
        $text = $text.Trim()
    }

    # 若模型在 JSON 前后附带说明文字，截取首个 { 到最后一个 } 的区间。
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -ge 0 -and $end -gt $start) {
        $text = $text.Substring($start, $end - $start + 1)
    }

    return $text | ConvertFrom-Json
}

function Test-CommandAvailable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-SystemSpeech {
    try {
        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $voices = @($synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name })
        $synth.Dispose()
        return @{
            available = $true
            voices = $voices
            message = "Windows 系统语音可用。"
        }
    } catch {
        return @{
            available = $false
            voices = @()
            message = "Windows 系统语音不可用：$($_.Exception.Message)"
        }
    }
}

function Get-InstallPlan {
    $winget = Test-CommandAvailable "winget"
    $choco = Test-CommandAvailable "choco"
    $manager = if ($winget) { "winget" } elseif ($choco) { "choco" } else { "manual" }

    $ffmpegCommand = switch ($manager) {
        "winget" { ".\scripts\install-deps.ps1 -Install -Ffmpeg -Manager winget" }
        "choco" { ".\scripts\install-deps.ps1 -Install -Ffmpeg -Manager choco" }
        default { "请手动安装 ffmpeg 并加入 PATH，然后重新启动本工具。" }
    }

    return @{
        packageManager = $manager
        winget = $winget
        choco = $choco
        commands = @{
            checkOnly = ".\scripts\check-env.ps1"
            installFfmpeg = $ffmpegCommand
        }
        note = "本程序不会自动安装依赖。只有用户在终端显式运行带 -Install 的脚本时才会安装。"
    }
}

function Split-RequestPath {
    param([string]$Path)

    $parts = $Path -split "\?", 2
    $route = $parts[0]
    $query = @{}
    if ($parts.Count -gt 1) {
        foreach ($pair in ($parts[1] -split "&")) {
            if ([string]::IsNullOrWhiteSpace($pair)) {
                continue
            }
            $kv = $pair -split "=", 2
            $key = [System.Uri]::UnescapeDataString($kv[0])
            $value = if ($kv.Count -gt 1) { [System.Uri]::UnescapeDataString($kv[1]) } else { "" }
            $query[$key] = $value
        }
    }
    return [pscustomobject]@{
        Route = $route
        Query = $query
    }
}

function Get-ProjectSummary {
    param([string]$ProjectDir)

    $projectPath = Join-Path $ProjectDir "project.json"
    $scriptPath = Join-Path $ProjectDir "script\script.json"
    $renderPlanPath = Join-Path $ProjectDir "output\render_plan.json"
    $assetPlanPath = Join-Path $ProjectDir "video\asset_plan.json"
    $subtitlePath = Join-Path $ProjectDir "output\subtitles.srt"
    $audioPath = Join-Path $ProjectDir "audio\voice.wav"

    $project = $null
    if (Test-Path $projectPath) {
        try { $project = Get-Content -Raw -Encoding UTF8 -Path $projectPath | ConvertFrom-Json } catch {}
    }

    $summary = [pscustomobject]@{
        projectId = Split-Path $ProjectDir -Leaf
        projectDir = $ProjectDir
        projectName = if ($project -and $project.projectName) { $project.projectName } else { Split-Path $ProjectDir -Leaf }
        generationMode = if ($project -and $project.generationMode) { $project.generationMode } else { "" }
        title = if ($project -and $project.script -and $project.script.title) { $project.script.title } else { "" }
        createdAt = if ($project -and $project.createdAt) { $project.createdAt } else { "" }
        files = @{
            project = (Test-Path $projectPath)
            script = (Test-Path $scriptPath)
            renderPlan = (Test-Path $renderPlanPath)
            assetPlan = (Test-Path $assetPlanPath)
            subtitles = (Test-Path $subtitlePath)
            audio = (Test-Path $audioPath)
            video = (Test-Path (Join-Path $ProjectDir "output\final.mp4"))
        }
    }
    return $summary
}

function Get-ProjectDetails {
    param([string]$ProjectDir)

    $files = @{
        project = Join-Path $ProjectDir "project.json"
        script = Join-Path $ProjectDir "script\script.json"
        scriptMarkdown = Join-Path $ProjectDir "script\script.md"
        assetPlan = Join-Path $ProjectDir "video\asset_plan.json"
        renderPlan = Join-Path $ProjectDir "output\render_plan.json"
        subtitles = Join-Path $ProjectDir "output\subtitles.srt"
        audio = Join-Path $ProjectDir "audio\voice.wav"
        audioText = Join-Path $ProjectDir "audio\voice.txt"
        video = Join-Path $ProjectDir "output\final.mp4"
        log = Join-Path $ProjectDir "logs\task.log"
    }

    $data = [pscustomobject]@{
        summary = Get-ProjectSummary -ProjectDir $ProjectDir
        files = @{}
    }

    foreach ($key in $files.Keys) {
        $path = $files[$key]
        if (Test-Path $path) {
            try {
                if ($path.EndsWith(".json") -or $path.EndsWith(".md") -or $path.EndsWith(".txt") -or $path.EndsWith(".srt") -or $path.EndsWith(".log")) {
                    $content = Get-Content -Raw -Encoding UTF8 -Path $path
                    $data.files[$key] = @{
                        path = $path
                        content = $content
                    }
                } else {
                    $data.files[$key] = @{
                        path = $path
                        exists = $true
                    }
                }
            } catch {
                $data.files[$key] = @{
                    path = $path
                    error = $_.Exception.Message
                }
            }
        } else {
            $data.files[$key] = @{
                path = $path
                exists = $false
            }
        }
    }

    return $data
}

function New-VoiceProfileId {
    return "voice_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")
}

function Get-VoiceProfiles {
    $profiles = @()
    Get-ChildItem -Directory -Path $VoiceProfilesRoot -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object {
        $profilePath = Join-Path $_.FullName "profile.json"
        if (Test-Path $profilePath) {
            try {
                $profile = Get-Content -Raw -Encoding UTF8 -Path $profilePath | ConvertFrom-Json
                $profiles += $profile
            } catch {}
        }
    }
    return $profiles
}

function Save-VoiceProfile {
    param($Payload)

    $name = [string]$Payload.name
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "音色名称不能为空。"
    }

    $fileName = [string]$Payload.fileName
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        throw "语音样本文件名不能为空。"
    }

    $base64 = [string]$Payload.fileBase64
    if ([string]::IsNullOrWhiteSpace($base64)) {
        throw "语音样本内容不能为空。"
    }

    $extension = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()
    if ($extension -notin @(".wav", ".mp3", ".m4a", ".aac", ".flac", ".ogg")) {
        throw "不支持的语音样本格式。"
    }

    $profileId = New-VoiceProfileId
    $profileDir = Join-Path $VoiceProfilesRoot $profileId
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null

    $samplePath = Join-Path $profileDir ("sample" + $extension)
    $bytes = [Convert]::FromBase64String($base64)
    [System.IO.File]::WriteAllBytes($samplePath, $bytes)

    $profile = [pscustomobject]@{
        id = $profileId
        name = $name
        type = "clone"
        provider = "local_sample_pending_clone_provider"
        sampleFileName = $fileName
        samplePath = $samplePath
        note = "当前版本已保存语音样本和音色档案；接入真实语音克隆服务后可用该样本创建 voiceId。"
        createdAt = (Get-Date).ToString("s")
    }

    $profilePath = Join-Path $profileDir "profile.json"
    Set-Content -Encoding UTF8 -Path $profilePath -Value ($profile | ConvertTo-Json -Depth 10)
    return $profile
}

function Invoke-EnvironmentCheck {
    $speech = Test-SystemSpeech
    $ffmpegCommand = Get-Command ffmpeg -ErrorAction SilentlyContinue
    $config = Read-AppConfig
    $textApiReady = $false
    if ($config.api -and -not [string]::IsNullOrWhiteSpace($config.api.textEndpoint) -and -not [string]::IsNullOrWhiteSpace($config.api.textApiKey)) {
        $textApiReady = $true
    }

    $checks = @(
        @{
            id = "powershell"
            name = "PowerShell"
            required = $true
            ok = $true
            version = $PSVersionTable.PSVersion.ToString()
            message = "本地服务运行环境可用。"
        },
        @{
            id = "system_speech"
            name = "Windows 系统语音"
            required = $false
            ok = [bool]$speech.available
            version = ""
            message = $speech.message
        },
        @{
            id = "ffmpeg"
            name = "ffmpeg"
            required = $false
            ok = [bool]$ffmpegCommand
            version = if ($ffmpegCommand) { $ffmpegCommand.Source } else { "" }
            message = if ($ffmpegCommand) { "检测到 ffmpeg，可生成基础 mp4。" } else { "未检测到 ffmpeg。仍可生成脚本、音频、字幕和渲染计划。" }
        },
        @{
            id = "text_api"
            name = "AI 文本接口"
            required = $false
            ok = $textApiReady
            version = if ($textApiReady) { [string]$config.api.textModel } else { "" }
            message = if ($textApiReady) { "已配置文本接口，将优先调用 AI 生成脚本。" } else { "未配置文本接口，将使用本地规则生成脚本。" }
        },
        @{
            id = "node"
            name = "Node.js"
            required = $false
            ok = (Test-CommandAvailable "node")
            version = ""
            message = "当前 MVP 不依赖 Node.js。"
        },
        @{
            id = "python"
            name = "Python"
            required = $false
            ok = (Test-CommandAvailable "python")
            version = ""
            message = "当前 MVP 不依赖 Python。"
        }
    )

    return @{
        ok = $true
        checkedAt = (Get-Date).ToString("s")
        root = $Root
        projectsRoot = $ProjectsRoot
        configPath = $ConfigPath
        checks = $checks
        speechVoices = $speech.voices
        installPlan = Get-InstallPlan
    }
}

function New-ProjectId {
    return "project_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")
}

function Split-TextSegments {
    param([string]$Text)

    $clean = ($Text -replace "`r`n", "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return @()
    }

    $sentences = [regex]::Split($clean, "(?<=[。！？.!?])\s+|`n+")
    $segments = New-Object System.Collections.Generic.List[string]
    $buffer = ""

    foreach ($sentence in $sentences) {
        $part = $sentence.Trim()
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }

        if ($part.Length -gt 180) {
            if ($buffer.Length -gt 0) {
                $segments.Add($buffer.Trim())
                $buffer = ""
            }
            for ($i = 0; $i -lt $part.Length; $i += 180) {
                $length = [Math]::Min(180, $part.Length - $i)
                $segments.Add($part.Substring($i, $length))
            }
            continue
        }

        if (($buffer.Length + $part.Length) -gt 180 -and $buffer.Length -gt 0) {
            $segments.Add($buffer.Trim())
            $buffer = $part
        } else {
            if ($buffer.Length -gt 0) {
                $buffer += " "
            }
            $buffer += $part
        }
    }

    if ($buffer.Length -gt 0) {
        $segments.Add($buffer.Trim())
    }

    if ($segments.Count -eq 0) {
        for ($i = 0; $i -lt $clean.Length; $i += 180) {
            $length = [Math]::Min(180, $clean.Length - $i)
            $segments.Add($clean.Substring($i, $length))
        }
    }

    return $segments.ToArray()
}

function New-LocalScript {
    param(
        [string]$Text,
        [string]$Mode,
        [string]$Style
    )

    $segments = Split-TextSegments $Text
    $items = @()
    $index = 1
    $totalDuration = 0

    foreach ($segment in $segments) {
        $duration = [Math]::Max(4, [Math]::Ceiling($segment.Length / 4.0))
        $totalDuration += $duration
        $visual = if ($segment.Length -gt 70) { $segment.Substring(0, 70) } else { $segment }
        $items += [pscustomobject]@{
            index = $index
            voiceText = $segment
            subtitle = $segment
            visualPrompt = "围绕以下内容生成画面：$visual"
            duration = $duration
            sceneType = if ($Mode -eq "ai_video_only") { "ai_video" } else { "avatar" }
        }
        $index += 1
    }

    $titleSource = if ($Text.Length -gt 28) { $Text.Substring(0, 28) } else { $Text }
    return [pscustomobject]@{
        title = "AI 视频 - $titleSource"
        summary = if ($Text.Length -gt 120) { $Text.Substring(0, 120) } else { $Text }
        keywords = @()
        style = $Style
        estimatedDuration = $totalDuration
        segments = $items
    }
}

function Get-ModeName {
    param([string]$Mode)
    switch ($Mode) {
        "avatar_only" { "单数字人" }
        "ai_video_only" { "单 AI 创作视频" }
        "mixed_avatar_ai_video" { "混合数字人与 AI 视频" }
        "animated_avatar" { "数字人动画形象" }
        default { $Mode }
    }
}

function New-ModeAssetPlan {
    param(
        [string]$Mode,
        $Script,
        $Options
    )

    $segments = @()
    foreach ($segment in $Script.segments) {
        $sceneMode = switch ($Mode) {
            "avatar_only" { "avatar_talking" }
            "ai_video_only" { "ai_video_scene" }
            "mixed_avatar_ai_video" { "avatar_overlay_ai_scene" }
            "animated_avatar" { "animated_avatar_talking" }
            default { "avatar_talking" }
        }

        $segments += [pscustomobject]@{
            index = $segment.index
            duration = $segment.duration
            sceneMode = $sceneMode
            voiceText = $segment.voiceText
            subtitle = $segment.subtitle
            visualPrompt = $segment.visualPrompt
            requiredAssets = switch ($Mode) {
                "avatar_only" { @("voice_audio", "avatar_video", "background", "subtitle") }
                "ai_video_only" { @("voice_audio", "ai_video_scene", "subtitle", "background_music") }
                "mixed_avatar_ai_video" { @("voice_audio", "avatar_alpha_video", "ai_video_scene", "subtitle", "background_music") }
                "animated_avatar" { @("voice_audio", "animated_avatar_video", "background", "subtitle") }
                default { @("voice_audio", "subtitle") }
            }
            status = "pending_provider_integration"
        }
    }

    return [pscustomobject]@{
        generationMode = $Mode
        modeName = Get-ModeName $Mode
        createdAt = (Get-Date).ToString("s")
        providers = @{
            text = "configured_or_local_fallback"
            tts = "windows_system_speech_or_external_tts"
            voiceClone = "pending"
            avatar = "pending"
            aiVideo = "pending"
            composer = "ffmpeg_optional"
        }
        renderStrategy = switch ($Mode) {
            "avatar_only" { "Use avatar talking video over fixed background, then mix voice and subtitles." }
            "ai_video_only" { "Generate AI video scenes from prompts, concatenate scenes, then mix voice and subtitles." }
            "mixed_avatar_ai_video" { "Generate AI video scenes as background, overlay avatar video, then mix voice and subtitles." }
            "animated_avatar" { "Generate animated avatar talking scenes, compose with background, voice and subtitles." }
            default { "Generate base video from available assets." }
        }
        options = $Options
        segments = $segments
    }
}

function Invoke-TextModel {
    param(
        [string]$Text,
        [string]$Mode,
        [string]$Style,
        $Config
    )

    $api = $Config.api
    if ($null -eq $api -or [string]::IsNullOrWhiteSpace($api.textEndpoint) -or [string]::IsNullOrWhiteSpace($api.textApiKey)) {
        return New-LocalScript -Text $Text -Mode $Mode -Style $Style
    }

    $prompt = @"
请把用户文本整理成适合视频生成的 JSON。只返回 JSON，不要返回 Markdown。
字段要求：
title, summary, keywords, estimatedDuration, segments。
segments 每项包含 index, voiceText, subtitle, visualPrompt, duration, sceneType。
视频模式：$Mode
内容风格：$Style
用户文本：
$Text
"@

    try {
        $body = @{
            model = $api.textModel
            messages = @(
                @{ role = "system"; content = "你是视频脚本策划助手，输出严格 JSON。" },
                @{ role = "user"; content = $prompt }
            )
            temperature = 0.7
        } | ConvertTo-Json -Depth 10

        $headers = @{
            Authorization = "Bearer $($api.textApiKey)"
            "Content-Type" = "application/json"
        }

        $response = Invoke-RestMethod -Method Post -Uri $api.textEndpoint -Headers $headers -Body $body
        $content = $response.choices[0].message.content
        $parsed = ConvertFrom-ModelJson -Content $content

        # 校验关键字段，缺失则回退本地脚本，避免后续按 segments 处理时报错。
        if ($null -eq $parsed -or $null -eq $parsed.segments -or @($parsed.segments).Count -eq 0) {
            return New-LocalScript -Text $Text -Mode $Mode -Style $Style
        }
        return $parsed
    } catch {
        return New-LocalScript -Text $Text -Mode $Mode -Style $Style
    }
}

function Format-SrtTime {
    param([double]$Seconds)

    $ts = [TimeSpan]::FromSeconds($Seconds)
    return "{0:00}:{1:00}:{2:00},{3:000}" -f [Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds, $ts.Milliseconds
}

function Write-Srt {
    param($Script, [string]$Path)

    $lines = New-Object System.Collections.Generic.List[string]
    $cursor = 0.0
    foreach ($segment in $Script.segments) {
        $start = $cursor
        $duration = [double]$segment.duration
        $end = $cursor + $duration
        $lines.Add([string]$segment.index)
        $lines.Add(("{0} --> {1}" -f (Format-SrtTime $start), (Format-SrtTime $end)))
        $lines.Add([string]$segment.subtitle)
        $lines.Add("")
        $cursor = $end
    }

    Set-Content -Encoding UTF8 -Path $Path -Value ($lines -join "`r`n")
}

function Write-ScriptMarkdown {
    param($Script, [string]$Path)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# $($Script.title)")
    $lines.Add("")
    $lines.Add("## 摘要")
    $lines.Add("")
    $lines.Add([string]$Script.summary)
    $lines.Add("")
    $lines.Add("## 分段脚本")
    $lines.Add("")
    foreach ($segment in $Script.segments) {
        $lines.Add("### $($segment.index)")
        $lines.Add("")
        $lines.Add("- 口播：$($segment.voiceText)")
        $lines.Add("- 字幕：$($segment.subtitle)")
        $lines.Add("- 画面：$($segment.visualPrompt)")
        $lines.Add("- 时长：$($segment.duration) 秒")
        $lines.Add("")
    }

    Set-Content -Encoding UTF8 -Path $Path -Value ($lines -join "`r`n")
}

function New-VoiceAudio {
    param(
        [string]$Text,
        [string]$Path,
        $VoiceConfig
    )

    $textPath = [System.IO.Path]::ChangeExtension($Path, ".txt")
    Set-Content -Encoding UTF8 -Path $textPath -Value $Text

    if ($Text.Length -gt 1500) {
        return @{
            success = $false
            skipped = $true
            textPath = $textPath
            message = "文本超过 1500 字，已跳过系统 TTS，未生成 voice.wav（避免长时间阻塞）。配音文本已保存到 voice.txt，可接入外部 TTS 生成完整音频。"
        }
    }

    try {
        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        if ($VoiceConfig -and -not [string]::IsNullOrWhiteSpace($VoiceConfig.name)) {
            try {
                $synth.SelectVoice($VoiceConfig.name)
            } catch {}
        }
        if ($VoiceConfig -and $null -ne $VoiceConfig.rate) {
            $rate = [Math]::Max(-10, [Math]::Min(10, [int]$VoiceConfig.rate))
            $synth.Rate = $rate
        }
        if ($VoiceConfig -and $null -ne $VoiceConfig.volume) {
            $volume = [Math]::Max(0, [Math]::Min(100, [int]$VoiceConfig.volume))
            $synth.Volume = $volume
        }

        $synth.SetOutputToWaveFile($Path)
        $synth.Speak($Text)
        $synth.Dispose()
        return @{
            success = $true
            skipped = $false
            textPath = $textPath
            message = "已生成系统 TTS 音频。"
        }
    } catch {
        return @{
            success = $false
            skipped = $false
            textPath = $textPath
            message = "系统 TTS 不可用，已保存配音文本。$($_.Exception.Message)"
        }
    }
}

function Get-VideoSize {
    param([string]$Ratio, [string]$Resolution)

    if ($Ratio -eq "16:9") {
        if ($Resolution -eq "720p") { return "1280x720" }
        return "1920x1080"
    }
    if ($Ratio -eq "1:1") {
        if ($Resolution -eq "720p") { return "720x720" }
        return "1080x1080"
    }
    if ($Resolution -eq "720p") { return "720x1280" }
    return "1080x1920"
}

function Invoke-ComposeVideo {
    param(
        [string]$ProjectDir,
        $ProjectConfig,
        $Script,
        [string]$AudioPath,
        [string]$SrtPath
    )

    $outputDir = Join-Path $ProjectDir "output"
    $finalPath = Join-Path $outputDir "final.mp4"
    $duration = [Math]::Max(1, [double]$Script.estimatedDuration)
    $ratio = if ($ProjectConfig.video.ratio) { $ProjectConfig.video.ratio } else { "9:16" }
    $resolution = if ($ProjectConfig.video.resolution) { $ProjectConfig.video.resolution } else { "1080p" }
    $fps = if ($ProjectConfig.video.fps) { [int]$ProjectConfig.video.fps } else { 30 }
    $size = Get-VideoSize -Ratio $ratio -Resolution $resolution

    $plan = [pscustomobject]@{
        output = $finalPath
        size = $size
        fps = $fps
        duration = $duration
        audio = $AudioPath
        subtitles = $SrtPath
        mode = $ProjectConfig.generationMode
        note = "安装 ffmpeg 并重新生成后可输出 mp4。当前会保留音频、字幕和项目配置。"
    }
    $planPath = Join-Path $outputDir "render_plan.json"
    Set-Content -Encoding UTF8 -Path $planPath -Value ($plan | ConvertTo-Json -Depth 10)

    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($null -eq $ffmpeg) {
        return @{
            success = $false
            output = $null
            renderPlan = $planPath
            message = "未检测到 ffmpeg，已生成渲染计划、音频和字幕。"
        }
    }

    try {
        $colorInput = "color=c=0x111827:s=$($size):d=$($duration):r=$fps"
        $args = @(
            "-y",
            "-f", "lavfi",
            "-i", $colorInput,
            "-i", $AudioPath,
            "-shortest",
            "-c:v", "libx264",
            "-c:a", "aac",
            "-pix_fmt", "yuv420p",
            $finalPath
        )
        & $ffmpeg.Source @args | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "ffmpeg 退出码：$LASTEXITCODE"
        }
        return @{
            success = $true
            output = $finalPath
            renderPlan = $planPath
            message = "已生成基础 mp4。"
        }
    } catch {
        return @{
            success = $false
            output = $null
            renderPlan = $planPath
            message = "ffmpeg 合成失败：$($_.Exception.Message)"
        }
    }
}

function New-VideoProject {
    param($Payload)

    $text = [string]$Payload.text
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "文本内容不能为空。"
    }

    $config = Read-AppConfig
    $options = $Payload.options
    $projectId = New-ProjectId
    $projectDir = Join-Path $ProjectsRoot $projectId

    $dirs = @("input", "script", "audio", "voice_profiles", "image", "video", "output", "logs")
    foreach ($dir in $dirs) {
        New-Item -ItemType Directory -Force -Path (Join-Path $projectDir $dir) | Out-Null
    }

    $inputPath = Join-Path $projectDir "input\source.txt"
    Set-Content -Encoding UTF8 -Path $inputPath -Value $text

    $mode = if ($options.generationMode) { [string]$options.generationMode } else { "avatar_only" }
    $style = if ($options.style) { [string]$options.style } else { "知识口播" }
    if ($Payload.script) {
        $script = $Payload.script
    } else {
        $script = Invoke-TextModel -Text $text -Mode $mode -Style $style -Config $config
    }

    $scriptJsonPath = Join-Path $projectDir "script\script.json"
    $scriptMdPath = Join-Path $projectDir "script\script.md"
    Set-Content -Encoding UTF8 -Path $scriptJsonPath -Value ($script | ConvertTo-Json -Depth 30)
    Write-ScriptMarkdown -Script $script -Path $scriptMdPath

    $assetPlan = New-ModeAssetPlan -Mode $mode -Script $script -Options $options
    $assetPlanPath = Join-Path $projectDir "video\asset_plan.json"
    Set-Content -Encoding UTF8 -Path $assetPlanPath -Value ($assetPlan | ConvertTo-Json -Depth 30)

    $voiceText = (($script.segments | ForEach-Object { $_.voiceText }) -join "`r`n")
    $audioPath = Join-Path $projectDir "audio\voice.wav"
    $voiceResult = New-VoiceAudio -Text $voiceText -Path $audioPath -VoiceConfig $options.voice

    if ($options.voice -and $options.voice.profileId) {
        $sourceProfilePath = Join-Path (Join-Path $VoiceProfilesRoot ([string]$options.voice.profileId)) "profile.json"
        if (Test-Path $sourceProfilePath) {
            Copy-Item -Force -Path $sourceProfilePath -Destination (Join-Path $projectDir "voice_profiles\profile.json")
        }
    }

    $srtPath = Join-Path $projectDir "output\subtitles.srt"
    Write-Srt -Script $script -Path $srtPath

    $projectConfig = [pscustomobject]@{
        projectName = if ($options.projectName) { [string]$options.projectName } else { $projectId }
        inputFile = $inputPath
        generationMode = $mode
        script = @{
            title = $script.title
            summary = $script.summary
            segments = $script.segments
        }
        voice = $options.voice
        video = @{
            ratio = if ($options.ratio) { [string]$options.ratio } else { "9:16" }
            resolution = if ($options.resolution) { [string]$options.resolution } else { "1080p" }
            fps = if ($options.fps) { [int]$options.fps } else { 30 }
        }
        subtitle = @{
            enabled = $true
        }
        output = @{
            format = "mp4"
            path = Join-Path $projectDir "output"
        }
        createdAt = (Get-Date).ToString("s")
    }

    $projectJsonPath = Join-Path $projectDir "project.json"
    Set-Content -Encoding UTF8 -Path $projectJsonPath -Value ($projectConfig | ConvertTo-Json -Depth 30)

    $composeResult = Invoke-ComposeVideo -ProjectDir $projectDir -ProjectConfig $projectConfig -Script $script -AudioPath $audioPath -SrtPath $srtPath

    $logPath = Join-Path $projectDir "logs\task.log"
    $logLines = @(
        "project=$projectId",
        "mode=$mode",
        "script=$scriptJsonPath",
        "audio=$audioPath",
        "tts=$($voiceResult.message)",
        "compose=$($composeResult.message)"
    )
    Set-Content -Encoding UTF8 -Path $logPath -Value ($logLines -join "`r`n")

    return [pscustomobject]@{
        projectId = $projectId
        projectDir = $projectDir
        script = $script
        files = @{
            input = $inputPath
            scriptJson = $scriptJsonPath
            scriptMarkdown = $scriptMdPath
            assetPlan = $assetPlanPath
            audio = if (Test-Path $audioPath) { $audioPath } else { $null }
            subtitles = $srtPath
            project = $projectJsonPath
            renderPlan = $composeResult.renderPlan
            video = $composeResult.output
            log = $logPath
        }
        status = @{
            tts = $voiceResult
            compose = $composeResult
        }
    }
}

function Invoke-ProjectCompose {
    param([string]$ProjectId)

    if ($ProjectId -notmatch "^project_\d{8}_\d{6}$") {
        throw "项目 ID 格式无效。"
    }

    $projectDir = Join-Path $ProjectsRoot $ProjectId
    if (-not (Test-Path $projectDir)) {
        throw "项目不存在。"
    }

    $projectPath = Join-Path $projectDir "project.json"
    $scriptPath = Join-Path $projectDir "script\script.json"
    $audioPath = Join-Path $projectDir "audio\voice.wav"
    $srtPath = Join-Path $projectDir "output\subtitles.srt"

    if (-not (Test-Path $projectPath)) { throw "缺少 project.json。" }
    if (-not (Test-Path $scriptPath)) { throw "缺少 script.json。" }
    if (-not (Test-Path $srtPath)) { throw "缺少 subtitles.srt。" }

    $projectConfig = Get-Content -Raw -Encoding UTF8 -Path $projectPath | ConvertFrom-Json
    $script = Get-Content -Raw -Encoding UTF8 -Path $scriptPath | ConvertFrom-Json
    $composeResult = Invoke-ComposeVideo -ProjectDir $projectDir -ProjectConfig $projectConfig -Script $script -AudioPath $audioPath -SrtPath $srtPath

    $logPath = Join-Path $projectDir "logs\task.log"
    Add-Content -Encoding UTF8 -Path $logPath -Value ("recompose={0}" -f $composeResult.message)

    return [pscustomobject]@{
        projectId = $ProjectId
        projectDir = $projectDir
        compose = $composeResult
        details = Get-ProjectDetails -ProjectDir $projectDir
    }
}

function Get-ContentType {
    param([string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".html" { "text/html; charset=utf-8" }
        ".css" { "text/css; charset=utf-8" }
        ".js" { "application/javascript; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        ".svg" { "image/svg+xml" }
        ".png" { "image/png" }
        ".jpg" { "image/jpeg" }
        ".jpeg" { "image/jpeg" }
        default { "application/octet-stream" }
    }
}

function Read-HttpRequest {
    param($Stream)

    $buffer = New-Object byte[] 8192
    $headerBytes = New-Object System.Collections.Generic.List[byte]
    $headerEnd = -1
    $leftover = @()

    while ($headerEnd -lt 0) {
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) {
            break
        }

        for ($i = 0; $i -lt $read; $i++) {
            $headerBytes.Add($buffer[$i]) | Out-Null
            $count = $headerBytes.Count
            if ($count -ge 4) {
                if ($headerBytes[$count - 4] -eq 13 -and $headerBytes[$count - 3] -eq 10 -and $headerBytes[$count - 2] -eq 13 -and $headerBytes[$count - 1] -eq 10) {
                    $headerEnd = $count
                    if (($i + 1) -lt $read) {
                        $leftover = $buffer[($i + 1)..($read - 1)]
                    }
                    break
                }
            }
        }
    }

    if ($headerBytes.Count -eq 0) {
        return $null
    }

    $headerText = [System.Text.Encoding]::UTF8.GetString($headerBytes.ToArray(), 0, $headerEnd)
    $lines = $headerText -split "`r`n"
    $requestLine = $lines[0]
    $parts = $requestLine -split " "
    if ($parts.Count -lt 2) {
        throw "Invalid HTTP request line."
    }

    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $index = $line.IndexOf(":")
        if ($index -gt 0) {
            $name = $line.Substring(0, $index).Trim().ToLowerInvariant()
            $value = $line.Substring($index + 1).Trim()
            $headers[$name] = $value
        }
    }

    $contentLength = 0
    if ($headers.ContainsKey("content-length")) {
        [int]::TryParse($headers["content-length"], [ref]$contentLength) | Out-Null
    }

    $body = @($leftover)

    while ($body.Length -lt $contentLength) {
        $remaining = $contentLength - $body.Length
        $read = $Stream.Read($buffer, 0, [Math]::Min($buffer.Length, $remaining))
        if ($read -le 0) {
            break
        }
        $chunk = $buffer[0..($read - 1)]
        $body = @($body + $chunk)
    }

    return [pscustomobject]@{
        Method = $parts[0]
        Path = $parts[1]
        Headers = $headers
        BodyBytes = [byte[]]$body
    }
}

function Write-HttpResponse {
    param(
        $Stream,
        [int]$StatusCode,
        [string]$StatusText,
        [string]$ContentType,
        [byte[]]$BodyBytes
    )

    if ($null -eq $BodyBytes) {
        $BodyBytes = [byte[]]@()
    }

    $header = "HTTP/1.1 $StatusCode $StatusText`r`nContent-Type: $ContentType`r`nContent-Length: $($BodyBytes.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($BodyBytes.Length -gt 0) {
        $Stream.Write($BodyBytes, 0, $BodyBytes.Length)
    }
    $Stream.Flush()
}

function Handle-Request {
    param($Request)

    $parsed = Split-RequestPath $Request.Path
    $path = $parsed.Route
    $method = $Request.Method.ToUpperInvariant()

    if ($method -eq "GET" -and $path -eq "/api/health") {
        return @{
            status = 200
            type = "application/json; charset=utf-8"
            body = (Invoke-EnvironmentCheck | ConvertTo-Json -Depth 20)
        }
    }

    if ($method -eq "GET" -and $path -eq "/api/environment") {
        return @{
            status = 200
            type = "application/json; charset=utf-8"
            body = (Invoke-EnvironmentCheck | ConvertTo-Json -Depth 20)
        }
    }

    if ($method -eq "GET" -and $path -eq "/api/config") {
        return @{
            status = 200
            type = "application/json; charset=utf-8"
            body = (@{ ok = $true; config = Get-ConfigForClient; path = $ConfigPath } | ConvertTo-Json -Depth 20)
        }
    }

    if ($method -eq "POST" -and $path -eq "/api/config") {
        $requestObject = [System.Text.Encoding]::UTF8.GetString($Request.BodyBytes) | ConvertFrom-Json
        $merged = Merge-ConfigSecrets $requestObject
        Save-AppConfig $merged | Out-Null
        return @{
            status = 200
            type = "application/json; charset=utf-8"
            body = (@{ ok = $true; config = Get-ConfigForClient; path = $ConfigPath } | ConvertTo-Json -Depth 20)
        }
    }

    if ($method -eq "GET" -and $path -eq "/api/projects") {
        $projects = Get-ChildItem -Directory -Path $ProjectsRoot -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object { Get-ProjectSummary -ProjectDir $_.FullName }
        return @{
            status = 200
            type = "application/json; charset=utf-8"
            body = (@{ projects = $projects } | ConvertTo-Json -Depth 10)
        }
    }

    if ($method -eq "GET" -and $path -eq "/api/voice-profiles") {
        return @{
            status = 200
            type = "application/json; charset=utf-8"
            body = (@{ profiles = Get-VoiceProfiles } | ConvertTo-Json -Depth 10)
        }
    }

    if ($method -eq "POST" -and $path -eq "/api/voice-profiles") {
        $requestObject = [System.Text.Encoding]::UTF8.GetString($Request.BodyBytes) | ConvertFrom-Json
        $profile = Save-VoiceProfile $requestObject
        return @{
            status = 200
            type = "application/json; charset=utf-8"
            body = (@{ ok = $true; profile = $profile } | ConvertTo-Json -Depth 10)
        }
    }

    if ($method -eq "GET" -and $path -match "^/api/projects/[^/]+$") {
        $projectId = Split-Path $path -Leaf
        if ($projectId -notmatch "^project_\d{8}_\d{6}$") {
            return @{
                status = 400
                type = "application/json; charset=utf-8"
                body = (@{ ok = $false; error = "项目 ID 格式无效。" } | ConvertTo-Json -Depth 5)
            }
        }

        $projectDir = Join-Path $ProjectsRoot $projectId
        if (-not (Test-Path $projectDir)) {
            return @{
                status = 404
                type = "application/json; charset=utf-8"
                body = (@{ ok = $false; error = "项目不存在。" } | ConvertTo-Json -Depth 5)
            }
        }

        return @{
            status = 200
            type = "application/json; charset=utf-8"
            body = (@{ ok = $true; result = (Get-ProjectDetails -ProjectDir $projectDir) } | ConvertTo-Json -Depth 20)
        }
    }

    if ($method -eq "POST" -and $path -eq "/api/generate") {
        $requestObject = [System.Text.Encoding]::UTF8.GetString($Request.BodyBytes) | ConvertFrom-Json
        $result = New-VideoProject $requestObject
        return @{
            status = 200
            type = "application/json; charset=utf-8"
            body = (@{ ok = $true; result = $result } | ConvertTo-Json -Depth 30)
        }
    }

    if ($method -eq "POST" -and $path -eq "/api/script/draft") {
        $requestObject = [System.Text.Encoding]::UTF8.GetString($Request.BodyBytes) | ConvertFrom-Json
        $text = [string]$requestObject.text
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw "文本内容不能为空。"
        }
        $options = $requestObject.options
        $mode = if ($options.generationMode) { [string]$options.generationMode } else { "avatar_only" }
        $style = if ($options.style) { [string]$options.style } else { "知识口播" }
        $script = Invoke-TextModel -Text $text -Mode $mode -Style $style -Config (Read-AppConfig)
        return @{
            status = 200
            type = "application/json; charset=utf-8"
            body = (@{ ok = $true; script = $script } | ConvertTo-Json -Depth 30)
        }
    }

    if ($method -eq "POST" -and $path -match "^/api/projects/[^/]+/compose$") {
        $segments = $path.Trim("/") -split "/"
        $projectId = $segments[2]
        $result = Invoke-ProjectCompose -ProjectId $projectId
        return @{
            status = 200
            type = "application/json; charset=utf-8"
            body = (@{ ok = $true; result = $result } | ConvertTo-Json -Depth 30)
        }
    }

    if ($method -eq "GET") {
        $safePath = $path
        if ([string]::IsNullOrWhiteSpace($safePath) -or $safePath -eq "/") {
            $safePath = "/index.html"
        }
        $safeRelative = $safePath.TrimStart("/") -replace "/", [System.IO.Path]::DirectorySeparatorChar
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $WwwRoot $safeRelative))
        $wwwFull = [System.IO.Path]::GetFullPath($WwwRoot)
        if (-not $fullPath.StartsWith($wwwFull)) {
            return @{
                status = 403
                type = "text/plain; charset=utf-8"
                body = "Forbidden"
            }
        }
        if (-not (Test-Path $fullPath -PathType Leaf)) {
            return @{
                status = 404
                type = "text/plain; charset=utf-8"
                body = "Not Found"
            }
        }
        $bytes = [System.IO.File]::ReadAllBytes($fullPath)
        return @{
            status = 200
            type = Get-ContentType $fullPath
            bytes = $bytes
        }
    }

    return @{
        status = 405
        type = "text/plain; charset=utf-8"
        body = "Method Not Allowed"
    }
}

function Invoke-SelfTest {
    $samplePath = Join-Path $Root "sample.txt"
    if (Test-Path $samplePath) {
        $sampleText = Get-Content -Raw -Encoding UTF8 -Path $samplePath
    } else {
        $sampleText = "这是一次本地自检。系统将生成脚本、字幕、配音文本、素材计划和项目配置。"
    }

    $payload = [pscustomobject]@{
        text = $sampleText
        options = [pscustomobject]@{
            generationMode = "mixed_avatar_ai_video"
            style = "知识口播"
            ratio = "9:16"
            resolution = "720p"
            fps = 30
            voice = [pscustomobject]@{
                type = "system"
                rate = 0
                volume = 100
            }
        }
    }

    return [pscustomobject]@{
        ok = $true
        environment = Invoke-EnvironmentCheck
        project = New-VideoProject $payload
    }
}

if ($SelfTest) {
    Invoke-SelfTest | ConvertTo-Json -Depth 30
    exit 0
}

if ($SelfTestVoice) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("voice sample placeholder")
    $payload = [pscustomobject]@{
        name = "测试克隆音色"
        fileName = "sample.wav"
        fileBase64 = [Convert]::ToBase64String($bytes)
    }
    Save-VoiceProfile $payload | ConvertTo-Json -Depth 10
    exit 0
}

function Start-TcpServer {
    param([int]$ListenPort)

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $ListenPort)
    $listener.Start()
    return $listener
}

$listener = Start-TcpServer -ListenPort $Port
$endpoint = "http://127.0.0.1:$Port/"
Write-Host "AI 视频生成工具已启动：$endpoint"
Write-Host "按 Ctrl+C 停止服务。"

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $request = Read-HttpRequest -Stream $stream
            if ($null -eq $request) {
                continue
            }

            Write-Host ("{0} {1}" -f $request.Method, $request.Path)
            $response = Handle-Request -Request $request
            if ($response.ContainsKey("bytes")) {
                Write-HttpResponse -Stream $stream -StatusCode $response.status -StatusText "OK" -ContentType $response.type -BodyBytes $response.bytes
            } else {
                $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$response.body)
                $statusText = switch ($response.status) {
                    200 { "OK" }
                    403 { "Forbidden" }
                    404 { "Not Found" }
                    405 { "Method Not Allowed" }
                    default { "OK" }
                }
                Write-HttpResponse -Stream $stream -StatusCode $response.status -StatusText $statusText -ContentType $response.type -BodyBytes $bodyBytes
            }
        } catch {
            Write-Host "REQUEST ERROR: $($_.Exception.Message)"
            try {
                $errBytes = [System.Text.Encoding]::UTF8.GetBytes((@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Depth 5))
                Write-HttpResponse -Stream $stream -StatusCode 500 -StatusText "Internal Server Error" -ContentType "application/json; charset=utf-8" -BodyBytes $errBytes
            } catch {}
        } finally {
            if ($null -ne $client) {
                $client.Close()
            }
        }
    }
} finally {
    $listener.Stop()
}
