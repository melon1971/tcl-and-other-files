CIPHERPANE BROWSER SECURITY v2.6.0 (Chrome/Brave/Edge 121+ & Firefox 140+, MV3)
==========================================================================================
Formerly "AegisGate Browser Firewall & Threat Blocker". Renamed in 2.6.0; see MIGRATING below.

INSTALL (Chrome/Brave/Edge): chrome://extensions -> Developer mode -> Load unpacked -> dist/chrome
INSTALL (Firefox, temporary): about:debugging#/runtime/this-firefox -> Load Temporary Add-on -> dist/firefox/manifest.json
(dist/ is produced by "node tools/build.js"; the two folders differ only in the manifest: Chrome uses a
service worker, Firefox an event page. Ready-made zips of each ship alongside the source.)
SETTINGS: click the gear in the popup, or right-click the toolbar icon -> Options / Manage extension -> Extension options.
Firefox: grant "Access your data for all websites" in about:addons -> CipherPane -> Permissions.
TESTS:   node tests/run.js   (no dependencies; lists/rules, page-script and worker runtime tests)
VERIFY:  in the release folder (next to the zips, not inside them): sha256sum -c SHA256SUMS
         (macOS: shasum -a 256 -c SHA256SUMS). A matching hash shows the file is unchanged since packaging;
         it does not show who packaged it.

WHAT IT DOES
- Local deceptive-URL heuristic (priority 160): blocks HTTP(S) URLs with credentials embedded in the authority.
  Local lookalike checks detect common brand typos and selected IDN homoglyphs before navigation continues.
  Hostnames are evaluated locally and are not uploaded or retained as browsing history. The navigation
  redirect is best-effort; static DNR list matches remain the synchronous block layer.
- Malware/phishing guard. Not overridable by Trust Site: the built-in rules (priority 1000) and the
  downloaded URLhaus (via curbengh) + phishing lists (priority 150). If a site is wrongly listed, switch that
  list off in Bulk Lists -> Auto-updating block lists.
- Ad/tracker blocker (built-in domains + auto-updating HaGeZi Light; StevenBlack optional).
- Force HTTPS with HTTP fallback warning page. Trust Site does not disable the upgrade.
- Download Guard (Off / Balanced / Strict).
- Third-Party Script Blocker and Strict outbound firewall (login/payment/captcha providers exempt).
- Bulk importer (up to 100,000 domains), custom blocks (up to 20,000), live per-tab request logger.

Priority order, highest first: 1001 LAN exemption, 1000 built-in malware rules, 200 custom blocks,
160 deceptive-URL heuristic, 150 malware/phishing lists, 100 Trust Site, 40 other lists,
30 login/payment exemptions, 20 Strict, 10 script blocker, 6 "allow HTTP", 5 HTTPS upgrade, 1 ad rules.

MIGRATING FROM AEGISGATE
The name, the Firefox add-on ID (now cipherpane-security@local.extension) and the settings-export format
changed. Storage keys did not, so an in-place update of the same Chrome folder keeps settings. A browser that
treats this as a new extension (Firefox always does, because the ID changed; Chrome does when the unpacked folder
path differs) starts with defaults. To carry settings over: in the OLD version open Settings -> Export, then in
CipherPane open Settings -> Import. Files exported by AegisGate 2.5.x import as they are.
Remove the old AegisGate extension afterwards so the two do not both filter the same requests.

CHANGES IN 2.6.0 (rename, cleanup, hardening). Details: SECURITY_AUDIT_v2.6.0.txt
Security
- Downloaded feeds can no longer block registry suffixes such as co.uk or com.au (one bad feed line would
  otherwise block every site under the suffix).
- Extension-page CSP is now default-deny (default-src 'none', plus frame-src and worker-src).
- The block page disables its "review in Settings" button when a web page has put it in a frame.
- The no-HTTPS warning page and the worker both refuse targets that carry embedded credentials or exceed
  2,048 characters; the worker also checks the type and length of message fields before using them.
Cleanup
- Removed unused code: visualLabel and the cleanHost export, the SOURCES[].url field, an unused fetchOne
  parameter, a wrapper function and duplicated constants/age formatter in the popup and options page.
- Removed the stale 2.5.0 audit file and the duplicated changelog blocks; dist/ is no longer shipped inside
  the source zip (it is built, and shipped as the Chrome and Firefox zips).
Compatibility
- Settings exported by the old name still import.

EARLIER RELEASES (summary)
2.5.1  Feed repair: URLhaus and HaGeZi mirrors corrected (410/404), ordered mirror fallback, stale persisted
       entries can no longer block the updater's own hosts, last-known-good lists preserved on failure.
2.5.0  Settings page, new icon set, separate Chrome/Firefox manifests (tools/build.js), lookalike heuristic
       rewrite with false-positive fixes, redundant "tabs" permission removed, blocked.html parameters validated.
2.4.4  Deceptive-URL (userinfo) rule and local lookalike/homoglyph protection; six-hour default feed interval.
2.4.x  Memory and bounds hardening (log caps, streamed list parsing, session-rule cap), worker-side checks of
       the warning page, Trust Site no longer overrides downloaded threat lists, anchored LAN exemption,
       stricter Download Guard, same-host-only feed redirects, worker-restart resilience.

KNOWN LIMITS (not fixable in a browser extension)
- blocked.html is web-accessible (needed for redirects), so a site can detect that the extension is installed.
- A worker hard-killed within 0.5 s of a block can still lose that single count.
- Only the file name and MIME type the browser reports can be checked; archives are not opened.
- Block lists only know threats that were already reported. The lookalike heuristic can miss novel attacks
  and can produce false positives; its redirect is best-effort.
- This is a browser-layer filter. It does not replace an OS firewall or sandboxing, and it has had no
  independent penetration test or live-browser certification. The included tests run against a mocked
  browser API.
