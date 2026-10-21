# Info
# Original Author : MeTroiD - #v1per on Quakenet
# Botnet relay edit: watches channels across multiple servers via the Eggdrop botnet
#
# ***  HOME RELAY BOT copy  ***
# This is the spychan config for the ONE bot that owns the home channel and
# prints everything the leaf bots relay to it. The relay engine below is byte-
# for-byte identical to the leaf copy; only the CONFIG block differs.
set spy(author)  "MeTroiD - #v1per on Quakenet"
set spy(version) "1.4.1-botnet-home"

# WIRE FORMAT CHANGED IN 1.4 — leaf copies must be updated in lockstep. A leaf
# now sends "SPYCHAN <network>: <event>" WITHOUT its own botnick; the home bot
# stamps the authenticated sender instead. A 1.3 leaf talking to a 1.4 home bot
# still works, but its lines show the bot name twice (once from the core, once
# from the stale payload) until the leaf is updated.

# ----------------------------------------------------------------------------
# WHAT THIS BOT DOES (the home / collector bot)
#
# The leaf bots each sit on their own network, watch a channel there, and ship
# their formatted lines across the Eggdrop botnet to THIS bot. This bot prints
# every one of those lines — plus anything it watches on its own network — into
# the single home channel below (#prototype).
#
#   QuakeNet : qbot  watches #scrabble  --\
#   DALnet   : dbot  watches #poker     ----> botnet --> THIS BOT --> #prototype
#   Libera   : lbot  watches #chat      --/
#
# Events relayed by default: JOIN, PART, QUIT (SIGN) and netSPLIT. Chat lines,
# actions, kicks and mode changes are present but commented out in the bind
# block below -- uncomment one to turn it on, comment it back out to turn it
# off. Commenting a line out now actually removes the bind on the next .rehash;
# it did not before 1.4.1, so a bind you had once enabled stayed live forever.
#
# !spyhelp [topic] — in-channel command reference (topics: about, watch,
# events, network). Public, and deliberately says nothing about spy(homebot),
# spy(relaybots) or the burst-guard settings -- those are config, not user
# help, and naming them in a public reply would hand a would-be abuser the
# botnet topology this script's own ORIGIN AUTHENTICATION comments guard
# against.
#
# Every tunable in the CONFIG block is range-checked at load (see CONFIG
# VALIDATION below) and a bad value is logged and replaced with its default.
# This matters most for the burst guard: before 1.4.1 a non-numeric or zero
# spy(rate_max)/spy(rate_window) silently switched the guard OFF rather than
# erroring, which is the opposite of what it is there for. Watch the partyline
# on load -- "spychan: CONFIG: invalid ..." means the value you typed is NOT
# the one in effect.
#
# Requirements:
#   - Every bot (this one + all leaves) is linked into ONE botnet (.link).
#   - The bots must be linked for any relay to travel — an unlinked leaf just
#     logs the dropped line.
#   - On each LEAF bot, set spy(homebot) to THIS bot's botnet nick so it knows
#     where to send. On THIS bot, spy(homebot) is left "" — that marks it as the
#     home printer, so it prints both incoming botnet relays and its own local
#     channels straight to #prototype.
# ----------------------------------------------------------------------------

# ---- HOME BOT CONFIG -------------------------------------------------------

# "" marks THIS bot as the home printer: it prints relays received from the
# leaf bots, and prints its own watched channels locally. Do NOT put this bot's
# own nick here — "" is what flags it as home. (Leaf bots, by contrast, set this
# to THIS bot's botnet nick.)
# NOTE: corrected to "" — this is the HOME bot copy. A previous edit left the
# printer's own nick ("Raistlin") here, which only worked if $botnick happened
# to equal it; on any other botnick this bot silently flipped to leaf behavior
# and tried to relay to a bot named "Raistlin" instead of printing locally.
# "" makes it the home printer unconditionally, matching this file's purpose.
set spy(homebot) ""

# The home channel. Everything the botnet relays lands here.
set spy(home) "#prototype"

# Channel(s) THIS home bot watches on ITS OWN network, if any. Leave "" if this
# bot only collects and prints and doesn't watch a local channel of its own.
set spy(chans) "#poets"

# Watch EVERY channel this bot is in instead of the fixed spy(chans) list.
# Keep 0 so the home bot only watches what you name above (or nothing).
set spy(allchans) 0

# Botnet nicks allowed to feed relay lines to this home bot. Empty = accept from
# any linked bot (botnet links are already trusted). Set to a space-separated
# list of your leaf-bot nicks (e.g. "qbot dbot lbot") to accept relays only from
# them and ignore anything else that reaches the SPYCHAN bind.
set spy(relaybots) ""

# Short tag for THIS bot's OWN network (only stamped on channels this bot itself
# watches; relayed lines already carry their origin network's tag). "" disables.
set spy(netname) ""

# Burst guard (PING-TIMEOUT FIX). The home bot prints EVERY leaf's relay plus
# its own watched channel into one channel, so a netsplit/netjoin (one line per
# user) or several busy leaves can dump hundreds of lines at once — enough to
# balloon the send queue and get the bot dropped for excess flood (logged as a
# ping timeout). These cap channel output to spy(rate_max) lines per
# spy(rate_window) seconds; overflow is dropped and summarised. rate_max 0 = off.
#
# THE SUSTAINED RATE MUST STAY BELOW THE QUEUE DRAIN RATE. puthelp empties at
# roughly one line per second under default flood settings. The previous 10-per-5s
# setting allowed 2 lines/s — double the drain — so a spike was absorbed but a
# SUSTAINED feed (three busy leaves, a long netjoin) still grew the send queue
# without bound and produced the exact ping timeout this guard exists to prevent.
# 4 per 5 s is 0.8 lines/s, leaving headroom. Raise rate_max only if you have
# measured your bot's actual drain rate; lower it if you still see lag.
set spy(rate_max)    4
set spy(rate_window) 5

# Output delivery mode. Every line spychan would otherwise print into
# spy(home) goes through this switch instead, so you can stop it from
# flooding a channel entirely:
#
#   channel    - PRIVMSG the home channel spy(home). (Default, old behavior.)
#   notice     - NOTICE the home channel spy(home) instead of PRIVMSG. Still
#                visible to everyone in the channel, but NOTICEs are excluded
#                from most clients' channel flood/highlight handling and are
#                easy to filter, so it's a lighter-weight footprint than PRIVMSG.
#   privnotice - NOTICE sent privately to ONE nick (spy(outnick)) instead of
#                the channel. Nothing is printed to any channel at all.
#   privmsg    - PRIVMSG sent privately to ONE nick (spy(outnick)) instead of
#                the channel. Nothing is printed to any channel at all.
#
# spy(outnick) is required (and validated) for privnotice/privmsg; it is
# ignored for channel/notice.
set spy(outmode) "channel"

# Nick to privately message/notice when spy(outmode) is privnotice or privmsg.
# Ignored otherwise. Must be a single nick with no whitespace.
set spy(outnick) ""

# ---- END CONFIG ------------------------------------------------------------

# ---- CONFIG VALIDATION -----------------------------------------------------
#
# None of the knobs above were checked, and the burst guard fails OPEN on a bad
# value rather than closed -- which matters, because that guard is the whole
# ping-timeout fix. Measured, all four silently switch it off with no error and
# nothing in the log:
#
#   rate_max "abc"   -> Tcl compares non-numeric operands as STRINGS, so both
#                       `<= 0` and `>= rate_max` go the wrong way and no line is
#                       ever throttled.
#   rate_max ""      -> "" sorts below "0", so the guard reports itself disabled.
#   rate_window 0    -> rate_reset lands on `now` every call, so the window rolls
#                       over before it can ever accumulate a count.
#   rate_window -5   -> same, permanently in the past.
#
# A malformed spy(chans) is worse than silent: `foreach c $spy(chans)` on a value
# with an unbalanced brace raises "unmatched open brace in list" inside a JOIN
# bind, i.e. once per join, forever.
#
# Runs on every source, so an edit-then-.rehash is validated too. Bad values are
# forced to the documented default with a log line rather than left to fail
# quietly at 3am.
proc spychan:cfg:int {name min default} {
  global spy
  if {![info exists spy($name)] || ![string is integer -strict $spy($name)]
      || $spy($name) < $min} {
    set had [expr {[info exists spy($name)] ? $spy($name) : "<unset>"}]
    putlog "spychan: CONFIG: invalid spy($name) ('$had'); using $default."
    set spy($name) $default
  }
}
# rate_max 0 legitimately means "guard off", so its floor is 0; rate_window is a
# divisor of sorts and must be at least 1 second to bound anything.
spychan:cfg:int rate_max    0 4
spychan:cfg:int rate_window 1 5
# (log_window is declared further down, next to spychan:logonce, and is
# validated there -- checking it here would only ever see it unset.)
if {![info exists spy(allchans)] || $spy(allchans) ni {0 1}} {
  putlog "spychan: CONFIG: spy(allchans) must be 0 or 1; using 0."
  set spy(allchans) 0
}
# spy(outmode) picks the sink spychan:say writes to. An unrecognised value
# falls back to "channel" (the pre-existing behavior) rather than silently
# doing nothing, same philosophy as every other knob validated here.
if {![info exists spy(outmode)] ||
    $spy(outmode) ni {channel notice privnotice privmsg}} {
  set had [expr {[info exists spy(outmode)] ? $spy(outmode) : "<unset>"}]
  putlog "spychan: CONFIG: invalid spy(outmode) ('$had'); using channel."
  set spy(outmode) "channel"
}
if {![info exists spy(outnick)]} { set spy(outnick) "" }
regsub -all {[\u0000-\u001f\u007f-\u009f]} $spy(outnick) "" spy(outnick)
set spy(outnick) [string trim $spy(outnick)]
# outnick is only meaningful (and required) for the two private modes. Fall
# back to "channel" rather than leaving a private mode configured with
# nowhere to send -- that would otherwise silently drop every line at the
# spychan:say sink forever (see the target check added there).
if {$spy(outmode) in {privnotice privmsg} &&
    ![regexp {^[^\s,]{1,30}$} $spy(outnick)]} {
  putlog "spychan: CONFIG: spy(outmode) is '$spy(outmode)' but spy(outnick) ('$spy(outnick)') is not a single valid nick; falling back to channel output."
  set spy(outmode) "channel"
}
# The channel/bot name lists are iterated with foreach and interpolated into
# outgoing lines, so they must be well-formed Tcl lists and free of the control
# characters spychan:clean exists to keep off the wire.
foreach {__k __label} {chans "watched channel list" relaybots "relay bot allowlist"} {
  if {![info exists spy($__k)]} { set spy($__k) "" ; continue }
  if {[catch {llength $spy($__k)}]} {
    putlog "spychan: CONFIG: spy($__k) is not a valid list ($__label); using \"\"."
    set spy($__k) ""
  }
}
unset -nocomplain __k __label
# Inline regsub rather than a call to spychan:clean: this block runs at CONFIG
# time, ABOVE the proc definitions, so on a FIRST load spychan:clean does not
# exist yet. (It would have appeared to work on a .rehash, where the previous
# load's proc is still defined -- the worst kind of latent break.)
foreach __k {home homebot netname} {
  if {![info exists spy($__k)]} { set spy($__k) "" ; continue }
  regsub -all {[\u0000-\u001f\u007f-\u009f]} $spy($__k) "" __v
  set spy($__k) [string trim $__v]
}
unset -nocomplain __k __v
# Validate the output target as one IRC channel token. It is interpolated
# directly into PRIVMSG, so accepting arbitrary text here can create malformed
# protocol lines. Require the normal IRC channel prefixes and reject all
# whitespace/control characters. The length cap also prevents an accidental
# oversized target from consuming the relay's output budget.
# Enforced, not just logged: a bad value used to go out as-is, so "prototype"
# (missing its #) PRIVMSGed every relay line to a USER named prototype.
# Cleared, spychan:say drops output and logs once a minute instead.
if {![regexp {^[#&][^\s,]{1,199}$} $spy(home)]} {
  putlog "spychan: CONFIG: spy(home) ('$spy(home)') is not a valid single IRC channel name -- nothing will be printed until this is fixed."
  set spy(home) ""
}

# homebot is used as an Eggdrop botnet target. Keep it to one conservative
# botnet nick rather than allowing whitespace/control characters into putbot or
# islinked arguments. An invalid value cannot be made useful at runtime, so
# force the leaf into the documented disconnected state.
if {$spy(homebot) ne "" && ![regexp {^[^\s]{1,63}$} $spy(homebot)]} {
  putlog "spychan: CONFIG: spy(homebot) ('$spy(homebot)') is not a valid botnet nick -- disabling botnet relay target."
  set spy(homebot) "__invalid__"
}

# Validate each configured channel/bot list element after list parsing. A list
# can be syntactically valid Tcl while still containing values that can never
# be valid IRC/Eggdrop identifiers. Dropping only bad entries preserves valid
# configuration rather than disabling the entire watch/allowlist.
foreach __k {chans relaybots} {
  if {![info exists spy($__k)]} { continue }
  set __good {}
  foreach __v $spy($__k) {
    if {$__k eq "chans"} {
      if {[regexp {^[#&][^\s,]{1,199}$} $__v]} {
        lappend __good $__v
      } else {
        putlog "spychan: CONFIG: ignoring invalid channel in spy(chans): '$__v'"
      }
    } else {
      if {[regexp {^[^\s]{1,63}$} $__v]} {
        lappend __good $__v
      } else {
        putlog "spychan: CONFIG: ignoring invalid bot in spy(relaybots): '$__v'"
      }
    }
  }
  set spy($__k) $__good
}
unset -nocomplain __k __v __good
# ---- END CONFIG VALIDATION -------------------------------------------------

# Relay JOINs, PARTs, QUITs and netSPLITs. Chat lines, actions, kicks and mode
# changes are intentionally disabled -- uncomment the matching `bind` line to
# relay that event type again. The SPYCHAN bind is required for the botnet relay.
#
# (This block used to say "JOINs and PARTs only" while SIGN and SPLT were both
# bound right below it, so the file misdescribed two of the four event types it
# actually relays.)
#
# EVERY event type gets an unconditional `unbind` above its bind line --
# including the DISABLED ones. `bind` is idempotent, so the unbind in front of
# an ENABLED bind is only belt-and-braces; the ones in front of the disabled
# binds are the load-bearing half. A .rehash re-sources this file but does NOT
# clear binds, so commenting out a `bind` line did nothing at all on a bot that
# had previously loaded it enabled: the old bind stayed live and kept relaying
# for the rest of the process's life, while the file now claimed that event was
# off. Measured: enable PUBM, comment it out, .rehash -- still bound. Unbinding
# unconditionally is what makes commenting a line out actually mean something.
catch { unbind PUBM -|- * spychan:chat }
#bind PUBM  -|- *         spychan:chat
catch { unbind CTCP -|- "ACTION" spychan:action }
#bind CTCP  -|- "ACTION"  spychan:action
catch { unbind SIGN -|- * spychan:sign }
bind SIGN  -|- *         spychan:sign
catch { unbind JOIN -|- * spychan:join }
bind JOIN  -|- *         spychan:join
catch { unbind PART -|- * spychan:part }
bind PART  -|- *         spychan:part
catch { unbind SPLT -|- * spychan:split }
bind SPLT  -|- *         spychan:split
catch { unbind KICK -|- * spychan:kick }
#bind KICK  -|- *         spychan:kick
catch { unbind RAW -|- "MODE" spychan:mode }
#bind RAW   -|- "MODE"    spychan:mode
catch { unbind BOT -|- "SPYCHAN" spychan:frombot }
bind BOT   -|- "SPYCHAN" spychan:frombot

# Self-announce (push, not a command). Each bot tells the home bot its own botnet
# nick + IRC network, and the home bot prints one line to the home channel. No one
# types anything: a leaf announces the moment it links to the home bot (LINK bind),
# and again on script (re)load if it's already linked; the home bot announces itself
# on load. SPYHELLO is the announcement crossing the botnet link the relay uses.
catch { unbind BOT -|- "SPYHELLO" spychan:hello }
bind BOT   -|- "SPYHELLO" spychan:hello
catch { unbind LINK -|- * spychan:link }
bind LINK  -|- *          spychan:link

# ----------------------------------------------------------------------------
# !spyhelp — in-channel command reference.
#
# This script has exactly one user-facing command; everything else is a push
# (self-announce) or a passive relay. The reply goes straight to the channel
# the command was typed in via puthelp, NOT through spychan:say/spychan:out --
# those are the relay's own fan-in/fan-out and are for relayed events, not for
# answering a command typed on whatever channel the bot happens to be on.
# ----------------------------------------------------------------------------
proc spychan:cmd_help {nick {topic ""}} {
  global spy
  switch -- [string tolower [string trim $topic]] {
    about {
      puthelp "NOTICE $nick :\002spychan\002 v$spy(version) relays JOIN/PART/QUIT/netsplit events from watched channels into a home channel, over the Eggdrop botnet if this isn't the home bot."
    }
    watch {
      if {[spychan:ishome] && $spy(allchans)} {
        puthelp "NOTICE $nick :This bot watches every channel it's on and relays their events."
      } elseif {[spychan:ishome] && $spy(chans) ne ""} {
        puthelp "NOTICE $nick :This bot watches: $spy(chans)"
      } elseif {[spychan:ishome]} {
        puthelp "NOTICE $nick :This bot watches no local channel of its own -- it only prints relays from other bots."
      } else {
        puthelp "NOTICE $nick :This is a leaf bot -- it watches its own network's channel(s) and relays events onward."
      }
    }
    events {
      puthelp "NOTICE $nick :Relayed by default: JOIN, PART, QUIT, netSPLIT. Chat/action/kick/mode relaying can be enabled per-bot by an admin."
    }
    network {
      puthelp "NOTICE $nick :This bot's network: [spychan:net:mine]"
    }
    default {
      puthelp "NOTICE $nick :\002spychan v$spy(version)\002 -- relays channel JOIN/PART/QUIT/netsplit events to a shared home channel across the botnet."
      puthelp "NOTICE $nick :\002!spyhelp <topic>\002 for more: about, watch, events, network."
    }
  }
}

# !spyhelp is public, and every reply sits in the same puthelp queue the relay
# drains through, so an unthrottled one let anyone in any channel the bot is on
# back up relay output (or flood the bot off) by repeating it. One answer per
# host per spy(help_cooldown) seconds.
if {![info exists spy(help_cooldown)]} { set spy(help_cooldown) 30 }
spychan:cfg:int help_cooldown 0 30
array set spy_helpseen {}
proc spychan:pub_help {nickname hostname handle channel arguments} {
  global spy spy_helpseen
  set now [clock seconds]
  set key [string tolower $hostname]
  if {[info exists spy_helpseen($key)] && $now - $spy_helpseen($key) < $spy(help_cooldown)} { return }
  if {[array size spy_helpseen] > 256} {
    foreach k [array names spy_helpseen] {
      if {$now - $spy_helpseen($k) >= $spy(help_cooldown)} { unset spy_helpseen($k) }
    }
    if {[array size spy_helpseen] > 256} { array unset spy_helpseen * }
  }
  set spy_helpseen($key) $now
  spychan:cmd_help $nickname [lindex [split [string trim $arguments]] 0]
}
catch { unbind pub -|- "!spyhelp" spychan:pub_help }
bind pub -|- "!spyhelp" spychan:pub_help

# Is $channel one we watch on this bot's network? In allchans mode we relay any
# channel the bot is actually on (its Eggdrop channel list); otherwise only the
# channels named in spy(chans). [channels] returns the bot's joined channel list.
proc spychan:watch {channel} {
  global spy
  # Never watch the channel we print INTO. Otherwise the bot reports on its own
  # output channel: harmless-looking with only JOIN/PART bound, but the header
  # invites re-enabling `bind PUBM`, and at that point every line spychan prints
  # to spy(home) is itself an event in spy(home) and gets relayed again — a
  # self-amplifying loop the burst guard throttles but never terminates. Same
  # trap if spy(allchans) is set to 1 while the bot sits in the home channel.
  if {[string equal -nocase $channel $spy(home)]} { return 0 }
  if {$spy(allchans)} {
    foreach c [channels] {
      if {[string equal -nocase $channel $c]} { return 1 }
    }
    return 0
  }
  # Guarded: this runs inside a JOIN/PART/SIGN/SPLT bind, where an error has
  # nowhere useful to go and repeats on every single event. spy(chans) is
  # hand-edited, and a value with an unbalanced brace makes foreach raise
  # "unmatched open brace in list" once per join, forever. The CONFIG validation
  # above catches that at load; this is the backstop for a value changed live.
  # NOTE: the result is computed into a variable and returned AFTER the catch,
  # never from inside it. `return` inside a catch script is intercepted by that
  # catch (completion code TCL_RETURN, not TCL_OK), so a `return 1` in the loop
  # below would be reported as a non-zero catch result -- i.e. every successful
  # match would look like an error and the proc would answer "not watched".
  set hit 0
  if {[catch {
    foreach c $spy(chans) {
      if {[string equal -nocase $channel $c]} { set hit 1 ; break }
    }
  } err]} {
    spychan:logonce "badchans" "spychan: spy(chans) is not a valid list ($err) -- watching nothing until it is fixed."
    return 0
  }
  return $hit
}

# Sanitize everything bound for the channel or the botnet. Two jobs:
#
#   1. Strip every C0 control char (\000-\037) and DEL (\177). This covers:
#      - CR and LF, which would let crafted IRC text inject an extra IRC
#        command (PRIVMSG path) or an extra BOTNET command to the home bot
#        (putbot path -- that one runs with botnet-link privilege, so it is
#        the dangerous one);
#      - NUL, which terminates the string;
#      - \001, which opens a CTCP;
#      - \007 (BEL), which beeps every client in the home channel;
#      - the mIRC colour/format codes (\002 \003 \017 \026 \035 \037 ...) a
#        user could embed to forge the "[net] [chan] <nick>" prefix or garble
#        the log. A relay line is plain text; none of these belong in it.
#      IRC servers usually strip CR/LF, but a relay must not trust the transport.
#
#   2. Cap the length so one crafted line can't flood the home channel or push
#      an oversized frame across the botnet. The cap is measured in BYTES (UTF-8),
#      not characters, so it holds even for multi-byte text; 400 bytes keeps clear
#      of IRC's 512-byte line limit once the prefixes and server-added source are
#      added. The trim lands on a codepoint boundary so a char is never split.
proc spychan:clean {s} {
  # \u0000-\u001f = C0 controls (incl. CR/LF/NUL/CTCP/BEL); \u007f = DEL;
  # \u0080-\u009f = C1 controls. C1 is stripped by Unicode CODEPOINT, so this
  # removes only genuine C1 control chars and never a legitimate accented
  # letter (e.g. U+00E9 'é' is unaffected).
  regsub -all {[\u0000-\u001f\u007f-\u009f]} $s "" s
  # Cap by BYTES, not characters. A relayed line becomes a UTF-8 PRIVMSG (and,
  # on a leaf, a botnet frame); IRC's limit is 512 BYTES on the wire, and one
  # non-ASCII char is 2-4 bytes, so a 400-CHARACTER cap could emit ~1600 bytes
  # and get truncated by the server (or bloat the send queue the burst guard
  # exists to protect). Trim to <=400 bytes, but only on a codepoint boundary so
  # a multi-byte char is never split into an invalid partial sequence. The "..."
  # marker (3 bytes) is included in the budget, so the final line is <=400 bytes.
  if {[string length [encoding convertto utf-8 $s]] > 400} {
    # Start the walk at 397 CHARACTERS, not at the full string length. Any prefix
    # longer than 397 characters is necessarily longer than 397 bytes (UTF-8 uses
    # >=1 byte per character), so the answer can never exceed 397 — starting
    # higher just burns iterations. This matters because each iteration re-encodes
    # the whole prefix, making the loop O(n^2) in the input length, and $s on the
    # spychan:frombot path arrives from a BOTNET frame, which is not bounded by
    # IRC's 512-byte line limit. A multi-megabyte line from a compromised or buggy
    # leaf would otherwise walk millions of re-encodings on the single-threaded
    # event loop. Capping the start bounds the loop to <=397 iterations for any
    # input, however large.
    set n [expr {min([string length $s], 397)}]
    while {$n > 0 && [string length [encoding convertto utf-8 [string range $s 0 [expr {$n - 1}]]]] > 397} {
      incr n -1
    }
    set s "[string range $s 0 [expr {$n - 1}]]..."
  }
  return $s
}

# ── Throttled putlog ────────────────────────────────────────────────────────
# Emits a log line at most once per spy(log_window) seconds per $key.
#
# The rejection paths (unlisted bot sending SPYCHAN / SPYHELLO) logged once per
# received frame with no limit, so a misconfigured or rogue linked bot could
# drive unbounded logfile growth just by spamming a command this script already
# decided to ignore. The message is scrubbed through spychan:clean because it
# embeds $frombot, which crossed the botnet link and is no more trusted than any
# other relayed field — control characters do not belong in the logfile either.
# These are guarded (not plain `set`) so a .rehash mid-burst doesn't zero the
# sliding window right when the guard is under load -- the one case where that
# matters. spy_logseen above is already rehash-safe via `array set {}`'s merge
# semantics; these three plain array elements needed the same treatment.
if {![info exists spy(log_window)]}   { set spy(log_window)   60 }
spychan:cfg:int log_window 1 60
array set spy_logseen {}
if {![info exists spy(rate_count)]}   { set spy(rate_count)   0 }
if {![info exists spy(rate_reset)]}   { set spy(rate_reset)   0 }
if {![info exists spy(rate_dropped)]} { set spy(rate_dropped) 0 }
proc spychan:logonce {key msg} {
  global spy spy_logseen
  set now [clock seconds]
  set key [string range $key 0 63]
  if {[info exists spy_logseen($key)] &&
      ($now - $spy_logseen($key)) < $spy(log_window)} {
    return
  }
  # Bound the table: distinct keys would otherwise accumulate for the life of
  # the bot. Drop expired records first; if every record is still live, clear
  # the table outright rather than repeat an O(n) scan that frees nothing.
  if {[array size spy_logseen] > 128} {
    foreach k [array names spy_logseen] {
      if {($now - $spy_logseen($k)) >= $spy(log_window)} { unset spy_logseen($k) }
    }
    if {[array size spy_logseen] > 128} { array unset spy_logseen * }
  }
  set spy_logseen($key) $now
  putlog [spychan:clean $msg]
}

# ── Burst guard state + choke point (PING-TIMEOUT FIX) ──────────────────────
# Sliding-window counter. Returns 1 (drop this line) once spy(rate_max) lines
# have already gone out in the current spy(rate_window)-second window; resets and
# returns 0 once the window elapses. When a window that dropped lines rolls over,
# it prints ONE summary line instead of the suppressed flood, so the home channel
# still shows that a burst happened without the bot flooding off its server.
# (rate_count/rate_reset/rate_dropped are initialized above, guarded against a
# .rehash resetting an in-progress window.)
proc spychan:ratelimited {} {
  global spy
  if {$spy(rate_max) <= 0} { return 0 }   ;# guard disabled in config
  set now [clock seconds]
  if {$now >= $spy(rate_reset)} {
    set spy(rate_count) 0
    set spy(rate_reset) [expr {$now + $spy(rate_window)}]
    if {$spy(rate_dropped) > 0} {
      # Must route through the SAME output mode as every other line, not
      # hardcode PRIVMSG-to-channel -- otherwise a bot configured for
      # privnotice/privmsg (precisely because it must never touch a channel)
      # would still leak this one summary line into spy(home). Resolve
      # cmd/target the identical way spychan:say does.
      switch -- $spy(outmode) {
        notice     { set __cmd "NOTICE";  set __target $spy(home) }
        privnotice { set __cmd "NOTICE";  set __target $spy(outnick) }
        privmsg    { set __cmd "PRIVMSG"; set __target $spy(outnick) }
        default    { set __cmd "PRIVMSG"; set __target $spy(home) }
      }
      if {$__target ne "" && [string first " " $__target] < 0} {
        puthelp "$__cmd $__target :-- spychan: suppressed $spy(rate_dropped) line(s) during a burst --"
      }
      set spy(rate_dropped) 0
      # The summary occupies the send queue exactly like any other line, so it
      # must be charged to the budget. Previously it was emitted outside the
      # count, letting each window put out rate_max + 1 lines — a small but
      # real overshoot of the configured ceiling, and it landed precisely during
      # a burst, when the queue was already the thing under pressure.
      incr spy(rate_count)
    }
  }
  if {$spy(rate_count) >= $spy(rate_max)} {
    incr spy(rate_dropped)
    return 1
  }
  incr spy(rate_count)
  return 0
}

# Every line printed to the home channel goes through here, so the burst guard
# applies uniformly whether the line was generated locally or arrived from a leaf
# across the botnet. This is the fan-in point that a storm would otherwise flood.
proc spychan:say {line} {
  global spy
  # Sink-level enforcement: sanitize HERE so every line that reaches the home
  # channel is scrubbed, regardless of which caller produced it. Cleaning
  # per-caller was fragile -- spychan:hello reached this sink with an uncleaned
  # $frombot (a value that crossed the botnet link) and so bypassed the scrub.
  # Doing it at the single choke point guarantees the invariant for all current
  # and future callers; re-cleaning an already-clean line is a harmless no-op.
  set line [spychan:clean $line]
  # Pick the wire command + target for the configured output mode. This is the
  # ONLY place that decides where a relay line actually goes -- everything
  # upstream (spychan:out, spychan:frombot, spychan:hello, the burst-guard
  # summary) just calls spychan:say, so changing spy(outmode) redirects every
  # line the script ever prints, including the "-- suppressed N line(s) --"
  # burst summary, with nothing else to touch.
  switch -- $spy(outmode) {
    notice {
      set cmd "NOTICE"
      set target $spy(home)
    }
    privnotice {
      set cmd "NOTICE"
      set target $spy(outnick)
    }
    privmsg {
      set cmd "PRIVMSG"
      set target $spy(outnick)
    }
    default {
      set cmd "PRIVMSG"
      set target $spy(home)
    }
  }
  # Refuse a target that is not a single token (channel or nick). It goes
  # straight into "$cmd $target :..." -- empty emits "$cmd  :text" with no
  # target at all (measured), and a value with a space would split into two
  # protocol parameters. Throttled so a misconfigured bot logs once a minute
  # rather than once per relayed event.
  if {$target eq "" || [string first " " $target] >= 0} {
    spychan:logonce "badtarget" "spychan: output target for mode '$spy(outmode)' ('$target') is not a single channel/nick -- dropping output."
    return
  }
  if {[spychan:ratelimited]} { return }
  puthelp "$cmd $target :$line"
}

# Send one finished relay line to the home channel: locally if we ARE the home
# bot (or no homebot set), otherwise across the botnet to the home bot.
#
# ORIGIN AUTHENTICATION: a leaf no longer writes its OWN botnick into the
# payload. It used to, and the home bot printed that payload verbatim — so the
# origin field was attacker-supplied data travelling inside the message, and any
# linked bot could emit a line claiming to be any other bot on any other network.
# The botnet core already tells the receiver who actually sent the frame; that
# value ($frombot in spychan:frombot) is the authenticated one, and the home bot
# now stamps it. A leaf therefore sends only "<network>: <event>" and the home
# bot prepends the true sender, producing the same "bot: net: event" output as
# before but with the bot field no longer forgeable.
#
# The network tag is still added at the ORIGIN, before the botnet hop: once the
# line crosses to the home bot, the local network would be the HOME bot's.
# spychan:net:mine auto-detects it from RAW 005 (ISUPPORT), falling back to
# spy(netname) then the global `network`. Prepended BEFORE spychan:clean so the
# length cap still bounds the final line.
#
# The botnet path checks the home bot is actually linked (islinked) and wraps
# putbot in catch: a leaf whose link is down logs the drop instead of erroring,
# which also enforces "the bots must be linked in order to relay."
proc spychan:out {line} {
  global spy botnick
  set net [spychan:net:mine]
  if {[spychan:ishome]} {
    # Local event on the home bot — no botnet hop, so there is no $frombot to
    # stamp and we name ourselves here. Not forgeable: it never left this bot.
    spychan:say "$botnick: $net: $line"
  } elseif {[islinked $spy(homebot)]} {
    set payload [spychan:clean "$net: $line"]
    if {[catch {putbot $spy(homebot) "SPYCHAN $payload"} err]} {
      spychan:logonce "relayfail" "spychan: relay to $spy(homebot) failed: $err"
    }
  } else {
    # Throttled: this fires once per WATCHED EVENT, so a leaf riding out a long
    # home-bot outage during a netsplit would otherwise write one log line per
    # user per channel.
    spychan:logonce "nolink" "spychan: home bot $spy(homebot) not linked — dropping relay lines."
  }
}

# Home bot side: receive a relay line from another bot and print it.
# Guarded three ways: only the home bot prints (a stray line reaching a leaf is
# ignored, never double-printed); if spy(relaybots) is set, the sending bot must
# be on that allowlist; and the payload is cleaned at the spychan:say sink so a
# relay arriving from the botnet gets the same control-char/length scrub as a
# locally generated line.
#
# $frombot is supplied by the botnet core for the link the frame actually
# arrived on, so it is the trustworthy identifier. It is stamped here rather
# than taken from the payload — see the ORIGIN AUTHENTICATION note on
# spychan:out. $rest is NOT pre-cleaned: spychan:say cleans every line it
# emits, and cleaning twice ran the byte-capping walk twice over the largest
# untrusted input in the script for no benefit.
proc spychan:frombot {frombot command rest} {
  global spy
  if {![spychan:ishome]} { return }
  if {$spy(relaybots) ne ""} {
    set ok 0
    foreach b $spy(relaybots) {
      if {[string equal -nocase $frombot $b]} { set ok 1; break }
    }
    if {!$ok} {
      spychan:logonce "relay-$frombot" "spychan: ignored relay from unlisted bot $frombot"
      return
    }
  }
  spychan:say "$frombot: $rest"
}

# ----------------------------------------------------------------------------
# Self-announce — each bot posts its own nick + network to the home channel.
#
# A bot only knows its OWN network, so instead of the home bot interrogating the
# botnet on demand, every bot pushes one line to the home bot: "I am <nick> on
# <network>." The home bot prints it to spy(home). This happens automatically —
# on link and on (re)load — so the home channel gets one line per bot with no
# command typed.
# ----------------------------------------------------------------------------

# This bot's IRC network. Prefer what the server announced in RAW 005
# (ISUPPORT NETWORK=..., Eggdrop 1.9+); then the spy(netname) tag already in the
# config; then the global `network` config var; "unknown" if none is usable.
proc spychan:net:mine {} {
  global spy network
  if {![catch {isupport get NETWORK} n] && $n ne ""} { return $n }
  if {[info exists spy(netname)] && $spy(netname) ne ""} { return $spy(netname) }
  if {[info exists network] && $network ne ""} { return $network }
  return "unknown"
}

# True once we can name the network authoritatively — i.e. the server has sent
# RAW 005 with NETWORK=... The self-announce waits for this so it reports the
# SAME network the join/part lines report, instead of an early fallback label.
# On Eggdrops without isupport (<1.9) we can't wait for it, so treat as ready and
# let spychan:net:mine fall back to spy(netname)/network.
proc spychan:net:ready {} {
  if {[info commands isupport] eq ""} { return 1 }
  return [expr {![catch {isupport get NETWORK} n] && $n ne ""}]
}

# This bot's BOTNET nick: botnet-nick if set, otherwise Eggdrop uses `nick`.
proc spychan:mybotnet {} {
  global nick botnick
  if {[info exists ::botnet-nick] && [set ::botnet-nick] ne ""} { return [set ::botnet-nick] }
  if {[info exists nick] && $nick ne ""} { return $nick }
  return $botnick
}

# True if THIS bot is the home/printer bot (spy(homebot) empty, or set to our own
# botnet nick). Same test the relay uses, kept in one place so both agree.
#
# Compared against the BOTNET nick, which is what spy(homebot) names. It used to
# compare the IRC nick: a leaf whose IRC nick on its own network happened to
# match the home bot's botnet nick (the same nick on every network is common)
# decided it WAS the home bot, printed into a spy(home) channel on its own
# network and never relayed anything.
proc spychan:ishome {} {
  global spy
  return [expr {$spy(homebot) eq "" || [string equal -nocase [spychan:mybotnet] $spy(homebot)]}]
}

# Send THIS bot's own "nick is on network" line to the home channel: printed
# locally if we are the home bot, otherwise pushed across the botnet to the home
# bot (which prints it via spychan:hello). A leaf only pushes when the home bot is
# actually linked; if it isn't, the leaf logs and waits for the LINK bind to fire
# the announce once the link comes up.
# Cancel any pending announce retry and schedule exactly one. Keeping a single
# outstanding timer is what stops repeated LINK events from stacking retry chains.
proc spychan:cancel_announce_timer {} {
  # Eggdrop's utimers output has varied slightly across releases; only inspect
  # entries that have the expected command/id fields. Never let a malformed
  # timer entry abort a rehash or announce callback.
  foreach t [utimers] {
    if {[llength $t] < 3} { continue }
    if {[string equal [lindex $t 1] "spychan:announce"]} {
      catch {killutimer [lindex $t 2]}
    }
  }
}

proc spychan:announce:retry {} {
  spychan:cancel_announce_timer
  catch {utimer 10 spychan:announce}
}

proc spychan:announce {} {
  global spy botnick
  # Hold off until we can name the network for real; otherwise the hello would
  # show an early fallback label while later join/part lines show the server's
  # actual NETWORK, and the two disagree. Retry shortly.
  #
  # The retry is scheduled through spychan:announce:retry, which cancels any
  # pending retry first. spychan:link calls spychan:announce directly, so link
  # flapping while the bot is still disconnected from IRC used to start a fresh,
  # independent retry chain on every flap, each one re-arming every 10 s forever.
  # Collapsing to a single outstanding timer keeps that bounded.
  if {![spychan:net:ready]} {
    spychan:announce:retry
    return
  }
  # Fire once per link session. A genuine (re)link resets this in spychan:link,
  # so we re-announce on relink but not twice on a single load+link startup.
  if {[info exists spy(hello_sent)] && $spy(hello_sent)} { return }
  if {[spychan:ishome]} {
    # Route through spychan:say so this line is scrubbed and rate-limited like
    # every other channel line, instead of a raw puthelp that skipped both.
    spychan:say "$botnick is on [spychan:net:mine]"
    set spy(hello_sent) 1
  } elseif {[islinked $spy(homebot)]} {
    if {[catch {putbot $spy(homebot) "SPYHELLO [spychan:clean [spychan:net:mine]]"} err]} {
      putlog "spychan: announce to $spy(homebot) failed: $err"
    } else {
      set spy(hello_sent) 1
    }
  } else {
    putlog "spychan: home bot $spy(homebot) not linked yet — will announce on link."
  }
}

# LINK bind: a bot just linked into the botnet. On a LEAF, when the bot that
# linked is our home bot (it just became reachable), announce ourselves to it.
# The home bot ignores this — it prints its own line on load, not per link.
# via has a default so this is safe across Eggdrop versions that pass one arg.
proc spychan:link {botname {via ""}} {
  global spy
  if {[spychan:ishome]} { return }
  if {[string equal -nocase $botname $spy(homebot)]} {
    set spy(hello_sent) 0
    spychan:announce
  }
}

# Home bot side: a leaf announced itself. Print "<leaf> is on <network>" to the
# home channel. Guarded like the relay: only the home bot prints; if
# spy(relaybots) is set the sender must be on that allowlist; and the network
# name crossed the botnet, so it is cleaned and length-capped before it reaches
# the channel.
proc spychan:hello {frombot command rest} {
  global spy
  if {![spychan:ishome]} { return }
  if {$spy(relaybots) ne ""} {
    set ok 0
    foreach b $spy(relaybots) {
      if {[string equal -nocase $frombot $b]} { set ok 1; break }
    }
    if {!$ok} {
      spychan:logonce "hello-$frombot" "spychan: ignored announce from unlisted bot $frombot"
      return
    }
  }
  # Clean BOTH fields: $frombot crossed the botnet link and is no more trusted
  # than $rest. (spychan:say also cleans now, but scrubbing here keeps this site
  # self-evidently safe and independent of the sink's behaviour.)
  set from [spychan:clean $frombot]
  set net  [spychan:clean [string trim $rest]]
  if {$net eq ""} { set net "unknown" }
  spychan:say "$from is on [string range $net 0 79]"
}

proc spychan:chat {nickname hostname handle channel arguments} {
  if {[spychan:watch $channel]} {
    spychan:out "\[$channel\] <$nickname> $arguments"
  }
}

proc spychan:action {nickname hostname handle channel keyword arguments} {
  if {[spychan:watch $channel]} {
    spychan:out "\[$channel\] * $nickname $arguments"
  }
}

proc spychan:join {nickname hostname handle channel} {
  if {[spychan:watch $channel]} {
    spychan:out "$nickname: join: $channel"
  }
}

proc spychan:part {nickname hostname handle channel {reason ""}} {
  if {[spychan:watch $channel]} {
    if {$reason eq ""} {
      spychan:out "$nickname: part: $channel"
    } else {
      # Parenthesised, not colon-appended. The reason is free text the user
      # controls, and the output format is colon-delimited, so a reason like
      # "x: Libera: someone: join: #secret" used to render as what looked like
      # a second, separate relay line. Brackets keep it unambiguously one field.
      spychan:out "$nickname: part: $channel ($reason)"
    }
  }
}

# Disabled by default (see the bind block). Output format matches the enabled
# events -- "<nick>: <event>: <chan>" -- rather than the old "[chan] * ..."
# shape, which would have made re-enabling this produce lines in a different
# format from every other relayed event.
proc spychan:kick {nickname hostname handle channel target {reason ""}} {
  if {[spychan:watch $channel]} {
    if {$reason eq ""} {
      spychan:out "$nickname: kick: $channel ($target)"
    } else {
      spychan:out "$nickname: kick: $channel ($target: $reason)"
    }
  }
}

proc spychan:sign {nickname hostname handle channel {reason ""}} {
  if {[spychan:watch $channel]} {
    if {$reason eq ""} {
      spychan:out "$nickname: quit: $channel"
    } else {
      spychan:out "$nickname: quit: $channel ($reason)"
    }
  }
}

proc spychan:split {nickname hostname handle channel} {
  if {[spychan:watch $channel]} {
    spychan:out "$nickname: split: $channel"
  }
}

proc spychan:mode {from key arguments} {
  global spy
  set channel    [string trim [lindex [split $arguments] 0]]
  set modechange [string trim [lindex [split $arguments] 1]]
  set victims    [string trim [join [lrange [split $arguments] 2 end]]]
  set nickname   [string trim [lindex [split $from "!"] 0]]
  if {[spychan:watch $channel]} {
    set change [string trim "$modechange $victims"]
    spychan:out "\[$channel\] * $nickname sets mode: $change"
  }
  return 0
}

# Announce shortly after load: gives the server a moment to send RAW 005 so the
# network is known, and covers a script reload while the botnet is already up
# (no fresh LINK event fires in that case). The home bot prints its own line; a
# leaf already linked to the home bot pushes to it now, otherwise the LINK bind
# handles it when the link comes up.
#
# Swept the same way spychan:announce:retry sweeps its own re-arms: without
# this, every .rehash schedules another independent one-shot timer on top of
# any still pending from an earlier load.
spychan:cancel_announce_timer
# Clear the once-per-session latch on every load.
#
# spy(hello_sent) is only ever written inside procs, so nothing in the CONFIG
# block above reset it -- it survived a .rehash intact. The timer below then
# fired, spychan:announce saw hello_sent already 1, and returned without saying
# anything, so the "covers a script reload while the botnet is already up" case
# this timer exists for never actually happened after the first load. (Measured:
# first load announces; every reload after it is silent.) Resetting here is
# what makes a reload re-announce; it cannot double-announce on a fresh
# load+link, because whichever of spychan:link or this timer runs first sets the
# latch and the other one then returns early.
set spy(hello_sent) 0
utimer 15 spychan:announce

putlog "Spychan.tcl version $spy(version) by $spy(author) Loaded! (!spyhelp for commands)"
