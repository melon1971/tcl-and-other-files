#!/bin/bash
# LocSec post-install check (4.0.11-91 and later, 5.x included; the log-format checks need 4.0.11-98, the unit check
# 4.0.11-103, the job-unit, capture and AppArmor checks 5.0-2, the descriptor-transit checks 5.0-3, the capture and narrower DENIED checks 5.0-5,
# the ClamAV-as-clamav probe and the AppArmor enforce-readiness report 5.0-6, the tcpdump /dev/null lines as information 5.0-7,
# the write probe's unit no longer fails 5.0-10, --install-missing and the optional-tools check 5.0-11). Run as root on a real machine AFTER installing the .deb:
#   sudo bash locsec-vm-check.sh [--install-missing] [path/to/attack_as_web.py]
# --install-missing installs apparmor-utils, libcap2-bin and curl with apt-get if their tools are missing (the 5.0-11
# package already recommends the first two, so apt installs them with LocSec); without it nothing is installed.
# Prints PASS/FAIL/WARN per check and a summary. Changes nothing except a short ufw status read, a root-only temporary
# file under /tmp for the 5.0-6 ClamAV probe (removed again),
# and (if an attack script is given) running it as the locsec user. Send the whole output back.
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
    echo "== Installing the missing optional packages:$NEED =="
    DEBIAN_FRONTEND=noninteractive apt-get install -y $NEED && echo "installed" || echo "apt-get could not install them (is the network up?); the checks below say what is missing"
  else echo "== Optional packages: nothing is missing =="; fi
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
echo "systemd $(systemctl --version | head -1)"; echo "package: $(dpkg-query -W -f='${Version}' locsecd 2>&1)"
echo "== Package and account =="
V=$(dpkg-query -W -f='${Version}' locsecd 2>/dev/null)
# dpkg's own ordering: 5.0-1 sorts after every 4.0.11-N. (Up to 5.0-1 this compared the
# upstream part with "4.0.11", so 5.x always failed here and skipped every later check.)
atleast(){ [ -n "$V" ] && dpkg --compare-versions "$V" ge "$1"; }
if atleast 4.0.11-91; then ok "locsecd $V installed (two-service build, 4.0.11-91 or later)"; else bad "locsecd installed version is '$V'; this script is for 4.0.11-91 or later"; fi
chk "locsec user exists" id locsec
id -nG locsec 2>/dev/null | tr ' ' '\n' | grep -qx adm && ok "locsec in adm" || bad "locsec not in adm"
id -nG locsec 2>/dev/null | tr ' ' '\n' | grep -qx systemd-journal && ok "locsec in systemd-journal" || bad "locsec not in systemd-journal"
echo "== Services =="
for u in locsecd-broker locsecd; do
  systemctl is-active --quiet $u && ok "$u active" || bad "$u not active ($(systemctl is-active $u))"
  systemctl is-enabled --quiet $u 2>/dev/null && ok "$u enabled" || warn "$u not enabled"
done
chk "daemon runs as locsec" bash -c 'ps -o user= -p "$(systemctl show -p MainPID --value locsecd)" | grep -qx locsec'
chk "broker runs as root" bash -c 'ps -o user= -p "$(systemctl show -p MainPID --value locsecd-broker)" | grep -qx root'
echo "daemon caps:  $(grep CapEff /proc/$(systemctl show -p MainPID --value locsecd)/status 2>&1)"
BPID=$(systemctl show -p MainPID --value locsecd-broker 2>/dev/null)
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
st /var/lib/locsecd locsec:locsec\ 700
st /var/lib/locsecd-broker root:root\ 700
st /var/lib/locsecd-broker/quarantine root:root\ 700
st /etc/locsecd root:locsec\ 750
st /etc/locsecd/locsecd.conf root:locsec\ 640
st /run/locsecd/broker.sock root:locsec\ 660
st /var/log/locsecd locsec:adm\ 750
[ -e /var/lib/locsecd/quarantine ] && bad "old quarantine dir still in /var/lib/locsecd" || ok "no quarantine dir in /var/lib/locsecd"
[ -e /etc/locsecd/runtime-policy.json ] && bad "runtime-policy.json still in /etc/locsecd" || ok "runtime-policy.json not in /etc/locsecd"
echo "== Hardening scores (container reported 1.6 and 2.9) =="
for u in locsecd locsecd-broker; do systemd-analyze security $u --no-pager 2>&1 | tail -1 | sed "s/^/$u: /"; done
if atleast 4.0.11-98; then
  for u in locsecd locsecd-broker; do
    [ "$(systemctl show -p SyslogIdentifier --value $u 2>/dev/null)" = "$u" ] && ok "$u logs to the journal as '$u'" || bad "$u SyslogIdentifier is '$(systemctl show -p SyslogIdentifier --value $u 2>&1)', want $u"
  done
fi
systemd-analyze verify /lib/systemd/system/locsecd.service /lib/systemd/system/locsecd-broker.service 2>&1 | sed 's/^/verify: /'
echo "== Dashboard =="
chk "listens on 127.0.0.1:8765" bash -c "ss -ltn | grep -q '127.0.0.1:8765'"
ss -ltn | grep -q '0.0.0.0:8765\|\[::\]:8765' && bad "dashboard listening on a non-local address" || ok "dashboard not on a non-local address"
code=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8765/ 2>/dev/null); [ "$code" = 401 ] || [ "$code" = 403 ] || [ "$code" = 200 ] && ok "HTTPS answers without token (HTTP $code)" || bad "HTTPS gave '$code'"
# 5.0-12: the dashboard page itself must load. 5.0-10 and 5.0-11 answered 401 to an unauthenticated request (the check
# above) but never sent the page to a logged-in window (a 404 JSON body instead), so this logs in the way the desktop
# window does: the root-only API token buys a single-use login code, the code buys a session cookie, the cookie loads the page.
if atleast 5.0-12 && [ -r /var/lib/locsecd/api.token ] && command -v curl >/dev/null 2>&1; then
  TOK=$(cat /var/lib/locsecd/api.token 2>/dev/null)
  LCODE=$(curl -sk -X POST -H "X-LocSec-Token: $TOK" -H 'Content-Type: application/json' -d '{}' https://127.0.0.1:8765/api/login-code 2>/dev/null | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("code") or "")
except Exception: print("")' 2>/dev/null)
  TOK=""
  if [ -z "$LCODE" ]; then bad "the dashboard login code could not be obtained from the service (the desktop window cannot log in)"
  else
    JAR=$(mktemp /tmp/locsec-jar.XXXXXX)
    read -r DC DS DT <<<"$(curl -sk -L -c "$JAR" -b "$JAR" -o /dev/null -w '%{http_code} %{size_download} %{content_type}' "https://127.0.0.1:8765/dashboard?code=$LCODE" 2>/dev/null)"
    rm -f "$JAR"
    if [ "${DC:-0}" = 200 ] && [ "${DS:-0}" -gt 100000 ] && [ "${DT#text/html}" != "$DT" ]; then ok "the dashboard page loads for a logged-in window (HTTP 200, $DS bytes of HTML)"
    else bad "the dashboard page did not load: HTTP ${DC:-none}, ${DS:-0} bytes, ${DT:-no content type} (the desktop window would show an error instead of the dashboard)"; fi
  fi
fi
echo "== CLI =="
chk "locsecctl broker-verbs lists 62" bash -c 'locsecctl broker-verbs | grep -c . | awk "{exit !(\$1>=62)}"'
chk "locsecctl status runs" locsecctl status
if atleast 5.0-3; then
  # 5.0-3: dpkg --verify through the broker. In 5.0-2 it failed on every call ("cannot set primary
  # group ID to root"), so every rkhunter "owned by a package and unmodified" check said "needs review".
  PV=$(python3 -I -c '
import json,socket,struct
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(130); s.connect("/run/locsecd/broker.sock")
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
  # 5.0-5: a real 5-second capture through the broker. The file is opened under the locsecd-web profile,
  # as the dashboard opens it: in 5.0-2 and 5.0-3 Debian's tcpdump profile refused such a file and
  # every capture was empty, while one opened by an unconfined root shell worked.
  CD=$(mktemp -d /tmp/locsec-cap.XXXXXX); chmod 755 "$CD"; CF=$CD/check.pcapng
  CAPPY='
import array,json,os,socket,struct,sys
fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT|os.O_EXCL,0o600)
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(30); s.connect("/run/locsecd/broker.sock")
d=json.dumps({"verb":"capture.start","args":{"iface":"any","seconds":5},"fd_args":["out"],"bind":False}).encode()
s.sendmsg([struct.pack(">I",len(d))],[(socket.SOL_SOCKET,socket.SCM_RIGHTS,array.array("i",[fd]))]); s.sendall(d)
b=b""
while True:
    c=s.recv(65536)
    if not c: break
    b+=c
print(b[4:].decode("utf-8","replace")[:300])'
  if command -v aa-exec >/dev/null && grep -q '^locsecd-web ' /sys/kernel/security/apparmor/profiles 2>/dev/null; then
    CR=$(aa-exec -p locsecd-web -- python3 -I -c "$CAPPY" "$CF" 2>&1); HOW="opened under locsecd-web"
  else CR=$(python3 -I -c "$CAPPY" "$CF" 2>&1); HOW="opened without AppArmor"; fi
  ( for i in 1 2 3; do ping -c 2 -W 1 127.0.0.1 >/dev/null 2>&1; sleep 1; done ) &
  sleep 10
  CS=$(stat -c %s "$CF" 2>/dev/null || echo 0)
  case "$CR" in *'"ok":true'*|*'"ok": true'*)
      [ "$CS" -gt 0 ] && ok "a 5-second capture saved $CS bytes (file $HOW)" || bad "a 5-second capture started but saved nothing (file $HOW): journalctl -t locsecd-broker -e; journalctl -k -e | grep tcpdump";;
    *) bad "capture.start did not start a capture: $CR";; esac
  rm -rf "$CD"
fi
echo "== Broker refuses and journal =="
if [ -n "${1:-}" ] && [ -f "$1" ]; then
  # The locsec user cannot read a home folder, so run a private copy from /tmp.
  A=$(mktemp /tmp/locsec-attack.XXXXXX.py); cp "$1" "$A"; chmod 644 "$A"
  START=$(date '+%Y-%m-%d %H:%M:%S'); sleep 1
  if setpriv --reuid=locsec --regid=locsec --init-groups python3 "$A" 2>&1 | tail -15 | tee /tmp/attack.out | grep -q "all attempts refused"; then ok "attack script: all attempts refused"; else bad "attack script did not end with 'all attempts refused' (see output)"; tail -15 /tmp/attack.out; fi
  rm -f "$A"; sleep 2
  if atleast 4.0.11-98; then
    REF=$(journalctl -t locsecd-broker --since "$START" --no-pager -o cat 2>/dev/null | grep 'privilege broker: refused')
    n=$(printf '%s\n' "$REF" | grep -c 'refused'); m=$(printf '%s\n' "$REF" | grep 'refused' | grep -vEc 'from pid [0-9]+ uid [0-9]+')
    [ "$n" -gt 0 ] && ok "broker logged $n refusals as locsecd-broker" || bad "no refusal lines under journalctl -t locsecd-broker"
    [ "$n" -gt 0 ] && [ "$m" = 0 ] && ok "every refusal names the caller's pid and uid" || { bad "$m of $n refusal lines do not name pid and uid:"; printf '%s\n' "$REF" | grep -vE 'from pid [0-9]+ uid [0-9]+' | head -5; }
    printf '%s\n' "$REF" | grep -q "path: '/etc/shadow' is not a file LocSec reads" && ok "file.open refusal names the path" || bad "file.open refusal does not name the path"
  fi
  [ -L /var/lib/locsecd/shadow-link ] && rm -f /var/lib/locsecd/shadow-link
else warn "no attack_as_web.py path given; skipped (tests/attack_as_web.py in the source tarball)"; fi
n=$(journalctl -u locsecd -u locsecd-broker -b --no-pager -p err 2>/dev/null | grep -vc '^-- ')
[ "$n" = 0 ] && ok "no error-level journal lines this boot" || { warn "$n error-level lines:"; journalctl -u locsecd -u locsecd-broker -b --no-pager -p err | grep -v '^-- ' | tail -20; }
journalctl -u locsecd -u locsecd-broker -b --no-pager 2>/dev/null | grep -iE "traceback|permission denied" | tail -10 | sed 's/^/log: /'
echo "== Mandatory access control =="
if command -v aa-status >/dev/null; then aa-status 2>/dev/null | head -3; fi
if atleast 5.0-5; then
  # 5.0-5: only since the broker started (older lines belong to an earlier LocSec), and split into the
  # programs LocSec runs (its own profiles, tcpdump, clamd, tshark, freshclam) and everything else.
  BSINCE=$(systemctl show -p ActiveEnterTimestamp --value locsecd-broker 2>/dev/null)
  DEN=$(journalctl -k --since "${BSINCE:-today}" --no-pager 2>/dev/null | grep 'apparmor="DENIED"' \
        | grep -v 'profile="/usr/sbin/clamd" name="/sys/fs/cgroup/[^"]*cpu.max"')
  # 5.0-7: Debian's own tcpdump profile (enforce) refuses the /dev/null handle a capture unit passes it
  # ("disconnected path"); the capture is written through a pipe and is not affected. Information, not a warning.
  TCPN=$(printf '%s\n' "$DEN" | grep -c -E 'profile="tcpdump" name="(dev/null|apparmor/\.null)"')
  DEN=$(printf '%s\n' "$DEN" | grep -v -E 'profile="tcpdump" name="(dev/null|apparmor/\.null)"')
  MINE=$(printf '%s\n' "$DEN" | grep -E 'profile="(locsecd-[a-z/]+|tcpdump|/usr/sbin/clamd|clamd|/usr/bin/tshark|tshark|dumpcap|/usr/bin/freshclam|freshclam)"')
  OTHER=$(printf '%s\n' "$DEN" | grep -v -E 'profile="(locsecd-[a-z/]+|tcpdump|/usr/sbin/clamd|clamd|/usr/bin/tshark|tshark|dumpcap|/usr/bin/freshclam|freshclam)"' | grep -c .)
  if [ -z "$MINE" ]; then ok "no AppArmor DENIED lines for LocSec or the tools it runs since the broker started"
  else warn "AppArmor DENIED lines for LocSec or the tools it runs since the broker started (keep these):"; printf '%s\n' "$MINE" | tail -10; fi
  [ "${TCPN:-0}" = 0 ] || echo "info: $TCPN DENIED line(s) from Debian's tcpdump profile about /dev/null during captures (cosmetic: the capture is written through a pipe and saved; reported as information since 5.0-7)"
  [ "$OTHER" = 0 ] || echo "info: $OTHER DENIED line(s) from other programs' profiles since the broker started (not LocSec; clamd's cpu.max read is left out)"
elif dmesg 2>/dev/null | grep -qi 'apparmor="DENIED"'; then warn "AppArmor DENIED lines (keep these):"; dmesg | grep -i 'apparmor="DENIED"' | tail -10; else ok "no AppArmor DENIED in dmesg"; fi
if atleast 4.0.11-103; then if grep -qs '^AppArmorProfile=' /lib/systemd/system/locsecd.service /lib/systemd/system/locsecd-broker.service; then bad "a LocSec unit file names an AppArmor profile (4.0.11-103 removed these; 5.0-2 uses drop-ins)"; else ok "the unit files name no AppArmor profile"; fi; fi
if atleast 5.0-2; then
  # 5.0-2 loads /etc/apparmor.d/locsecd in complain mode and names it with drop-ins, only when AppArmor is on.
  if [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = Y ] && [ ! -e /etc/apparmor.d/disable/locsecd ]; then
    for pr in locsecd:locsecd-web locsecd-broker:locsecd-broker; do
      u=${pr%%:*}; p=${pr#*:}
      # 5.0-10: complain mode (the default) or enforce mode (after sudo aa-enforce /etc/apparmor.d/locsecd) both pass.
      MODE=$(grep -oE "^$p \((complain|enforce)\)" ${LOCSEC_VMCHECK_AAPROFILES:-/sys/kernel/security/apparmor/profiles} 2>/dev/null | head -1 | grep -oE 'complain|enforce')
      [ -n "$MODE" ] && ok "AppArmor profile $p loaded ($MODE)" || bad "AppArmor profile $p is not loaded (neither complain nor enforce mode)"
      [ "$(systemctl show -p AppArmorProfile --value $u 2>/dev/null)" = "$p" ] && ok "$u runs under $p" || bad "$u does not name $p (drop-in /etc/systemd/system/$u.service.d/locsec-apparmor.conf)"
      pid=$(systemctl show -p MainPID --value $u 2>/dev/null)
      if [ -n "$MODE" ] && grep -q "^$p ($MODE)" /proc/$pid/attr/current 2>/dev/null; then ok "$u process is confined by $p ($MODE)"
      else warn "$u process label is '$(cat /proc/$pid/attr/current 2>/dev/null)', want $p (${MODE:-complain or enforce}); restart it once (sudo systemctl restart $u)"; fi
    done
    if atleast 5.0-3; then
      # 5.0-3: without attach_disconnected the kernel drops every file handed between the two halves
      # (capture, deep analysis, AIDE report, root-only logs) although the log line says ALLOWED.
      for p in locsecd-web locsecd-broker; do
        grep -Eq "^profile $p flags=\([^)]*attach_disconnected" /etc/apparmor.d/locsecd 2>/dev/null && ok "$p has attach_disconnected" || bad "$p in /etc/apparmor.d/locsecd lacks attach_disconnected (an edited conffile kept at upgrade?)"
      done
      SINCE=$(systemctl show -p ActiveEnterTimestamp --value locsecd-broker 2>/dev/null)
      nd=$(journalctl -k --since "${SINCE:-today}" --no-pager 2>/dev/null | grep -E 'profile="locsecd-(web|broker)' | grep -c 'Failed name lookup - disconnected path')
      [ "$nd" = 0 ] && ok "no disconnected-path lines from the LocSec profiles since the broker started" || { bad "$nd disconnected-path lines since the broker started (files dropped between the halves):"; journalctl -k --since "${SINCE:-today}" --no-pager | grep -E 'profile="locsecd-(web|broker)' | grep 'disconnected path' | tail -5; }
      nf=$(journalctl -t locsecd-broker --since "${SINCE:-today}" --no-pager -o cat 2>/dev/null | grep -cE 'arrived without its file descriptor|too many file descriptors')
      [ "$nf" = 0 ] && ok "no request lost its file descriptor since the broker started" || bad "$nf requests lost their file descriptor since the broker started (journalctl -t locsecd-broker)"
    fi
    ASINCE=$(systemctl show -p ActiveEnterTimestamp --value locsecd-broker 2>/dev/null)
    na=$(journalctl -k --since "${ASINCE:-today}" --no-pager 2>/dev/null | grep 'apparmor="ALLOWED"' | grep -cE 'profile="locsecd-(web|broker)')
    [ "$na" = 0 ] && ok "no ALLOWED lines from the LocSec profiles since the broker started" || { warn "$na ALLOWED lines from the LocSec profiles since the broker started (what enforce mode would block; the distinct ones are listed under enforce readiness below):"; journalctl -k --since "${ASINCE:-today}" --no-pager | grep 'apparmor="ALLOWED"' | grep -E 'profile="locsecd-(web|broker)' | tail -4; }
  else
    ls /etc/systemd/system/locsecd*.service.d/locsec-apparmor.conf >/dev/null 2>&1 && bad "AppArmor is off or the profile disabled, but a LocSec AppArmor drop-in is present" || ok "AppArmor off or profile disabled, and no LocSec AppArmor drop-in"
  fi
fi
if atleast 5.0-6; then
  # 5.0-6: is it safe to switch the LocSec profiles from complain to enforce? Only when, after a full walk
  # through the dashboard (every scan, a capture and its analysis, an update, a quarantine and a restore),
  # the profiles logged no ALLOWED line: every ALLOWED line is something enforce mode would block.
  # LOCSEC_VMCHECK_KLOG=file reads the kernel log lines from a file instead (to test this report).
  echo "== AppArmor enforce readiness (report only; nothing is changed) =="
  ENFN=$(grep -cE '^locsecd-(web|broker) \(enforce\)' ${LOCSEC_VMCHECK_AAPROFILES:-/sys/kernel/security/apparmor/profiles} 2>/dev/null)
  # Only lines since the broker last started (an install or upgrade restarts it): older lines belong to the
  # previous version's profile and would be counted against this one.
  RSINCE=$(systemctl show -p ActiveEnterTimestamp --value locsecd-broker 2>/dev/null)
  if [ -n "${LOCSEC_VMCHECK_KLOG:-}" ]; then KL=$(cat "$LOCSEC_VMCHECK_KLOG" 2>/dev/null); else KL=$(journalctl -k --since "${RSINCE:-today}" --no-pager 2>/dev/null); fi
  AL=$(printf '%s\n' "$KL" | grep 'apparmor="ALLOWED"' | grep -E 'profile="locsecd-(web|broker)')
  if [ -z "$AL" ]; then
    if [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = Y ] || [ -n "${LOCSEC_VMCHECK_KLOG:-}" ]; then
      if [ "${ENFN:-0}" -ge 2 ]; then ok "both LocSec profiles are in enforce mode and nothing was blocked (no DENIED line for them above); undo: sudo aa-complain /etc/apparmor.d/locsecd"
      else ok "enforce readiness: the LocSec profiles logged no ALLOWED line since the broker started. If you have used every dashboard function since then they can be switched to enforce: sudo aa-enforce /etc/apparmor.d/locsecd (undo: sudo aa-complain /etc/apparmor.d/locsecd; both come from the apparmor-utils package: sudo apt install apparmor-utils)"; fi
    else warn "enforce readiness: AppArmor is off, so there is nothing to report"; fi
  else
    NA=$(printf '%s\n' "$AL" | grep -c .)
    warn "enforce readiness: NOT ready. $NA ALLOWED line(s) from the LocSec profiles; enforce mode would block them. Distinct profile, operation, mask and path, with counts:"
    printf '%s\n' "$AL" | sed -E 's/.*operation="([^"]*)".*profile="([^"]*)".*[ ]name="([^"]*)".*requested_mask="([^"]*)".*/\2 \1 \4 \3/;t;s/.*operation="([^"]*)".*profile="([^"]*)".*/\2 \1 - -/' \
      | sed -E 's#(/proc/)[0-9]+#\1PID#; s#(/run/user/)[0-9]+#\1UID#; s#(locsecd-[a-z]+-p)[0-9]+-[0-9a-f]+#\1PID-ID#' | sort | uniq -c | sort -rn | head -25 | sed 's/^/    /'
    echo "    Add a rule for each wanted line to /etc/apparmor.d/local/locsecd-web or /etc/apparmor.d/local/locsecd-broker, reload with: sudo apparmor_parser -r /etc/apparmor.d/locsecd, repeat the walkthrough, then run this check again."
  fi
fi
echo "== ClamAV =="
if atleast 5.0-6; then
  # 5.0-6: a ClamAV batch runs as the clamav user with CAP_DAC_READ_SEARCH as its only (ambient) capability,
  # the way the broker starts it. It must still read a root-only file (clamdscan --fdpass), and must NOT be
  # able to write a file root owns (before 5.0-6 the unit was uid 0 and could).
  if id clamav >/dev/null 2>&1 && command -v clamdscan >/dev/null && command -v systemd-run >/dev/null && systemctl is-active --quiet clamav-daemon; then
    CT=$(mktemp -d /var/tmp/locsec-clam.XXXXXX); chmod 755 "$CT"; CFILE=$CT/rootonly.txt
    echo "LocSec check file" > "$CFILE"; chmod 600 "$CFILE"
    CUNIT=(systemd-run --pipe --wait --collect --quiet --property=AmbientCapabilities= --property=AmbientCapabilities=CAP_DAC_READ_SEARCH
           --property=User=clamav --property=CapabilityBoundingSet=CAP_DAC_READ_SEARCH --property=NoNewPrivileges=yes
           --property=IPAddressDeny=any --property=IPAddressAllow=localhost --property=RestrictAddressFamilies="AF_UNIX AF_INET AF_INET6")
    CR=$("${CUNIT[@]}" clamdscan --fdpass "$CFILE" 2>&1); crc=$?
    if [ "$crc" = 0 ]; then ok "a unit started as the clamav user with CAP_DAC_READ_SEARCH scans a root-only file with --fdpass"
    else bad "a ClamAV unit as the clamav user could not scan a root-only file with --fdpass (rc=$crc): $(printf '%s' "$CR" | tail -2 | tr '\n' ' ')"; fi
    # The unit exits 0 whatever happens (5.0-10): a failing unit shows up as a "Problem" on LocSec's Logs page.
    "${CUNIT[@]}" sh -c "echo changed >> '$CFILE' 2>/dev/null; exit 0" >/dev/null 2>&1
    if [ "$(cat "$CFILE")" = "LocSec check file" ]; then ok "the same unit cannot write a file root owns"
    else bad "the ClamAV unit changed a root-owned file (before 5.0-6 it could; the clamav user setting is not applied)"; fi
    rm -rf "$CT"
  else warn "ClamAV probe skipped (needs the clamav account, clamdscan, systemd-run and an active clamav-daemon)"; fi
  nfp=$(journalctl -t locsecd-broker --since "$(systemctl show -p ActiveEnterTimestamp --value locsecd-broker 2>/dev/null || echo today)" --no-pager -o cat 2>/dev/null | grep -c 'fdpass failed')
  [ "$nfp" = 0 ] && ok "no 'ClamAV fdpass failed' line since the broker started" || warn "$nfp 'fdpass failed' line(s) since the broker started: ClamAV fell back to --stream (journalctl -t locsecd-broker | grep 'fdpass failed')"
fi
systemctl is-active --quiet clamav-daemon && ok "clamav-daemon active" || { ls /var/lib/clamav/main.c[vl]d >/dev/null 2>&1 && warn "clamav-daemon not active though signatures exist (from -102 LocSec starts it within 5 minutes of the first download)" || warn "clamav-daemon not active: no signatures yet (freshclam still downloading?)"; }
if atleast 4.0.11-102; then
  grep -qE '^ExcludePath \^/(run|snap|home/\\\.ecryptfs)/$' /etc/clamav/clamd.conf 2>/dev/null && warn "clamd.conf still has ExcludePath lines an older LocSec added (left because the file was also edited otherwise)" || ok "clamd.conf has no LocSec-added lines"
fi
if atleast 5.0-2 && [ -f /etc/suricata/suricata.yaml.locsec-orig ]; then
  echo "== Suricata on purge =="
  M=/var/lib/locsecd-broker/suricata-restore.sha256
  if [ -f "$M" ] && sha256sum -c --status "$M" 2>/dev/null; then ok "suricata.yaml is still what LocSec wrote: a purge puts suricata.yaml.locsec-orig back"
  else warn "suricata.yaml was changed after LocSec last wrote it (or an older LocSec wrote it): a purge leaves it and suricata.yaml.locsec-orig as they are"; fi
fi
echo "== Dependencies =="
for t in ufw aide lynis rkhunter clamdscan suricata tcpdump debsecan; do command -v $t >/dev/null && ok "tool present: $t" || warn "tool missing: $t"; done
echo "== Optional tools =="
for pair in aa-enforce:apparmor-utils capsh:libcap2-bin curl:curl; do
  t=${pair%%:*}; pk=${pair#*:}
  command -v "$t" >/dev/null 2>&1 && ok "optional tool present: $t ($pk)" || warn "optional tool missing: $t (package $pk): sudo apt install $pk, or run this script with --install-missing"
done
echo; echo "== Manual checks still needed =="
cat <<'M'
 1 Open the dashboard window from the menu (and 'locsecctl gui'); confirm the polkit prompt, tray icon, notifications. Note the desktop and session above.
 2 Dashboard: run each scan once; Update system; block + unblock an address; capture + Analyze + Deep analysis; quarantine + restore a test file (EICAR); look at every Logs source.
 3 After step 2:  sudo journalctl -t locsecd-broker --since '30 min ago' | grep -i refus   -- anything refused that you expected to work?
   (Use a --since time after this script's attack test, whose refusals are expected. Each line names the caller's pid and uid.)
 4 Stop locsecd mid-scan:  sudo systemctl stop locsecd; systemctl list-units 'locsecd-*'   -- nothing left running?
   5.0-3: after step 2, run this script again: the descriptor-transit checks cover the capture, Deep analysis, AIDE and Lynis runs.
   5.0-5: the capture check above covers a capture; still try Analyze and Deep analysis on one from the dashboard.
   5.0-3, after the ClamAV scan:  sudo journalctl -t locsecd-broker --since '30 min ago' | grep -i 'fdpass failed'   -- nothing?
   5.0-2, during a capture:  systemctl list-units 'locsecd-capture-*'; ps -o user=,cmd= -C tcpdump   -- one unit, user tcpdump?
   And during each scan:  systemctl show -p CapabilityBoundingSet 'locsecd-scan-*' 'locsecd-clamav-*'   -- not the full list?
 5 Reboot; then repeat this script. Finally: sudo apt purge locsecd; check /var/lib/locsecd* are gone; reinstall.
M
echo; echo "SUMMARY: $P passed, $F failed, $W warnings"; [ $F = 0 ]
