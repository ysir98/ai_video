const fileInput = document.querySelector("#fileInput");
const textInput = document.querySelector("#textInput");
const textStats = document.querySelector("#textStats");
const clearBtn = document.querySelector("#clearBtn");
const generateBtn = document.querySelector("#generateBtn");
const resultBox = document.querySelector("#resultBox");
const health = document.querySelector("#health");
const refreshProjectsBtn = document.querySelector("#refreshProjectsBtn");
const refreshEnvBtn = document.querySelector("#refreshEnvBtn");
const environmentList = document.querySelector("#environmentList");
const installPlan = document.querySelector("#installPlan");
const projectList = document.querySelector("#projectList");
const selectedProjectLabel = document.querySelector("#selectedProjectLabel");
const voiceTypeSelect = document.querySelector("#voiceTypeSelect");
const voiceProfileSelect = document.querySelector("#voiceProfileSelect");
const voiceSampleInput = document.querySelector("#voiceSampleInput");
const voiceProfileName = document.querySelector("#voiceProfileName");
const saveVoiceProfileBtn = document.querySelector("#saveVoiceProfileBtn");
const voiceProfileStatus = document.querySelector("#voiceProfileStatus");
const saveConfigBtn = document.querySelector("#saveConfigBtn");
const configStatus = document.querySelector("#configStatus");
const composeProjectBtn = document.querySelector("#composeProjectBtn");
const draftScriptBtn = document.querySelector("#draftScriptBtn");
const scriptDraftInput = document.querySelector("#scriptDraftInput");
const scriptDraftStatus = document.querySelector("#scriptDraftStatus");
const formatScriptBtn = document.querySelector("#formatScriptBtn");
const clearDraftBtn = document.querySelector("#clearDraftBtn");
let currentProjectId = "";

function estimateDuration(text) {
  return Math.max(0, Math.ceil(text.trim().length / 4));
}

function updateStats() {
  const count = textInput.value.trim().length;
  textStats.textContent = `${count} 字，预计 ${estimateDuration(textInput.value)} 秒`;
}

function selectedMode() {
  return document.querySelector("input[name='mode']:checked").value;
}

function currentGenerationOptions() {
  return {
    generationMode: selectedMode(),
    style: document.querySelector("#styleSelect").value,
    ratio: document.querySelector("#ratioSelect").value,
    resolution: document.querySelector("#resolutionSelect").value,
    fps: 30,
    voice: {
      type: voiceTypeSelect.value,
      profileId: voiceProfileSelect.value,
      rate: Number(document.querySelector("#voiceRate").value),
      volume: Number(document.querySelector("#voiceVolume").value)
    }
  };
}

function readConfirmedScript() {
  const raw = scriptDraftInput.value.trim();
  if (!raw) return null;
  return JSON.parse(raw);
}

function updateModeCards() {
  document.querySelectorAll(".mode-card").forEach((card) => {
    const input = card.querySelector("input");
    card.classList.toggle("selected", input.checked);
  });
}

function bindStepNavigation() {
  document.querySelectorAll(".steps button").forEach((button) => {
    button.addEventListener("click", () => {
      document.querySelectorAll(".steps button").forEach((item) => item.classList.remove("active"));
      button.classList.add("active");
      const target = document.querySelector(`#${button.dataset.target}`);
      if (target) {
        target.scrollIntoView({ behavior: "smooth", block: "start" });
      }
    });
  });
}

async function loadHealth() {
  try {
    const res = await fetch("/api/health");
    const data = await res.json();
    const ffmpegCheck = data.checks.find((item) => item.id === "ffmpeg");
    const speechCheck = data.checks.find((item) => item.id === "system_speech");
    const textApiCheck = data.checks.find((item) => item.id === "text_api");
    health.innerHTML = [
      `服务状态：${data.ok ? "正常" : "异常"}`,
      `系统语音：${speechCheck?.ok ? "可用" : "不可用"}`,
      `ffmpeg：${ffmpegCheck?.ok ? "已检测到" : "未检测到"}`,
      `AI 文本接口：${textApiCheck?.ok ? "已配置" : "本地兜底"}`,
      `项目目录：${data.projectsRoot}`
    ].join("<br>");
    renderEnvironment(data);
  } catch (error) {
    health.textContent = `环境检测失败：${error.message}`;
    environmentList.textContent = `环境检测失败：${error.message}`;
  }
}

function renderEnvironment(data) {
  environmentList.innerHTML = data.checks.map((item) => {
    const status = item.ok ? "ok" : "missing";
    const required = item.required ? "必需" : "可选";
    const version = item.version ? `<span class="env-version">${item.version}</span>` : "";
    return `
      <div class="env-item ${status}">
        <div>
          <strong>${item.name}</strong>
          <small>${required}</small>
          ${version}
        </div>
        <p>${item.message}</p>
      </div>
    `;
  }).join("");

  const plan = data.installPlan;
  installPlan.innerHTML = `
    <strong>安装向导</strong>
    <p>${plan.note}</p>
    <code>${plan.commands.checkOnly}</code>
    <code>${plan.commands.installFfmpeg}</code>
  `;
}

async function loadProjects() {
  try {
    const res = await fetch("/api/projects");
    const data = await res.json();
    if (!data.projects || data.projects.length === 0) {
      projectList.innerHTML = "<div class='empty-state'>暂无历史项目。</div>";
      resultBox.textContent = "尚未选择项目。";
      return;
    }
    projectList.innerHTML = data.projects.map((item) => {
      const projectId = item.projectId || item.Name || item.name || "";
      const mode = item.generationMode || "unknown";
      const title = item.title || item.projectName || projectId;
      return `
        <button class="project-card" data-project-id="${projectId}" type="button">
          <strong>${title}</strong>
          <span>${projectId}</span>
          <small>${mode}</small>
        </button>
      `;
    }).join("");
  } catch (error) {
    resultBox.textContent = `读取项目失败：${error.message}`;
  }
}

async function loadVoiceProfiles() {
  try {
    const res = await fetch("/api/voice-profiles");
    const data = await res.json();
    const profiles = data.profiles || [];
    voiceProfileSelect.innerHTML = [
      `<option value="">未选择</option>`,
      ...profiles.map((profile) => `<option value="${profile.id}">${profile.name} (${profile.id})</option>`)
    ].join("");
    voiceProfileStatus.textContent = profiles.length
      ? `已保存 ${profiles.length} 个音色样本。`
      : "暂无保存音色，可上传语音样本创建。";
  } catch (error) {
    voiceProfileStatus.textContent = `读取音色失败：${error.message}`;
  }
}

async function loadConfig() {
  try {
    const res = await fetch("/api/config");
    const data = await res.json();
    if (!res.ok || !data.ok) {
      throw new Error(data.error || "读取配置失败");
    }
    const api = data.config.api || {};
    document.querySelector("#textEndpointInput").value = api.textEndpoint || "";
    document.querySelector("#textApiKeyInput").value = api.textApiKey || "";
    document.querySelector("#textModelInput").value = api.textModel || "";
    document.querySelector("#ttsProviderInput").value = api.ttsProvider || "";
    document.querySelector("#ttsEndpointInput").value = api.ttsEndpoint || "";
    document.querySelector("#ttsApiKeyInput").value = api.ttsApiKey || "";
    document.querySelector("#voiceCloneProviderInput").value = api.voiceCloneProvider || "";
    document.querySelector("#voiceCloneEndpointInput").value = api.voiceCloneEndpoint || "";
    document.querySelector("#voiceCloneApiKeyInput").value = api.voiceCloneApiKey || "";
    document.querySelector("#avatarEndpointInput").value = api.avatarEndpoint || "";
    document.querySelector("#avatarApiKeyInput").value = api.avatarApiKey || "";
    document.querySelector("#videoEndpointInput").value = api.videoEndpoint || "";
    document.querySelector("#videoApiKeyInput").value = api.videoApiKey || "";
    configStatus.textContent = `已读取配置：${data.path}`;
  } catch (error) {
    configStatus.textContent = `读取配置失败：${error.message}`;
  }
}

async function saveConfig() {
  saveConfigBtn.disabled = true;
  saveConfigBtn.textContent = "保存中...";
  configStatus.textContent = "正在保存配置。";

  const payload = {
    api: {
      textEndpoint: document.querySelector("#textEndpointInput").value.trim(),
      textApiKey: document.querySelector("#textApiKeyInput").value.trim(),
      textModel: document.querySelector("#textModelInput").value.trim(),
      ttsProvider: document.querySelector("#ttsProviderInput").value.trim(),
      ttsEndpoint: document.querySelector("#ttsEndpointInput").value.trim(),
      ttsApiKey: document.querySelector("#ttsApiKeyInput").value.trim(),
      voiceCloneProvider: document.querySelector("#voiceCloneProviderInput").value.trim(),
      voiceCloneEndpoint: document.querySelector("#voiceCloneEndpointInput").value.trim(),
      voiceCloneApiKey: document.querySelector("#voiceCloneApiKeyInput").value.trim(),
      avatarEndpoint: document.querySelector("#avatarEndpointInput").value.trim(),
      avatarApiKey: document.querySelector("#avatarApiKeyInput").value.trim(),
      videoEndpoint: document.querySelector("#videoEndpointInput").value.trim(),
      videoApiKey: document.querySelector("#videoApiKeyInput").value.trim()
    },
    output: {
      defaultDir: "projects",
      resolution: document.querySelector("#resolutionSelect").value,
      fps: 30,
      format: "mp4"
    },
    style: {
      defaultVideoRatio: document.querySelector("#ratioSelect").value,
      subtitleEnabled: true,
      bgmEnabled: true
    }
  };

  try {
    const res = await fetch("/api/config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    const data = await res.json();
    if (!res.ok || !data.ok) {
      throw new Error(data.error || "保存失败");
    }
    configStatus.textContent = `已保存配置：${data.path}`;
    loadHealth();
  } catch (error) {
    configStatus.textContent = `保存配置失败：${error.message}`;
  } finally {
    saveConfigBtn.disabled = false;
    saveConfigBtn.textContent = "保存配置";
  }
}

function fileToBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const result = String(reader.result || "");
      resolve(result.includes(",") ? result.split(",")[1] : result);
    };
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

async function loadProjectDetails(projectId) {
  if (!projectId) {
    selectedProjectLabel.textContent = "未选择项目";
    resultBox.textContent = "项目 ID 为空，请刷新项目列表后重试。";
    return;
  }

  currentProjectId = projectId;
  selectedProjectLabel.textContent = projectId;
  document.querySelectorAll(".project-card").forEach((card) => {
    card.classList.toggle("selected", card.dataset.projectId === projectId);
  });
  resultBox.textContent = `正在加载项目：${projectId}`;

  try {
    const res = await fetch(`/api/projects/${encodeURIComponent(projectId)}`);
    const data = await res.json();
    if (!res.ok || !data.ok) {
      throw new Error(data.error || "读取项目失败");
    }

    const summary = data.result.summary;
    selectedProjectLabel.textContent = summary.projectId;
    resultBox.textContent = [
      `项目：${summary.projectName}`,
      `项目 ID：${summary.projectId}`,
      `模式：${summary.generationMode}`,
      `标题：${summary.title}`,
      `创建时间：${summary.createdAt}`,
      `目录：${summary.projectDir}`,
      "",
      "文件：",
      ...Object.entries(summary.files).map(([key, value]) => `- ${key}: ${value ? "已生成" : "缺失"}`),
      "",
      "项目 JSON：",
      data.result.files.project?.content || "",
      "",
      "脚本 JSON：",
      data.result.files.script?.content || "",
      "",
      "脚本文档：",
      data.result.files.scriptMarkdown?.content || "",
      "",
      "素材计划：",
      data.result.files.assetPlan?.content || "",
      "",
      "字幕：",
      data.result.files.subtitles?.content || "",
      "",
      "渲染计划：",
      data.result.files.renderPlan?.content || "",
      "",
      "任务日志：",
      data.result.files.log?.content || ""
    ].join("\n");
  } catch (error) {
    resultBox.textContent = `加载项目详情失败：${error.message}`;
  }
}

fileInput.addEventListener("change", async () => {
  const file = fileInput.files[0];
  if (!file) return;
  textInput.value = await file.text();
  updateStats();
});

textInput.addEventListener("input", updateStats);
clearBtn.addEventListener("click", () => {
  textInput.value = "";
  updateStats();
});

document.querySelectorAll("input[name='mode']").forEach((input) => {
  input.addEventListener("change", updateModeCards);
});

refreshProjectsBtn.addEventListener("click", loadProjects);
refreshEnvBtn.addEventListener("click", loadHealth);
saveConfigBtn.addEventListener("click", saveConfig);

draftScriptBtn.addEventListener("click", async () => {
  const text = textInput.value.trim();
  if (!text) {
    scriptDraftStatus.textContent = "请先导入或输入文本内容。";
    return;
  }

  draftScriptBtn.disabled = true;
  draftScriptBtn.textContent = "处理中...";
  scriptDraftStatus.textContent = "正在解读和润色文本，生成可确认脚本。";

  try {
    const res = await fetch("/api/script/draft", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        text,
        options: currentGenerationOptions()
      })
    });
    const data = await res.json();
    if (!res.ok || !data.ok) {
      throw new Error(data.error || "脚本生成失败");
    }
    scriptDraftInput.value = JSON.stringify(data.script, null, 2);
    scriptDraftStatus.textContent = "脚本草稿已生成，可修改确认后点击“开始生成”。";
    document.querySelector("#scriptSection").scrollIntoView({ behavior: "smooth", block: "start" });
  } catch (error) {
    scriptDraftStatus.textContent = `脚本生成失败：${error.message}`;
  } finally {
    draftScriptBtn.disabled = false;
    draftScriptBtn.textContent = "解读/润色脚本";
  }
});

formatScriptBtn.addEventListener("click", () => {
  try {
    const script = readConfirmedScript();
    if (!script) {
      scriptDraftStatus.textContent = "暂无脚本草稿。";
      return;
    }
    scriptDraftInput.value = JSON.stringify(script, null, 2);
    scriptDraftStatus.textContent = "脚本 JSON 已格式化。";
  } catch (error) {
    scriptDraftStatus.textContent = `脚本 JSON 格式错误：${error.message}`;
  }
});

clearDraftBtn.addEventListener("click", () => {
  scriptDraftInput.value = "";
  scriptDraftStatus.textContent = "已清除脚本草稿。";
});

projectList.addEventListener("click", (event) => {
  const card = event.target.closest(".project-card");
  if (!card) return;
  loadProjectDetails(card.dataset.projectId);
});

composeProjectBtn.addEventListener("click", async () => {
  if (!currentProjectId) {
    resultBox.textContent = "请先在项目列表中选择一个项目。";
    return;
  }

  composeProjectBtn.disabled = true;
  composeProjectBtn.textContent = "合成中...";
  resultBox.textContent = "正在根据脚本、音频和字幕生成/重新合成视频。";

  try {
    const res = await fetch(`/api/projects/${encodeURIComponent(currentProjectId)}/compose`, {
      method: "POST"
    });
    const data = await res.json();
    if (!res.ok || !data.ok) {
      throw new Error(data.error || "合成失败");
    }
    resultBox.textContent = [
      `项目：${data.result.projectId}`,
      `目录：${data.result.projectDir}`,
      `结果：${data.result.compose.message}`,
      `视频：${data.result.compose.output || "未生成，通常是缺少 ffmpeg 或素材接口"}`,
      `渲染计划：${data.result.compose.renderPlan}`
    ].join("\n");
    await loadProjects();
  } catch (error) {
    resultBox.textContent = `合成失败：${error.message}`;
  } finally {
    composeProjectBtn.disabled = false;
    composeProjectBtn.textContent = "生成/重新合成视频";
  }
});

saveVoiceProfileBtn.addEventListener("click", async () => {
  const file = voiceSampleInput.files[0];
  const name = voiceProfileName.value.trim();
  if (!file) {
    voiceProfileStatus.textContent = "请先选择一个语音样本文件。";
    return;
  }
  if (!name) {
    voiceProfileStatus.textContent = "请填写音色名称。";
    return;
  }

  saveVoiceProfileBtn.disabled = true;
  saveVoiceProfileBtn.textContent = "保存中...";
  voiceProfileStatus.textContent = "正在保存语音样本到本地音色库。";

  try {
    const fileBase64 = await fileToBase64(file);
    const res = await fetch("/api/voice-profiles", {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        name,
        fileName: file.name,
        fileBase64
      })
    });
    const data = await res.json();
    if (!res.ok || !data.ok) {
      throw new Error(data.error || "保存失败");
    }
    voiceTypeSelect.value = "clone";
    await loadVoiceProfiles();
    voiceProfileSelect.value = data.profile.id;
    voiceProfileStatus.textContent = `已保存音色：${data.profile.name}`;
  } catch (error) {
    voiceProfileStatus.textContent = `保存音色失败：${error.message}`;
  } finally {
    saveVoiceProfileBtn.disabled = false;
    saveVoiceProfileBtn.textContent = "保存音色样本";
  }
});

generateBtn.addEventListener("click", async () => {
  const text = textInput.value.trim();
  if (!text) {
    resultBox.textContent = "请先导入或输入文本内容。";
    return;
  }

  generateBtn.disabled = true;
  generateBtn.textContent = "生成中...";
  resultBox.textContent = "正在生成项目，请稍候。首次调用系统语音可能需要一些时间。";

  let confirmedScript = null;
  try {
    confirmedScript = readConfirmedScript();
  } catch (error) {
    resultBox.textContent = `脚本草稿 JSON 格式错误，请修正后再生成：${error.message}`;
    generateBtn.disabled = false;
    generateBtn.textContent = "开始生成";
    return;
  }

  if (!confirmedScript) {
    resultBox.textContent = "请先点击“解读/润色脚本”，确认或修改脚本草稿后再开始生成。";
    generateBtn.disabled = false;
    generateBtn.textContent = "开始生成";
    document.querySelector("#scriptSection").scrollIntoView({ behavior: "smooth", block: "start" });
    return;
  }

  const payload = {
    text,
    options: currentGenerationOptions(),
    script: confirmedScript
  };

  try {
    const res = await fetch("/api/generate", {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify(payload)
    });
    const data = await res.json();
    if (!res.ok || !data.ok) {
      throw new Error(data.error || "生成失败");
    }

    const result = data.result;
    selectedProjectLabel.textContent = result.projectId;
    currentProjectId = result.projectId;
    resultBox.textContent = [
      `项目：${result.projectId}`,
      `目录：${result.projectDir}`,
      "",
      `脚本 JSON：${result.files.scriptJson}`,
      `脚本文档：${result.files.scriptMarkdown}`,
      `素材计划：${result.files.assetPlan}`,
      `音频：${result.files.audio || "未生成"}`,
      `字幕：${result.files.subtitles}`,
      `视频：${result.files.video || "未生成，需安装 ffmpeg 后重新生成"}`,
      `渲染计划：${result.files.renderPlan}`,
      `日志：${result.files.log}`,
      "",
      `TTS：${result.status.tts.message}`,
      `合成：${result.status.compose.message}`,
      "",
      "下一步：在项目列表中选择该项目，然后点击“生成/重新合成视频”。如果已安装 ffmpeg，会输出 output/final.mp4；否则会刷新 render_plan.json。"
    ].join("\n");
    await loadProjects();
  } catch (error) {
    resultBox.textContent = `生成失败：${error.message}`;
  } finally {
    generateBtn.disabled = false;
    generateBtn.textContent = "开始生成";
    loadHealth();
  }
});

updateModeCards();
updateStats();
bindStepNavigation();
loadHealth();
loadProjects();
loadVoiceProfiles();
loadConfig();
