# tcl-and-other-files

This repository collects the current release files, source archives, helper scripts, and related documentation for a few independent projects that I distribute here for convenience.

## Repository files by type

### Tcl and Tcl-related scripts (.tcl)
- `guard.tcl`
- `mafia.tcl`
- `masterhelp.tcl`
- `mem.tcl`
- `restrict.tcl`
- `spychan.tcl`
- `sysinfo.tcl`
- `talkbot.tcl`
- `talkbot_cost.tcl`
- `whocom.tcl`

### Data and configuration files (.conf, .cfg, .sqlite3)
- `60-scanistry-hardening.conf`
- `99-hardening_1.conf`
- `Mafia.cfg`
- `mafia.sqlite3`

### Documentation and guides (.docx)
- `AI_Network_Defense_Guide.docx`
- `ClamAV-upgrade-trixie.docx`
- `LiveWorld-RPG-Guide.docx`
- `Scanistry-Ignores-and-Blocks.docx`
- `Scanistry-Installation-Guide-5_0-23.docx`

### Packages and archives (.deb, .tar.gz, .zip, .diff)
- `scanistry_5.0-23_amd64.deb`
- `liveworld-rpg_1.0.36_all.deb`
- `scanistry-5.0-23-source.tar.gz`
- `liveworld-rpg-1.0.36-source.tar.gz`
- `netbots4.11.zip`
- `netbots-4.10-to-4.11.diff`

### Validation and release files (.sh, .txt)
- `scanistry-vm-check.sh`
- `SHA256SUMS-5.0-23.txt`
- `SHA256SUMS-1.0.36.txt`

## Current uploads

### Scanistry

- [scanistry_5.0-23_amd64.deb](scanistry_5.0-23_amd64.deb) — Debian package for the current Scanistry release
- [scanistry-5.0-23-source.tar.gz](scanistry-5.0-23-source.tar.gz) — source archive for the same release
- [scanistry-vm-check.sh](scanistry-vm-check.sh) — post-install verification script
- [SHA256SUMS-5.0-23.txt](SHA256SUMS-5.0-23.txt) — checksums for the release files
- [Scanistry-Installation-Guide-5_0-23.docx](Scanistry-Installation-Guide-5_0-23.docx) — installation guide
- [Scanistry-Ignores-and-Blocks.docx](Scanistry-Ignores-and-Blocks.docx) — notes on ignore rules and block handling
- [ClamAV-upgrade-trixie.docx](ClamAV-upgrade-trixie.docx) — ClamAV upgrade guidance

### LiveWorld RPG

- [liveworld-rpg_1.0.36_all.deb](liveworld-rpg_1.0.36_all.deb) — Debian package
- [liveworld-rpg-1.0.36-source.tar.gz](liveworld-rpg-1.0.36-source.tar.gz) — source archive
- [LiveWorld-RPG-Guide.docx](LiveWorld-RPG-Guide.docx) — game guide

### Eggdrop / Tcl scripts

- [masterhelp.tcl](masterhelp.tcl) — Eggdrop help-menu script
- [guard.tcl](guard.tcl)
- [mafia.tcl](mafia.tcl)
- [mafia.sqlite3](mafia.sqlite3)
- [mem.tcl](mem.tcl)
- [restrict.tcl](restrict.tcl)
- [spychan.tcl](spychan.tcl)
- [sysinfo.tcl](sysinfo.tcl)
- [talkbot.tcl](talkbot.tcl)
- [talkbot_cost.tcl](talkbot_cost.tcl)
- [whocom.tcl](whocom.tcl)
- [netbots4.11.zip](netbots4.11.zip)
- [netbots-4.10-to-4.11.diff](netbots-4.10-to-4.11.diff)
- [Mafia.cfg](Mafia.cfg)

### System config examples

- [60-scanistry-hardening.conf](60-scanistry-hardening.conf)
- [99-hardening_1.conf](99-hardening_1.conf)

---

# Scanistry — Local Host Security Daemon

Scanistry is a local host security daemon and dashboard for a single Linux machine. It coordinates standard tools such as UFW/nftables, Suricata, ClamAV, AIDE, Lynis, rkhunter, and debsecan into a single dashboard-driven workflow.

## Current release

- Version: 5.0-23
- Package: `scanistry`
- Current Debian package: [scanistry_5.0-23_amd64.deb](scanistry_5.0-23_amd64.deb)
- Source: [scanistry-5.0-23-source.tar.gz](scanistry-5.0-23-source.tar.gz)
- Check script: [scanistry-vm-check.sh](scanistry-vm-check.sh)
- Integrity hashes: [SHA256SUMS-5.0-23.txt](SHA256SUMS-5.0-23.txt)

Install it with:

```bash
sudo apt install -y ./scanistry_5.0-23_amd64.deb
```

## What it does

- firewall control and auto-blocking
- network intrusion detection with Suricata
- malware scanning with ClamAV
- file-integrity monitoring with AIDE
- hardening audit with Lynis
- rootkit checks with rkhunter
- CVE and package auditing
- local dashboard and API over HTTPS

See the package documentation and the install guide for the full feature set and operational details.

---

# masterhelp.tcl — Eggdrop Help Menu Script

`masterhelp.tcl` is a Tcl script that provides a help-menu system for Eggdrop IRC bots. It indexes and organizes commands and references into a structure that can be browsed from the bot.

## Included Eggdrop scripts

This repository contains a set of related Eggdrop scripts and references intended to pair with the help menu, including:

- `guard.tcl`
- `mafia.tcl`
- `mem.tcl`
- `restrict.tcl`
- `spychan.tcl`
- `sysinfo.tcl`
- `talkbot.tcl`
- `talkbot_cost.tcl`
- `whocom.tcl`

---

# Eggdrop on Debian 13 (Trixie) — Package Requirements

The Eggdrop scripts in this repository are intended for Debian 13 and related Debian-based systems. The exact package set depends on which script you load and which features you use.

Typical requirements include the packages needed for Tcl, IRC, networking, and script support. See the project files in this repo for the relevant package lists and notes.

## Eggdrop / Tcl scripts

```bash
sudo apt update
sudo apt install -y \
  eggdrop \
  tcl8.6 \
  tcl-tls \
  tcllib \
  libsqlite3-tcl \
  ca-certificates \
  coreutils \
  openssl \
  curl \
  build-essential \
  libssl-dev \
  zlib1g-dev
```

These are the packages most commonly needed by the Eggdrop bot and the Tcl scripts in this repository:

- `eggdrop` — IRC bot runtime
- `tcl8.6` — Tcl interpreter for the scripts
- `tcl-tls` — TLS/HTTPS support for scripts such as `talkbot.tcl` and `whocom.tcl`
- `tcllib` — helper libraries such as `json`
- `libsqlite3-tcl` — SQLite support for scripts such as `mafia.tcl`
- `ca-certificates` — trust chain for HTTPS/TLS connections
- `coreutils` — standard Unix utilities such as `df`, `ls`, `cat`, and `sort`
- `openssl` and `curl` — useful for HTTPS API access and testing
- `build-essential`, `libssl-dev`, and `zlib1g-dev` — for source builds or compilation work

## TLS-capable bot / API scripts

If you run scripts that connect to hosted APIs or use HTTPS features, make sure these are installed:

```bash
sudo apt install -y \
  tcl-tls \
  ca-certificates \
  openssl \
  curl \
  tcllib
```

These packages are especially relevant for bot scripts that call external services or fetch data over TLS.

## Scanistry

Scanistry is a local host security and monitoring stack. The package itself pulls in most of the required tools, but the general dependency set is:

```bash
sudo apt install -y \
  ufw \
  nftables \
  aide \
  lynis \
  debsecan \
  rkhunter \
  clamav \
  clamav-daemon \
  freshclam \
  suricata \
  suricata-update \
  tshark \
  tcpdump \
  apparmor-utils \
  libcap2-bin \
  python3-pyqt6 \
  python3-pyqt6.qtwebengine \
  rsyslog \
  policykit-1 \
  pkexec
```

Useful extras for the desktop side and service control:

```bash
sudo apt install -y \
  mate-polkit \
  polkit-gnome \
  dunst \
  xfce4-notifyd \
  gnome-shell-extension-appindicator
```

## LiveWorld RPG

LiveWorld RPG is a Python/Pygame game and has the usual runtime dependencies:

```bash
sudo apt install -y \
  python3 \
  python3-pygame \
  python3-numpy \
  x11-utils
```

Optional extras:

```bash
sudo apt install -y \
  python3-tk \
  python3-pil \
  python3-pip
```

## Common support packages

These are useful across the repository and for general Debian 13 use:

```bash
sudo apt install -y \
  build-essential \
  git \
  curl \
  procps \
  net-tools \
  jq \
  rsyslog \
  ca-certificates
```

## Recommended all-in-one install for Debian 13

If you want a practical starting point for the Eggdrop/Tcl side of this repository, a good base install is:

```bash
sudo apt update
sudo apt install -y \
  eggdrop \
  tcl8.6 \
  tcl-tls \
  tcllib \
  libsqlite3-tcl \
  ca-certificates \
  openssl \
  curl \
  build-essential \
  libssl-dev \
  zlib1g-dev \
  git \
  coreutils \
  procps \
  net-tools \
  jq
```

## Before loading

- Load the main script first, not the `_data.tcl` file it depends on.
- Run Eggdrop as a normal user, not as root.
- For `whocom.tcl`, outbound port 43 is needed for raw WHOIS requests; `!dom` falls back to HTTPS lookups if needed.

## Verify the packages load

```bash
echo 'puts [package require tls]; puts [package require sqlite3]; puts [package require json]' | tclsh8.6
```

---

# LiveWorld RPG — Offline Fantasy RPG

**Version 1.0.36** · Package: `liveworld-rpg`

LiveWorld RPG is an offline, single-player fantasy RPG with isometric 2.5D graphics, written in Python with pygame. You play in a large living world with 12 classes, instanced dungeons and raids, PvP battles, and a full quest, crafting, and guild-driven system.

---

# Useful files and notes

- [README.md](README.md) — repository index and overview
- [SHA256SUMS-5.0-23.txt](SHA256SUMS-5.0-23.txt) — current file integrity hashes for the Scanistry release
- [Scanistry-Installation-Guide-5_0-23.docx](Scanistry-Installation-Guide-5_0-23.docx) — setup and migration notes
- [ClamAV-upgrade-trixie.docx](ClamAV-upgrade-trixie.docx) — Debian 13 ClamAV notes
- [Scanistry-Ignores-and-Blocks.docx](Scanistry-Ignores-and-Blocks.docx) — ignore/block behavior explanations

This repository is intended as a package and documentation mirror for the current uploads. New builds, source archives, and documentation are uploaded here as they are produced.
