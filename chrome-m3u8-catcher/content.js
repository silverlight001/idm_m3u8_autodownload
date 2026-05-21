(function () {
  let stopped = false;
  let timer = null;

  const script = document.createElement("script");
  script.src = chrome.runtime.getURL("page-hook.js");
  script.onload = () => script.remove();
  (document.documentElement || document.head).appendChild(script);

  const overlay = document.createElement("div");
  overlay.id = "__m3u8dl_video_overlay";
  overlay.innerHTML = `
    <button id="__m3u8dl_download_button" type="button">
      <span class="__m3u8dl_icon">&gt;</span>
      <span class="__m3u8dl_text">m3u8DL Download</span>
    </button>
    <div id="__m3u8dl_hint"></div>
  `;

  const style = document.createElement("style");
  style.textContent = `
    #__m3u8dl_video_overlay {
      position: fixed;
      z-index: 2147483647;
      display: none;
      font-family: "Segoe UI", Arial, sans-serif;
      pointer-events: none;
    }
    #__m3u8dl_download_button {
      pointer-events: auto;
      display: inline-flex;
      align-items: center;
      gap: 5px;
      height: 24px;
      padding: 0 9px;
      border: 1px solid #9eb7d8;
      border-radius: 3px;
      background: linear-gradient(#fff, #ddecff);
      color: #e32222;
      font-size: 13px;
      font-weight: 700;
      line-height: 22px;
      cursor: pointer;
      box-shadow: 0 1px 3px rgba(0, 0, 0, .18);
    }
    #__m3u8dl_download_button:hover {
      background: linear-gradient(#fff, #cfe2ff);
    }
    #__m3u8dl_download_button:disabled {
      cursor: default;
      color: #64748b;
      background: #eef2f7;
    }
    #__m3u8dl_hint {
      display: none;
      pointer-events: none;
      margin-top: 3px;
      padding: 5px 7px;
      max-width: 260px;
      border: 1px solid #d7b84b;
      border-radius: 4px;
      background: #fff8c5;
      color: #172033;
      font-size: 12px;
      line-height: 1.35;
      box-shadow: 0 1px 3px rgba(0, 0, 0, .16);
    }
  `;

  function appendOverlay() {
    if (!document.documentElement) return;
    if (!document.getElementById("__m3u8dl_video_overlay")) {
      document.documentElement.appendChild(style);
      document.documentElement.appendChild(overlay);
    }
  }

  function send(message) {
    return new Promise((resolve) => {
      try {
        if (stopped || !chrome?.runtime?.id) {
          stopOverlay();
          resolve({ ok: false, error: "extension context invalidated" });
          return;
        }
        chrome.runtime.sendMessage(message, (response) => {
          if (chrome.runtime.lastError) {
            stopOverlay();
            resolve({ ok: false, error: chrome.runtime.lastError.message });
            return;
          }
          resolve(response);
        });
      } catch (error) {
        stopOverlay();
        resolve({ ok: false, error: error.message });
      }
    });
  }

  function stopOverlay() {
    if (stopped) return;
    stopped = true;
    if (timer) window.clearInterval(timer);
    window.removeEventListener("scroll", refreshOverlay, true);
    window.removeEventListener("resize", refreshOverlay);
    document.removeEventListener("fullscreenchange", refreshOverlay);
    overlay.remove();
    style.remove();
  }

  function largestVisibleVideo() {
    let best = null;
    let bestArea = 0;
    for (const video of document.querySelectorAll("video")) {
      const rect = video.getBoundingClientRect();
      const area = rect.width * rect.height;
      if (rect.width < 160 || rect.height < 90) continue;
      if (rect.bottom <= 0 || rect.right <= 0 || rect.top >= innerHeight || rect.left >= innerWidth) continue;
      if (area > bestArea) {
        best = rect;
        bestArea = area;
      }
    }
    return best;
  }

  async function refreshOverlay() {
    if (stopped) return;
    appendOverlay();
    const rect = largestVisibleVideo();
    if (!rect) {
      overlay.style.display = "none";
      return;
    }

    const response = await send({ type: "getState" });
    if (stopped || !response?.ok) return;
    const capture = response?.state?.lastCapture || {};
    const button = overlay.querySelector("#__m3u8dl_download_button");
    const hint = overlay.querySelector("#__m3u8dl_hint");

    overlay.style.display = "block";
    overlay.style.top = `${Math.max(4, rect.top + 8)}px`;
    overlay.style.left = `${Math.max(4, Math.min(innerWidth - 160, rect.right - 176))}px`;

    if (!capture.url) {
      button.disabled = true;
      button.querySelector(".__m3u8dl_text").textContent = "Waiting for video";
      hint.style.display = "block";
      hint.textContent = "Start playback to capture video resources.";
      return;
    }

    if (capture.inferred && !capture.playlistBody) {
      button.disabled = true;
      button.querySelector(".__m3u8dl_text").textContent = "Segments only";
      hint.style.display = "block";
      hint.textContent = "Reload the page and play from the beginning to capture the real m3u8 playlist.";
      return;
    }

    button.disabled = false;
    if (capture.captureSource === "segment-collection") {
      button.querySelector(".__m3u8dl_text").textContent = `Captured TS: ${capture.segmentCount || 0}`;
      hint.style.display = "block";
      hint.textContent = "Click to download captured segments. For a full file, let playback run from the beginning until all segments are captured.";
      return;
    }

    button.querySelector(".__m3u8dl_text").textContent = "m3u8DL Download";
    hint.style.display = "none";
  }

  overlay.addEventListener("click", async (event) => {
    const button = event.target.closest("#__m3u8dl_download_button");
    if (!button || button.disabled) return;

    button.disabled = true;
    button.querySelector(".__m3u8dl_text").textContent = "Submitting...";
    const response = await send({ type: "download" });
    button.querySelector(".__m3u8dl_text").textContent = response?.ok ? "Submitted" : "Failed";
    setTimeout(refreshOverlay, 1500);
  });

  timer = setInterval(refreshOverlay, 1000);
  window.addEventListener("scroll", refreshOverlay, true);
  window.addEventListener("resize", refreshOverlay);
  document.addEventListener("fullscreenchange", refreshOverlay);

  window.addEventListener("message", (event) => {
    if (event.source !== window) return;
    const data = event.data;
    if (!data || data.source !== "m3u8dl-page-hook") return;
    send({
      type: "pageMediaCapture",
      url: data.url,
      body: data.body || "",
      pageUrl: location.href,
      title: document.title || ""
    }).then(() => refreshOverlay());
  });
})();
