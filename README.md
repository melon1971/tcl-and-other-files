# Tcl and Other Files

A curated collection of **Eggdrop IRC bot scripts**, **Linux security hardening tools**, and **supporting packages and documentation**. The projects target Debian and Ubuntu-based systems (the Eggdrop scripts also run on openSUSE and FreeBSD/GhostBSD) and cover three areas:

- **IRC automation:** channel protection, services helpers, an AI chat bot, OS reference lookups, and more than 20 multiplayer channel games for Eggdrop.
- **Host security:** the Scanistry security daemon and dashboard, kernel hardening profiles, and validation tooling.
- **Desktop gaming:** LiveWorld RPG, an offline isometric fantasy RPG distributed as a Debian package.

---

## Table of Contents

1. [Repository Layout](#repository-layout)
2. [Eggdrop Scripts](#eggdrop-scripts)
   - [Channel Protection and Moderation](#channel-protection-and-moderation)
   - [IRC Services and User Lookup](#irc-services-and-user-lookup)
   - [Bot Administration and Utilities](#bot-administration-and-utilities)
   - [AI Chat](#ai-chat)
   - [Operating System Reference Help](#operating-system-reference-help)
   - [Games](#games)
   - [Stock Eggdrop Scripts](#stock-eggdrop-scripts)
   - [Data, State, and Supporting Files](#data-state-and-supporting-files)
3. [Eggdrop Requirements](#eggdrop-requirements)
4. [Installing Eggdrop on Debian 13 (Trixie)](#installing-eggdrop-on-debian-13-trixie)
5. [Scanistry Security Suite](#scanistry-security-suite)
6. [LiveWorld RPG](#liveworld-rpg)
7. [Documentation](#documentation)
8. [Release Checksums](#release-checksums)
9. [Quick Start](#quick-start)
10. [Operational Notes](#operational-notes)

---

## Repository Layout

| Area | Contents | Purpose |
| --- | --- | --- |
| `scripts/` | Eggdrop Tcl scripts, data files, cron helpers | IRC bot automation, protection, utilities, and games |
| `scripts/duck_hunt/` | Duck Hunt config, databases, language packs, HTML tables | Supporting assets for `Duck_Hunt.tcl` |
| `scanistry/` | Debian package, source tarball, patch, sysctl profiles, guides | Host security daemon and system hardening |
| `liveworld/` | Debian package, source tarball, player guide | Offline isometric fantasy RPG |
| Repository root | Validation script, NetBots archives, additional guides | Environment checks and legacy bot packs |

---

## Eggdrop Scripts

All scripts are written for Eggdrop and are loaded with `source scripts/<name>.tcl` in the bot's configuration file. They are not standalone command-line programs. Unless noted, each script answers a help command in the channel that lists its full command set.

### Channel Protection and Moderation

| File | Description | Entry Point |
| --- | --- | --- |
| `guard.tcl` | Join monitor. Waits a configurable delay after a user joins, skips trusted handles and anyone holding +o/+v/+h, then sends a rate-limited WHOIS and bans and kicks users found in configured blacklisted channels. State is kept in `guard.state`. | `!guardhelp`, `.guard` |
| `restrict.tcl` | Auto-restrict. Sets channel mode +R on managed channels after a kick from a trusted source (native kick or a trusted "has been kicked" report) and respects +R set deliberately by operators. | `.autorestrict` |
| `sentinel.tcl` | Flood protection system by slennox (v2.70) with BitchX CTCP simulation. Defends against floodnets and proxy floods. | `.sentinel`, `.lock`, `.unlock` |
| `spychan.tcl` | Botnet relay (v1.4.1, home-relay build). Watches channels across multiple networks through linked Eggdrop bots and prints relayed events in a home channel. | `!spyhelp` |
| `klined.tcl` | Removes servers from the bot's server list after a K-line to avoid repeated reconnects. | DCC commands |

### IRC Services and User Lookup

| File | Description | Entry Point |
| --- | --- | --- |
| `whocom.tcl` | Lookup command pack: WHOIS, WHOWAS, CTCP PING and VERSION, domain WHOIS (raw port 43 with RDAP and HackerTarget fallbacks), and IP geolocation/ASN. Hardened with access controls and input validation. | `!whohelp` |
| `dalnet.tcl` | ChanServ, NickServ, and MemoServ help for DALnet. Answers from the local `dalnet_help.db` file and never queries the live services. | `!dalhelp`, `!cshelp`, `!nshelp`, `!mshelp` |
| `sendnotice.tcl` | Optional add-on for `dalnet.tcl`. Adds a separate rate limiter for the send-to-user commands (`!csend`, `!nsend`, `!msend`). | `.sendlimit` |
| `nsf.tcl`, `nst.tcl` | DALnet NickServ auto-identify. Identifies on connect and on request, offers GHOST recovery, and re-identifies after netsplits. Includes a ping-out fix that makes recovery single-flight. The two files are identical except for the configured bot nick. | Automatic |
| `bseen.tcl` | Bass's Seen script (v1.4.2c). Records every nick seen online, with wildcard search and flood protection. | `!seen`, `.seen` |

### Bot Administration and Utilities

| File | Description | Entry Point |
| --- | --- | --- |
| `masterhelp.tcl` | Top-level help menu that points users to each script's own help command without overriding them. | `!bhelp` |
| `com.tcl` | Hardened bot control for admins: restart, rehash, and die (this bot only), with live per-channel enable and disable. | `!comhelp`, `!brestart`, `!brehash`, `!bdie`, `!bchans` |
| `mem.tcl` | One-shot memory and state diagnostic. Walks namespaces and reports array element counts and approximate size so the heaviest arrays stand out. | `.memdiag` |
| `sysinfo.tcl` | System information: distro, kernel, CPU/GPU, cores, memory, disk, and aggregate network RX/TX. Never shows IPs, MACs, interface names, or hostnames. Rate-limited, and requires +o by default. | `!sysinfo`, `.sysinfo` |
| `convert.tcl` | Unit converter (v4) for temperature, currency, mass, distance, and volume. Hardened build, enabled per channel with `+convert`. | Configurable trigger |
| `melons_poems.tcl` | Poetry bot. Indexes `.docx` poems from a configured directory and posts random or requested poems, with optional sticky auto-posting. | `!poem`, `!poems`, `!autopoem` |
| `autoscripts.tcl` | Eggdrop's script manager for installing, loading, and listing packaged scripts from the partyline. | `.script` |

### AI Chat

| File | Description | Entry Point |
| --- | --- | --- |
| `talkbot.tcl` | AI talking bot backed by the OpenAI API. Replies only when its nick is mentioned in allowed channels and only to users holding the configured access flags (+f, +o, +m, or +n by default). Inert outside its configured channels. Also provides independent random posts and a channel command bridge. | `!talkbothelp`, `!dcchelp` |
| `talkbot_cost.tcl` | API spend tracker for `talkbot.tcl`. Records token usage and web-search calls per day and per model, prices them from a user-defined table, and reports spend on demand. Must be loaded together with `talkbot.tcl`. | `!cost`, `!costhelp` |

### Operating System Reference Help

Each help system is a pair of files: a **logic** script that you source, and a **data** file that holds the topics and commands. To add or change content, edit the `_data.tcl` file only. All helpers share the same rate limiting, output-mode switch, and bind hardening.

| Logic Script | Data File | Coverage | Trigger |
| --- | --- | --- | --- |
| `archhelp.tcl` | `arch_data.tcl` | Arch Linux (Arch Wiki installation guide) | `!archhelp` |
| `bsdhelp.tcl` | `bsd_data.tcl` | FreeBSD, OpenBSD, NetBSD (official handbooks) | `!bsdhelp` |
| `buntuhelp.tcl` | `buntu_data.tcl` | Ubuntu (Server and Desktop guides, Snap, Netplan) | `!buntuhelp` |
| `debhelp.tcl` | `deb_data.tcl` | Debian (FAQ, Reference, official docs) | `!debhelp` |
| `linuxhelp.tcl` | `linux_data.tcl` | General Linux commands (ss64, linuxcommand.org, man7) | `!linuxhelp` |
| `susehelp.tcl` | `suse_data.tcl` | openSUSE Leap and Tumbleweed, Zypper, YaST | `!susehelp` |
| `winhelp.tcl` | `win_data.tcl` | Windows 10/11 commands, winget, keyboard shortcuts | `!winhelp` |

### Games

| File | Game | Highlights | Help |
| --- | --- | --- | --- |
| `mafia.tcl` | Mafia crime RPG | Crimes, drug dealing, weapons, robberies, cops, and rank progression. Settings live in `Mafia.cfg`; data is stored in `mafia.sqlite3`. | `!mafiahelp` |
| `Duck_Hunt.tcl` | Duck Hunt (v2.11, Menz Agitat) | IRC "FPS": shoot ducks as they take flight. Shop, stats, progression, English and French language packs. | `!duckhunthelp` |
| `openrpg.tcl` | Open World RPG | WoW/Angband-style character creation, exploration, and combat. | `!openrpghelp` |
| `fishing.tcl` | Fishing RPG | Freshwater and saltwater locations, levels 1–500, rarity tiers, and a Megalodon world-boss event. | `!fishhelp` |
| `fight.tcl` | Blind-commit fighting | Both fighters privately choose an attack and a guard each round; the bot resolves them simultaneously. | `!fighthelp` |
| `baseball.tcl` | Hall-of-Fame Baseball | Full 9-inning simulation with team drafting, exhibition games, and round-robin seasons. Uses `baseball_data.db`. | In-channel help |
| `homerunsmash.tcl` | HomerunSmash | All-day background pitch-and-swing minigame. | In-channel help |
| `golf.tcl` | Golf | 9 or 18 holes on random courses, weather, gear, and a Hole-in-One jackpot tournament. | `!golf` |
| `bowling.tcl` | Ten-pin bowling | Standard USBC scoring rules. | In-channel help |
| `monopoly.tcl` | Monopoly | Up to 4 players with CPU fill, full official rules, auctions, and trading. | `!mono` |
| `life.tcl` | The Game of LIFE | 2–4 players with CPU fill: careers, Pay Days, LIFE tiles, and retirement. | `!lifehelp` |
| `risk.tcl` | RISK | 2–6 players, classic 42-territory World Domination rules. | `!riskhelp` |
| `clue.tcl` | Clue / Cluedo | Full deduction game with private card disproofs. | In-channel help |
| `battleship.tcl` | Battleship | Two players, 10x10 grid, fleets placed privately by `/msg`. | In-channel help |
| `StairsAndSlides.tcl` | Stairs and Slides | Board race game (TCLScripts.NET). | `!stairshelp` |
| `BlackScrabble.tcl` | Black Scrabble (v1.2.1) | Form words from a given set of letters. Uses `Scrabble.db`. | `!scrabblehelp` |
| `poker.tcl` | Texas Hold'em | Blinds, side pots, real showdown evaluation, and persistent chips. | `!pokerhelp` |
| `blackjack.tcl` | Blackjack | Multiplayer with continuous rounds and per-channel enable/disable. | `!bjhelp` |
| `cribbage.tcl` | Cribbage | Two players or solo against the bot, with faithful scoring rules. | `!crib` |
| `casino.tcl` | Casino | Slots and hi-card gambling with a persistent points economy and top 10. | `!casinohelp` |

### Stock Eggdrop Scripts

These ship with Eggdrop itself (see `scripts/CONTENTS`) and are included for completeness.

| File | Description |
| --- | --- |
| `action.fix.tcl` | Converts DCC `/me` actions into proper `.me` output. |
| `alltools.tcl` | Library of helper procedures used by other scripts. |
| `autobotchk` | Generates a crontab or systemd entry that keeps the bot running. |
| `botchk` | Shell script for restarting the bot from cron. |
| `cmd_resolve.tcl` | Adds non-blocking `.resolve` and `.dns` partyline commands. |
| `compat.tcl` | Maps legacy Tcl commands to their current equivalents. |
| `dccwhois.tcl` | Lets all users run `.whois` on their own handle. |
| `getops.tcl` | Lets linked botnet bots request and grant ops from each other. |
| `notes2.tcl` | Checks notes across every shared bot on the hub. |
| `ques5.tcl` | Generates web pages listing who is in each channel (requires `alltools.tcl`). |
| `quotepong.tcl` | Answers EFnet `/quote pong` cookies when ident is unavailable. |
| `userinfo.tcl` | Extended user-info fields (URL, email, and similar). |
| `weed` | Prunes unwanted entries from an Eggdrop userlist. |

### Data, State, and Supporting Files

| File | Used By | Description |
| --- | --- | --- |
| `Mafia.cfg` | `mafia.tcl` | Tunable game settings. Required: the script will not load without it. |
| `mafia.sqlite3` | `mafia.tcl` | SQLite database holding Mafia game state; autosaved every few minutes. |
| `baseball_data.db` | `baseball.tcl` | Teams, rosters, schedule, stats, and standings. |
| `dalnet_help.db` | `dalnet.tcl` | Local DALnet services help text. |
| `fight.db` | `fight.tcl` | Fighter records. |
| `orpg_players.db` | `openrpg.tcl` | Saved characters. |
| `Scrabble.db` | `BlackScrabble.tcl` | Scrabble scores (created empty). |
| `guard.state` | `guard.tcl` | Persistent guard state. |
| `talkbot_cost.dat` | `talkbot_cost.tcl` | Recorded API usage and spend. |
| `talkbot_memory.dat` | `talkbot.tcl` | Conversation memory. |
| `talkbot.tcl.bak-dashes` | — | Backup copy of a previous `talkbot.tcl` revision. Do not source. |
| `duck_hunt/` | `Duck_Hunt.tcl` | `Duck_Hunt.cfg`, player and transfer databases, `en.msg`/`fr.msg` language files, shop and progression tables (HTML), background image, changelog, and documentation. |
| `netbots4.10.zip` | — | NetBots 4.10 script pack archive. |
| `netbots4.11.zip` | — | NetBots 4.11 script pack archive. |
| `netbots-4.10-to-4.11.diff` | — | Patch between NetBots 4.10 and 4.11. |

---

## Eggdrop Requirements

### Baseline

- **Eggdrop 1.8 or newer**; 1.9+ is recommended and assumed by `melons_poems.tcl`, `life.tcl`, `monopoly.tcl`, and `risk.tcl`.
- **Tcl 8.6.** Most scripts would run on 8.5, but `talkbot.tcl`'s image feature uses `binary decode base64`, which requires 8.6.

### Per-Script Requirements

| Script | Tcl Packages | External Programs / Files |
| --- | --- | --- |
| `mafia.tcl` | `sqlite3` (required) — `libsqlite3-tcl`; `sqlite-tcl` on RHEL | `Mafia.cfg` in the same directory |
| `fishing.tcl` | `sqlite3` (required) — `libsqlite3-tcl` | — |
| `masterhelp.tcl` | None | None |
| `melons_poems.tcl` | None | `unzip` (reads the `.docx` poems); configured poem directory |
| `mem.tcl` | None | Linux `/proc` for the RSS readout (optional) |
| `talkbot.tcl` | `http` (ships with Tcl); `tls` (required) — `tcl-tls`; `json` (optional, recommended) — `tcllib` | `ca-certificates`; OpenAI API key; outbound HTTPS |
| `talkbot_cost.tcl` | `json` (optional) — `tcllib` | `talkbot.tcl` loaded |
| `sysinfo.tcl` | None | `coreutils` (`uname`, `df`, `nproc`); `pciutils` (`lspci`, GPU detection); `nvidia-smi` optional; Linux `/proc` |
| `whocom.tcl` | `http`; `tls` (for `!ip` and the RDAP fallback in `!dom`) | Outbound TCP port 43 for raw WHOIS |
| `convert.tcl` | `tls` 1.7.16 or newer | Outbound HTTPS for currency rates |

All other scripts (the `*help` family, `dalnet`, `casino`, `baseball`, `fight`, `openrpg`, `spychan`, `restrict`, `guard`, `com`, and the remaining games) need no extra Tcl packages. The `*_data.tcl` files are sourced by their parent scripts.

### Package Summary (Debian/Ubuntu)

| Package | Needed By | Notes |
| --- | --- | --- |
| `eggdrop` | All scripts | IRC bot runtime |
| `tcl8.6` | All scripts | Core Tcl runtime |
| `tcl-tls` | `talkbot`, `whocom`, `convert` | HTTPS support (e.g. `api.openai.com`). `convert.tcl` needs tls 1.7.16+; Trixie ships a newer version. |
| `tcllib` | `talkbot`, `talkbot_cost` | Provides `json`. Without it, both fall back to a regex parse of the API response. |
| `libsqlite3-tcl` | `mafia`, `fishing` | Provides `package sqlite3` for their databases. |
| `ca-certificates` | `talkbot` | Supplies `/etc/ssl/certs/ca-certificates.crt` for TLS verification. |
| `coreutils` | `sysinfo` | Provides `df`, `uname`, and `nproc`. |
| `pciutils` | `sysinfo` | Provides `lspci` for GPU detection. |
| `unzip` | `melons_poems` | Extracts text from `.docx` poems. |

### Built-In Components

These need no separate package:

| Component | Used By | Notes |
| --- | --- | --- |
| `http` | `talkbot`, `whocom`, `convert` | Ships with core Tcl. |
| `msgcat` | `Duck_Hunt` | Ships with core Tcl; loads the `en.msg`/`fr.msg` language packs. |
| `md5` | Several scripts | Built into the Eggdrop binary. |

### Package Names by Platform

| Need | Debian / Ubuntu | openSUSE Leap | FreeBSD / GhostBSD |
| --- | --- | --- | --- |
| Core Tcl (includes `http`, `msgcat`) | `tcl8.6` | `tcl` | `tcl86` (`lang/tcl86`) |
| `sqlite3` Tcl binding | `libsqlite3-tcl` | `sqlite3-tcl` (or `tcl-sqlite3`, varies by release) | `tcl-sqlite3` (`databases/tcl-sqlite3`) |
| `tls` (HTTPS) | `tcl-tls` | No Leap package; build from source | `tcltls` (`security/tcltls`) |
| `json` (optional) | `tcllib` | `tcllib` | `tcllib` (`devel/tcllib`) |
| `md5` | Built into Eggdrop | Built into Eggdrop | Built into Eggdrop |

**Debian / Ubuntu**

```bash
sudo apt install tcl8.6 tcl-tls libsqlite3-tcl tcllib
```

**openSUSE Leap**

```bash
sudo zypper install tcl sqlite3-tcl tcllib
```

TclTLS has no official package for Leap 15.5, 15.6, or 16.0; it is built only for Tumbleweed. Either install the Tumbleweed `tls` RPM manually (check glibc and OpenSSL ABI compatibility first), or build it from source against the system OpenSSL:

```bash
sudo zypper install tcl-devel openssl-devel
git clone https://core.tcl-lang.org/tcltls
cd tcltls && ./configure && make && sudo make install
```

Without `tls`, `talkbot.tcl`'s OpenAI calls and `whocom.tcl`'s HTTPS lookups fail; plain `http://` calls still work.

**FreeBSD / GhostBSD**

GhostBSD uses the FreeBSD package and ports tree, so the same names apply to both.

```bash
sudo pkg install tcl86 tcl-sqlite3 tcltls tcllib
```

Install `tcl-sqlite3`, not plain `sqlite3`: the latter is only the CLI and library, not the Tcl binding. If no current `tcltls` binary is available for your GhostBSD release, build it from ports:

```bash
cd /usr/ports/security/tcltls && sudo make install clean
```

### Fallback Behavior

- If `tls` is missing, `talkbot.tcl` will not reply at all. `whocom.tcl` keeps working but loses `!ip` and RDAP; raw WHOIS on port 43 still works.
- If `json` (tcllib) is missing, `talkbot.tcl` falls back to a regex parser, which is slightly less robust.
- `talkbot.tcl` lists `!costhelp`, but that command comes from `talkbot_cost.tcl`, which must also be loaded.
- `sysinfo.tcl` and `mem.tcl` read Linux `/proc`; on BSD or other systems some fields show `N/A`.

---

## Installing Eggdrop on Debian 13 (Trixie)

### 1. Install Packages

```bash
sudo apt update
sudo apt install eggdrop tcl8.6 tcl-tls tcllib libsqlite3-tcl \
                 ca-certificates coreutils unzip pciutils
```

To build Eggdrop from source instead of using the `eggdrop` package, also install:

```bash
sudo apt install build-essential tcl8.6-dev libssl-dev zlib1g-dev
```

Confirm the `eggdrop` package is available in your release with `apt-cache policy eggdrop`.

### 2. Create a Dedicated User

Never run the bot as root.

```bash
sudo adduser eggdrop
sudo -iu eggdrop
```

### 3. Verify the Tcl Packages Load

```bash
echo 'puts [package require tls]; puts [package require sqlite3]; puts [package require json]' | tclsh8.6
```

Each line should print a version number. An error names the missing package.

### 4. Load Order

- Source the **main** script (for example `bsdhelp.tcl`), never its `_data.tcl` file.
- Load `talkbot_cost.tcl` together with `talkbot.tcl`.
- Keep `Mafia.cfg` in the same directory as `mafia.tcl`.
- Load `sendnotice.tcl` only alongside `dalnet.tcl`.

### 5. Network

`whocom.tcl`'s `!dom` uses raw TCP WHOIS on port 43, so allow outbound port 43. It falls back to RDAP and HackerTarget over HTTPS.

---

## Scanistry Security Suite

**Scanistry 5.0-26** is a 24/7 local security daemon and Qt6 dashboard for Debian 12 (bookworm) and 13 (trixie), Ubuntu 24.04 LTS, 26.04 LTS and 26.10, Linux Mint 22, and LMDE 6 and 7.

It coordinates UFW, ClamAV, AIDE, Lynis, rkhunter, debsecan, tcpdump, tshark, Suricata, and APT security updates; monitors authentication activity; maintains threat-intelligence feeds; automatically blocks hostile addresses; and runs heavy scans during low system load. The dashboard listens on `127.0.0.1` only, over HTTPS with a machine-specific certificate. A panel shield icon shows service status and opens the dashboard. Scanistry contains no AI components.

### Files

| File | Type | Description |
| --- | --- | --- |
| `scanistry_5.0-26_amd64.deb` | Debian package | Installable amd64 build. |
| `scanistry-5.0-26-source.tar.gz` | Source archive | Full package source tree. |
| `scanistry-5.0-26.patch` | Patch | Changes from 5.0-25 to 5.0-26. |
| `60-scanistry-hardening.conf` | sysctl profile | Kernel and network hardening installed to `/etc/sysctl.d/` as a conffile (derived from Lynis KRNL-6000). Edits survive upgrades. |
| `99-hardening_1.conf` | sysctl profile | Optional extra hardening for Debian 12/13, installed as `/etc/sysctl.d/99-hardening.conf`. Loads after Scanistry and deliberately sets none of its keys. Apply with `sudo sysctl --system`. |
| `scanistry-vm-check.sh` | Bash script | Post-install validation of the Scanistry installation and its dependencies. Run as root. |
| `SHA256SUMS-5.0-26.txt` | Checksums | SHA-256 hashes for the package and source archive. |

### Dependencies

Installed automatically by APT from the package's `Depends` field:

| Category | Packages |
| --- | --- |
| Runtime | `python3` (>= 3.10), `python3-pyqt6`, `python3-pyqt6.qtwebengine` |
| Firewall and network | `ufw`, `nftables`, `iproute2`, `net-tools`, `tcpdump`, `tshark`, `suricata` |
| Malware and integrity | `clamav`, `clamav-daemon`, `clamav-freshclam`, `aide`, `rkhunter` |
| Auditing and updates | `lynis`, `debsecan`, `apt`, `unattended-upgrades` |
| System | `passwd`, `procps`, `lsof`, `rsyslog`, `openssl`, `ca-certificates`, `sudo`, `apparmor-utils`, `libcap2-bin` |
| Desktop integration | `pkexec`, `polkitd`, `xdg-utils`, `libnotify-bin` |

**Recommended:** `suricata-update`. **Suggested:** a polkit authentication agent for your desktop, `gnome-shell-extension-appindicator` (required for the panel icon on vanilla GNOME), and a notification daemon.

### Installation

```bash
sha256sum -c SHA256SUMS-5.0-26.txt
sudo apt install ./scanistry_5.0-26_amd64.deb
sudo bash scanistry-vm-check.sh
```

See `Scanistry-Installation-Guide-5_0-26.docx` for full setup instructions.

---

## LiveWorld RPG

**LiveWorld RPG 1.0.36** is an offline living-world fantasy RPG with isometric 2.5D graphics. Features include 12 classes with Tank, Healer, and DPS specs; walkable instanced dungeons and raids with boss mechanics; an elite level 91–100 Heroic raid; Mythic quest chains; herbalism and alchemy; a town trading market; city raids; and walkable PvP arenas (Duel, Team Deathmatch, Capture the Flag, Domination).

| File | Type | Description |
| --- | --- | --- |
| `liveworld-rpg_1.0.36_all.deb` | Debian package | Architecture-independent installable build. |
| `liveworld-rpg-1.0.36-source.tar.gz` | Source archive | Full game source. |
| `LiveWorld-RPG-Guide.docx` | Documentation | Player guide. |
| `SHA256SUMS-1.0.36.txt` | Checksums | SHA-256 hashes for the package and source archive. |

**Dependencies:** `python3` (>= 3.8), `python3-pygame` (>= 2.0), `python3-numpy`. **Recommended:** `x11-utils`.

```bash
sha256sum -c SHA256SUMS-1.0.36.txt
sudo apt install ./liveworld-rpg_1.0.36_all.deb
```

The full version history is installed to `/usr/share/doc/liveworld-rpg/changelog`.

---

## Documentation

| File | Topic |
| --- | --- |
| `Eggdrop_Script_Requirements.docx` | Tcl packages and external programs required by the core Eggdrop scripts. |
| `eggdrop_trixie_packages.docx` | Package requirements and setup for running the script set on Debian 13 (Trixie). |
| `eggdrop-tcl-dependencies.docx` | Tcl dependency reference across Debian/Ubuntu, openSUSE Leap, and FreeBSD/GhostBSD. |
| `Scanistry-Installation-Guide-5_0-26.docx` | Installation and setup for Scanistry 5.0-26. |
| `Scanistry-Ignores-and-Blocks.docx` | Managing Scanistry's ignore and block policy. |
| `Scanistry-Domain-Count-Fix.docx` | Fix for the Scanistry domain-count display. |
| `Scanistry-tracookiepixel-alert.docx` | Analysis of the tracking-cookie/pixel alert. |
| `Suricata_Alert_Review.docx` | Reviewing and triaging Suricata alerts. |
| `ClamAV-upgrade-trixie.docx` | Upgrading ClamAV on Debian 13 (Trixie). |
| `ClamAV-upgrade-homebox.docx` | Upgrading ClamAV on the home server. |
| `AI_Network_Defense_Guide.docx` | AI-assisted network defense strategies. |
| `LiveWorld-RPG-Guide.docx` | LiveWorld RPG player guide. |
| `duck_hunt/documentation.txt` | Duck Hunt setup and usage. |
| `scripts/CONTENTS` | Index of the stock Eggdrop example scripts. |

---

## Release Checksums

Verify downloads with `sha256sum -c <file>` before installing.

| Artifact | SHA-256 |
| --- | --- |
| `scanistry_5.0-26_amd64.deb` | `00016803711c9bfbd686bf1e97188590142dffd695226e0cc746b036b29e6ad0` |
| `scanistry-5.0-26-source.tar.gz` | `b63a1dab7088a7dfa64d201c4d1d50964adcd64c7ab4e67bee22efe9035fb23d` |
| `liveworld-rpg_1.0.36_all.deb` | `6aedf16413814ec99a274655316f7be934e671feed916234ebe296226c823687` |
| `liveworld-rpg-1.0.36-source.tar.gz` | `44c2bde6ed511229a65e1263d9bc50fcae7dbb273b0379d50cc899a400ac4220` |

---

## Quick Start

1. Install the Eggdrop packages listed in [Installing Eggdrop on Debian 13](#installing-eggdrop-on-debian-13-trixie) and verify the Tcl packages load.
2. Copy the contents of `scripts/` (including `duck_hunt/`) into your Eggdrop `scripts/` directory.
3. Review each script's configuration block (channels, access flags, triggers, API keys) before loading it.
4. Add one `source scripts/<name>.tcl` line per script to your Eggdrop configuration file.
5. Run `.rehash` from the partyline, or restart the bot.
6. For Scanistry or LiveWorld RPG, verify the checksums and install the `.deb` with `apt`.

---

## Operational Notes

| Topic | Details |
| --- | --- |
| Target environment | Debian/Ubuntu Linux with Eggdrop 1.8+ (1.9+ recommended) and Tcl 8.6. openSUSE Leap and FreeBSD/GhostBSD are supported with the platform package names above. |
| Privileges | Run Eggdrop as an unprivileged user, never as root. Run `scanistry-vm-check.sh` as root. |
| Secrets | `talkbot.tcl` requires an OpenAI API key, and `nsf.tcl`/`nst.tcl` hold NickServ credentials. Keep these files readable only by the bot user and never commit real credentials. |
| Rehash safety | Most scripts are written to survive `.rehash` cleanly, re-applying settings and removing stale binds and timers. |
| Data files | Back up the `.db`, `.dat`, `.state`, and `mafia.sqlite3` files to preserve game progress and bot state. |
| Portability | `sysinfo.tcl` and `mem.tcl` rely on Linux `/proc`; other platforms show partial data. |
