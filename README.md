# Tcl and Other Files

This repository contains a mixed collection of Eggdrop/Tcl scripts, security hardening files, Linux system validation scripts, and supporting documentation. These projects are designed for IRC bot automation, system defense, and environment verification with a focus on Debian/Ubuntu-based systems.

## Repository Overview

| Area | Purpose | Notes |
| --- | --- | --- |
| Archive packages | Source tarballs and Debian packages | Bundled release artifacts and package checks |
| Documentation | Guides and install references | Includes docs for security and game content |
| Eggdrop scripts | IRC bot automation and protection | Includes guard, restrict, spychan, and mafia scripts |
| System hardening config | Security tuning and system lockdown | Scanistry configuration files and hardening profiles |
| Validation scripts | Post-install or environment checks | Shell-based verification for Scanistry |

## File Inventory

### Eggdrop and Tcl Scripts

| File | Type | Description |
| --- | --- | --- |
| `guard.tcl` | Tcl script | Eggdrop join monitor for watching channels, WHOIS enforcement, and ban handling. |
| `mafia.tcl` | Tcl script | Mafia-style crime/RPG game engine for Eggdrop. |
| `masterhelp.tcl` | Tcl script | Helper script that's used for help output in Eggdrop bot environments. |
| `mem.tcl` | Tcl script | Utility / memory or monitor script for TCL-based bot usage. |
| `restrict.tcl` | Tcl script | Restriction script that turns on +R for managed channels after trusted kicks. |
| `spychan.tcl` | Tcl script | Botnet relay and channel spy script for monitoring channel events across linked Eggdrop bots. |
| `sysinfo.tcl` | Tcl script | System information script for system information. |
| `talkbot.tcl` | Tcl script | A talk bot or IRC interaction script. |
| `talkbot_cost.tcl` | Tcl script | Cost-related variant of the talk bot logic. |
| `whocom.tcl` | Tcl script | A who command and identity helper for IRC bot functions. |

### Configuration and Data Files

| File | Type | Description |
| --- | --- | --- |
| `60-scanistry-hardening.conf` | System config | Hardening configuration for a security appliance or host lockdown policy. |
| `99-hardening_1.conf` | System config | Additional hardening policy or override rules. |
| `Mafia.cfg` | Configuration | Settings file for the Mafia RPG bot game. |
| `mafia.sqlite3` | SQLite database | Stored data for the Mafia game state. |
| `netbots-4.10-to-4.11.diff` | Patch | Diff between NetBots versions 4.10 and 4.11. |
| `SHA256SUMS-1.0.36.txt` | Checksum file | Hash list for the 1.0.36 package set. |
| `SHA256SUMS-5.0-23.txt` | Checksum file | Hash list for the 5.0-23 package set. |

### Security and Package Files

| File | Type | Description |
| --- | --- | --- |
| `liveworld-rpg-1.0.36-source.tar.gz` | Source archive | Source bundle for LiveWorld RPG 1.0.36. |
| `liveworld-rpg_1.0.36_all.deb` | Debian package | Debian package for LiveWorld RPG application. |
| `netbots4.11.zip` | Archive | NetBots package bundle/version archive. |
| `scanistry-5.0-23-source.tar.gz` | Source archive | Source bundle for the Scanistry 5.0-23 release. |
| `scanistry-vm-check.sh` | Bash script | Post-install validation script for Scanistry security package checks. |
| `scanistry_5.0-23_amd64.deb` | Debian package | Scanistry package build for amd64 systems. |

### Documentation Files

| File | Type | Description |
| --- | --- | --- |
| `AI_Network_Defense_Guide.docx` | Documentation | Guide covering AI-assisted network defense strategies. |
| `ClamAV-upgrade-trixie.docx` | Documentation | ClamAV upgrade instructions for Debian trixie. |
| `LiveWorld-RPG-Guide.docx` | Documentation | Guide for the LiveWorld RPG project. |
| `Scanistry-Ignores-and-Blocks.docx` | Documentation | Security notes on Scanistry ignore/block policy. |
| `Scanistry-Installation-Guide-5_0-23.docx` | Documentation | Installation and setup notes for Scanistry 5.0-23. |

## Scripts and Programs Summary

| Script / Program | Role | Main Requirements |
| --- | --- | --- |
| `guard.tcl` | IRC channel and join monitoring | Eggdrop, Tcl |
| `mafia.tcl` | Mafia game engine | Eggdrop, Tcl, SQLite3 |
| `mem.tcl` | Memory or monitoring utility | Eggdrop, Tcl |
| `restrict.tcl` | Channel restriction automation | Eggdrop, Tcl |
| `scanistry-vm-check.sh` | Security validation | Bash, systemd, AppArmor, curl, ufw, apt |
| `spychan.tcl` | Botnet relay and channel spy | Eggdrop, Tcl |
| `sysinfo.tcl` | System information lookup | Eggdrop, Tcl |
| `talkbot.tcl` | IRC bot/chat functionality | Eggdrop, Tcl |
| `whocom.tcl` | Who/identity lookup | Eggdrop, Tcl |

## Required Packages and Tools

The following packages are the main dependencies associated with the programs and scripts found in this repository.

| Package | Used By | Purpose |
| --- | --- | --- |
| `aide` | `scanistry-vm-check.sh` | File integrity and system audit support |
| `apparmor-utils` | `scanistry-vm-check.sh` | AppArmor profile validation and enforcement utilities |
| `apt` / `apt-get` | `scanistry-vm-check.sh` | Package installation and dependency management |
| `bash` | `scanistry-vm-check.sh` | Shell environment used to run validation checks |
| `clamdscan` | `scanistry-vm-check.sh` | ClamAV scanning support |
| `curl` | `scanistry-vm-check.sh` | HTTP/HTTPS checks for dashboard validation |
| `debsecan` | `scanistry-vm-check.sh` | Debian package security analysis |
| `eggdrop` | `guard.tcl`, `restrict.tcl`, `spychan.tcl`, `mafia.tcl`, `talkbot.tcl`, `sysinfo.tcl`, `whocom.tcl`, `mem.tcl`, `masterhelp.tcl` | IRC bot runtime for Tcl-based scripts |
| `libcap2-bin` | `scanistry-vm-check.sh` | Capability handling and tool support |
| `lynis` | `scanistry-vm-check.sh` | Security auditing and system hardening checks |
| `python3` | `scanistry-vm-check.sh` | Embedded Python logic in the validation script |
| `rkhunter` | `scanistry-vm-check.sh` | Rootkit detection checks |
| `sqlite3` | `mafia.tcl`, `mafia.sqlite3` | SQLite database support for Mafia game data |
| `suricata` | `scanistry-vm-check.sh` | Network intrusion detection checks |
| `systemd` | `scanistry-vm-check.sh` | Service and system configuration checks |
| `tcl` | All `.tcl` scripts | Tcl interpreter used to run Eggdrop scripts |
| `tcpdump` | `scanistry-vm-check.sh` | Packet capture and inspection |
| `ufw` | `scanistry-vm-check.sh` | Firewall checks and validation |

## Notes

| Topic | Details |
| --- | --- |
| Documentation | Word documents likely explain installation, upgrades, and operational security guidance |
| Intended environment | Linux-based systems with Eggdrop-compatible IRC bot hosting and optional security hardening tools |
| Script compatibility | Tcl scripts are intended for Eggdrop installations and are not standalone command-line utilities by default |
| Security tooling | Scanistry-related files appear to be for Debian/Ubuntu system hardening and validation work |

## Quick Start

1. Place the Tcl scripts in your Eggdrop `scripts/` directory.
2. Ensure `Mafia.cfg` is kept alongside `mafia.tcl`.
3. Source the desired script from your Eggdrop configuration file.
4. Install the required system packages based on the script or package being used.
5. For Scanistry validation, run the shell script with root privileges and review the output.

## Summary

This repository is a practical collection of IRC bot features, a game framework, and Linux security validation files. The overall structure is consistent: Tcl-based automation for Eggdrop, external package artifacts, and hardening/validation scripts for secure system operations.
