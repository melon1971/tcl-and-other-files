// blocked.html is web-accessible (DNR redirects to it), so any web page can open it with any query
// string. Treat every parameter as untrusted: show only text that matches what CipherPane itself produces.
// A web page can embed this page in a frame. Nothing here may be clickable from inside one.
const framed = window.self !== window.top;
const params = new URLSearchParams(location.search);
const HOST_RE = /^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$/;
const DETAIL_RE = /^(look-alike characters imitating |brand name split with hyphens: |lookalike spelling of |brand name with a phishing keyword: |brand-name subdomain impersonation of |brand name on a high-abuse TLD: )[a-z]{3,20}$|^label mixes Latin and Cyrillic\/Greek letters$/;

if (params.get("reason") === "lookalike") {
  const host = (params.get("host") || "").toLowerCase();
  const detail = params.get("detail") || "";
  const okHost = HOST_RE.test(host);
  const h = document.createElement("p");
  h.className = "hint";
  h.textContent = "Local phishing heuristic: " + (DETAIL_RE.test(detail) ? detail : "suspicious lookalike domain") +
    " (" + (okHost ? host : "unknown host") + ").";
  document.querySelector(".card")?.insertBefore(h, document.getElementById("backBtn"));
  const p = document.querySelector(".card > p");
  if (p) p.textContent = "CipherPane detected a likely brand-impersonation domain and redirected this navigation before continuing.";
  const allow = document.getElementById("allowBtn");
  if (allow && okHost && !framed) {
    allow.hidden = false;
    allow.addEventListener("click", () => {
      try { chrome.tabs.create({ url: chrome.runtime.getURL("options.html#allow=" + encodeURIComponent(host)) }); } catch (e) {}
    });
  }
}
document.getElementById("backBtn").addEventListener("click", () => history.back());
