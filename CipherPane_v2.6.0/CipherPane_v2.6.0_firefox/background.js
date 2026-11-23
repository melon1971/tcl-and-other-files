// CipherPane Browser Security v2.6.0 background service worker.
//
// Rule priority map (highest wins):
//   1001  private-LAN IP exemption for the raw-IP file rules (static ruleset, fully anchored)
//   1000  malware/phishing static ruleset         -- never overridden
//    200  user custom blocks                      -- explicit user choice beats Trust
//    150  downloaded malware + phishing lists     -- NOT overridden by Trust (turn the source off instead)
//    100  trusted-site allow rules                -- https only for page/frame loads, so Trust never disables the HTTPS upgrade
//     40  other imported lists (manual import, ad/tracker lists)
//     30  login/payment/captcha exemptions for Strict and Third-Party Script Blocker
//     20  strict outbound firewall
//     10  third-party script blocker
//      6  "allow HTTP" exceptions (exact host only) for sites without HTTPS
//      5  HTTPS upgrade
//      1  ads/trackers static ruleset
//
// Service-worker rule: this worker can be killed at any time. Anything that must survive
// (HTTPS-fallback hints, one-time download allows, request logs) is mirrored to storage.session.

if (typeof importScripts === "function") importScripts("lists.js", "reputation.js");
const { cleanDomains, mergedBulk, sourceOn } = CipherLists;

const DEFAULT_STATE = {
  malwareEnabled: true,
  adsEnabled: true,
  httpsUpgrade: true,
  blockThirdPartyScripts: false,
  strictFirewallMode: false,
  downloadGuard: "balanced",
  httpAllowedDomains: [],
  trustedDomains: [],
  customBlockedDomains: [],
  bulkBlockedDomains: [],
  blockedCount: 0,
  autoUpdateEnabled: true,
  autoUpdateHours: 6,
  heuristicProtection: true,
  heuristicAllowDomains: [],
  sourceEnabled: {},
  autoLists: {},
  autoListMeta: {},
  syncStatus: { ok: true, msg: "", ts: 0 }
};

const { MAX_BULK, MAX_CUSTOM, MAX_HTTP_ALLOWED, MAX_TRUSTED, MAX_HEURISTIC_ALLOW } = CipherLists.LIMITS;
const CHUNK_SIZE = 500;

function chunk(arr, size) {
  const out = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

function errText(e) {
  if (e && e.name === "AbortError") return "timed out";
  return String((e && e.message) || e).slice(0, 240);
}

// ---------- session-backed map (survives the worker being killed) ----------
const SESS = (chrome.storage && chrome.storage.session) || null;

function makeStore(key) {
  const m = new Map();
  const validEntry = (k, v) => {
    if (key === "dlAllowed") {
      return typeof k === "string" && k.length <= 2048 && /^https?:\/\//i.test(k) &&
             Number.isFinite(v) && v > Date.now();
    }
    if (key === "upgraded") {
      return /^\d{1,12}$/.test(k) && v && typeof v === "object" &&
             typeof v.host === "string" && v.host.length <= 253 &&
             typeof v.httpUrl === "string" && v.httpUrl.length <= 2048 &&
             Number.isFinite(v.ts) && Date.now() - v.ts <= 120000;
    }
    return false;
  };
  const ready = SESS
    ? SESS.get(key).then((r) => {
        const o = (r && r[key] && typeof r[key] === "object" && !Array.isArray(r[key])) ? r[key] : {};
        for (const k of Object.keys(o).slice(-1000)) {
          if (!m.has(k) && validEntry(k, o[k])) m.set(k, o[k]);
        }
      }).catch(() => {})
    : Promise.resolve();
  const save = () => {
    if (!SESS) return;
    for (const [k, v] of m) if (!validEntry(k, v)) m.delete(k);
    while (m.size > 1000) m.delete(m.keys().next().value);
    SESS.set({ [key]: Object.fromEntries(m) }).catch(() => {});
  };
  return { m, ready, save };
}

// ---------- per-tab request log (query strings stripped) ----------
const tabLogs = {};
const LOG_MAX = 150;              // entries kept per tab
const LOG_MAX_TABS = 500;         // tabs kept
const LOG_URL_MAX = 512;          // a page controls its own URL paths; never store them whole
const LOG_BYTE_BUDGET = 4 * 1024 * 1024;   // storage.session quota is ~10 MB shared with other keys

let logsReady = SESS
  ? SESS.get("tabLogs").then(async (r) => {
      const saved = (r && r.tabLogs && typeof r.tabLogs === "object" && !Array.isArray(r.tabLogs)) ? r.tabLogs : {};
      let open = null;
      try { open = new Set((await chrome.tabs.query({})).map(t => String(t.id))); } catch (e) {}
      for (const k of Object.keys(saved).slice(-1000)) {
        if (!/^\d{1,12}$/.test(k) || (open && !open.has(k))) continue;
        if (!Array.isArray(saved[k])) continue;
        const clean = saved[k].slice(0, LOG_MAX).filter(e => e && typeof e === "object" &&
          ["ALLOWED", "BLOCKED", "ERROR"].includes(e.status) &&
          typeof e.host === "string" && e.host.length <= 253 &&
          typeof e.type === "string" && e.type.length <= 40 &&
          typeof e.url === "string" && e.url.length <= 2048);
        tabLogs[k] = (Array.isArray(tabLogs[k]) ? tabLogs[k] : []).concat(clean).slice(0, LOG_MAX);
      }
    }).catch(() => {})
  : Promise.resolve();

let saveTimer = null;
function flushLogs() {
  if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; }
  if (!SESS) return;
  // Persist newest tabs first, within a byte budget: one oversized write would be rejected by the
  // storage quota and lose every tab's log, and serializing it would spike worker memory.
  const out = {};
  let bytes = 0;
  const ids = Object.keys(tabLogs).sort((a, b) => Number(b) - Number(a)).slice(0, LOG_MAX_TABS);
  for (const k of ids) {
    const list = tabLogs[k];
    if (!Array.isArray(list)) continue;
    let est = 16;
    for (const e of list) est += e.url.length + e.host.length + e.type.length + 70;
    if (bytes + est > LOG_BYTE_BUDGET) continue;
    out[k] = list;
    bytes += est;
  }
  SESS.set({ tabLogs: out }).catch(() => {});
}
function scheduleLogSave() {
  if (!SESS || saveTimer) return;
  saveTimer = setTimeout(() => { saveTimer = null; flushLogs(); }, 800);
}

function safeUrl(u) {
  try {
    const p = new URL(u);
    return `${p.protocol}//${p.host}${p.pathname}`;
  } catch {
    return "";
  }
}

// The one place a tab's log array is created, so the tab cap holds for every caller.
// (Integer keys enumerate in ascending order, so the entry evicted at the cap is the lowest tab id.)
function ensureTabLog(tabId) {
  if (!Number.isSafeInteger(tabId) || tabId < 0) return null;
  if (!Object.prototype.hasOwnProperty.call(tabLogs, tabId) || !Array.isArray(tabLogs[tabId])) {
    const keys = Object.keys(tabLogs);
    if (keys.length >= LOG_MAX_TABS) delete tabLogs[keys[0]];
    tabLogs[tabId] = [];
  }
  return tabLogs[tabId];
}

// Log record with every field length-bounded at write time.
function logEntry(status, details) {
  let host = "";
  try { host = new URL(details.url).hostname; } catch { return null; }
  return {
    time: Date.now(),
    status,
    host: host.slice(0, 253),
    type: String(details.type || "").slice(0, 40),
    url: safeUrl(details.url).slice(0, LOG_URL_MAX)
  };
}

function pushLog(tabId, entry) {
  const list = ensureTabLog(tabId);
  if (!list || !entry) return;
  list.unshift(entry);
  if (list.length > LOG_MAX) list.length = LOG_MAX;
  scheduleLogSave();
}

// Drop logs of tabs that no longer exist (an onRemoved event is missed while the worker is stopped).
async function pruneTabLogs() {
  try {
    const open = new Set((await chrome.tabs.query({})).map(t => String(t.id)));
    let changed = false;
    for (const k of Object.keys(tabLogs)) if (!open.has(k)) { delete tabLogs[k]; changed = true; }
    if (changed) scheduleLogSave();
  } catch (e) {}
}

function isOwnPage(u, name) {
  try {
    const p = new URL(u);
    return (p.protocol === "chrome-extension:" || p.protocol === "moz-extension:") &&
           (!name || p.pathname === "/" + name);
  } catch { return false; }
}

// HTTPS-upgrade hints: tabId -> { host, httpUrl, ts }
const upgraded = makeStore("upgraded");
function upgSet(tabId, rec) {
  upgraded.ready.then(() => {
    upgraded.m.set(String(tabId), rec);
    upgraded.save();
  }).catch(() => {});
}
function upgDel(tabId) {
  upgraded.ready.then(() => {
    if (upgraded.m.delete(String(tabId))) upgraded.save();
  }).catch(() => {});
}

chrome.tabs.onRemoved.addListener((tabId) => {
  delete tabLogs[tabId];
  upgDel(tabId);
  scheduleLogSave();
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "loading" && changeInfo.url && !isOwnPage(changeInfo.url)) {
    const list = ensureTabLog(tabId);
    if (list) { list.length = 0; scheduleLogSave(); }
  }
});

chrome.webRequest.onCompleted.addListener(
  (details) => {
    try {
      if (isOwnPage(details.url)) return;
      if (details.tabId >= 0) pushLog(details.tabId, logEntry("ALLOWED", details));
      if (details.type === "main_frame") upgDel(details.tabId);
    } catch {}
  },
  { urls: ["<all_urls>"] }
);

// ---------- blocked counter ----------
// Blocks are added in memory and flushed in one write. The flush also runs on onSuspend,
// so a worker that is stopped normally keeps its count (a hard kill can still lose <0.5 s).
let pendingBlocks = 0;
let flushTimer = null;
let counterChain = Promise.resolve();
function flushBlocks() {
  if (flushTimer) { clearTimeout(flushTimer); flushTimer = null; }
  const add = pendingBlocks;
  pendingBlocks = 0;
  if (!add) return counterChain;
  counterChain = counterChain.then(async () => {
    const { blockedCount = 0 } = await chrome.storage.local.get("blockedCount");
    await chrome.storage.local.set({ blockedCount: (Number(blockedCount) || 0) + add });
  }).catch(() => {});
  return counterChain;
}
function bumpBlockedCount(n) {
  pendingBlocks += (n || 1);
  if (!flushTimer) flushTimer = setTimeout(() => { flushTimer = null; flushBlocks(); }, 500);
}
if (chrome.runtime.onSuspend) {
  chrome.runtime.onSuspend.addListener(() => { flushBlocks(); flushLogs(); });
}

chrome.webRequest.onErrorOccurred.addListener(
  (details) => {
    try {
      if (isOwnPage(details.url)) return;
      const err = String(details.error || "");
      const isBlocked = err === "net::ERR_BLOCKED_BY_CLIENT" || err === "NS_ERROR_ABORT";
      if (details.tabId >= 0) pushLog(details.tabId, logEntry(isBlocked ? "BLOCKED" : "ERROR", details));
      if (isBlocked) bumpBlockedCount();
      if (details.type === "main_frame") maybeHttpsFallback(details, err).catch(() => {});
    } catch {}
  },
  { urls: ["<all_urls>"] }
);

chrome.webRequest.onBeforeRedirect.addListener(
  (details) => {
    try {
      if (isOwnPage(details.redirectUrl, "blocked.html")) {
        if (details.tabId >= 0) pushLog(details.tabId, logEntry("BLOCKED", details));
        bumpBlockedCount();
        return;
      }
      if (details.type === "main_frame" && details.url.startsWith("http:") && details.url.length <= 2048 &&
          details.redirectUrl.startsWith("https:") && Number.isInteger(details.tabId) && details.tabId >= 0) {
        const from = new URL(details.url), to = new URL(details.redirectUrl);
        if (from.hostname === to.hostname && /Internal Redirect/i.test(details.statusLine || "Internal Redirect")) {
          upgSet(details.tabId, { host: from.hostname, httpUrl: details.url, ts: Date.now() });
        }
      }
    } catch {}
  },
  { urls: ["<all_urls>"] }
);

// ---------- HTTPS-first with HTTP fallback ----------
// If the HTTPS attempt fails because the site has no HTTPS service, the tab is sent to a warning
// page. Certificate errors never offer a downgrade. Errors a network attacker can cause on demand
// (reset / closed / protocol error) offer "continue once" only; "always allow" is offered only after
// a refused connection or a timeout.
const NO_HTTPS_ERR = /CONNECTION_REFUSED|CONNECTION_TIMED_OUT|CONNECTION_RESET|CONNECTION_CLOSED|EMPTY_RESPONSE|SSL_PROTOCOL_ERROR|SSL_VERSION_OR_CIPHER_MISMATCH|NET_TIMEOUT|NET_RESET|NET_INTERRUPT|SSL_ERROR_(RX_RECORD_TOO_LONG|NO_CYPHER_OVERLAP|PROTOCOL_VERSION_ALERT)/;
const STRONG_NO_HTTPS = /CONNECTION_REFUSED|CONNECTION_TIMED_OUT|NET_TIMEOUT/;
const FALLBACK_WINDOW_MS = 120000;

async function maybeHttpsFallback(details, err) {
  await upgraded.ready;
  const rec = upgraded.m.get(String(details.tabId));
  if (!rec) return;
  upgDel(details.tabId);
  if (Date.now() - rec.ts > FALLBACK_WINDOW_MS) return;
  if (!details.url.startsWith("https:")) return;
  if (new URL(details.url).hostname !== rec.host) return;
  if (/CERT|CERTIFICATE|BAD_CERT/i.test(err) || !NO_HTTPS_ERR.test(err)) return;
  const strong = STRONG_NO_HTTPS.test(err) ? "1" : "0";
  try {
    await chrome.tabs.update(details.tabId, {
      url: chrome.runtime.getURL("nohttps.html") + "?u=" + encodeURIComponent(rec.httpUrl) + "&s=" + strong
    });
  } catch {}
}

// "allow HTTP for this browser session": exact host only (urlFilter, not requestDomains,
// so subdomains are not included)
function httpRuleFilter(host) { return "|http://" + host + "^"; }

let sessionChain = Promise.resolve();
const MAX_SESSION_HTTP_RULES = 200;   // session rules live until the browser closes; keep them bounded
function allowHttpForSession(host) {
  sessionChain = sessionChain.then(async () => {
    const rules = await chrome.declarativeNetRequest.getSessionRules();
    const f = httpRuleFilter(host);
    if (rules.some(r => r.condition.urlFilter === f)) return;
    const id = rules.reduce((m, r) => Math.max(m, r.id), 0) + 1;
    const mine = rules.filter(r => r.priority === 6 && r.action && r.action.type === "allow")
                      .sort((a, b) => a.id - b.id);
    const removeRuleIds = mine.slice(0, Math.max(0, mine.length - (MAX_SESSION_HTTP_RULES - 1))).map(r => r.id);
    await chrome.declarativeNetRequest.updateSessionRules({
      removeRuleIds,
      addRules: [{ id, priority: 6, action: { type: "allow" },
                   condition: { urlFilter: f, resourceTypes: ["main_frame", "sub_frame"] } }]
    });
  }).catch((e) => console.warn("session rule failed:", e));
  return sessionChain;
}

// ---------- Download Guard ----------
const dlHandled = new Set();          // downloads already cancelled
const dlBusy = new Set();             // downloads being judged right now (stops double processing)
const dlAllowed = makeStore("dlAllowed");   // url -> expiry (ms), survives worker restarts
const DL_ALLOW_MS = 5 * 60000;

async function dlIsAllowed(item) {
  await dlAllowed.ready;
  const now = Date.now();
  let changed = false;
  for (const [u, t] of dlAllowed.m) if (t < now) { dlAllowed.m.delete(u); changed = true; }
  if (changed) dlAllowed.save();
  return dlAllowed.m.has(item.url) || !!(item.finalUrl && dlAllowed.m.has(item.finalUrl));
}

// blockedDownloads is read-modify-write: serialize every change so entries are not lost
let dlChain = Promise.resolve();
function mutateBlocked(fn) {
  const p = dlChain.then(async () => {
    if (!SESS) return null;
    const { blockedDownloads = [] } = await SESS.get("blockedDownloads");
    const next = fn(Array.isArray(blockedDownloads) ? blockedDownloads.slice() : []);
    await SESS.set({ blockedDownloads: next });
    return next;
  });
  dlChain = p.catch(() => {});
  return p;
}

function recordBlockedDownload(item, verdict) {
  let host = "";
  try {
    const u = new URL(item.finalUrl || item.url);
    host = u.protocol === "blob:" ? new URL(u.pathname).hostname : u.hostname;
  } catch {}
  const raw = String(item.url || "");
  const canAllow = /^https?:\/\//i.test(raw) && raw.length <= 2048;   // never keep data:/blob: payloads
  const entry = {
    id: String(Date.now()) + Math.random().toString(36).slice(2, 7),
    t: Date.now(),
    name: (String(item.filename || "").split(/[\\/]/).pop() ||
           (safeUrl(item.url).split("/").pop() || "download")).slice(0, 255),
    host: host.slice(0, 253), reason: String(verdict.reason || "").slice(0, 200), tier: verdict.tier,
    url: canAllow ? raw : "", canAllow
  };
  return mutateBlocked((list) => { list.unshift(entry); return list.slice(0, 20); });
}

async function guardDownload(item) {
  if (!item || dlHandled.has(item.id) || dlBusy.has(item.id)) return;
  dlBusy.add(item.id);
  try {
    if (await dlIsAllowed(item)) return;
    const st = await chrome.storage.local.get({ downloadGuard: "balanced", trustedDomains: [] });
    if (st.downloadGuard !== "balanced" && st.downloadGuard !== "strict") return;
    const verdict = CipherLists.checkDownload(item, { mode: st.downloadGuard, trusted: cleanDomains(st.trustedDomains) });
    if (!verdict) return;
    while (dlHandled.size >= 1000) dlHandled.delete(dlHandled.values().next().value);
    dlHandled.add(item.id);
    try { await chrome.downloads.cancel(item.id); } catch {}
    try { await chrome.downloads.removeFile(item.id); } catch {}
    try { await chrome.downloads.erase({ id: item.id }); } catch {}
    await recordBlockedDownload(item, verdict).catch(() => {});
    bumpBlockedCount();
    try { chrome.action.setBadgeBackgroundColor({ color: "#e11d48" }); chrome.action.setBadgeText({ text: "!" }); } catch {}
  } finally {
    dlBusy.delete(item.id);
  }
}

if (chrome.downloads) {
  chrome.downloads.onCreated.addListener((item) => { guardDownload(item).catch(() => {}); });
  chrome.downloads.onChanged.addListener((delta) => {
    if (dlHandled.has(delta.id) || !(delta.filename || delta.mime || delta.finalUrl)) return;
    chrome.downloads.search({ id: delta.id }).then((r) => { if (r && r[0]) return guardDownload(r[0]); }).catch(() => {});
  });
}

// What the HTTP-fallback warning page was opened for, read from that page's own URL
// (?u=<http url>&s=<1 if "always" may be offered>).
function nohttpsContext(senderUrl) {
  try {
    const p = new URL(senderUrl);
    const raw = p.searchParams.get("u") || "";
    if (raw.length > 2048) return null;
    const u = new URL(raw);
    if (u.protocol !== "http:" || u.username || u.password) return null;
    return { host: CipherLists.normalizeHost(u.hostname), strong: p.searchParams.get("s") === "1" };
  } catch (e) { return null; }
}

// ---------- messages: only our own extension pages may talk to the worker ----------
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!sender || sender.id !== chrome.runtime.id) return false;
  if (!sender.url || !sender.url.startsWith(chrome.runtime.getURL(""))) return false;
  if (!msg || typeof msg !== "object") return false;
  if (msg.type === "UPDATE_LISTS_NOW" && (isOwnPage(sender.url, "popup.html") || isOwnPage(sender.url, "options.html"))) {
    updateLists();
    sendResponse({ ok: true });
    return true;
  }
  if (msg.type === "ALLOW_HTTP" && isOwnPage(sender.url, "nohttps.html")) {
    const host = typeof msg.host === "string" && msg.host.length <= 253 ? CipherLists.normalizeHost(msg.host) : "";
    // The warning page's own URL says which host it was opened for and whether "always" may be
    // offered. Enforce both here, not only in the page: the worker is the one that writes the rule.
    const ctx = nohttpsContext(sender.url);
    if (!host || !ctx || ctx.host !== host || (msg.mode !== "always" && msg.mode !== "session") ||
        (msg.mode === "always" && !ctx.strong)) {
      sendResponse({ ok: false });
      return false;
    }
    (async () => {
      if (msg.mode === "always") {
        const { httpAllowedDomains } = await chrome.storage.local.get("httpAllowedDomains");
        const cur = cleanDomains(httpAllowedDomains);
        if (!cur.includes(host)) {
          if (cur.length >= MAX_HTTP_ALLOWED) { sendResponse({ ok: false }); return; }
          await chrome.storage.local.set({ httpAllowedDomains: [...cur, host] });
        }
        await queueSync();
      } else {
        await allowHttpForSession(host);
      }
      sendResponse({ ok: true });
    })().catch(() => sendResponse({ ok: false }));
    return true;
  }
  if (msg.type === "ALLOW_DOWNLOAD" && isOwnPage(sender.url, "popup.html")) {
    if (typeof msg.id !== "string" || msg.id.length > 64) { sendResponse({ ok: false }); return false; }
    (async () => {
      const { blockedDownloads = [] } = SESS ? await SESS.get("blockedDownloads") : {};
      const entry = (Array.isArray(blockedDownloads) ? blockedDownloads : []).find(e => e && e.id === msg.id);
      if (!entry || !entry.url) { sendResponse({ ok: false }); return; }
      await dlAllowed.ready;
      dlAllowed.m.set(entry.url, Date.now() + DL_ALLOW_MS);
      dlAllowed.save();
      await mutateBlocked((list) => list.filter(e => e.id !== msg.id));
      try { await chrome.downloads.download({ url: entry.url }); } catch (e) { sendResponse({ ok: false }); return; }
      sendResponse({ ok: true });
    })().catch(() => sendResponse({ ok: false }));
    return true;
  }
  if (msg.type === "CLEAR_DOWNLOAD_ALERTS" && isOwnPage(sender.url, "popup.html")) {
    try { chrome.action.setBadgeText({ text: "" }); } catch {}
    sendResponse({ ok: true });
    return true;
  }
  if (!Number.isSafeInteger(msg.tabId) || msg.tabId < 0 || !isOwnPage(sender.url, "popup.html")) return false;
  if (msg.type === "GET_TAB_LOGS") {
    logsReady.then(() => {
      const l = Object.prototype.hasOwnProperty.call(tabLogs, msg.tabId) ? tabLogs[msg.tabId] : null;
      sendResponse({ logs: Array.isArray(l) ? l : [] });
    });
    return true;
  }
  if (msg.type === "CLEAR_TAB_LOGS") {
    if (Object.prototype.hasOwnProperty.call(tabLogs, msg.tabId) && Array.isArray(tabLogs[msg.tabId])) {
      tabLogs[msg.tabId].length = 0;
      scheduleLogSave();
    }
    sendResponse({ ok: true });
    return true;
  }
  return false;
});

// ---------- lifecycle ----------
chrome.runtime.onInstalled.addListener(async () => {
  // Only the keys this extension owns: get(null) would pull every stored list into memory at once.
  const existing = await chrome.storage.local.get(Object.keys(DEFAULT_STATE));
  const state = { ...DEFAULT_STATE, ...existing };
  // Normalize and cap persisted collections during install/update migration.
  state.trustedDomains = cleanDomains(state.trustedDomains).slice(0, MAX_TRUSTED);
  state.customBlockedDomains = cleanDomains(state.customBlockedDomains).slice(0, MAX_CUSTOM);
  state.httpAllowedDomains = cleanDomains(state.httpAllowedDomains).slice(0, MAX_HTTP_ALLOWED);
  state.bulkBlockedDomains = cleanDomains(state.bulkBlockedDomains).slice(0, MAX_BULK);
  state.heuristicAllowDomains = cleanDomains(state.heuristicAllowDomains).slice(0, MAX_HEURISTIC_ALLOW);
  if (typeof state.heuristicProtection !== "boolean") state.heuristicProtection = true;
  const oldAuto = state.autoLists && typeof state.autoLists === "object" && !Array.isArray(state.autoLists)
    ? state.autoLists : {};
  state.autoLists = {};
  for (const src of CipherLists.SOURCES) {
    if (Array.isArray(oldAuto[src.id])) state.autoLists[src.id] = cleanDomains(oldAuto[src.id]).slice(0, MAX_BULK);
  }
  state.sourceEnabled = state.sourceEnabled && typeof state.sourceEnabled === "object" && !Array.isArray(state.sourceEnabled)
    ? state.sourceEnabled : {};
  state.autoListMeta = state.autoListMeta && typeof state.autoListMeta === "object" && !Array.isArray(state.autoListMeta)
    ? state.autoListMeta : {};
  if (!["off", "balanced", "strict"].includes(state.downloadGuard)) state.downloadGuard = "balanced";
  if (!Number.isSafeInteger(state.blockedCount) || state.blockedCount < 0) state.blockedCount = 0;
  await chrome.storage.local.set(state);
  await queueSync();
  await ensureUpdateAlarm(true).catch(() => {});
  maybeUpdate().catch(() => {});
});

chrome.runtime.onStartup.addListener(() => {
  logsReady.then(pruneTabLogs);
  queueSync();
  maybeUpdate().catch(() => {});
});

// If an update was cut short (worker killed), its saved progress was never applied and the
// "running" flag is stale: apply what was saved and clear the flag.
chrome.storage.local.get("autoListMeta").then(({ autoListMeta }) => {
  if (autoListMeta && autoListMeta.running && Date.now() - autoListMeta.running > 180000 && !updating) {
    return chrome.storage.local.set({ autoListMeta: { ...autoListMeta, running: 0 } }).then(() => queueSync());
  }
}).catch(() => {});

// Keys whose change never needs a rule rebuild (rebuilding is expensive with big lists).
const NO_SYNC_KEYS = new Set(["blockedCount", "autoListMeta", "autoUpdateEnabled", "autoUpdateHours", "downloadGuard", "syncStatus",
  "heuristicProtection", "heuristicAllowDomains"]);

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local") return;
  if (changes.autoUpdateEnabled || changes.autoUpdateHours) ensureUpdateAlarm(true).catch(() => {});
  if (changes.sourceEnabled && changes.sourceEnabled.oldValue !== undefined) updateLists();
  // while an update runs, per-source saves are not applied one by one; one sync runs at the end
  const need = Object.keys(changes).filter(k => !NO_SYNC_KEYS.has(k) && !(k === "autoLists" && updating));
  if (!need.length) return;
  queueSync();
});

// ---------- rule sync (serialized and coalesced: latest state wins) ----------
let syncChain = Promise.resolve();
let syncQueued = false;
function queueSync() {
  if (syncQueued) return syncChain;
  syncQueued = true;
  syncChain = syncChain
    .then(async () => {
      syncQueued = false;
      await syncAllRules(await chrome.storage.local.get(DEFAULT_STATE));
    })
    .catch((e) => { syncQueued = false; console.warn("CipherPane rule sync failed:", e); });
  return syncChain;
}

async function setSyncStatus(ok, msg) {
  try { await chrome.storage.local.set({ syncStatus: { ok, msg, ts: Date.now() } }); } catch {}
  try {
    if (!ok) {
      chrome.action.setBadgeBackgroundColor({ color: "#e11d48" });
      chrome.action.setBadgeText({ text: "ERR" });
    } else if ((await chrome.action.getBadgeText({})) === "ERR") {
      chrome.action.setBadgeText({ text: "" });
    }
  } catch {}
}

function buildRules(state, reduced) {
  const addRules = [];
  let nextId = 1000;

  const trusted = cleanDomains(state.trustedDomains).slice(0, MAX_TRUSTED);
  const custom = cleanDomains(state.customBlockedDomains).slice(0, MAX_CUSTOM);
  const bulk = mergedBulk(state, MAX_BULK);
  if (reduced) bulk.other = [];
  const httpOk = cleanDomains(state.httpAllowedDomains).slice(0, MAX_HTTP_ALLOWED);

  const SUB_TYPES = ["script", "xmlhttprequest", "image", "stylesheet", "font",
                     "media", "websocket", "ping", "object", "other"];
  const BLOCK_TYPES = ["sub_frame", "script", "xmlhttprequest", "image", "stylesheet", "font",
                       "media", "ping", "websocket", "object", "other"];

  // Conservative URL heuristic: credentials embedded in an HTTP(S) authority are a
  // common phishing disguise (for example https://bank.example@attacker.test/).
  // DNR evaluates this locally; no URL or browsing data is sent to a service.
  // This intentionally does not block on keyword/TLD guesses, which create false positives.
  addRules.push({ id: nextId++, priority: 160,
    action: { type: "redirect", redirect: { extensionPath: "/blocked.html" } },
    condition: { regexFilter: "^https?://[^/?#]*@", resourceTypes: ["main_frame"] } });
  addRules.push({ id: nextId++, priority: 160, action: { type: "block" },
    condition: { regexFilter: "^https?://[^/?#]*@",
      resourceTypes: ["sub_frame", "script", "xmlhttprequest", "image", "stylesheet",
                      "font", "media", "ping", "websocket", "object", "other"] } });

  // Trusted sites. Page and frame loads are exempted for https only, so "Trust" never turns
  // off the HTTPS upgrade. Below the threat lists (150) and custom blocks (200).
  for (const part of chunk(trusted, CHUNK_SIZE)) {
    addRules.push({ id: nextId++, priority: 100, action: { type: "allow" },
      condition: { requestDomains: part, urlFilter: "|https:", resourceTypes: ["main_frame"] } });
    addRules.push({ id: nextId++, priority: 100, action: { type: "allow" },
      condition: { initiatorDomains: part, urlFilter: "|https:", resourceTypes: ["sub_frame"] } });
    addRules.push({ id: nextId++, priority: 100, action: { type: "allow" },
      condition: { initiatorDomains: part, resourceTypes: SUB_TYPES } });
  }

  for (const part of chunk(custom, CHUNK_SIZE)) {
    addRules.push({ id: nextId++, priority: 200, action: { type: "redirect", redirect: { extensionPath: "/blocked.html" } },
      condition: { requestDomains: part, resourceTypes: ["main_frame"] } });
    addRules.push({ id: nextId++, priority: 200, action: { type: "block" },
      condition: { requestDomains: part, resourceTypes: BLOCK_TYPES } });
  }

  // Downloaded malware/phishing lists: above Trust.
  for (const part of chunk(bulk.threat, CHUNK_SIZE)) {
    addRules.push({ id: nextId++, priority: 150, action: { type: "redirect", redirect: { extensionPath: "/blocked.html" } },
      condition: { requestDomains: part, resourceTypes: ["main_frame"] } });
    addRules.push({ id: nextId++, priority: 150, action: { type: "block" },
      condition: { requestDomains: part, resourceTypes: BLOCK_TYPES } });
  }

  for (const part of chunk(bulk.other, CHUNK_SIZE)) {
    addRules.push({ id: nextId++, priority: 40, action: { type: "block" },
      condition: { requestDomains: part,
        resourceTypes: ["main_frame", "sub_frame", "script", "xmlhttprequest", "image", "ping", "websocket", "other"] } });
  }

  if (state.strictFirewallMode || state.blockThirdPartyScripts) {
    const exemptTypes = ["script", "sub_frame", "xmlhttprequest", "ping", "websocket", "object"];
    for (const part of chunk(CipherLists.STRICT_ALLOW_DOMAINS, 100)) {
      addRules.push({ id: nextId++, priority: 30, action: { type: "allow" },
        condition: { requestDomains: part, urlFilter: "|https:", resourceTypes: exemptTypes } });
    }
    for (const f of CipherLists.STRICT_ALLOW_URLFILTERS) {
      addRules.push({ id: nextId++, priority: 30, action: { type: "allow" },
        condition: { urlFilter: f, resourceTypes: exemptTypes } });
    }
  }

  if (state.strictFirewallMode) {
    addRules.push({ id: nextId++, priority: 20, action: { type: "block" },
      condition: { domainType: "thirdParty", resourceTypes: ["script", "sub_frame", "xmlhttprequest", "ping", "websocket", "object"] } });
  }

  if (state.blockThirdPartyScripts) {
    addRules.push({ id: nextId++, priority: 10, action: { type: "block" },
      condition: { domainType: "thirdParty", resourceTypes: ["script"] } });
  }

  // Sites the user chose to load over plain HTTP. Exact host only (no subdomains). Beats the upgrade rule.
  for (const h of httpOk) {
    addRules.push({ id: nextId++, priority: 6, action: { type: "allow" },
      condition: { urlFilter: httpRuleFilter(h), resourceTypes: ["main_frame", "sub_frame"] } });
  }

  if (state.httpsUpgrade) {
    addRules.push({ id: nextId++, priority: 5, action: { type: "upgradeScheme" },
      condition: {
        regexFilter: "^http://([a-zA-Z0-9-]+\\.)+[a-zA-Z][a-zA-Z0-9-]*([:/?#]|$)",
        excludedRequestDomains: ["localhost", "local", "lan", "internal", "home.arpa", "intranet", "corp"],
        resourceTypes: ["main_frame", "sub_frame"]
      } });
  }
  return addRules;
}

async function syncAllRules(state) {
  const enable = [];
  const disable = [];
  (state.malwareEnabled ? enable : disable).push("malware_phishing_rules");
  (state.adsEnabled ? enable : disable).push("ads_trackers_rules");

  let rulesetErr = "";
  try {
    await chrome.declarativeNetRequest.updateEnabledRulesets({ enableRulesetIds: enable, disableRulesetIds: disable });
  } catch (e) {
    rulesetErr = "Could not switch built-in rule sets: " + errText(e);
    console.warn("Ruleset toggle warning:", e);
  }

  const existingDynamic = await chrome.declarativeNetRequest.getDynamicRules();
  const removeRuleIds = existingDynamic.map(r => r.id);

  try {
    await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds, addRules: buildRules(state, false) });
    await setSyncStatus(!rulesetErr, rulesetErr);
  } catch (e) {
    console.warn("Full rule set rejected:", e);
    try {
      // fall back to a smaller set: everything except the big ad/manual lists
      await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds, addRules: buildRules(state, true) });
      await setSyncStatus(false, "The full rule set was rejected (" + errText(e) + "). Running with reduced block lists.");
    } catch (e2) {
      await setSyncStatus(false, "Rule update failed (" + errText(e2) + "). The previous rules are still active.");
    }
  }
}

// ---------- local lookalike / homoglyph navigation protection ----------
// This is a local, best-effort navigation guard. It never sends the visited hostname anywhere
// and never stores a browsing history. Static DNR blocklists remain the synchronous first line.
let heuristicRedirects = new Set();
if (chrome.webNavigation && chrome.webNavigation.onBeforeNavigate) {
  chrome.webNavigation.onBeforeNavigate.addListener((details) => {
    if (details.frameId !== 0 || !/^https?:\/\//i.test(details.url)) return;
    let host = "";
    try { host = new URL(details.url).hostname; } catch (_) { return; }
    if (!host || CipherLists.isIpHost(host) || CipherLists.isPrivateHost(host)) return;
    chrome.storage.local.get({ heuristicProtection: true, heuristicAllowDomains: [], trustedDomains: [] }).then((state) => {
      if (!state.heuristicProtection || heuristicRedirects.has(details.tabId)) return;
      // Sites the user trusted or explicitly allow-listed are never second-guessed by the heuristic.
      const allow = cleanDomains(state.heuristicAllowDomains).slice(0, MAX_HEURISTIC_ALLOW)
        .concat(cleanDomains(state.trustedDomains).slice(0, MAX_TRUSTED));
      const verdict = CipherReputation.scoreHost(host, allow);
      if (verdict.score < 70) return;
      heuristicRedirects.add(details.tabId);
      const target = chrome.runtime.getURL("blocked.html") + "?reason=lookalike&host=" + encodeURIComponent(host.slice(0, 253)) + "&detail=" + encodeURIComponent(String(verdict.reason).slice(0, 120));
      chrome.tabs.update(details.tabId, { url: target }).catch(() => {}).finally(() => {
        setTimeout(() => heuristicRedirects.delete(details.tabId), 3000);
      });
    }).catch(() => {});
  });
  chrome.tabs.onRemoved.addListener((tabId) => heuristicRedirects.delete(tabId));
}

// ---------- automatic block-list updates ----------
//  - only the mirror URLs in SOURCES are contacted, in order (the manifest CSP connect-src lists the same hosts);
//  - HTTPS only, final host re-checked after redirects, no cookies, no referrer, 25 s timeout, 15 MB cap;
//  - a failed, empty or suddenly much smaller download never replaces the previous good list;
//  - entries that CipherLists.isProtected() flags (never-block apexes, registry suffixes, or anything covering a source host) are dropped;
//  - results are saved after every source; one rule sync runs when the update finishes.
const UPDATE_ALARM = "cipherpane-list-update";
const RETRY_ALARM = "cipherpane-list-retry";
const MAX_LIST_BYTES = 15 * 1024 * 1024;
const FETCH_TIMEOUT_MS = 25000;
const MIN_HOURS = 6;
const MAX_HOURS = 168;
const MAX_FAIL_RETRIES = 3;

function clampHours(h) {
  h = Number(h);
  if (!Number.isFinite(h)) h = 6;
  return Math.min(MAX_HOURS, Math.max(MIN_HOURS, Math.round(h)));
}

async function ensureUpdateAlarm(reset) {
  const { autoUpdateEnabled = true, autoUpdateHours = 6 } =
    await chrome.storage.local.get(["autoUpdateEnabled", "autoUpdateHours"]);
  if (!autoUpdateEnabled) {
    await chrome.alarms.clear(UPDATE_ALARM);
    await chrome.alarms.clear(RETRY_ALARM);
    return;
  }
  const minutes = clampHours(autoUpdateHours) * 60;
  const existing = await chrome.alarms.get(UPDATE_ALARM);
  if (!reset && existing && existing.periodInMinutes === minutes) return;
  await chrome.alarms.create(UPDATE_ALARM, { delayInMinutes: 1, periodInMinutes: minutes });
}

async function updateIsDue() {
  const { autoUpdateEnabled = true, autoUpdateHours = 6, autoListMeta = {} } =
    await chrome.storage.local.get(["autoUpdateEnabled", "autoUpdateHours", "autoListMeta"]);
  if (!autoUpdateEnabled) return false;
  const last = Number(autoListMeta.lastRun) || 0;
  const streak = Number(autoListMeta.failStreak) || 0;
  const retrying = streak > 0 && streak < MAX_FAIL_RETRIES;
  const wait = retrying ? 25 * 60000 : clampHours(autoUpdateHours) * 3600000 - 5 * 60000;
  return Date.now() - last >= wait;
}

async function maybeUpdate() {
  if (await updateIsDue()) await updateLists();
}

// One update at a time. A request that arrives while one is running (for example a source
// toggled mid-run) is not dropped: it makes the run repeat once with the newest settings.
let updating = null;
let rerun = false;
function updateLists() {
  if (updating) { rerun = true; return updating; }
  updating = (async () => {
    do {
      rerun = false;
      try { await runUpdate(); } catch (e) { console.warn("CipherPane list update failed:", e); }
    } while (rerun);
  })().finally(() => { updating = null; queueSync(); });
  return updating;
}

// One mirror. `etag` is sent only when it came from this exact URL.
async function fetchOne(url, etag) {
  if (!/^https:\/\//.test(url)) throw new Error("refusing non-HTTPS source");
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const headers = {};
    if (etag) headers["If-None-Match"] = etag;
    const resp = await fetch(url, {
      method: "GET", headers, cache: "no-cache", credentials: "omit",
      referrerPolicy: "no-referrer", redirect: "follow", signal: ctrl.signal
    });
    // Every early exit cancels the body: an unread response keeps its connection and buffers alive.
    if (resp.status === 304) { await CipherLists.cancelBody(resp); return { notModified: true }; }
    if (!resp.ok) { await CipherLists.cancelBody(resp); throw new Error("HTTP " + resp.status); }
    if (resp.url && !CipherLists.sourceRedirectAllowed(url, resp.url)) {
      await CipherLists.cancelBody(resp);
      throw new Error("redirected away from the configured HTTPS source host");
    }
    if (/^\s*(text\/html|application\/xhtml)/i.test(resp.headers.get("content-type") || "")) {
      await CipherLists.cancelBody(resp);                    // error / captive-portal page, not a list
      throw new Error("unexpected content type (not a list)");
    }
    // Streamed: the 15 MB body is parsed chunk by chunk, never held as one string.
    const domains = await CipherLists.parseResponseDomains(resp, MAX_LIST_BYTES, { max: MAX_BULK });
    if (!domains.length) throw new Error("no valid domains in download");
    return { domains, etag: resp.headers.get("etag") || "" };
  } finally {
    clearTimeout(timer);
  }
}

// Tries each mirror of a source in order; the first good download wins. A dead mirror (404/410/timeout)
// only fails the source when every mirror failed.
async function fetchSource(src, prev) {
  const errors = [];
  for (const url of src.urls) {
    try {
      const r = await fetchOne(url, prev && prev.url === url ? prev.etag : "");
      r.url = url;
      return r;
    } catch (e) {
      let host = "";
      try { host = new URL(url).hostname; } catch (_) {}
      errors.push(host + ": " + errText(e));
    }
  }
  throw new Error(errors.join("; "));
}

async function runUpdate() {
  const st = await chrome.storage.local.get({ sourceEnabled: {}, autoLists: {}, autoListMeta: {} });
  const storedLists = st.autoLists && typeof st.autoLists === "object" && !Array.isArray(st.autoLists)
    ? st.autoLists : {};
  const lists = {};
  let listsChanged = false;
  for (const src of CipherLists.SOURCES) {
    if (Array.isArray(storedLists[src.id])) {
      // Older releases did not sanitize persisted lists against current feed hosts.
      // A stale entry such as github.io, gitlab.io, jsdelivr.net or pages.dev can
      // block every updater mirror through DNR, producing browser-level NetworkError.
      const original = cleanDomains(storedLists[src.id]);
      const safe = original.filter(d => !CipherLists.isProtected(d)).slice(0, MAX_BULK);
      lists[src.id] = safe;
      if (safe.length !== original.length) listsChanged = true;
    }
  }
  const storedMeta = st.autoListMeta && typeof st.autoListMeta === "object" && !Array.isArray(st.autoListMeta)
    ? st.autoListMeta : {};
  const storedPer = storedMeta.sources && typeof storedMeta.sources === "object" && !Array.isArray(storedMeta.sources)
    ? storedMeta.sources : {};
  const per = { ...storedPer };
  const prevMeta = storedMeta;
  let meta = { ...prevMeta, running: Date.now(), sources: per };
  const initialPayload = { autoListMeta: meta };
  if (listsChanged) initialPayload.autoLists = lists;
  await chrome.storage.local.set(initialPayload);
  if (listsChanged) {
    // Remove any legacy DNR rules that could block the feed hosts before the first fetch.
    // Waiting until the normal end-of-update sync would leave the old block rules active.
    await queueSync();
    listsChanged = false;
  }

  let allOk = true;
  let budget = MAX_BULK;
  for (const src of CipherLists.SOURCES) {
    if (!sourceOn(src, st.sourceEnabled)) {
      if (lists[src.id] || per[src.id]) { delete lists[src.id]; delete per[src.id]; listsChanged = true; }
    } else {
      const prev = per[src.id] || {};
      try {
        if (budget <= 0) {
          delete lists[src.id];
          listsChanged = true;
          per[src.id] = { ts: Date.now(), ok: true, count: 0, etag: "", error: "", note: "skipped: list capacity reached" };
        } else {
          const r = await fetchSource(src, Array.isArray(lists[src.id]) ? prev : null);
          if (r.notModified) {
            per[src.id] = { ...prev, ts: Date.now(), ok: true, error: "" };
          } else {
            let domains = r.domains.filter(d => !CipherLists.isProtected(d));
            if (!domains.length) throw new Error("no valid domains in download");
            const old = Array.isArray(lists[src.id]) ? lists[src.id].length : 0;
            if (old > 1000 && domains.length < old * 0.5) {
              throw new Error(`list shrank from ${old} to ${domains.length}; kept previous`);
            }
            let note = "";
            if (domains.length > budget) { domains = domains.slice(0, budget); note = "truncated to capacity"; }
            lists[src.id] = domains;
            listsChanged = true;
            per[src.id] = { ts: Date.now(), ok: true, count: domains.length, etag: r.etag, url: r.url, error: "", note };
          }
        }
      } catch (e) {
        allOk = false;
        per[src.id] = { ...prev, ts: Date.now(), ok: false, error: errText(e) };
      }
      budget -= Array.isArray(lists[src.id]) ? lists[src.id].length : 0;
    }
    const payload = { autoListMeta: { ...meta, sources: per } };
    if (listsChanged) payload.autoLists = lists;
    await chrome.storage.local.set(payload);
  }

  const now = Date.now();
  meta = {
    lastRun: now,
    lastOk: allOk ? now : (Number(prevMeta.lastOk) || 0),
    failStreak: allOk ? 0 : (Number(prevMeta.failStreak) || 0) + 1,
    running: 0,
    sources: per
  };
  await chrome.storage.local.set({ autoListMeta: meta });
  if (!allOk && meta.failStreak < MAX_FAIL_RETRIES) {
    await chrome.alarms.create(RETRY_ALARM, { delayInMinutes: 30 });
  }
}

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === UPDATE_ALARM || alarm.name === RETRY_ALARM) {
    logsReady.then(pruneTabLogs);
    maybeUpdate().catch(() => {});
  }
});

// A worker can start for any event (including after being killed when idle); make sure the
// schedule still exists without resetting it.
ensureUpdateAlarm(false).catch(() => {});
