(function () {
  "use strict";
  const msg = document.getElementById("msg");
  let target = null;
  const strong = new URLSearchParams(location.search).get("s") === "1";
  try {
    const raw = new URLSearchParams(location.search).get("u") || "";
    const u = raw.length <= 2048 ? new URL(raw) : null;
    if (u && u.protocol === "http:" && !u.username && !u.password) target = u;
  } catch (e) {}
  const back = document.getElementById("backBtn");
  back.addEventListener("click", () => { history.length > 1 ? history.back() : window.close(); });
  if (!target) {
    msg.textContent = "Nothing to continue to.";
    document.getElementById("onceBtn").disabled = true;
    document.getElementById("alwaysBtn").disabled = true;
    return;
  }
  document.getElementById("hostName").textContent = target.hostname;
  if (!strong) {
    const ab = document.getElementById("alwaysBtn");
    ab.disabled = true;
    msg.textContent = "The failure looked like a connection reset or protocol error, which can be caused by someone on the network. \"Always allow\" is not offered; you can continue once.";
  }
  async function go(mode) {
    try {
      const r = await chrome.runtime.sendMessage({ type: "ALLOW_HTTP", host: target.hostname, mode });
      if (!r || !r.ok) throw new Error("refused");
      location.replace(target.href);
    } catch (e) {
      msg.textContent = "Could not allow this site (only normal domain names can be allowed).";
    }
  }
  document.getElementById("onceBtn").addEventListener("click", () => go("session"));
  document.getElementById("alwaysBtn").addEventListener("click", () => go("always"));
})();
