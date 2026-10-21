# tcl-and-other-files

This repository collects the current release files, source archives, helper scripts, and related documentation for a few independent projects that I distribute here for convenience.

## Current uploads

### Scanistry

- [scanistry_5.0-23_amd64.deb](scanistry_5.0-23_amd64.deb) — Debian package for the current Scanistry release
- [scanistry-5.0-23-source.tar.gz](scanistry-5.0-23-source.tar.gz) — source archive for the same release
- [scanistry-vm-check.sh](scanistry-vm-check.sh) — post-install verification script
- [SHA256SUMS-5.0-23.txt](SHA256SUMS-5.0-23.txt) — checksums for the release files
- [Scanistry-Installation-Guide-5_0-23.docx](Scanistry-Installation-Guide-5_0-23.docx) — installation guide
- [Scanistry-Ignores-and-Blocks.docx](Scanistry-Ignores-and-Blocks.docx) — notes on ignore rules and block handling
- [AI_Network_Defense_Guide.docx](AI_Network_Defense_Guide.docx) — network defense notes
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

---

# LiveWorld RPG — Offline Fantasy RPG

LiveWorld RPG is an offline isometric fantasy role-playing game for Debian-based Linux systems.

## Current release

- Version: 1.0.36
- Debian package: [liveworld-rpg_1.0.36_all.deb](liveworld-rpg_1.0.36_all.deb)
- Source archive: [liveworld-rpg-1.0.36-source.tar.gz](liveworld-rpg-1.0.36-source.tar.gz)
- Guide: [LiveWorld-RPG-Guide.docx](LiveWorld-RPG-Guide.docx)

The game is distributed here as a ready-to-install Debian package and as a source tarball for building or inspection.

---

# Useful files and notes

- [README.md](README.md) — repository index and overview
- [SHA256SUMS-5.0-23.txt](SHA256SUMS-5.0-23.txt) — current file integrity hashes for the Scanistry release
- [Scanistry-Installation-Guide-5_0-23.docx](Scanistry-Installation-Guide-5_0-23.docx) — setup and migration notes
- [AI_Network_Defense_Guide.docx](AI_Network_Defense_Guide.docx) — local defensive guidance
- [ClamAV-upgrade-trixie.docx](ClamAV-upgrade-trixie.docx) — Debian 13 ClamAV notes
- [Scanistry-Ignores-and-Blocks.docx](Scanistry-Ignores-and-Blocks.docx) — ignore/block behavior explanations

This repository is intended as a package and documentation mirror for the current uploads. New builds, source archives, and documentation are uploaded here as they are produced.
