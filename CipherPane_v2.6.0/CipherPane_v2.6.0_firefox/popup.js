const KEYS = [
  "malwareEnabled",
  "adsEnabled",
  "httpsUpgrade",
  "blockThirdPartyScripts",
  "strictFirewallMode",
  "downloadGuard",
  "httpAllowedDomains",
  "trustedDomains",
  "customBlockedDomains",
  "bulkBlockedDomains",
  "blockedCount",
  "autoUpdateEnabled",
  "autoUpdateHours",
  "heuristicProtection",
  "sourceEnabled",
  "autoListMeta",
  "syncStatus"
];

let currentHost = "";
let currentTabId = -1;

const MAX_FILE_BYTES = 10 * 1024 * 1024;
const { MAX_BULK, MAX_CUSTOM, MAX_TRUSTED } = CipherLists.LIMITS;
const MAX_RENDER_ROWS = 500;     // up to 20,000 custom blocks exist; drawing them all builds 20k DOM nodes + closures

function arr(x) { return Array.isArray(x) ? x : []; }
async function getArr(key) { return arr((await chrome.storage.local.get(key))[key]); }

// storage.local.set can fail (quota); show it instead of failing silently
async function safeSet(obj) {
  try { await chrome.storage.local.set(obj); return true; }
  catch (e) {
    const el = document.getElementById("popupErr");
    if (el) { el.textContent = "Could not save: " + String((e && e.message) || e).slice(0, 120); el.hidden = false; }
    return false;
  }
}
const DOMAIN_RE = CipherLists.DOMAIN_RE;

document.addEventListener("DOMContentLoaded", async () => {
  document.querySelectorAll(".tab-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".tab-btn").forEach(b => b.classList.remove("active"));
      document.querySelectorAll(".tab-content").forEach(c => c.classList.remove("active"));
      btn.classList.add("active");
      document.getElementById(btn.dataset.tab).classList.add("active");
      if (btn.dataset.tab === "loggerTab") loadTabLogs();
    });
  });

  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab) {
    currentTabId = tab.id;
    if (tab.url && tab.url.startsWith("http")) {
      try {
        currentHost = new URL(tab.url).hostname;
        document.getElementById("currentDomain").textContent = currentHost;
        if (!DOMAIN_RE.test(currentHost.toLowerCase())) {
          // raw IPs and single-label hosts cannot be matched by domain rules
          const tb = document.getElementById("trustSiteBtn");
          tb.disabled = true;
          tb.textContent = "Can't trust IP";
          currentHost = "";
        }
      } catch {
        document.getElementById("currentDomain").textContent = "Unavailable";
      }
    } else {
      document.getElementById("currentDomain").textContent = "Browser Page";
      document.getElementById("trustSiteBtn").disabled = true;
    }
  }

  const state = await chrome.storage.local.get(KEYS);
  renderUI(state);
  try { chrome.runtime.sendMessage({ type: "CLEAR_DOWNLOAD_ALERTS" }); } catch (e) {}
  renderDownloads();

  document.getElementById("openSettings").addEventListener("click", async () => {
    try { await chrome.runtime.openOptionsPage(); window.close(); } catch (e) {}
  });

  document.getElementById("downloadGuard").addEventListener("change", async (e) => {
    await chrome.storage.local.set({ downloadGuard: e.target.value });
  });

  ["malwareEnabled", "adsEnabled", "httpsUpgrade", "blockThirdPartyScripts", "strictFirewallMode"].forEach(id => {
    document.getElementById(id).addEventListener("change", async (e) => {
      await chrome.storage.local.set({ [id]: e.target.checked });
      renderUI(await chrome.storage.local.get(KEYS));
    });
  });

  document.getElementById("trustSiteBtn").addEventListener("click", async () => {
    if (!currentHost) return;
    const trustedDomains = CipherLists.cleanDomains(await getArr("trustedDomains")).slice(0, MAX_TRUSTED);
    const exists = trustedDomains.includes(currentHost);
    if (!exists && trustedDomains.length >= MAX_TRUSTED) {
      const el = document.getElementById("popupErr");
      el.textContent = `Trusted-site limit reached (${MAX_TRUSTED.toLocaleString()}). Remove a site before adding another.`;
      el.hidden = false;
      return;
    }
    const updatedList = exists
      ? trustedDomains.filter(d => d !== currentHost)
      : [...trustedDomains, currentHost];
    await safeSet({ trustedDomains: updatedList });
    renderUI(await chrome.storage.local.get(KEYS));
  });

  document.getElementById("addBlockBtn").addEventListener("click", async () => {
    const input = document.getElementById("blockDomainInput");
    const parsed = CipherLists.parseFilterLines(input.value, { lenient: true });
    if (!parsed.length) return;
    const customBlockedDomains = await getArr("customBlockedDomains");
    const merged = Array.from(new Set([...customBlockedDomains, ...parsed])).slice(0, MAX_CUSTOM);
    if (!(await safeSet({ customBlockedDomains: merged }))) return;
    input.value = "";
    renderUI(await chrome.storage.local.get(KEYS));
  });

  document.getElementById("refreshLogsBtn").addEventListener("click", loadTabLogs);
  document.getElementById("clearLogsBtn").addEventListener("click", async () => {
    if (currentTabId < 0) return;
    try { await chrome.runtime.sendMessage({ type: "CLEAR_TAB_LOGS", tabId: currentTabId }); } catch (e) {}
    loadTabLogs();
  });

  document.getElementById("bulkFileInput").addEventListener("change", (e) => {
    const file = e.target.files[0];
    if (!file) return;
    if (file.size > MAX_FILE_BYTES) {
      document.getElementById("bulkStatusText").textContent = "File too large (10 MB max).";
      e.target.value = "";
      return;
    }
    const reader = new FileReader();
    reader.onload = (ev) => {
      document.getElementById("bulkTextInput").value = ev.target.result;
      e.target.value = "";
    };
    reader.onerror = () => {
      document.getElementById("bulkStatusText").textContent = "Could not read that file.";
      e.target.value = "";
    };
    reader.readAsText(file);
  });

  document.getElementById("importBulkBtn").addEventListener("click", async () => {
    const raw = document.getElementById("bulkTextInput").value;
    const parsed = CipherLists.parseFilterLines(raw);
    if (!parsed.length) {
      document.getElementById("bulkStatusText").textContent = "No valid domains detected in input.";
      return;
    }
    const bulkBlockedDomains = await getArr("bulkBlockedDomains");
    const union = Array.from(new Set([...bulkBlockedDomains, ...parsed]));
    const merged = union.slice(0, MAX_BULK);
    if (!(await safeSet({ bulkBlockedDomains: merged }))) return;
    document.getElementById("bulkTextInput").value = "";
    await renderUI(await chrome.storage.local.get(KEYS));
    if (union.length > MAX_BULK) {
      document.getElementById("bulkStatusText").textContent =
        `${MAX_BULK.toLocaleString()} domain limit reached; ${(union.length - MAX_BULK).toLocaleString()} entries were not imported.`;
    }
  });

  const heuristicToggle = document.getElementById("heuristicProtection");
  if (heuristicToggle) heuristicToggle.addEventListener("change", async (e) => {
    await safeSet({ heuristicProtection: e.target.checked });
  });
  document.getElementById("autoUpdateEnabled").addEventListener("change", async (e) => {
    await chrome.storage.local.set({ autoUpdateEnabled: e.target.checked });
  });
  document.getElementById("autoUpdateHours").addEventListener("change", async (e) => {
    await chrome.storage.local.set({ autoUpdateHours: Number(e.target.value) });
  });
  document.getElementById("updateNowBtn").addEventListener("click", async (e) => {
    e.target.disabled = true;
    try { await chrome.runtime.sendMessage({ type: "UPDATE_LISTS_NOW" }); } catch (err) {}
    setTimeout(() => { e.target.disabled = false; }, 4000);
  });
  chrome.storage.onChanged.addListener(async (changes, area) => {
    if (area === "local" && changes.blockedCount && changes.blockedCount.newValue !== undefined) {
      document.getElementById("blockedCount").textContent = changes.blockedCount.newValue;
    }
    if (area === "local" && (changes.autoListMeta || changes.autoLists || changes.syncStatus)) {
      // Only the update panel and warning line change here; re-reading and redrawing every list
      // (bulk list = up to 100,000 strings) on each progress write is wasted memory.
      refreshAutoPanel();
    }
    if (area === "session" && changes.blockedDownloads) renderDownloads();
  });

  document.getElementById("clearBulkBtn").addEventListener("click", async () => {
    await safeSet({ bulkBlockedDomains: [] });
    renderUI(await chrome.storage.local.get(KEYS));
  });
});

async function refreshAutoPanel() {
  const st = await chrome.storage.local.get(["autoUpdateEnabled", "autoUpdateHours", "sourceEnabled", "autoListMeta", "syncStatus"]);
  renderAuto(st);
  renderSyncWarn(st.syncStatus);
}

function renderSyncWarn(ss) {
  const sw = document.getElementById("syncWarn");
  if (sw) { sw.hidden = !(ss && ss.ok === false); sw.textContent = ss && ss.ok === false ? "Rules problem: " + String(ss.msg || "unknown error") : ""; }
}

async function loadTabLogs() {
  if (currentTabId < 0) return;
  let res = null;
  try { res = await chrome.runtime.sendMessage({ type: "GET_TAB_LOGS", tabId: currentTabId }); } catch (e) {}
  const logs = (res && res.logs) || [];
  const container = document.getElementById("logContainer");
  container.textContent = "";
  if (!logs.length) {
    const note = document.createElement("div");
    note.className = "desc empty-note";
    note.textContent = "No logged requests yet. Reload the active tab to capture traffic.";
    container.appendChild(note);
    return;
  }
  const STATUSES = ["ALLOWED", "BLOCKED", "ERROR"];
  for (const item of logs) {
    const row = document.createElement("div");
    row.className = "log-item";
    row.title = String(item.url || "");
    const badge = document.createElement("span");
    const status = STATUSES.includes(item.status) ? item.status : "ERROR";
    badge.className = `log-badge log-${status}`;
    badge.textContent = status;
    const hostEl = document.createElement("span");
    hostEl.className = "log-host";
    hostEl.textContent = String(item.host || "");
    const typeEl = document.createElement("span");
    typeEl.className = "log-type";
    typeEl.textContent = String(item.type || "");
    row.append(badge, hostEl, typeEl);
    if (item.status === "ALLOWED" && item.host !== currentHost && DOMAIN_RE.test(String(item.host).toLowerCase())) {
      const blkBtn = document.createElement("button");
      blkBtn.className = "log-block-btn";
      blkBtn.textContent = "Block";
      blkBtn.onclick = async () => {
        const customBlockedDomains = await getArr("customBlockedDomains");
        if (!customBlockedDomains.includes(item.host) && customBlockedDomains.length < MAX_CUSTOM) {
          await safeSet({ customBlockedDomains: [...customBlockedDomains, item.host] });
        }
        blkBtn.textContent = "Blocked";
        blkBtn.disabled = true;
      };
      row.appendChild(blkBtn);
    }
    container.appendChild(row);
  }
}

async function renderDownloads() {
  const sec = document.getElementById("dlSection");
  const ul = document.getElementById("dlList");
  let list = [];
  try {
    if (chrome.storage.session) list = arr((await chrome.storage.session.get("blockedDownloads")).blockedDownloads);
  } catch (e) {}
  ul.textContent = "";
  sec.hidden = !list.length;
  for (const d of list) {
    const li = document.createElement("li");
    const row = document.createElement("div");
    row.className = "dl-row";
    const name = document.createElement("span");
    name.className = "dl-name";
    name.textContent = String(d.name || "download");
    const btn = document.createElement("button");
    btn.className = "btn-small btn-muted";
    btn.textContent = "Allow";
    btn.title = d.canAllow === false ? "Cannot be re-downloaded from here" : "Download it anyway (once)";
    if (d.canAllow === false) btn.disabled = true;
    btn.addEventListener("click", async () => {
      btn.disabled = true;
      try { await chrome.runtime.sendMessage({ type: "ALLOW_DOWNLOAD", id: d.id }); } catch (e) {}
      renderDownloads();
    });
    row.append(name, btn);
    const why = document.createElement("div");
    why.className = "dl-why";
    why.textContent = String(d.reason || "");
    const host = document.createElement("div");
    host.className = "dl-host";
    host.textContent = String(d.host || "");
    li.append(row, why, host);
    ul.appendChild(li);
  }
}

function renderUI(state) {
  document.getElementById("downloadGuard").value = ["off", "balanced", "strict"].includes(state.downloadGuard) ? state.downloadGuard : "balanced";
  const httpList = document.getElementById("httpList");
  const httpOk = arr(state.httpAllowedDomains);
  document.getElementById("httpSection").hidden = !httpOk.length;
  httpList.textContent = "";
  httpOk.forEach(domain => {
    const li = document.createElement("li");
    const label = document.createElement("span");
    label.textContent = domain;
    const btn = document.createElement("button");
    btn.textContent = "\u2715";
    btn.className = "remove-btn";
    btn.title = "Stop allowing HTTP for this site";
    btn.onclick = async () => {
      const fresh = await getArr("httpAllowedDomains");
      await safeSet({ httpAllowedDomains: fresh.filter(d => d !== domain) });
      renderUI(await chrome.storage.local.get(KEYS));
    };
    li.append(label, btn);
    httpList.appendChild(li);
  });

  document.getElementById("malwareEnabled").checked = state.malwareEnabled !== false;
  document.getElementById("adsEnabled").checked = state.adsEnabled !== false;
  document.getElementById("httpsUpgrade").checked = state.httpsUpgrade !== false;
  document.getElementById("blockThirdPartyScripts").checked = !!state.blockThirdPartyScripts;
  document.getElementById("strictFirewallMode").checked = !!state.strictFirewallMode;
  document.getElementById("blockedCount").textContent = state.blockedCount || 0;

  const bulkCount = arr(state.bulkBlockedDomains).length;
  document.getElementById("bulkStatusText").textContent = `${bulkCount.toLocaleString()} manually imported domains`;
  renderAuto(state);
  renderSyncWarn(state.syncStatus);

  const trusted = CipherLists.cleanDomains(state.trustedDomains).slice(0, MAX_TRUSTED).includes(currentHost);
  const trustBtn = document.getElementById("trustSiteBtn");
  if (currentHost) {
    trustBtn.textContent = trusted ? "Trusted ✓" : "Trust Site";
    trustBtn.classList.toggle("trusted", trusted);
  }

  const listEl = document.getElementById("customBlockList");
  listEl.textContent = "";
  const customAll = arr(state.customBlockedDomains);
  customAll.slice(0, MAX_RENDER_ROWS).forEach(domain => {
    const li = document.createElement("li");
    const label = document.createElement("span");
    label.textContent = domain;
    li.appendChild(label);
    const btn = document.createElement("button");
    btn.textContent = "✕";
    btn.className = "remove-btn";
    btn.onclick = async () => {
      const fresh = await getArr("customBlockedDomains");
      const next = fresh.filter(d => d !== domain);
      await safeSet({ customBlockedDomains: next });
      renderUI(await chrome.storage.local.get(KEYS));
    };
    li.appendChild(btn);
    listEl.appendChild(li);
  });
  if (customAll.length > MAX_RENDER_ROWS) {
    const more = document.createElement("li");
    more.className = "desc";
    more.textContent = `\u2026and ${(customAll.length - MAX_RENDER_ROWS).toLocaleString()} more (all are still enforced)`;
    listEl.appendChild(more);
  }
}

const fmtAge = CipherLists.fmtAge;

function renderAuto(state) {
  document.getElementById("autoUpdateEnabled").checked = state.autoUpdateEnabled !== false;
  const heuristicToggle = document.getElementById("heuristicProtection");
  if (heuristicToggle) heuristicToggle.checked = state.heuristicProtection !== false;
  const sel = document.getElementById("autoUpdateHours");
  sel.value = String(state.autoUpdateHours || 6);
  if (!sel.value) sel.value = "6";

  const meta = state.autoListMeta || {};
  const per = meta.sources || {};
  const enabledMap = state.sourceEnabled || {};
  const ul = document.getElementById("sourceList");
  ul.textContent = "";
  for (const src of CipherLists.SOURCES) {
    const on = typeof enabledMap[src.id] === "boolean" ? enabledMap[src.id] : src.enabled;
    const s = per[src.id];
    const li = document.createElement("li");
    li.className = "source-item";
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = on;
    cb.addEventListener("change", async () => {
      const got = (await chrome.storage.local.get("sourceEnabled")).sourceEnabled;
      const cur = (got && typeof got === "object" && !Array.isArray(got)) ? got : {};
      cur[src.id] = cb.checked;
      await safeSet({ sourceEnabled: cur });
    });
    const info = document.createElement("div");
    info.className = "source-info";
    const name = document.createElement("div");
    name.className = "title";
    name.textContent = `${src.name} \u2013 ${src.kind}`;
    const line = document.createElement("div");
    line.className = "desc";
    if (!on) {
      line.textContent = "Off";
    } else if (!s) {
      line.textContent = "Not downloaded yet";
    } else if (s.ok) {
      line.textContent = `${(s.count || 0).toLocaleString()} domains, checked ${fmtAge(s.ts)}` +
        (s.note ? ` (${s.note})` : "");
    } else {
      line.classList.add("source-fail");
      line.textContent = `Failed: ${s.error || "error"}` +
        (s.count ? ` \u2013 still using previous ${s.count.toLocaleString()} domains` : "");
    }
    info.append(name, line);
    li.append(cb, info);
    ul.appendChild(li);
  }

  const status = document.getElementById("autoStatusText");
  if (meta.running && Date.now() - meta.running < 180000) status.textContent = "Updating lists\u2026";
  else if (meta.lastOk) status.textContent = `Last successful update: ${fmtAge(meta.lastOk)}`;
  else if (meta.lastRun) status.textContent = `Last attempt ${fmtAge(meta.lastRun)} had errors`;
  else status.textContent = "No update has run yet";
}
