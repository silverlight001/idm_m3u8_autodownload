const NATIVE_HOST = "com.local.m3u8dl";
const VIDEO_EXT_RE = /\.(m3u8|mpd|mp4|m4v|webm|mov|flv|ts|m4s|f4v)(?:[?#]|$)/i;
const VIDEO_CONTENT_TYPE_RE = /^(application\/vnd\.apple\.mpegurl|application\/x-mpegurl|audio\/mpegurl|application\/dash\+xml|video\/|audio\/mp4|application\/octet-stream)/i;
const requestHeadersByUrl = new Map();
const DEFAULT_STATE = {
  enabled: true,
  lastCapture: null,
  captures: [],
  segmentGroups: {},
  workDirTemplate: "D:\\Downloads\\m3u8\\{yyyyMMdd}",
  autoSend: false
};

async function getState() {
  const data = await chrome.storage.local.get(DEFAULT_STATE);
  const state = { ...DEFAULT_STATE, ...data };
  return normalizeState(state);
}

async function setState(partial) {
  await chrome.storage.local.set(partial);
}

async function enrichHeaders(url, pageUrl, rawHeaders = {}) {
  const headers = { ...(rawHeaders || {}) };
  if (!headers.Referer && pageUrl) headers.Referer = pageUrl;

  try {
    const cookies = await chrome.cookies.getAll({ url });
    if (cookies && cookies.length) {
      headers.Cookie = cookies.map((item) => `${item.name}=${item.value}`).join("; ");
    }
  } catch {
    // Cookie access can fail on restricted schemes; request headers are still useful.
  }

  if (!headers.Accept) headers.Accept = "*/*";
  return headers;
}

async function captureFromPage(message, sender) {
  const state = await getState();
  if (!state.enabled) return;

  let tabTitle = message.title || "";
  let pageUrl = message.pageUrl || "";
  if (sender?.tab) {
    tabTitle = sender.tab.title || tabTitle;
    pageUrl = sender.tab.url || pageUrl;
  }

  const capture = {
    url: message.url || pageUrl,
    playlistBody: message.body || "",
    inferred: false,
    captureSource: message.body ? "page-playlist-body" : "page-url",
    title: sanitizeTitle(tabTitle),
    mediaType: "hls",
    rawMediaType: "hls",
    headers: await enrichHeaders(message.url || pageUrl, pageUrl, {}),
    pageUrl,
    tabId: sender?.tab?.id ?? -1,
    capturedAt: new Date().toISOString()
  };

  const deduped = [capture, ...(state.captures || []).filter((item) => item.url !== capture.url)].slice(0, 20);
  await setState({ lastCapture: capture, captures: deduped });
  await chrome.action.setBadgeText({ text: "HLS" });
  await chrome.action.setBadgeBackgroundColor({ color: "#1f6feb" });
}

function detectMediaType(url, responseHeaders = []) {
  const cleanUrl = typeof url === "string" ? url : "";
  const header = (responseHeaders || []).find((item) => item.name && item.name.toLowerCase() === "content-type");
  const contentType = header?.value || "";

  if (/\.m3u8(?:[?#]|$)/i.test(cleanUrl) || /mpegurl/i.test(contentType)) return "hls";
  if (/\.mpd(?:[?#]|$)/i.test(cleanUrl) || /dash\+xml/i.test(contentType)) return "dash";
  if (/\.(mp4|m4v|webm|mov|flv|f4v)(?:[?#]|$)/i.test(cleanUrl) || /^video\//i.test(contentType)) return "file";
  if (/\.(ts|m4s)(?:[?#]|$)/i.test(cleanUrl)) return "segment";
  if (VIDEO_EXT_RE.test(cleanUrl) || VIDEO_CONTENT_TYPE_RE.test(contentType)) return "media";
  return null;
}

function mediaRank(mediaType) {
  return {
    hls: 5,
    file: 4,
    dash: 3,
    media: 2,
    segment: 1
  }[mediaType] || 0;
}

function inferPlaylistFromSegment(url) {
  const match = String(url).match(/^(https?:\/\/.+\/)([^/?#]+?)(\d+)\.(ts|m4s)([?#].*)?$/i);
  if (!match) return "";
  return `${match[1]}${match[2]}.m3u8${match[5] || ""}`;
}

function parseSegmentUrl(url) {
  const match = String(url).match(/^(https?:\/\/.+\/)([^/?#]*?)(\d+)\.(ts|m4s)([?#].*)?$/i);
  if (!match) return null;
  return {
    key: `${match[1]}${match[2]}.${match[4]}`,
    index: Number(match[3]),
    url
  };
}

function buildPlaylistFromSegments(segmentUrls) {
  const lines = [
    "#EXTM3U",
    "#EXT-X-VERSION:3",
    "#EXT-X-TARGETDURATION:10",
    "#EXT-X-MEDIA-SEQUENCE:0"
  ];
  for (const url of segmentUrls) {
    lines.push("#EXTINF:10.000,");
    lines.push(url);
  }
  lines.push("#EXT-X-ENDLIST");
  return lines.join("\n") + "\n";
}

function normalizeCapture(capture) {
  if (!capture || capture.mediaType !== "segment") return capture;
  const inferredUrl = inferPlaylistFromSegment(capture.url);
  if (!inferredUrl) return capture;
  return {
    ...capture,
    rawUrl: capture.rawUrl || capture.url,
    rawMediaType: capture.rawMediaType || "segment",
    inferred: true,
    captureSource: "segment-inferred",
    url: inferredUrl,
    mediaType: "hls"
  };
}

function normalizeState(state) {
  return {
    ...state,
    lastCapture: normalizeCapture(state.lastCapture),
    captures: (state.captures || []).map(normalizeCapture)
  };
}

function todayToken(template) {
  const now = new Date();
  const yyyy = String(now.getFullYear());
  const mm = String(now.getMonth() + 1).padStart(2, "0");
  const dd = String(now.getDate()).padStart(2, "0");
  return template
    .replaceAll("{yyyyMMdd}", `${yyyy}${mm}${dd}`)
    .replaceAll("{yyyy-MM-dd}", `${yyyy}-${mm}-${dd}`)
    .replaceAll("{yyyyMM}", `${yyyy}${mm}`);
}

function sanitizeTitle(title) {
  const fallback = `video_${new Date().toISOString().replace(/[:.]/g, "-")}`;
  return (title || fallback)
    .replace(/[\\/:*?"<>|]/g, "_")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120) || fallback;
}

async function captureM3u8(details) {
  const mediaType = detectMediaType(details.url, details.responseHeaders);
  if (!mediaType) return;

  const state = await getState();
  if (!state.enabled) return;

  let tabTitle = "";
  let pageUrl = "";
  if (details.tabId >= 0) {
    try {
      const tab = await chrome.tabs.get(details.tabId);
      tabTitle = tab.title || "";
      pageUrl = tab.url || "";
    } catch {
      // Tab may have closed.
    }
  }

  if (mediaType === "segment") {
    const segment = parseSegmentUrl(details.url);
    if (segment) {
      const groups = state.segmentGroups || {};
      const group = groups[segment.key] || { items: {}, title: "", pageUrl: "", updatedAt: "" };
      group.items[String(segment.index)] = {
        index: segment.index,
        url: details.url,
        capturedAt: new Date().toISOString()
      };
      group.title = sanitizeTitle(tabTitle || group.title);
      group.pageUrl = pageUrl || group.pageUrl;
      group.updatedAt = new Date().toISOString();
      groups[segment.key] = group;

      const sortedItems = Object.values(group.items).sort((a, b) => a.index - b.index);
      const segmentUrls = sortedItems.map((item) => item.url);
      const capture = {
        url: inferPlaylistFromSegment(details.url) || details.url,
        rawUrl: details.url,
        inferred: false,
        captureSource: "segment-collection",
        title: sanitizeTitle(tabTitle),
        mediaType: "hls",
        rawMediaType: "segment",
      headers: await enrichHeaders(details.url, pageUrl, getUsefulHeaders(details.url)),
        playlistBody: buildPlaylistFromSegments(segmentUrls),
        segmentCount: segmentUrls.length,
        pageUrl,
        tabId: details.tabId,
        capturedAt: new Date().toISOString()
      };

      const deduped = [capture, ...(state.captures || []).filter((item) => item.url !== capture.url)].slice(0, 20);
      await setState({ lastCapture: capture, captures: deduped, segmentGroups: groups });
      await chrome.action.setBadgeText({ text: `TS${Math.min(segmentUrls.length, 99)}` });
      await chrome.action.setBadgeBackgroundColor({ color: "#1f6feb" });
      return;
    }
  }

  const inferredUrl = mediaType === "segment" ? inferPlaylistFromSegment(details.url) : "";
  const capture = {
    url: inferredUrl || details.url,
    rawUrl: details.url,
    inferred: Boolean(inferredUrl),
    captureSource: inferredUrl ? "segment-inferred" : "webRequest",
    title: sanitizeTitle(tabTitle),
    mediaType: inferredUrl ? "hls" : mediaType,
    rawMediaType: mediaType,
    headers: await enrichHeaders(details.url, pageUrl, getUsefulHeaders(details.url)),
    pageUrl,
    tabId: details.tabId,
    capturedAt: new Date().toISOString()
  };

  const current = state.lastCapture;
  if (current && mediaRank(current.mediaType) > mediaRank(capture.mediaType)) {
    const dedupedOnly = [capture, ...(state.captures || []).filter((item) => item.url !== capture.url)].slice(0, 20);
    await setState({ captures: dedupedOnly });
    return;
  }

  const deduped = [capture, ...(state.captures || []).filter((item) => item.url !== capture.url)].slice(0, 20);
  await setState({ lastCapture: capture, captures: deduped });

  await chrome.action.setBadgeText({ text: mediaType === "hls" ? "HLS" : "VID" });
  await chrome.action.setBadgeBackgroundColor({ color: "#1f6feb" });

  if (state.autoSend) {
    await sendToNative({
      ...capture,
      workDir: todayToken(state.workDirTemplate || DEFAULT_STATE.workDirTemplate)
    });
  }
}

async function sendToNative(payload) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendNativeMessage(NATIVE_HOST, {
      type: "download",
      url: payload.url,
      title: sanitizeTitle(payload.title),
      mediaType: payload.mediaType || "media",
      headers: payload.headers || {},
      playlistBody: payload.playlistBody || "",
      workDir: payload.workDir
    }, (response) => {
      const err = chrome.runtime.lastError;
      if (err) {
        reject(new Error(err.message));
        return;
      }
      if (!response || response.ok !== true) {
        reject(new Error(response?.error || "Native host failed"));
        return;
      }
      resolve(response);
    });
  });
}

chrome.webRequest.onBeforeRequest.addListener(
  captureM3u8,
  { urls: ["<all_urls>"] }
);

chrome.webRequest.onBeforeSendHeaders.addListener(
  (details) => {
    const headers = {};
    for (const item of details.requestHeaders || []) {
      const name = item.name.toLowerCase();
      if (["referer", "user-agent", "cookie", "origin", "accept", "accept-language"].includes(name)) {
        headers[item.name] = item.value || "";
      }
    }
    requestHeadersByUrl.set(details.url, headers);
    if (requestHeadersByUrl.size > 500) {
      const firstKey = requestHeadersByUrl.keys().next().value;
      requestHeadersByUrl.delete(firstKey);
    }
  },
  { urls: ["<all_urls>"] },
  ["requestHeaders", "extraHeaders"]
);

chrome.webRequest.onHeadersReceived.addListener(
  captureM3u8,
  { urls: ["<all_urls>"] },
  ["responseHeaders"]
);

function getUsefulHeaders(url) {
  return requestHeadersByUrl.get(url) || {};
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    if (message?.type === "getState") {
      sendResponse({ ok: true, state: await getState() });
      return;
    }

    if (message?.type === "pageMediaCapture") {
      await captureFromPage(message, sender);
      sendResponse({ ok: true });
      return;
    }

    if (message?.type === "setState") {
      await setState(message.patch || {});
      sendResponse({ ok: true, state: await getState() });
      return;
    }

    if (message?.type === "download") {
      const state = await getState();
      const capture = message.capture || state.lastCapture;
      if (!capture?.url) throw new Error("No m3u8 capture available");
      if (capture.inferred && !capture.playlistBody) {
        throw new Error("Only media segments were captured. Reload the page and play from the beginning so the real playlist can be captured.");
      }

      const result = await sendToNative({
        ...capture,
        title: message.title || capture.title,
        workDir: message.workDir || todayToken(state.workDirTemplate)
      });
      sendResponse({ ok: true, result });
      return;
    }

    sendResponse({ ok: false, error: "Unknown message" });
  })().catch((error) => {
    sendResponse({ ok: false, error: error.message });
  });
  return true;
});
