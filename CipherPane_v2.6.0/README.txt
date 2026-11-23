# CipherPane Browser Security v2.6.0

**Browser Security Suite for Chrome, Brave, Edge 121+, and Firefox 140+**  
**Manifest V3**

CipherPane was formerly named **AegisGate Browser Firewall & Threat Blocker**. It was renamed in version 2.6.0; see [Migrating from AegisGate](#migrating-from-aegisgate).

---

## Table of Contents

1. [Installation](#installation)
2. [Settings](#settings)
3. [Testing and Verification](#testing-and-verification)
4. [What It Does](#what-it-does)
5. [Rule Priority](#rule-priority)
6. [Migrating from AegisGate](#migrating-from-aegisgate)
7. [Changes in 2.6.0](#changes-in-260)
8. [Earlier Releases](#earlier-releases)
9. [Known Limits](#known-limits)

---

## Installation

### Chrome, Brave, or Edge

1. Open `chrome://extensions`.
2. Enable **Developer mode**.
3. Choose **Load unpacked**.
4. Select `dist/chrome`.

### Firefox

1. Open `about:debugging#/runtime/this-firefox`.
2. Choose **Load Temporary Add-on**.
3. Select `dist/firefox/manifest.json`.

The `dist/` folder is produced by:

```bash
node tools/build.js
```

Chrome and Firefox use separate manifests: Chrome uses a service worker, while Firefox uses an event page. Ready-made archives for both browsers are included alongside the source files.

---

## Settings

Open Settings by:

- Clicking the gear in the popup, or
- Right-clicking the toolbar icon and choosing **Options**, **Manage extension**, or **Extension options**.

For Firefox, grant **Access your data for all websites** under:

```text
about:addons -> CipherPane -> Permissions
```

---

## Testing and Verification

Run the included test suite:

```bash
node tests/run.js
```

The suite has no dependencies and runs list/rule, page-script, and worker runtime tests.

Verify the release files from the release folder, next to the ZIP archives:

```bash
sha256sum -c SHA256SUMS
```

On macOS:

```bash
shasum -a 256 -c SHA256SUMS
```

A matching hash shows that a file is unchanged since packaging. It does not establish who packaged it.

---

## What It Does

| Feature | Description |
| --- | --- |
| Deceptive-URL protection | Blocks HTTP(S) URLs with credentials embedded in the authority, using local priority-160 heuristic rules. Detects common brand typos and selected IDN homoglyphs before navigation continues. |
| Malware and phishing guard | Uses priority-1000 built-in rules and priority-150 downloaded URLhaus/phishing lists. Trust Site cannot override these rules. |
| Ad and tracker blocker | Blocks built-in domains and the auto-updating HaGeZi Light list. StevenBlack is optional. |
| HTTPS enforcement | Forces HTTPS with an HTTP fallback warning page. Trust Site does not disable the upgrade. |
| Download Guard | Provides Off, Balanced, and Strict modes. |
| Script and firewall controls | Includes a Third-Party Script Blocker and Strict outbound firewall, with login, payment, and captcha providers exempted. |
| Bulk management | Imports up to 100,000 domains, supports up to 20,000 custom blocks, and provides a live per-tab request logger. |

Hostnames are evaluated locally and are not uploaded or retained as browsing history. Navigation redirects are best-effort; static DNR list matches remain the synchronous block layer.

If a legitimate site is incorrectly listed, disable that list in:

```text
Bulk Lists -> Auto-updating block lists
```

---

## Rule Priority

Rules are applied from highest to lowest priority:

| Priority | Rule |
| ---: | --- |
| 1001 | LAN exemption |
| 1000 | Built-in malware rules |
| 200 | Custom blocks |
| 160 | Deceptive-URL heuristic |
| 150 | Malware/phishing lists |
| 100 | Trust Site |
| 40 | Other lists |
| 30 | Login/payment exemptions |
| 20 | Strict outbound firewall |
| 10 | Script blocker |
| 6 | Allow HTTP |
| 5 | HTTPS upgrade |
| 1 | Ad rules |

---

## Migrating from AegisGate

The name, Firefox add-on ID, and settings-export format changed in CipherPane 2.6.0.

- The Firefox add-on ID is now `cipherpane-security@local.extension`.
- Storage keys did not change, so an in-place update of the same Chrome folder retains settings.
- A browser that treats the extension as new starts with default settings. This includes Firefox after the add-on ID change and Chrome when the unpacked folder path changes.

To transfer settings:

1. Open **Settings -> Export** in the old AegisGate version.
2. Open CipherPane Settings.
3. Choose **Import**.

Files exported by AegisGate 2.5.x import without conversion.

Remove the old AegisGate extension afterward so both extensions do not filter the same requests.

---

## Changes in 2.6.0

The 2.6.0 release includes a rename, cleanup, and security hardening pass. Full details are available in `SECURITY_AUDIT_v2.6.0.txt`.

### Security

- Downloaded feeds can no longer block registry suffixes such as `co.uk` or `com.au`, preventing one bad feed line from blocking every site below the suffix.
- Extension-page CSP is now default-deny, using `default-src 'none'` with restricted frame and worker sources.
- The block page disables its **Review in Settings** button when a web page places it in a frame.
- The no-HTTPS warning page and worker now reject targets with embedded credentials or lengths over 2,048 characters.
- The worker also validates the type and length of message fields before using them.

### Cleanup

- Removed unused code, including `visualLabel`, the `cleanHost` export, `SOURCES[].url`, an unused `fetchOne` parameter, and one wrapper function.
- Removed duplicated constants and age formatting from the popup and options page.
- Removed the stale 2.5.0 audit file and duplicated changelog blocks.
- Removed `dist/` from the source ZIP. It is generated and distributed as separate Chrome and Firefox ZIP archives.

### Compatibility

- Settings exported under the old AegisGate name continue to import.

---

## Earlier Releases

| Release | Summary |
| --- | --- |
| 2.5.1 | Corrected URLhaus and HaGeZi mirrors, ordered mirror fallback, prevented stale persisted entries from blocking updater hosts, and preserved last-known-good lists on failure. |
| 2.5.0 | Added the settings page and new icon set, introduced separate Chrome/Firefox manifests, rewrote lookalike protection with false-positive fixes, removed the redundant `tabs` permission, and added blocked-page parameter validation. |
| 2.4.4 | Added deceptive-URL protection and local lookalike/homoglyph protection, with a six-hour default feed interval. |
| 2.4.x | Improved memory and bounds hardening, added log caps and streamed list parsing, capped session rules, hardened worker-page checks, prevented Trust Site from overriding threat lists, and added anchored LAN exemptions and same-host-only feed redirects. |

---

## Known Limits

- `blocked.html` is web-accessible for redirects, so a website may detect that the extension is installed.
- A worker killed within 0.5 seconds of a block may lose that single count.
- Download Guard can inspect only the file name and MIME type reported by the browser; archives are not opened.
- Block lists contain only threats that have already been reported.
- The lookalike heuristic can miss novel attacks and produce false positives; redirects are best-effort.
- CipherPane operates only at the browser layer. It does not replace an OS firewall or sandbox.
- No independent penetration test or live-browser certification is included.
- Included tests run against a mocked browser API.

