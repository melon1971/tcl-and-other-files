This README documents five groups of independent components:

1. **[LocSec](#locsec--local-host-security-daemon)**: a Linux host security daemon and dashboard (package `locsecd`, v5.0-1).
2. **[masterhelp.tcl](#masterhelptcl--eggdrop-help-menu-script)**: an Eggdrop IRC bot script that provides the `!bhelp` help menu.
3. **[The Eggdrop scripts it indexes](#eggdrop-scripts-indexed-by-masterhelptcl)**: the OS reference, game, IRC-tool, and utility scripts that `!bhelp` points users to.
4. **[Eggdrop on Debian 13 (Trixie)](#eggdrop-on-debian-13-trixie--package-requirements)**: the apt packages the full Eggdrop script set needs, by script.
5. **[LiveWorld RPG](#liveworld-rpg--offline-fantasy-rpg)**: an offline isometric fantasy RPG for Debian-based Linux (package `liveworld-rpg`, v0.46.42).

LocSec, the Eggdrop scripts and LiveWorld RPG are unrelated pieces of software. They are documented together here for convenience.

---

# LocSec — Local Host Security Daemon

**Version 5.0-1** · Package: `locsecd` · 

> **Release status: production release (5.0-1).** Reported by the tester: about three weeks of continuous use through every scan and upgrade on Debian 13 (GNOME and KDE Plasma) and Linux Mint 22 (Cinnamon), with logs correct and `locsec-vm-check.sh` passing. 5.0-1 is the 4.0.11-103 code with a new version number. **Ubuntu (24.04, 26.04, 26.10), Debian 12 and LMDE are expected to work but have not been run yet**; Mint 22 is built on Ubuntu 24.04, so most of the path is shared. Still true: releases are unsigned (check SHA256SUMS), no third-party security review is recorded here, and the AppArmor profiles are not loaded.
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

**5.0-1 is a production release.** Its code is 4.0.11-103; only the version and the documentation changed (see the 5.0-1 changes below).

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
1. A fresh install with `sudo apt install ./locsecd_5.0-1_amd64.deb`, and an upgrade from 4.0.11-88 and from -101. Neither may stop at a prompt about `/etc/clamav/clamd.conf`, and `systemctl is-active clamav-daemon` says `active` within a few minutes of the first signature download.
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

**Known open items in 5.0-1 (unchanged from 4.0.11-103):**
- The AppArmor profiles (`locsecd-web` and `locsecd-broker`, since -100) are examples: not installed or loaded by the package, in complain mode, and not yet loaded on a real kernel. From -103 the units do not name them.
- Purge still leaves LocSec's edits in `/etc/suricata/suricata.yaml` (the original is kept as `suricata.yaml.locsec-orig`), and the rule-files rewrite on a non-default rule path is untested.
- The broker can still start job units with full root, but only the ones its verbs define. It keeps `CAP_DAC_READ_SEARCH`, `CAP_NET_ADMIN`, `CAP_NET_RAW` and `CAP_SETGID`.
- Releases are unsigned, and there has been no independent security review.

---

## Install

```bash
sudo apt install -y ./locsecd_5.0-1_amd64.deb
```

Use `apt install` from a terminal, not `dpkg -i` or GDebi, so dependencies resolve automatically.
- The install finishes straight away.
- ClamAV downloads its first signatures, and Suricata sets itself up, in the background afterwards.
- An existing 4.0.11 install upgrades in place to 5.0-1 with the same command.

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

`LocSec-Installation-Guide-4_0_11-102.docx` has the full details:
- configuration reference
- scan behaviour
- Suricata
- security model
- troubleshooting
- AIDE coordination
- release history through 5.0-1
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

### Release files and integrity

LocSec releases are **not signed**. Compare these SHA-256 hashes, or rebuild from source you trust, before installing a copy of unknown origin:

```
81de57c36faadbb3f3e5c779cbf46bb2f27c90ffb0d0d73832c0cb9796e42925  locsecd_5.0-1_amd64.deb
75d8a44e87940f514195dd8e02690b459fde138720fb827366402a714f81dbfc  locsecd-5.0-1-source.tar.gz
aa923b6271ab5c9756d84e6a023149739f58d7ba35cbe9d3b88041e45293cb7b  LocSec-Installation-Guide-5_0-1.docx
```

### Building from source

The source tarball is the package tree itself (`DEBIAN/` plus `etc/`, `lib/`, `usr/`, `var/`). The only build tool is `dpkg-deb`:

```bash
tar xzf locsecd-5.0-1-source.tar.gz
cd locsecd-5.0-1-source       # edit, then refresh checksums (tests/ is not part of the package):
find . \( -path ./DEBIAN -o -path ./tests \) -prune -o -type f -print | sed 's#^\./##' | sort | xargs md5sum > DEBIAN/md5sums
cd ..
python3 locsecd-5.0-1-source/tests/check_broker.py locsecd-5.0-1-source/usr/lib/locsecd/locsecd.py
rm -rf build && mkdir build && cp -a locsecd-5.0-1-source build/pkg && rm -rf build/pkg/tests
dpkg-deb --root-owner-group -Zzstd --build build/pkg locsecd_5.0-1_amd64.deb
sudo apt install ./locsecd_5.0-1_amd64.deb
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

**Version 0.46.42** · Package: `liveworld-rpg`

LiveWorld RPG is an offline, single-player fantasy RPG with isometric 2.5D graphics, written in Python with pygame. You play in a large living world with 12 classes, instanced dungeons and raids, PvP battlegrounds, crafting, gathering, fishing, mounts, and about 640 computer-controlled adventurers.

For the full player's guide, see `LiveWorld-RPG-Guide.md`, or press **F1** in the game.

## What's new in 0.46.42

- **Hardening.** Damaged or hand-edited saves can no longer crash quest, mount, market, build or party lookups. Unknown mounts in a save are dropped, new save folders are private, and dead drawing code and unused constants are removed.

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
| `liveworld-rpg_0.46.42_all.deb` | Installable Debian package (architecture `all`, 380,032 bytes) |
| `LiveWorld-RPG-Guide.md` | Player's guide, the same text as the in-game guide (F1) |

## Verify the download

Compare the SHA-256 of the package with this value:

```bash
sha256sum liveworld-rpg_0.46.42_all.deb
```

```
2ad9e164cfcb6dcb94c1bbeb01bc3e3d9696d2aa0056b251eaa2de16e344e3c8  liveworld-rpg_0.46.42_all.deb
```

## Requirements

- Debian, Ubuntu, Linux Mint or another Debian-based Linux (any CPU)
- `python3`, `python3-pygame`, `python3-numpy` (apt installs these for you)
- Recommended: `x11-utils` for correct full-screen sizing

## Install

```bash
sudo apt install ./liveworld-rpg_0.46.42_all.deb
```

Keep the `./` so apt installs the local file and fetches the dependencies. Installing over an older version keeps your saves. If you used `dpkg -i` and it reported missing packages, run `sudo apt -f install`.

## Play

Start it from **Applications → Games → LiveWorld RPG**, or run:

```bash
liveworld-rpg
```

The first start builds the world (about half a minute). Later starts use a cache.

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
dpkg-deb -R liveworld-rpg_0.46.42_all.deb liveworld-rpg-0.46.42
dpkg-deb --root-owner-group --build liveworld-rpg-0.46.42 liveworld-rpg_0.46.42_all-rebuilt.deb
```

A rebuilt package installs the same files. Its SHA-256 will not match the published one, because file timestamps inside the archive differ. Check the published .deb against the hash above, not a rebuilt one.

## Recent changes (0.46.x)

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
