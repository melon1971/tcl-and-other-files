README

LocSec  ·  masterhelp.tcl  ·  Indexed Eggdrop Scripts
This README documents three groups of independent components:
    1. LocSec — a Linux host security daemon and dashboard (package locsecd, v4.0.11-67).
    2. masterhelp.tcl — an Eggdrop IRC bot script that provides the !bhelp help menu.
    3. The Eggdrop scripts it indexes — the OS reference, game, IRC-tool, and utility scripts that !bhelp points users to.
LocSec and the Eggdrop scripts are unrelated pieces of software; they are documented together here for convenience.
LocSec — Local Host Security Daemon
Version 4.0.11-67 · Package: locsecd · License: GPL-3.0-or-later
LocSec is a 24/7 security daemon and web/desktop dashboard for a single Linux host. Rather than reimplementing security tools, it coordinates the standard ones — firewall, intrusion detection, malware scanning, file-integrity monitoring, and package/CVE auditing — and puts them behind one dashboard served at 127.0.0.1:8765.
It does not phone home, and it contains no AI component: nothing in the package contacts a language model.
What it does
Area	What LocSec does	Backed by
Firewall & auto-blocking	Blocks IPs/CIDRs after repeated failed logins (default: 5 in 15 min) or port-scan behaviour (8 closed ports in 10 min). Blocks expire automatically (default 30 days). Private/loopback networks are never auto-blocked.	UFW (primary), nftables (fallback)
Fallback firewall	If UFW is installed but inactive, installs its own default-deny input chain after ~2 minutes. It never force-enables UFW, so remote installs can't lock you out.	nftables
Threat intelligence	Refreshes IOC feeds every 12 h over HTTPS only, auto-blocks listed addresses (capped per refresh), and checks domains/IPs/URLs against the local copy.	Feeds + local cache
Malware scanning	Daily ClamAV scan of /home (configurable). Infected files can be quarantined, restored (SHA-256 verified), or deleted.	ClamAV
File-integrity monitoring	Weekly AIDE check with a plain-language explanation of each change, including whether a package install explains it. Baseline create / accept / rebuild workflow.	AIDE
Hardening audit	Weekly Lynis run; reports the hardening index, warnings, and suggestions.	Lynis
Rootkit detection	Weekly rkhunter run with warning classification (benign vs. needs-review) and an ignore list for known-good items.	rkhunter
CVE & update auditing	Weekly CVE scan (debsecan on Debian/LMDE, pending APT security updates everywhere). Applies security updates automatically every 12 h.	debsecan, APT, unattended-upgrades
Network inspection	Live connections and listening ports; bounded packet capture and tshark analysis (sandboxed).	tcpdump, tshark, iproute2
Incident timeline	Every block, scan finding, and login event in one place, with plain-words Explain, Fix it (where a safe automatic fix exists), and Mark solved. Repeats fold into one open incident.	Built-in rules
Log readability	Rewrites auth, UFW, AIDE, rkhunter, ClamAV, and system logs into labelled rows (Fine / Note / Heads up / Problem) with a What to do fix for each problem.	journald / rsyslog files
System hardening	Applies kernel/network sysctl hardening and blocks unused protocol modules (dccp, sctp, rds, tipc). Deliberately skips settings that break VPNs, IPv6, Flatpak, or SysRq.	sysctl, modprobe

Heavy scans run one at a time, at low CPU/IO priority, and only when the machine has been idle (load ≤ 1.0 for 10 min). Real-time protection (login monitoring, blocking) never waits for idle.
Dashboard
Open it with:
locsecctl gui
or browse to http://127.0.0.1:8765/dashboard. Pages:
    • Overview — protection status, missing tools, exposure card (firewall policy, network-facing services, SSH logins, disk encryption)
    • Firewall & Blocks — UFW control, manual block/unblock, every block explained
    • Login Activity — auth successes/failures and block threshold
    • Incidents — timeline, response policy toggles, notifications
    • Scans & CVEs — run scans, schedule table, update system, AIDE baseline actions
    • Malware / Quarantine — quarantine, restore, delete
    • Threat Intelligence — feed refresh and indicator lookup
    • Ports & Capture — connections, listening ports, packet captures
    • Services — systemd unit control (with protections for units your access depends on)
    • Reports — recent JSON reports (auto-deleted after 7 days)
    • Logs — plain-words log viewer
    • Troubleshooting / Help — built-in reference

A shield panel icon (blue = running, amber = stopped/failed) starts at every graphical login. Without PyQt6 (Ubuntu 22.04 / Mint 21), the launcher opens the dashboard in your default browser using a single-use, 60-second login code.
Command line
locsecctl status                  # service status
locsecctl start | stop | restart  # control the service
locsecctl scan                    # full scan now
locsecctl scan-aide | scan-lynis | scan-rkhunter | scan-clamav | scan-debsecan | scan-ports
locsecctl cve                     # CVE scan now
locsecctl update                  # apply system updates now
locsecctl feed-update             # refresh threat feeds now
locsecctl aide-init               # create AIDE baseline only if none exists
locsecctl aide-accept             # promote pending AIDE baseline after review
locsecctl aide-reinitialize       # rebuild and replace the AIDE baseline
locsecctl logs                    # last 200 journal lines
locsecctl uninstall               # staged uninstall (--keep-tools, --all, --dry-run, -y)
A local JSON API is also available; every request needs the root-only token in an X-LocSec-Token header (/var/lib/locsecd/api.token).
Default schedule
Job	Cadence
AIDE, Lynis, debsecan, rkhunter, ports snapshot, CVE scan	Weekly, one per day (staggered)
ClamAV	Daily
Security updates	Every 12 hours
Virus & rootkit definitions	Daily
Threat-intelligence feeds	Every 12 hours

Anything started manually runs immediately and ignores the schedule.
Security model
    • Local only. Dashboard and API bind to 127.0.0.1; the setting is pinned. Requests with a foreign Host header are refused (anti DNS-rebinding), and cross-site POSTs are rejected.
    • Token-authenticated. Every endpoint requires the per-install token. Sessions use an HttpOnly, SameSite=Strict cookie that expires after 8 h idle / 3 days.
    • Sandboxed daemon. Runs as root under a restrictive systemd sandbox: read-only /usr, /boot, /etc, and /home; capabilities limited to CAP_DAC_READ_SEARCH, CAP_NET_ADMIN, CAP_NET_RAW; NoNewPrivileges; 2 GB memory cap.
    • Privileged work is isolated. Tools that need more access run in separate, time-limited transient units from a fixed command allowlist. Nothing from the dashboard or API is passed to a shell.
    • Guardrails. Allowlisted networks are never auto-blocked; quarantine refuses system paths unless forced and never follows symlinks; the Services page can't stop ssh, networking, dbus, polkit, the display manager, or LocSec itself.
    • Bounded storage. Reports, captures, incidents, and blocks all have age and count limits.
    • Outbound traffic is limited to threat feeds, APT repositories, and ClamAV signature updates.
    • Releases are not signed. Verify a .deb by hash or rebuild from source you trust.

Supported systems
    • Debian 12, 13 · LMDE 6, 7
    • Ubuntu 22.04, 24.04, 26.04 LTS and derivatives
    • Linux Mint 21, 22 (tested on 22.3)

Architecture: amd64 · Requires: Python ≥ 3.10
Install
sudo apt install -y ./locsecd_4.0.11-67_amd64.deb
Use apt install, not dpkg -i, so dependencies resolve automatically. The daemon starts within a minute or two (ClamAV downloads its first signatures during install).
Hard dependencies: ufw, nftables, aide, lynis, debsecan, rkhunter, clamav (+ daemon and freshclam), tshark, tcpdump, iproute2, procps, lsof, net-tools, apt, unattended-upgrades, ca-certificates, pkexec, polkitd, sudo
Recommended: python3-pyqt6, python3-pyqt6.qtwebengine (desktop window), rsyslog, xdg-utils, libnotify-bin
What the installer does
    • Creates /var/lib/locsecd and locks /etc/locsecd/locsecd.conf to mode 0600
    • Migrates config on upgrade (adds new keys; keeps values you changed)
    • Configures ClamAV excludes and runs the first freshclam
    • Disables Debian's daily AIDE timer (LocSec runs AIDE weekly itself) and installs a lock-sharing drop-in in case you re-enable it
    • Applies kernel/network hardening and blocks four unused protocol modules
    • Enables and starts locsecd.service

It never force-enables UFW and never touches fail2ban.
After install — first steps
    1. Open the dashboard: locsecctl gui
    2. Check the Overview page for anything missing.
    3. Create the AIDE baseline: Scans → Rebuild AIDE baseline, or sudo locsecctl aide-init.
Key files
Path	Purpose
/etc/locsecd/locsecd.conf	Main configuration (JSON) — edit, then sudo systemctl restart locsecd
/etc/locsecd/runtime-policy.json	Response toggles saved from the Incidents page
/var/lib/locsecd/	State: blocks, reports, captures, quarantine, incidents, API token
/var/log/locsecd/locsecd.log	Daemon log (rotated daily, 14 kept)
/usr/lib/locsecd/locsecd.py	Daemon and embedded dashboard
/usr/bin/locsecctl	Command-line control script

Common configuration keys
Key	Default	Meaning
auto_block	true	Master switch for automatic blocking
auth_threshold / auth_window	5 / 900	Failed logins in the window that trigger a block
scan_detect / scan_ports	true / 8	Port-scan blocking
fallback_firewall	true	Own default-deny firewall while UFW is inactive
fallback_allow_tcp	[]	Ports the fallback firewall leaves open, e.g. [22]
scan_interval	604800	Weekly scan cadence (seconds)
clamav_scan_paths	["/home"]	What ClamAV scans
auto_update / update_security_only	true / true	Automatic security-only updates
block_ttl_days	30	Block lifetime
report_retention_days	7	Report lifetime

See the Installation Guide (Section 6) for the full list.
Remote install tip: if you manage this host over SSH while UFW is inactive, set fallback_allow_tcp to include your SSH port (e.g. [22]) so the fallback firewall doesn't cut you off.
Uninstall
sudo apt remove locsecd        # keeps config and state
sudo apt purge locsecd         # removes config and state
locsecctl uninstall --dry-run  # preview a staged removal, incl. tools LocSec brought in
Removing LocSec turns Debian's daily AIDE check back on. If you still have the older aisentryd package, remove it before installing LocSec — automatic migration was dropped in 4.0.11-67.
Documentation
Full details — configuration reference, scan behaviour, troubleshooting, AIDE coordination, release history, and building from source — are in LocSec-Installation-Guide-4_0_11-67.docx.
masterhelp.tcl — Eggdrop Help Menu Script
masterhelp.tcl is an Eggdrop IRC bot script that provides the bot's top-level !bhelp menu. It is a signpost: it lists the help commands that other scripts on the bot own and answer, and it deliberately does not touch those scripts.
Users type !bhelp in a channel and get a short list of categories. Each category trigger (for example !oshelp) prints its own sub-list, and the entries in that sub-list (for example !debhelp) are answered by the individual scripts.
How the menu is organised
!bhelp
├── !oshelp         OS / handbook command references
├── !gamehelp       Bot games (an index of four sub-categories)
│   ├── !sportgamehelp
│   ├── !fightgamehelp
│   ├── !cardgamehelp
│   └── !othergamehelp
├── !irchelp        IRC / network services and channel tools
└── !otherhelp      Everything else
!bhelp and the eight category triggers above are the only triggers this script binds. The entries listed beneath them are owned and answered by other scripts.
Entries listed under each category
Category	Listed help triggers
!oshelp	!archhelp, !bsdhelp (also !fbsdhelp/!obsdhelp/!nbsdhelp), !buntuhelp, !debhelp, !linuxhelp, !susehelp, !winhelp
!sportgamehelp	!baseballhelp, !bowlhelp, !duckhunthelp, !fishhelp, !golfhelp, !homerunhelp
!fightgamehelp	!bshiphelp, !fighthelp, !mafiahelp, !riskhelp
!cardgamehelp	!bjhelp, !casinohelp, !cribbagehelp, !pokerhelp
!othergamehelp	!cluehelp, !lifehelp, !monohelp, !openrpghelp, !scrabblehelp, !stairshelp
!irchelp	!dalhelp, !guardhelp, !restricthelp, !spyhelp, !whohelp
!otherhelp	!comhelp, !converthelp, !poemshelp, !talkbothelp (also covers !dcchelp and !costhelp)

After every menu or sub-list the script prints one footer line: "If a !help command does not work, the bot may not be on this network."
The menu is a plain list of strings. It has no link to any real bind, so an entry whose script is removed or renamed will keep appearing and silently stop working. Before adding an entry, confirm the target script really binds that trigger (look for its bind pub line).
What the script does
    • Prints the menu and sub-lists for !bhelp and the eight category triggers.
    • Restricts where it answers with a channel allow-list.
    • Chooses how it replies — in the channel, by NOTICE, or by private message — for everyone, switchable at runtime by the bot owner.
    • Rate-limits users so the menu can't be used to flood the bot.
    • Survives rehashes cleanly — no duplicate binds, duplicate timers, or lost cooldown state.

Commands
Command	Who	Effect
!bhelp	Everyone (default flags -|-)	Print the top-level category menu
!oshelp !gamehelp !irchelp !otherhelp	Everyone	Print that category's sub-list
!sportgamehelp !fightgamehelp !cardgamehelp !othergamehelp	Everyone	Print that game sub-category's list
!bhelp mode	Everyone	Show the current output mode and channel scope (read-only)
!bhelp set <channel|msg|notice>	Bot owner (flag n) only	Change where !bhelp answers, for every caller, until changed again

Accepted aliases for msg: pm, dm, privmsg, private. A non-owner who tries !bhelp set … is told only the owner can do that. Runtime changes are written to the bot log.
Installation
    1. Copy masterhelp.tcl into your Eggdrop scripts/ directory.
    2. Add this line to eggdrop.conf:
source scripts/masterhelp.tcl
    3. Edit the settings below (at minimum, channel), then rehash or restart the bot:
.rehash
On load, the bot logs a line such as:
masterhelp.tcl loaded (trigger=!bhelp, flags=-|-, output=notice): 4 categories, 8 category triggers bound
Configuration
All settings live in the namespace eval masterhelp { … } block at the top of the file. Edit them and .rehash.
Setting	Default	Meaning
trigger	!bhelp	The top-level command
flags	-|-	Who may use the commands: -|- everyone, o ops, n owner, etc. Applies to !bhelp and all eight category triggers.
channel	#prototype #mafia #debian	Channels where the help commands answer. Space-separated, case-insensitive. * or all means every channel. Empty disables public replies. Change this to match your own channels.
output	notice	Reply mode: channel, msg, or notice. Also changeable at runtime with !bhelp set. Survives a rehash.
ratelimit_secs	15	Seconds a user must wait between uses
ratelimit_scope	both	global (one shared cooldown per user), percmd (one per command per user), or both (must clear both)
ratelimit_cleanup_secs	3600	How often stale cooldown entries are swept (seconds)
ratelimit_maxentries	5000	Hard cap on cooldown table size; the oldest entry is evicted when the cap is reached
menu	four categories	Top-level list, as {trigger "description"} entries
categories	see above	Each category's sub-list, same shape
footer	"If a !help command does not work…"	Printed once after every list

Invalid values for ratelimit_*, output, or an empty trigger are logged and forced to a safe default rather than failing silently.
Maintaining the menu
Add an entry to an existing category
    1. Confirm the other script actually binds the trigger.
    2. Add a {!newhelp "description"} line to the right sub-list in $categories, keeping the list in alphabetical order by trigger.
    3. .rehash.
Add a new category
    1. Add a line to $menu and a matching {!newcat { … }} block to $categories.
    2. Add a one-line proc (masterhelp::newcat_cmd) that calls masterhelp::cmd_category "!newcat" $nick $host $hand $chan.
    3. Add the trigger and proc to the bind list near the bottom of the file.
    4. .rehash.
Keep each description short: IRC messages are limited to 512 bytes, and this script truncates every outgoing line to 400 characters.
Design notes
    • Leaf help triggers are not bound here. Scripts such as dalnet.tcl, whois.tcl, fight.tcl, and talkbot.tcl own their own help commands and answer them directly. This script only points users at them.
    • Config uses set, state uses variable. Configuration values are plain set, so edits take effect on rehash. output, the cooldown tables, and the bind-tracking variables use a guard so they keep their values across a rehash.
    • No leaked binds or timers. The script records what it actually bound (bound_trigger, bound_flags, bound_subtriggers) and unbinds those exact registrations on reload, so editing trigger or flags doesn't leave the old bind active. The cleanup timer is likewise cancelled and rescheduled each load.
    • Output is sanitised. Carriage returns, newlines, and \001 characters are stripped and lines are capped at 400 characters, so menu text can't inject IRC commands or CTCP.
    • Bounded memory. User IDs (nick!host) are truncated, the cooldown tables are size-capped, and an hourly sweep drops entries older than two hours (or twice the cooldown, if larger).
    • Whitespace-safe parsing. Arguments are tokenised with a \S+ scan, so !bhelp set  channel (two spaces) works.

Requirements
    • Eggdrop with Tcl 8.5 or later (the script uses lassign and the ni operator)
    • The other help scripts you list in the menu, if you want those entries to answer

Eggdrop Scripts Indexed by masterhelp.tcl
These are the scripts that !bhelp points to. Each one answers its own help trigger; masterhelp.tcl only lists them. Where a script has a separate data file, it is listed with it. Everything is sourced from eggdrop.conf the usual way (source scripts/<file>.tcl, then .rehash).
Several scripts are third-party and keep their original authors and licences: Duck_Hunt.tcl (Menz Agitat), BlackScrabble.tcl, and StairsAndSlides.tcl (TCLScripts.NET).
!oshelp — OS command references
Each reads its topics from a matching *_data.tcl file, so you can add or change topics without touching the bot logic.
Trigger	Files	Summary
!archhelp	archhelp.tcl, arch_data.tcl	Arch Linux install, pacman, AUR, systemd, network
!bsdhelp	bsdhelp.tcl, bsd_data.tcl	FreeBSD / OpenBSD / NetBSD (also !fbsdhelp, !obsdhelp, !nbsdhelp)
!buntuhelp	buntuhelp.tcl, buntu_data.tcl	Ubuntu apt, snap, sources, systemd, network
!debhelp	debhelp.tcl, deb_data.tcl	Debian apt, sources, systemd, network, disks
!linuxhelp	linuxhelp.tcl, linux_data.tcl	General, distro-agnostic Linux shell and userland
!susehelp	susehelp.tcl, suse_data.tcl	openSUSE zypper, repos, YaST, systemd
!winhelp	winhelp.tcl, win_data.tcl	Windows commands, winget, setup, recovery

!gamehelp — Games
Trigger	Files	Summary
!baseballhelp	baseball.tcl, baseball_data.db	Hall-of-Fame baseball: draft teams, play exhibitions or a full season (default trigger !bb)
!bowlhelp	bowling.tcl	!bowl — USBC ten-pin bowling with frame scoring
!duckhunthelp	Duck_Hunt.tcl, duck_hunt/	!duckhunt — shoot ducks, reload, shop, stats (third-party)
!fishhelp	fishing.tcl	!fish — fishing RPG with levels 1–500, gear, bait, boats, monthly tournament; SQLite-backed
!golfhelp	golf.tcl	!golf — 9/18-hole rounds, weather, gear shop, hole-in-one tournament
!homerunhelp	homerunsmash.tcl	All-day pitch-and-swing minigame
!bshiphelp	battleship.tcl	!battleship — two-player, fleets placed by private message
!fighthelp	fight.tcl, fight.db	!fight — blind-commit fighting game: both players secretly pick an attack and a guard
!mafiahelp	mafia.tcl, Mafia.cfg	!mafia — crime/RPG game; SQLite-backed, settings in Mafia.cfg
!riskhelp	risk.tcl	!risk — classic Risk for 2–6 players, CPU fills empty seats
!bjhelp	blackjack.tcl	!blackjack — multiplayer blackjack with betting
!casinohelp	casino.tcl	!slots, !cards, !points, !give, !top10
!cribbagehelp	cribbage.tcl	!crib — two-player cribbage, or solo against the bot
!pokerhelp	poker.tcl	!poker — play-money Texas Hold'em
!cluehelp	clue.tcl	!clue — Clue/Cluedo deduction game
!lifehelp	life.tcl	!life — The Game of Life, 2–4 players
!monohelp	monopoly.tcl	!mono — Monopoly, up to 4 players
!openrpghelp	openrpg.tcl, orpg_players.db	!openrpg — open-world RPG (races, classes, spells, dungeons, raids)
!scrabblehelp	BlackScrabble.tcl, Scrabble.db	!scrabble — word game (third-party)
!stairshelp	StairsAndSlides.tcl	!stairs — stairs and slides board game (third-party)

!irchelp — IRC and channel tools
Trigger	Files	Summary
!dalhelp	dalnet.tcl, dalnet_help.db, optional sendnotice.tcl	DALnet ChanServ/NickServ/MemoServ help (!cshelp, !nshelp, !mshelp, !csend, !nsend, !msend). Answers come from the local .db file, not from services. sendnotice.tcl adds a separate rate limit for the !*send commands.
!guardhelp	guard.tcl, guard.state	Join monitor: WHOIS-checks new joiners and bans (timed, default 24 h) users found in a designated channel. Bans are listable and removable with .guard or !guard.
!restricthelp	restrict.tcl (header: autorestrict.tcl)	Sets channel +R after a kick from a trusted source, then removes it after 15 minutes (45 if repeated). .autorestrict on the partyline for status/off/clear.
!spyhelp	spychan.tcl	Botnet relay: leaf bots on other networks relay joins/parts/quits/splits to a home channel
!whohelp	whocom.tcl	!wi, !wa, !pi, !ver, !dom, !ip lookups

!otherhelp — Everything else
Trigger	Files	Summary
!comhelp	com.tcl	Admin-only !brestart, !brehash, !bdie, !bchans
!converthelp	convert.tcl	Temperature, currency, mass, distance, volume. Enable per channel with .chanset #channel +convert.
!poemshelp	melons_poems.tcl	!poem, !poems, !autopoem; #poets only
!talkbothelp	talkbot.tcl, optional talkbot_cost.tcl	AI persona that replies when the bot is mentioned (OpenAI API), plus !talkbotfacts, !talkbotpic, !dcchelp. talkbot_cost.tcl adds !cost / !costhelp spend reporting and must be sourced after talkbot.tcl.

Setup notes
    • talkbot needs an OpenAI API key. Put it in scripts/talkbot_apikey.txt (chmod 600) and leave the inline apikey variable empty. Only users with an access flag (+f, +o, +m, +n by default) get replies.
    • Data files (*.db, guard.state, Mafia.cfg) are created or edited by their scripts; back them up with the bot.
