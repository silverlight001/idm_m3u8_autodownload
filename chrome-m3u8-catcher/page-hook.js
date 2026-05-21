(function () {
  if (window.__m3u8dlPageHookInstalled) return;
  window.__m3u8dlPageHookInstalled = true;

  function emit(url, body) {
    if (!url && !body) return;
    const text = String(body || "");
    const targetUrl = String(url || "");
    if (!/\.m3u8(?:[?#]|$)/i.test(targetUrl) && !/#EXTM3U/i.test(text)) return;
    window.postMessage({
      source: "m3u8dl-page-hook",
      url: targetUrl,
      body: text.slice(0, 1024 * 1024)
    }, "*");
  }

  function scanText(text, baseUrl) {
    const source = String(text || "");
    const absolute = /https?:\/\/[^'"\s<>]+?\.m3u8[^'"\s<>]*/ig;
    let match;
    while ((match = absolute.exec(source))) emit(match[0], "");

    const relative = /['"]([^'"]+?\.m3u8[^'"]*)['"]/ig;
    while ((match = relative.exec(source))) {
      try {
        emit(new URL(match[1], baseUrl || location.href).href, "");
      } catch {
      }
    }
  }

  const nativeFetch = window.fetch;
  if (typeof nativeFetch === "function") {
    window.fetch = async function (...args) {
      const response = await nativeFetch.apply(this, args);
      try {
        const url = response.url || String(args[0]?.url || args[0] || "");
        if (/\.m3u8(?:[?#]|$)/i.test(url)) {
          response.clone().text().then((body) => emit(url, body)).catch(() => emit(url, ""));
        } else {
          response.clone().text().then((body) => emit(url, body)).catch(() => {});
        }
      } catch {
      }
      return response;
    };
  }

  const nativeOpen = XMLHttpRequest.prototype.open;
  const nativeSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url, ...rest) {
    this.__m3u8dlUrl = String(url || "");
    return nativeOpen.call(this, method, url, ...rest);
  };
  XMLHttpRequest.prototype.send = function (...args) {
    this.addEventListener("load", function () {
      try {
        const body = typeof this.responseText === "string" ? this.responseText : "";
        emit(this.responseURL || this.__m3u8dlUrl || "", body);
      } catch {
      }
    });
    return nativeSend.apply(this, args);
  };

  function scanPage() {
    try {
      scanText(document.documentElement && document.documentElement.innerHTML, location.href);
      for (const entry of performance.getEntriesByType("resource")) {
        if (/\.m3u8(?:[?#]|$)/i.test(entry.name)) emit(entry.name, "");
      }
    } catch {
    }
  }

  setTimeout(scanPage, 500);
  setTimeout(scanPage, 2000);
  setInterval(scanPage, 5000);
})();
