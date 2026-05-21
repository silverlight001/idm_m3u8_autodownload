const $ = (id) => document.getElementById(id);

function todayPath(template) {
  const now = new Date();
  const yyyy = String(now.getFullYear());
  const mm = String(now.getMonth() + 1).padStart(2, "0");
  const dd = String(now.getDate()).padStart(2, "0");
  return template
    .replaceAll("{yyyyMMdd}", `${yyyy}${mm}${dd}`)
    .replaceAll("{yyyy-MM-dd}", `${yyyy}-${mm}-${dd}`)
    .replaceAll("{yyyyMM}", `${yyyy}${mm}`);
}

function send(message) {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage(message, resolve);
  });
}

async function load() {
  const response = await send({ type: "getState" });
  const state = response.state;
  const capture = state.lastCapture || {};

  $("enabled").checked = Boolean(state.enabled);
  $("autoSend").checked = Boolean(state.autoSend);
  $("workDir").value = todayPath(state.workDirTemplate || "D:\\srep\\{yyyyMMdd}");
  $("title").value = capture.title || "";
  $("url").value = capture.url || "";
  const inferred = capture.rawMediaType === "segment" && capture.mediaType === "hls" ? " (inferred from segment)" : "";
  $("download").disabled = !capture.url || (capture.inferred && !capture.playlistBody);
  if (!capture.url) {
    $("status").textContent = "Open a video page and play it until a video request appears.";
  } else if (capture.inferred && !capture.playlistBody) {
    $("status").textContent = "Only segments captured. Reload the page and play from the beginning.";
  } else if (capture.captureSource === "segment-collection") {
    $("status").textContent = `Captured TS segments: ${capture.segmentCount || 0}. Playback must run to capture more.`;
  } else {
    $("status").textContent = `Ready: ${capture.mediaType || "video"}${inferred}`;
  }
}

async function saveSettings() {
  await send({
    type: "setState",
    patch: {
      enabled: $("enabled").checked,
      autoSend: $("autoSend").checked,
      workDirTemplate: $("workDir").value
    }
  });
}

$("enabled").addEventListener("change", saveSettings);
$("autoSend").addEventListener("change", saveSettings);
$("workDir").addEventListener("change", saveSettings);

$("download").addEventListener("click", async () => {
  $("download").disabled = true;
  $("status").textContent = "Submitting...";
  const response = await send({
    type: "download",
    title: $("title").value,
    workDir: $("workDir").value
  });

  $("download").disabled = false;
  $("status").textContent = response?.ok ? "Submitted to N_m3u8DL" : `Error: ${response?.error || "unknown"}`;
});

load();
