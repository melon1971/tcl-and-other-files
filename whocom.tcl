# Hardened audit revision: access controls, input validation, and safer defaults applied.
# whocom.tcl — multi-lookup command pack for Eggdrop
#
# Channel commands:
#   !wa <nick>        -> /WHOWAS <nick>
#   !wi <nick>        -> /WHOIS <nick>
#   !pi <nick>       -> CTCP PING <nick>, reports round-trip time
#   !ver <nick>        -> CTCP VERSION <nick>
#   !dom <domain>   -> whois lookup on a domain (raw TCP whois, with RDAP/HackerTarget fallbacks)
#   !ip <address>      -> geolocation/ASN lookup on an IPv4/IPv6 address (with fallbacks)
#   !whohelp           -> lists all of the above
#
# All of the above answer in every channel the bot is on by default; set
# $channels in the config block to a list of channels to restrict them
# (all seven commands, including !whohelp) to just those.
#
# Requires: package "http" (bundled with Tcl). For the https:// lookups used
# by !dom (RDAP fallback) and !ip you also need the "tls" package (tcllib's
# tcl-tls / tcltls). If tls isn't installed, https requests are skipped and
# whocom falls back to the next configured source, or reports that no source
# was reachable. The primary !dom source is a raw TCP port-43 whois query,
# which needs neither http nor tls.
#
# HackerTarget's WHOIS API now requires a key ("error valid key required"
# from an unauthenticated request) -- set hackertarget_apikey in the config
# block below if you have one, otherwise that fallback source is skipped.
#
# Install:
#   1. Drop this file in your eggdrop's scripts/ dir.
#   2. Add:  source scripts/whocom.tcl
#      to your eggdrop.conf, then .rehash or restart the bot.
#   3. Adjust the config block below to taste, including tls_verify.

package require http

namespace eval whocom {
    # Runtime state (cooldown windows, in-flight lookup queues) is
    # initialized once, further down, by the load-once guard (see
    # whocom::state_loaded), so a .rehash doesn't reset everyone's
    # rate-limit window or drop a lookup that is still in flight.

    # ---------------- Configuration ----------------
    #
    # Every setting in this section (through ip_sources below) is a plain
    # `set`, so the current value is applied on every load and every
    # .rehash. The live state further down (q_whois and friends) is
    # declared with a bare `variable` and initialised only once, by the
    # whocom::state_loaded guard, so a rehash can't reset it.

    # Command triggers
    set trig_wa      "!wa"
    set trig_wi      "!wi"
    set trig_ping    "!pi"
    set trig_ver     "!ver"
    set trig_domain  "!dom"
    set trig_ip      "!ip"
    set trig_help    "!whohelp"

    # Where replies go: "chan" (public in the triggering channel) or
    # "notice" (notice to the person who triggered it). Private messages
    # are disabled for this script -- there is no "msg" destination and
    # no way to trigger a command via /msg either; setting a dest_* value
    # to "msg" is treated the same as "notice" (see whocom::reply).
    set dest_wa      "notice"
    set dest_wi      "notice"
    set dest_ping    "notice"
    set dest_ver     "notice"
    set dest_domain  "notice"
    set dest_ip      "notice"
    set dest_help    "notice"

    # Access control. Leave as "" to let anyone in the channel use a
    # command. Set to an eggdrop flag (e.g. "o" for chanops) to require it.
    # These are intentionally configurable. An empty value means any
    # channel user may use the command; set an Eggdrop flag such as "o"
    # to require channel-operator privileges. For a public bot, consider
    # requiring "o" or another restricted flag for WHOIS/WHOWAS/CTCP.
    set need_flag_wa      ""
    set need_flag_wi      ""
    set need_flag_ping    ""
    set need_flag_ver     ""
    set need_flag_domain  ""
    set need_flag_ip      ""

    # Which channels ALL of these public commands (including !whohelp)
    # answer in. Empty list {} (the default) = every channel the bot is
    # on. Non-empty = only those channels, exact match, case-insensitive.
    # Checked first in every cmd_* proc, ahead of the flag/cooldown/onchan
    # checks, and fails completely silently -- a channel outside $channels
    # should look like the bot has none of these commands at all there,
    # not like a permission wall. Validated below: trimmed, must start
    # with #/&/+/!, 2-64 chars, no whitespace/commas/control bytes, capped
    # at 64 entries.
    set channels {}

    # Per-user cooldown (seconds) between command uses. Adjust to taste.
    set cooldown 15

    # Whether "cooldown" is tracked per user across ALL commands, or
    # separately per user+command. "user" (default): using !wi and then
    # immediately !dom counts as one use of the same window. "command":
    # each command gets its own independent per-user cooldown window
    # (the original behavior), so !wi and !dom don't share a timer.
    set cooldown_scope "user"

    # Minimum seconds between *any* two !dom/!ip HTTP lookups, shared
    # across all users -- a milder backstop (separate from the per-user
    # "cooldown" above) so several different people looking up domains/IPs
    # at once still can't collectively hammer the free third-party APIs
    # fast enough to get the bot's own IP rate-limited or banned by them.
    # Set to 0 to disable.
    set http_cooldown 2
    # http_lastuse is runtime state, not config -- declared (not reset) in
    # the validation block near the end of this file, so a .rehash does not
    # clear the cross-user backstop that keeps the free lookup APIs from
    # rate-limiting or banning this bot's IP.

    # Maximum user supplied argument size
    set max_arg_length 64

    # If enabled, !wi/!pi/!ver require the target to be in the
    # triggering channel. Set to 0 to allow IRC-wide nick lookups and
    # CTCP probes. With this disabled, IRC server nick routing lets
    # !pi/!ver reach a nick even when they are not in this channel.
    # !wa is always exempt because it queries WHOWAS.
    set restrict_onchan 0

    # How long (seconds) to wait for a server WHOIS/WHOWAS to finish, or
    # for a CTCP PING/VERSION reply, before giving up.
    set irc_timeout 15
    set ctcp_timeout 12

    # HTTP timeout for domain/IP lookups, in milliseconds.
    set http_timeout 8000

    # Hard cap on how many bytes of an HTTP response body we'll buffer
    # before aborting the request. These lookups only ever expect small
    # JSON/text payloads; without a cap a malicious or compromised
    # upstream could send an arbitrarily large body and exhaust memory.
    set http_max_body 262144

    # Max HTTP redirects to follow for a single lookup (rdap.org's
    # redirector needs at least one hop). Kept low since each hop is a
    # fresh network round-trip.
    set http_max_redirects 3

    # HTTPS certificate verification. Keep enabled unless the host running
    # Eggdrop has a known reason to use an unverified TLS connection.
    set tls_verify 1

    # TLS protocol range for HTTPS. Only protocols supported by TclTLS
    # and inside this range are enabled on the transport.
    set tls_min_version "tls1.2"
    set tls_max_version "tls1.3"

    # HackerTarget's free WHOIS API now rejects anonymous requests
    # ("error valid key required"). Get a key at hackertarget.com and
    # put it here to re-enable that source; leave "" to skip it
    # entirely (it will otherwise fail -- and log noise -- on every
    # single lookup).
    set hackertarget_apikey ""

    # Timeout (milliseconds) for the raw TCP whois (port 43) source.
    set whois_tcp_timeout 6000

    # Maximum number of simultaneous raw WHOIS TCP connections. This is a
    # process-wide backstop in addition to the per-user cooldown, so many
    # users (or many changing nicks) cannot make the bot hold an unbounded
    # number of outbound sockets open at once.
    set max_whois_connections 16

    # Authoritative WHOIS server per TLD, for the common ones where a
    # direct query avoids an extra referral round trip. TLDs not listed
    # here skip raw WHOIS and fall through to the HTTPS RDAP source; this
    # intentionally avoids trusting an unauthenticated plaintext IANA
    # referral as a new outbound connection target.
    set whois_tld_servers {
        com  whois.verisign-grs.com
        net  whois.verisign-grs.com
        org  whois.pir.org
        info whois.afilias.net
        biz  whois.biz
        io   whois.nic.io
        co   whois.nic.co
        dev  whois.nic.google
        app  whois.nic.google
        xyz  whois.nic.xyz
        me   whois.nic.me
        us   whois.nic.us
        uk   whois.nic.uk
    }

    # Domain lookup sources, tried in order until one succeeds.
    # Each entry is {label url-with-%s-for-domain parser-proc}. The
    # "WHOIS" entry has no HTTP URL (its url field is unused) --
    # try_domain_source special-cases that label to run a raw TCP
    # port-43 query instead. It's listed first since it doesn't depend
    # on rdap.org being reachable (which has been timing out) or on
    # HackerTarget's now-gated API, and a plain whois query is usually
    # both faster and more reliable than either.
    set domain_sources {
        {"WHOIS"        ""                                              whocom::parse_hackertarget_whois}
        {"RDAP"        "https://rdap.org/domain/%s"                    whocom::parse_rdap}
        {"HackerTarget" "https://api.hackertarget.com/whois/?q=%s"     whocom::parse_hackertarget_whois}
    }

    # IP lookup sources, tried in order until one succeeds.
    # Only HTTPS sources are used; plaintext third-party lookups are
    # intentionally excluded.
    set ip_sources {
        {"ipwho.is" "https://ipwho.is/%s"              whocom::parse_ipwhois}
    }

    # -----------------------------------------------

    # Internal state (do not edit)
    variable q_whois   ;# array: lc(nick) -> list of pending {requester chan dest}
    variable q_whowas
    variable q_ping
    variable q_ver
    variable buf_whois  ;# array: lc(nick) -> accumulated info array
    variable buf_whowas
    variable gen_whois   ;# array: lc(nick) -> generation counter (stale-timer guard)
    variable gen_whowas
    variable gen_ver     ;# array: lc(nick) -> generation counter (stale-timer guard)
    variable lastuse    ;# array: "cmd,hostmask" -> unixtime
    variable cooldown_notified ;# array: "cmd,hostmask" -> 1 (already told to slow down)
    variable whois_conns ;# array: socket -> dict (state for in-flight raw TCP whois queries)
    variable max_waiters_per_target 16
    variable max_waiters_total 128
}

# Bug fix: these arrays used to be reset with a bare `array set foo {}`
# sitting directly in the namespace eval block above, which ran in full
# on EVERY source of this file -- including a plain `.rehash`, which
# re-sources the whole script without restarting the process. That
# silently wiped every in-flight lookup on every rehash:
#   - q_whois/q_whowas/q_ver queued callers lost their entry, and the
#     already-scheduled utimer timeout for it then found gen_*($key)
#     gone and returned immediately -- the caller got no reply and no
#     timeout message, ever.
#   - whois_conns (the raw port-43 socket state behind !dom) losing its
#     entry is worse: the open socket, its fileevent, and its pending
#     `after` timeout are real OS/Tcl resources that a variable reset
#     does not tear down. When the timer or fileevent later fired,
#     whois_tcp_fail/whois_tcp_finish/whois_tcp_connected/
#     whois_tcp_readable all bail out on `![info exists whois_conns($sock)]`
#     without ever calling `close $sock` -- leaking one file descriptor
#     per rehash that happened to land mid-query. On a bot rehashed
#     periodically (config sync, cron, etc.) that's a slow, real fd leak.
#
# Fixed by only initializing these on the FIRST source (this guard), the
# same load-once pattern already used correctly for the `bind`s below.
# A `.rehash` now leaves in-flight queues, buffers, and open whois
# sockets untouched; only a full `.restart` (fresh interpreter) clears
# them, which is safe since nothing can be in flight across a restart.
if {![info exists whocom::state_loaded] || !$whocom::state_loaded} {
    namespace eval whocom {
        array set q_whois {}
        array set q_whowas {}
        array set q_ping {}
        array set q_ver {}
        array set buf_whois {}
        array set buf_whowas {}
        array set gen_whois {}
        array set gen_whowas {}
        array set gen_ver {}
        array set lastuse {}
        array set cooldown_notified {}
        array set whois_conns {}
        variable state_loaded 1
    }
}

# ================= helpers =================

# REMOVED, as dead or actively worse than what already exists:
#
#   whocom::valid_domain / whocom::valid_ip
#       Neither had a single caller. cmd_domain and cmd_ip each do their
#       own, much stricter validation inline (a real label-structure
#       regexp for domains; per-octet IPv4 plus an IPv6 shape for
#       addresses), and these two were the loose early drafts of that --
#       valid_ip in particular accepted "...." and ":::::" as an address.
#       Keeping a laxer copy of a security check around is how the wrong
#       one eventually gets called.
#
#   whocom::ratelimit / cleanup_ratelimit / schedule_ratelimit_cleanup
#       A second, parallel cooldown that only !ip ever consulted, keyed on
#       NICK where whocom::allowed -- which !ip also calls, two lines
#       later -- is keyed on HOSTMASK. Two limiters reading the same
#       `cooldown` value, one of which any user defeats by changing nick,
#       is not defence in depth; it is a weaker check shadowing a stronger
#       one, plus a self-perpetuating `after` chain and an array to sweep.
#       The hostmask-keyed whocom::allowed does the job for every command
#       including !ip, so the nick-keyed copy and its cleanup timer are
#       gone. (The `ratelimit` array declaration in the namespace block
#       and the schedule call at the end of the file went with them.)

proc whocom::lc {s} { return [string tolower $s] }

# Register a public trigger, remembering what was ACTUALLY bound so the
# next source can unbind that rather than the current config value.
#
# Every pub bind in this file was written as
#     catch { unbind pub - $whocom::trig_wi whocom::cmd_wi }
#     bind   pub -         $whocom::trig_wi whocom::cmd_wi
# which is correct only for as long as nobody edits a trigger. The moment
# an admin changes trig_wi to "!w" and rehashes, the unbind names the NEW
# trigger -- a registration that does not exist -- so it does nothing, the
# OLD "!wi" bind stays live alongside the new "!w", and both answer for the
# rest of the process's life: two replies, two WHOIS queries, two cooldown
# consumptions per command. $slot is a stable name for the registration so
# a renamed trigger is still found and removed.
namespace eval whocom {
    variable bound_pub
    if {![info exists bound_pub]} { array set bound_pub {} }
}

proc whocom::bind_pub {slot trigger procname} {
    variable bound_pub
    if {[info exists bound_pub($slot)]} {
        lassign $bound_pub($slot) oldtrig oldproc
        catch { unbind pub - $oldtrig $oldproc }
        unset bound_pub($slot)
    }
    # Also clear a registration made by an older revision of this file,
    # which bound the literal current value with no slot tracking.
    catch { unbind pub - $trigger $procname }
    if {[string trim $trigger] eq ""} {
        putlog "whocom: refusing to bind $procname to an empty trigger"
        return 0
    }
    if {[catch { bind pub - $trigger $procname } err]} {
        putlog "whocom: failed to bind $trigger -> $procname: $err"
        return 0
    }
    set bound_pub($slot) [list $trigger $procname]
    return 1
}

# Reply to $chan/$nick according to a dest mode ("chan"/"notice").
# Strips CR/LF/control chars and caps length before it ever reaches
# putserv, since some of what we relay (WHOIS realname/away text, JSON
# fields from third-party APIs) originates outside our control.
#
# Private messages are hard-disabled: "msg" is not an available dest mode.
# There is no "bind msg" anywhere in this script either, so the bot never
# sends OR accepts a private message for any of these commands -- every
# reply goes to the channel (default) or as a NOTICE, never a PRIVMSG to
# a user. If a dest_* config variable is left/set to "msg" (e.g. from an
# older config), it's treated as "notice" rather than honored, so private
# messaging can't be re-enabled by accident via config.
proc whocom::reply {dest chan nick text} {
    # Sanitized once, not twice: every branch re-ran whocom::sanitize on
    # text the first line had already sanitized. Harmless but it made the
    # single point of control look like three.
    set text [whocom::sanitize $text]
    if {$text eq ""} { return }
    switch -- $dest {
        notice  -
        msg     { putserv "NOTICE $nick :$text" }
        default { putserv "PRIVMSG $chan :$text" }
    }
}

# Strip characters that have no business in a single IRC line (raw
# CR/LF would forge a second line; other control chars are just noise)
# and cap length so one field can't blow past the 512-byte line limit.
# \x02 (the mIRC bold toggle) is deliberately left out of the stripped
# range so whocom::bold-wrapped labels survive to the client.
#
# This no longer force-lowercases the whole line. Individual call sites
# are responsible for lowering their own externally-sourced text
# (registries/CTCP/third-party APIs love to shout, e.g. "GOOGLE.COM" /
# "NS1.GOOGLE.COM") via [string tolower ...] where that normalization
# still matters; a handful of labels ([WHOIS], [WHOWAS n], the domain
# field names, [IP Lookup]) are deliberately left both cased and bold.
proc whocom::sanitize {text} {
    set text [regsub -all {[\r\n\x00\x01\x03-\x08\x0b\x0c\x0e-\x1f\x7f]} $text ""]
    # Cap on BYTES as they go on the wire, not characters. Almost
    # everything relayed here comes from outside -- WHOIS realnames, CTCP
    # VERSION replies, and geolocation JSON whose city/region/org fields
    # are routinely non-ASCII ("Zürich", "São Paulo", a CJK ISP name). A
    # 400-CHARACTER line of those is up to 1200 bytes, well past IRC's
    # 512-byte limit, so the server truncated exactly the lines this cap
    # exists to keep intact. Cut on a character boundary so a multi-byte
    # codepoint is never severed into invalid UTF-8.
    if {[catch { string length [encoding convertto utf-8 $text] } blen]} {
        set blen [string length $text]
    }
    if {$blen <= 400} { return $text }
    set out ""
    set used 0
    foreach ch [split $text ""] {
        if {[catch { string length [encoding convertto utf-8 $ch] } cb]} { set cb 1 }
        if {$used + $cb > 396} { break }
        append out $ch
        incr used $cb
    }
    return "${out}..."
}

# Wrap text in the mIRC bold toggle. Two toggles (open/close) rather
# than a reset code, so this composes safely inside a larger line.
proc whocom::bold {s} {
    return "\x02${s}\x02"
}

# Cooldown check. Returns 1 if allowed (and records the use), 0 if the
# caller is on cooldown. Keyed by hostmask rather than eggdrop handle:
# most people on a public channel have no bot userlist entry, so their
# handle is just "*" -- keying on that would collapse every anonymous
# user's cooldown into one shared bucket.
#
# When cooldown_scope is "user" (default), the key omits $cmd, so one
# cooldown window is shared across every whocom command for that user.
# When cooldown_scope is "command", the key includes $cmd, so each
# command gets its own independent per-user window.
proc whocom::allowed {cmd uhost} {
    variable cooldown
    variable cooldown_scope
    variable lastuse
    variable cooldown_notified
    set key [whocom::cooldown_key $cmd $uhost]
    set now [clock seconds]

    # Cheap periodic prune so these arrays don't grow forever on a
    # long-running bot: sweep on ~1 in 50 calls.
    if {[expr {int(rand() * 50)}] == 0} {
        foreach k [array names lastuse] {
            if {($now - $lastuse($k)) > 3600} { unset lastuse($k) }
        }
        foreach k [array names cooldown_notified] {
            if {![info exists lastuse($k)]} { unset cooldown_notified($k) }
        }
    }

    if {[info exists lastuse($key)] && ($now - $lastuse($key)) < $cooldown} {
        return 0
    }
    set lastuse($key) $now
    ;# fresh cooldown window starting -- clear so the next time this user
    ;# gets throttled they see a notice again instead of staying silenced
    ;# from a previous window forever.
    catch {unset cooldown_notified($key)}
    return 1
}

# Called instead of a bare whocom::reply whenever whocom::allowed refuses a
# command. A user hammering a command while on cooldown would otherwise get
# a "slow down" notice for *every* attempt -- itself a flood, against the
# user and against the bot's own output. This sends at most one notice per
# user per cooldown window, then stays silent until the window resets.
# Builds the array key used by whocom::allowed / whocom::cooldown_notice,
# honoring cooldown_scope -- see whocom::allowed for what each mode means.
proc whocom::cooldown_key {cmd uhost} {
    variable cooldown_scope
    if {$cooldown_scope eq "command"} {
        return "$cmd,[string tolower $uhost]"
    }
    return [string tolower $uhost]
}

proc whocom::cooldown_notice {cmd uhost dest chan nick {msg "Slow down a bit before running that again."}} {
    variable cooldown_notified
    set key [whocom::cooldown_key $cmd $uhost]
    if {[info exists cooldown_notified($key)]} { return }
    set cooldown_notified($key) 1
    whocom::reply $dest $chan $nick $msg
}

# Separate, milder throttle just for the outbound HTTP lookups (!dom /
# !ip): several different users (or one user cycling nicks) could
# otherwise still collectively hammer the free third-party APIs fast
# enough to get the bot's IP rate-limited or banned by them, even though
# each of them individually respects their own per-user "cooldown".
# Disabled (always allowed) when http_cooldown is 0.
proc whocom::http_allowed {} {
    variable http_cooldown
    variable http_lastuse
    if {$http_cooldown <= 0} { return 1 }
    set now [clock seconds]
    if {[info exists http_lastuse] && ($now - $http_lastuse) < $http_cooldown} {
        return 0
    }
    set http_lastuse $now
    return 1
}

proc whocom::has_flag {need hand chan} {
    if {$need eq ""} { return 1 }
    return [matchattr $hand $need $chan]
}

# Which channels the public commands are scoped to. Empty = every channel
# the bot is on; non-empty = exact, case-insensitive match against
# $channels. See the $channels declaration above for why every cmd_* proc
# checks this first and returns silently rather than replying.
proc whocom::channel_allowed {chan} {
    variable channels
    if {[llength $channels] == 0} { return 1 }
    foreach c $channels {
        if {[string equal -nocase $c $chan]} { return 1 }
    }
    return 0
}

# Reject oversized or unsafe user supplied command arguments.
proc whocom::valid_arg {arg} {
    variable max_arg_length
    if {[string length $arg] == 0} { return 0 }
    if {[string length $arg] > $max_arg_length} { return 0 }
    if {[regexp {[\x00-\x1f\x7f]} $arg]} { return 0 }
    return 1
}

# Validate a nick argument before it ever reaches WHOIS/WHOWAS/CTCP.
# Deliberately conservative (RFC-ish nick grammar, length-capped): this
# blocks wildcard masks (e.g. "*", "A?B") and garbage input from being
# used to fish for excessive WHOIS results or otherwise abuse the
# lookup, not just cosmetic validation.
proc whocom::valid_nick {n} {
    if {[string length $n] == 0 || [string length $n] > 30} { return 0 }
    return [regexp {^[A-Za-z_\[\]\\^{}|`][A-Za-z0-9_\[\]\\^{}|`-]*$} $n]
}

# Validate an IPv6 address without accepting malformed colon strings such
# as ":::" or "1::2::3". IPv4-mapped/embedded IPv6 forms are accepted too.
proc whocom::valid_ipv6 {addr} {
    if {$addr eq "" || [string length $addr] > 45} { return 0 }
    set compression [string first "::" $addr]
    if {$compression >= 0 && [string first "::" $addr [expr {$compression + 2}]] >= 0} {
        return 0
    }

    set has_dot [string match "*.*" $addr]
    if {$has_dot} {
        set tail [lindex [split $addr ":"] end]
        if {![regexp {^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}$} $tail]} {
            return 0
        }
    }

    set groups 0
    if {$compression >= 0} {
        set left [string range $addr 0 [expr {$compression - 1}]]
        set right [string range $addr [expr {$compression + 2}] end]

        if {$left ne ""} {
            foreach part [split $left ":"] {
                if {$part eq "" || [string length $part] > 4 ||
                    ![regexp {^[0-9A-Fa-f]+$} $part]} {
                    return 0
                }
                incr groups
            }
        }

        if {$right ne ""} {
            set rightparts [split $right ":"]
            foreach part $rightparts {
                if {$part eq ""} { return 0 }
                if {$has_dot && [string first "." $part] >= 0} {
                    if {$part ne [lindex $rightparts end]} { return 0 }
                    incr groups 2
                } else {
                    if {[string length $part] > 4 ||
                        ![regexp {^[0-9A-Fa-f]+$} $part]} {
                        return 0
                    }
                    incr groups
                }
            }
        }

        # :: must stand for at least one omitted 16-bit group.
        return [expr {$groups < 8}]
    }

    set parts [split $addr ":"]
    if {$has_dot} {
        set last [lindex $parts end]
        if {$last eq "" || [string first "." $last] < 0} { return 0 }
        set parts [lreplace $parts end end]
        set groups 2
    }
    foreach part $parts {
        if {$part eq "" || [string length $part] > 4 ||
            ![regexp {^[0-9A-Fa-f]+$} $part]} {
            return 0
        }
        incr groups
    }
    return [expr {$groups == 8}]
}

# Enforce restrict_onchan: refuse to WHOIS/CTCP a nick that isn't
# actually present in the triggering channel, unless the feature is
# turned off.
proc whocom::target_ok {target chan} {
    variable restrict_onchan
    if {!$restrict_onchan} { return 1 }
    if {[catch {onchan $target $chan} res]} { return 0 }
    return $res
}

# Split a raw IRC numeric's parameter text into a list, honoring the
# ":trailing param" convention.
proc whocom::splitparams {text} {
    set idx [string first " :" $text]
    if {$idx >= 0} {
        set trailing [string range $text [expr {$idx + 2}] end]
        set head [string range $text 0 [expr {$idx - 1}]]
    } else {
        set trailing ""
        set head $text
    }
    set params [split [string trim $head] " "]
    if {$idx >= 0} { lappend params $trailing }
    return $params
}

# ================= Logging =================
proc whocom::log {msg} {
    # Redact the HackerTarget API key before anything reaches the logfile.
    # try_domain_source appends "&apikey=<key>" to the request URL, and
    # http_get_impl / http_done log that URL verbatim on every transport
    # failure, redirect and non-200 -- so the key ended up written to disk
    # (and to the partyline console, where anyone with +o log access reads
    # it) on any HackerTarget hiccup. One choke point here covers every
    # call site, including the $url a callback passes back.
    set msg [regsub -all -nocase {([?&]apikey=)[^&[:space:]]+} $msg {\1<redacted>}]
    putlog "whocom: [whocom::sanitize $msg]"
}

# Collapse a response body down to a single-line, length-capped snippet
# suitable for putlog -- so a "parser found no usable fields" log line
# actually shows *why* (rate-limit message, HTML error page, etc.)
# instead of leaving us to guess.
proc whocom::log_snippet {body} {
    set s [regsub -all {[\r\n]+} $body " "]
    set s [regsub -all {[\x00-\x08\x0b\x0c\x0e-\x1f]} $s ""]
    if {[string length $s] > 200} {
        set s "[string range $s 0 196]..."
    }
    return $s
}

# ================= !whohelp =================

whocom::bind_pub help $whocom::trig_help whocom::cmd_help
proc whocom::cmd_help {nick uhost hand chan text} {
    variable dest_help
    variable trig_wa
    variable trig_wi
    variable trig_ping
    variable trig_ver
    variable trig_domain
    variable trig_ip

    if {![whocom::channel_allowed $chan]} { return 0 }
    if {![whocom::allowed "help" $uhost]} {
        whocom::cooldown_notice "help" $uhost $dest_help $chan $nick
        return 0
    }

    variable cooldown
    variable cooldown_scope
    variable restrict_onchan
    # The two aliases (!whois / !whowas) are real binds -- they have been
    # since this script was written -- and the help listed neither, so the
    # only way to find them was to read the source. The cooldown and the
    # on-channel restriction were likewise undocumented, which is what
    # makes the bot look broken when it answers "isn't in this channel" or
    # says nothing at all.
    set scopedesc [expr {$cooldown_scope eq "command"
                         ? "per command" : "across all of these commands"}]
    set lines [list \
        "[whocom::bold "COMMANDS:"]" \
        "[whocom::bold $trig_domain] <domain.tld> - WHOIS/RDAP lookup on a domain" \
        "[whocom::bold $trig_ip] <address>   - Geolocation/ASN lookup on an IP" \
        "[whocom::bold $trig_ping] <nick>    - [whocom::bold "CTCP PING"] a nick, reports latency" \
        "[whocom::bold $trig_ver] <nick>     - [whocom::bold "CTCP VERSION"] a nick" \
        "[whocom::bold $trig_wa] <nick> (or !whowas)  - [whocom::bold "WHOWAS"] lookup on a nick" \
        "[whocom::bold $trig_wi] <nick> (or !whois)   - [whocom::bold "WHOIS"] lookup on a nick" \
        "Replies are sent as a private notice unless the bot is configured otherwise. There is a ${cooldown}s cooldown $scopedesc, and a command used inside it is ignored rather than answered." \
    ]
    if {$restrict_onchan} {
        lappend lines "$trig_wi/$trig_ping/$trig_ver only work on someone who is in this channel; $trig_wa works on anyone."
    }
    foreach l $lines { whocom::reply $dest_help $chan $nick $l }
    return 0
}

# ================= !wi (WHOIS) =================

whocom::bind_pub wi      $whocom::trig_wi whocom::cmd_wi
whocom::bind_pub wi_alias "!whois"        whocom::cmd_wi

proc whocom::pending_total {} {
    set total 0
    foreach name {q_whois q_whowas q_ping q_ver} {
        upvar 0 ::whocom::$name arr
        foreach key [array names arr] {
            incr total [llength $arr($key)]
        }
    }
    return $total
}

proc whocom::queue_allowed {arrayName key} {
    variable max_waiters_per_target
    variable max_waiters_total
    upvar 0 ::whocom::$arrayName arr
    if {[info exists arr($key)] && [llength $arr($key)] >= $max_waiters_per_target} {
        return 0
    }
    if {[whocom::pending_total] >= $max_waiters_total} {
        return 0
    }
    return 1
}

proc whocom::cmd_wi {nick uhost hand chan text} {
    variable need_flag_wi
    variable dest_wi
    variable q_whois
    variable gen_whois
    variable irc_timeout

    if {![whocom::channel_allowed $chan]} { return 0 }

    set target [lindex [split [string trim $text]] 0]
    # Order fixed: valid_arg returns 0 for an EMPTY argument too, so with
    # the checks the other way round a bare "!wi" answered "Invalid or
    # oversized input." and the usage line below was unreachable -- the
    # one message a first-time user needs was the one they could never
    # get. Empty is a usage question; non-empty-but-bad is an error.
    if {$target eq ""} {
        whocom::reply $dest_wi $chan $nick "Usage: $whocom::trig_wi <nick>"
        return 0
    }
    if {![whocom::valid_arg $target]} {
        whocom::reply $dest_wi $chan $nick "Invalid or oversized input."
        return 0
    }
    if {![whocom::valid_nick $target]} {
        whocom::reply $dest_wi $chan $nick "\"[string tolower $target]\" isn't a valid nick."
        return 0
    }
    if {![whocom::has_flag $need_flag_wi $hand $chan]} { return 0 }
    if {![whocom::allowed "wi" $uhost]} {
        whocom::cooldown_notice "wi" $uhost $dest_wi $chan $nick
        return 0
    }
    if {![whocom::target_ok $target $chan]} {
        whocom::reply $dest_wi $chan $nick "[string tolower $target] isn't in this channel."
        return 0
    }

    set key [whocom::lc $target]
    if {![whocom::queue_allowed q_whois $key]} {
        whocom::reply $dest_wi $chan $nick "That lookup is busy; try again shortly."
        return 0
    }
    set inflight [expr {[info exists q_whois($key)] && [llength $q_whois($key)] > 0}]
    lappend q_whois($key) [list $nick $chan $dest_wi]

    if {!$inflight} {
        ;# only fire one WHOIS per outstanding nick; everyone queued for the
        ;# same nick gets notified together when it resolves. The generation
        ;# counter lets a stale timeout timer (from an earlier, already-
        ;# completed request for this same nick) recognize it's stale and
        ;# do nothing instead of clobbering a newer in-flight request.
        if {![info exists gen_whois($key)]} { set gen_whois($key) 0 }
        incr gen_whois($key)
        catch {unset whocom::buf_whois($key)}
        set whocom::buf_whois($key) [dict create channels "" idle "" away "" \
            userhost "" realname "" server "" account ""]
        putquick "WHOIS $target"
        putlog "whocom: sent WHOIS for $target"
        utimer $irc_timeout [list whocom::whois_timeout $key $gen_whois($key)]
    }
    return 0
}

proc whocom::whois_timeout {key gen} {
    variable q_whois
    variable gen_whois
    if {![info exists gen_whois($key)] || $gen_whois($key) != $gen} { return }
    if {![info exists q_whois($key)] || [llength $q_whois($key)] == 0} { return }
    foreach entry $q_whois($key) {
        lassign $entry rnick rchan rdest
        whocom::reply $rdest $rchan $rnick "WHOIS for $key timed out (no reply from server)."
    }
    catch {unset whocom::q_whois($key)}
    catch {unset whocom::buf_whois($key)}
    catch {unset whocom::gen_whois($key)}
}

catch { unbind raw - 311 whocom::raw_whoisuser }
bind raw - 311 whocom::raw_whoisuser
proc whocom::raw_whoisuser {from kw text} {
    set p [whocom::splitparams $text]
    ;# p: ournick target user host * :realname
    set target [lindex $p 1]
    set key [whocom::lc $target]
    if {![info exists whocom::buf_whois($key)]} { return 0 }
    dict set whocom::buf_whois($key) userhost "[lindex $p 2]@[lindex $p 3]"
    dict set whocom::buf_whois($key) realname [lindex $p 5]
    return 0
}

catch { unbind raw - 312 whocom::raw_whoisserver }
bind raw - 312 whocom::raw_whoisserver
proc whocom::raw_whoisserver {from kw text} {
    set p [whocom::splitparams $text]
    set target [lindex $p 1]
    set key [whocom::lc $target]
    if {![info exists whocom::buf_whois($key)]} { return 0 }
    dict set whocom::buf_whois($key) server "[lindex $p 2]"
    return 0
}

catch { unbind raw - 319 whocom::raw_whoischannels }
bind raw - 319 whocom::raw_whoischannels
proc whocom::raw_whoischannels {from kw text} {
    set p [whocom::splitparams $text]
    set target [lindex $p 1]
    set key [whocom::lc $target]
    if {![info exists whocom::buf_whois($key)]} { return 0 }
    dict set whocom::buf_whois($key) channels [lindex $p 2]
    return 0
}

catch { unbind raw - 317 whocom::raw_whoisidle }
bind raw - 317 whocom::raw_whoisidle
proc whocom::raw_whoisidle {from kw text} {
    set p [whocom::splitparams $text]
    set target [lindex $p 1]
    set key [whocom::lc $target]
    if {![info exists whocom::buf_whois($key)]} { return 0 }
    dict set whocom::buf_whois($key) idle [lindex $p 2]
    return 0
}

catch { unbind raw - 301 whocom::raw_whoisaway }
bind raw - 301 whocom::raw_whoisaway
proc whocom::raw_whoisaway {from kw text} {
    set p [whocom::splitparams $text]
    set target [lindex $p 1]
    set key [whocom::lc $target]
    if {[info exists whocom::buf_whois($key)]} {
        dict set whocom::buf_whois($key) away [lindex $p end]
    }
    return 0
}

catch { unbind raw - 330 whocom::raw_whoisaccount }
bind raw - 330 whocom::raw_whoisaccount
proc whocom::raw_whoisaccount {from kw text} {
    ;# nonstandard but widely used: <ournick> <target> <account> :is logged in as
    set p [whocom::splitparams $text]
    set target [lindex $p 1]
    set key [whocom::lc $target]
    if {![info exists whocom::buf_whois($key)]} { return 0 }
    dict set whocom::buf_whois($key) account [lindex $p 2]
    return 0
}

catch { unbind raw - 401 whocom::raw_nosuchnick }
bind raw - 401 whocom::raw_nosuchnick
proc whocom::raw_nosuchnick {from kw text} {
    set p [whocom::splitparams $text]
    set target [lindex $p 1]
    set key [whocom::lc $target]
    variable q_whois
    variable q_ping
    variable q_ver
    set lt [string tolower $target]
    # The 401 a server sends back for the CTCP PRIVMSG of !pi/!ver means the
    # same thing as for a WHOIS: there is nobody by that name. Answer those
    # waiters now instead of leaving them to the "timed out (no reply)"
    # message $ctcp_timeout seconds later. Their pending timers then find
    # nothing to do (ping_timeout matches no stamp; ver_timeout finds no
    # gen_ver) and return.
    foreach {arr label companions} {
        q_whois "WHOIS"        {buf_whois gen_whois}
        q_ping  "CTCP PING"    {}
        q_ver   "CTCP VERSION" {gen_ver}
    } {
        upvar 0 ::whocom::$arr q
        if {![info exists q($key)] || [llength $q($key)] == 0} { continue }
        foreach entry $q($key) {
            lassign $entry rnick rchan rdest
            whocom::reply $rdest $rchan $rnick "$label: no such nick \"$lt\"."
        }
        unset q($key)
        foreach comp $companions { catch {unset ::whocom::${comp}($key)} }
    }
    return 0
}

catch { unbind raw - 318 whocom::raw_endofwhois }
bind raw - 318 whocom::raw_endofwhois
proc whocom::raw_endofwhois {from kw text} {
    set p [whocom::splitparams $text]
    set target [lindex $p 1]
    set key [whocom::lc $target]
    variable q_whois
    if {![info exists q_whois($key)] || [llength $q_whois($key)] == 0} { return 0 }

    if {![info exists whocom::buf_whois($key)]} {
        foreach entry $q_whois($key) {
            lassign $entry rnick rchan rdest
            whocom::reply $rdest $rchan $rnick "WHOIS: no data for \"[string tolower $target]\"."
        }
        catch {unset whocom::q_whois($key)}
        catch {unset whocom::gen_whois($key)}
        return 0
    }
    set d $whocom::buf_whois($key)
    set fields [list]
    if {[dict get $d userhost] ne ""} { lappend fields [string tolower "User/Host: [dict get $d userhost]"] }
    if {[dict get $d realname] ne ""} { lappend fields [string tolower "Realname: [dict get $d realname]"] }
    if {[dict get $d server] ne ""}   { lappend fields [string tolower "Server: [dict get $d server]"] }
    if {[dict get $d idle] ne ""}     { lappend fields [string tolower "Idle: [dict get $d idle]s"] }
    if {[dict get $d channels] ne ""} { lappend fields [string tolower "Channels: [dict get $d channels]"] }
    if {[dict get $d account] ne ""}  { lappend fields [string tolower "Account: [dict get $d account]"] }
    if {[dict get $d away] ne ""}     { lappend fields [string tolower "Away: [dict get $d away]"] }

    foreach entry $q_whois($key) {
        lassign $entry rnick rchan rdest
        whocom::reply $rdest $rchan $rnick "[whocom::bold "\[WHOIS\]"] [string tolower $target]"
        foreach field $fields {
            whocom::reply $rdest $rchan $rnick $field
        }
    }
    catch {unset whocom::q_whois($key)}
    catch {unset whocom::buf_whois($key)}
    catch {unset whocom::gen_whois($key)}
    return 0
}

# ================= !wa (WHOWAS) =================

whocom::bind_pub wa      $whocom::trig_wa whocom::cmd_wa
whocom::bind_pub wa_alias "!whowas"       whocom::cmd_wa

proc whocom::cmd_wa {nick uhost hand chan text} {
    variable need_flag_wa
    variable dest_wa
    variable q_whowas
    variable gen_whowas
    variable irc_timeout

    if {![whocom::channel_allowed $chan]} { return 0 }

    set target [lindex [split [string trim $text]] 0]
    if {$target eq ""} {
        whocom::reply $dest_wa $chan $nick "Usage: $whocom::trig_wa <nick>"
        return 0
    }
    if {![whocom::valid_nick $target]} {
        whocom::reply $dest_wa $chan $nick "\"[string tolower $target]\" isn't a valid nick."
        return 0
    }
    if {![whocom::has_flag $need_flag_wa $hand $chan]} { return 0 }
    if {![whocom::allowed "wa" $uhost]} {
        whocom::cooldown_notice "wa" $uhost $dest_wa $chan $nick
        return 0
    }

    set key [whocom::lc $target]
    if {![whocom::queue_allowed q_whowas $key]} {
        whocom::reply $dest_wa $chan $nick "That lookup is busy; try again shortly."
        return 0
    }
    set inflight [expr {[info exists q_whowas($key)] && [llength $q_whowas($key)] > 0}]
    lappend q_whowas($key) [list $nick $chan $dest_wa]

    if {!$inflight} {
        if {![info exists gen_whowas($key)]} { set gen_whowas($key) 0 }
        incr gen_whowas($key)
        catch {unset whocom::buf_whowas($key)}
        set whocom::buf_whowas($key) [list]
        putquick "WHOWAS $target"
        putlog "whocom: sent WHOWAS for $target"
        utimer $irc_timeout [list whocom::whowas_timeout $key $gen_whowas($key)]
    }
    return 0
}

proc whocom::whowas_timeout {key gen} {
    variable q_whowas
    variable gen_whowas
    if {![info exists gen_whowas($key)] || $gen_whowas($key) != $gen} { return }
    if {![info exists q_whowas($key)] || [llength $q_whowas($key)] == 0} { return }
    foreach entry $q_whowas($key) {
        lassign $entry rnick rchan rdest
        whocom::reply $rdest $rchan $rnick "WHOWAS for $key timed out (no reply from server)."
    }
    catch {unset whocom::q_whowas($key)}
    catch {unset whocom::gen_whowas($key)}
    catch {unset whocom::buf_whowas($key)}
}

catch { unbind raw - 314 whocom::raw_whowasuser }
bind raw - 314 whocom::raw_whowasuser
proc whocom::raw_whowasuser {from kw text} {
    set p [whocom::splitparams $text]
    ;# p: ournick target user host * :realname
    set target [lindex $p 1]
    set key [whocom::lc $target]
    if {![info exists whocom::buf_whowas($key)]} { return 0 }
    lappend whocom::buf_whowas($key) "[lindex $p 1]!\
[lindex $p 2]@[lindex $p 3] ([lindex $p 5])"
    return 0
}

catch { unbind raw - 406 whocom::raw_wasnosuchnick }
bind raw - 406 whocom::raw_wasnosuchnick
proc whocom::raw_wasnosuchnick {from kw text} {
    set p [whocom::splitparams $text]
    set target [lindex $p 1]
    set key [whocom::lc $target]
    variable q_whowas
    if {![info exists q_whowas($key)] || [llength $q_whowas($key)] == 0} { return 0 }
    foreach entry $q_whowas($key) {
        lassign $entry rnick rchan rdest
        whocom::reply $rdest $rchan $rnick "WHOWAS: no such nick \"[string tolower $target]\" on record."
    }
    catch {unset whocom::q_whowas($key)}
    catch {unset whocom::buf_whowas($key)}
    catch {unset whocom::gen_whowas($key)}
    return 0
}

catch { unbind raw - 369 whocom::raw_endofwhowas }
bind raw - 369 whocom::raw_endofwhowas
proc whocom::raw_endofwhowas {from kw text} {
    set p [whocom::splitparams $text]
    set target [lindex $p 1]
    set key [whocom::lc $target]
    variable q_whowas
    if {![info exists q_whowas($key)] || [llength $q_whowas($key)] == 0} { return 0 }

    if {![info exists whocom::buf_whowas($key)] || \
        [llength $whocom::buf_whowas($key)] == 0} {
        foreach entry $q_whowas($key) {
            lassign $entry rnick rchan rdest
            whocom::reply $rdest $rchan $rnick "WHOWAS: no records for \"[string tolower $target]\"."
        }
        catch {unset whocom::q_whowas($key)}
        catch {unset whocom::gen_whowas($key)}
        return 0
    }
    foreach entry $q_whowas($key) {
        lassign $entry rnick rchan rdest
        set n 1
        foreach rec $whocom::buf_whowas($key) {
            whocom::reply $rdest $rchan $rnick "[whocom::bold "\[WHOWAS $n\]"] [string tolower $rec]"
            incr n
        }
    }
    catch {unset whocom::q_whowas($key)}
    catch {unset whocom::buf_whowas($key)}
    catch {unset whocom::gen_whowas($key)}
    return 0
}

# ================= !pi (CTCP PING) =================

whocom::bind_pub ping $whocom::trig_ping whocom::cmd_ping
proc whocom::cmd_ping {nick uhost hand chan text} {
    variable need_flag_ping
    variable dest_ping
    variable q_ping
    variable ctcp_timeout

    if {![whocom::channel_allowed $chan]} { return 0 }

    set target [lindex [split [string trim $text]] 0]
    if {$target eq ""} {
        whocom::reply $dest_ping $chan $nick "Usage: $whocom::trig_ping <nick>"
        return 0
    }
    if {![whocom::valid_nick $target]} {
        whocom::reply $dest_ping $chan $nick "\"[string tolower $target]\" isn't a valid nick."
        return 0
    }
    if {![whocom::has_flag $need_flag_ping $hand $chan]} { return 0 }
    if {![whocom::allowed "ping" $uhost]} {
        whocom::cooldown_notice "ping" $uhost $dest_ping $chan $nick
        return 0
    }
    if {![whocom::target_ok $target $chan]} {
        whocom::reply $dest_ping $chan $nick "[string tolower $target] isn't in this channel."
        return 0
    }

    set key [whocom::lc $target]
    if {![whocom::queue_allowed q_ping $key]} {
        whocom::reply $dest_ping $chan $nick "That probe is busy; try again shortly."
        return 0
    }
    # Share ONE in-flight probe per target, the way cmd_ver already does.
    #
    # cmd_ver's comment spells out why -- an unsolicited CTCP the bot can
    # be made to send at a third party, once per user, with each user on
    # their own independent cooldown, is a distributed CTCP-flood
    # amplifier -- and then that fix was applied to VERSION only. PING had
    # the same hole and is the better amplifier of the two, since the
    # target's client answers every one of them. queue_allowed capped the
    # waiter LIST at 16 per target, but every one of those 16 was its own
    # CTCP on the wire.
    #
    # The RTT stays meaningful: waiters that join an existing probe share
    # its stamp and are all answered from that single round-trip, so the
    # figure they get is a real measurement, just not one taken from the
    # instant they personally typed the command.
    set stamp ""
    if {[info exists q_ping($key)] && [llength $q_ping($key)] > 0} {
        set stamp [lindex [lindex $q_ping($key) end] 3]
    }
    if {$stamp eq ""} {
        set stamp [clock milliseconds]
        lappend q_ping($key) [list $nick $chan $dest_ping $stamp]
        putquick "PRIVMSG $target :\001PING $stamp\001"
        utimer $ctcp_timeout [list whocom::ping_timeout $key $stamp]
    } else {
        lappend q_ping($key) [list $nick $chan $dest_ping $stamp]
    }
    return 0
}

proc whocom::ping_timeout {key stamp} {
    variable q_ping
    if {![info exists q_ping($key)]} { return }
    # Every waiter that shares this stamp shared the one probe that just
    # timed out (see cmd_ping), so all of them are answered and removed
    # together -- picking out only the first match would leave the rest
    # queued forever with no timer left to clear them, which is also what
    # would keep queue_allowed reporting "busy" for that nick.
    set matched {}
    set keep {}
    foreach e $q_ping($key) {
        if {[lindex $e 3] eq $stamp} { lappend matched $e } else { lappend keep $e }
    }
    if {![llength $matched]} { return }
    set q_ping($key) $keep
    # Bug fix: this used to leave q_ping($key) sitting in the array as a
    # permanent empty list once the last pending probe for a nick drained
    # -- unlike q_whois/q_whowas, which unset their array element in
    # every terminal path. That meant one permanent (if empty) array key
    # for every distinct nick ever !pi'd, for the life of the process: a
    # slow, unbounded memory leak on a long-running bot. Unset once empty.
    if {[llength $q_ping($key)] == 0} { unset q_ping($key) }
    foreach entry $matched {
        lassign $entry rnick rchan rdest
        whocom::reply $rdest $rchan $rnick "[whocom::bold "CTCP PING"] to $key timed out (no reply)."
    }
}

catch { unbind ctcr - PING whocom::ctcr_ping }
bind ctcr - PING whocom::ctcr_ping
proc whocom::ctcr_ping {nick uhost hand dest keyword text} {
    variable q_ping
    set key [whocom::lc $nick]
    if {![info exists q_ping($key)] || [llength $q_ping($key)] == 0} { return 0 }
    set now [clock milliseconds]
    set stamp [string trim $text]
    # String compare, not ==: the token comes straight off the wire, and
    # `==` on two operands that both look numeric is a NUMERIC compare, so
    # a reply of "0123" or " 123 " matched a pending stamp of 123. eq also
    # avoids the error `==` raises on a non-numeric token.
    set matched {}
    set keep {}
    foreach e $q_ping($key) {
        if {[lindex $e 3] eq $stamp} { lappend matched $e } else { lappend keep $e }
    }
    if {![llength $matched]} {
        # Never accept an unmatched token as a valid response.
        return 0
    }
    set q_ping($key) $keep
    # Don't leave a permanent empty array entry behind once the last
    # pending probe for this nick is answered.
    if {[llength $q_ping($key)] == 0} { unset q_ping($key) }
    # One probe, every waiter on it answered -- see cmd_ping.
    foreach entry $matched {
        lassign $entry rnick rchan rdest sentstamp
        set ms [expr {$now - $sentstamp}]
        whocom::reply $rdest $rchan $rnick "[whocom::bold "CTCP PING"] reply from [string tolower $nick]: ${ms}ms"
    }
    return 0
}

# ================= !ver (CTCP VERSION) =================

whocom::bind_pub ver $whocom::trig_ver whocom::cmd_ver
proc whocom::cmd_ver {nick uhost hand chan text} {
    variable need_flag_ver
    variable dest_ver
    variable q_ver
    variable gen_ver
    variable ctcp_timeout

    if {![whocom::channel_allowed $chan]} { return 0 }

    set target [lindex [split [string trim $text]] 0]
    if {$target eq ""} {
        whocom::reply $dest_ver $chan $nick "Usage: $whocom::trig_ver <nick>"
        return 0
    }
    if {![whocom::valid_nick $target]} {
        whocom::reply $dest_ver $chan $nick "\"[string tolower $target]\" isn't a valid nick."
        return 0
    }
    if {![whocom::has_flag $need_flag_ver $hand $chan]} { return 0 }
    if {![whocom::allowed "ver" $uhost]} {
        whocom::cooldown_notice "ver" $uhost $dest_ver $chan $nick
        return 0
    }
    if {![whocom::target_ok $target $chan]} {
        whocom::reply $dest_ver $chan $nick "[string tolower $target] isn't in this channel."
        return 0
    }

    # Share one in-flight probe per target, the same way !wi/!wa already
    # do, instead of firing a brand-new raw CTCP for every single
    # invocation. Fixed here: with no dedup, every on-channel user (each
    # with their own independent cooldown) could keep this bot
    # sending fresh, unsolicited "\001VERSION\001" CTCPs at the same
    # third party indefinitely -- turning the bot into a distributed
    # CTCP-flood amplifier against anyone in a shared channel. Everyone
    # queued for the same nick now gets notified together off a single
    # probe, exactly like WHOIS. A generation counter (mirroring
    # gen_whois/gen_whowas) keeps a stale timeout timer from an earlier,
    # already-completed request from clobbering a fresh one for the same
    # nick.
    set key [whocom::lc $target]
    if {![whocom::queue_allowed q_ver $key]} {
        whocom::reply $dest_ver $chan $nick "That probe is busy; try again shortly."
        return 0
    }
    set inflight [expr {[info exists q_ver($key)] && [llength $q_ver($key)] > 0}]
    lappend q_ver($key) [list $nick $chan $dest_ver]
    if {!$inflight} {
        if {![info exists gen_ver($key)]} { set gen_ver($key) 0 }
        incr gen_ver($key)
        putquick "PRIVMSG $target :\001VERSION\001"
        utimer $ctcp_timeout [list whocom::ver_timeout $key $gen_ver($key)]
    }
    return 0
}

proc whocom::ver_timeout {key gen} {
    variable q_ver
    variable gen_ver
    if {![info exists gen_ver($key)] || $gen_ver($key) != $gen} { return }
    if {![info exists q_ver($key)] || [llength $q_ver($key)] == 0} { return }
    foreach entry $q_ver($key) {
        lassign $entry rnick rchan rdest
        whocom::reply $rdest $rchan $rnick "[whocom::bold "CTCP VERSION"] to $key timed out (no reply)."
    }
    # Bug fix: same leak as q_ping (see ping_timeout) -- unset the array
    # element instead of leaving a permanent empty list behind for every
    # distinct nick ever !ver'd.
    catch {unset whocom::q_ver($key)}
    catch {unset whocom::gen_ver($key)}
}

catch { unbind ctcr - VERSION whocom::ctcr_version }
bind ctcr - VERSION whocom::ctcr_version
proc whocom::ctcr_version {nick uhost hand dest keyword text} {
    variable q_ver
    set key [whocom::lc $nick]
    if {![info exists q_ver($key)] || [llength $q_ver($key)] == 0} { return 0 }
    if {$text eq ""} { set text "(empty reply)" }
    ;# only ONE real probe was ever sent for this key (see cmd_ver's
    ;# in-flight dedup), so this single reply answers everyone queued
    ;# for it -- not just whoever queued first.
    foreach entry $q_ver($key) {
        lassign $entry rnick rchan rdest
        whocom::reply $rdest $rchan $rnick "[whocom::bold "CTCP VERSION"] reply from [string tolower $nick]: [string tolower $text]"
    }
    # Same fix as ver_timeout above.
    catch {unset whocom::q_ver($key)}
    catch {unset whocom::gen_ver($key)}
    return 0
}

# ================= !dom =================

whocom::bind_pub domain $whocom::trig_domain whocom::cmd_domain
proc whocom::cmd_domain {nick uhost hand chan text} {
    variable need_flag_domain
    variable dest_domain

    if {![whocom::channel_allowed $chan]} { return 0 }

    set domain [string tolower [lindex [split [string trim $text]] 0]]
    if {$domain eq ""} {
        whocom::reply $dest_domain $chan $nick "Usage: $whocom::trig_domain <domain.tld>"
        return 0
    }
    if {[string length $domain] > 253} {
        whocom::reply $dest_domain $chan $nick "That domain is too long to be valid."
        return 0
    }
    if {![regexp {^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$} $domain]} {
        whocom::reply $dest_domain $chan $nick "That doesn't look like a valid domain."
        return 0
    }
    if {![whocom::has_flag $need_flag_domain $hand $chan]} { return 0 }
    if {![whocom::allowed "domain" $uhost]} {
        whocom::cooldown_notice "domain" $uhost $dest_domain $chan $nick
        return 0
    }
    if {![whocom::http_allowed]} {
        whocom::reply $dest_domain $chan $nick "Lookup service is busy, try again in a few seconds."
        return 0
    }

    whocom::reply $dest_domain $chan $nick "Looking up $domain ..."
    whocom::try_domain_source 0 $domain $nick $chan $dest_domain
    return 0
}

proc whocom::try_domain_source {idx domain nick chan dest} {
    variable domain_sources
    variable hackertarget_apikey
    if {$idx >= [llength $domain_sources]} {
        whocom::reply $dest $chan $nick "Domain lookup for $domain failed: all sources unreachable."
        return
    }
    lassign [lindex $domain_sources $idx] label urlfmt parser
    set cb [list whocom::domain_result $idx $domain $nick $chan $dest $label $parser]

    if {$label eq "WHOIS"} {
        whocom::whois_tcp_lookup $domain $cb
        return
    }
    if {$label eq "HackerTarget" && $hackertarget_apikey eq ""} {
        whocom::log "domain lookup via HackerTarget skipped for $domain: no API key configured (hackertarget_apikey)"
        whocom::try_domain_source [expr {$idx + 1}] $domain $nick $chan $dest
        return
    }

    set url [format $urlfmt $domain]
    if {$label eq "HackerTarget"} {
        append url "&apikey=$hackertarget_apikey"
    }
    whocom::http_get $url $cb
}

proc whocom::domain_result {idx domain nick chan dest label parser body url code} {
    set ok 0
    if {![string is integer -strict $code]} {
        whocom::log "domain lookup via $label failed for $domain: transport error ($code)"
    } elseif {$code != 200} {
        whocom::log "domain lookup via $label failed for $domain: HTTP $code"
    } elseif {$body eq ""} {
        whocom::log "domain lookup via $label failed for $domain: empty body"
    } else {
        if {[catch {set fields [$parser $body $domain]} perr]} {
            whocom::log "domain lookup via $label: parser error for $domain: $perr"
        } elseif {![llength $fields]} {
            whocom::log "domain lookup via $label: parser found no usable fields for $domain (body: [whocom::log_snippet $body])"
        } else {
            whocom::reply $dest $chan $nick "[whocom::bold "\[DOMAIN via $label\]"] [string tolower $domain]"
            foreach field $fields {
                whocom::reply $dest $chan $nick $field
            }
            set ok 1
        }
    }
    if {!$ok} {
        whocom::try_domain_source [expr {$idx + 1}] $domain $nick $chan $dest
    }
}

# RDAP (rdap.org) JSON parser - very small hand-rolled extractor, avoids a
# hard dependency on a JSON package.
proc whocom::parse_rdap {body domain} {
    set out [list]

    if {[regexp {"ldhName"\s*:\s*"([^"]+)"} $body -> v]} {
        lappend out "[whocom::bold DOMAIN:] [string tolower $v]"
    }

    set events [list]
    foreach {full action date} [regexp -all -inline \
        {"eventAction"\s*:\s*"([^"]+)"\s*,\s*"eventDate"\s*:\s*"([^"]+)"} $body] {
        lappend events "$action=$date"
    }
    if {[llength $events]} { lappend out "[whocom::bold EVENTS:] [string tolower [join $events {, }]]" }

    # Nameserver blocks vary by registry; grab any ldhName that sits inside
    # a nameserver object as a best effort.
    set ns [list]
    foreach {full n} [regexp -all -inline \
        {"objectClassName"\s*:\s*"nameserver"[^\}]*"ldhName"\s*:\s*"([^"]+)"} $body] {
        lappend ns $n
    }
    if {[llength $ns]} { lappend out "[whocom::bold NS:] [string tolower [join $ns {, }]]" }

    if {![llength $out]} { return [list] }
    return $out
}

# HackerTarget plaintext WHOIS API parser (returns raw whois text, not JSON)
proc whocom::parse_hackertarget_whois {body domain} {
    # This parser serves TWO sources: HackerTarget's API and the raw
    # port-43 WHOIS that is now the primary domain source.
    #
    # The old guard was [string match -nocase "*error*" $body], written for
    # HackerTarget's one-line "error valid key required" response -- but
    # against a real registry WHOIS record it matches the word "error"
    # ANYWHERE, including inside the legal disclaimer several registries
    # append to every single response. A perfectly good WHOIS record was
    # then thrown away and the lookup fell through to RDAP for no reason.
    # Only treat it as an error reply if the body is short enough to BE
    # one, or if it actually starts with an error marker.
    if {[string length $body] < 20} { return "" }
    set head [string trim [string range $body 0 199]]
    if {[string length $body] < 200 && [string match -nocase "*error*" $body]} { return "" }
    if {[regexp -nocase {^(error|\{"error)} $head]} { return "" }
    set out [list]
    set ns [list]
    foreach line [split $body "\n"] {
        set line [string trim $line]
        if {$line eq ""} { continue }
        if {[regexp -nocase {^(registrar):\s*(.+)$} $line -> k v]} {
            lappend out "[whocom::bold REGISTRAR:] [string tolower $v]"
        } elseif {[regexp -nocase {^(creation date|created on|created):\s*(.+)$} $line -> k v]} {
            lappend out "[whocom::bold CREATED:] [string tolower $v]"
        } elseif {[regexp -nocase {^(registry expiry date|expiration date|expires on):\s*(.+)$} $line -> k v]} {
            lappend out "[whocom::bold EXPIRES:] [string tolower $v]"
        } elseif {[regexp -nocase {^(name server):\s*(.+)$} $line -> k v]} {
            lappend ns [string tolower $v]
        }
        ;# NS lines are collected separately and joined below, so cap on
        ;# the single-value fields only -- an NS-heavy record shouldn't
        ;# crowd out registrar/dates before they're even seen.
        if {[llength $out] >= 6} { break }
    }
    if {[llength $ns]} { lappend out "[whocom::bold NS:] [join $ns {, }]" }
    if {![llength $out]} { return [list] }
    return $out
}

# ================= raw TCP whois (port 43) =================
#
# A traditional whois query needs no HTTPS/TLS stack, no API key, and
# doesn't depend on rdap.org's redirector being up -- so it's used as
# the primary domain source, with RDAP/HackerTarget as fallbacks. TLDs
# not in whois_tld_servers skip raw WHOIS and fall through to HTTPS RDAP;
# this avoids trusting an unauthenticated plaintext IANA referral as a
# new outbound connection target.
#
# Fully async (socket -async + fileevent), for the same reason
# whocom::http_get is: a synchronous call would stall the whole bot's
# event loop.

proc whocom::whois_tcp_lookup {domain callback} {
    variable whois_tld_servers
    set tld [string tolower [lindex [split $domain "."] end]]
    if {[dict exists $whois_tld_servers $tld]} {
        whocom::whois_tcp_query [dict get $whois_tld_servers $tld] $domain $callback
    } else {
        # Do not follow unauthenticated plaintext IANA referrals. Let the
        # caller fall through to RDAP instead.
        whocom::invoke_callback $callback "" "whois://iana-referral-disabled" "unsupported-tld"
    }
}

# Is $host safe to open a raw TCP connection to?
#
# The comment here used to say this was shared with a whois_server_allowed
# proc that validated the IANA referral hop. There is no such proc in this
# file -- whois_tcp_lookup no longer follows IANA referrals at all (it
# refuses an unlisted TLD outright and lets the caller fall through to
# RDAP), so the only caller left is redirect_allowed. A comment pointing at
# a validator that does not exist is worse than no comment: it reads as an
# assurance that something is being checked. Blocks bracketed
# or bare IPv6 literals, ALL bare IPv4 literals (not just private ranges
# -- a legitimate referral/redirect target is always a hostname), and
# "localhost". Callers still layer their own extra checks (scheme,
# character-set validation of the hostname) on top of this.
proc whocom::host_is_ip_or_local {host} {
    set host [string tolower $host]
    if {$host eq "localhost"} { return 1 }
    if {[string index $host 0] eq "\["} { return 1 }
    if {[string match "*:*" $host]} { return 1 }
    if {[regexp {^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$} $host]} {
        return 1
    }
    return 0
}

# Opens a raw port-43 whois query to $server and hands the response to
# $callback.
#
# The block of comment that used to sit here described validating an IANA
# "refer:" hop against an untrusted plaintext reply -- a hop this file no
# longer makes (whois_tcp_lookup refuses an unlisted TLD and falls through
# to RDAP instead), by a proc that does not exist. $server therefore only
# ever comes from the operator-authored whois_tld_servers table, never from
# the network. If you ever re-enable referral following, validate the
# referred host before it reaches [socket]: an unauthenticated, unencrypted
# reply naming the next host to connect to is exactly the shape that lets
# an on-path attacker aim the bot at an internal address.
proc whocom::whois_tcp_query {server domain callback} {
    variable whois_tcp_timeout
    variable whois_conns
    variable max_whois_connections

    if {[array size whois_conns] >= $max_whois_connections} {
        whocom::log "whois TCP connection limit reached; deferring $domain"
        whocom::invoke_callback $callback "" "whois://$server" "busy"
        return
    }

    if {[catch {socket -async $server 43} sock]} {
        whocom::log "whois TCP connect failed for $server: $sock"
        whocom::invoke_callback $callback "" "whois://$server" "connect-failed"
        return
    }
    fconfigure $sock -blocking 0 -translation crlf -buffering none
    set whois_conns($sock) [dict create server $server domain $domain \
        callback $callback buf "" timer ""]
    dict set whois_conns($sock) timer \
        [after $whois_tcp_timeout [list whocom::whois_tcp_timeout_fire $sock]]
    fileevent $sock writable [list whocom::whois_tcp_connected $sock]
}

proc whocom::whois_tcp_connected {sock} {
    variable whois_conns
    if {![info exists whois_conns($sock)]} { return }
    fileevent $sock writable {}
    if {[catch {fconfigure $sock -error} err]} { set err "connect failed" }
    if {$err ne ""} {
        whocom::whois_tcp_fail $sock "connect-error"
        return
    }
    set domain [dict get $whois_conns($sock) domain]
    if {[catch { puts $sock $domain; flush $sock } werr]} {
        whocom::whois_tcp_fail $sock "write-error"
        return
    }
    fileevent $sock readable [list whocom::whois_tcp_readable $sock]
}

proc whocom::whois_tcp_readable {sock} {
    variable whois_conns
    variable http_max_body
    if {![info exists whois_conns($sock)]} { return }
    if {[catch {read $sock} chunk]} {
        whocom::whois_tcp_fail $sock "read-error"
        return
    }
    dict append whois_conns($sock) buf $chunk
    if {[string length [dict get $whois_conns($sock) buf]] > $http_max_body} {
        whocom::whois_tcp_finish $sock
        return
    }
    if {[eof $sock]} {
        whocom::whois_tcp_finish $sock
    }
}

proc whocom::whois_tcp_timeout_fire {sock} {
    whocom::whois_tcp_fail $sock "timeout"
}

proc whocom::whois_tcp_fail {sock reason} {
    variable whois_conns
    if {![info exists whois_conns($sock)]} { return }
    set d $whois_conns($sock)
    catch { after cancel [dict get $d timer] }
    catch { close $sock }
    unset whois_conns($sock)
    whocom::log "whois TCP query to [dict get $d server] for [dict get $d domain] failed: $reason"
    whocom::invoke_callback [dict get $d callback] "" "whois://[dict get $d server]" $reason
}

proc whocom::whois_tcp_finish {sock} {
    variable whois_conns
    if {![info exists whois_conns($sock)]} { return }
    set d $whois_conns($sock)
    catch { after cancel [dict get $d timer] }
    catch { close $sock }
    unset whois_conns($sock)
    set body [dict get $d buf]
    if {$body eq ""} {
        whocom::invoke_callback [dict get $d callback] "" "whois://[dict get $d server]" "empty-response"
        return
    }
    whocom::invoke_callback [dict get $d callback] $body "whois://[dict get $d server]" 200
}

# ================= !ip =================

whocom::bind_pub ip $whocom::trig_ip whocom::cmd_ip
proc whocom::cmd_ip {nick uhost hand chan text} {
    # The nick-keyed whocom::ratelimit call that used to sit here is gone
    # -- see the removal note near the top of this file. whocom::allowed
    # below enforces the same `cooldown` on a hostmask key, which a nick
    # change does not reset. It also ran BEFORE the usage/validation
    # checks, so a bare "!ip" with no argument burned the window.
    variable need_flag_ip
    variable dest_ip

    if {![whocom::channel_allowed $chan]} { return 0 }

    set addr [lindex [split [string trim $text]] 0]
    if {$addr eq ""} {
        whocom::reply $dest_ip $chan $nick "Usage: $whocom::trig_ip <address>"
        return 0
    }
    if {[string length $addr] > 45} {
        whocom::reply $dest_ip $chan $nick "That doesn't look like a valid IPv4/IPv6 address."
        return 0
    }
    set octet {(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])}
    set is_v4 [regexp "^$octet\\.$octet\\.$octet\\.$octet\\$" $addr]
    set is_v6 [whocom::valid_ipv6 $addr]
    if {!$is_v4 && !$is_v6} {
        whocom::reply $dest_ip $chan $nick "That doesn't look like a valid IPv4/IPv6 address."
        return 0
    }
    if {![whocom::has_flag $need_flag_ip $hand $chan]} { return 0 }
    if {![whocom::allowed "ip" $uhost]} {
        whocom::cooldown_notice "ip" $uhost $dest_ip $chan $nick
        return 0
    }
    if {![whocom::http_allowed]} {
        whocom::reply $dest_ip $chan $nick "Lookup service is busy, try again in a few seconds."
        return 0
    }

    whocom::reply $dest_ip $chan $nick "Looking up [string tolower $addr] ..."
    whocom::try_ip_source 0 $addr $nick $chan $dest_ip
    return 0
}

proc whocom::try_ip_source {idx addr nick chan dest} {
    variable ip_sources
    if {$idx >= [llength $ip_sources]} {
        whocom::reply $dest $chan $nick "IP lookup for $addr failed: all sources unreachable."
        return
    }
    lassign [lindex $ip_sources $idx] label urlfmt parser
    set url [format $urlfmt $addr]
    whocom::http_get $url [list whocom::ip_result $idx $addr $nick $chan $dest $label $parser]
}

proc whocom::ip_result {idx addr nick chan dest label parser body url code} {
    set ok 0
    if {![string is integer -strict $code]} {
        whocom::log "IP lookup via $label failed for $addr: transport error ($code)"
    } elseif {$code != 200} {
        whocom::log "IP lookup via $label failed for $addr: HTTP $code"
    } elseif {$body eq ""} {
        whocom::log "IP lookup via $label failed for $addr: empty body"
    } else {
        if {[catch {set formatted [$parser $body $addr]} perr]} {
            whocom::log "IP lookup via $label: parser error for $addr: $perr"
        } elseif {$formatted eq ""} {
            whocom::log "IP lookup via $label: parser found no usable fields for $addr (body: [whocom::log_snippet $body])"
        } else {
            whocom::reply $dest $chan $nick "[whocom::bold "\[IP Lookup\]"] [string tolower $formatted]"
            set ok 1
        }
    }
    if {!$ok} {
        whocom::try_ip_source [expr {$idx + 1}] $addr $nick $chan $dest
    }
}

proc whocom::jval {body key} {
    if {[regexp "\"$key\"\\s*:\\s*\"(\[^\"\]*)\"" $body -> v]} { return $v }
    if {[regexp "\"$key\"\\s*:\\s*(-?\[0-9\]+(\\.\[0-9\]+)?)" $body -> v]} { return $v }
    return ""
}

# ipwho.is JSON parser
proc whocom::parse_ipwhois {body addr} {
    if {[regexp {"success"\s*:\s*false} $body]} { return "" }
    set out [list]
    set city [whocom::jval $body city]
    set region [whocom::jval $body region]
    set country [whocom::jval $body country]
    # The connection object's fields come in any order ({"asn":..,"org":..,
    # "isp":..,"domain":..} from ipwho.is), so none of them may be required
    # to sit right before the closing brace -- the old patterns demanded
    # exactly that for isp/org/asn, so those three never matched a real
    # response and ISP/Org/ASN were never shown.
    set isp ""
    regexp {"connection"\s*:\s*\x7b[^\x7d]*"isp"\s*:\s*"([^"]*)"} $body -> isp
    set org ""
    regexp {"connection"\s*:\s*\x7b[^\x7d]*"org"\s*:\s*"([^"]*)"} $body -> org
    set as ""
    if {[regexp {"connection"\s*:\s*\x7b[^\x7d]*"asn"\s*:\s*(\d+)} $body -> as]} { set as "AS$as" }
    set condomain ""
    regexp {"connection"\s*:\s*\x7b[^\x7d]*"domain"\s*:\s*"([^"]*)"} $body -> condomain
    set continent [whocom::jval $body continent]
    set cc [whocom::jval $body country_code]
    set capital [whocom::jval $body capital]
    set calling [whocom::jval $body calling_code]
    set postal [whocom::jval $body postal]
    set tzid ""
    regexp {"timezone"\s*:\s*\x7b[^\x7d]*"id"\s*:\s*"([^"]*)"} $body -> tzid
    set tzabbr ""
    regexp {"timezone"\s*:\s*\x7b[^\x7d]*"abbr"\s*:\s*"([^"]*)"} $body -> tzabbr
    set loc [list]
    foreach v [list $city $region $country] { if {$v ne ""} { lappend loc $v } }
    if {[llength $loc]} { lappend out "Location: [join $loc {, }]" }
    if {$cc ne ""} { lappend out "Country Code: $cc" }
    if {$continent ne ""} { lappend out "Continent: $continent" }
    if {$capital ne ""} { lappend out "Capital: $capital" }
    if {$postal ne ""} { lappend out "Postal: $postal" }
    if {$calling ne ""} { lappend out "Calling Code: +$calling" }
    if {$tzid ne ""} {
        set tz $tzid
        if {$tzabbr ne ""} { append tz " ($tzabbr)" }
        lappend out "Timezone: $tz"
    }
    if {$isp ne ""} { lappend out "ISP: $isp" }
    if {$org ne "" && $org ne $isp} { lappend out "Org: $org" }
    if {$as ne ""} { lappend out "ASN: $as" }
    if {$condomain ne ""} { lappend out "ISP Domain: $condomain" }
    return [join $out "  "]
}

# ================= HTTP wrapper =================

# HTTPS state. Do not assume tls was loaded when this script was sourced:
# Eggdrop script load order can put whocom.tcl before another script that
# loads TclTLS. ensure_https is called for every HTTPS request, so a later
# tls load can recover without restarting the bot.
#
# whocom's TLS transport is registered under its OWN private URL scheme
# ($https_scheme), never as the process-wide "https" one. ::http::register
# is global: the old code unregistered and re-registered "https" on every
# !dom/!ip request, replacing whatever transport any other script had set
# up -- talkbot.tcl registers "https" once with a CA trust store so its
# certificate check (and the API key it protects) actually means
# something, and any channel user running !ip silently swapped that for
# whocom's transport (no CA file; unverified if tls_verify is 0). Requests
# are sent as $https_scheme://host/... and mapped back to https:// for
# logging, redirects, and callbacks.
#
# NOTE: these are reset on every source (rehash included) deliberately --
# they only record whether the transport is registered, which is cheap to
# re-detect, so a newly-loaded tls package is picked up without a restart.
namespace eval whocom {
    variable https_scheme "whocomhttps"
    variable https_ready 0
    variable https_error ""
    variable https_transport ""
    variable https_protocols {}
}

proc whocom::tls_version_rank {version} {
    switch -- $version {
        tls1   { return 10 }
        tls1.1 { return 11 }
        tls1.2 { return 12 }
        tls1.3 { return 13 }
        default { return -1 }
    }
}

proc whocom::tls_version_allowed {version min max} {
    set rank [whocom::tls_version_rank $version]
    set minrank [whocom::tls_version_rank $min]
    set maxrank [whocom::tls_version_rank $max]
    if {$rank < 0} { return 0 }
    if {$minrank >= 0 && $rank < $minrank} { return 0 }
    if {$maxrank >= 0 && $rank > $maxrank} { return 0 }
    return 1
}

proc whocom::https_socket {args} {
    variable tls_verify
    variable tls_min_version
    variable tls_max_version
    variable https_protocols

    # http::register normally supplies host and port. Accept the complete
    # argument list so this transport also tolerates Tcl HTTP variants that
    # append transport arguments.
    if {[llength $args] < 2} {
        return -code error "HTTPS transport expected host and port, got: $args"
    }

    set host [lindex $args end-1]
    set port [lindex $args end]

    set opts [list -autoservername 1 -require $tls_verify]
    # The http package asks for a non-blocking connect ("-async host port").
    # Dropping it made every HTTPS lookup's connect (DNS + TCP + TLS) block
    # the whole bot's event loop.
    if {"-async" in [lrange $args 0 end-2]} { lappend opts -async }

    foreach proto {tls1 tls1.1 tls1.2 tls1.3} {
        if {[lsearch -exact $https_protocols $proto] < 0} { continue }
        lappend opts -$proto [whocom::tls_version_allowed             $proto $tls_min_version $tls_max_version]
    }

    return [::tls::socket {*}$opts $host $port]
}

proc whocom::ensure_https {} {
    variable https_scheme
    variable https_ready
    variable https_error
    variable https_transport
    variable https_protocols

    # Already registered (and still ours): nothing to do.
    if {$https_ready && [info exists ::http::urlTypes($https_scheme)]} { return 1 }

    set https_ready 0
    set https_error ""
    set https_transport ""
    set https_protocols {}

    if {[catch {package require tls} err]} {
        set https_error $err
        return 0
    }

    if {[catch {set https_protocols [::tls::protocols]} err]} {
        # TclTLS releases without tls::protocols: keep a conservative
        # fallback. The configured TLS options are still applied.
        set https_protocols {tls1.2}
    }

    if {[catch {
        set https_transport [list ::whocom::https_socket]
        ::http::register $https_scheme 443 $https_transport
    } err]} {
        set https_error $err
        set https_transport ""
        return 0
    }

    set https_ready 1
    return 1
}

# Resolve a Location header against the URL it came from. Handles the
# absolute case (the common one -- rdap.org's redirector sends a full
# URL) and falls back to a reasonable best-effort join for a relative
# Location, rather than assuming absolute and silently mis-navigating.
proc whocom::resolve_url {base loc} {
    if {[regexp {^[a-zA-Z][a-zA-Z0-9+.-]*://} $loc]} {
        return $loc
    }
    if {![regexp {^([a-zA-Z][a-zA-Z0-9+.-]*://[^/]+)} $base -> origin]} {
        # Base isn't a URL we understand; nothing sane to resolve against.
        return $loc
    }
    if {[string index $loc 0] eq "/"} {
        return "$origin$loc"
    }
    set slash [string last "/" $base]
    if {$slash > [string length $origin]} {
        set dir [string range $base 0 $slash]
    } else {
        set dir "$origin/"
    }
    return "$dir$loc"
}

# Fire a GET and invoke $callback as:
#   callback body url http_status_code
#
# This is asynchronous (http::geturl -command): eggdrop / Tcl are
# single-threaded and event-driven, so a *synchronous* geturl here would
# stall the entire bot -- every channel, every other command, WHOIS/CTCP
# timers, the works -- for up to the full timeout on every fallback
# source and every redirect hop, and any unauthenticated channel user can
# trigger it via !dom/!ip. Going async means the event loop stays free
# while a lookup is in flight.
#
# http::status reports "ok" as soon as the transaction completes, whether
# the response was 200 or 302 -- it does NOT follow redirects. rdap.org's
# domain endpoint is a redirector (302 to the domain's authoritative RDAP
# server), so without following Location ourselves every RDAP lookup was
# silently "succeeding" against the redirector's near-empty 302 body.
#
# Redirect targets are validated by whocom::redirect_allowed before being
# followed: only https, and never to an IP-literal or "localhost" host.
# Without this, a compromised or DNS-hijacked upstream (or an open
# redirect on one of them) could point the bot's outbound request at an
# internal host -- e.g. a cloud metadata endpoint or something on
# localhost -- and have whatever it returns get parsed and echoed back
# into the channel.
proc whocom::http_get {url callback} {
    return [whocom::http_get_impl $url $callback 0]
}

proc whocom::http_get_impl {url callback redirs} {
    variable http_timeout
    variable https_scheme
    variable https_error

    set wire_url $url
    if {[string match -nocase "https://*" $url]} {
        if {![whocom::ensure_https]} {
            whocom::log "HTTPS unavailable for $url: $https_error"
            whocom::invoke_callback $callback "" $url "tls-unavailable"
            return 0
        }
        # Sent via whocom's private scheme -- see the HTTPS state note.
        set wire_url "${https_scheme}://[string range $url 8 end]"
    } elseif {![string match -nocase "http://*" $url]} {
        whocom::log "refusing non-http(s) URL: $url"
        whocom::invoke_callback $callback "" $url "bad-scheme"
        return 0
    }

    if {[catch {package require http} http_err]} {
        whocom::log "HTTP package unavailable: $http_err"
        whocom::invoke_callback $callback "" $url "http-unavailable"
        return 0
    }

    if {[catch {
        http::geturl $wire_url \
            -timeout $http_timeout \
            -headers {User-Agent {Eggdrop whocom/1.2} Accept {application/json,text/plain,*/*}} \
            -progress whocom::http_progress \
            -command [list whocom::http_done $callback $url $redirs]
    } err]} {
        whocom::log "HTTP request failed for $url: $err"
        whocom::invoke_callback $callback "" $url "request-failed"
        return 0
    }
    return 1
}

# -progress callback for http::geturl. Fired periodically as the body
# streams in; aborts the transfer once it exceeds http_max_body so a
# malicious/compromised upstream can't force the bot to buffer an
# unbounded response in memory.
proc whocom::http_progress {token total current} {
    variable http_max_body
    if {$http_max_body > 0 && $current > $http_max_body} {
        catch { ::http::reset $token "body-too-large" }
    }
}

# Decide whether a redirect target is safe to follow. Only https, and
# never straight to an IP literal (v4 or v6) or "localhost" -- legitimate
# redirects from these lookup services go to public hostnames, so
# anything landing on a raw address (loopback, link-local, RFC1918,
# multicast, or otherwise) is treated as unsafe rather than trying to
# enumerate every private range.
proc whocom::redirect_allowed {url} {
    if {![regexp -nocase {^https://([^/:@]+)(:[0-9]+)?(/|$)} $url -> host]} {
        return 0
    }
    if {![regexp {^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$} $host]} {
        return 0
    }
    foreach label [split $host "."] {
        if {$label eq "" || [string length $label] > 63} { return 0 }
        if {![regexp {^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$} $label]} {
            return 0
        }
    }
    # host_is_ip_or_local already refuses every bare IPv4/IPv6 literal
    # (not just private ranges -- a legitimate redirect target here is
    # always a hostname) plus "localhost".
    return [expr {![whocom::host_is_ip_or_local $host]}]
}

proc whocom::http_done {callback url redirs token} {
    variable http_max_redirects

    set status [http::status $token]
    set ncode [http::ncode $token]
    set body [http::data $token]
    set meta [http::meta $token]
    set httperr [http::error $token]
    catch {http::cleanup $token}

    if {$status eq "reset"} {
        whocom::log "HTTP request for $url aborted: $httperr"
        whocom::invoke_callback $callback "" $url "aborted"
        return
    }

    if {$status ne "ok"} {
        whocom::log "HTTP request failed for $url: status=$status code=$ncode"
        whocom::invoke_callback $callback "" $url $ncode
        return
    }

    if {$ncode in {301 302 303 307 308}} {
        set loc ""
        foreach {k v} $meta {
            if {[string equal -nocase $k "Location"]} { set loc $v; break }
        }
        if {$loc eq ""} {
            whocom::log "HTTP redirect ($ncode) for $url had no Location header"
            whocom::invoke_callback $callback "" $url $ncode
            return
        }
        set loc [whocom::resolve_url $url $loc]
        if {![whocom::redirect_allowed $loc]} {
            whocom::log "blocked unsafe HTTP redirect: $url -> $loc"
            whocom::invoke_callback $callback "" $url "unsafe-redirect"
            return
        }
        if {$redirs >= $http_max_redirects} {
            whocom::log "too many HTTP redirects for $url (stopped at $loc)"
            whocom::invoke_callback $callback "" $url "too-many-redirects"
            return
        }
        whocom::log "following HTTP redirect ($ncode): $url -> $loc"
        whocom::http_get_impl $loc $callback [expr {$redirs + 1}]
        return
    }

    whocom::invoke_callback $callback $body $url $ncode
}

# Invoke a http_get callback and, if the callback itself throws (a bug in
# a parser or result handler), log it instead of silently discarding it.
# Previously these calls were wrapped in a bare "catch { ... }" with the
# error result never inspected, so a callback-side bug (e.g. comparing a
# non-numeric status string with "==") would silently abort the whole
# lookup chain -- no reply to the user, no line in the log, nothing.
proc whocom::invoke_callback {callback args} {
    if {[catch {uplevel #0 [list {*}$callback {*}$args]} err]} {
        whocom::log "callback error ($callback): $err"
    }
}

##############################################################################
# Reconcile in-flight lookup queues against the timers that clear them.
#
# The load-once guard deliberately PRESERVES q_whois/q_whowas/q_ping/q_ver
# across a re-source, which is right for a .rehash: the utimer that will
# eventually answer or time out each queued caller is still pending, so
# wiping the queue would strand them (that's the bug the guard's own
# comment documents).
#
# A `.restart` rebuilds the Tcl interpreter, so the queues simply start
# empty there. What this guards against is a queue entry whose timeout
# timer has gone missing some other way -- e.g. another script sweeping
# [utimers] with killutimer on rehash. Such an entry would otherwise sit
# forever: its caller never gets a reply or a timeout, queue_allowed keeps
# answering "That lookup is busy" for that nick, and pending_total stays
# inflated against max_waiters_total.
#
# The core's timer table is the authority on what is really still pending.
# On every source, any queued key with no matching timeout timer armed is
# dropped (with a log line, since a caller is being silently given up on).
# Normally every timer is there and this is a no-op.
##############################################################################

proc whocom::reconcile_pending {} {
    if {[catch {utimers} active]} { return }
    set armed {}
    foreach t $active {
        set cmd [lindex $t 1]
        if {[string match "whocom::*_timeout *" $cmd]} {
            # {whocom::whois_timeout <key> <gen>} -- record proc+key.
            lappend armed "[lindex $cmd 0]|[lindex $cmd 1]"
        }
    }
    set dropped 0
    # The third column is the buffer/generation arrays belonging to THAT
    # queue, and only those.
    #
    # This used to unset buf_whois, buf_whowas, gen_whois, gen_whowas AND
    # gen_ver for the key on every drop, whichever queue the key came from
    # -- so cleaning up one orphan reached into three other lookups that
    # happened to be about the same nick, and the ones it reached into were
    # the LIVE ones this proc is careful not to touch. A .restart landing
    # while "bob" had both an orphaned !pi and a still-armed !ver dropped
    # gen_ver(bob) along with the ping orphan. Then:
    #
    #   - ver_timeout fires, finds no gen_ver(bob), and returns doing
    #     nothing -- that check exists to spot a STALE timer, and a missing
    #     generation is indistinguishable from one;
    #   - q_ver(bob) is therefore never cleared, so cmd_ver's `inflight`
    #     test is true forever and no further VERSION probe is ever sent
    #     for that nick -- every later !ver bob queues silently and is
    #     never answered;
    #   - pending_total stays inflated against max_waiters_total, and once
    #     16 waiters pile up queue_allowed answers "That probe is busy"
    #     for that nick for the life of the process.
    #
    # Which is, exactly, the permanent-wedge failure described at the top
    # of this block -- reintroduced by the cleanup written to prevent it.
    # gen_whois/gen_whowas had the same exposure, and a wiped buf_whois
    # additionally turned a live WHOIS into "no data for <nick>".
    #
    # q_ping has no companions: a ping is correlated by its stamp, which
    # lives in the queue entry itself, so dropping the entry is the whole
    # cleanup.
    foreach {arrname timeoutproc companions} {
        q_whois  whocom::whois_timeout  {buf_whois gen_whois}
        q_whowas whocom::whowas_timeout {buf_whowas gen_whowas}
        q_ping   whocom::ping_timeout   {}
        q_ver    whocom::ver_timeout    {gen_ver}
    } {
        upvar 0 whocom::$arrname arr
        if {![array exists arr]} { continue }
        foreach key [array names arr] {
            if {[lsearch -exact $armed "$timeoutproc|$key"] >= 0} { continue }
            incr dropped [llength $arr($key)]
            unset arr($key)
            foreach comp $companions {
                catch { unset whocom::${comp}($key) }
            }
        }
    }
    if {$dropped > 0} {
        whocom::log "cleared $dropped orphaned lookup waiter(s) with no timer behind them (restart during a lookup?)"
    }
}

##############################################################################
# Config validation. Every one of these is used in arithmetic or handed
# straight to utimer/after/http, in a path any channel user can trigger.
# A non-integer cooldown makes whocom::allowed raise on the first command;
# a non-integer irc_timeout makes utimer raise inside the bind, after the
# WHOIS has already gone out, leaving the caller queued with no timer --
# the same orphan state reconcile_pending exists to clean up.
##############################################################################

proc whocom::_cfg_int {name min max default} {
    upvar #0 whocom::$name v
    if {![info exists v] || ![string is integer -strict $v] || $v < $min
            || ($max ne "" && $v > $max)} {
        set had [expr {[info exists v] ? $v : "<unset>"}]
        putlog "whocom: CONFIG: invalid $name ('$had'); forcing $default."
        set v $default
    }
}

namespace eval whocom {
    ::whocom::_cfg_int cooldown                0 86400   15
    ::whocom::_cfg_int http_cooldown           0 3600    2
    ::whocom::_cfg_int max_arg_length          1 512     64
    ::whocom::_cfg_int irc_timeout             1 300     15
    ::whocom::_cfg_int ctcp_timeout            1 300     12
    ::whocom::_cfg_int http_timeout         1000 60000   8000
    ::whocom::_cfg_int http_max_body        1024 16777216 262144
    ::whocom::_cfg_int http_max_redirects      0 10      3
    ::whocom::_cfg_int whois_tcp_timeout    1000 60000   6000
    ::whocom::_cfg_int max_whois_connections 1 256       16
    ::whocom::_cfg_int max_waiters_per_target 1 1000     16
    ::whocom::_cfg_int max_waiters_total       1 100000  128

    if {$cooldown_scope ni {user command}} {
        putlog "whocom: CONFIG: invalid cooldown_scope ('$cooldown_scope'); forcing user."
        set cooldown_scope "user"
    }
    if {$restrict_onchan ni {0 1}} {
        putlog "whocom: CONFIG: restrict_onchan must be 0 or 1; forcing 1."
        set restrict_onchan 1
    }
    if {$tls_verify ni {0 1}} {
        putlog "whocom: CONFIG: tls_verify must be 0 or 1; forcing 1."
        set tls_verify 1
    }
    if {$tls_verify == 0} {
        putlog "whocom: WARNING: tls_verify is 0 -- HTTPS certificates are NOT checked, so an on-path attacker can feed this bot whatever lookup results they like."
    }
    # tls_min_version/tls_max_version were never validated, unlike every
    # other security-relevant setting in this block. whocom::tls_version_rank
    # (which enforces them) returns -1 for anything it doesn't recognize --
    # including a typo, a wrong case ("TLS1.2"), or an empty string -- and
    # tls_version_allowed treats a -1 bound as "no floor/ceiling", i.e. it
    # FAILS OPEN: a malformed tls_min_version silently drops the minimum
    # version requirement instead of erring toward the safer default, the
    # opposite of how tls_verify/restrict_onchan above are handled. Force
    # both back to their shipped defaults if either isn't one of the four
    # values tls_version_rank actually recognizes.
    if {[whocom::tls_version_rank $tls_min_version] < 0} {
        putlog "whocom: CONFIG: invalid tls_min_version ('$tls_min_version'); forcing tls1.2."
        set tls_min_version "tls1.2"
    }
    if {[whocom::tls_version_rank $tls_max_version] < 0} {
        putlog "whocom: CONFIG: invalid tls_max_version ('$tls_max_version'); forcing tls1.3."
        set tls_max_version "tls1.3"
    }
    if {[whocom::tls_version_rank $tls_min_version] > [whocom::tls_version_rank $tls_max_version]} {
        putlog "whocom: CONFIG: tls_min_version ('$tls_min_version') is above tls_max_version ('$tls_max_version'); forcing both back to tls1.2/tls1.3."
        set tls_min_version "tls1.2"
        set tls_max_version "tls1.3"
    }
    foreach __d {dest_wa dest_wi dest_ping dest_ver dest_domain dest_ip dest_help} {
        if {[set whocom::$__d] ni {chan notice msg}} {
            putlog "whocom: CONFIG: invalid $__d; forcing notice."
            set whocom::$__d "notice"
        }
    }
    unset -nocomplain __d
    # channels: trim each entry, drop anything malformed rather than let a
    # typo (a name with no #, a pasted comma, a trailing space) sit in the
    # list matching nothing forever with no indication why every one of
    # these commands went quiet in that channel.
    set __clean {}
    foreach __c $channels {
        set __c [string trim $__c]
        if {[string length $__c] < 2 || [string length $__c] > 64
                || ![regexp {^[#&+!]} $__c]
                || [regexp {[\s,\x00-\x1f]} $__c]} {
            putlog "whocom: CONFIG: dropping malformed channels entry '$__c'."
            continue
        }
        lappend __clean $__c
        if {[llength $__clean] >= 64} { break }
    }
    set channels $__clean
    unset -nocomplain __c __clean
    # http_lastuse is the shared outbound-HTTP throttle stamp. It used to
    # be a plain `variable http_lastuse 0` in the config block, i.e. an
    # assignment that ran on every source -- so a .rehash reset the
    # cross-user backstop that exists to keep the free lookup APIs from
    # banning this bot's IP. Declared without resetting now.
    variable http_lastuse
    if {![info exists http_lastuse]} { set http_lastuse 0 }
}

whocom::reconcile_pending

if {[llength $whocom::channels] == 0} {
    set whocom::_scope "every channel the bot is on"
} else {
    set whocom::_scope "[join $whocom::channels {, }]"
}
putlog "whocom.tcl loaded (!wa/!whowas !wi/!whois !pi !ver !dom !ip !whohelp) -- active in $whocom::_scope"
unset -nocomplain whocom::_scope
