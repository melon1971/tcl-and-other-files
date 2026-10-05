#!/bin/bash
# LocSec post-install check (4.0.11-91 and later; the log-format checks need 4.0.11-98, the unit check 4.0.11-103). Run as root on a real machine AFTER installing the .deb:
#   sudo bash locsec-vm-check.sh [path/to/attack_as_web.py]
# Prints PASS/FAIL/WARN per check and a summary. Changes nothing except a short ufw status read
# and (if an attack script is given) running it as the locsec user. Send the whole output back.
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 2; }
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
V=$(dpkg-query -W -f='${Version}' locsecd 2>/dev/null); R=${V##*-}
if [ "${V%-*}" = "4.0.11" ] && [ "$R" -ge 91 ] 2>/dev/null; then ok "locsecd $V installed (two-service build, 4.0.11-91 or later)"; else bad "locsecd installed version is '$V'; this script is for 4.0.11-91 or later"; fi
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
if [ "$R" -ge 98 ] 2>/dev/null; then
  for u in locsecd locsecd-broker; do
    [ "$(systemctl show -p SyslogIdentifier --value $u 2>/dev/null)" = "$u" ] && ok "$u logs to the journal as '$u'" || bad "$u SyslogIdentifier is '$(systemctl show -p SyslogIdentifier --value $u 2>&1)', want $u"
  done
fi
systemd-analyze verify /lib/systemd/system/locsecd.service /lib/systemd/system/locsecd-broker.service 2>&1 | sed 's/^/verify: /'
echo "== Dashboard =="
chk "listens on 127.0.0.1:8765" bash -c "ss -ltn | grep -q '127.0.0.1:8765'"
ss -ltn | grep -q '0.0.0.0:8765\|\[::\]:8765' && bad "dashboard listening on a non-local address" || ok "dashboard not on a non-local address"
code=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8765/ 2>/dev/null); [ "$code" = 401 ] || [ "$code" = 403 ] || [ "$code" = 200 ] && ok "HTTPS answers without token (HTTP $code)" || bad "HTTPS gave '$code'"
echo "== CLI =="
chk "locsecctl broker-verbs lists 62" bash -c 'locsecctl broker-verbs | grep -c . | awk "{exit !(\$1>=62)}"'
chk "locsecctl status runs" locsecctl status
echo "== Broker refuses and journal =="
if [ -n "${1:-}" ] && [ -f "$1" ]; then
  # The locsec user cannot read a home folder, so run a private copy from /tmp.
  A=$(mktemp /tmp/locsec-attack.XXXXXX.py); cp "$1" "$A"; chmod 644 "$A"
  START=$(date '+%Y-%m-%d %H:%M:%S'); sleep 1
  if setpriv --reuid=locsec --regid=locsec --init-groups python3 "$A" 2>&1 | tail -15 | tee /tmp/attack.out | grep -q "all attempts refused"; then ok "attack script: all attempts refused"; else bad "attack script did not end with 'all attempts refused' (see output)"; tail -15 /tmp/attack.out; fi
  rm -f "$A"; sleep 2
  if [ "$R" -ge 98 ] 2>/dev/null; then
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
if dmesg 2>/dev/null | grep -qi 'apparmor="DENIED"'; then warn "AppArmor DENIED lines (keep these):"; dmesg | grep -i 'apparmor="DENIED"' | tail -10; else ok "no AppArmor DENIED in dmesg"; fi
if [ "$R" -ge 103 ] 2>/dev/null; then if grep -qs '^AppArmorProfile=' /lib/systemd/system/locsecd.service /lib/systemd/system/locsecd-broker.service; then bad "a LocSec unit names an AppArmor profile (4.0.11-103 removed these)"; else ok "units name no AppArmor profile (none is loaded)"; fi; fi
echo "== ClamAV =="
systemctl is-active --quiet clamav-daemon && ok "clamav-daemon active" || { ls /var/lib/clamav/main.c[vl]d >/dev/null 2>&1 && warn "clamav-daemon not active though signatures exist (from -102 LocSec starts it within 5 minutes of the first download)" || warn "clamav-daemon not active: no signatures yet (freshclam still downloading?)"; }
if [ "$R" -ge 102 ] 2>/dev/null; then
  grep -qE '^ExcludePath \^/(run|snap|home/\\\.ecryptfs)/$' /etc/clamav/clamd.conf 2>/dev/null && warn "clamd.conf still has ExcludePath lines an older LocSec added (left because the file was also edited otherwise)" || ok "clamd.conf has no LocSec-added lines"
fi
echo "== Dependencies =="
for t in ufw aide lynis rkhunter clamdscan suricata tcpdump debsecan; do command -v $t >/dev/null && ok "tool present: $t" || warn "tool missing: $t"; done
echo; echo "== Manual checks still needed =="
cat <<'M'
 1 Open the dashboard window from the menu (and 'locsecctl gui'); confirm the polkit prompt, tray icon, notifications. Note the desktop and session above.
 2 Dashboard: run each scan once; Update system; block + unblock an address; capture + Analyze + Deep analysis; quarantine + restore a test file (EICAR); look at every Logs source.
 3 After step 2:  sudo journalctl -t locsecd-broker --since '30 min ago' | grep -i refus   -- anything refused that you expected to work?
   (Use a --since time after this script's attack test, whose refusals are expected. Each line names the caller's pid and uid.)
 4 Stop locsecd mid-scan:  sudo systemctl stop locsecd; systemctl list-units 'locsecd-*'   -- nothing left running?
 5 Reboot; then repeat this script. Finally: sudo apt purge locsecd; check /var/lib/locsecd* are gone; reinstall.
M
echo; echo "SUMMARY: $P passed, $F failed, $W warnings"; [ $F = 0 ]
