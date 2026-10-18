#!/bin/bash
# Scanistry post-install check (4.0.11-91 and later, 5.x included; the log-format checks need 4.0.11-98, the unit check
# 4.0.11-103, the job-unit, capture and AppArmor checks 5.0-2, the descriptor-transit checks 5.0-3, the capture and narrower DENIED checks 5.0-5,
# the ClamAV-as-clamav probe and the AppArmor enforce-readiness report 5.0-6, the tcpdump /dev/null lines as information 5.0-7,
# the write probe's unit no longer fails 5.0-10, --install-missing and the optional-tools check 5.0-11, the dashboard-page login check 5.0-12,
# apparmor-utils and libcap2-bin as hard dependencies 5.0-13, the approval, broker /run, CSP, sysctl and AppArmor-mode checks 5.0-14,
# the dpkg.log profile-rule check 5.0-15, the approve/deny argument-order checks 5.0-16, the threat-feed limit and unblock
# checks 5.0-17, the web profile's ptrace rule and DENIED lines in the enforce-readiness report 5.0-18, the vendor unit-file rule 5.0-19,
# the broker-side allow_ips refusal and the token-only login code 5.0-20).
# Run as root on a real machine AFTER installing the .deb:
#   sudo bash scanistry-vm-check.sh [--install-missing] [path/to/attack_as_web.py]
# --install-missing installs apparmor-utils, libcap2-bin and curl with apt-get if their tools are missing (since 5.0-13
# the package depends on the first two, so apt installs them with Scanistry; the flag matters for curl, and for a machine
# still on 5.0-11 or 5.0-12); without it nothing is installed.
# Prints PASS/FAIL/WARN per check and a summary. Changes nothing except a short ufw status read, a root-only temporary
# file under /tmp for the 5.0-6 ClamAV probe (removed again), one request parked for approval and denied again (5.0-14:
# "turn UFW off" asked for as the scanistry user, which must wait for an administrator; it is never approved),
# and (if an attack script is given) running it as the scanistry user. Send the whole output back.
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 2; }
# 5.0-11: optional --install-missing; everything else (the attack script's path) is passed through unchanged.
INSTALL_MISSING=0; ARGS=()
for a in "$@"; do case "$a" in --install-missing) INSTALL_MISSING=1;; *) ARGS+=("$a");; esac; done
set -- "${ARGS[@]}"
if [ "$INSTALL_MISSING" = 1 ]; then
  NEED=""
  command -v aa-enforce >/dev/null 2>&1 || NEED="$NEED apparmor-utils"
  command -v capsh >/dev/null 2>&1 || NEED="$NEED libcap2-bin"
  command -v curl >/dev/null 2>&1 || NEED="$NEED curl"
  if [ -n "$NEED" ]; then
    echo "== Installing the missing packages:$NEED =="
    DEBIAN_FRONTEND=noninteractive apt-get install -y $NEED && echo "installed" || echo "apt-get could not install them (is the network up?); the checks below say what is missing"
  else echo "== Packages: nothing is missing =="; fi
fi
P=0; F=0; W=0
ok(){ echo "PASS  $*"; P=$((P+1)); }
bad(){ echo "FAIL  $*"; F=$((F+1)); }
warn(){ echo "WARN  $*"; W=$((W+1)); }
chk(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
# sudo drops XDG_SESSION_TYPE and XDG_CURRENT_DESKTOP, so ask logind about the user who ran sudo.
DESK=${XDG_CURRENT_DESKTOP:-}; SESS=${XDG_SESSION_TYPE:-}
if [ -n "${SUDO_USER:-}" ] && command -v loginctl >/dev/null; then
  for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$SUDO_USER" '$3==u{print $1}'); do
    t=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
    case "$t" in wayland|x11) SESS=$t; d=$(loginctl show-session "$sid" -p Desktop --value 2>/dev/null); [ -n "$d" ] && DESK=$d; break;; esac
  done
fi
echo "== System =="; . /etc/os-release; echo "$PRETTY_NAME | kernel $(uname -r) | desktop: ${DESK:-unknown} | session: ${SESS:-unknown}"
echo "systemd $(systemctl --version | head -1)"; echo "package: $(dpkg-query -W -f='${Version}' scanistry 2>&1)"
echo "== Package and account =="
V=$(dpkg-query -W -f='${Version}' scanistry 2>/dev/null)
# dpkg's own ordering: 5.0-1 sorts after every 4.0.11-N. (Up to 5.0-1 this compared the
# upstream part with "4.0.11", so 5.x always failed here and skipped every later check.)
atleast(){ [ -n "$V" ] && dpkg --compare-versions "$V" ge "$1"; }
if atleast 4.0.11-91; then ok "scanistry $V installed (two-service build, 4.0.11-91 or later)"; else bad "scanistry installed version is '$V'; this script is for 4.0.11-91 or later"; fi
chk "scanistry user exists" id scanistry
id -nG scanistry 2>/dev/null | tr ' ' '\n' | grep -qx adm && ok "scanistry in adm" || bad "scanistry not in adm"
id -nG scanistry 2>/dev/null | tr ' ' '\n' | grep -qx systemd-journal && ok "scanistry in systemd-journal" || bad "scanistry not in systemd-journal"
echo "== Services =="
for u in scanistry-broker scanistry; do
  systemctl is-active --quiet $u && ok "$u active" || bad "$u not active ($(systemctl is-active $u))"
  systemctl is-enabled --quiet $u 2>/dev/null && ok "$u enabled" || warn "$u not enabled"
done
chk "daemon runs as scanistry" bash -c 'ps -o user:32= -p "$(systemctl show -p MainPID --value scanistry)" | grep -qx scanistry'
chk "broker runs as root" bash -c 'ps -o user:32= -p "$(systemctl show -p MainPID --value scanistry-broker)" | grep -qx root'
echo "daemon caps:  $(grep CapEff /proc/$(systemctl show -p MainPID --value scanistry)/status 2>&1)"
BPID=$(systemctl show -p MainPID --value scanistry-broker 2>/dev/null)
echo "broker caps:  $(grep CapBnd /proc/$BPID/status 2>&1)"
if atleast 5.0-2; then
  # The bounding set is a hex mask; decode it with capsh when it is there.
  BCAPS=$(capsh --decode="$(awk '/^CapBnd/{print $2}' /proc/$BPID/status 2>/dev/null)" 2>/dev/null)
  if [ -z "$BCAPS" ]; then warn "capsh not installed (package libcap2-bin); broker capabilities not decoded"
  elif printf '%s' "$BCAPS" | grep -q cap_setgid; then bad "broker still has CAP_SETGID (5.0-2 removed it): $BCAPS"
  else ok "broker has no CAP_SETGID ($BCAPS)"; fi
fi
echo "== Ownership =="
st(){ [ "$(stat -c '%U:%G %a' "$1" 2>/dev/null)" = "$2" ] && ok "$1 is $2" || bad "$1 is '$(stat -c '%U:%G %a' "$1" 2>&1)', want $2"; }
st /var/lib/scanistry scanistry:scanistry\ 700
st /var/lib/scanistry-broker root:root\ 700
st /var/lib/scanistry-broker/quarantine root:root\ 700
st /etc/scanistry root:scanistry\ 750
st /etc/scanistry/scanistry.conf root:scanistry\ 640
st /run/scanistry/broker.sock root:scanistry\ 660
st /var/log/scanistry scanistry:adm\ 750
[ -e /var/lib/scanistry/quarantine ] && bad "old quarantine dir still in /var/lib/scanistry" || ok "no quarantine dir in /var/lib/scanistry"
[ -e /etc/scanistry/runtime-policy.json ] && bad "runtime-policy.json still in /etc/scanistry" || ok "runtime-policy.json not in /etc/scanistry"
echo "== Hardening scores (container reported 1.6 and 2.9) =="
for u in scanistry scanistry-broker; do systemd-analyze security $u --no-pager 2>&1 | tail -1 | sed "s/^/$u: /"; done
if atleast 4.0.11-98; then
  for u in scanistry scanistry-broker; do
    [ "$(systemctl show -p SyslogIdentifier --value $u 2>/dev/null)" = "$u" ] && ok "$u logs to the journal as '$u'" || bad "$u SyslogIdentifier is '$(systemctl show -p SyslogIdentifier --value $u 2>&1)', want $u"
  done
fi
systemd-analyze verify /lib/systemd/system/scanistry.service /lib/systemd/system/scanistry-broker.service 2>&1 | sed 's/^/verify: /'
echo "== Dashboard =="
chk "listens on 127.0.0.1:8765" bash -c "ss -ltn | grep -q '127.0.0.1:8765'"
ss -ltn | grep -q '0.0.0.0:8765\|\[::\]:8765' && bad "dashboard listening on a non-local address" || ok "dashboard not on a non-local address"
code=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8765/ 2>/dev/null); [ "$code" = 401 ] || [ "$code" = 403 ] || [ "$code" = 200 ] && ok "HTTPS answers without token (HTTP $code)" || bad "HTTPS gave '$code'"
# 5.0-12: the dashboard page itself must load. 5.0-10 and 5.0-11 answered 401 to an unauthenticated request (the check
# above) but never sent the page to a logged-in window (a 404 JSON body instead), so this logs in the way the desktop
# window does: the root-only API token buys a single-use login code, the code buys a session cookie, the cookie loads the page.
if atleast 5.0-12 && [ -r /var/lib/scanistry/api.token ] && command -v curl >/dev/null 2>&1; then
  TOK=$(cat /var/lib/scanistry/api.token 2>/dev/null)
  LCODE=$(curl -sk -X POST -H "X-Scanistry-Token: $TOK" -H 'Content-Type: application/json' -d '{}' https://127.0.0.1:8765/api/login-code 2>/dev/null | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("code") or "")
except Exception: print("")' 2>/dev/null)
  TOK=""
  if [ -z "$LCODE" ]; then bad "the dashboard login code could not be obtained from the service (the desktop window cannot log in)"
  else
    JAR=$(mktemp /tmp/scanistry-jar.XXXXXX); HDR=$(mktemp /tmp/scanistry-hdr.XXXXXX)
    read -r DC DS DT <<<"$(curl -sk -L -c "$JAR" -b "$JAR" -D "$HDR" -o /dev/null -w '%{http_code} %{size_download} %{content_type}' "https://127.0.0.1:8765/dashboard?code=$LCODE" 2>/dev/null)"
    CSP=$(grep -i '^content-security-policy:' "$HDR" | tail -1 | tr -d '\r')
    rm -f "$JAR" "$HDR"
    if [ "${DC:-0}" = 200 ] && [ "${DS:-0}" -gt 100000 ] && [ "${DT#text/html}" != "$DT" ]; then ok "the dashboard page loads for a logged-in window (HTTP 200, $DS bytes of HTML)"
    else bad "the dashboard page did not load: HTTP ${DC:-none}, ${DS:-0} bytes, ${DT:-no content type} (the desktop window would show an error instead of the dashboard)"; fi
    if atleast 5.0-14; then
      # 5.0-14: no inline script. The page's one script carries a fresh nonce; inline event attributes are forbidden.
      case "$CSP" in
        *"script-src 'nonce-"*"script-src-attr 'none'"*)
          case "$CSP" in *"script-src 'unsafe-inline'"*) bad "the dashboard CSP still allows inline script: $CSP";;
            *) ok "the dashboard CSP allows only its nonce'd script (no 'unsafe-inline' for scripts)";; esac;;
        *) bad "the dashboard CSP is not the 5.0-14 one (nonce, script-src-attr 'none'): ${CSP:-no header}";;
      esac
    fi
  fi
fi
echo "== CLI =="
if atleast 5.0-14; then NV=66; else NV=62; fi
NVL=$(scanistryctl broker-verbs 2>/dev/null | sed -n 's/^\([0-9][0-9]*\) verbs;.*/\1/p')
[ "${NVL:-0}" -ge "$NV" ] && ok "scanistryctl broker-verbs lists $NVL verbs (at least $NV)" || bad "scanistryctl broker-verbs lists '${NVL:-nothing}', want at least $NV"
chk "scanistryctl status runs" scanistryctl status
if atleast 5.0-3; then
  # 5.0-3: dpkg --verify through the broker. In 5.0-2 it failed on every call ("cannot set primary
  # group ID to root"), so every rkhunter "owned by a package and unmodified" check said "needs review".
  PV=$(python3 -I -c '
import json,socket,struct
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(130); s.connect("/run/scanistry/broker.sock")
d=json.dumps({"verb":"pkg.verify","args":{"pkg":"coreutils"},"fd_args":[],"bind":False}).encode()
s.sendall(struct.pack(">I",len(d))+d); b=b""
while True:
    c=s.recv(65536)
    if not c: break
    b+=c
r=json.loads(b[4:]).get("result"); print(r[0] if isinstance(r,list) else r, (r[1] if isinstance(r,list) else "").strip()[:200])
' 2>&1)
  case "$PV" in "0 "*|0) ok "broker pkg.verify works (dpkg --verify coreutils)";;
    *) bad "broker pkg.verify failed: $PV";; esac
fi
if atleast 5.0-5; then
  # 5.0-5: a real 5-second capture through the broker. The file is opened under the scanistry-web profile,
  # as the dashboard opens it: in 5.0-2 and 5.0-3 Debian's tcpdump profile refused such a file and
  # every capture was empty, while one opened by an unconfined root shell worked.
  CD=$(mktemp -d /tmp/scanistry-cap.XXXXXX); chmod 755 "$CD"; CF=$CD/check.pcapng
  CAPPY='
import array,json,os,socket,struct,sys
fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT|os.O_EXCL,0o600)
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(30); s.connect("/run/scanistry/broker.sock")
d=json.dumps({"verb":"capture.start","args":{"iface":"any","seconds":5},"fd_args":["out"],"bind":False}).encode()
s.sendmsg([struct.pack(">I",len(d))],[(socket.SOL_SOCKET,socket.SCM_RIGHTS,array.array("i",[fd]))]); s.sendall(d)
b=b""
while True:
    c=s.recv(65536)
    if not c: break
    b+=c
print(b[4:].decode("utf-8","replace")[:300])'
  if command -v aa-exec >/dev/null && grep -q '^scanistry-web ' /sys/kernel/security/apparmor/profiles 2>/dev/null; then
    CR=$(aa-exec -p scanistry-web -- python3 -I -c "$CAPPY" "$CF" 2>&1); HOW="opened under scanistry-web"
  else CR=$(python3 -I -c "$CAPPY" "$CF" 2>&1); HOW="opened without AppArmor"; fi
  ( for i in 1 2 3; do ping -c 2 -W 1 127.0.0.1 >/dev/null 2>&1; sleep 1; done ) &
  sleep 10
  CS=$(stat -c %s "$CF" 2>/dev/null || echo 0)
  case "$CR" in *'"ok":true'*|*'"ok": true'*)
      [ "$CS" -gt 0 ] && ok "a 5-second capture saved $CS bytes (file $HOW)" || bad "a 5-second capture started but saved nothing (file $HOW): journalctl -t scanistry-broker -e; journalctl -k -e | grep tcpdump";;
    *) bad "capture.start did not start a capture: $CR";; esac
  rm -rf "$CD"
fi
if atleast 5.0-14; then
  echo "== 5.0-14: approvals and the narrower broker =="
  # The broker may write only /run/scanistry and three lock files in /run, not all of /run.
  RWP=$(systemctl show -p ReadWritePaths --value scanistry-broker 2>/dev/null)
  [ -n "$RWP" ] || RWP=$(sed -n 's/^ReadWritePaths=//p' /etc/systemd/system/scanistry-broker.service.d/*.conf /lib/systemd/system/scanistry-broker.service 2>/dev/null | tr '\n' ' ')
  if [ -z "$RWP" ]; then bad "could not read the broker's ReadWritePaths (systemctl show -p ReadWritePaths scanistry-broker)"
  elif printf ' %s ' "$RWP" | grep -qE ' -?/run '; then bad "the broker can still write all of /run (ReadWritePaths: $RWP)"
  else ok "the broker cannot write all of /run (ReadWritePaths: $RWP)"; fi
  for f in /run/lock/scanistry-aide.lock /run/xtables.lock /run/ufw.lock; do
    [ -f "$f" ] && [ ! -L "$f" ] && ok "$f exists (scanistry-broker-prep makes it before the broker starts)" || bad "$f is missing or not a plain file (ExecStartPre=+/usr/lib/scanistry/scanistry-broker-prep did not run?)"
  done
  BRQ='
import json,socket,struct,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(60); s.connect("/run/scanistry/broker.sock")
d=json.dumps({"verb":sys.argv[1],"args":json.loads(sys.argv[2]),"fd_args":[],"bind":False}).encode()
s.sendall(struct.pack(">I",len(d))+d); b=b""
while True:
    c=s.recv(65536)
    if not c: break
    b+=c
print(json.dumps(json.loads(b[4:])))'
  # ufw still runs inside the narrower sandbox (it takes /run/ufw.lock; legacy iptables /run/xtables.lock).
  US=$(setpriv --reuid=scanistry --regid=scanistry --init-groups python3 -I -c "$BRQ" fw.ufw.status '{}' 2>&1)
  case "$US" in *'"result": [0,'*) ok "the broker still runs ufw in its narrower sandbox (fw.ufw.status)";;
    *) bad "fw.ufw.status through the broker failed: $(printf '%s' "$US" | cut -c1-200)";; esac
  # Turning UFW off, asked for as the scanistry user, must be parked for an administrator, not run.
  UFW0=$(ufw status 2>/dev/null | head -1)
  AR=$(setpriv --reuid=scanistry --regid=scanistry --init-groups python3 -I -c "$BRQ" fw.ufw.disable '{}' 2>&1)
  AID=$(printf '%s' "$AR" | python3 -I -c 'import sys,json
try: print(json.load(sys.stdin).get("approval") or "")
except Exception: print("")')
  UFW1=$(ufw status 2>/dev/null | head -1)
  if [ -n "$AID" ] && printf '%s' "$AR" | grep -q 'needs administrator approval' && [ "$UFW0" = "$UFW1" ]; then ok "turning UFW off from the unprivileged side waits for approval ($AID) and changed nothing (${UFW1:-ufw status unavailable})"
  else bad "turning UFW off from the unprivileged side was not parked for approval: $(printf '%s' "$AR" | cut -c1-200) (ufw: '$UFW0' -> '$UFW1')"; fi
  if [ -n "$AID" ]; then
    GR=$(setpriv --reuid=scanistry --regid=scanistry --init-groups python3 -I -c "$BRQ" approval.grant "{\"aid\":\"$AID\"}" 2>&1)
    printf '%s' "$GR" | grep -q 'only root can approve' && ok "the unprivileged side cannot approve its own request" || bad "approval.grant from the scanistry user was not refused: $(printf '%s' "$GR" | cut -c1-200)"
    scanistryctl approvals 2>/dev/null | grep -q "^$AID  turn the UFW firewall off" && ok "sudo scanistryctl approvals lists it with what it would do" || bad "sudo scanistryctl approvals does not list $AID"
    if atleast 5.0-16; then
      # 5.0-16: the ID and -y come in either order, and an unknown option is refused before the broker is asked.
      # (5.0-14 and 5.0-15 took "-y" for the ID.) deny -y ID is the safe way to test the order: it only drops the request.
      UO=$(scanistryctl approve -x "$AID" 2>&1); urc=$?
      { [ "$urc" = 2 ] && printf '%s' "$UO" | grep -q 'unknown option -x'; } && ok "sudo scanistryctl approve -x ID is refused as an unknown option (nothing approved)" || bad "approve -x ID was not refused as an unknown option (rc=$urc): $(printf '%s' "$UO" | cut -c1-160)"
      scanistryctl approvals 2>/dev/null | grep -q "^$AID  " && ok "the request is still waiting after the refused option" || bad "the request $AID is gone after a refused option"
      scanistryctl deny -y "$AID" 2>/dev/null | grep -q '"ok": true' && ok "sudo scanistryctl deny -y ID drops it (the option before the ID; it was never approved)" || bad "sudo scanistryctl deny -y $AID failed (5.0-16 takes the ID and -y in either order)"
    else
      scanistryctl deny "$AID" 2>/dev/null | grep -q '"ok": true' && ok "sudo scanistryctl deny drops it (it was never approved)" || bad "sudo scanistryctl deny $AID failed"
    fi
    [ "$(ufw status 2>/dev/null | head -1)" = "$UFW0" ] && ok "ufw is unchanged after the approval test (${UFW0:-ufw status unavailable})" || bad "ufw changed during the approval test: '$UFW0' -> '$(ufw status 2>/dev/null | head -1)'"
  fi
  if atleast 5.0-15; then
    # 5.0-15: the AIDE/package explanations on the Logs page read /var/log/dpkg.log; without this rule enforce mode blocks it.
    web=$(sed -n '/profile scanistry-web/,/profile scanistry-broker/p' /etc/apparmor.d/scanistry 2>/dev/null)
    printf '%s\n' "$web" | grep -qE '^[[:space:]]*/var/log/dpkg\.log\* r,$' && ok "scanistry-web may read /var/log/dpkg.log and its rotated copies" || bad "scanistry-web has no /var/log/dpkg.log* r, rule (an edited profile kept at upgrade?)"
    if atleast 5.0-18; then
      # 5.0-18: pgrep, looking for an AIDE run Scanistry did not start (Scans page), was DENIED in enforce mode without this rule.
      printf '%s\n' "$web" | grep -qE '^[[:space:]]*ptrace read peer=unconfined,$' && ok "scanistry-web may read other processes' details for pgrep (ptrace read peer=unconfined)" || bad "scanistry-web has no ptrace read peer=unconfined, rule (an edited profile kept at upgrade?)"
    fi
    if atleast 5.0-19; then
      # 5.0-19: the AIDE report reads WantedBy=/Also= of the units a sudo systemctl command named; never /etc/systemd/system.
      printf '%s\n' "$web" | grep -qE '^[[:space:]]*/usr/lib/systemd/system/\*\* r,$' && ok "scanistry-web may read the vendor unit files (/usr/lib/systemd/system)" || bad "scanistry-web has no /usr/lib/systemd/system/** r, rule (an edited profile kept at upgrade?)"
      printf '%s\n' "$web" | grep -qE '^[[:space:]]*/etc/systemd/system/' && bad "scanistry-web may read /etc/systemd/system (drop-ins there can hold secrets)" || ok "scanistry-web cannot read /etc/systemd/system"
    fi
  fi
  echo "== 5.0-14: kernel settings =="
  for kv in kernel.yama.ptrace_scope=1 kernel.unprivileged_bpf_disabled=1 net.core.bpf_jit_harden=2 net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.default.rp_filter=2; do
    k=${kv%%=*}; want=${kv#*=}; have=$(sysctl -n "$k" 2>/dev/null)
    if [ -z "$have" ]; then warn "$k is not available in this kernel"
    elif [ "$have" = "$want" ]; then ok "$k = $have"
    elif [ "${k##*.}" = rp_filter ] && [ "$have" = 1 ]; then
      # rp_filter 1 (strict) is stricter than Scanistry's 2 (loose); Scanistry only avoids it because it can break VPNs and multi-homed machines.
      ok "$k = 1 (strict), stricter than Scanistry's 2 (loose); set elsewhere on purpose, fine unless a VPN or second connection drops traffic"
    else bad "$k = $have, want $want (a file sorted after 60-scanistry-hardening.conf sets it, or it is not applied yet: sudo sysctl --system)"; fi
  done
  grep -qE '^[a-z0-9_.]+[[:space:]]*=[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]' /etc/sysctl.d/60-scanistry-hardening.conf 2>/dev/null \
    && bad "60-scanistry-hardening.conf has text after a value (an edited conffile kept at upgrade? sysctl.d has no end-of-line comments)" \
    || ok "60-scanistry-hardening.conf has no text after any value"
  SE=$(journalctl -b -u systemd-sysctl --no-pager -o cat 2>/dev/null | grep -iE "couldn't write|invalid argument" | grep -c .)
  [ "${SE:-0}" = 0 ] && ok "systemd-sysctl logged no write errors this boot" || { warn "systemd-sysctl logged $SE write error(s) this boot (the end-of-line comments before 5.0-14 did this; reboot once after upgrading):"; journalctl -b -u systemd-sysctl --no-pager -o cat | grep -iE "couldn't write|invalid argument" | tail -5; }
fi
if atleast 5.0-17; then
  echo "== 5.0-17: threat-feed blocks and unblock (read only) =="
  # The installed code: the feed limit counts only new blocks, and a failed unblock keeps the block.
  LP=/usr/lib/scanistry/scanistry.py
  grep -q 'if blocked>=limit or failed>=limit: break' "$LP" 2>/dev/null && ok "the feed refresh counts only new blocks toward feed_auto_block_limit" \
    || bad "$LP does not have the 5.0-17 feed loop (feed blocks stop at the first feed_auto_block_limit entries)"
  grep -q 'the block is kept' "$LP" 2>/dev/null && ok "a failed unblock keeps the block in the list" \
    || bad "$LP does not have the 5.0-17 unblock fix (a failed unblock drops the block from the list)"
  # Before 5.0-17 max_auto_block_prefix was accepted up to 100000; it is a prefix length (1 to 32) and is clamped.
  MAP=$(python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("max_auto_block_prefix",8))
except Exception: print("")' /etc/scanistry/scanistry.conf 2>/dev/null)
  case "$MAP" in ''|*[!0-9]*) warn "max_auto_block_prefix in /etc/scanistry/scanistry.conf is not a whole number ('$MAP'); Scanistry uses 8";;
    *) [ "$MAP" -ge 1 ] && [ "$MAP" -le 32 ] && ok "max_auto_block_prefix = $MAP (1 to 32)" \
         || warn "max_auto_block_prefix = $MAP in /etc/scanistry/scanistry.conf; since 5.0-17 Scanistry clamps it to 1..32";; esac
  # How far the feeds are blocked, from the state files and the last refresh's log line. Nothing is changed.
  DSTART=$(date -d "$(systemctl show -p ActiveEnterTimestamp --value scanistry 2>/dev/null)" +%s 2>/dev/null || echo 0)
  FRPY='
import json,re,sys
from datetime import datetime
dstart=float(sys.argv[1] or 0)
def load(p,d):
    try:
        x=json.load(open(p)); return x if isinstance(x,type(d)) else d
    except Exception: return d
cfg=load("/etc/scanistry/scanistry.conf",{})
try: limit=max(0,min(10000,int(cfg.get("feed_auto_block_limit",500))))
except Exception: limit=500
auto=cfg.get("feed_auto_block",True) and cfg.get("auto_block",True) and cfg.get("response_feed_block",True)
feeds=load("/var/lib/scanistry/feeds.json",{})
ind=len(feeds.get("ips") or [])+len(feeds.get("networks") or [])
blocks=load("/var/lib/scanistry/blocks.json",{})
fb=sum(1 for v in blocks.values() if isinstance(v,dict) and v.get("source")=="feed")
last=None
try:
    for line in open("/var/log/scanistry/scanistry.log",errors="replace"):
        if "threat feed update:" in line and "newly blocked" in line: last=line.strip()
except Exception: pass
new=old=None; ts=0
if last:
    m=re.search(r"(\d+) newly blocked, (\d+) already blocked",last)
    if m: new,old=int(m.group(1)),int(m.group(2))
    try: ts=datetime.fromisoformat(last.split()[0]).timestamp()
    except Exception: ts=0
print(json.dumps({"limit":limit,"auto":bool(auto),"indicators":ind,"feed_blocks":fb,"blocks":len(blocks),
                  "new":new,"old":old,"since_start":bool(ts and dstart and ts>=dstart),"last":(last or "")[:300]}))
'
  FR=$(python3 -I -c "$FRPY" "$DSTART" 2>&1)
  FJ() { printf '%s' "$FR" | python3 -I -c 'import json,sys
try: v=json.load(sys.stdin).get(sys.argv[1])
except Exception: v=None
print("" if v is None else v)' "$1"; }
  if [ -z "$(FJ limit)" ]; then warn "could not read the feed state (/etc/scanistry/scanistry.conf, /var/lib/scanistry/feeds.json, blocks.json): $(printf '%s' "$FR" | tail -1 | cut -c1-160)"
  else
    LIM=$(FJ limit); IND=$(FJ indicators); FB=$(FJ feed_blocks); NB=$(FJ blocks); NEW=$(FJ new); OLD=$(FJ old)
    echo "info: $FB feed blocks of $IND feed addresses and ranges ($NB blocks in all); feed_auto_block_limit = $LIM new blocks per refresh"
    [ -n "$(FJ last)" ] && echo "info: last refresh: $(FJ last | cut -c1-220)"
    if [ "$(FJ auto)" != True ]; then ok "automatic feed blocking is off (feed_auto_block, auto_block or response_feed_block), so nothing to check"
    elif [ "$(FJ since_start)" != True ]; then warn "no feed refresh logged since scanistry last started; press \"Update feeds now\" on Threat Intelligence, wait for it to finish, then run this check again"
    elif [ "${NEW:-0}" -gt 0 ]; then ok "the last refresh added $NEW new feed blocks ($OLD already blocked)"
    elif [ "${FB:-0}" -ge "${IND:-0}" ] || [ "${IND:-0}" -le "${LIM:-500}" ]; then ok "the last refresh added nothing new: every feed entry it may block is blocked already ($FB of $IND)"
    elif [ "${FB:-0}" = "${OLD:-x}" ] && [ "${OLD:-0}" -le "${LIM:-500}" ] && [ "${OLD:-0}" -ge $(( ${LIM:-500} * 9 / 10 )) ]; then
      bad "the last refresh added nothing and found only the first $OLD blocked: the pre-5.0-17 stall (feed blocks stuck at the limit). Restart scanistry (sudo systemctl restart scanistry) and refresh again"
    else warn "the last refresh added nothing although $FB of $IND feed entries are blocked: entries left are refused by policy (allow_ips, ranges wider than max_auto_block_prefix, IPv6 automatic blocking off, a DNS server or gateway) or the 20,000-block cap is reached; see /var/log/scanistry/scanistry.log"; fi
  fi
fi
if atleast 5.0-20; then
  echo "== 5.0-20: local network and login codes (read only) =="
  LP=/usr/lib/scanistry/scanistry.py
  grep -q 'is or overlaps the local network (allow_ips); Scanistry never blocks it' "$LP" 2>/dev/null && ok "the broker itself refuses to block the local network (allow_ips) or a range overlapping it" \
    || bad "$LP does not have the 5.0-20 broker-side allow_ips refusal (a compromised dashboard could block the LAN)"
  grep -q 'a login code needs the API token (X-Scanistry-Token header), not a session' "$LP" 2>/dev/null && ok "a dashboard login code needs the API token (a session cookie cannot mint one)" \
    || bad "$LP does not have the 5.0-20 token-only login code (a session could renew itself indefinitely)"
fi
echo "== Broker refuses and journal =="
if [ -n "${1:-}" ] && [ -f "$1" ]; then
  # The scanistry user cannot read a home folder, so run a private copy from /tmp.
  A=$(mktemp /tmp/scanistry-attack.XXXXXX.py); cp "$1" "$A"; chmod 644 "$A"
  START=$(date '+%Y-%m-%d %H:%M:%S'); sleep 1
  if setpriv --reuid=scanistry --regid=scanistry --init-groups python3 "$A" 2>&1 | tail -15 | tee /tmp/attack.out | grep -q "all attempts refused"; then ok "attack script: all attempts refused"; else bad "attack script did not end with 'all attempts refused' (see output)"; tail -15 /tmp/attack.out; fi
  rm -f "$A"; sleep 2
  if atleast 4.0.11-98; then
    REF=$(journalctl -t scanistry-broker --since "$START" --no-pager -o cat 2>/dev/null | grep 'privilege broker: refused')
    n=$(printf '%s\n' "$REF" | grep -c 'refused'); m=$(printf '%s\n' "$REF" | grep 'refused' | grep -vEc 'from pid [0-9]+ uid [0-9]+')
    [ "$n" -gt 0 ] && ok "broker logged $n refusals as scanistry-broker" || bad "no refusal lines under journalctl -t scanistry-broker"
    [ "$n" -gt 0 ] && [ "$m" = 0 ] && ok "every refusal names the caller's pid and uid" || { bad "$m of $n refusal lines do not name pid and uid:"; printf '%s\n' "$REF" | grep -vE 'from pid [0-9]+ uid [0-9]+' | head -5; }
    printf '%s\n' "$REF" | grep -q "path: '/etc/shadow' is not a file Scanistry reads" && ok "file.open refusal names the path" || bad "file.open refusal does not name the path"
  fi
  [ -L /var/lib/scanistry/shadow-link ] && rm -f /var/lib/scanistry/shadow-link
else warn "no attack_as_web.py path given; skipped (tests/attack_as_web.py in the source tarball)"; fi
n=$(journalctl -u scanistry -u scanistry-broker -b --no-pager -p err 2>/dev/null | grep -vc '^-- ')
[ "$n" = 0 ] && ok "no error-level journal lines this boot" || { warn "$n error-level lines:"; journalctl -u scanistry -u scanistry-broker -b --no-pager -p err | grep -v '^-- ' | tail -20; }
journalctl -u scanistry -u scanistry-broker -b --no-pager 2>/dev/null | grep -iE "traceback|permission denied" | tail -10 | sed 's/^/log: /'
echo "== Mandatory access control =="
if command -v aa-status >/dev/null; then aa-status 2>/dev/null | head -3; fi
if atleast 5.0-5; then
  # 5.0-5: only since the broker started (older lines belong to an earlier Scanistry), and split into the
  # programs Scanistry runs (its own profiles, tcpdump, clamd, tshark, freshclam) and everything else.
  BSINCE=$(systemctl show -p ActiveEnterTimestamp --value scanistry-broker 2>/dev/null)
  DEN=$(journalctl -k --since "${BSINCE:-today}" --no-pager 2>/dev/null | grep 'apparmor="DENIED"' \
        | grep -v 'profile="/usr/sbin/clamd" name="/sys/fs/cgroup/[^"]*cpu.max"')
  # 5.0-7: Debian's own tcpdump profile (enforce) refuses the /dev/null handle a capture unit passes it
  # ("disconnected path"); the capture is written through a pipe and is not affected. Information, not a warning.
  TCPN=$(printf '%s\n' "$DEN" | grep -c -E 'profile="tcpdump" name="(dev/null|apparmor/\.null)"')
  DEN=$(printf '%s\n' "$DEN" | grep -v -E 'profile="tcpdump" name="(dev/null|apparmor/\.null)"')
  MINE=$(printf '%s\n' "$DEN" | grep -E 'profile="(scanistry-[a-z/]+|tcpdump|/usr/sbin/clamd|clamd|/usr/bin/tshark|tshark|dumpcap|/usr/bin/freshclam|freshclam)"')
  OTHER=$(printf '%s\n' "$DEN" | grep -v -E 'profile="(scanistry-[a-z/]+|tcpdump|/usr/sbin/clamd|clamd|/usr/bin/tshark|tshark|dumpcap|/usr/bin/freshclam|freshclam)"' | grep -c .)
  if [ -z "$MINE" ]; then ok "no AppArmor DENIED lines for Scanistry or the tools it runs since the broker started"
  else warn "AppArmor DENIED lines for Scanistry or the tools it runs since the broker started (keep these):"; printf '%s\n' "$MINE" | tail -10; fi
  [ "${TCPN:-0}" = 0 ] || echo "info: $TCPN DENIED line(s) from Debian's tcpdump profile about /dev/null during captures (cosmetic: the capture is written through a pipe and saved; reported as information since 5.0-7)"
  [ "$OTHER" = 0 ] || echo "info: $OTHER DENIED line(s) from other programs' profiles since the broker started (not Scanistry; clamd's cpu.max read is left out)"
elif dmesg 2>/dev/null | grep -qi 'apparmor="DENIED"'; then warn "AppArmor DENIED lines (keep these):"; dmesg | grep -i 'apparmor="DENIED"' | tail -10; else ok "no AppArmor DENIED in dmesg"; fi
if atleast 4.0.11-103; then if grep -qs '^AppArmorProfile=' /lib/systemd/system/scanistry.service /lib/systemd/system/scanistry-broker.service; then bad "a Scanistry unit file names an AppArmor profile (4.0.11-103 removed these; 5.0-2 uses drop-ins)"; else ok "the unit files name no AppArmor profile"; fi; fi
if atleast 5.0-2; then
  # 5.0-2 loads /etc/apparmor.d/scanistry and names it with drop-ins, only when AppArmor is on: complain mode up to 5.0-13,
  # enforce mode from 5.0-14 unless /etc/apparmor.d/force-complain/scanistry keeps complain mode.
  if [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = Y ] && [ ! -e /etc/apparmor.d/disable/scanistry ]; then
    for pr in scanistry:scanistry-web scanistry-broker:scanistry-broker; do
      u=${pr%%:*}; p=${pr#*:}
      # 5.0-10: complain mode (the default) or enforce mode (after sudo aa-enforce /etc/apparmor.d/scanistry) both pass.
      MODE=$(grep -oE "^$p \((complain|enforce)\)" ${SCANISTRY_VMCHECK_AAPROFILES:-/sys/kernel/security/apparmor/profiles} 2>/dev/null | head -1 | grep -oE 'complain|enforce')
      [ -n "$MODE" ] && ok "AppArmor profile $p loaded ($MODE)" || bad "AppArmor profile $p is not loaded (neither complain nor enforce mode)"
      if atleast 5.0-14 && [ "$MODE" = complain ]; then
        if [ -e /etc/apparmor.d/force-complain/scanistry ]; then warn "$p is in complain mode because /etc/apparmor.d/force-complain/scanistry exists (sudo scanistryctl apparmor complain, or the upgrade found ALLOWED lines); see the readiness report below, then: sudo scanistryctl apparmor enforce"
        else bad "$p is in complain mode although 5.0-14 loads it in enforce mode and there is no force-complain link (an edited profile kept at upgrade? sudo scanistryctl apparmor status)"; fi
      fi
      [ "$(systemctl show -p AppArmorProfile --value $u 2>/dev/null)" = "$p" ] && ok "$u runs under $p" || bad "$u does not name $p (drop-in /etc/systemd/system/$u.service.d/scanistry-apparmor.conf)"
      pid=$(systemctl show -p MainPID --value $u 2>/dev/null)
      if [ -n "$MODE" ] && grep -q "^$p ($MODE)" /proc/$pid/attr/current 2>/dev/null; then ok "$u process is confined by $p ($MODE)"
      else warn "$u process label is '$(cat /proc/$pid/attr/current 2>/dev/null)', want $p (${MODE:-complain or enforce}); restart it once (sudo systemctl restart $u)"; fi
    done
    if atleast 5.0-3; then
      # 5.0-3: without attach_disconnected the kernel drops every file handed between the two halves
      # (capture, deep analysis, AIDE report, root-only logs) although the log line says ALLOWED.
      for p in scanistry-web scanistry-broker; do
        grep -Eq "^profile $p flags=\([^)]*attach_disconnected" /etc/apparmor.d/scanistry 2>/dev/null && ok "$p has attach_disconnected" || bad "$p in /etc/apparmor.d/scanistry lacks attach_disconnected (an edited conffile kept at upgrade?)"
      done
      SINCE=$(systemctl show -p ActiveEnterTimestamp --value scanistry-broker 2>/dev/null)
      nd=$(journalctl -k --since "${SINCE:-today}" --no-pager 2>/dev/null | grep -E 'profile="scanistry-(web|broker)' | grep -c 'Failed name lookup - disconnected path')
      [ "$nd" = 0 ] && ok "no disconnected-path lines from the Scanistry profiles since the broker started" || { bad "$nd disconnected-path lines since the broker started (files dropped between the halves):"; journalctl -k --since "${SINCE:-today}" --no-pager | grep -E 'profile="scanistry-(web|broker)' | grep 'disconnected path' | tail -5; }
      nf=$(journalctl -t scanistry-broker --since "${SINCE:-today}" --no-pager -o cat 2>/dev/null | grep -cE 'arrived without its file descriptor|too many file descriptors')
      [ "$nf" = 0 ] && ok "no request lost its file descriptor since the broker started" || bad "$nf requests lost their file descriptor since the broker started (journalctl -t scanistry-broker)"
    fi
    ASINCE=$(systemctl show -p ActiveEnterTimestamp --value scanistry-broker 2>/dev/null)
    na=$(journalctl -k --since "${ASINCE:-today}" --no-pager 2>/dev/null | grep 'apparmor="ALLOWED"' | grep -cE 'profile="scanistry-(web|broker)')
    [ "$na" = 0 ] && ok "no ALLOWED lines from the Scanistry profiles since the broker started" || { warn "$na ALLOWED lines from the Scanistry profiles since the broker started (what enforce mode would block; the distinct ones are listed under enforce readiness below):"; journalctl -k --since "${ASINCE:-today}" --no-pager | grep 'apparmor="ALLOWED"' | grep -E 'profile="scanistry-(web|broker)' | tail -4; }
  else
    ls /etc/systemd/system/scanistry*.service.d/scanistry-apparmor.conf >/dev/null 2>&1 && bad "AppArmor is off or the profile disabled, but a Scanistry AppArmor drop-in is present" || ok "AppArmor off or profile disabled, and no Scanistry AppArmor drop-in"
  fi
fi
if atleast 5.0-6; then
  # 5.0-6: is it safe to switch the Scanistry profiles from complain to enforce? Only when, after a full walk
  # through the dashboard (every scan, a capture and its analysis, an update, a quarantine and a restore),
  # the profiles logged no ALLOWED line: every ALLOWED line is something enforce mode would block.
  # SCANISTRY_VMCHECK_KLOG=file reads the kernel log lines from a file instead (to test this report).
  echo "== AppArmor enforce readiness (report only; nothing is changed) =="
  ENFN=$(grep -cE '^scanistry-(web|broker) \(enforce\)' ${SCANISTRY_VMCHECK_AAPROFILES:-/sys/kernel/security/apparmor/profiles} 2>/dev/null)
  # Only lines since the broker last started (an install or upgrade restarts it): older lines belong to the
  # previous version's profile and would be counted against this one.
  RSINCE=$(systemctl show -p ActiveEnterTimestamp --value scanistry-broker 2>/dev/null)
  if [ -n "${SCANISTRY_VMCHECK_KLOG:-}" ]; then KL=$(cat "$SCANISTRY_VMCHECK_KLOG" 2>/dev/null); else KL=$(journalctl -k --since "${RSINCE:-today}" --no-pager 2>/dev/null); fi
  AL=$(printf '%s\n' "$KL" | grep 'apparmor="ALLOWED"' | grep -E 'profile="scanistry-(web|broker)')
  if [ -z "$AL" ]; then
    if [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = Y ] || [ -n "${SCANISTRY_VMCHECK_KLOG:-}" ]; then
      if atleast 5.0-14; then EN_CMD="sudo scanistryctl apparmor enforce"; CO_CMD="sudo scanistryctl apparmor complain"
      else EN_CMD="sudo aa-enforce /etc/apparmor.d/scanistry"; CO_CMD="sudo aa-complain /etc/apparmor.d/scanistry"; fi
      # 5.0-18: "nothing was blocked" only when the Mandatory access control section found no DENIED line for Scanistry
      # (up to 5.0-17 this said so right after a DENIED warning, because only ALLOWED lines were counted here).
      NMINE=$(printf '%s\n' "${MINE:-}" | grep -c .)
      if [ "${ENFN:-0}" -ge 2 ] && [ "${NMINE:-0}" -gt 0 ]; then warn "both Scanistry profiles are in enforce mode, but enforce mode blocked Scanistry or a tool it runs ($NMINE DENIED line(s) above): add a rule for each wanted one to /etc/apparmor.d/local/scanistry-web or /etc/apparmor.d/local/scanistry-broker and reload (sudo apparmor_parser -r /etc/apparmor.d/scanistry), or go back to complain mode: $CO_CMD"
      elif [ "${ENFN:-0}" -ge 2 ]; then ok "both Scanistry profiles are in enforce mode and nothing was blocked (no DENIED line for them above); undo: $CO_CMD"
      else ok "enforce readiness: the Scanistry profiles logged no ALLOWED line since the broker started. If you have used every dashboard function since then they can be switched to enforce: $EN_CMD (undo: $CO_CMD)"; fi
    else warn "enforce readiness: AppArmor is off, so there is nothing to report"; fi
  else
    NA=$(printf '%s\n' "$AL" | grep -c .)
    warn "enforce readiness: NOT ready. $NA ALLOWED line(s) from the Scanistry profiles; enforce mode would block them. Distinct profile, operation, mask and path, with counts:"
    printf '%s\n' "$AL" | sed -E 's/.*operation="([^"]*)".*profile="([^"]*)".*[ ]name="([^"]*)".*requested_mask="([^"]*)".*/\2 \1 \4 \3/;t;s/.*operation="([^"]*)".*profile="([^"]*)".*/\2 \1 - -/' \
      | sed -E 's#(/proc/)[0-9]+#\1PID#; s#(/run/user/)[0-9]+#\1UID#; s#(scanistry-[a-z]+-p)[0-9]+-[0-9a-f]+#\1PID-ID#' | sort | uniq -c | sort -rn | head -25 | sed 's/^/    /'
    echo "    Add a rule for each wanted line to /etc/apparmor.d/local/scanistry-web or /etc/apparmor.d/local/scanistry-broker, reload with: sudo apparmor_parser -r /etc/apparmor.d/scanistry, repeat the walkthrough, then run this check again."
    atleast 5.0-14 && echo "    (5.0-14: sudo scanistryctl apparmor status shows the mode; sudo scanistryctl apparmor enforce refuses while these lines exist, unless --force.)"
  fi
fi
echo "== ClamAV =="
if atleast 5.0-6; then
  # 5.0-6: a ClamAV batch runs as the clamav user with CAP_DAC_READ_SEARCH as its only (ambient) capability,
  # the way the broker starts it. It must still read a root-only file (clamdscan --fdpass), and must NOT be
  # able to write a file root owns (before 5.0-6 the unit was uid 0 and could).
  if id clamav >/dev/null 2>&1 && command -v clamdscan >/dev/null && command -v systemd-run >/dev/null && systemctl is-active --quiet clamav-daemon; then
    CT=$(mktemp -d /var/tmp/scanistry-clam.XXXXXX); chmod 755 "$CT"; CFILE=$CT/rootonly.txt
    echo "Scanistry check file" > "$CFILE"; chmod 600 "$CFILE"
    CUNIT=(systemd-run --pipe --wait --collect --quiet --property=AmbientCapabilities= --property=AmbientCapabilities=CAP_DAC_READ_SEARCH
           --property=User=clamav --property=CapabilityBoundingSet=CAP_DAC_READ_SEARCH --property=NoNewPrivileges=yes
           --property=IPAddressDeny=any --property=IPAddressAllow=localhost --property=RestrictAddressFamilies="AF_UNIX AF_INET AF_INET6")
    CR=$("${CUNIT[@]}" clamdscan --fdpass "$CFILE" 2>&1); crc=$?
    if [ "$crc" = 0 ]; then ok "a unit started as the clamav user with CAP_DAC_READ_SEARCH scans a root-only file with --fdpass"
    else bad "a ClamAV unit as the clamav user could not scan a root-only file with --fdpass (rc=$crc): $(printf '%s' "$CR" | tail -2 | tr '\n' ' ')"; fi
    # The unit exits 0 whatever happens (5.0-10): a failing unit shows up as a "Problem" on Scanistry's Logs page.
    "${CUNIT[@]}" sh -c "echo changed >> '$CFILE' 2>/dev/null; exit 0" >/dev/null 2>&1
    if [ "$(cat "$CFILE")" = "Scanistry check file" ]; then ok "the same unit cannot write a file root owns"
    else bad "the ClamAV unit changed a root-owned file (before 5.0-6 it could; the clamav user setting is not applied)"; fi
    rm -rf "$CT"
  else warn "ClamAV probe skipped (needs the clamav account, clamdscan, systemd-run and an active clamav-daemon)"; fi
  nfp=$(journalctl -t scanistry-broker --since "$(systemctl show -p ActiveEnterTimestamp --value scanistry-broker 2>/dev/null || echo today)" --no-pager -o cat 2>/dev/null | grep -c 'fdpass failed')
  [ "$nfp" = 0 ] && ok "no 'ClamAV fdpass failed' line since the broker started" || warn "$nfp 'fdpass failed' line(s) since the broker started: ClamAV fell back to --stream (journalctl -t scanistry-broker | grep 'fdpass failed')"
fi
systemctl is-active --quiet clamav-daemon && ok "clamav-daemon active" || { ls /var/lib/clamav/main.c[vl]d >/dev/null 2>&1 && warn "clamav-daemon not active though signatures exist (from -102 Scanistry starts it within 5 minutes of the first download)" || warn "clamav-daemon not active: no signatures yet (freshclam still downloading?)"; }
if atleast 4.0.11-102; then
  grep -qE '^ExcludePath \^/(run|snap|home/\\\.ecryptfs)/$' /etc/clamav/clamd.conf 2>/dev/null && warn "clamd.conf still has ExcludePath lines an older Scanistry added (left because the file was also edited otherwise)" || ok "clamd.conf has no Scanistry-added lines"
fi
if atleast 5.0-2 && [ -f /etc/suricata/suricata.yaml.scanistry-orig ]; then
  echo "== Suricata on purge =="
  M=/var/lib/scanistry-broker/suricata-restore.sha256
  if [ -f "$M" ] && sha256sum -c --status "$M" 2>/dev/null; then ok "suricata.yaml is still what Scanistry wrote: a purge puts suricata.yaml.scanistry-orig back"
  else warn "suricata.yaml was changed after Scanistry last wrote it (or an older Scanistry wrote it): a purge leaves it and suricata.yaml.scanistry-orig as they are"; fi
fi
echo "== Dependencies =="
for t in ufw aide lynis rkhunter clamdscan suricata tcpdump debsecan; do command -v $t >/dev/null && ok "tool present: $t" || warn "tool missing: $t"; done
echo "== Tools used by this check =="
for pair in aa-enforce:apparmor-utils capsh:libcap2-bin curl:curl; do
  t=${pair%%:*}; pk=${pair#*:}
  command -v "$t" >/dev/null 2>&1 && ok "tool present: $t ($pk)" || warn "tool missing: $t (package $pk): sudo apt install $pk, or run this script with --install-missing"
done
echo; echo "== Manual checks still needed =="
cat <<'M'
 1 Open the dashboard window from the menu (and 'scanistryctl gui'); confirm the polkit prompt, tray icon, notifications. Note the desktop and session above.
 2 Dashboard: run each scan once; Update system; block + unblock an address; capture + Analyze + Deep analysis; quarantine + restore a test file (EICAR); look at every Logs source.
 3 After step 2:  sudo journalctl -t scanistry-broker --since '30 min ago' | grep -i refus   -- anything refused that you expected to work?
   (Use a --since time after this script's attack test, whose refusals are expected. Each line names the caller's pid and uid.)
 4 Stop scanistry mid-scan:  sudo systemctl stop scanistry; systemctl list-units 'scanistry-*'   -- nothing left running?
   5.0-3: after step 2, run this script again: the descriptor-transit checks cover the capture, Deep analysis, AIDE and Lynis runs.
   5.0-5: the capture check above covers a capture; still try Analyze and Deep analysis on one from the dashboard.
   5.0-3, after the ClamAV scan:  sudo journalctl -t scanistry-broker --since '30 min ago' | grep -i 'fdpass failed'   -- nothing?
   5.0-2, during a capture:  systemctl list-units 'scanistry-capture-*'; ps -o user=,cmd= -C tcpdump   -- one unit, user tcpdump?
   And during each scan:  systemctl show -p CapabilityBoundingSet 'scanistry-scan-*' 'scanistry-clamav-*'   -- not the full list?
 5 Reboot; then repeat this script. Finally: sudo apt purge scanistry; check /var/lib/scanistry* are gone; reinstall.
 6 5.0-14 approvals, from the dashboard: Disable UFW, Open port 9999/tcp, Stop on clamav-freshclam, Accept pending AIDE baseline
   (if shown), and Scan & quarantine with "Quarantine even if clean" on a test file. Each must say it needs administrator approval
   and change nothing. Then:  sudo scanistryctl approvals   (all listed?)  approve the quarantine one (sudo scanistryctl approve ID)
   and deny the rest (sudo scanistryctl deny ID). 5.0-16: sudo scanistryctl approve -y ID (the option first) must work too. Also: sudo scanistryctl aide-reinitialize   -- does it ask before rebuilding?
 8 5.0-17 threat feeds: on Threat Intelligence press "Update feeds now" (or wait for the 12-hour refresh), then run this check:
   the 5.0-17 section should report new feed blocks until every feed entry is blocked (about 500 more per refresh).
   The Firewall page lists the newest 500 blocks and says how many there are in all.
 9 5.0-17 unblock that fails: block 203.0.113.9 from the Firewall page, then hold ufw's lock and press Unblock on it:
     sudo flock /run/ufw.lock sleep 60 &      (then press Unblock within the minute)
   It must say the unblock failed, the address must still be listed, and an "unblock failed" incident must appear.
   After the minute, Unblock again: it must succeed and the address must be gone (sudo ufw status | grep 203.0.113.9 -- nothing?).
 7 5.0-14 AppArmor:  sudo scanistryctl apparmor status   -- enforce for both? After step 2, any "apparmor-denied" incident on the
   Incidents page, or a feature that stopped working? If so: sudo scanistryctl apparmor complain, and send the incident text.
M
echo; echo "SUMMARY: $P passed, $F failed, $W warnings"; [ $F = 0 ]
