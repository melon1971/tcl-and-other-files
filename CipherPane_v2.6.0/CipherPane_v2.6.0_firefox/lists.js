// CipherPane v2.5 shared code: auto-update sources, list parser, safety filters, Strict-mode
// login/payment exemptions and the Download Guard decision logic.
// Loaded by the background worker (importScripts, or the manifest "scripts" array on
// Firefox) and by the popup (<script> tag). No network or storage access in this file.
(function (root) {
  "use strict";

  const DOMAIN_RE = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/;

  // The only hosts the extension ever downloads from. Fixed in code on purpose: a tampered
  // storage value cannot redirect the updater. The manifest CSP connect-src must list the
  // same hosts. Order matters: when the combined cap is reached, later sources are cut first.
  const SOURCES = [
    // Use the current hosts-format endpoints. abuse.ch's former public hostfile endpoint was retired.
    // Mirrors are ordered by freshness/reliability; every mirror is independently validated.
    { id: "urlhaus", threat: true, name: "URLhaus malware hosts (abuse.ch, via curbengh)", kind: "Malware",
      urls: [
        "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-hosts-online.txt",
        "https://curbengh.github.io/malware-filter/urlhaus-filter-hosts-online.txt",
        "https://urlhaus-filter.pages.dev/urlhaus-filter-hosts-online.txt"
      ], enabled: true },
    { id: "phishing", threat: true, name: "Phishing Filter (curbengh)", kind: "Phishing",
      urls: [
        "https://malware-filter.gitlab.io/malware-filter/phishing-filter-hosts.txt",
        "https://curbengh.github.io/malware-filter/phishing-filter-hosts.txt",
        "https://phishing-filter.pages.dev/phishing-filter-hosts.txt"
      ], enabled: true },
    // HaGeZi's current Light plain-domain format.
    { id: "hagezi_light", name: "HaGeZi Light (ads, trackers, malware)", kind: "Ads/Trackers",
      urls: [
        "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/light-onlydomains.txt",
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/light-onlydomains.txt"
      ], enabled: true },
    { id: "stevenblack", name: "StevenBlack unified hosts", kind: "Ads/Malware",
      urls: [
        "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts",
        "https://cdn.jsdelivr.net/gh/StevenBlack/hosts@master/hosts"
      ], enabled: false }
  ];
  for (const src of SOURCES) { Object.freeze(src.urls); Object.freeze(src); }
  Object.freeze(SOURCES);

  // Apex domains that must never be blocked by a downloaded list (a bad upstream entry would
  // break large parts of the web or the updater itself). Subdomains such as ads.google.com are
  // still blockable. Your own custom blocks and manual imports are not filtered by this.
  const NEVER_BLOCK = new Set([
    "google.com", "googleapis.com", "gstatic.com", "googleusercontent.com", "youtube.com",
    "microsoft.com", "windows.com", "windowsupdate.com", "live.com", "office.com", "apple.com",
    "icloud.com", "amazon.com", "amazonaws.com", "cloudfront.net", "cloudflare.com",
    "akamaihd.net", "akamaized.net", "fastly.net", "github.com", "githubusercontent.com",
    "github.io", "mozilla.org", "mozilla.net", "mozilla.com", "wikipedia.org", "wikimedia.org"
  ]);

  function sourceRedirectAllowed(sourceUrl, finalUrl) {
    try {
      const source = new URL(sourceUrl), final = new URL(finalUrl);
      return source.protocol === "https:" && final.protocol === "https:" &&
             source.hostname.toLowerCase() === final.hostname.toLowerCase();
    } catch (e) { return false; }
  }

  // SOURCES is fixed in code, so the host list is computed once (isProtected() runs once per
  // downloaded domain; re-parsing every source URL each time churned tens of MB of garbage).
  let SOURCE_HOSTS = null;
  function sourceHosts() {
    if (!SOURCE_HOSTS) {
      const out = [];
      for (const s of SOURCES) for (const u of s.urls) { try { out.push(new URL(u).hostname); } catch (e) {} }
      SOURCE_HOSTS = Object.freeze(out);
    }
    return SOURCE_HOSTS;
  }

  // Registry-style suffixes (co.uk, com.au, org.uk ...). DNR matches a domain and every subdomain, so one
  // poisoned feed line such as "co.uk" would block a whole country's websites. Downloaded feeds never get
  // to block these; a full public-suffix list is too large to ship, so this covers the "SLD.ccTLD" shape.
  const SUFFIX_SLDS = new Set(["co", "com", "org", "net", "gov", "edu", "ac", "or", "ne", "go", "gob", "mil", "nom", "ltd", "plc", "sch"]);
  function isSuffixLike(d) {
    const l = d.split(".");
    return l.length === 2 && l[1].length === 2 && SUFFIX_SLDS.has(l[0]);
  }

  // true if blocking `d` would also block a download source, a registry suffix, or is on the never-block list
  function isProtected(d) {
    if (NEVER_BLOCK.has(d) || isSuffixLike(d)) return true;
    for (const h of sourceHosts()) if (h === d || h.endsWith("." + d)) return true;
    return false;
  }

  function normalizeHost(h) {
    h = String(h || "").trim().toLowerCase().replace(/\.$/, "");
    if (!h) return "";
    if (/[^\x00-\x7f]/.test(h)) {                       // IDN -> punycode
      try { h = new URL("http://" + h).hostname; } catch (e) { return ""; }
    }
    return h.length <= 253 && DOMAIN_RE.test(h) ? h : "";
  }

  // Returns the domains one input line asks to block. Strict by default: only whole-domain
  // rules are accepted. Cosmetic filters (##, #@#), path rules (||x.com/ads), rules with
  // options ($third-party, $image ...), exceptions (@@) and wildcards are skipped, because
  // turning them into a block of the whole domain would break sites.
  // lenient (manual single-domain box only) also accepts a pasted URL and strips scheme/path/port.
  function domainsFromLine(raw, lenient) {
    let line = String(raw).slice(0, 1001).trim();
    if (line.length > 1000) return [];          // no real rule is this long; also bounds worst-case work
    if (!line) return [];
    const c = line[0];
    if (c === "!" || c === "#" || c === "[") return [];
    if (line.startsWith("@@")) return [];
    if (/#[@?$%]*#/.test(line)) return [];              // cosmetic / scriptlet filters
    { const hc = line.search(/\s#/); if (hc >= 0) line = line.slice(0, hc).trim(); }          // trailing hosts-file comment
    if (!line) return [];

    if (line.startsWith("||")) {
      const m = /^\|\|([^\/^$*|:?\s]+)\^?$/.exec(line);
      const h = m ? normalizeHost(m[1]) : "";
      return h ? [h] : [];
    }

    const parts = line.split(/\s+/);
    if (parts.length >= 2 && /^(0\.0\.0\.0|127\.0\.0\.1|::1?|::)$/.test(parts[0])) {
      const out = [];
      for (const p of parts.slice(1)) { const h = normalizeHost(p); if (h) out.push(h); }
      return out;
    }

    if (lenient) {
      line = line.replace(/^https?:\/\//i, "").split(/[\/?#]/)[0].split(":")[0];
      const h = normalizeHost(line);
      return h ? [h] : [];
    }
    if (parts.length === 1 && /^[^\/*$^|:?#\s]+$/.test(line)) {
      const h = normalizeHost(line);
      return h ? [h] : [];
    }
    return [];
  }

  function parseFilterLines(text, opts) {
    const lenient = !!(opts && opts.lenient);
    const max = (opts && opts.max) || 100000;
    const out = new Set();
    for (const line of String(text).split(/\r?\n/)) {
      for (const d of domainsFromLine(line, lenient)) {
        out.add(d);
        if (out.size >= max) return Array.from(out);
      }
    }
    return Array.from(out);
  }

  async function cancelBody(resp) {
    try { if (resp && resp.body && !resp.bodyUsed) await resp.body.cancel(); } catch (e) {}
  }

  // Streaming list parser. Decodes chunk by chunk and hands each line to the parser, so the
  // whole body (up to 15 MB, 30 MB once held as a UTF-16 string) and the array of ~700k line
  // strings that split() builds are never in memory at once. A line longer than 2,000 characters
  // is dropped without being buffered, so a body with no newlines cannot grow the buffer.
  // Reading stops (and the body is cancelled) as soon as `max` domains are collected.
  async function parseResponseDomains(resp, maxBytes, opts) {
    const max = (opts && opts.max) || 100000;
    const declared = Number(resp.headers.get("content-length"));
    if (declared > maxBytes) { await cancelBody(resp); throw new Error("list too large"); }
    const out = new Set();
    let pending = "", skipping = false;
    const feed = (line) => {
      for (const d of domainsFromLine(line, false)) { out.add(d); if (out.size >= max) return true; }
      return false;
    };
    const eat = (s) => {                       // returns true when `max` is reached
      let i = 0;
      while (i < s.length) {
        const nl = s.indexOf("\n", i);
        if (!skipping) {
          pending += nl < 0 ? s.slice(i) : s.slice(i, nl);
          if (pending.length > 2000) { pending = ""; skipping = true; }
        }
        if (nl < 0) return false;
        if (!skipping && feed(pending)) return true;
        pending = ""; skipping = false;
        i = nl + 1;
      }
      return false;
    };
    if (!resp.body || !resp.body.getReader) {
      const t = await resp.text();
      if (new TextEncoder().encode(t).byteLength > maxBytes) throw new Error("list too large");
      if (!eat(t) && !skipping && pending) feed(pending);
      return Array.from(out);
    }
    const reader = resp.body.getReader();
    const dec = new TextDecoder("utf-8");
    let total = 0;
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        total += value.length;
        if (total > maxBytes) throw new Error("list too large");
        if (eat(dec.decode(value, { stream: true }))) return Array.from(out);
      }
      if (!eat(dec.decode()) && !skipping && pending) feed(pending);
      return Array.from(out);
    } finally {
      try { await reader.cancel(); } catch (e) {}      // no-op when the body was fully read
    }
  }

  // ---------- Strict mode: login / payment / captcha providers ----------
  // Strict mode blocks third-party scripts, frames and XHR. These providers are exempted
  // (https only) so sign-in, captcha and card payment pages keep working. Everything else
  // stays blocked. Suffix match: "stripe.com" also covers js.stripe.com.
  const STRICT_ALLOW_DOMAINS = [
    // sign-in / SSO
    "accounts.google.com", "apis.google.com", "appleid.apple.com", "idmsa.apple.com",
    "login.microsoftonline.com", "login.live.com", "login.microsoft.com", "aadcdn.msauth.net",
    "msauth.net", "msftauth.net", "oktacdn.com", "cdn.auth0.com", "cdn.onelogin.com",
    "duosecurity.com", "login.yahoo.com", "id.atlassian.com", "accounts.spotify.com",
    // captcha / bot checks
    "hcaptcha.com", "challenges.cloudflare.com", "recaptcha.net", "arkoselabs.com", "funcaptcha.com",
    // payments and 3-D Secure
    "stripe.com", "stripe.network", "paypal.com", "paypalobjects.com", "braintreegateway.com",
    "braintree-api.com", "adyen.com", "checkout.com", "squareup.com", "squarecdn.com", "klarna.com",
    "klarnacdn.net", "affirm.com", "afterpay.com", "shopifycs.com", "authorize.net", "worldpay.com",
    "cardinalcommerce.com", "razorpay.com", "mollie.com", "pay.google.com", "applepay.cdn-apple.com"
  ];
  // okta.com / auth0.com / onelogin.com are NOT exempt: anyone can open a tenant there. Add your
  // company tenant with Trust Site instead. google.com / gstatic.com are too broad to exempt as a whole; only the captcha paths.
  const STRICT_ALLOW_URLFILTERS = ["|https://www.google.com/recaptcha/", "|https://www.gstatic.com/recaptcha/"];

  // ---------- host helpers ----------
  function isIPv4(h) { return /^(\d{1,3}\.){3}\d{1,3}$/.test(h); }
  function isIPv6(h) { return h.startsWith("[") && h.endsWith("]"); }
  function isIpHost(h) { return isIPv4(h) || isIPv6(h); }
  // Private / loopback / link-local / CGNAT / LAN-style names: never treated as "internet" hosts.
  function isPrivateHost(h) {
    h = String(h || "").toLowerCase();
    if (h === "localhost" || /\.(local|lan|internal|home\.arpa|intranet|corp|localdomain)$/.test(h)) return true;
    if (isIPv4(h)) {
      const [a, b] = h.split(".").map(Number);
      return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) ||
             (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127);
    }
    if (isIPv6(h)) {
      const v = h.slice(1, -1);
      const mm = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(v);
      if (mm) { const hi = parseInt(mm[1], 16), lo = parseInt(mm[2], 16); return isPrivateHost([hi >> 8, hi & 255, lo >> 8, lo & 255].join(".")); }
      return v === "::1" || v === "::" || /^f[cd][0-9a-f]{2}:/.test(v) || /^fe[89ab][0-9a-f]:/.test(v);
    }
    return false;
  }
  function hostMatches(host, list) {
    for (const d of list) if (host === d || host.endsWith("." + d)) return true;
    return false;
  }

  // ---------- shared list helpers (used by the worker and the tests) ----------
  function cleanDomains(list) {
    const out = new Set();
    for (const d of (Array.isArray(list) ? list : [])) {
      if (typeof d !== "string") continue;
      const c = d.trim().toLowerCase();
      if (c.length <= 253 && DOMAIN_RE.test(c)) out.add(c);
    }
    return Array.from(out);
  }

  function fmtAge(ts) {
    const mins = Math.max(0, Math.round((Date.now() - ts) / 60000));
    if (mins < 2) return "just now";
    if (mins < 120) return mins + " min ago";
    const hrs = Math.round(mins / 60);
    if (hrs < 48) return hrs + " h ago";
    return Math.round(hrs / 24) + " d ago";
  }

  function sourceOn(src, enabledMap) {
    const v = enabledMap && enabledMap[src.id];
    return typeof v === "boolean" ? v : src.enabled;
  }

  // Combined block list, capped at `max`. Order of priority when the cap bites:
  // 1) malware/phishing sources, 2) the user's manual imports, 3) ad/tracker sources.
  // A huge manual import can therefore never push the malware lists out.
  function mergedBulk(state, max) {
    max = max || 100000;
    const lists = (state && state.autoLists) || {};
    const enabled = (state && state.sourceEnabled) || {};
    const threat = new Set(), other = new Set();
    const room = () => max - threat.size - other.size;
    const take = (src, into) => {
      const l = lists[src.id];
      if (!Array.isArray(l)) return;
      for (const d of l) {
        if (room() <= 0) return;
        if (typeof d === "string" && d.length <= 253 && DOMAIN_RE.test(d) &&
            !isProtected(d) && !threat.has(d) && !other.has(d)) into.add(d);
      }
    };
    for (const src of SOURCES) if (src.threat && sourceOn(src, enabled)) take(src, threat);
    for (const d of cleanDomains(state && state.bulkBlockedDomains)) {
      if (room() <= 0) break;
      if (!threat.has(d)) other.add(d);
    }
    for (const src of SOURCES) if (!src.threat && sourceOn(src, enabled)) take(src, other);
    return { threat: Array.from(threat), other: Array.from(other) };
  }

  // ---------- Download Guard ----------
  // Tier A: almost never a legitimate download. Blocked in Balanced and Strict.
  const DL_TIER_A = new Set(["scr", "pif", "vbs", "vbe", "jse", "wsf", "wsh", "hta", "lnk", "cpl", "reg",
    "chm", "gadget", "msc", "scf", "sct", "wsc", "ps1xml", "psc1", "application", "appref-ms", "library-ms",
    "searchconnector-ms", "iqy", "slk", "settingcontent-ms",
    "url", "jnlp", "xll", "wiz", "ws", "vb", "vbscript", "xbap", "diagcab", "diagpkg", "mde", "ade", "shb", "shs",
    "msh", "msh1", "msh2", "mshxml", "msh1xml", "msh2xml", "ps2", "ps2xml", "psd1", "job", "inf"]);
  // Tier B: executables, installers, scripts, macro documents. Balanced blocks them only when the
  // delivery looks wrong (raw IP / plain HTTP); Strict blocks them unless the host is trusted.
  const DL_TIER_B = new Set(["exe", "msi", "msix", "msixbundle", "appx", "appxbundle", "bat", "cmd", "com",
    "ps1", "psm1", "jar", "dll", "sys", "apk", "xapk", "dmg", "pkg", "iso", "img", "vhd", "vhdx", "sh", "bash",
    "run", "bin", "appimage", "deb", "rpm", "js", "py", "pl", "docm", "xlsm", "pptm", "dotm", "xlam", "ppam",
    "xlm", "xltm", "potm", "sldm", "ppsm", "msp", "mst", "xpi", "crx", "pyw", "pyz", "one", "onepkg", "ocx", "drv", "vsix"]);
  // Tier C: archives. Blocked from a public raw IP; Strict also blocks them from untrusted hosts.
  const DL_TIER_C = new Set(["zip", "rar", "7z", "gz", "tgz", "xz", "bz2", "tbz2", "txz", "zst", "lz", "lzh", "lha",
    "cab", "tar", "z", "ace", "arj", "uue"]);
  // Tier D: documents that can run script. Blocked from a public raw IP only.
  const DL_TIER_D = new Set(["html", "htm", "xhtml", "shtml", "mht", "mhtml", "svg", "svgz"]);
  const DL_EXEC_MIME = /^application\/(x-msdownload|x-dosexec|x-msdos-program|vnd\.microsoft\.portable-executable|x-executable|x-elf|x-mach-binary|x-msi|x-bat|x-sh|x-shellscript|java-archive|x-java-archive|hta|x-ms-installer|vnd\.android\.package-archive)$/i;
  const DL_GENERIC_MIME = /^application\/(octet-stream|x-binary|binary|force-download|x-download)$/i;
  const DL_DECOY_EXT = "pdf|docx?|xlsx?|pptx?|txt|rtf|csv|jpe?g|png|gif|bmp|webp|svg|mp3|mp4|avi|mov|mkv|wav|odt|ods|zip|rar|7z|html?";
  const DL_DOUBLE_EXT = new RegExp("\\.(" + DL_DECOY_EXT + ")[ ._-]*\\.(exe|scr|bat|cmd|com|pif|vbs|vbe|js|jse|wsf|wsh|hta|lnk|ps1|msi|jar|cpl|reg|xll|jnlp|url|pyw|vb)$", "i");
  const BIDI_RE = /[\u202a-\u202e\u2066-\u2069\u200e\u200f]/;
  const INVISIBLE_RE = /[\u200b-\u200d\u2060\ufeff\u00ad]/g;

  // File name as the OS will see it: no path, no hidden characters, no NTFS stream suffix,
  // no trailing dots/spaces (Windows drops them, so "a.exe." runs as "a.exe").
  function cleanName(name) {
    let n = String(name || "").split(/[\\/]/).pop();
    n = n.replace(BIDI_RE, "").replace(INVISIBLE_RE, "");
    const ci = n.indexOf(":");
    if (ci > 0) n = n.slice(0, ci);
    return n.replace(/[. \t]+$/, "").trim();
  }

  function fileExt(name) {
    const base = cleanName(name).toLowerCase();
    const i = base.lastIndexOf(".");
    return i > 0 ? base.slice(i + 1) : "";
  }

  function urlParts(u) {
    try {
      let p = new URL(u);
      if (p.protocol === "blob:") p = new URL(p.pathname);       // blob:https://host/uuid
      return { protocol: p.protocol, host: p.hostname.toLowerCase(), path: p.pathname };
    } catch (e) { return null; }
  }

  // info: { url, finalUrl, referrer, filename, mime }   ctx: { mode, trusted: [domains] }
  // returns null (allow) or { reason, tier }
  // "Trusted" means every host the file came from (original and final URL) is trusted. The
  // referring page does not count: a trusted page can link to a hostile file host.
  function checkDownload(info, ctx) {
    const mode = ctx && ctx.mode;
    if (mode !== "balanced" && mode !== "strict") return null;
    const src = urlParts(info.finalUrl || info.url);
    const orig = urlParts(info.url);
    const hosts = [src, orig].filter(Boolean).map(x => x.host);
    const rawName = String(info.filename || "");
    const named = cleanName(rawName) || cleanName(src && src.path);
    const ext = fileExt(named) || (orig ? fileExt(orig.path) : "");
    const mime = String(info.mime || "");
    const trusted = ((ctx && ctx.trusted) || []);
    const isTrusted = hosts.length > 0 && hosts.every(h => hostMatches(h, trusted));
    const publicIp = hosts.some(h => isIpHost(h) && !isPrivateHost(h));
    const insecure = [src, orig].some(x => x && x.protocol === "http:" && !isPrivateHost(x.host));
    const execMime = DL_EXEC_MIME.test(mime);
    const genericMime = DL_GENERIC_MIME.test(mime);

    if (BIDI_RE.test(rawName))
      return { reason: "file name uses hidden text-direction characters", tier: "A" };
    if (DL_DOUBLE_EXT.test(named))
      return { reason: "disguised file name (double extension)", tier: "A" };
    if (DL_TIER_A.has(ext)) return { reason: "." + ext + " files are a common malware type", tier: "A" };
    if (execMime && ext && !DL_TIER_B.has(ext) && !/^(sh|bin)$/.test(ext))
      return { reason: "file name says ." + ext + " but the server sent an executable (" + mime + ")", tier: "A" };
    const risky = DL_TIER_B.has(ext) || (execMime && !ext);
    if (risky && publicIp) return { reason: "executable/installer from a raw IP address", tier: "B" };
    if (DL_TIER_C.has(ext) && publicIp) return { reason: "archive from a raw IP address", tier: "C" };
    if (DL_TIER_D.has(ext) && publicIp) return { reason: "web page/SVG file from a raw IP address", tier: "D" };
    if (risky && insecure) return { reason: "executable/installer over unencrypted HTTP", tier: "B" };
    if (mode === "strict" && !isTrusted) {
      if (risky) return { reason: "Strict mode blocks executables/installers from sites you have not trusted", tier: "B" };
      if (genericMime && !ext) return { reason: "Strict mode blocks files of unknown type from sites you have not trusted", tier: "B" };
      if (DL_TIER_C.has(ext)) return { reason: "Strict mode blocks archives from sites you have not trusted", tier: "C" };
    }
    return null;
  }

  // ---------- settings import / export (Options page) ----------
  const LIMITS = Object.freeze({ MAX_BULK: 100000, MAX_CUSTOM: 20000, MAX_HTTP_ALLOWED: 500, MAX_TRUSTED: 5000, MAX_HEURISTIC_ALLOW: 500 });
  const BOOL_KEYS = ["malwareEnabled", "adsEnabled", "httpsUpgrade", "blockThirdPartyScripts", "strictFirewallMode",
                     "autoUpdateEnabled", "heuristicProtection"];
  const LIST_KEYS = { trustedDomains: LIMITS.MAX_TRUSTED, customBlockedDomains: LIMITS.MAX_CUSTOM,
                      httpAllowedDomains: LIMITS.MAX_HTTP_ALLOWED, bulkBlockedDomains: LIMITS.MAX_BULK,
                      heuristicAllowDomains: LIMITS.MAX_HEURISTIC_ALLOW };
  const UPDATE_HOURS = [6, 12, 24, 72, 168];
  const SETTINGS_FORMAT = "cipherpane-settings";
  const isSettingsFormat = (f) => f === SETTINGS_FORMAT || f === "aegisgate-settings";   // pre-rename exports still import

  // Turns an untrusted settings file into a storage patch containing only known keys with valid values.
  // Anything unknown or malformed is dropped, never stored. Counters, feed caches and status are not importable.
  function sanitizeSettings(obj) {
    const out = {};
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) return out;
    for (const k of BOOL_KEYS) if (typeof obj[k] === "boolean") out[k] = obj[k];
    if (["off", "balanced", "strict"].includes(obj.downloadGuard)) out.downloadGuard = obj.downloadGuard;
    if (UPDATE_HOURS.includes(obj.autoUpdateHours)) out.autoUpdateHours = obj.autoUpdateHours;
    for (const k of Object.keys(LIST_KEYS)) if (Array.isArray(obj[k])) out[k] = cleanDomains(obj[k]).slice(0, LIST_KEYS[k]);
    if (obj.sourceEnabled && typeof obj.sourceEnabled === "object" && !Array.isArray(obj.sourceEnabled)) {
      const se = {};
      for (const src of SOURCES) if (typeof obj.sourceEnabled[src.id] === "boolean") se[src.id] = obj.sourceEnabled[src.id];
      out.sourceEnabled = se;
    }
    return out;
  }
  const EXPORT_KEYS = [...BOOL_KEYS, "downloadGuard", "autoUpdateHours", "sourceEnabled", ...Object.keys(LIST_KEYS)];

  root.CipherLists = { DOMAIN_RE, SOURCES, isProtected, normalizeHost,
                      domainsFromLine, parseFilterLines, parseResponseDomains, cancelBody,
                      STRICT_ALLOW_DOMAINS, STRICT_ALLOW_URLFILTERS, isIpHost, isPrivateHost,
                      sourceHosts, sourceRedirectAllowed, LIMITS, EXPORT_KEYS, UPDATE_HOURS, sanitizeSettings, SETTINGS_FORMAT, isSettingsFormat, cleanDomains, sourceOn, fmtAge, mergedBulk, checkDownload };
})(typeof self !== "undefined" ? self : globalThis);
