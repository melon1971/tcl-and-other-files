This README documents five groups of independent components:

1. **[LocSec](#locsec--local-host-security-daemon)**: a Linux host security daemon and dashboard (package `locsecd`, v5.0-12).
2. **[masterhelp.tcl](#masterhelptcl--eggdrop-help-menu-script)**: an Eggdrop IRC bot script that provides the `!bhelp` help menu.
3. **[The Eggdrop scripts it indexes](#eggdrop-scripts-indexed-by-masterhelptcl)**: the OS reference, game, IRC-tool, and utility scripts that `!bhelp` points users to.
4. **[Eggdrop on Debian 13 (Trixie)](#eggdrop-on-debian-13-trixie--package-requirements)**: the apt packages the full Eggdrop script set needs, by script.
5. **[LiveWorld RPG](#liveworld-rpg--offline-fantasy-rpg)**: an offline isometric fantasy RPG for Debian-based Linux (package `liveworld-rpg`, v1.0.11).

LocSec, the Eggdrop scripts and LiveWorld RPG are unrelated pieces of software. They are documented together here for convenience.

---

# LocSec — Local Host Security Daemon

**Version 5.0-12** · Package: `locsecd` · 

> **Release status (5.0-12, 9 October 2026): a FIX. Install it if you installed 5.0-10 or 5.0-11.** In those two releases the dashboard window opened but showed `{"error": "not found"}` instead of the dashboard. Cause: 5.0-10 changed the page's `Permissions-Policy` header and left a `#` comment in the middle of the one-line chain of statements that sends the page, so everything after it (`Content-Length`, `end_headers()`, the page body, the `return`) was commented out and the server fell through to its "not found" reply. The service, scans, firewall, broker, captures and API were not affected, only the dashboard page. It was not caught because the 5.0-10 test only looked for the header text in the source and `locsec-vm-check.sh` only requested the page without logging in. 5.0-12 moves the comment, adds `tests/test_http_5012.py` (loads the page the way the desktop window does with the real request handler; it fails on the 5.0-11 code and passes on the built 5.0-12 `.deb`), and adds the same login-and-load check to `locsec-vm-check.sh`. **5.0-12 was then installed and checked on the same machine: 66 passed, 0 failed, 0 warnings** (62 for 5.0-10 plus the 4 items added since: the dashboard-page load and the three optional-tool checks), with both AppArmor profiles in enforce mode.
>
> **Status of 5.0-11 (9 October 2026; its dashboard was broken, see above).** 5.0-11 follows the first switch of the AppArmor profiles to enforce mode on a real machine, where `aa-enforce` was "command not found" until `apparmor-utils` was installed. The package now **recommends** `apparmor-utils` and `libcap2-bin` (not hard dependencies: LocSec installs and runs without them, and `apt install --no-install-recommends` skips them), so a normal `sudo apt install ./locsecd_5.0-12_amd64.deb` brings them in; `locsec-vm-check.sh` has an opt-in `--install-missing` flag for machines that already have LocSec. **5.0-11 itself has not been installed yet**: run `locsec-vm-check.sh` after installing.
>
> **Status of 5.0-10 (9 October 2026).** 5.0-10 follows the Logs page of the 5.0-9 machine: the desktop window no longer logs two Permissions-Policy warnings at every load, Debian's cosmetic `tcpdump` `/dev/null` denials are an information row on the Logs page, the broker profile states `deny capability sys_ptrace` (an optional request from `pgrep` that the unit never had), and the check script's ClamAV write probe no longer shows up as a Problem. The same log showed NetworkManager complaining every 12 seconds that IPv6 is disabled: that is **not** LocSec. It comes from the machine's own `/etc/sysctl.d/99-hardening.conf` (15 July, before LocSec was installed), which sets `net.ipv6.conf.all.disable_ipv6 = 1` while the connection's `ipv6.method` is `auto`; `nmcli connection modify "Wired connection 1" ipv6.method disabled` quiets it. **5.0-10 was then installed and checked on the same machine: 62 passed, 0 failed, 0 warnings**, with the attack test (28 refusals, each naming pid, uid and path), a capture that saved data, the ClamAV probe, and **no `ALLOWED` line at all**, so the enforce-readiness report said ready. After the full dashboard walkthrough on 5.0-9 the only line the profiles had logged was `pgrep`'s optional `sys_ptrace` request, which 5.0-10 states in the profile. **Both profiles were then switched to enforce mode on that machine** (`sudo aa-enforce /etc/apparmor.d/locsecd`, which needs `sudo apt install apparmor-utils`): `aa-status` listed `locsecd-broker` and `locsecd-web` in enforce mode, the attack test still passed (28 refusals), a capture saved 50,660 bytes, and the check reported no `DENIED` line for LocSec or the tools it runs. The check script of 5.0-10 first failed two items in that state because it assumed complain mode; it now accepts either mode (undo: `sudo aa-complain /etc/apparmor.d/locsecd`). The profiles ship in complain mode, so enforce is a deliberate step you take on your own machine after a walkthrough.
>
> **Status of 5.0-9 (9 October 2026).** 5.0-8 was installed and checked on the same machine (Debian 13, KDE Plasma, Wayland): `locsec-vm-check.sh` **56 passed, 0 failed**, and the profile rules added in 5.0-8 are confirmed: the `DEBSECAN` and ClamAV scans ran afterwards and logged nothing for `debsecan`, `nice`, `ionice`, `dpkg` or `nmcli`. The only `ALLOWED` line left was the broker opening the `/home/` directory itself. 5.0-9 adds that rule (so the readiness report should show nothing after a full walkthrough) and **plans the weekly scans on different days**. **5.0-9 was then installed and checked on the same machine: 62 passed, 0 failed, 0 warnings** (attack test: 28 refusals; a capture saved data; the ClamAV probe passes; the AppArmor profiles logged no `ALLOWED` line since the broker started, so the enforce-readiness report said ready). That readiness is only as good as the walkthrough behind it: after the upgrade only the `DEBSECAN` and ClamAV scans and a capture had been run, so do the full dashboard walkthrough once more before switching the profiles to enforce (`sudo aa-enforce /etc/apparmor.d/locsecd`; undo with `sudo aa-complain /etc/apparmor.d/locsecd`).
>
> **Status of 5.0-8 (9 October 2026).** 5.0-7 was installed and checked on the same machine (Debian 13, KDE Plasma, Wayland): `locsec-vm-check.sh` **60 passed, 0 failed**, with the attack test (28 refusals, each naming pid, uid and path), a capture that saved data, the ClamAV-as-`clamav` probe, and the two cosmetic `tcpdump` `/dev/null` lines reported as information. After the upgrade the AppArmor profiles logged **one** `ALLOWED` line, `nmcli`. 5.0-8 adds the rule for it and for the other programs the same machine logged earlier (`nice`, `ionice`, `debsecan`, `dpkg`); the profiles stay in complain mode. **5.0-8 itself has not been installed yet**: run `locsec-vm-check.sh` after installing.
>
> **Status of 5.0-7 (9 October 2026).** 5.0-6 was installed and checked on a real machine (Debian 13, KDE Plasma, Wayland, kernel 6.12, systemd 257, AppArmor 4.1): `locsec-vm-check.sh` **59 passed, 0 failed**, with the attack test (all 28 attempts refused), the capture saving data, `pkg.verify` working, no `fdpass failed` lines, and the new ClamAV probe passing (a unit started as `clamav` with `CAP_DAC_READ_SEARCH` scanned a root-only file with `--fdpass` and could not write a root-owned file). A full dashboard walkthrough ran on the same machine: AIDE, Lynis (75/100), debsecan, rkhunter, ports, CVE, definitions, Update system, a capture with built-in analysis, and the Suricata log (53,108 rules loaded, Problem 0, Warning 0), and a ClamAV scan from the dashboard that completed (one informational line: a file changed during the scan). 5.0-7 follows that run: **notifications are off until enabled** (Enable and Disable buttons), **the dashboard window stays open** when another window is clicked, the **AppArmor profile is fixed for what it logged on that machine**, and **rkhunter's "file properties changed" warnings are classified** when dpkg verifies the file. **5.0-7 itself has not been installed yet**: install it and run `locsec-vm-check.sh`.
>
> **Status of 5.0-6 (9 October 2026).** 5.0-6 closes 5.0-6 closes what 5.0-5 listed as open, as far as that can be done without a real machine: ClamAV scans run as the `clamav` user so they cannot write root's files, `locsec-vm-check.sh` reports whether the AppArmor profiles are ready for enforce mode, a signing script is included, and the four test files that were not run now ran in a sandbox. **None of the 5.0-5 or 5.0-6 changes has been installed on a real machine yet**: install it and run `locsec-vm-check.sh`. The 5.0-6 ClamAV change in particular has only been tested with stubbed commands (systemd parses the unit settings as intended; the live probe is in the check script).
>
> **Status of 5.0-5 (9 October 2026).** 5.0-5 is built from the 5.0-3 code that ran on a real machine (Debian 13, KDE Plasma on X11, kernel 6.12, systemd 257, AppArmor 4.1): `locsec-vm-check.sh` 54 passed and 0 failed with the attack test, Lynis read its report again, rkhunter's package check worked, ClamAV used `--fdpass` on 33,411 files with 0 errors, and the AIDE check wrote its report. **5.0-5 itself has not been installed on a real machine yet**: run `locsec-vm-check.sh` after installing (its new 5.0-5 checks include a real packet capture). There was no 5.0-4 release; its changes are in 5.0-5. Still true: releases are unsigned (check SHA256SUMS) and no third-party security review is recorded here. Since 5.0-2 the AppArmor profiles are installed and loaded in complain mode (they log what enforce mode would block and do not yet enforce it).
>
> **Earlier status (5.0-1): production release.** Reported by the tester: about three weeks of continuous use through every scan and upgrade on Debian 13 (GNOME and KDE Plasma) and Linux Mint 22 (Cinnamon), with logs correct and `locsec-vm-check.sh` passing. 5.0-1 is the 4.0.11-103 code with a new version number. **Ubuntu (24.04, 26.04, 26.10), Debian 12 and LMDE are expected to work but have not been run yet**; Mint 22 is built on Ubuntu 24.04, so most of the path is shared. Still true: releases are unsigned (check SHA256SUMS), no third-party security review is recorded here, and the AppArmor profiles are not loaded.
>
> **Earlier status (4.0.11-103): release candidate for Debian 13 (GNOME).** Reported by the tester, not independently verified: about a week of normal use on Debian 13 (GNOME) on builds -97 to -102, no daemon or broker errors in the journal there, and `locsec-vm-check.sh` passed on -103 with its attack test. Linux Mint 22.3 (Cinnamon) ran about a week on the early 4.0 builds (up to 4.0.11-88); the two-process builds (-91 and later) have not run on Mint. Still true: unsigned releases, no independent security review, AppArmor profiles not loaded.
>
> **Earlier status (kept for the record): pre-release, not yet for production.** 4.0.11-103 is the two-process LocSec (since -91) plus fixes found on a real Debian 13 machine (GNOME on Wayland, systemd 257). There 4.0.11-97 passed all 35 install checks, including the attack test, and earlier builds ran every scan and Update system from the dashboard. 4.0.11-98 passed 40 install checks there, including its new log-format checks, and block and unblock, quarantine and restore worked. A purge and fresh install of -101 worked, and the rest of the walkthrough was reported working. -102 stopped LocSec editing ClamAV's own config file, which made that reinstall stop at a "package maintainer's version" prompt, and starts clamd once its first signatures arrive; a fresh -102 install passed 41 checks with one warning, which -103 removes (two AppArmor log lines from the units' unloaded profile names). KDE Plasma, Ubuntu, Debian 12 and Mint are still untested. See [Release status](#release-status).

LocSec is a 24/7 security daemon and desktop dashboard for a **single Linux host**. It does not reimplement security tools. Instead, it coordinates the standard ones and puts them behind one dashboard:

- firewall
- network intrusion detection
- malware scanning
- file-integrity monitoring
- package and CVE auditing

The dashboard is served over HTTPS at `127.0.0.1:8765` and shown in a native Qt6 desktop window.

Since 4.0.11-91 LocSec runs as two services:
- **`locsecd.service`** runs as the unprivileged system user `locsec`. It serves the dashboard and API, does the monitoring, downloads the threat feeds, runs the scheduler and parses every log, alert and capture.
- **`locsecd-broker.service`** runs as root and only carries out a fixed list of named operations for it: firewall changes, packet capture, scans, updates, quarantine and the like. It has no network access.

You enable, start and stop `locsecd.service`. The broker follows it.

LocSec does not phone home, and it contains no AI component: nothing in the package contacts a language model.

---

## What it does

| Area | What LocSec does | Backed by |
| --- | --- | --- |
| **Firewall & auto-blocking** | Blocks IPs and CIDRs that trigger either detector. Blocks expire automatically. Private and loopback networks are never auto-blocked. See the details below this table. | UFW (primary), nftables (fallback) |
| **Fallback firewall** | If UFW is installed but inactive, installs its own default-deny input chain after about 2 minutes. It never force-enables UFW, so remote installs can't lock you out. | nftables |
| **Threat intelligence** | Refreshes IOC feeds every 12 h, over HTTPS only. Auto-blocks listed addresses (capped per refresh) and checks domains, IPs and URLs against the local copy. | Feeds + local cache |
| **Network intrusion detection** | Reads Suricata's alerts every minute. Severity 1–2 alerts become *Intrusion signature (Suricata)* incidents. Severity 1 also blocks the remote address for 24 h, but only when that address is certainly the sender (outbound traffic, or inbound TCP). Inbound UDP can be forged, so it is recorded but never blocked. Suricata is set up automatically at install and kept on the right network interface. Rules refresh after each feed update. | Suricata, suricata-update |
| **Malware scanning** | Daily ClamAV scan of `/home` (configurable). Infected files can be quarantined, restored (SHA-256 verified) or deleted. | ClamAV |
| **File-integrity monitoring** | Weekly AIDE check that explains each change in plain language, including whether a package install explains it. Baseline workflow: **Build AIDE database**, or accept a pending baseline. | AIDE |
| **Hardening audit** | Weekly Lynis run. Reports the hardening index, warnings and suggestions. | Lynis |
| **Rootkit detection** | Weekly rkhunter run. Warnings are classified as benign or needs-review, with an ignore list for known-good items. | rkhunter |
| **CVE & update auditing** | Weekly CVE scan: debsecan on Debian/LMDE, and pending APT security updates everywhere. Applies security updates automatically every 12 h. The last update time survives restarts, and a failed update is retried after an hour. | debsecan, APT, unattended-upgrades |
| **Network inspection** | Live connections and listening ports, and bounded packet capture. **Analyze** uses a built-in, memory-safe header reader, so Wireshark is never exposed to captured traffic by default. An optional **Deep analysis** runs tshark as a throwaway unprivileged user with no network. | tcpdump, built-in reader, tshark (optional) |
| **Incident timeline** | Every block, scan finding, intrusion alert and login event in one place. Each has **Explain**, **Fix it** (where a safe automatic fix exists) and **Mark solved**. Repeats fold into one open incident. | Built-in rules |
| **Log readability** | Rewrites auth, firewall, AIDE, rkhunter, ClamAV, Suricata and system logs into labelled rows (**OK / Info / Warning / Problem**). Every problem row comes with a *What to do* fix. | journald / rsyslog files |
| **System hardening** | Applies kernel and network sysctl hardening. Blocks unused protocol modules (`dccp`, `sctp`, `rds`, `tipc`). Deliberately skips settings that break VPNs, IPv6, Flatpak or SysRq. | sysctl, modprobe |

**Auto-blocking thresholds:**
- **Failed logins:** 5 in 15 minutes (default).
- **Port scans:** 8 closed ports in 10 minutes.
- **Block lifetime:** 30 days by default. Port-scan blocks last 24 h, because probe addresses can be forged.

**How heavy scans run:**
- One at a time, at low CPU and I/O priority.
- Only when the machine has been idle (load ≤ 1.0 for 10 minutes).
- While a job runs, LocSec holds off suspend and lid-close sleep, so a laptop doesn't freeze a scan halfway. It never wakes a sleeping computer.

Real-time protection (login monitoring, intrusion alerts, blocking) never waits for idle.

---

## Dashboard

Open it with:

```bash
locsecctl gui
```

or browse to `https://127.0.0.1:8765/dashboard`.

- It is served over HTTPS only (TLS 1.2+), with a certificate generated for the machine.
- The desktop window verifies that certificate before it sends the API token.

Pages:

- **Overview**:
  - protection status and missing tools
  - Suricata state
  - an exposure card covering firewall policy, network-facing services, SSH logins and disk encryption
- **Firewall & Blocks**: UFW control, manual block/unblock, and an explanation for every block.
- **Login Activity**: authentication successes and failures, and the block threshold.
- **Incidents**: the timeline, response-policy toggles and desktop notifications.
- **Scans & CVEs**:
  - run scans
  - a schedule table showing when each job last ran and is next due
  - update the system
  - **Build AIDE database** and accept a pending AIDE baseline
- **Malware / Quarantine**: quarantine, restore and delete files.
- **Threat Intelligence**: feed refresh, indicator lookup, and an **Intrusion detection (Suricata)** card. The card shows:
  - what Suricata does and its state
  - the capture interface next to the interface the computer actually uses
  - the rule count and rule date
  - alerts in the last 24 h and counts by severity
  - the most frequent signatures and the 50 most recent alerts
  - why the list is empty, when it is
- **Ports & Capture**: connections, listening ports and packet captures.
  - **Analyze** uses the built-in header reader.
  - **Deep analysis (Wireshark)** gives the full protocol breakdown, sandboxed.
- **Services**: systemd unit control for LocSec-managed services. Other services need an explicit opt-in, and units your access depends on are protected.
- **Reports**: recent JSON reports, auto-deleted after 7 days.
- **Logs**: a plain-language log viewer, including **Suricata alerts** and **Suricata engine** sources:
  - **Suricata alerts** reads `eve.json` backwards and shows alert records only.
  - **Suricata engine** shows `suricata.log`, with a fallback to `journalctl -u suricata`.
- **Troubleshooting / Help**: the built-in reference.

**Panel icon:**
- A shield icon starts at every graphical login and opens or hides the native window. It is blue when LocSec is running and amber when it is stopped or failed.
- Quitting the icon does not stop the `locsecd` service.
- Vanilla GNOME on Debian needs `gnome-shell-extension-appindicator` to show the icon.

PyQt6 and QtWebEngine are hard dependencies, so the dashboard does not normally open in an external browser. A single-use login-code browser path remains only as a recovery fallback, for when the Qt components are missing.

---

## Command line

```bash
locsecctl status                  # status of locsecd and locsecd-broker
locsecctl start | stop | restart  # control the service
locsecctl enable | disable        # launch at boot
locsecctl gui                     # open the desktop window
locsecctl tray                    # start the panel icon only
locsecctl scan-aide | scan-lynis | scan-rkhunter | scan-clamav | scan-debsecan | scan-ports
locsecctl cve                     # CVE scan now
locsecctl update                  # apply system updates now
locsecctl feed-update             # refresh threat feeds now
locsecctl aide-init               # create AIDE baseline only if none exists
locsecctl aide-accept             # promote pending AIDE baseline after review
locsecctl aide-reinitialize       # = Build AIDE database: rebuild and replace the baseline
locsecctl suricata-setup          # set Suricata's interface, download rules, start it
locsecctl suricata-status         # show Suricata's state and what suricata-setup would change
locsecctl tls-fingerprint         # show the dashboard certificate fingerprint
locsecctl tls-renew               # regenerate the dashboard certificate (then restart locsecd)
locsecctl logs                    # last 200 journal lines of both services
locsecctl broker-verbs            # everything LocSec can do as root (no root needed)
locsecctl uninstall               # staged uninstall (--keep-tools, --all, --include-firewall, --dry-run, -y)
```

A local JSON API is also available.
- Every request needs the token (`/var/lib/locsecd/api.token`, readable only by root and the `locsec` account) in an `X-LocSec-Token` header.
- `GET /api/ids` returns the same Suricata data the Threat Intelligence card shows.

---

## Default schedule

| Job | Cadence |
| --- | --- |
| AIDE, Lynis, debsecan, rkhunter, ports snapshot, CVE scan | Weekly, one per day (staggered) |
| ClamAV | Daily |
| Security updates | Every 12 hours (retried after 1 h if one fails) |
| Virus & rootkit definitions | Daily |
| Threat-intelligence feeds, then Suricata rules | Every 12 hours |
| Suricata alerts | Read every minute |
| Suricata interface check | Every 5 minutes |

Anything started manually runs immediately and ignores the schedule.

---

## Security model

- **Local only, HTTPS only.**
  - The dashboard and API bind to `127.0.0.1` over TLS 1.2+, with a machine-specific certificate. The bind address is pinned.
  - Requests with a foreign `Host` header are refused (anti DNS-rebinding).
  - Cross-site POSTs and oversized request bodies are rejected.
- **Token-authenticated.**
  - Every endpoint requires the per-install token.
  - Sessions use an HttpOnly, SameSite=Strict cookie that expires after 8 h idle or 3 days at most.
  - **Since -87:** more than 30 failed logins in a minute are answered with HTTP 429, logged, and opened as a *Dashboard token guessing* incident. Valid credentials keep working, so another local user cannot lock the administrator out.
- **Trusted configuration (since -87).**
  - `locsecd.conf` is used only if it is a regular, root-owned file that is not group- or world-writable, in a root-owned directory. Otherwise LocSec runs on its built-in defaults and logs an error with the fix.
  - `ids_eve_path` must resolve to a file under `/var/log/`, so the Logs page cannot be pointed at private files.
  - **Since -91:** `/etc/locsecd` is `root:locsec` 0750, and `locsecd.conf` and the dashboard key are `root:locsec` 0640. Both services read them, and only root can change them.
- **Two processes (since -91).** Everything that parses outside input runs without root, so a bug there no longer hands an attacker root.
  - **`locsecd.service`** runs as the user `locsec`, in the `adm` and `systemd-journal` groups so it can read the logs. It has no capabilities and cannot gain any. It can write only `/var/lib/locsecd` and `/var/log/locsecd`, has no access to `/home` or devices, and runs under a system-call filter without the privileged calls. `systemd-analyze security`: 1.6 (OK).
  - **`locsecd-broker.service`** runs as root with `CAP_DAC_READ_SEARCH`, `CAP_NET_ADMIN`, `CAP_NET_RAW` and `CAP_SETGID` only, no IP network access (`IPAddressDeny=any`), a read-only system and the earlier system-call filter. `systemd-analyze security`: 2.9 (OK).
  - They talk over `/run/locsecd/broker.sock`. Only root and `locsec` can open it, and the broker checks the caller's uid on every connection.
  - **Since -98:** every refusal is logged at WARN with the caller's pid and uid, as the kernel reports them, and with what was asked for: `refused file.open from pid 7980 uid 999: path: '/etc/shadow' is not a file LocSec reads`. Values a client chose are quoted, with control characters escaped and cut short, so they cannot forge log lines. The broker logs as `locsecd-broker` and the daemon as `locsecd`, so `journalctl -t locsecd-broker` shows only the broker.
  - The broker knows 62 operations ("verbs"); the daemon may request 52 of them (`locsecctl broker-verbs`). The other 10 are internal steps, such as rebuilding the AIDE baseline without the AIDE lock. Each verb checks its own arguments and builds its own command line. None accepts a command, an option, an arbitrary path or an arbitrary unit name.
  - The broker never opens a file in the daemon's directories. Captures, the AIDE report and Deep analysis input are handed to it as open files.
  - Root-only state (the quarantine vault, the install manifest, scratch files) is in `/var/lib/locsecd-broker`, which the daemon cannot read.
- **Capture analysis can't be used to attack the host (since -88).**
  - **Analyze** never runs Wireshark. LocSec's own pure-Python reader parses only the IP and TCP/UDP headers. It checks every length and is capped at 1 GB, 3 M packets or 60 s. It was fuzz-tested with 30,000 corrupted captures.
  - **Deep analysis** runs tshark as a throwaway `DynamicUser`. It has no network, a read-only system, LocSec's state, logs and keys hidden, a system-call filter and a 512 MB cap. It receives the capture on stdin and never opens files itself.
  - `systemd-analyze security` rates the tshark unit 2.5 (OK), down from 7.5 (EXPOSED).
  - `capture_deep_analysis=false` removes the Wireshark option entirely.
- **Privileged work is isolated.**
  - Tools that need more access run in separate, time-limited transient units. Only the broker starts them, and only the ones its verbs define.
  - If `systemd-run` is unavailable they fail closed rather than run as a plain root process.
  - If the process that asked for a job goes away, the broker stops that job.
  - Nothing from the dashboard or API is passed to a shell.
- **Guardrails.**
  - Allowlisted networks are never auto-blocked. IPv4-mapped IPv6 addresses are treated as the IPv4 address they stand for.
  - Quarantine refuses system paths unless forced, and never follows symlinks.
  - **Since -91:** account, sudo, PAM, SSH, boot and systemd files, the shells, the C library and LocSec itself are never quarantined, even with force.
  - Report reads and deletes refuse symlinks.
  - Dashboard control of services that are not LocSec-managed is off by default (`allow_manual_service_control`). Even when enabled, it can't stop `ssh`, networking, `dbus`, polkit, the display manager or LocSec itself.
- **Forged-log resistance.**
  - Port-scan detection counts only genuine kernel firewall log lines.
  - Failed logins count toward blocking only when journald attributes them to `sshd`, so a local program can't frame an address. Each SSH try counts once toward the threshold.
  - Suricata alerts block only addresses that are certainly the sender.
- **Bounded storage.** Reports, captures, incidents and blocks all have age and count limits. The Suricata log reader examines at most the newest 32 MB.
- **Outbound traffic** is limited to threat feeds, APT repositories, ClamAV signature updates and Suricata rule downloads.
- **Releases are not signed.** Verify a `.deb` by hash, or rebuild from source you trust.

---

## Supported systems

- Debian 12, 13 · LMDE 6, 7
- Ubuntu 24.04 LTS, 26.04 LTS, 26.10, and derivatives
- Linux Mint 22 (4.0.11-88 tested on 22.3)

Ubuntu 22.04 and Linux Mint 21 are not supported. They have no PyQt6, which this build requires.

**Architecture:** amd64 · **Requires:** Python ≥ 3.10

---

## Release status

**5.0-12 is the current release.** 5.0-1 was the first production release (the 4.0.11-103 code with a new version number); 5.0-2, 5.0-3, 5.0-5, 5.0-6, 5.0-7, 5.0-8, 5.0-9, 5.0-10, 5.0-11 and 5.0-12 follow it (see the changes below). The platform table below is from the 5.0-1 testing and has not been repeated for 5.0-5; only the Debian 13 / KDE Plasma / X11 machine above has run 5.0-3.

| Platform | Status |
| --- | --- |
| Debian 13 (GNOME, KDE Plasma) | Tested: about three weeks of continuous use, every scan and upgrade, reported by the tester |
| Linux Mint 22 (Cinnamon) | Tested, reported by the tester |
| Ubuntu 24.04, 26.04, 26.10 | Expected to work, not yet run. Run `locsec-vm-check.sh` with the attack test after installing |
| Debian 12, LMDE 6 and 7 | Expected to work, not yet run |

On a platform that has not been run yet, follow the checklist further down before relying on it.

The rest of this section is the testing record of the 4.0.11 builds, kept as it was.

### Testing record (4.0.11 builds)

4.0.11-103 was a **pre-release**. Do not put it on a machine you depend on until it has passed the checks below. It changes how LocSec runs (two services, a new system account, new file ownership), and the install scripts migrate existing machines, so a problem could leave a machine without its security tools until it is fixed.

**Tested so far, on one real machine (Debian 13 trixie, GNOME, kernel 6.12, systemd 257), with 4.0.11-91:**
- `locsec-vm-check.sh`: 34 checks passed. Both services were active as `locsec` and `root`, the daemon had no capabilities, every state path had the intended owner and mode, the broker socket was `root:locsec` 0660, `systemd-analyze security` gave 1.6 (daemon) and 2.9 (broker), the dashboard listened only on 127.0.0.1, and AppArmor logged no denials.
- `tests/attack_as_web.py`, run as `locsec`: all 43 attempts to exceed the broker's verbs were refused, and a legitimate request still worked.
- That run found one bug, fixed in -92: the start-up sweep of stale job units asked the broker to stop `locsecd-broker.service` itself. The broker refused, but it refused the whole list.

**Every scan, on that machine (4.0.11-92):**
- Update system installed 6 security updates (Wireshark libraries) as root through the broker. The CVE scan afterwards found 0 fixable vulnerabilities.
- AIDE, Lynis (hardening index 72), debsecan, rkhunter, ClamAV (20,615 files in /home, nothing found), the ports/firewall snapshot and the CVE scan all ran and wrote reports.
- They found six problems in LocSec, fixed in -93:
  - AIDE explained none of its changes, because the unprivileged half could not read the snapshot time.
  - Suricata alerts for this machine's own connections were labelled "passing through", which also meant they could never trigger a block.
  - The ports scan could not name any program.
  - rkhunter and Lynis flagged LocSec's own changes (locsec in adm and systemd-journal, rsyslogd, Suricata's promiscuous interface).
  - The definitions update wrote no report.

**4.0.11-97 on that machine (4 October 2026, GNOME on Wayland):**
- `locsec-vm-check.sh`: 35 passed, 0 failed, 0 warnings. The hardening scores were again 1.6 and 2.9, and there were no error-level journal lines.
- `tests/attack_as_web.py`, run as `locsec`: all attempts refused. The broker logged each refusal at WARN.
- The panel icon shows on GNOME (Wayland).
- Reading those refusal lines showed four logging gaps, fixed in -98: some refusals did not name the caller, `file.open` refusals did not say which path, both services logged as `locsecd.py`, and one message was hard to read.

**4.0.11-98 on that machine (4 October 2026):**
- `locsec-vm-check.sh`: 40 passed, 0 failed, 0 warnings, including the new checks: both services log under their own names, every refusal from the attack test names the caller's pid and uid, and the `file.open` refusal names the path.
- rkhunter from the dashboard: 0 findings need review, 4 informational, each with its reason (rsyslogd, lwp-request, LTTng files in /dev/shm, /etc/.updated). The three rkhunter incidents still open from 12:01 were raised by -92, before -93 classified them.
- Block and unblock of 203.0.113.5 from Firewall & Blocks worked and each opened an incident.
- It found two bugs, fixed in -99:
  - **Send test notification** said "No local graphical session is active" while the GNOME session was open, so no notification had been shown since -91. The daemon looked for the session bus in `/run/user`, which `ProtectHome=true` hides from it.
  - The "Computer blocked" incident offered **Fix it** after the address was unblocked, which would have blocked it again.

**4.0.11-99 to -101 on that machine (4 and 5 October 2026):**
- Quarantine and restore of the EICAR test file: ClamAV found it, the file left the home folder, and Restore brought it back with the same SHA-256.
- A purge and a fresh install of -101 worked, and the rest of the walkthrough was reported working.
- That reinstall stopped at a dpkg/ucf prompt about a ClamAV config file ("install the package maintainer's version?"), and clamav-daemon stayed stopped afterwards. Both fixed in -102 (see the -102 changes).

**Tested so far, in a container without systemd:**
- The code compiles on Python 3.10, 3.11, 3.12 and 3.13, and the broker rule tests pass (each one added in -92 to -103 fails on the code before it, except one -102 test noted in its changelog). -101 had 197; -102's tarball carries the -99 suite plus the 7 -102 tests (190), because -101's test folder was not available when -102 was made.
- **-102:** the clamd.conf clean-up was run on five sample files: LocSec's lines are removed only when that gives back the file ucf recorded, and a file the administrator also edited is left alone.
- **-98:** the real broker ran here and `attack_as_web.py` was run against it as `locsec`. Every refusal named the client's pid and uid, and a path with a newline and terminal codes in it was logged as one escaped line.
- The static check finds no root operation outside the broker.
- The same 35 scenarios run the same commands as in 4.0.11-90, except for two intended changes.
- The real install scripts ran as a fresh install and as an upgrade from a 4.0.11-90 layout. A fresh install leaves `locsecd.conf` as shipped.
- With both services running against stand-in tools, the dashboard API, packet capture, quarantine and restore, and the root-only logs all worked.

**Not tested yet:**
- The -102 ClamAV changes on a real machine: an upgrade from -101 (no prompt, and no LocSec lines left in `clamd.conf`), and a fresh install where clamd starts within about 5 minutes of the first signature download (confirmed on a fresh -102 install: the log shows "ClamAV signatures have arrived" and clamav-daemon was active; the upgrade from -101 is still untested).
- A week of normal use, so every scheduled job runs on its own.
- An upgrade from 4.0.11-88.
- The AppArmor profiles from -100 (`/usr/share/doc/locsecd/examples`), loaded on a real kernel.
- KDE Plasma, X11, Ubuntu 24.04, 26.04 and 26.10, Debian 12, LMDE and Linux Mint. Everything so far is from one Debian 13 GNOME/Wayland machine.

**Checklist for a platform not yet run (originally the release checklist for each supported release):**
1. A fresh install with `sudo apt install ./locsecd_5.0-12_amd64.deb`, and an upgrade from 4.0.11-88 and from -101. Neither may stop at a prompt about `/etc/clamav/clamd.conf`, and `systemctl is-active clamav-daemon` says `active` within a few minutes of the first signature download.
2. `locsecctl status`: both services are active. `ps -o user,cmd -C python3` shows one process as `locsec` and one as `root`.
3. The window opens from the menu and from `locsecctl gui`, the token prompt appears, the tray icon shows and turns amber when you stop `locsecd`, and **Send test notification** (Incidents) shows a popup.
4. From the dashboard:
   - each scan once (AIDE, Lynis, rkhunter, ClamAV, CVE)
   - Update system
   - a block and an unblock
   - a capture with Analyze and Deep analysis
   - a quarantine and a restore of a test file
   - every source on the Logs page
5. `journalctl -u locsecd -u locsecd-broker | grep -iE "refused|error|traceback"` shows nothing unexpected. Do this after the dashboard walkthrough and before the attack test, which fills the log with refusals on purpose. Each refusal names the caller's pid and uid.
6. Copy `tests/attack_as_web.py` from the source tarball to `/tmp` (the `locsec` user cannot read your home folder), then run `sudo setpriv --reuid=locsec --regid=locsec --init-groups python3 /tmp/attack_as_web.py`. It must end with "all attempts refused".
7. A reboot, and a week of normal use so every scheduled job runs once.

**Open items in 5.0-6:**
- **AppArmor is still in complain mode** (5.0-7 fixed the profile for what it logged on a real machine, below, but nobody has repeated the walkthrough against the new profile). The profiles (`locsecd-web`, `locsecd-broker`, in `/etc/apparmor.d/locsecd`) log what enforce mode would block and do not block it. Whether enforce is safe depends on what they log on the machine that runs them, so it stays a deliberate step: `locsec-vm-check.sh` (5.0-6) has an "AppArmor enforce readiness" report that lists the `ALLOWED` lines still logged this boot, or says there are none and gives the one command that switches to enforce and the one that undoes it. Nobody has run a full walkthrough against it yet.
- **ClamAV runs as the `clamav` user (5.0-6) instead of uid 0** with only `CAP_DAC_READ_SEARCH`, so it still reads every file but cannot write files root owns, and `--fdpass` still works because the unit has no mount-namespace option. Tested with stubbed commands; the new probe in `locsec-vm-check.sh` checks it on a real machine (scan a root-only file with `--fdpass`; fail to write a root-owned file).
- `apt-get install/upgrade` jobs still run with every capability, because dpkg is root by definition. Every other job unit has its own capability profile since 5.0-2.
- **The four root-only test files ran in a sandbox, not in a throwaway VM:** `test_broker_rules.py` (270 passed, 0 failed), `test_feed_carry.py` (PASS), `test_ids_reloading.py` (ok) and `difftest.py` (35 scenarios, identical commands to 5.0-5). The sandbox is a user namespace with a private `/var/lib`, `/var/log`, `/run`, `/srv` and a copy of `/etc`, fake root and stubbed commands, so it does not replace a run on a real machine.
- **rkhunter's baseline needs refreshing after intentional changes.** rkhunter keeps its own snapshot of users, groups and file properties and reports every difference until it is told to accept it: for example adding yourself to `sudo` (a privileged group, which LocSec deliberately does not wave through) and the package updates since the snapshot was built. When the changes were intended, run `sudo rkhunter --propupd` once. It makes the current state the new baseline, so run it only when nothing else on the machine has changed unexpectedly.
- **Releases are signed (5.0-12 onward), but there has been no independent security review.** The 5.0-12 files carry detached signatures (`.asc`) made with the release key below; the signature proves the files came from the holder of that key, not that the code has been reviewed. Older releases are unsigned.

---

## Install

```bash
sudo apt install -y ./locsecd_5.0-12_amd64.deb
```

Use `apt install` from a terminal, not `dpkg -i` or GDebi, so dependencies resolve automatically.
- The install finishes straight away.
- ClamAV downloads its first signatures, and Suricata sets itself up, in the background afterwards.
- An existing 4.0.11 install upgrades in place to 5.0-12 with the same command.

**Hard dependencies:**
- **Security tools:** `ufw`, `nftables`, `aide`, `lynis`, `debsecan`, `rkhunter`, `clamav` (+ daemon and freshclam), `suricata`
- **Network and system utilities:** `tshark`, `tcpdump`, `iproute2`, `procps`, `lsof`, `net-tools`
- **Packaging and privilege:** `apt`, `unattended-upgrades`, `ca-certificates`, `pkexec`, `polkitd`, `sudo`, `openssl`, `passwd` (creates the `locsec` account)
- **Desktop stack:** `python3-pyqt6`, `python3-pyqt6.qtwebengine`, `rsyslog`, `xdg-utils`, `libnotify-bin`

`pkexec` and `polkitd` can also be satisfied by `policykit-1` on older releases.

**Recommended:** `suricata-update`, which downloads the Suricata rules.

**Suggested:**
- a polkit agent, e.g. `mate-polkit` or `polkit-gnome`. Without one, the window asks for your sudo password instead.
- `gnome-shell-extension-appindicator`
- a notification daemon: `xfce4-notifyd`, `mako-notifier` or `dunst`

### Extra packages for the check script, AppArmor and signing

The `.deb` installs everything LocSec itself needs (the dependency list above). From 5.0-11 it also **recommends** `apparmor-utils` and `libcap2-bin`, which apt installs with it by default (they are not hard dependencies: LocSec runs without them). On an earlier install, or if you switched recommends off, install them yourself, or run `sudo bash locsec-vm-check.sh --install-missing`, which installs whichever of `apparmor-utils`, `libcap2-bin` and `curl` is missing. The post-install check, switching AppArmor to enforce mode and signing a release use these packages:

```bash
sudo apt install apparmor-utils libcap2-bin
```

| Package | Gives you | What happens without it |
| --- | --- | --- |
| `apparmor-utils` | `aa-enforce`, `aa-complain`, `aa-status`, `aa-exec` | `sudo aa-enforce /etc/apparmor.d/locsecd` (and the undo, `aa-complain`) is "command not found". `locsec-vm-check.sh` still runs, but its capture check cannot open the capture file under the `locsecd-web` profile, so it tests the capture without AppArmor and says so |
| `libcap2-bin` | `capsh` | `locsec-vm-check.sh` cannot decode the broker's capability list and warns instead of passing the "no `CAP_SETGID`" check |
| `curl` | the HTTPS check of the dashboard | `locsec-vm-check.sh` cannot reach `https://127.0.0.1:8765/` and fails that item (usually already installed) |
| `util-linux` | `setpriv`, used to run `attack_as_web.py` as the `locsec` user | the attack test cannot run (always installed on Debian, Ubuntu and Mint) |
| `gnupg` | `gpg`, used by `release/sign-release.sh` | releases cannot be signed (see "Signing a release") |

The check script, the attack test and the signing script are not part of the package: `locsec-vm-check.sh` is published beside it, and `attack_as_web.py` and `sign-release.sh` are in the source tarball. A polkit agent and a notification daemon are in the Suggested list above. LiveWorld RPG needs `python3-pygame` and `python3-numpy` (apt installs them with the `.deb`) and recommends `x11-utils`.

### What the installer does

- Creates the system account `locsec` and adds it to the `adm` and `systemd-journal` groups.
- Creates `/var/lib/locsecd` (owned by `locsec`, 0700), `/var/lib/locsecd-broker` (root, 0700) and `/var/log/locsecd` (`locsec:adm`). Sets `/etc/locsecd` to `root:locsec` 0750 and `locsecd.conf` to `root:locsec` 0640.
- **On an upgrade from 4.0.11-90 or older:** gives `/var/lib/locsecd` to `locsec` and moves the root-only files out of it into `/var/lib/locsecd-broker`: the quarantine vault, the install manifest and Suricata's setup state. It also moves the dashboard's policy file from `/etc/locsecd` to `/var/lib/locsecd`. Symbolic links are never followed.
- Generates the dashboard TLS certificate. If that fails, install `openssl`, then run `sudo locsecctl tls-renew && sudo systemctl restart locsecd`.
- Migrates the config on upgrade: new keys are added, and values you changed are kept.
- Leaves `/etc/clamav/clamd.conf` to the ClamAV package (since -102). It removes `ExcludePath` lines an older LocSec appended, but only when that gives back exactly the file the package installed. LocSec's scans use their own exclusion list.
- Enables ClamAV and starts it in the background. The first `freshclam` download takes a few minutes, and LocSec starts clamd once it has finished.
- Runs `locsec-suricata-setup` in the background. It:
  - points Suricata at the interface of the default route
  - downloads rules with `suricata-update`
  - makes `suricata.yaml` load them, and starts Suricata

  Every edit is checked with `suricata -T` first, and the original config is kept as `suricata.yaml.locsec-orig`.
- Disables Debian's daily AIDE timer (LocSec runs AIDE weekly itself) and installs a lock-sharing drop-in in case you re-enable it.
- Applies kernel and network hardening, and blocks four unused protocol modules.
- Enables and starts `locsecd.service`, which starts `locsecd-broker.service` with it.

It **never** force-enables UFW and never touches fail2ban.

### After install — first steps

1. Open the dashboard: `locsecctl gui`
2. Check the Overview page for anything missing.
3. Create the AIDE baseline: **Scans → Build AIDE database**, or `sudo locsecctl aide-init`.
4. Check the Suricata card on **Threat Intelligence**. It should say *watching the network* and show a rule count. If it doesn't, run `sudo locsecctl suricata-setup`.

---

## Suricata: what it does and why the alert list is usually empty

Suricata is a network intrusion detection system (IDS). It inspects the packets on the machine's network interface and compares them with tens of thousands of signatures for known attacks, exploit attempts, malware command-and-control traffic and scanning. The threat lists block addresses already known to be malicious. Suricata recognises the *behaviour*, including outbound traffic from an infected program on this computer, which a firewall and an address list cannot see.

An empty alert list is normal. Suricata logs every connection, DNS lookup and TLS handshake to `eve.json`, and writes an alert only when traffic matches an attack signature. That is rare on a home or office network. When the list is empty, the Threat Intelligence card and the **Suricata alerts** log say exactly why:
- Suricata is not installed.
- Suricata is not running.
- Suricata hasn't created `eve.json` yet.
- The file holds only non-alert records, with counts by type.

If the **Suricata engine** log shows *failed to find interface* or *0 rules loaded*, run `sudo locsecctl suricata-setup`.

To silence a rule that misfires on your network, add its rule number (sid) to `ids_ignore_sids`.

---

## Which AIDE button do I use?

LocSec never changes the AIDE database by itself. The weekly check only compares the system against `aide.db`, and the baseline changes only when you press a button.

| Situation | What to do |
| --- | --- |
| New machine, or the check says AIDE is not initialized | Press **Build AIDE database** once |
| The weekly check is clean | Nothing |
| Differences you recognise (package updates, a config change you made) | Review the report, then press **Build AIDE database**. Otherwise the same differences repeat weekly |
| Differences you do **not** recognise (under `/etc`, `/usr/bin`, `/boot`, `~/.ssh`) | Press neither. Investigate first |
| You just pressed Build AIDE database and it finished | Nothing. It is already the active baseline |
| **Accept pending AIDE baseline** is visible | A pending `aide.db.new` that differs from `aide.db` exists. Review it, and accept only if you want it to become the baseline |

**Build AIDE database:**
- Hashes the system as it is now and treats that as normal. The old baseline is not backed up.
- A finished build counts as an AIDE run (shown under *Last ran* in the Schedule table) and delays the next weekly check by a full interval.
- The duplicate `aide.db.new` that `aideinit --force` leaves behind is removed when it is identical.

**Accept pending:**
- Keeps the previous database as `aide.db.locsec-backup`, so it can be rolled back.
- The button is hidden unless a *differing* pending database exists. `locsecctl aide-accept` always works.

---

## Key files

| Path | Purpose |
| --- | --- |
| `/etc/locsecd/locsecd.conf` | Main configuration (JSON, `root:locsec` 0640). Edit, then `sudo systemctl restart locsecd`. Must stay root-owned and not group/world-writable |
| `/var/lib/locsecd/runtime-policy.json` | Response toggles saved from the Incidents page (in `/etc/locsecd` before -91) |
| `/etc/locsecd/dashboard.key` | Dashboard TLS private key (`root:locsec` 0640) |
| `/etc/ssl/locsecd/dashboard.crt` | Dashboard TLS certificate (the window pins it) |
| `/var/lib/locsecd/` | State, owned by `locsec`: blocks, reports, captures, incidents, sessions, API token |
| `/var/lib/locsecd-broker/` | Root only: quarantine vault, install manifest, Suricata setup state, scratch files |
| `/var/log/locsecd/locsecd.log` | Daemon log (`locsec:adm`, rotated daily, 14 kept). The broker logs to the journal: `journalctl -u locsecd-broker`, or `journalctl -t locsecd-broker` since -98 |
| `/run/locsecd/broker.sock` | The broker's socket (`root:locsec` 0660) |
| `/lib/systemd/system/locsecd.service`, `locsecd-broker.service` | The unprivileged daemon and the root broker |
| `/var/log/suricata/eve.json`, `suricata.log` | Suricata alerts and engine log (owned by the suricata package) |
| `/usr/lib/locsecd/locsecd.py` | Daemon, embedded dashboard and broker (`--broker`) |
| `/usr/lib/locsecd/locsec-gui.py` | Qt6 desktop window (`/usr/bin/locsec-gui`) |
| `/usr/lib/locsecd/locsec-suricata-setup` | Root-only Suricata configuration helper |
| `/usr/bin/locsecctl` | Command-line control script |

---

## Common configuration keys

| Key | Default | Meaning |
| --- | --- | --- |
| `auto_block` | `true` | Master switch for automatic blocking |
| `auth_threshold` / `auth_window` | `5` / `900` | Failed logins in the window that trigger a block |
| `scan_detect` / `scan_ports` | `true` / `8` | Port-scan blocking |
| `fallback_firewall` | `true` | Own default-deny firewall while UFW is inactive |
| `fallback_allow_tcp` | `[]` | Ports the fallback firewall leaves open, e.g. `[22]` |
| `scan_interval` | `604800` | Weekly scan cadence (seconds) |
| `clamav_scan_paths` | `["/home"]` | What ClamAV scans |
| `auto_update` / `update_security_only` | `true` / `true` | Automatic security-only updates |
| `block_ttl_days` | `30` | Block lifetime |
| `scan_block_hours` / `scan_block_max_per_hour` | `24` / `10` | Port-scan block lifetime and hourly cap |
| `report_retention_days` | `7` | Report lifetime |
| `allow_manual_service_control` | `false` | Allow the Services page to control units LocSec doesn't manage |
| `inhibit_sleep_during_jobs` / `inhibit_lid_switch` | `true` / `true` | Hold off suspend and ignore lid close while a job runs |
| `ids_enabled` / `ids_response_block` | `true` / `true` | Read Suricata's alerts, and let them block |
| `ids_block_severity` / `ids_incident_severity` | `1` / `2` | Highest severity number that blocks (0 = record only), and that becomes an incident |
| `ids_block_hours` / `ids_block_max_per_hour` | `24` / `10` | Intrusion-signature block lifetime and hourly cap |
| `ids_ignore_sids` | `[]` | Suricata rule numbers to ignore |
| `ids_rules_update` | `true` | Run `suricata-update` after each threat-feed update |
| `ids_auto_configure` | `true` | Keep Suricata's capture interface on the default route |
| `ids_eve_path` | `/var/log/suricata/eve.json` | Where Suricata writes alerts (must be under `/var/log/`) |
| `capture_deep_analysis` | `true` | Offer the sandboxed Wireshark **Deep analysis** for saved captures |

See the Installation Guide (Section 6) for the full list.

> **Remote install tip:** if you manage this host over SSH while UFW is inactive, set `fallback_allow_tcp` to include your SSH port (e.g. `[22]`). Otherwise the fallback firewall cuts you off.

---

## Uninstall

```bash
sudo apt remove locsecd        # keeps config and state
sudo apt purge locsecd         # removes config and state, including the quarantine vault
locsecctl uninstall --dry-run  # preview a staged removal, incl. tools LocSec brought in
```

- Removing LocSec turns Debian's daily AIDE check back on.
- Purge keeps the `locsec` system account, as is usual for system accounts. Remove it by hand if nothing else uses it: `sudo deluser --system locsec`.
- The staged uninstaller treats `suricata` and `suricata-update` as security tools LocSec brought in (stage 2).
- If you still have the older **aisentryd** package, remove it *before* installing LocSec. Automatic migration was dropped in 4.0.11-67.

---

## Documentation

`LocSec-Installation-Guide-5_0-12.docx` has the full details:
- configuration reference
- scan behaviour
- Suricata
- security model
- troubleshooting
- AIDE coordination
- release history through 5.0-12 (the 5.0-6 and 5.0-7 sections: the post-install check, window behaviour, ClamAV as the `clamav` user, rkhunter package updates, the AppArmor helper change, release signing, notifications off by default)
- building from source

Per-release notes ship with the package in `/usr/share/doc/locsecd/`. The manual pages are `locsecctl(1)` and `locsec-gui(1)`.

### Changes since 4.0.11-73

| Release | Change |
| --- | --- |
| -74 | A systemd-logind sleep inhibitor is held while a maintenance job runs, so idle suspend and lid close don't freeze it. New keys `inhibit_sleep_during_jobs` and `inhibit_lid_switch` |
| -75 | Dead-code cleanup, no behaviour change. The unused `GET /api/blocks` endpoint is removed |
| -76 | System updates run reliably. The last update time is saved across restarts, a failed update is retried after an hour, and the Scans page shows when updates last ran |
| -77 | The installer no longer waits on ClamAV, which runs in the background instead. GDebi is no longer recommended (APT only), and interrupted-install recovery steps are documented |
| -78 | Supported releases: Ubuntu 24.04 LTS, 26.04 LTS and 26.10 added. Ubuntu 22.04 and Mint 21 dropped (no PyQt6) |
| -79 | See the -79 details below this table |
| -80 | Dashboard control of non-LocSec services is off by default (`allow_manual_service_control` opt-in) |
| -81 | Report reads and deletes are hardened against symlink and race attacks. `__pycache__` is no longer shipped |
| -82 | Privileged transient jobs fail closed when `systemd-run` is unavailable |
| -83 | Suricata intrusion signatures: `eve.json` alerts become incidents and severity 1 can block. New `ids_*` keys and an Overview card |
| -84 | `suricata` is a dependency (installed with LocSec). `suricata-update` is recommended |
| -85 | Suricata sets itself up at install (`locsec-suricata-setup`). New `locsecctl suricata-setup` / `suricata-status` and the `ids_auto_configure` key |
| -86 | Professional wording on every explanation page (firewall, ports, connection attempts, blocked computers). Severity labels are now OK / Info / Warning / Problem |
| -87 | See the -87 details below this table |
| -88 | Capture analysis hardened. **Analyze** uses a built-in, memory-safe header reader. Wireshark **Deep analysis** runs sandboxed as a throwaway unprivileged user with no network (exposure 7.5 → 2.5). New key `capture_deep_analysis`. Deep analysis no longer undercounts conversations |
| -89 | Unit sandbox tightened: `ProtectSystem=strict`, `PrivateDevices=true`, redundant `AmbientCapabilities=` removed (exposure 3.5 → 3.0) |
| -90 | Privilege broker: every root operation goes through 41 named, argument-checked verbs. A runtime guard refuses privileged commands outside a verb. New `locsecctl broker-verbs` |
| -91 | **Two processes.** The daemon runs as the unprivileged user `locsec`. A root broker service runs the verbs (now 62) over a Unix socket. New `locsecd-broker.service`, `/var/lib/locsecd-broker`, quarantine "never" list. See the -91 details below this table |
| -92 | **Fix.** The start-up sweep of stale job units no longer asks the broker to stop itself. |
| -93 | **Fixes from the first real-hardware scans.** AIDE explanations, Suricata direction and blocking, program names in the ports scan, LocSec's own rkhunter and Lynis warnings, and a report for definitions updates. |
| -94 | **clamd AppArmor rule.** The installer adds the `/proc/PID/cgroup` read rule to clamd's local AppArmor profile and reloads it; purge removes it. |
| -95 | **Follow-up fixes.** Lynis promiscuous-interface match, definitions-report wording, Suricata rules at most every 6 h. |
| -96 | **Scans page and AIDE.** Full scan removed; scan buttons renamed and moved to the top row; AIDE explains setup-made files of changed packages. |
| -97 | **AIDE and reports.** Account files explained from the system log, rebuilt and LocSec files, folders; freshclam wording; old Suricata errors; clearer restore message. |
| -99 | **Notifications and Fix it.** Desktop notifications are shown again (broken since -91); a notification counts as shown only when the desktop accepted it; no Fix it on a block that was lifted. |
| -100 | **AppArmor profiles.** The example profile is rewritten as two (`locsecd-web`, `locsecd-broker`), named by the units with `AppArmorProfile=-…` so nothing changes until they are loaded. Not installed by the package. |
| -101 | **Bug sweep.** `job.apt_upgrade` refuses names ending in `-` (they meant "remove" to apt); the pre-91 migration runs only once; more quarantine protections; the Suricata setup lock moved out of `/run/lock`; 13 other fixes and dead code removed. |
| -103 | **AppArmor noise.** The units no longer name the unloaded AppArmor profiles, which logged two denied `change_onexec` lines at every start. |
| -102 | **ClamAV.** LocSec no longer edits `clamd.conf` (the "package maintainer's version" prompt) and cleans up what older builds added; clamd starts once the first signatures arrive; scans exclude the quarantine vault's real location. |
| -98 | **Broker refusal log.** Every refusal names the caller's pid and uid; `file.open` names the path; the journal names the services `locsecd-broker` and `locsecd`; clearer wording for a file descriptor sent for a plain argument. |

**-79 fixes:**
- A dashboard port that is already in use no longer crashes the daemon.
- IPv4-mapped IPv6 addresses can't bypass the allowlist.
- The watchdog now covers all threads.
- Packet-capture input is validated.
- The man pages are added.

**-87 changes:**
- A Suricata card on Threat Intelligence, and `GET /api/ids`.
- **Suricata alerts** and **Suricata engine** log sources.
- Config ownership and permission checks, and `ids_eve_path` limited to `/var/log/`.
- Failed-login monitoring.
- `SystemCallFilter`, `MemoryDenyWriteExecute` and `RemoveIPC` in the unit.
- State and config directories set to 0700.
- Start-up log messages are no longer lost.

**5.0-12 changes** (fixes the broken dashboard of 5.0-10 and 5.0-11):
- **The dashboard page is sent again.** The `#` comment is on its own line above the statement; the page, its headers and the `Permissions-Policy` behaviour are as intended (the desktop window gets camera, microphone and geolocation only, any other browser the full header).
- **New test `tests/test_http_5012.py`:** starts the real request handler on a local port and loads the page the way the desktop window does (login code, redirect, session cookie, page): 200, HTML, the whole dashboard, a matching `Content-Length`, the security headers, a login code that cannot be used twice. It also scans for a `#` comment in the middle of a statement chain. Verified: 4 checks fail on the 5.0-11 code, all pass on the 5.0-12 source and on the unpacked 5.0-12 `.deb`.
- **`locsec-vm-check.sh`:** a new check logs in the way the desktop window does (the root-only API token buys a single-use login code, the code buys a session cookie, the cookie loads the page) and fails if the page is not sent. Tested against a fake `curl` for a good page, the 22-byte error page, a 404 and a missing login code.
- **Tests:** everything else passes in the sandbox (270 rule tests, 0 failed).

**5.0-11 changes** (from switching the AppArmor profiles to enforce mode on a real machine; this release had the broken dashboard):
- **Recommended packages.** `DEBIAN/control` now has `Recommends: suricata-update, apparmor-utils, libcap2-bin`. They are recommends, not dependencies: apt installs them by default, LocSec runs without them, and `--no-install-recommends` skips them. `apparmor-utils` provides `aa-enforce`, `aa-complain`, `aa-status` and `aa-exec`; `libcap2-bin` provides `capsh`. `README.Debian`, the AppArmor profile's header and the package README now say where `aa-enforce` comes from.
- **`locsec-vm-check.sh`:** an opt-in `--install-missing` flag runs `apt-get install -y` for whichever of `apparmor-utils`, `libcap2-bin` and `curl` is missing and says what it installs (without the flag the script still changes nothing); a new "Optional tools" section lists a missing tool with the exact `apt` command. It also accepts the profiles in complain **or** enforce mode (5.0-10 build of the script).
- **Tests:** new `tests/test_5011.py` (8 checks); everything else passes in the sandbox (270 rule tests, 0 failed).

**5.0-10 changes** (from the Logs page of the 5.0-9 machine):
- **No Permissions-Policy warnings.** The dashboard's `Permissions-Policy` header listed `payment` and `usb`, which the desktop window's embedded browser does not know, so it logged "Unrecognized feature" for each at every load. The desktop window now gets camera, microphone and geolocation only; any other browser still gets the full header.
- **`tcpdump` denials on the Logs page:** the two `/dev/null` denials from Debian's own `tcpdump` profile (`file_inherit`, `apparmor/.null`, "disconnected path") are an information row that says they are cosmetic; any other AppArmor denial is still a warning.
- **AppArmor:** the broker profile states `deny capability sys_ptrace`. `pgrep` asks for it as an optional extra and the unit never had it, but the profile logged it as an `ALLOWED` line and the enforce-readiness report listed it. No change in behaviour.
- **`locsec-vm-check.sh`:** the ClamAV write probe exits 0 whatever happens (it checks the file is unchanged); before, the unit failed on purpose and LocSec's own Logs page showed it as a Problem.
- **Tests:** new `tests/test_5010.py` (6 checks); everything else passes in the sandbox (270 rule tests, 0 failed).

**5.0-9 changes** (from the real-machine check of 5.0-8 and a request about the scan schedule):
- **Weekly scans are planned on different days.** AIDE, Lynis, Debsecan, rkhunter, Ports/firewall and the CVE scan each run once a week, when the computer is idle, and the scheduler already started at most one per calendar day (most overdue first). But the Schedule table on the Scans page showed each check's own due date, so six checks that had all been run by hand on one afternoon all showed "Next: Fri, Oct 16" as if they would all run that day. The Next column now shows the day each check will really start, with the per-day limit applied: after six manual runs on one afternoon they are planned on six different days. `scan_jobs_per_day` (default 1) is now limited to 1 or 2 (it accepted 1 to 10). ClamAV keeps its own daily schedule.
- **AppArmor profile:** the last line the profiles logged after 5.0-8 was the broker opening the `/home/` directory (its `/home/**` rule does not match the directory itself). Added `/home/` and `/root/`. Still complain mode.
- **Tests:** new `tests/test_sched_509.py` (12 checks); `tests/test_507.py` 35. Everything else passes in the sandbox (270 rule tests, 0 failed).

**5.0-8 changes** (from the real-machine check of 5.0-7):
- **AppArmor profile:** after the upgrade `locsecd-web` logged one `ALLOWED` line, the exec of `nmcli` (the router-address lookup); added. The same machine had logged, before the upgrade, that `locsecd-web` also runs `nice`, `ionice`, `debsecan` and the `dpkg` that `debsecan` calls, and reads `/usr/share/dpkg` and `/etc/dpkg`; those were added too, but the scans that use them have not run since the upgrade, so these rules are not yet confirmed by a log. Still complain mode.
- **`locsec-vm-check.sh`:** both ALLOWED checks, and the enforce-readiness report, count only the lines since the broker last started (they counted the whole boot, which mixed in a previous version's lines and showed 498 lines instead of the 2 that were real).
- **Tests:** `tests/test_507.py` now has 34 checks (the new rules included); everything else unchanged and passing in the sandbox.

**5.0-7 changes** (from the first real-machine run of 5.0-6 and a feature request):
- **The dashboard window stays open** (confirmed on the tested machine: KDE Plasma, Wayland). On a Wayland desktop with a taskbar the GUI was forced through XWayland and told the window manager to keep the window off the taskbar and the pager, so clicking another window put LocSec behind it with no taskbar button to bring it back (it looked minimised to the tray). That code is gone: the window is an ordinary window with its own taskbar button, runs natively on Wayland, and stays open until you close or minimise it. Closing still hides it to the panel icon.
- **Notifications are off until you enable them** (the Enable and Disable buttons, the unchecked boxes and the OFF / ON line were confirmed on screen on the tested machine). All seven desktop notification kinds default to off (five were on). The Incidents page has **Enable notifications** and **Disable notifications** buttons (every kind at once, saved immediately) beside Save and Send test notification, plus a line saying whether they are on or off. The panel icon's own pop-ups (service stopped or running again) are off until enabled from the icon's menu (Enable notifications / Disable notifications). A choice you saved earlier is kept.
- **AppArmor profile fixed from real logs.** `locsecd-web` ran `systemctl`, `journalctl`, `loginctl`, `dpkg-query` and `ss` through a child profile, which the kernel refuses under `NoNewPrivileges` (`info="no new privs"`), so they could not have run in enforce mode. They now inherit the web profile and the child profile is gone. Added the rules the 83 `ALLOWED` lines asked for: the journal directories themselves (`/**` does not match the directory), `pgrep`, `lsblk`, `/sys/block`, `/sys/devices`, `/var/lib/suricata`, the systemd and D-Bus sockets, and for the broker `/proc/` and `ptrace read peer=unconfined`. Still complain mode.
- **rkhunter:** "The file properties have changed" for a file owned by a package that `dpkg --verify` reports unmodified is informational (17 such warnings were listed as needing review after normal updates). A file that does not verify, a block naming several files, and new members of groups such as `sudo` still need review. `dpkg --verify` runs once per package per scan.
- **`locsec-vm-check.sh`:** Debian's own `tcpdump` profile logs two cosmetic `/dev/null` denials per capture; they are now reported as information and a real `tcpdump` denial still warns.
- **Tests:** new `tests/test_507.py` (27 passed). All other suites pass in the sandbox: `check_broker.py`, `test_broker_rules.py` 270, `test_fd_transit.py` 11, `test_suricata_purge.py` 38, `test_capture_pipe.py` 12, `test_reports_505.py` 16, `test_netinfo_505.py` 10, `test_auth_505.py` 6, `test_aide_505.py` 33 (the alternatives-database cases depend on the machine), `test_feed_carry.py`, `test_ids_reloading.py`, `test_clamav_506.py` 8.

**5.0-6 changes:**
- **ClamAV scans cannot write root's files.** The batch unit now runs as the `clamav` user with `CAP_DAC_READ_SEARCH` as its only ambient capability, instead of uid 0. Read-only file-system options would break `clamdscan --fdpass` (5.0-3), so this removes the write access another way: the unit is no longer the owner of root's files. Without a `clamav` account the unit starts as before. If a scan as `clamav` failed systemically, the existing fallback (`--stream`, then `clamscan`) still applies.
- **AppArmor enforce readiness** report in `locsec-vm-check.sh` (read-only; changes nothing).
- **Release signing:** `release/sign-release.sh` (not part of the package).
- **`locsec-vm-check.sh` (5.0-6 checks):** a unit started as the broker starts a ClamAV batch must scan a root-only file with `--fdpass` and must not be able to write a file root owns; no `fdpass failed` line since the broker started; the readiness report.
- **Tests:** new `tests/test_clamav_506.py` (8 passed). All no-root tests pass (`check_broker.py`, `test_fd_transit.py` 11, `test_suricata_purge.py` 38, `test_capture_pipe.py` 12, `test_reports_505.py` 16, `test_netinfo_505.py` 10, `test_auth_505.py` 6, `test_aide_505.py` 36). The four root-only files ran in a sandbox (see the open items).

**5.0-5 changes** (found running 5.0-3 on a real machine on 9 October 2026, plus a review pass; there was no 5.0-4):
- **Captures save data again** (broken since 5.0-2). Debian's enforcing `tcpdump` AppArmor profile refused the capture file handed to the capture unit and the kernel swapped it for a null device, so every capture was empty and deleted 15 seconds after it ended. tcpdump now writes into a pipe and the broker copies it into the capture file. A capture that records nothing is logged with the reason.
- **The daemon no longer runs `ip`** (the system-call filter made it fail with rc=1 at every start). It reads addresses and default routes from `/proc/net`, so the Suricata interface follow-up and the router address for "never auto-block infrastructure" work.
- **Reports:** the CVE scan's "APT security candidates" has its own status (warning for security updates, information for other updates, OK when none), security and other updates are listed separately with their origin, and its advice follows `update_security_only` and `auto_update`. freshclam's "OUTDATED" message is explained. One wrong local password is no longer logged twice.
- **AIDE explanations** cover LocSec's own AppArmor drop-ins, `update-alternatives` links, files a package's setup script writes and CUPS's `printers.conf.O`. Home-folder entries are called start-up files only when they are. The "Do not quarantine it" text no longer cuts commands at the dots inside a path.
- **Review pass** (dead code, memory, index bugs, orphans, stop/restart): no dead code found (AST scan of 332 functions, imports, names and locals); setup-script texts are capped at 256 KB and dropped after each analysis; the external-AIDE process list no longer raises `IndexError`; a damaged `sessions.json` no longer fails every dashboard request; `run(save_to=...)` creates its file 0600 and never through a symlink; state directories are opened without following links. The shutdown order, orphan-unit sweep and keep-awake inhibitors were reviewed and needed no change. Every subprocess call has a timeout except the uninstaller's interactive `apt purge`.
- **AppArmor:** the broker profile allows `/run/ufw.lock` (most of the roughly 1,500 `ALLOWED` lines per boot).
- **`locsec-vm-check.sh`:** a real 5-second capture through the broker (fails if nothing is saved); AppArmor `DENIED` lines counted only since the broker started and split into LocSec and the tools it runs versus other programs.
- **Tests:** new `test_capture_pipe.py` 12, `test_reports_505.py` 16, `test_netinfo_505.py` 10, `test_auth_505.py` 6, `test_aide_505.py` 36. Passed for this build: `check_broker.py`, `test_fd_transit.py` 11, `test_suricata_purge.py` 38, and the AppArmor profile parsed with `apparmor_parser` 4.1.

**5.0-3 changes** (fixes four regressions from 5.0-2, found on its first real machine on 9 October 2026):
- **Files handed between the two halves arrive again** (capture, Deep analysis, AIDE report, root-only logs). The profiles now carry `attach_disconnected`, and a descriptor that does not arrive no longer resets the connection: the broker answers with a refusal that says to look for `operation=file_receive` in `journalctl -k`.
- **Lynis no longer reports "OK, no findings"** when it could not read its report; a run without a fresh `lynis-report.dat` is an error.
- **rkhunter's "verified benign" check works again.** `pkg.verify` (`dpkg --verify`) failed on every call after the broker lost `CAP_SETGID`; it now runs in its own `locsecd-pkgverify-*` unit with only `CAP_DAC_READ_SEARCH`.
- **ClamAV scans use `--fdpass` again** instead of falling back to `--stream` (the mount-namespace options of the 5.0-2 profile had broken it).
- **Tests:** `test_fd_transit.py` 11 passed (8 fail on 5.0-2).

**5.0-2 changes:**
- **Job units no longer get every capability.** Each broker job unit now names a profile (`_JOB_PROFILES`) with its own capability bounding set and file system; a job without a profile is refused. Before, `CapabilityBoundingSet=~` was read as every capability, so every job ran as full root, and the throwaway user that parses untrusted captures held every ambient capability.
- **Packet captures run in their own unit** (`locsecd-capture-*`, drops to the `tcpdump` user). The broker lost `CAP_SETGID` and `AF_PACKET`.
- **AppArmor profiles are installed and loaded in complain mode** (`/etc/apparmor.d/locsecd`, a conffile), and named by drop-ins only when AppArmor is on.
- **Purge puts `suricata.yaml` back** when it is still what LocSec wrote, and the inline `rule-files: [a, b]` form is handled.
- **`locsec-vm-check.sh` now accepts 5.x correctly** (it compared only the Debian revision before and skipped later checks without saying so).
- **Tests:** 70 more checks in `test_broker_rules.py` (261 passed, 1 failed: an AIDE test that depends on the date it runs, failing the same way on 5.0-1); `test_suricata_purge.py` 38 passed.

**5.0-1 changes:**
- Version 5.0-1, the first production release. The code is 4.0.11-103 unchanged. dpkg orders 5.0-1 after every 4.0.11 build, so upgrades run the same migrations.
- The dashboard help shows 5.0 in its install and rebuild examples.
- The .deb no longer contains a stray `__pycache__/locsecd.cpython-313.pyc` that the 4.0.11-103 .deb (and its source tarball) carried.
- `DEBIAN/md5sums` in the source tarball is regenerated; -103's tarball carried the -102 list.
- `locsec-vm-check.sh` accepts 5.x as well as 4.0.11-91 and later.
- Rule tests: 192 passed, 0 failed, the same as 4.0.11-103 run in the same sandbox.

**-103 changes:**
- Removed `AppArmorProfile=-locsecd-web` and `-locsecd-broker` from the two units. No profile is loaded, so the kernel logged `apparmor="DENIED" operation="change_onexec" info="label not found"` at each service start; the services ran normally, and `locsec-vm-check.sh` warned. To use the example profiles, load them and add `AppArmorProfile=` with a drop-in.
- `locsec-vm-check.sh` checks that the units name no profile. 192 rule tests (-102's 190 carried the 7 new ones; one more for the units).

**-102 changes:**
- LocSec no longer writes to `/etc/clamav/clamd.conf`. Up to -101 the installer appended six `ExcludePath` lines there. The file belongs to the clamav-daemon package and is tracked by ucf, so the next ClamAV upgrade or reinstall asked whether to install the package maintainer's version. LocSec never needed those lines: its scans build their own file list with their own exclusions.
- The installer removes lines an older LocSec added, but only when that gives back exactly the file ucf recorded (its md5 in `/var/lib/ucf/hashfile`). A `clamd.conf` that was also edited by hand is left as it is.
- On a fresh install clamav-daemon stayed stopped until a reboot or the first ClamAV scan: Debian's unit does not start without signatures, and the installer's start came before the first download. LocSec now checks every 5 minutes and starts clamd once the signatures exist, but only if systemd skipped its start for that reason. A clamd you stopped, or disabled, is left alone.
- The ClamAV scan excluded `/var/lib/locsecd/quarantine`, the vault's location before -91; it now excludes `/var/lib/locsecd-broker`. The report also counts files skipped for being in an excluded path.
- `locsec-vm-check.sh` reports whether clamav-daemon is active and whether `clamd.conf` still has LocSec-added lines.

**-101 and -100:** see `CHANGELOG-4.0.11-101` and `CHANGELOG-4.0.11-100` in `/usr/share/doc/locsecd/`.

**-99 changes:**
- Desktop notifications work again. Since -91 the daemon, which runs as `locsec` with `ProtectHome=true`, looked for the user's session bus in `/run/user`, which it cannot see, so it found "no graphical session" and never showed one. It now finds sessions from `loginctl` alone, and the broker checks the session bus as before.
- A notification is recorded as shown only when the desktop accepted it. One that was not shown stays "Waiting for a log-in", is summarised at the next log-in, and the log says why.
- **Send test notification** sends at once and reports whether the desktop showed it.
- A "Computer blocked" incident offers **Fix it** only to retry a failed block, not after the address was unblocked or the block expired. Explain says when a block is no longer in effect.
- Five new rule tests (183); three fail on -98.

**-98 changes:**
- Every broker refusal reads `refused VERB from pid P uid U: reason`. Refusals from argument checks (`file.open`, a block that is too wide, `apt_install`, `apt_upgrade`, `notify.desktop`) and malformed requests used to leave out the client. A call made inside the broker says `(in-process)`.
- `file.open` and `file.stat` refusals quote the path. Values a client chose (paths, package names, made-up verb names) are escaped and cut at 160 characters, so a crafted request cannot add lines or terminal codes to the log.
- `SyslogIdentifier=locsecd-broker` and `SyslogIdentifier=locsecd` in the units. Both used to appear in the journal as `locsecd.py[PID]`. The Logs page knows the new names and the old one.
- "target is not a file descriptor argument" now reads "target must be a plain value, not a file descriptor".
- Logging only: nothing the broker allows or refuses has changed. Seven new rule tests (178), each failing on -97. The rule tests now pin their own time zone, because one -97 AIDE test failed when the clock was UTC.

**-97 changes:**
- AIDE: account files (`passwd`, `group`, `shadow`, `gshadow`) are explained from the system log when only system accounts were added. A password change or a new login account stays a warning, with the log lines quoted. These files never get "quarantine it" advice.
- AIDE: files the system rebuilds during installs (`ld.so.cache`, `mailcap`, `99synaptic`), LocSec's own files, and folders whose explained entries changed are explained.
- The definitions update reads freshclam's own messages, so "Updated" and "Already up to date" are right.
- Suricata engine log: errors from before Suricata's latest clean start no longer count as current problems.
- A malformed quarantine restore id gets a clear message.

**-96 changes:**
- The Full scan button, the all-in-one scan behind it and `locsecctl scan` are removed. Each tool runs on its own schedule, or from its own button.
- Scans page: the scan buttons are named AIDE, Lynis, Debsecan, rkhunter, ClamAV, Ports/firewall and CVE scan, in the top row. Update system, the definitions update and the AIDE-baseline buttons are the row below.
- AIDE explains files a package's setup makes that dpkg does not list (Python byte-code, `rcN.d` and `.wants` links, `.dpkg-old` copies) and Synaptic's logs, when that package changed after the snapshot.

**-95 changes:**
- Lynis: the promiscuous-interface warning on Suricata's interface is informational (the -93 version missed Lynis's double space).
- The definitions-update report says "Updated" or "Already up to date" per tool instead of "No malware".
- Suricata rules are downloaded and reloaded at most every `ids_rules_min_hours` (default 6), remembered across restarts; before, every LocSec restart reloaded all ~53,000 rules.

**-94 changes:**
- The installer lets clamd read its own `/proc/PID/cgroup` under AppArmor: it adds `@{PROC}/@{pid}/cgroup r,` to `/etc/apparmor.d/local/usr.sbin.clamd` (once, marked "Added by locsecd") and reloads the clamd profile, which stops a harmless `apparmor="DENIED"` line at every clamd start. A purge removes only that marked rule.

**-93 changes:**
- AIDE: changes from software installed since the snapshot are explained again (the snapshot time now comes from the broker).
- Suricata: this machine's own connections are recognised as outbound, so alerts are worded right and can trigger a block. If `ip` gives no addresses, LocSec reads `/proc/net` and logs why.
- Ports scan: program names are shown (`ss -p` runs in a short transient unit).
- rkhunter: locsec in adm and systemd-journal, and package-owned files missing from rkhunter.dat that verify unmodified, are informational.
- Lynis: a promiscuous interface is informational when Suricata captures on it.
- The definitions update writes a report.

**-92 changes:**
- The start-up sweep of stale job units no longer asks the broker to stop `locsecd-broker.service` (found on a real Debian 13 machine). A new rule test covers it.

**-91 changes:**
- `locsecd.service` runs as `locsec` with no capabilities. `locsecd-broker.service` runs as root without network access and only answers requests for its verbs.
- New root-only directory `/var/lib/locsecd-broker`, for the quarantine vault, the install manifest and Suricata setup state. The installer migrates them.
- The dashboard's policy file moved to `/var/lib/locsecd/runtime-policy.json`.
- `sudo locsecctl scan-aide` and the other one-shot commands run as `locsec` too.
- Files cross between the two services as open descriptors. The broker stops the jobs of a client that goes away.
- New `passwd` dependency.
- postinst no longer writes `report_retention_days` into `locsecd.conf` (the daemon already defaults it to 7), so a fresh install leaves the file as shipped and `dpkg --verify` no longer reports it.

### `locsec-vm-check.sh`: the post-install check

Run it as root on a real machine after installing the .deb. It prints PASS, FAIL or WARN per check and a summary, and changes nothing except a short `ufw` status read. With an attack script it also runs `attack_as_web.py` as the `locsec` user.

```bash
sudo bash locsec-vm-check.sh                           # checks only
sudo bash locsec-vm-check.sh /tmp/attack_as_web.py     # plus the attack test (copy it from tests/ in the source tarball)
```

Checks added by version (each runs only when that LocSec version or later is installed; the version is compared with `dpkg --compare-versions`):

| From | Checks |
| --- | --- |
| 4.0.11-91 | Package and `locsec` account; both services active, enabled and running as `locsec` and `root`; file ownership and modes; hardening scores; dashboard on 127.0.0.1:8765 only; `locsecctl` verbs; the attack test; error lines in the journal |
| 4.0.11-98 | Both services log to the journal under their own names; refusal lines name the caller's pid and uid; the `file.open` refusal names the path |
| 4.0.11-102, -103 | `clamd.conf` has no LocSec-added lines; the unit files name no AppArmor profile |
| 5.0-2 | The broker has no `CAP_SETGID` (decoded with `capsh`); both AppArmor profiles are loaded in complain mode, named by the units' drop-ins and carried by the running processes; how many `ALLOWED` lines they logged this boot; whether a purge would put `suricata.yaml` back |
| 5.0-3 | Both profiles have `attach_disconnected`; no "disconnected path" kernel lines and no request that lost its file descriptor since the broker started; `pkg.verify` through the broker works (`dpkg --verify coreutils`) |
| 5.0-5 | A real 5-second packet capture through the broker, with the file opened under the `locsecd-web` profile as the dashboard opens it (fails if nothing is saved; it would have caught the empty captures); AppArmor `DENIED` lines counted only since the broker started and listed separately for LocSec and the tools it runs (`tcpdump`, `clamd`, `tshark`, `freshclam`) versus other programs, with clamd's own `cpu.max` read left out |
| 5.0-6 | A unit started as `clamav` with ambient `CAP_DAC_READ_SEARCH` (the way the broker starts a ClamAV batch) scans a root-only file with `--fdpass` and cannot write a file root owns; no `fdpass failed` line since the broker started; an **AppArmor enforce readiness** report (the distinct `ALLOWED` lines, with counts, or the commands to switch to enforce and back). `LOCSEC_VMCHECK_KLOG=file` reads the kernel log from a file to test the report |
| **5.0-7** | The two cosmetic `/dev/null` denials from Debian's `tcpdump` profile during a capture are reported as information; any other `tcpdump` denial still warns |

The script ends with a short list of manual checks (open the dashboard, run each scan once, stop `locsecd` mid-scan and confirm nothing is left running, reboot and run it again, purge and reinstall). Run it once before and once after the dashboard walkthrough: the descriptor-transit and capture checks cover the capture, Deep analysis, AIDE and Lynis runs. After the ClamAV scan, `sudo journalctl -t locsecd-broker --since '30 min ago' | grep -i 'fdpass failed'` should print nothing.

### Release files and integrity

LocSec releases are **not signed**. Compare these SHA-256 hashes, or rebuild from source you trust, before installing a copy of unknown origin:

```
8b904c99243e8c5e9805836b0022211f34b3b1873edffce16a9758d762527beb  locsecd_5.0-12_amd64.deb
041bb37a934837ece091cf20da48f77478cb6b5040d9d04c84aad1b6b524f068  locsecd-5.0-12-source.tar.gz
b41b5af293713532d8ddda76e3cbea6af0691a4f07c1fcc2d7df5e31a2561709  locsec-vm-check.sh
cc218154dec595d27910e7970779a984aa1afb6097ad45d15b2579a9df16b5bb  LocSec-Installation-Guide-5_0-12.docx
```

The installation guide, `LocSec-Installation-Guide-5_0-12.docx`, is listed above and was updated for 5.0-12. `SHA256SUMS-5.0-12.txt` lists these four files and does not list this README.

### The 5.0-12 release is signed

| | |
| --- | --- |
| Key | `LocSec release` (the user ID is shown by `gpg --list-keys 7AF133991FCE7BA116B59CF6236F1B2948231734`), ed25519, created 9 October 2026, **expires 8 October 2028** |
| Fingerprint | `7AF1 3399 1FCE 7BA1 16B5  9CF6 236F 1B29 4823 1734` (full: `7AF133991FCE7BA116B59CF6236F1B2948231734`) |
| Public key | `locsec-release-key.asc`, in the release folder |
| Signatures | one `.asc` beside each of `locsecd_5.0-12_amd64.deb`, `locsecd-5.0-12-source.tar.gz`, `locsec-vm-check.sh`, `LocSec-Installation-Guide-5_0-12.docx` and `SHA256SUMS-5.0-12.txt` (all five verified as "Good signature") |

To check a download, import the public key, verify the signed checksum file, then check the files against it:

```bash
gpg --import locsec-release-key.asc
gpg --verify SHA256SUMS-5.0-12.txt.asc SHA256SUMS-5.0-12.txt && sha256sum -c SHA256SUMS-5.0-12.txt
```

Compare the fingerprint that `gpg --import` or `gpg --fingerprint` shows with the one above **and with a copy published somewhere other than next to the files**: a key that comes from the same place as the files proves nothing. The signatures cover the five files named above only; this README, `STATUS-AND-TODO.md` and `LocSec-What-Is-Left-To-Do.docx` are not signed. If any signed file is changed, it must be re-signed and `SHA256SUMS-5.0-12.txt` regenerated and re-signed last. The secret key stays in the signer's `~/.gnupg`; the revocation certificate GnuPG made for it should be kept offline.

### Signing a release

The releases are unsigned until someone signs them with a key of their own. `release/sign-release.sh` (in the source tarball) does the signing and the verification, and never creates a key. To make a release key once (you choose the name, expiry and passphrase, and keep the secret key offline or backed up):

```bash
gpg --quick-generate-key "LocSec release <you@example.org>" ed25519 sign 2y
gpg --armor --export <fingerprint> > locsec-release-key.asc      # publish next to the releases
sha256sum locsecd_5.0-12_amd64.deb locsecd-5.0-12-source.tar.gz locsec-vm-check.sh > SHA256SUMS-5.0-12.txt
LOCSEC_SIGN_KEY=<fingerprint> bash release/sign-release.sh locsecd_5.0-12_amd64.deb locsecd-5.0-12-source.tar.gz locsec-vm-check.sh SHA256SUMS-5.0-12.txt
```

To check a download: `gpg --import locsec-release-key.asc && gpg --verify SHA256SUMS-5.0-12.txt.asc SHA256SUMS-5.0-12.txt && sha256sum -c SHA256SUMS-5.0-12.txt`. Compare the key's fingerprint with one published somewhere else: a key that comes from the same place as the files proves nothing. The script was tested with a throwaway key (it signs, verifies, detects a changed file and refuses to run without a key).

`SHA256SUMS-5.0-5.txt` also lists `README.md`; this README has been edited since, so its hash will not match.

### Building from source

The source tarball is the package tree itself (`DEBIAN/` plus `etc/`, `lib/`, `usr/`, `var/`). The only build tool is `dpkg-deb`:

```bash
tar xzf locsecd-5.0-12-source.tar.gz
cd locsecd-5.0-12-source       # edit, then refresh checksums (tests/ is not part of the package):
find . \( -path ./DEBIAN -o -path ./tests -o -path ./release \) -prune -o -type f -print | sed 's#^\./##' | sort | xargs md5sum > DEBIAN/md5sums
cd ..
python3 locsecd-5.0-12-source/tests/check_broker.py locsecd-5.0-12-source/usr/lib/locsecd/locsecd.py
rm -rf build && mkdir build && cp -a locsecd-5.0-12-source build/pkg && rm -rf build/pkg/tests build/pkg/release
dpkg-deb --root-owner-group -Zzstd --build build/pkg locsecd_5.0-12_amd64.deb
sudo apt install ./locsecd_5.0-12_amd64.deb
```

- Copy the tree with `tar` or `cp -a`, because it contains a symlink and an empty directory.
- The tarball's `tests/` folder is not part of the package. `dpkg-deb` packs everything in the folder it is given, so build from a copy without `tests/`, as above. `tests/README` explains each check. The static check (`check_broker.py`) is safe anywhere; run the others only in a throwaway container or VM.
- LocSec is GPL-3.0-or-later because `locsec-gui.py` imports PyQt6, which is GPLv3.

---

# masterhelp.tcl — Eggdrop Help Menu Script

`masterhelp.tcl` is an [Eggdrop](https://www.eggheads.org/) IRC bot script that provides the bot's top-level **`!bhelp`** menu. It is a signpost: it lists the help commands that *other* scripts on the bot own and answer, and it deliberately does not touch those scripts.

Users type `!bhelp` in a channel and get a short list of categories. Each category trigger (for example `!oshelp`) prints its own sub-list, and the entries in that sub-list (for example `!debhelp`) are answered by the individual scripts.

---

## How the menu is organised

```
!bhelp
├── !oshelp         OS / handbook command references
├── !gamehelp       Bot games (an index of four sub-categories)
│   ├── !sportgamehelp
│   ├── !fightgamehelp
│   ├── !cardgamehelp
│   └── !othergamehelp
├── !irchelp        IRC / network services and channel tools
└── !otherhelp      Everything else
```

`!bhelp` and the eight category triggers above are the **only** triggers this script binds. The entries listed beneath them are owned and answered by other scripts.

### Entries listed under each category

| Category | Listed help triggers |
| --- | --- |
| `!oshelp` | `!archhelp`, `!bsdhelp` (also `!fbsdhelp`/`!obsdhelp`/`!nbsdhelp`), `!buntuhelp`, `!debhelp`, `!linuxhelp`, `!susehelp`, `!winhelp` |
| `!sportgamehelp` | `!baseballhelp`, `!bowlhelp`, `!duckhunthelp`, `!fishhelp`, `!golfhelp`, `!homerunhelp` |
| `!fightgamehelp` | `!bshiphelp`, `!fighthelp`, `!mafiahelp`, `!riskhelp` |
| `!cardgamehelp` | `!bjhelp`, `!casinohelp`, `!cribbagehelp`, `!pokerhelp` |
| `!othergamehelp` | `!cluehelp`, `!lifehelp`, `!monohelp`, `!openrpghelp`, `!scrabblehelp`, `!stairshelp` |
| `!irchelp` | `!dalhelp`, `!guardhelp`, `!restricthelp`, `!spyhelp`, `!whohelp` |
| `!otherhelp` | `!comhelp`, `!converthelp`, `!poemshelp`, `!talkbothelp` (also covers `!dcchelp` and `!costhelp`) |

After every menu or sub-list the script prints one footer line: *"If a !help command does not work, the bot may not be on this network."*

> **The menu is a plain list of strings.** It has no link to any real bind, so an entry whose script is removed or renamed will keep appearing and silently stop working. Before adding an entry, confirm the target script really binds that trigger (look for its `bind pub` line).

---

## What the script does

- **Prints the menu and sub-lists** for `!bhelp` and the eight category triggers.
- **Restricts where it answers** with a channel allow-list.
- **Chooses how it replies** — in the channel, by NOTICE, or by private message — for everyone, switchable at runtime by the bot owner.
- **Rate-limits users** so the menu can't be used to flood the bot.
- **Survives rehashes cleanly** — no duplicate binds, duplicate timers, or lost cooldown state.

### Commands

| Command | Who | Effect |
| --- | --- | --- |
| `!bhelp` | Everyone (default flags `-\|-`) | Print the top-level category menu |
| `!oshelp` `!gamehelp` `!irchelp` `!otherhelp` | Everyone | Print that category's sub-list |
| `!sportgamehelp` `!fightgamehelp` `!cardgamehelp` `!othergamehelp` | Everyone | Print that game sub-category's list |
| `!bhelp mode` | Everyone | Show the current output mode and channel scope (read-only) |
| `!bhelp set <channel\|msg\|notice>` | Bot owner (flag `n`) only | Change where `!bhelp` answers, for **every** caller, until changed again |

Accepted aliases for `msg`: `pm`, `dm`, `privmsg`, `private`. A non-owner who tries `!bhelp set …` is told only the owner can do that. Runtime changes are written to the bot log.

---

## Installation

1. Copy `masterhelp.tcl` into your Eggdrop `scripts/` directory.
2. Add this line to `eggdrop.conf`:

   ```tcl
   source scripts/masterhelp.tcl
   ```

3. Edit the settings below (at minimum, `channel`), then rehash or restart the bot:

   ```
   .rehash
   ```

On load, the bot logs a line such as:

```
masterhelp.tcl loaded (trigger=!bhelp, flags=-|-, output=notice): 4 categories, 8 category triggers bound
```

---

## Configuration

All settings live in the `namespace eval masterhelp { … }` block at the top of the file. Edit them and `.rehash`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `trigger` | `!bhelp` | The top-level command |
| `flags` | `-\|-` | Who may use the commands: `-\|-` everyone, `o` ops, `n` owner, etc. Applies to `!bhelp` and all eight category triggers. |
| `channel` | `#prototype #mafia #debian` | Channels where the help commands answer. Space-separated, case-insensitive. `*` or `all` means every channel. Empty disables public replies. **Change this to match your own channels.** |
| `output` | `notice` | Reply mode: `channel`, `msg`, or `notice`. Also changeable at runtime with `!bhelp set`. Survives a rehash. |
| `ratelimit_secs` | `15` | Seconds a user must wait between uses |
| `ratelimit_scope` | `both` | `global` (one shared cooldown per user), `percmd` (one per command per user), or `both` (must clear both) |
| `ratelimit_cleanup_secs` | `3600` | How often stale cooldown entries are swept (seconds) |
| `ratelimit_maxentries` | `5000` | Hard cap on cooldown table size; the oldest entry is evicted when the cap is reached |
| `menu` | four categories | Top-level list, as `{trigger "description"}` entries |
| `categories` | see above | Each category's sub-list, same shape |
| `footer` | "If a !help command does not work…" | Printed once after every list |

Invalid values for `ratelimit_*`, `output`, or an empty `trigger` are logged and forced to a safe default rather than failing silently.

---

## Maintaining the menu

**Add an entry to an existing category**

1. Confirm the other script actually binds the trigger.
2. Add a `{!newhelp "description"}` line to the right sub-list in `$categories`, keeping the list in alphabetical order by trigger.
3. `.rehash`.

**Add a new category**

1. Add a line to `$menu` and a matching `{!newcat { … }}` block to `$categories`.
2. Add a one-line proc (`masterhelp::newcat_cmd`) that calls `masterhelp::cmd_category "!newcat" $nick $host $hand $chan`.
3. Add the trigger and proc to the bind list near the bottom of the file.
4. `.rehash`.

Keep each description short: IRC messages are limited to 512 bytes, and this script truncates every outgoing line to 400 characters.

---

## Design notes

- **Leaf help triggers are not bound here.** Scripts such as `dalnet.tcl`, `whois.tcl`, `fight.tcl`, and `talkbot.tcl` own their own help commands and answer them directly. This script only points users at them.
- **Config uses `set`, state uses `variable`.** Configuration values are plain `set`, so edits take effect on rehash. `output`, the cooldown tables, and the bind-tracking variables use a guard so they *keep* their values across a rehash.
- **No leaked binds or timers.** The script records what it actually bound (`bound_trigger`, `bound_flags`, `bound_subtriggers`) and unbinds those exact registrations on reload, so editing `trigger` or `flags` doesn't leave the old bind active. The cleanup timer is likewise cancelled and rescheduled each load.
- **Output is sanitised.** Carriage returns, newlines, and `\001` characters are stripped and lines are capped at 400 characters, so menu text can't inject IRC commands or CTCP.
- **Bounded memory.** User IDs (`nick!host`) are truncated, the cooldown tables are size-capped, and an hourly sweep drops entries older than two hours (or twice the cooldown, if larger).
- **Whitespace-safe parsing.** Arguments are tokenised with a `\S+` scan, so `!bhelp set  channel` (two spaces) works.

---

## Requirements

- Eggdrop with Tcl 8.5 or later (the script uses `lassign` and the `ni` operator)
- The other help scripts you list in the menu, if you want those entries to answer
- `masterhelp.tcl` itself needs no extra Tcl packages; some of the scripts it lists do (see [Eggdrop on Debian 13 (Trixie)](#eggdrop-on-debian-13-trixie--package-requirements))

---

# Eggdrop Scripts Indexed by masterhelp.tcl

These are the scripts that `!bhelp` points to. Each one answers its own help trigger; `masterhelp.tcl` only lists them. Where a script has a separate data file, it is listed with it. Everything is sourced from `eggdrop.conf` the usual way (`source scripts/<file>.tcl`, then `.rehash`).

Several scripts are third-party and keep their original authors and licences: `Duck_Hunt.tcl` (Menz Agitat), `BlackScrabble.tcl`, and `StairsAndSlides.tcl` (TCLScripts.NET).

## `!oshelp` — OS command references

Each reads its topics from a matching `*_data.tcl` file, so you can add or change topics without touching the bot logic.

| Trigger | Files | Summary |
| --- | --- | --- |
| `!archhelp` | `archhelp.tcl`, `arch_data.tcl` | Arch Linux install, pacman, AUR, systemd, network |
| `!bsdhelp` | `bsdhelp.tcl`, `bsd_data.tcl` | FreeBSD / OpenBSD / NetBSD (also `!fbsdhelp`, `!obsdhelp`, `!nbsdhelp`) |
| `!buntuhelp` | `buntuhelp.tcl`, `buntu_data.tcl` | Ubuntu apt, snap, sources, systemd, network |
| `!debhelp` | `debhelp.tcl`, `deb_data.tcl` | Debian apt, sources, systemd, network, disks |
| `!linuxhelp` | `linuxhelp.tcl`, `linux_data.tcl` | General, distro-agnostic Linux shell and userland |
| `!susehelp` | `susehelp.tcl`, `suse_data.tcl` | openSUSE zypper, repos, YaST, systemd |
| `!winhelp` | `winhelp.tcl`, `win_data.tcl` | Windows commands, winget, setup, recovery |

## `!gamehelp` — Games

| Trigger | Files | Summary |
| --- | --- | --- |
| `!baseballhelp` | `baseball.tcl`, `baseball_data.db` | Hall-of-Fame baseball: draft teams, play exhibitions or a full season (default trigger `!bb`) |
| `!bowlhelp` | `bowling.tcl` | `!bowl` — USBC ten-pin bowling with frame scoring |
| `!duckhunthelp` | `Duck_Hunt.tcl`, `duck_hunt/` | `!duckhunt` — shoot ducks, reload, shop, stats (third-party) |
| `!fishhelp` | `fishing.tcl` | `!fish` — fishing RPG with levels 1–500, gear, bait, boats, monthly tournament; SQLite-backed |
| `!golfhelp` | `golf.tcl` | `!golf` — 9/18-hole rounds, weather, gear shop, hole-in-one tournament |
| `!homerunhelp` | `homerunsmash.tcl` | All-day pitch-and-swing minigame |
| `!bshiphelp` | `battleship.tcl` | `!battleship` — two-player, fleets placed by private message |
| `!fighthelp` | `fight.tcl`, `fight.db` | `!fight` — blind-commit fighting game: both players secretly pick an attack and a guard |
| `!mafiahelp` | `mafia.tcl`, `Mafia.cfg` | `!mafia` — crime/RPG game; SQLite-backed, settings in `Mafia.cfg` |
| `!riskhelp` | `risk.tcl` | `!risk` — classic Risk for 2–6 players, CPU fills empty seats |
| `!bjhelp` | `blackjack.tcl` | `!blackjack` — multiplayer blackjack with betting |
| `!casinohelp` | `casino.tcl` | `!slots`, `!cards`, `!points`, `!give`, `!top10` |
| `!cribbagehelp` | `cribbage.tcl` | `!crib` — two-player cribbage, or solo against the bot |
| `!pokerhelp` | `poker.tcl` | `!poker` — play-money Texas Hold'em |
| `!cluehelp` | `clue.tcl` | `!clue` — Clue/Cluedo deduction game |
| `!lifehelp` | `life.tcl` | `!life` — The Game of Life, 2–4 players |
| `!monohelp` | `monopoly.tcl` | `!mono` — Monopoly, up to 4 players |
| `!openrpghelp` | `openrpg.tcl`, `orpg_players.db` | `!openrpg` — open-world RPG (races, classes, spells, dungeons, raids) |
| `!scrabblehelp` | `BlackScrabble.tcl`, `Scrabble.db` | `!scrabble` — word game (third-party) |
| `!stairshelp` | `StairsAndSlides.tcl` | `!stairs` — stairs and slides board game (third-party) |

## `!irchelp` — IRC and channel tools

| Trigger | Files | Summary |
| --- | --- | --- |
| `!dalhelp` | `dalnet.tcl`, `dalnet_help.db`, optional `sendnotice.tcl` | DALnet ChanServ/NickServ/MemoServ help (`!cshelp`, `!nshelp`, `!mshelp`, `!csend`, `!nsend`, `!msend`). Answers come from the local `.db` file, not from services. `sendnotice.tcl` adds a separate rate limit for the `!*send` commands. |
| `!guardhelp` | `guard.tcl`, `guard.state` | Join monitor: WHOIS-checks new joiners and bans (timed, default 24 h) users found in a designated channel. Bans are listable and removable with `.guard` or `!guard`. |
| `!restricthelp` | `restrict.tcl` (header: `autorestrict.tcl`) | Sets channel `+R` after a kick from a trusted source, then removes it after 15 minutes (45 if repeated). `.autorestrict` on the partyline for status/off/clear. |
| `!spyhelp` | `spychan.tcl` | Botnet relay: leaf bots on other networks relay joins/parts/quits/splits to a home channel |
| `!whohelp` | `whocom.tcl` | `!wi`, `!wa`, `!pi`, `!ver`, `!dom`, `!ip` lookups |

## `!otherhelp` — Everything else

| Trigger | Files | Summary |
| --- | --- | --- |
| `!comhelp` | `com.tcl` | Admin-only `!brestart`, `!brehash`, `!bdie`, `!bchans` |
| `!converthelp` | `convert.tcl` | Temperature, currency, mass, distance, volume. Enable per channel with `.chanset #channel +convert`. |
| `!poemshelp` | `melons_poems.tcl` | `!poem`, `!poems`, `!autopoem`; `#poets` only |
| `!talkbothelp` | `talkbot.tcl`, optional `talkbot_cost.tcl` | AI persona that replies when the bot is mentioned (OpenAI API), plus `!talkbotfacts`, `!talkbotpic`, `!dcchelp`. `talkbot_cost.tcl` adds `!cost` / `!costhelp` spend reporting and must be sourced *after* `talkbot.tcl`. |

## Setup notes

- **talkbot** needs an OpenAI API key. Put it in `scripts/talkbot_apikey.txt` (`chmod 600`) and leave the inline `apikey` variable empty. Only users with an access flag (+f, +o, +m, +n by default) get replies.
- **Data files** (`*.db`, `guard.state`, `Mafia.cfg`) are created or edited by their scripts; back them up with the bot.

---

# Eggdrop on Debian 13 (Trixie) — Package Requirements

Package requirements for the 28-script Eggdrop set (the `new.zip` script set), including the scripts indexed above. This is based on reading each script's `package require` and `exec` calls; **nothing was run**. Confirm the Eggdrop package exists in your release with `apt-cache policy eggdrop`.

## Install

```bash
apt update
apt install eggdrop tcl8.6 tcl-tls tcllib libsqlite3-tcl ca-certificates coreutils
```

If you build Eggdrop from source instead of using the `eggdrop` package, also install:

```bash
apt install build-essential tcl8.6-dev libssl-dev zlib1g-dev
```

## Dependencies by script

| Package | Needed by | Notes |
| --- | --- | --- |
| `tcl8.6` | All scripts | Core Tcl runtime |
| `tcl-tls` | `talkbot`, `whocom`, `convert` | HTTPS (`api.openai.com` etc.). `convert.tcl` wants tls 1.7.16+; Trixie's is newer. |
| `tcllib` | `talkbot`, `talkbot_cost` | Provides `json`. Without it they fall back to a regex scrape of the API response. |
| `libsqlite3-tcl` | `fishing`, `mafia` | Provides `package sqlite3`; both scripts need it for their databases. |
| `ca-certificates` | `talkbot` | Supplies `/etc/ssl/certs/ca-certificates.crt` for TLS verification. |
| `coreutils` | `sysinfo` | Provides `df`. Everything else is read from `/proc`. |

`http` ships with Tcl and needs no separate package. The remaining scripts — the `*help` family, `dalnet`, `casino`, `baseball`, `fight`, `openrpg`, `spychan`, `restrict`, `mem`, `com`, `masterhelp`, `melons_poems` — need no extra Tcl packages. The `*_data.tcl` files are sourced by their parent scripts.

## Before loading

- **Load order:** source the *main* script (e.g. `bsdhelp.tcl`), not its `_data.tcl` file. `talkbot_cost.tcl` goes with `talkbot.tcl` (after it).
- **Run as a normal user:** never as root. `adduser eggdrop`, then run the bot as that user.
- **`whocom.tcl`:** `!dom` uses raw TCP whois on port 43, so allow outbound 43. It falls back to RDAP and HackerTarget over HTTPS.

## Verify the packages load

```bash
echo 'puts [package require tls]; puts [package require sqlite3]; puts [package require json]' | tclsh8.6
```

---

# LiveWorld RPG — Offline Fantasy RPG

**Version 1.0.11** · Package: `liveworld-rpg`

LiveWorld RPG is an offline, single-player fantasy RPG with isometric 2.5D graphics, written in Python with pygame. You play in a large living world with 12 classes, instanced dungeons and raids, PvP battlegrounds, crafting, gathering, fishing, mounts, and about 640 computer-controlled adventurers.

For the full player's guide, see `LiveWorld-RPG-Guide.md`, or press **F1** in the game.

## What's new in 1.0.11 (9 October 2026)

- **Quest tooltips.** Hovering a quest offer at a Quest Giver or a Mayor now shows its full description, level, XP, gold and the whole reward (the reward line on the card was cut off). Hovering one of your active quests in that window shows the same details as the Quest log (Q).
- **Crash on button clicks fixed (probably).** Some PCs crashed (a segmentation fault with no message) when clicking window buttons such as Accept, Decline or Turn in. Every window button plays a click sound, and the background music used to be created and started from a timer thread while the main thread played sounds; SDL_mixer is not safe to drive from two threads. The music is now built in the background but started on the main thread only. This was not reproduced on the developer's side, so if it still happens, start the game with sound off (`LIVEWORLD_NO_AUDIO=1 liveworld-rpg`) and send `startup.log`.
- **Crash trace.** A crash inside a library now leaves a Python traceback in `startup.log`.
- **Slain town guards return.** The code that puts slain guards back at their posts after 30 minutes was never called, so they stayed flagged as slain and their list grew for the whole session. It runs every update now.
- **Safer layout cache.** The cached road layout is only loaded if you own the file and it is not world-writable, and new cache files are written private (0600).
- **Tests:** 74 pass (two new ones for the guards and the main-thread-only sound).
- **Not changed:** the first start uses a `fork` pool to paint the map while the map is not cached yet; this was reviewed and left as it is.

### The 1.0 series, release by release (8 and 9 October 2026)

The full note for every 1.0.x release, newest first (the same text as the game's AppStream release notes):

- **1.0.11** (2026-10-09): Hovering a quest at a Quest Giver or Mayor now shows its full details and reward. Fixes a crash when clicking buttons such as Accept or Decline (sound is now driven from the main thread only; set LIVEWORLD_NO_AUDIO=1 to turn sound off). Slain town guards now return to their posts. Crashes leave a trace in the startup log.
- **1.0.10** (2026-10-09): The location box under the minimap (and every other gold-framed panel) is now evenly solid instead of see-through at the top and bottom with a dark band in the middle. Dungeon entrances show a glowing violet portal instead of a flat dark doorway.
- **1.0.9** (2026-10-09): The location box under the minimap is now solid, so it no longer looks gray over snow.
- **1.0.8** (2026-10-09): Adventurers now leave and enter walled towns through their gates instead of pressing against the wall on the straight line to their goal.
- **1.0.7** (2026-10-09): Adventurers that cannot get closer to their goal for about 10 seconds (for example pressed against a city wall) give up and pick a new task.
- **1.0.6** (2026-10-09): Faster start: the road, town and pond layout is cached on disk after the first launch (about 20-35 s saved on slow CPUs).
- **1.0.5** (2026-10-09): A vast 1440x1200 world with 20 hamlets, 2,000 zone players plus 100 roamers who wander the whole map and sometimes assault towns (rarely). Reinforcements arrive the longer a city battle lasts. New regalia for rulers, queens, mayors and quest givers, and varied faces for townsfolk. First launch builds the map about twice as fast, using every CPU core. City raids are rarer.
- **1.0.4** (2026-10-08): City raids rebuilt: 24 attackers at most, random garrisons, every guard, quest giver and ruler rallies and can fall (back in 30 minutes), bigger towns are better defended, and a fallen town is safe for 24 hours. A global alert shows when an allied town is attacked. Crownlands is a neutral zone and the other zones mix Alliance and Horde towns. 1,440 players spread over every zone, capped at their zone top level, with every gear tier from Poor to Mythic. Flying mounts cannot be hurt. Stable mount pictures fixed.
- **1.0.3** (2026-10-08): Mounts leave trails, wing wash and hoof dust. Towns glow after dark and forges throw sparks. Dungeon gates breathe coloured light. Bridges have foam and lanterns. Fire, frost and arcane/lightning spells burn, freeze and stun, and each gives a short buff.
- **1.0.2** (2026-10-08): Every class has a bonus on spell hits, frozen and burning enemies glow, and the guide matches the new elements. Raids: a red arrow and minimap marker point to the besieged town, and a Go to the fight button takes you there. Battleground flags and capture points glow.
- **1.0.1** (2026-10-08): Monsters notice you from much closer, let go when you move away, and never pull you at a dungeon door. Forests are real woods with open meadows between. Faster on slow computers.
- **1.0.0** (2026-10-08): Battlegrounds: Horde is always red and Alliance always blue - flags, capture points, scores and flag messages follow your faction.

### From 0.46.42 and earlier

- **0.46.42.** Hardening: damaged or hand-edited saves can no longer crash quest, mount, market, build or party lookups.

### From 0.46.15 to 0.46.41

- **Waygates (0.46.36).** The major city of every zone turns one of its houses into a teleport building. For 50 gold and a Scroll of Teleportation, pick any city of your side from a list (raided cities first). City raids now field 24 attackers, always full. The Waygate window wraps its text and fits its list of cities (0.46.41).
- **Mana (0.46.29, 0.46.31).** Mana no longer refills by itself in a fight, so Mana Potions matter. The new **Meditation** passive (level 50, equip it at a Skill Shop) regenerates mana everywhere, even in combat. Maximum mana grows by 6 per level, and mana comes back out of combat on its own.
- **Passive slots (0.46.30).** 1 slot up to level 50, 2 from level 51, 3 from level 75.
- **Hover details everywhere (0.46.38).** Skills (damage, cooldown, effects), passives, class cards, the Trade Market, ground drops and Armory supplies all show tooltips. The Forge shows each piece's Power against what you wear.
- **Spell elements (0.46.38).** Cold slows and freezes, fire ignites, electric shocks and arcs to a second enemy, earth staggers.
- **Class flavour (0.46.39).** Shadow spells wither (+10% damage taken from you for 4 seconds), holy spells leech 6% of damage as healing, poison and nature spells poison for 8% a second over 4 seconds.
- **Battlegrounds (0.46.31, 0.46.32, 0.46.34).**
  - 4 minutes (12v12) and 8 minutes (24v24).
  - Capture the Flag is first to 3 captures, or most flags at time. The whole team hunts the enemy carrier or escorts yours, dropped flags return at once, flag dots show on the minimap, and team lists collapse.
  - Battle mounts are ridden only in battlegrounds. Buying one no longer makes it your open-world mount, and the Armory picks your battleground mount separately.
- **Town guards (0.46.35).** They attack enemy-faction adventurers who walk inside the town's walls, just as they attack you. The intruders retreat to a friendly town to heal.
- **Interface.**
  - The quest tracker can be collapsed to a small button (0.46.29).
  - Weapon icons match the weapon everywhere (0.46.25).
  - Stable cards are readable, every mount animates and flying mounts have no legs (0.46.38).
  - "Ask to join party" and "Dismiss from party" sit side by side (0.46.37).
  - The Settings key list wraps inside its panel (0.46.40).
  - Buildings, city walls and battleground cover are drawn in darker stone (0.46.32).
  - Every button plays the same click, and the HUD labels the PvP rank (0.46.33).
- **Movement (0.46.24).** It uses real elapsed time, so on a slow PC walking and mounts move at their full stated speed.

## Files in this release

| File | What it is |
|---|---|
| `liveworld-rpg_1.0.11_all.deb` | Installable Debian package (architecture `all`, 393,672 bytes) |
| `liveworld-rpg-1.0.11-source.tar.gz` | The whole package tree, packaging scripts, tests and `build.sh` |
| `LiveWorld-RPG-Guide.md` | Player's guide: the in-game guide (F1) text, with an Updating and troubleshooting page, plus a "What's new in the 1.0 releases" section that is in this file only |
| `SHA256SUMS-1.0.11.txt` | Checksums of the three files above |

## Verify the download

Put the files and `SHA256SUMS-1.0.11.txt` in one folder and run `sha256sum -c SHA256SUMS-1.0.11.txt`; every line must say OK.

```
b42564820042195f57fc2a7204699a3397208c7d094409b71545fe0e3fbd4470  liveworld-rpg_1.0.11_all.deb
47d06f46d33dfff695b85bbe09536851ee8c2d66e314357020b1044b4961ef85  liveworld-rpg-1.0.11-source.tar.gz
f43ef6db0e1c41df26fb9967d6c139a9f92dcb409d52d69958f5a531826e56d3  LiveWorld-RPG-Guide.md
```

## Requirements

- Debian, Ubuntu, Linux Mint or another Debian-based Linux (any CPU)
- `python3`, `python3-pygame`, `python3-numpy` (apt installs these for you)
- Recommended: `x11-utils` for correct full-screen sizing

## Install

```bash
sudo apt install ./liveworld-rpg_1.0.11_all.deb
```

Keep the `./` so apt installs the local file and fetches the dependencies. Close the game first. Installing over an older version keeps your saves (they live in `~/.local/share/liveworld-rpg`). If you used `dpkg -i` and it reported missing packages, run `sudo apt -f install`.

## Play

Start it from **Applications → Games → LiveWorld RPG**, or run:

```bash
liveworld-rpg
```

The first start builds the world and caches the road layout and map (20 to 35 seconds on a slow PC). Later starts take a few seconds. The cache files in the save folder are safe to delete; they are rebuilt.

To create a hero from the terminal instead:

```bash
liveworld-create-character NAME Alliance|Horde CLASS [SPEC]
```

### Key controls

| Input | Action |
|---|---|
| Left click | Walk / target a monster and auto-attack with your weapon |
| 1–0, Shift+1–6 | Class spells / capstone spells (levels 30–80) |
| W A S D / arrows | Move |
| Space or E, Tab | Attack nearest / next target |
| F | Talk, gather, enter, use buildings |
| H / J / T / Y / V / Z / G | Health potion / mana potion / teleport / buff / eat / loot / fish |
| I / C / K / U / M / Q | Bag / Hero / Skills / Stats / Map / Quests |
| X | Mount / dismount |
| O / N | Leave dungeon / skip rest |
| F1 / F9 / F10 / F11 / Esc | Guide / Lite graphics / High–Ultra / Full screen / Settings |

## Saves and logs

| What | Where |
|---|---|
| Characters, saves, settings | `~/.local/share/liveworld-rpg` |
| Startup log | `~/.local/state/liveworld-rpg/startup.log` (the previous run is kept as `startup.log.1`) |

The world saves every 30 seconds and when you quit.

## Troubleshooting

| Problem | Fix |
|---|---|
| Window opens then closes | Read `~/.local/state/liveworld-rpg/startup.log`. If pygame is missing, run `sudo apt install python3-pygame python3-numpy`. |
| The game closes when you click Accept, Decline or another window button | Fixed in 1.0.11 (sound is driven from the main thread only). If it still happens, run `LIVEWORLD_NO_AUDIO=1 liveworld-rpg` and send `~/.local/state/liveworld-rpg/startup.log`; a crash in a library now leaves a Python traceback there. |
| "Already running" | Only one copy can use a save at a time. Switch to the open window. |
| Slow or choppy | Press F9 to step graphics between Lite, Normal and High. Movement uses real elapsed time (0.46.24), so speed stays correct on a slow PC. |
| HUD hidden under a desktop panel | Esc → Settings → Display → Borderless or Window |
| Nights too dark | Raise Brightness in Settings. |
| "IN COMBAT" won't go away | Fixed in 0.46.13. Stop attacking and stand still for 10 seconds, then walk away from the monster. |
| Mana does not refill in a fight | Intended since 0.46.29. Carry Mana Potions (J), or equip the Meditation passive (level 50, Skill Shop). |

## Uninstall

```bash
sudo apt remove liveworld-rpg
```

You can also use **Uninstall LiveWorld RPG** in the applications menu. It asks whether to keep or delete your saves.

## Rebuilding the .deb

The package is plain files, so you can unpack and rebuild it:

```bash
dpkg-deb -R liveworld-rpg_1.0.11_all.deb liveworld-rpg-1.0.11
dpkg-deb --root-owner-group --build liveworld-rpg-1.0.11 liveworld-rpg_1.0.11_all-rebuilt.deb
```

A rebuilt package installs the same files. Its SHA-256 will not match the published one, because file timestamps inside the archive differ. Check the published .deb against the hash above, not a rebuilt one.

## Building from source

```bash
tar xzf liveworld-rpg-1.0.11-source.tar.gz
cd liveworld-rpg-1.0.11
./build.sh --test
```

`build.sh --test` runs the 74 smoke tests (about 3 to 5 minutes, using temporary save folders, never your real saves), then writes the `.deb`, the source archive and `SHA256SUMS-1.0.11.txt` to `dist/`. It needs `dpkg-deb`, `python3`, `python3-pygame` and `python3-numpy`; the `.docx` guide is skipped unless Node.js with the `docx` module is installed.

## Recent changes (1.0.x and 0.46.x)

- **1.0.11**: Quest tooltips at Quest Givers and Mayors. Main-thread-only sound (button-click crash). Slain guards return. Crash trace in `startup.log`. Safer layout cache.
- **1.0.0 to 1.0.10**: see "What's new" above.

- **0.46.42**: Hardening against damaged or hand-edited saves; new save folders are private.
- **0.46.41**: The Waygate window wraps its text and fits its list of cities.
- **0.46.40**: The Settings key list wraps inside its panel.
- **0.46.39**: Class flavour: shadow spells wither, holy spells leech healing, poison spells poison over time.
- **0.46.38**: Hover details for skills, passives, class cards, the Trade Market, drops and Armory supplies. Spell elements (cold, fire, electric, earth). Readable Stable cards and animated mounts. Forge shows Power against what you wear.
- **0.46.37**: "Ask to join party" and "Dismiss from party" side by side.
- **0.46.36**: Waygates in every zone's major city (50 gold and a Scroll of Teleportation). City raids field 24 attackers.
- **0.46.35**: Town guards attack enemy-faction adventurers inside their walls.
- **0.46.34**: Battle mounts are ridden only in battlegrounds.
- **0.46.33**: Market return hardening, one click sound for every button, PvP rank on the HUD.
- **0.46.32**: Battlegrounds last 4 minutes (12v12) and 8 minutes (24v24). Darker stone for buildings, walls and cover.
- **0.46.31**: Mana grows 6 per level and regenerates out of combat. Capture the Flag is first to 3 captures.
- **0.46.30**: Third passive slot at level 75.
- **0.46.29**: Mana no longer refills by itself in combat. New Meditation passive (level 50). Collapsible quest tracker.
- **0.46.25**: Weapon icons match the weapon everywhere.
- **0.46.24**: Movement uses real elapsed time.
- **0.46.14**: Smaller package. The leftover Python cache file is no longer included. No gameplay changes.
- **0.46.13**: "IN COMBAT" can no longer get stuck. It clears after 10 seconds with no hits, no spells and no movement.
- **0.46.12**: The big gold `?` quest dots are gone from the minimap. The Quest Giver window no longer overlaps its messages.
- **0.46.11**: Gear and Mats tabs show only their own list. Quest tooltips added. Fishing messages now show on screen.
- **0.46.10**: One tooltip style everywhere, and tooltips fade when the mouse leaves.
- **0.46.9**: Gear tooltips in the War Hall and the vault.
- **0.46.8**: Alliance cities are blue and Horde cities are red.
- **0.46.7**: The War Hall name plate sits above the roof.
- **0.46.4–0.46.6**: Magic monsters (Arcane Dust droppers) appear in every zone, with violet markings. Existing saves get them too.
- **0.46.3**: A pickup notice for every item, coloured by rarity.
- **0.46.1–0.46.2**: Pulsing gold quest areas on the maps replace the misleading quest dots.
- **0.46.0**: Magic Shop, Forge upgrades +1 to +5, six-piece sets with 2/4/6-piece bonuses, Mythic bonuses, new spell and weapon effects.

The full history is in the package description (`apt show liveworld-rpg`) and in `/usr/share/metainfo/liveworld-rpg.metainfo.xml`.
