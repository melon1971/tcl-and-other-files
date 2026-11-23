/* CipherPane local domain-risk heuristics. No network calls, no browsing-history storage.
 *
 * What it looks for (all on the hostname alone):
 *   - homoglyphs / digit substitution of a protected brand (paypa1, rnicrosoft, Cyrillic "раураl")
 *   - Latin letters mixed with Cyrillic/Greek inside one label
 *   - one-character typos / transpositions of longer brand names (gogle, paypla, micorsoft)
 *   - hyphen-split brand names (pay-pal.com)
 *   - brand + phishing keyword in the registrable name or in a subdomain (paypal-login.com, paypal.com.evil.test)
 *   - an exact brand name on a throw-away TLD (paypal.top)
 * What it deliberately does NOT do: flag the same brand on another normal TLD (amazon.es, paypal.me),
 * flag short brands for ordinary dictionary neighbours (apply, phase, case), or flag IPs / LAN names.
 * Scores >= 70 redirect to the warning page; anything lower is informational only.
 */
(function (root) {
  "use strict";
  const BRANDS = [
    ["paypal", ["paypal.com", "paypal.me", "paypalobjects.com"]],
    ["google", ["google.com", "google.co.uk", "google.ca", "google.de", "google.fr", "google.com.au", "google.es", "google.it", "google.co.jp", "google.com.br", "google.co.in"]],
    ["microsoft", ["microsoft.com", "live.com", "office.com", "outlook.com", "microsoftonline.com"]],
    ["apple", ["apple.com", "icloud.com"]],
    ["amazon", ["amazon.com", "amazon.co.uk", "amazon.ca", "amazon.de", "amazon.co.jp", "amazon.fr", "amazon.es", "amazon.it", "amazon.in", "amazon.com.au", "amazon.com.mx", "amazon.com.br", "amazonaws.com"]],
    ["facebook", ["facebook.com", "fb.com", "fb.me"]],
    ["instagram", ["instagram.com"]],
    ["whatsapp", ["whatsapp.com", "whatsapp.net"]],
    ["linkedin", ["linkedin.com"]],
    ["netflix", ["netflix.com", "netflix.net"]],
    ["chase", ["chase.com"]],
    ["wellsfargo", ["wellsfargo.com"]],
    ["bankofamerica", ["bankofamerica.com"]],
    ["coinbase", ["coinbase.com"]],
    ["binance", ["binance.com", "binance.us"]],
    ["github", ["github.com", "github.io", "githubusercontent.com"]],
    ["dropbox", ["dropbox.com"]],
    ["docusign", ["docusign.com", "docusign.net"]],
    ["ebay", ["ebay.com", "ebay.co.uk", "ebay.de", "ebay.com.au", "ebay.ca", "ebay.fr"]],
    ["adobe", ["adobe.com"]],
    ["yahoo", ["yahoo.com", "yahoo.co.jp", "yahoo.co.uk"]]
  ];
  // Short brands collide with ordinary words one letter away (apply, phase, case, ebay/bay), so they
  // are matched by look-alike characters only, never by edit distance.
  const MIN_EDIT_LEN = 6;

  // Second-level suffixes that make the registrable name the THIRD label from the right.
  const MULTI_SUFFIX = new Set(["co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.jp", "ne.jp",
    "co.nz", "co.in", "com.br", "com.mx", "com.cn", "com.tr", "com.sg", "co.za", "com.ar", "co.kr", "com.hk", "com.tw"]);
  const RISKY_TLD = new Set(["xyz", "top", "tk", "ml", "ga", "cf", "gq", "icu", "click", "buzz", "support", "work", "zip",
    "mov", "cam", "online", "site", "shop", "live", "life", "store", "rest", "fit", "cyou", "monster", "sbs", "cfd", "bond"]);
  const BAIT_WORDS = new Set(["login", "signin", "secure", "security", "verify", "verification", "account", "accounts", "update",
    "support", "billing", "wallet", "auth", "service", "services", "help", "recovery", "confirm", "unlock", "alert", "online", "pay", "payment"]);

  const CONFUSABLES = {
    "0": "o", "!": "i", "|": "l", "ı": "i", "İ": "i", "ɡ": "g", "ɑ": "a", "ӏ": "l", "ѕ": "s", "һ": "h", "ԛ": "q", "ԝ": "w", "ԁ": "d",
    "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "х": "x", "у": "y", "і": "i", "ј": "j", "к": "k", "м": "m", "н": "h", "т": "t", "в": "b",
    "α": "a", "ε": "e", "ο": "o", "ρ": "p", "ν": "v", "ι": "i", "κ": "k", "τ": "t", "υ": "u", "χ": "x", "β": "b"
  };
  const NON_LATIN_RE = /[Ͱ-ϿЀ-ԯ]/;   // Greek + Cyrillic
  const LATIN_RE = /[a-z]/;

  function cleanHost(input) {
    try {
      let h = String(input || "").trim().toLowerCase();
      if (/^[a-z][a-z0-9+.-]*:\/\//i.test(h)) h = new URL(h).hostname;
      else h = new URL("https://" + h).hostname;
      return h.replace(/\.$/, "");
    } catch (_) { return ""; }
  }

  function decodePunycode(label) {
    if (!label.startsWith("xn--")) return label;
    const s = label.slice(4), out = [];
    const dash = s.lastIndexOf("-");
    let n = 128, i = 0, bias = 72, pos = 0;
    if (dash >= 0) { for (const c of s.slice(0, dash)) out.push(c.codePointAt(0)); pos = dash + 1; }
    const digit = c => c >= "a" && c <= "z" ? c.charCodeAt(0) - 97 : c >= "0" && c <= "9" ? c.charCodeAt(0) - 22 : 36;
    const adapt = (delta, points, first) => { delta = first ? Math.floor(delta / 700) : delta >> 1; delta += Math.floor(delta / points); let k = 0; while (delta > 455) { delta = Math.floor(delta / 35); k += 36; } return k + Math.floor(36 * delta / (delta + 38)); };
    try {
      while (pos < s.length) {
        const old = i; let w = 1;
        for (let k = 36; ; k += 36) { if (pos >= s.length) return label; const d = digit(s[pos++]); i += d * w; const t = k <= bias ? 1 : k >= bias + 26 ? 26 : k - bias; if (d < t) break; w *= 36 - t; }
        const len = out.length + 1; bias = adapt(i - old, len, old === 0); n += Math.floor(i / len); i %= len; out.splice(i, 0, n); i++;
      }
      return String.fromCodePoint(...out);
    } catch (_) { return label; }
  }

  // What a human would read: accents stripped, look-alike characters folded to ASCII, "rn"->"m", "vv"->"w".
  // "1" is ambiguous (l or i), so the caller gets both readings.
  function visualForms(label) {
    const base = decodePunycode(label).normalize("NFD").replace(/[̀-ͯ]/g, "");
    const fold = (one) => Array.from(base).map(c => c === "1" ? one : (CONFUSABLES[c] || c)).join("").replace(/rn/g, "m").replace(/vv/g, "w");
    const a = fold("l"), b = fold("i");
    return a === b ? [a] : [a, b];
  }

  // Optimal-string-alignment distance (insert / delete / substitute / adjacent swap), bounded by limit.
  function editDistance(a, b, limit) {
    if (Math.abs(a.length - b.length) > limit) return limit + 1;
    let prev2 = null, prev = Array.from({ length: b.length + 1 }, (_, i) => i);
    for (let i = 1; i <= a.length; i++) {
      const cur = [i]; let rowMin = i;
      for (let j = 1; j <= b.length; j++) {
        let v = Math.min(cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
        if (prev2 && i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) v = Math.min(v, prev2[j - 2] + 1);
        cur[j] = v;
        if (v < rowMin) rowMin = v;
      }
      if (rowMin > limit) return limit + 1;
      prev2 = prev; prev = cur;
    }
    return prev[b.length];
  }

  // { labels, rootIdx } where labels[rootIdx] is the registrable name; rootIdx < 0 when there is none.
  function parseHost(host) {
    const labels = host.split(".");
    const tail2 = labels.slice(-2).join(".");
    const sufLen = labels.length >= 3 && MULTI_SUFFIX.has(tail2) ? 2 : 1;
    return { labels, rootIdx: labels.length - sufLen - 1, tld: labels[labels.length - 1] };
  }

  const isOfficial = (host, list) => list.some(d => host === d || host.endsWith("." + d));
  const tokens = (label) => label.split("-").filter(Boolean);

  function scoreHost(input, allowDomains) {
    const host = cleanHost(input);
    if (!host || host.length > 253) return { score: 0, reason: "invalid host", host: "" };
    if (/^(\d{1,3}\.){3}\d{1,3}$/.test(host) || host.startsWith("[")) return { score: 0, reason: "IP address", host };
    const allow = (Array.isArray(allowDomains) ? allowDomains : []).map(cleanHost).filter(Boolean);
    if (allow.some(x => host === x || host.endsWith("." + x))) return { score: 0, reason: "user allow-listed", host };

    const { labels, rootIdx, tld } = parseHost(host);
    if (rootIdx < 0) return { score: 0, reason: "no local lookalike match", host };

    // Latin mixed with Cyrillic/Greek inside one label is almost never legitimate.
    for (const l of labels) {
      const d = decodePunycode(l);
      if (d !== l && LATIN_RE.test(d) && NON_LATIN_RE.test(d)) return { score: 92, reason: "label mixes Latin and Cyrillic/Greek letters", host };
    }

    let best = { score: 0, reason: "no local lookalike match", host };
    const take = (score, reason) => { if (score > best.score) best = { score, reason, host }; };
    const root = labels[rootIdx];
    const rootForms = visualForms(root);
    const subs = labels.slice(0, rootIdx);

    for (const [brand, official] of BRANDS) {
      if (isOfficial(host, official)) continue;

      // look-alike characters in the registrable name
      if (root !== brand && rootForms.some(v => v === brand || v.replace(/-/g, "") === brand))
        take(root.includes("-") && !rootForms.includes(brand) ? 85 : 95,
             root.includes("-") ? "brand name split with hyphens: " + brand : "look-alike characters imitating " + brand);

      // typos of longer brand names
      if (brand.length >= MIN_EDIT_LEN) {
        const lim = brand.length >= 8 ? 2 : 1;
        for (const v of rootForms) {
          const d = editDistance(v.replace(/-/g, ""), brand, lim);
          if (d >= 1 && d <= lim) { take(d === 1 ? 85 : 72, "lookalike spelling of " + brand); break; }
        }
      }

      // brand + bait word in the registrable name (paypal-login.com, secure-paypal.net)
      const tk = tokens(root);
      if (tk.length >= 2 && tk.includes(brand) && tk.some(t => BAIT_WORDS.has(t)))
        take(88, "brand name with a phishing keyword: " + brand);

      // brand used as a subdomain of someone else's domain: paypal.com.evil.test, login.paypal.evil.test.
      // A bare "<brand>.github.io"-style label is NOT flagged (facebook.github.io, google.github.io are real).
      const TLDISH = new Set(["com", "net", "org", "co"]);
      const baitSub = subs.some(l => tokens(l).some(t => BAIT_WORDS.has(t)));
      if (subs.some((l, i) => (l === brand && (TLDISH.has(subs[i + 1]) || baitSub)) ||
                              (tokens(l).includes(brand) && tokens(l).some(t => BAIT_WORDS.has(t)))))
        take(78, "brand-name subdomain impersonation of " + brand);

      // the exact brand name on a throw-away TLD
      if (root === brand && RISKY_TLD.has(tld)) take(75, "brand name on a high-abuse TLD: " + brand);
    }
    return best;
  }
  root.CipherReputation = Object.freeze({ scoreHost, editDistance, parseHost });
})(typeof self !== "undefined" ? self : globalThis);
