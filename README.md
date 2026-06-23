# AI 视频生成工具

这是一个本地运行的 AI 视频生成 MVP。当前版本使用 Windows 自带 PowerShell/.NET 实现本地服务，前端为纯 HTML/CSS/JS，无需 Node 或 Python。

## 已实现

- 本地 Web 工作台。
- 读取或粘贴 `txt` 文本。
- 四种视频模式选择：
  - 单数字人
  - 单 AI 创作视频
  - 混合数字人与 AI 视频
  - 数字人动画形象
- 本地脚本生成兜底逻辑。
- 可配置 OpenAI 兼容文本接口。
- 使用 Windows 系统语音生成 `wav` 配音。
- 支持保存语音样本为本地音色档案，并在后续项目中重复选择。
- 生成 `srt` 字幕。
- 生成项目目录、脚本、音频、字幕、配置和日志。
- 检测到 `ffmpeg` 后可生成基础 `mp4`。

## 启动

在当前目录执行：

```powershell
.\run.ps1
```

浏览器打开：

```text
http://localhost:8765/
```

如需指定端口：

```powershell
.\run.ps1 -Port 8788
```

## 配置 AI 文本接口

首次启动会从 `config/appsettings.example.json` 复制生成 `config/appsettings.json`。

可以在 `config/appsettings.json` 中配置 OpenAI 兼容接口：

```json
{
  "api": {
    "textEndpoint": "https://api.example.com/v1/chat/completions",
    "textApiKey": "YOUR_API_KEY",
    "textModel": "gpt-4.1-mini"
  }
}
```

未配置接口时，系统会使用本地规则生成脚本，保证流程可跑通。

## ffmpeg

当前环境如果没有安装 `ffmpeg`，系统仍会生成：

- `input/source.txt`
- `script/script.json`
- `script/script.md`
- `audio/voice.wav`
- `output/subtitles.srt`
- `output/render_plan.json`
- `project.json`
- `logs/task.log`

安装 `ffmpeg` 并加入系统 PATH 后，重新生成即可输出基础 `output/final.mp4`。

## 音色选择与语音克隆样本

当前版本支持本地保存克隆音色样本：

1. 打开页面。
2. 在“语音”区域选择“克隆音色”。
3. 选择一个语音样本文件，支持 `wav`、`mp3`、`m4a`、`aac`、`flac`、`ogg`。
4. 输入音色名称。
5. 点击“保存音色样本”。
6. 保存后可在“已保存音色”下拉框中重复选择。

音色样本会保存到：

```text
voice_profiles/voice_yyyyMMdd_HHmmss/
  profile.json
  sample.wav
```

生成项目时，所选音色配置会写入项目的 `project.json`，并复制一份到：

```text
projects/project_xxx/voice_profiles/profile.json
```

注意：当前版本保存的是“语音克隆样本和音色档案”。还没有接入真实语音克隆服务商，所以最终配音仍使用 Windows 系统语音或配音文本兜底。接入真实克隆接口后，会使用该样本创建服务商 `voiceId`，再用该音色生成配音。

## 项目产物

生成后的项目位于：

```text
projects/project_yyyyMMdd_HHmmss/
```

目录结构：

```text
input/
script/
audio/
voice_profiles/
image/
video/
output/
logs/
project.json
```

## 后续开发方向

- 接入真实 TTS 和语音克隆接口。
- 接入数字人生成接口。
- 接入 AI 视频生成接口。
- 增加片段级预览和重试。
- 增加项目恢复和批量任务队列。
- 增强 ffmpeg 合成模板，支持字幕烧录、数字人叠加、背景视频混合。
