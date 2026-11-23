// CipherPane Options page. Talks to chrome.storage.local only (plus one message asking the worker to
// refresh lists). No inline script, no innerHTML: every value from storage is shown with textContent.
(function () {
  "use strict";
  const L = CipherLists;
  const { MAX_TRUSTED, MAX_CUSTOM, MAX_HEURISTIC_ALLOW } = L.LIMITS;
  const MAX_ROWS = 500;                 // up to 20,000 entries can exist; never draw them all
  const MAX_IMPORT_BYTES = 8 * 1024 * 1024;
  const DEFAULTS = {
    malwareEnabled: true, adsEnabled: true, httpsUpgrade: true, blockThirdPartyScripts: false,
    strictFirewallMode: false, downloadGuard: "balanced", autoUpdateEnabled: true, autoUpdateHours: 6,
    heuristicProtection: true
  };
  const $ = (id) => document.getElementById(id);
  const arr = (x) => (Array.isArray(x) ? x : []);
  const store = chrome.storage.local;

  let msgTimer = null;
  function say(text, isErr) {
    const el = $("msg");
    el.textContent = text;
    el.classList.toggle("err", !!isErr);
    el.hidden = false;
    clearTimeout(msgTimer);
    msgTimer = setTimeout(() => { el.hidden = true; }, isErr ? 9000 : 4000);
  }
  async function save(obj) {
    try { await store.set(obj); return true; }
    catch (e) { say("Could not save: " + String((e && e.message) || e).slice(0, 140), true); return false; }
  }

  // ---------------- switches ----------------
  async function loadSwitches() {
    const st = await store.get(Object.keys(DEFAULTS));
    for (const el of document.querySelectorAll("input[data-key]")) {
      const k = el.dataset.key;
      el.checked = typeof st[k] === "boolean" ? st[k] : DEFAULTS[k];
    }
    $("downloadGuard").value = ["off", "balanced", "strict"].includes(st.downloadGuard) ? st.downloadGuard : DEFAULTS.downloadGuard;
    const h = L.UPDATE_HOURS.includes(Number(st.autoUpdateHours)) ? String(st.autoUpdateHours) : String(DEFAULTS.autoUpdateHours);
    $("autoUpdateHours").value = h;
  }
  for (const el of document.querySelectorAll("input[data-key]")) {
    el.addEventListener("change", () => save({ [el.dataset.key]: el.checked }));
  }
  $("downloadGuard").addEventListener("change", (e) => save({ downloadGuard: e.target.value }));
  $("autoUpdateHours").addEventListener("change", (e) => save({ autoUpdateHours: Number(e.target.value) }));

  // ---------------- domain lists ----------------
  const LISTS = {
    heuristicAllowDomains: { ul: "allowList", max: MAX_HEURISTIC_ALLOW, empty: "No exceptions." },
    trustedDomains:        { ul: "trustList", max: MAX_TRUSTED, empty: "No trusted sites." },
    customBlockedDomains:  { ul: "blockList", max: MAX_CUSTOM, empty: "No blocked sites." },
    httpAllowedDomains:    { ul: "httpList",  max: L.LIMITS.MAX_HTTP_ALLOWED, empty: "None. A site only appears here if you choose \"Always allow HTTP\"." }
  };

  async function renderList(key) {
    const cfg = LISTS[key];
    const list = L.cleanDomains((await store.get(key))[key]);
    const ul = $(cfg.ul);
    ul.textContent = "";
    if (!list.length) {
      const li = document.createElement("li");
      li.className = "empty";
      li.textContent = cfg.empty;
      ul.appendChild(li);
      return;
    }
    for (const d of list.slice(0, MAX_ROWS)) {
      const li = document.createElement("li");
      const label = document.createElement("span");
      label.textContent = d;
      const btn = document.createElement("button");
      btn.type = "button";
      btn.textContent = "Remove";
      btn.setAttribute("aria-label", "Remove " + d);
      btn.addEventListener("click", async () => {
        const fresh = L.cleanDomains((await store.get(key))[key]);
        if (await save({ [key]: fresh.filter((x) => x !== d) })) renderList(key);
      });
      li.append(label, btn);
      ul.appendChild(li);
    }
    if (list.length > MAX_ROWS) {
      const li = document.createElement("li");
      li.className = "empty";
      li.textContent = "…and " + (list.length - MAX_ROWS).toLocaleString() + " more (all still apply)";
      ul.appendChild(li);
    }
  }

  // Accepts "example.com", "https://example.com/x" or "Example.COM"; rejects anything else.
  function parseDomainInput(raw) {
    let v = String(raw || "").trim().toLowerCase().replace(/^https?:\/\//, "").split(/[\/?#]/)[0].replace(/:\d+$/, "");
    return L.normalizeHost(v);
  }
  async function addDomain(key, inputId) {
    const cfg = LISTS[key];
    const d = parseDomainInput($(inputId).value);
    if (!d) { say("That is not a valid domain name (for example: example.com).", true); return; }
    const cur = L.cleanDomains((await store.get(key))[key]);
    if (cur.includes(d)) { say(d + " is already in the list."); return; }
    if (cur.length >= cfg.max) { say("List limit reached (" + cfg.max.toLocaleString() + ").", true); return; }
    if (await save({ [key]: [...cur, d] })) { $(inputId).value = ""; renderList(key); say("Added " + d + "."); }
  }
  for (const [btn, key, input] of [["allowAdd", "heuristicAllowDomains", "allowInput"], ["trustAdd", "trustedDomains", "trustInput"], ["blockAdd", "customBlockedDomains", "blockInput"]]) {
    $(btn).addEventListener("click", () => addDomain(key, input));
    $(input).addEventListener("keydown", (e) => { if (e.key === "Enter") addDomain(key, input); });
  }

  // The warning page links here as #allow=<host>. It only pre-fills the box: adding stays a deliberate click
  // on this page, which a web page cannot frame or click for you.
  function prefillFromHash() {
    const m = /^#allow=([^&]+)/.exec(location.hash);
    if (!m) return;
    let host = "";
    try { host = parseDomainInput(decodeURIComponent(m[1])); } catch (e) {}
    if (host) { $("allowInput").value = host; $("allowInput").focus(); say("Check that you really trust " + host + ", then press Add under “Allowed despite the warning”."); }
    history.replaceState(null, "", location.pathname);
  }

  // ---------------- blocklist sources ----------------
  const fmtAge = L.fmtAge;
  async function renderSources() {
    const st = await store.get({ sourceEnabled: {}, autoListMeta: {} });
    const enabled = st.sourceEnabled && typeof st.sourceEnabled === "object" && !Array.isArray(st.sourceEnabled) ? st.sourceEnabled : {};
    const meta = st.autoListMeta && typeof st.autoListMeta === "object" ? st.autoListMeta : {};
    const per = meta.sources && typeof meta.sources === "object" ? meta.sources : {};
    const ul = $("sourceList");
    ul.textContent = "";
    for (const src of L.SOURCES) {
      const on = L.sourceOn(src, enabled);
      const s = per[src.id];
      const li = document.createElement("li");
      const cb = document.createElement("input");
      cb.type = "checkbox";
      cb.checked = on;
      cb.setAttribute("aria-label", src.name);
      cb.addEventListener("change", async () => {
        const cur = (await store.get("sourceEnabled")).sourceEnabled;
        const next = cur && typeof cur === "object" && !Array.isArray(cur) ? cur : {};
        next[src.id] = cb.checked;
        await save({ sourceEnabled: next });
      });
      const box = document.createElement("div");
      const t = document.createElement("div");
      t.className = "t";
      t.textContent = src.name + " – " + src.kind;
      const d = document.createElement("div");
      d.className = "note";
      if (!on) d.textContent = "Off";
      else if (!s) d.textContent = "Not downloaded yet";
      else if (s.ok) { d.classList.add("ok"); d.textContent = (s.count || 0).toLocaleString() + " domains, checked " + fmtAge(s.ts) + (s.note ? " (" + s.note + ")" : ""); }
      else { d.classList.add("fail"); d.textContent = "Failed: " + (s.error || "error") + (s.count ? " – still using previous " + s.count.toLocaleString() + " domains" : ""); }
      box.append(t, d);
      li.append(cb, box);
      ul.appendChild(li);
    }
    const us = $("updateStatus");
    if (meta.running && Date.now() - meta.running < 180000) us.textContent = "Updating…";
    else if (meta.lastOk) us.textContent = "Last successful update: " + fmtAge(meta.lastOk);
    else if (meta.lastRun) us.textContent = "Last attempt " + fmtAge(meta.lastRun) + " had errors";
    else us.textContent = "No update has run yet";
  }
  $("updateNow").addEventListener("click", async (e) => {
    const b = e.target;
    b.disabled = true;
    try { await chrome.runtime.sendMessage({ type: "UPDATE_LISTS_NOW" }); } catch (err) { say("Could not reach the background worker. Try again in a moment.", true); }
    setTimeout(() => { b.disabled = false; }, 4000);
  });

  // ---------------- backup / reset ----------------
  $("exportBtn").addEventListener("click", async () => {
    const st = await store.get(L.EXPORT_KEYS);
    const body = { format: L.SETTINGS_FORMAT, version: chrome.runtime.getManifest().version, exported: new Date().toISOString(), settings: st };
    const url = URL.createObjectURL(new Blob([JSON.stringify(body, null, 2)], { type: "application/json" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = "cipherpane-settings.json";
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10000);
  });
  $("importFile").addEventListener("change", async (e) => {
    const f = e.target.files && e.target.files[0];
    e.target.value = "";
    if (!f) return;
    if (f.size > MAX_IMPORT_BYTES) { say("That file is too large to be a settings export.", true); return; }
    let obj;
    try { obj = JSON.parse(await f.text()); } catch (err) { say("That file is not valid JSON.", true); return; }
    if (!obj || !L.isSettingsFormat(obj.format) || typeof obj.settings !== "object") { say("That is not an CipherPane settings export.", true); return; }
    const patch = L.sanitizeSettings(obj.settings);
    const n = Object.keys(patch).length;
    if (!n) { say("Nothing usable found in that file.", true); return; }
    if (!confirm("Import " + n + " settings from this file? They replace your current values for those items.")) return;
    if (await save(patch)) { await refreshAll(); say("Imported " + n + " settings."); }
  });
  $("resetBtn").addEventListener("click", async () => {
    if (!confirm("Reset all switches and update settings to their defaults? Your site lists are kept.")) return;
    if (await save({ ...DEFAULTS, sourceEnabled: {} })) { await refreshAll(); say("Switches reset to defaults."); }
  });
  $("zeroBtn").addEventListener("click", async () => { if (await save({ blockedCount: 0 })) say("Counter reset."); });

  // ---------------- about ----------------
  function renderAbout() {
    $("verLine").textContent = "Version " + chrome.runtime.getManifest().version;
    const ul = $("hostList");
    ul.textContent = "";
    for (const h of L.sourceHosts().filter((x, i, a) => a.indexOf(x) === i)) {
      const li = document.createElement("li");
      li.textContent = h;
      ul.appendChild(li);
    }
  }

  async function refreshAll() {
    await Promise.all([loadSwitches(), renderSources(), ...Object.keys(LISTS).map(renderList)]);
  }

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local") return;
    if (changes.autoListMeta || changes.sourceEnabled) renderSources().catch(() => {});
  });

  renderAbout();
  refreshAll().then(prefillFromHash).catch((e) => say("Could not load settings: " + String((e && e.message) || e).slice(0, 140), true));
})();
