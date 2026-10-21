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
