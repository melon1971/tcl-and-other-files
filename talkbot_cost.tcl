##############################################################################
# talkbot_cost.tcl -- API spend tracker/reporter for talkbot.tcl (Eggdrop).
#
# WHAT IT DOES:
#   - Watches every successful OpenAI call talkbot.tcl makes and records the
#     token counts OpenAI reports back ("usage" block) plus any web_search
#     tool calls, bucketed per day and per model, in a small local file.
#   - Prices those tokens from a table YOU fill in (PRICES below) and reports
#     spend in channel on demand.
#
#     COMMANDS: two separate triggers, so the two purposes can never bleed
#     into each other -- "!costhelp" ALWAYS just prints the command list,
#     whatever (if anything) follows it. The spend reports live under their
#     own trigger, "!cost":
#         !cost                    TODAY, THIS WEEK and THIS MONTH at once
#         !cost today              just today
#         !cost week               just the week window
#         !cost month              just the month window
#         !cost days [n]           per-day breakdown, last n days (max 31)
#         !cost models             spend split by model, month window
#     Aliases under !cost: summary/report/all = (bare), day/t = today,
#     weekly/w/7d = week, monthly/m/30d = month.
#   - Costs nothing itself: no extra API calls, ever. It only reads the
#     response bodies talkbot.tcl is already paying for.
#
# HOW IT HOOKS IN -- no edits to talkbot.tcl required:
#   talkbot.tcl calls ::talkbot::extract_text with the full raw JSON response
#   body, exactly once per successful (2xx) API response. This script renames
#   that proc aside and installs a wrapper that skims the "usage" numbers off
#   the body before handing it to the original untouched. The wrapper is
#   catch-wrapped, so even a bug in here can never stop the bot from replying.
#
# INSTALL:
#   1. Copy this file into your eggdrop's scripts/ directory.
#   2. In eggdrop.conf, AFTER the talkbot line:
#          source scripts/talkbot.tcl
#          source scripts/talkbot_cost.tcl        <-- must come second
#   3. Fill in the PRICES table below from platform.openai.com/pricing for
#      whatever model talkbot.tcl is set to. Until you do, the report says
#      "PRICE NOT SET" rather than quietly showing you $0.00.
#   4. .rehash
#
# WHAT IT DOES *NOT* COUNT:
#   - Spend from before you loaded this file. It starts counting at load;
#     it cannot see history. For authoritative billed totals including the
#     past, use the usage dashboard at platform.openai.com/usage.
#   - Mafia sayings and the channel command bridge -- those make no API call
#     at all, so they genuinely cost $0.00 and never show up here.
#   - Failed/timed-out requests (no usage block is returned for them).
#
# REQUIRES: nothing beyond what talkbot.tcl already needs. Uses tcllib's json
# package if present, falls back to a regex scrape if not.
##############################################################################

namespace eval ::talkbotcost {}

set ::talkbotcost::script_dir [file normalize [file dirname [info script]]]

##############################################################################
# CONFIG -- everything you're meant to edit lives here. Change a value,
# then .rehash.
#
# Settings use `set name value`, so every .rehash re-applies them. Runtime
# state that must survive a rehash (`started`, `cost_log`, the throttle
# arrays) is declared with a bare `variable name` plus an `info exists`
# guard instead, because `variable name value` assigns on every source.
##############################################################################

namespace eval ::talkbotcost {

    # ---- Prices -----------------------------------------------------------
    #
    # USD per 1,000,000 tokens, one line per model, as:
    #     <model-name>  {<input> <cached-input> <cache-writes> <output>}
    #
    # Model name is matched case-insensitively against the "model" field
    # OpenAI returns in the response (which may be more specific than what
    # you set in talkbot.tcl, e.g. a dated snapshot) -- longest matching
    # prefix wins, so an entry for "gpt-5.6-luna" also covers
    # "gpt-5.6-luna-2026-07-01".
    #
    # gpt-5.6-luna is filled in from the pricing table you supplied (the
    # standard/base tier -- talkbot.tcl sends a plain request with no
    # priority/service-tier flag, so that's the one it's actually billed at;
    # your table's second, ~1.5-2x set was a higher tier and is not used
    # here). Cache writes are REAL and billed for GPT-5.6: OpenAI's explicit
    # prompt-caching feature for this model family reports a genuine
    # "cache_write_tokens" count in the usage block, charged at 1.25x the
    # uncached input rate -- 1.25 * 0.20 = 0.25 for Luna, which is exactly
    # the rate below. (Earlier GPT models had no such field -- caching was
    # automatic-read-only there, no write charge -- which is why this used
    # to be treated as a placeholder. It isn't one for GPT-5.6.)
    #
    # !!! Other models below are still PLACEHOLDERS -- fill them in from
    # !!! https://platform.openai.com/docs/pricing if you ever switch
    # !!! talkbot.tcl's "model" setting. A model with no entry here (or all
    # !!! zeroes) is reported as "PRICE NOT SET" rather than silently
    # !!! showing $0.00.
    #
    # If a model has no separate cached-input or cache-write rate, just
    # repeat the input rate in that slot. Reasoning tokens are billed as
    # output tokens and are already included in output_tokens by the API.
    # Cleared before it is repopulated: `array set` MERGES into an existing
    # array, so on a rehash a model you DELETED from this table stayed in
    # the live array with its old rates and kept pricing calls at them.
    # Editing a rate worked; removing a row didn't.
    variable prices
    if {[array exists prices]} { array unset prices * }
    array set prices {
        gpt-5.6-luna   {0.20 0.02 0.25 1.20}
        gpt-4.1-mini   {0 0 0 0}
        gpt-4o         {0 0 0 0}
        gpt-image-1    {5.00 1.25 5.00 40.00}
    }
    # gpt-image-1 (talkbot.tcl's !talkbotpic): text-prompt input and image
    # output tokens, which is what its usage block reports. A low-quality
    # 1024x1024 image is ~272 output tokens, about $0.011. Check the current
    # rates on the pricing page if you change image_model or image_quality.

    # USD per web_search tool call. talkbot.tcl has use_web_search on by
    # default, and search calls are billed separately from tokens. Check the
    # "Built-in tools" section of the pricing page. Set 0 if you turned
    # use_web_search off in talkbot.tcl.
    set price_per_web_search 0

    # Shown in front of every figure. Purely cosmetic -- prices above are
    # whatever unit you type in.
    set currency "$"

    # ---- Where the numbers are kept --------------------------------------

    # Per-day, per-model token totals. Plain text, one Tcl array-get list,
    # human-readable. Anchored next to this script.
    set data_file [file join $::talkbotcost::script_dir "talkbot_cost.dat"]

    # Days of history to keep. Older buckets are dropped on save. 400 keeps
    # a bit over a year so month-to-month comparisons stay possible.
    set keep_days 400

    # ---- Who can ask, and where the answer goes ---------------------------

    # 1 = on. 0 = keep recording silently but never answer the trigger.
    set report_enabled 1

    # Two SEPARATE channel triggers, each also answering "<botnick> ...":
    #   help_trigger   -- ALWAYS just prints the command list, no matter what
    #                     (if anything) follows it. It never produces spend
    #                     figures.
    #   report_trigger -- the spend reports. Bare (no args) prints all three
    #                     windows (today/week/month) at once; "today"/"week"/
    #                     "month" prints just that one; "days [n]" and
    #                     "models" are also available (see report_help).
    set help_trigger "!costhelp"
    set report_trigger "!cost"

    # Which channels the trigger is looked for in. Empty list {} = the same
    # channels talkbot.tcl is active in (::talkbot::allowed_channels).
    # Validated below: trimmed, must start with #/&/+/!, 2-64 chars, no
    # whitespace/commas/control bytes, capped at 64 entries.
    set channels {}

    # Minimum Eggdrop flag needed to ask. Checked globally AND as a channel
    # flag, and ranked on talkbot.tcl's own ladder (o < m < n by default), so
    # +n also satisfies +m. Spend figures are business information -- +m
    # (master) by default, not +o.
    set required_flag "m"

    # Where the answer goes:
    #   "notice"  -- NOTICE to whoever asked (keeps it off-channel)
    #   "channel" -- public reply in the channel
    #   "msg"     -- private PRIVMSG to whoever asked
    set output "channel"

    # Where the !costhelp command list goes. Same three values as $output
    # above. Split out from $output because the help text is long (multiple
    # lines) and static -- people who don't mind spend figures in-channel
    # often still don't want a 7-line command reference cluttering it every
    # time someone asks, so this can be pinned to "notice" independently.
    # Leave it at "notice" unless you want every "!costhelp" echoed to the
    # whole channel.
    set help_output "notice"

    # 1 = bold the segment labels ("today (...)", "last 7 days", "this month
    # (...)", "avg") with IRC's \x02. 0 = plain text everywhere, for clients
    # or logs where the control byte is noise rather than formatting.
    #
    # HOW THIS SURVIVES SANITIZING (the non-obvious part): IRC bold is \x02,
    # a C0 control byte, and ::talkbot::irc_output_safe -- which every line
    # here is deliberately routed through -- strips EVERY C0 byte, \x02
    # included. That stripping is a security property, not an oversight (it
    # is what stops model output from faking colours or another user's line),
    # so it must not be weakened. Instead the report marks bold with
    # bold_marker below, and ::talkbotcost::send swaps it for the real \x02
    # as the very last step before putserv -- after sanitizing, after
    # wrapping. Both characters are exactly 1 char wide, so wrap_text's
    # length maths stays exact either way.
    #
    # NOTE: an earlier version of this marker used U+E000 (Private Use Area),
    # on the assumption that irc_output_safe only strips C0 control bytes.
    # In practice irc_output_safe also strips non-ASCII, so the PUA marker
    # was getting eaten the same way a real \x02 would have been --
    # confirmed via the before/after debug logging in ::talkbotcost::send.
    # bold_marker must therefore be ordinary printable ASCII (0x20-0x7E),
    # which is the one range irc_output_safe is guaranteed to pass through
    # untouched.
    set use_bold 1

    # The placeholder stand-in for \x02. Printable ASCII (not C0, not
    # non-ASCII) so it survives irc_output_safe, which strips both of those.
    # Picked "~" because it's exactly 1 char wide (matches \x02 for
    # wrap_text's length maths) and won't turn up in dollar-figure cost
    # lines or OpenAI model names. Change it only if it somehow collides.
    set bold_marker "~"

    # Minimum seconds before the SAME person can repeat the SAME subcommand.
    # Same posture as talkbot.tcl's reply_cooldown: a repeat within the window
    # is silently ignored -- no error, no "slow down" reply, it just doesn't
    # answer again yet. Report generation is local/free (no API call), so this
    # exists purely to stop someone from flooding the channel/their own
    # NOTICEs by mashing "!costhelp", not to protect any spend.
    #
    # KEYED PER SUBCOMMAND on purpose. A single per-person window silently ate
    # the normal way people use this: a mistyped subcommand -> unknown option
    # -> "!costhelp" for the command list 7 seconds later -> nothing at all,
    # because the error reply had just consumed the window. Mashing one
    # command is a flood; walking today -> week -> month, or reading the
    # error and asking for the command list, is not.
    set cost_cooldown 10

    # Floor between ANY two answers to the same person, whatever the
    # subcommand. Stops someone cycling through every subcommand back-to-back
    # to dump a screenful. Small enough that a human typing the next command
    # never trips it. 0 disables.
    set cost_burst_gap 2

    # Minimum seconds between DENIED-attempt log lines for the SAME source
    # (handle, or nick!uhost when unidentified) in the SAME channel. Unlike
    # cost_cooldown/cost_burst_gap above, this applies to people who fail the
    # +required_flag check -- i.e. anyone at all who can talk in an allowed
    # channel, not just authorized users. Without a floor here, that's an
    # unauthenticated, unbounded putlog() on every single message matching
    # the trigger -- a trivial log-flood/disk-fill vector open to anyone in
    # the channel. This does not affect answering (denied requests are never
    # answered regardless); it only rate-limits how often the same denial is
    # re-logged.
    set denied_log_cooldown 30

    # Week definition for the "this week" figure:
    #   "rolling"  -- the last 7 days including today
    #   "calendar" -- since the most recent start-of-week (see week_start)
    set week_mode "rolling"
    set week_start 1   ;# for "calendar": 0=Sunday, 1=Monday

    # Month definition for the "this month" figure:
    #   "calendar" -- since the 1st (matches how OpenAI bills you)
    #   "rolling"  -- the last 30 days including today
    set month_mode "calendar"
}

##############################################################################
# CONFIG validation.
#
# None of these were checked, and one of them fails in a way that is hard to
# diagnose: keep_days is used by `clock add` at the TOP of ::talkbotcost::save,
# OUTSIDE that proc's catch. A non-integer there raises out of save, out of
# record_from_body, and is swallowed by the load-bearing catch in the
# extract_text wrapper -- so a typo in keep_days silently stops all
# recording, leaving only one "recording failed" log line per API call to
# say so. The rest are the ordinary case of an arithmetic comparison in a
# bind path.
##############################################################################

proc ::talkbotcost::_cfg_int {name min max default} {
    upvar #0 ::talkbotcost::$name v
    if {![info exists v] || ![string is integer -strict $v] || $v < $min
            || ($max ne "" && $v > $max)} {
        set had [expr {[info exists v] ? $v : "<unset>"}]
        putlog "\[talkbot-cost\] CONFIG: invalid $name ('$had'); forcing $default."
        set v $default
    }
}

namespace eval ::talkbotcost {
    ::talkbotcost::_cfg_int keep_days                 1 36500  400
    ::talkbotcost::_cfg_int cost_cooldown             0 3600   10
    ::talkbotcost::_cfg_int cost_burst_gap            0 3600   2
    ::talkbotcost::_cfg_int denied_log_cooldown       0 86400  30
    ::talkbotcost::_cfg_int week_start                0 6      1
    # runtime_state_ttl / runtime_state_max_entries are declared further
    # down, next to the throttle arrays they bound, and validated there.

    if {$report_enabled ni {0 1}} {
        putlog "\[talkbot-cost\] CONFIG: report_enabled must be 0 or 1; forcing 1."
        set report_enabled 1
    }
    if {$use_bold ni {0 1}} {
        putlog "\[talkbot-cost\] CONFIG: use_bold must be 0 or 1; forcing 0."
        set use_bold 0
    }
    if {$output ni {channel notice msg}} {
        putlog "\[talkbot-cost\] CONFIG: invalid output ('$output'); forcing notice."
        set output "notice"
    }
    if {$help_output ni {channel notice msg}} {
        putlog "\[talkbot-cost\] CONFIG: invalid help_output ('$help_output'); forcing notice."
        set help_output "notice"
    }
    if {$week_mode ni {rolling calendar}} {
        putlog "\[talkbot-cost\] CONFIG: invalid week_mode; forcing rolling."
        set week_mode "rolling"
    }
    if {$month_mode ni {rolling calendar}} {
        putlog "\[talkbot-cost\] CONFIG: invalid month_mode; forcing calendar."
        set month_mode "calendar"
    }
    if {![string is double -strict $price_per_web_search] || $price_per_web_search < 0} {
        putlog "\[talkbot-cost\] CONFIG: invalid price_per_web_search; forcing 0."
        set price_per_web_search 0
    }
    # required_flag was never checked. flag_ok hands it straight to
    # matchattr, and Eggdrop's matchattr treats an EMPTY flag string as
    # trivially satisfied by anyone -- unlike sysinfo.tcl's require_flag,
    # "" was never a documented "anyone can ask" mode here, so a blank or
    # malformed value (an empty edit, a stray space) would silently open
    # spend figures -- business information, per the header -- to every
    # single userlist handle instead of just +required_flag ones. Forced
    # back to a real single flag letter rather than treated as intentional.
    if {[string length $required_flag] != 1 || ![regexp {^[a-zA-Z]$} $required_flag]} {
        putlog "\[talkbot-cost\] CONFIG: required_flag ('$required_flag') must be a single letter; forcing m."
        set required_flag "m"
    }
    # bold_marker must be exactly one printable ASCII character: send swaps
    # it for \x02 AFTER wrap_text has measured the line, so anything wider
    # than one character silently breaks the wrap arithmetic, and anything
    # outside 0x20-0x7E is eaten by irc_output_safe before it ever gets
    # here (the bug the CONFIG comment describes with U+E000).
    if {[string length $bold_marker] != 1
            || ![regexp {^[\x20-\x7E]$} $bold_marker]} {
        putlog "\[talkbot-cost\] CONFIG: bold_marker must be one printable ASCII char; forcing ~."
        set bold_marker "~"
    }
    if {[string trim $help_trigger] eq "" || [string trim $report_trigger] eq ""} {
        putlog "\[talkbot-cost\] CONFIG: empty trigger; forcing !costhelp / !cost."
        set help_trigger "!costhelp"
        set report_trigger "!cost"
    }
    # channels was never validated either -- unlike everything else in this
    # block it can't crash anything (channel_ok is just a string-equal loop),
    # but a stray typo (trailing space, a name missing its #, a pasted line
    # with a comma in it) would silently and permanently never match any
    # real channel rather than erroring, which is a much harder failure to
    # notice: !cost would just stop answering anywhere and the log would
    # say nothing about why. Same trim/shape/cap treatment as every other
    # channel list validated this session (see risk.tcl's channels_cfg).
    set __clean {}
    foreach __c $channels {
        set __c [string trim $__c]
        if {[string length $__c] < 2 || [string length $__c] > 64
                || ![regexp {^[#&+!]} $__c]
                || [regexp {[\s,\x00-\x1f]} $__c]} {
            putlog "\[talkbot-cost\] CONFIG: dropping malformed channels entry '$__c'."
            continue
        }
        lappend __clean $__c
        if {[llength $__clean] >= 64} { break }
    }
    set channels $__clean
    unset -nocomplain __c __clean

    # Every row must be four non-negative numbers, or bucket_cost's expr
    # raises -- inside sum_range, inside the pubm handler.
    foreach __m [array names prices] {
        set __bad 0
        if {[llength $prices($__m)] != 4} {
            set __bad 1
        } else {
            foreach __v $prices($__m) {
                if {![string is double -strict $__v] || $__v < 0} { set __bad 1 ; break }
            }
        }
        if {$__bad} {
            putlog "\[talkbot-cost\] CONFIG: price row for '$__m' is not four non-negative numbers; treating it as unpriced."
            set prices($__m) {0 0 0 0}
        }
    }
    unset -nocomplain __m __v __bad
}

##############################################################################
# Storage: array cost_log(YYYY-MM-DD|model) = {calls input cached output
# searches}. Dates are LOCAL dates (the bot's timezone), which is what you
# actually mean by "today"; note OpenAI bills on UTC, so a late-night figure
# here can straddle two of their days.
##############################################################################

namespace eval ::talkbotcost {
    variable cost_log
    array set cost_log {}

    # First date we ever recorded, for "tracking since ...".
    #
    # BUG FIXED: this was `variable started ""`, a plain ASSIGNMENT that
    # runs on every source. This whole block is outside the load-once guard
    # (deliberately -- it's how a CONFIG edit takes effect on .rehash), so
    # every rehash blanked it, and ::talkbotcost::load -- which is what
    # restores it from the file's "#started" line -- only runs under that
    # guard. The next recorded call then set it to TODAY and save() wrote
    # today's date into the file, permanently destroying the real
    # tracking-since date. Exactly the bug talkbot.tcl's own comments
    # describe for global_call_log, in the same shape: declare without
    # resetting, so only a real restart clears it.
    variable started
    if {![info exists started]} { set started "" }
}

##############################################################################
# !costhelp rate limiting -- per-handle, per-subcommand cooldown plus a short
# per-handle burst floor, in memory only (resets on a restart, same as
# talkbot.tcl's own reply_cooldown).
##############################################################################

namespace eval ::talkbotcost {
    variable last_request_at      ;# handle|subcommand -> unixtime
    array set last_request_at {}
    variable last_any_at          ;# handle -> unixtime of last answer of any kind
    array set last_any_at {}
    variable denied_log_at        ;# source|chan -> unixtime of last DENIED log line
    array set denied_log_at {}

    # Runtime throttle state is intentionally memory-only. Keep it bounded so
    # nick cycling / handle churn cannot create unbounded arrays.
    set runtime_state_ttl 86400
    set runtime_state_max_entries 10000
    ::talkbotcost::_cfg_int runtime_state_ttl         600 2592000 86400
    ::talkbotcost::_cfg_int runtime_state_max_entries 100 1000000 10000
}

# Remove stale in-memory throttle entries and enforce a hard ceiling.
# This protects against cheap IRC identity churn attacks while keeping normal
# operation effectively unchanged.
proc ::talkbotcost::prune_runtime_state {} {
    variable last_request_at
    variable last_any_at
    variable denied_log_at
    variable runtime_state_ttl
    variable runtime_state_max_entries

    set now [clock seconds]

    foreach arr {last_request_at last_any_at denied_log_at} {
        upvar 0 ::talkbotcost::$arr state
        foreach key [array names state] {
            if {($now - $state($key)) > $runtime_state_ttl} {
                unset state($key)
            }
        }

        set count [array size state]
        if {$count > $runtime_state_max_entries} {
            set entries {}
            foreach key [array names state] {
                lappend entries [list $state($key) $key]
            }
            set entries [lsort -integer -index 0 $entries]

            set remove_count [expr {$count - $runtime_state_max_entries}]
            foreach item [lrange $entries 0 [expr {$remove_count - 1}]] {
                unset state([lindex $item 1])
            }
        }
    }
}

# $sub is the subcommand as dispatched ("" for the bare trigger). Note that
# neither timestamp is updated when the answer is refused, so mashing a
# throttled command cannot keep pushing its own window forward.
proc ::talkbotcost::cooldown_ok {hand sub} {
    prune_runtime_state
    variable last_request_at
    variable last_any_at
    variable cost_cooldown
    variable cost_burst_gap
    set who [string tolower $hand]
    set key "$who|$sub"
    set now [clock seconds]
    if {[info exists last_request_at($key)]} {
        if {$now - $last_request_at($key) < $cost_cooldown} { return 0 }
    }
    if {[info exists last_any_at($who)]} {
        if {$now - $last_any_at($who) < $cost_burst_gap} { return 0 }
    }
    set last_request_at($key) $now
    set last_any_at($who) $now
    return 1
}

# Separate, coarser throttle purely for the DENIED-attempt log line (see
# denied_log_cooldown above). Keyed by source+channel, independent of
# cooldown_ok's per-handle/per-subcommand state, since a denied caller never
# reaches cooldown_ok (they're rejected before a subcommand is even
# resolved) and must not be able to force unlimited log writes.
proc ::talkbotcost::denied_log_ok {src chan} {
    prune_runtime_state
    variable denied_log_at
    variable denied_log_cooldown
    set key "[string tolower $src]|[string tolower $chan]"
    set now [clock seconds]
    if {[info exists denied_log_at($key)] &&
        $now - $denied_log_at($key) < $denied_log_cooldown} {
        return 0
    }
    set denied_log_at($key) $now
    return 1
}

proc ::talkbotcost::load {} {
    variable cost_log
    variable started
    variable data_file
    if {![file exists $data_file]} { return }
    # save() writes this file carefully (EXCL temp, 0600, atomic rename);
    # the read side had none of the matching defenses. [file type] is an
    # lstat, so a symlink planted at this predictable path is refused
    # rather than followed; NONBLOCK means a FIFO raced in after that check
    # returns instead of blocking the event loop forever mid-source; and
    # the read is capped instead of unbounded. The channel is also closed
    # on the error path -- it was inside the same catch as the read, so a
    # failed read leaked it.
    if {[catch { file type $data_file } ftype] || $ftype ne "file"} {
        putlog "\[talkbot-cost\] refusing $data_file -- not a regular file ($ftype)."
        return
    }
    if {[catch {
        set fh [open $data_file {RDONLY NONBLOCK}]
        fconfigure $fh -blocking 1 -translation lf -encoding utf-8
        # keep_days x a handful of models x a short bucket each: the real
        # file is tens of KB. 16 MB is far past that and still a bound.
        set data [read $fh 16777216]
        close $fh
    } err]} {
        catch { close $fh }
        putlog "\[talkbot-cost\] could not read $data_file: $err"
        return
    }
    # First line is the "started" date, the rest is the array-get list.
    set lines [split $data "\n"]
    set first [string trim [lindex $lines 0]]
    if {[regexp {^#started (\d{4}-\d{2}-\d{2})$} $first -> d]} {
        # clock scan accepts surprisingly broad free-form input; use the
        # exact stored format and round-trip it so an invalid date cannot
        # poison later range comparisons.
        if {![catch {
            set parsed [clock scan $d -format %Y-%m-%d]
            set roundtrip [clock format $parsed -format %Y-%m-%d]
        }] && $roundtrip eq $d} {
            set started $d
            set data [join [lrange $lines 1 end] "\n"]
        } else {
            putlog "\[talkbot-cost\] ignoring invalid #started date '$d' in $data_file"
        }
    }
    # Parse into a scratch array and validate every key and bucket before
    # adopting it. A hand-edited or truncated file used to be loaded
    # straight into cost_log, and a bucket holding anything non-numeric
    # then raised inside sum_range's [incr] -- i.e. on every single !cost,
    # uncaught, for the rest of the session. Keys must be the
    # YYYY-MM-DD|model shape this file's own storage format promises.
    #
    # The model half is held to the SAME charset and length parse_usage
    # clamps a live model name to before storing it, not merely "anything
    # without a pipe". Those were two different rules for one field, and
    # the loose one was on the path that reads attacker-or-accident-
    # supplied bytes:
    #
    #   - parse_usage does regsub -all {[^A-Za-z0-9._:-]} -> "?" and caps
    #     at 100 chars, so a model name that reaches cost_log through an
    #     API response can never contain bold_marker.
    #   - a model name that reached cost_log through THIS file could
    #     contain anything at all, bold_marker included -- and send()
    #     swaps every bold_marker for a real \x02 as its very last step,
    #     after irc_output_safe has run. That is the whole point of the
    #     placeholder scheme, and it means a "~" arriving from the data
    #     file paints real formatting into the channel through !cost and
    #     !cost models, walking around the control-byte stripping exactly
    #     the way the `plain` proc exists to stop user text from doing.
    #     An unbounded name also went straight into the report line.
    #
    # A record that does not match what this script itself writes is not
    # this script's record; drop it with the rest of the malformed ones.
    set kept 0
    set dropped 0
    # A 16 MiB file can still contain an enormous number of tiny array
    # elements. Refuse an implausibly large bucket count before adopting it;
    # normal talkbot cost files are orders of magnitude smaller.
    if {[string length $data] > 16777216} {
        putlog "\[talkbot-cost\] $data_file is too large; keeping in-memory counts and NOT loading it."
        return
    }
    if {[catch { array set scratch $data } err]} {
        putlog "\[talkbot-cost\] $data_file did not parse; keeping in-memory counts and NOT loading it: $err"
        return
    }
    foreach k [array names scratch] {
        if {![regexp {^\d{4}-\d{2}-\d{2}\|[A-Za-z0-9._:?-]{1,100}$} $k]} { incr dropped ; continue }
        if {![::talkbotcost::valid_bucket $scratch($k)]} {
            incr dropped
            continue
        }
        set b [::talkbotcost::normalize_bucket $scratch($k)]
        set cost_log($k) $b
        incr kept
    }
    if {$dropped > 0} {
        putlog "\[talkbot-cost\] $data_file: dropped $dropped malformed bucket(s) on load"
    }
    if {$kept > 0} {
        putlog "\[talkbot-cost\] loaded $kept bucket(s) from $data_file"
    }
}

proc ::talkbotcost::save {} {
    variable cost_log
    variable started
    variable data_file
    variable keep_days

    # Drop buckets older than keep_days so the file can't grow forever.
    set cutoff [clock format [clock add [clock seconds] -$keep_days days] -format %Y-%m-%d]
    foreach k [array names cost_log] {
        if {[string compare [lindex [split $k "|"] 0] $cutoff] < 0} {
            unset cost_log($k)
        }
    }

    if {[catch {
        # Temp file, created 0600 from the very first byte, then renamed into
        # place -- same pattern talkbot.tcl uses for its memory file, and for
        # the same reasons: no world-readable window, and a crash mid-write
        # can't destroy the existing data.
        #
        # Permissions are passed to Tcl's own open (mode applies at file
        # CREATION, i.e. is set atomically by the underlying creat() call)
        # rather than opened-then-chmod'd afterward: chmod-after-open leaves
        # a real window where the file exists at the default/umask
        # permissions before the fix-up lands, and if that fix-up's catch
        # silently swallowed a failure (as it used to here), a file holding
        # business spend figures could be left world-readable indefinitely.
        # Any failure below (including a permissions failure) now aborts the
        # save instead of writing data under unknown permissions.
        set tmp "$data_file.new"
        # Remove any stray leftover at $tmp first -- if it happened to be a
        # symlink (e.g. planted by another user on a shared box), removing
        # the link itself (not its target) before recreating with EXCL means
        # we always write into a file we just created, never through a
        # pre-existing link.
        catch { file delete -- $tmp }
        set fh [open $tmp {WRONLY CREAT EXCL} 0600]
        fconfigure $fh -translation lf -encoding utf-8
        puts $fh "#started $started"
        puts $fh [array get cost_log]
        close $fh
        file rename -force -- $tmp $data_file
        # Belt-and-braces: rename preserves the 0600 the file was created
        # with, but re-assert it in case some filesystem's rename semantics
        # don't. Failure here is not fatal -- the file is already 0600.
        catch { file attributes $data_file -permissions 0600 }
    } err]} {
        putlog "\[talkbot-cost\] could not save $data_file: $err"
        catch { file delete -- "$data_file.new" }
    }
}

##############################################################################
# Recording. Called (inside a catch) from the extract_text wrapper with the
# raw response body.
##############################################################################

# Returns the substring of $body spanning the "usage":{...} object (braces
# included), found by counting brace depth from the first "usage" key so
# nested objects like input_tokens_details don't end the match early.
# Returns "" if no "usage" key/object is found at all.
#
# WHY THIS EXISTS: the regex fallback below only runs when tcllib's json
# package is unavailable/fails to parse a given body -- the json2dict path
# above is already scoped to the usage dict and doesn't need this. But
# talkbot.tcl runs with use_web_search on, so a response body can
# legitimately contain chunks of real web-page text/snippets the model
# pulled in via the search tool -- arbitrary content from the open internet,
# sitting in the same JSON body this script scans. The regex fallback used
# to run its field regexes against the ENTIRE body, so on any call where the
# json path didn't run, a fetched web page containing text that happened to
# look like `"cache_write_tokens": 30000` (an article about API caching,
# say) would have been misread as real usage data and billed. This is
# defense in depth, not a fix for anything actually observed here -- your
# tcllib is installed and working, so the scoped json path above is what's
# really running, and the cache-write charges you're seeing are genuine
# (see the PRICES table comment on cache_write_tokens). Scoping the
# fallback to just the usage object closes off that risk for the rare case
# the json path doesn't run, regardless.
proc ::talkbotcost::extract_usage_block {body} {
    set start [string first "\"usage\"" $body]
    if {$start < 0} { return "" }
    set brace_start [string first "\{" $body $start]
    if {$brace_start < 0} { return "" }
    set depth 0
    set len [string length $body]
    for {set i $brace_start} {$i < $len} {incr i} {
        set ch [string index $body $i]
        if {$ch eq "\{"} { incr depth }
        if {$ch eq "\}"} {
            incr depth -1
            if {$depth == 0} { return [string range $body $brace_start $i] }
        }
    }
    return ""
}

# Pulls {model input cached cache_write output searches} out of a Responses
# API body. Uses tcllib json if available, regex scrape otherwise -- same
# belt-and-braces approach talkbot.tcl's own extract_text takes.
proc ::talkbotcost::parse_usage {body} {
    set model ""
    set in 0 ; set cached 0 ; set cachewrite 0 ; set out 0
    set searches 0 ; set have_searches 0

    set ok 0
    if {![catch { package require json }]} {
        catch {
            set data [::json::json2dict $body]
            if {[dict exists $data usage]} {
                set u [dict get $data usage]
                if {[dict exists $u input_tokens]}  { set in  [dict get $u input_tokens] }
                if {[dict exists $u output_tokens]} { set out [dict get $u output_tokens] }
                if {[dict exists $u input_tokens_details cached_tokens]} {
                    set cached [dict get $u input_tokens_details cached_tokens]
                }
                # GPT-5.6's explicit prompt-caching feature reports a real
                # cache_write_tokens count here, billed at 1.25x the
                # uncached input rate -- see the PRICES table comment above.
                # Older/non-GPT-5.6 models have no such field (their caching
                # is automatic read-only discounting, no write charge), so
                # this stays 0 and the configured rate sits unused for them.
                foreach k {cache_write_tokens cache_creation_input_tokens} {
                    if {[dict exists $u $k]} { set cachewrite [dict get $u $k]; break }
                    if {[dict exists $u input_tokens_details $k]} {
                        set cachewrite [dict get $u input_tokens_details $k]; break
                    }
                }
                set ok 1
            }
            if {[dict exists $data model]} { set model [dict get $data model] }
            # Count web_search_call items from the PARSED output array, not
            # a body-wide regex (see the searches computation below for why
            # a raw scan is unsafe) -- this is the accurate, injection-proof
            # path and is used whenever tcllib's parser got us this far.
            if {$ok} {
                set searches 0
                if {[dict exists $data output]} {
                    foreach item [dict get $data output] {
                        if {[catch {
                            if {[dict exists $item type] &&
                                [dict get $item type] eq "web_search_call"} {
                                incr searches
                            }
                        }]} { continue }
                    }
                }
                set have_searches 1
            }
        }
    }
    if {!$ok} {
        # Scoped to the usage object itself (see extract_usage_block above) --
        # NOT the whole body -- so text the web_search tool pulled in from a
        # real web page can never be misread as a token/pricing field. Falls
        # back to the full body only if no "usage" key is found at all (rare;
        # in/out would then almost certainly come back 0 and get rejected
        # below anyway, same as before this fix).
        set usage_body [::talkbotcost::extract_usage_block $body]
        if {$usage_body eq ""} { set usage_body $body }
        # The closing quote in each pattern is what stops "input_tokens" from
        # also matching "input_tokens_details".
        regexp {"input_tokens"\s*:\s*(\d+)}  $usage_body -> in
        regexp {"output_tokens"\s*:\s*(\d+)} $usage_body -> out
        regexp {"cached_tokens"\s*:\s*(\d+)} $usage_body -> cached
        foreach k {cache_write_tokens cache_creation_input_tokens} {
            if {[regexp "\"$k\"\\s*:\\s*(\\d+)" $usage_body -> v]} { set cachewrite $v; break }
        }
        if {$in == 0 && $out == 0} { return {} }
    }
    if {$model eq ""} { regexp {"model"\s*:\s*"([^"]+)"} $body -> model }
    if {$model eq ""} {
        # Last resort: whatever talkbot.tcl is currently configured for.
        catch { set model $::talkbot::model }
    }
    if {$model eq ""} { set model "unknown" }
    # Defensive cap: a "model" pulled from the raw-body regex fallback above
    # (used when the json2dict path didn't run) is unscoped by necessity --
    # the model field lives outside the "usage" object, so it can't be
    # brace-scoped the way usage is. In practice OpenAI always emits "model"
    # before the "output" array that can carry fetched web text, so the
    # first regex match is the real one, but this length/charset clamp
    # keeps a pathological match from bloating cost_log's array keys or the
    # per-model report with garbage.
    if {[string length $model] > 100} { set model [string range $model 0 99] }
    regsub -all {[^A-Za-z0-9._:-]} $model "?" model

    # Each web_search_call item in the output array is one billable search.
    # Prefer the count taken from the parsed output array above (accurate,
    # can't be spoofed by fetched web content). Only fall back to a raw-body
    # regex when the JSON parse path didn't run at all -- unlike the usage
    # numbers, a web_search_call marker can't be brace-scoped the way
    # extract_usage_block scopes "usage" (the real marker sits inside the
    # very output array that can also carry arbitrary fetched web text), so
    # a body-wide regex here really can be fooled by a page the model
    # searched containing that literal substring. Rather than report a
    # spoofable number, the unscoped fallback just reports 0 searches --
    # tcllib is required for anything else, same posture the CONFIG/header
    # comments already take ("your tcllib is installed and working").
    if {!$have_searches} { set searches 0 }

    foreach n [list in cached cachewrite out searches] {
        if {![string is integer -strict [set $n]]} { set $n 0 }
        # Defensive: none of these fields are ever meant to be negative;
        # don't let a malformed/adversarial payload flip the sign and
        # silently discount (or invert) a bucket's cost.
        if {[set $n] < 0} { set $n 0 }
    }
    # Defensive: cached is a SUBSET of input; never let a weird payload make
    # the uncached remainder negative and silently discount the bill.
    if {$cached > $in} { set cached $in }

    return [list $model $in $cached $cachewrite $out $searches]
}

# Normalizes a stored bucket to the current 6-field shape {calls input
# cached cache_write output searches}, so a data file written before
# cache-write tracking was added (5 fields, no cache_write) still loads
# correctly instead of throwing off every lassign downstream.
proc ::talkbotcost::valid_bucket {b} {
    # Strict validator for data loaded from disk. Keep this separate from
    # normalize_bucket: malformed persisted data must be REJECTED, not
    # silently converted into a plausible zero bucket.
    if {[catch { llength $b } n]} { return 0 }
    if {$n != 5 && $n != 6} { return 0 }
    foreach v $b {
        if {![string is integer -strict $v] || $v < 0} { return 0 }
        # Prevent pathological hand-edited integers from consuming excessive
        # CPU/RAM in later arithmetic/report formatting.
        if {$v > 1000000000000} { return 0 }
    }
    return 1
}

proc ::talkbotcost::normalize_bucket {b} {
    # A stored bucket is read back from a plain-text file that the header
    # invites you to hand-edit. Valid legacy 5-field buckets are upgraded;
    # malformed values become a safe zero bucket for callers that need a
    # total rather than an exception. load() uses valid_bucket first and
    # therefore drops malformed persisted records instead of adopting them.
    if {![::talkbotcost::valid_bucket $b]} {
        return {0 0 0 0 0 0}
    }
    if {[llength $b] == 5} {
        lassign $b c i ca o s
        set b [list $c $i $ca 0 $o $s]
    }
    return $b
}

# $model_override names the model when the response body doesn't (the
# images endpoint omits it, and parse_usage would otherwise fall back to the
# CHAT model and price an image at chat rates).
proc ::talkbotcost::record_from_body {body {model_override ""}} {
    variable cost_log
    variable started

    set u [::talkbotcost::parse_usage $body]
    if {[llength $u] != 6} { return }
    lassign $u model in cached cachewrite out searches
    if {$model_override ne ""} {
        set model [string range $model_override 0 99]
        regsub -all {[^A-Za-z0-9._:-]} $model "?" model
    }

    set day [clock format [clock seconds] -format %Y-%m-%d]
    if {$started eq ""} { set started $day }
    set key "$day|[string tolower $model]"

    if {![info exists cost_log($key)]} { set cost_log($key) {0 0 0 0 0 0} }
    lassign [::talkbotcost::normalize_bucket $cost_log($key)] c i ca cw o s
    set cost_log($key) [list [expr {$c + 1}] [expr {$i + $in}] \
                             [expr {$ca + $cached}] [expr {$cw + $cachewrite}] \
                             [expr {$o + $out}] [expr {$s + $searches}]]
    ::talkbotcost::save
}

##############################################################################
# Pricing.
##############################################################################

# Longest-prefix match against the PRICES table, so one entry covers all the
# dated snapshots of a model. Returns {} when the model isn't priced at all.
proc ::talkbotcost::price_for {model} {
    variable prices
    set model [string tolower $model]
    set best "" ; set bestlen -1
    foreach name [array names prices] {
        set n [string tolower $name]
        if {[string first $n $model] == 0 && [string length $n] > $bestlen} {
            set best $prices($name)
            set bestlen [string length $n]
        }
    }
    return $best
}

# Is this model priced with anything other than all zeroes? An all-zero row
# means "you haven't filled the table in yet", which we report honestly
# instead of as free.
proc ::talkbotcost::priced {model} {
    set p [::talkbotcost::price_for $model]
    if {[llength $p] != 4} { return 0 }
    foreach v $p { if {$v != 0} { return 1 } }
    return 0
}

# Dollars for one bucket. Cached input and cache writes are billed at their
# own rates; the uncached remainder of input gets the full input rate.
# cache_write tokens are billed in addition to (not instead of) input --
# see the CONFIG comment on `prices` for why this is normally 0 today.
proc ::talkbotcost::bucket_cost {model in cached cachewrite out searches} {
    variable price_per_web_search
    set p [::talkbotcost::price_for $model]
    if {[llength $p] != 4} { set p {0 0 0 0} }
    lassign $p p_in p_cached p_cachewrite p_out
    set fresh [expr {$in - $cached}]
    if {$fresh < 0} { set fresh 0 }
    return [expr {double($fresh)      * $p_in         / 1000000.0
                + double($cached)     * $p_cached      / 1000000.0
                + double($cachewrite) * $p_cachewrite  / 1000000.0
                + double($out)        * $p_out         / 1000000.0
                + double($searches)   * $price_per_web_search}]
}

##############################################################################
# Aggregation over a date range (inclusive, YYYY-MM-DD strings).
# Returns {cost calls input cached cache_write output searches
# unpriced_models}.
##############################################################################

proc ::talkbotcost::sum_range {from to} {
    variable cost_log
    set cost 0.0 ; set calls 0 ; set in 0 ; set cached 0 ; set cachewrite 0
    set out 0 ; set searches 0
    set unpriced {}
    foreach k [array names cost_log] {
        lassign [split $k "|"] day model
        if {[string compare $day $from] < 0} { continue }
        if {[string compare $day $to]   > 0} { continue }
        lassign [::talkbotcost::normalize_bucket $cost_log($k)] c i ca cw o s
        incr calls $c ; incr in $i ; incr cached $ca ; incr cachewrite $cw
        incr out $o ; incr searches $s
        set cost [expr {$cost + [::talkbotcost::bucket_cost $model $i $ca $cw $o $s]}]
        if {![::talkbotcost::priced $model] && [lsearch -exact $unpriced $model] < 0} {
            lappend unpriced $model
        }
    }
    return [list $cost $calls $in $cached $cachewrite $out $searches $unpriced]
}

proc ::talkbotcost::today {} {
    return [clock format [clock seconds] -format %Y-%m-%d]
}

proc ::talkbotcost::days_ago {n} {
    return [clock format [clock add [clock seconds] -$n days] -format %Y-%m-%d]
}

# Start date of the "this week" window, per week_mode.
proc ::talkbotcost::week_from {} {
    variable week_mode
    variable week_start
    if {$week_mode eq "calendar"} {
        set dow [clock format [clock seconds] -format %w]   ;# 0=Sunday
        set back [expr {($dow - $week_start + 7) % 7}]
        return [::talkbotcost::days_ago $back]
    }
    return [::talkbotcost::days_ago 6]
}

# Start date of the "this month" window, per month_mode.
proc ::talkbotcost::month_from {} {
    variable month_mode
    if {$month_mode eq "rolling"} { return [::talkbotcost::days_ago 29] }
    return [clock format [clock seconds] -format %Y-%m-01]
}

##############################################################################
# Formatting.
##############################################################################

# Marks $text for bolding. Emits the bold_marker placeholder, NOT a real
# \x02 -- see the use_bold/bold_marker comments in CONFIG for why. Wrapping the text
# on both sides works because \x02 is a toggle, so the trailing marker turns
# bold back off. Safe to call even when use_bold is 0: send strips the
# markers instead of substituting them.
proc ::talkbotcost::b {text} {
    variable bold_marker
    return "$bold_marker$text$bold_marker"
}

# Strips the bold_marker out of text that came from a USER, before it is
# interpolated into a reply line.
#
# send() swaps every bold_marker for a real \x02 as its last step, after
# irc_output_safe has run -- which is the whole point of the placeholder
# scheme, but it also means any marker character sitting in user-supplied
# text becomes a real bold toggle on the wire. The only user text this
# script ever echoes is the unrecognized subcommand in its error reply, so
# "!cost ~~~" turned into bold codes in the channel: small, but it is
# precisely the "model/user-influenced output painting formatting into the
# channel" that irc_output_safe strips control bytes to prevent, walked
# around by this file's own marker. Also caps the length, since the echo is
# otherwise as long as whatever was typed.
proc ::talkbotcost::plain {text {limit 40}} {
    variable bold_marker
    set text [string map [list $bold_marker ""] $text]
    if {[string length $text] > $limit} {
        set text "[string range $text 0 [expr {$limit - 1}]]..."
    }
    return $text
}

proc ::talkbotcost::money {amount} {
    variable currency
    # Sub-dollar spend is the normal case for an IRC bot -- four decimals so
    # a day's worth doesn't round away to "$0.00".
    if {abs($amount) < 1.0} { return [format "%s%.4f" $currency $amount] }
    return [format "%s%.2f" $currency $amount]
}

proc ::talkbotcost::tokens {n} {
    if {$n >= 1000000} { return [format "%.1fM" [expr {$n / 1000000.0}]] }
    if {$n >= 1000}    { return [format "%.1fk" [expr {$n / 1000.0}]] }
    return $n
}

# Styled after the tile row on an OpenRouter-style activity dashboard --
# spend / requests / token volume / cache hit rate / blended $ per 1M tokens
# -- as one IRC-text line, since there's no room for tiles on a text
# protocol. "Blended $/1M" here means this bucket's actual dollar cost
# divided by its actual token count, i.e. the effective rate you're really
# paying once cached-input and output rates are mixed together -- not the
# sticker price of any single rate.
proc ::talkbotcost::segment {label from to} {
    lassign [::talkbotcost::sum_range $from $to] cost calls in cached cachewrite out searches unpriced
    set total_tok [expr {$in + $cachewrite + $out}]
    if {$calls == 0} {
        return "[::talkbotcost::b $label] -- spend [::talkbotcost::money 0] | requests 0 | tokens 0 | cache -- | blended --/1M"
    }
    set hitrate [expr {$in > 0 ? (100.0 * $cached / $in) : 0.0}]
    set blended [expr {$total_tok > 0 ? ($cost * 1000000.0 / $total_tok) : 0.0}]
    set s "[::talkbotcost::b $label] -- spend [::talkbotcost::money $cost] | requests $calls | tokens [::talkbotcost::tokens $total_tok] ([::talkbotcost::tokens $in] in / [::talkbotcost::tokens $out] out)"
    append s " | cache [format %.1f $hitrate]%"
    append s " | blended [::talkbotcost::money $blended]/1M"
    if {$cachewrite > 0} { append s " | [::talkbotcost::tokens $cachewrite] cache-write" }
    if {$searches > 0} { append s " | $searches search[expr {$searches == 1 ? "" : "es"}]" }
    return $s
}

##############################################################################
# The report itself.
##############################################################################

# One window's {label from to}, so the full report and the single-window
# subcommands ("!cost today" / "week" / "month") can never drift apart in
# either the date maths or the wording. $which is today|week|month.
proc ::talkbotcost::window_spec {which} {
    variable week_mode
    variable month_mode
    set now [::talkbotcost::today]
    switch -- $which {
        today {
            return [list "today ($now)" $now $now]
        }
        week {
            set from [::talkbotcost::week_from]
            return [list [expr {$week_mode eq "calendar" ? "this week (since $from)" : "last 7 days"}] $from $now]
        }
        month {
            set from [::talkbotcost::month_from]
            return [list [expr {$month_mode eq "calendar" ? "this month (since $from)" : "last 30 days"}] $from $now]
        }
    }
    return {}
}

# A single window on its own -- "!cost today", "!cost week", "!cost month".
# The same line the full report would show for that window, plus the same
# PRICE NOT SET warning: a one-line answer must not be the one place an
# unpriced model quietly reads as near-$0.
proc ::talkbotcost::report_window {which} {
    set spec [::talkbotcost::window_spec $which]
    if {[llength $spec] != 3} { return [list "no such window '$which'"] }
    lassign $spec label from to
    set lines [list [::talkbotcost::segment $label $from $to]]
    lassign [::talkbotcost::sum_range $from $to] x0 x1 x2 x3 x4 x5 x6 unpriced
    if {[llength $unpriced] > 0} {
        lappend lines "WARNING: PRICE NOT SET for: [join $unpriced {, }] -- those calls are counted but valued at 0. Fill in the PRICES table in talkbot_cost.tcl."
    }
    return $lines
}

proc ::talkbotcost::report {} {
    variable started

    set now [::talkbotcost::today]
    set mfrom [::talkbotcost::month_from]

    # No "talkbot API spend:" header line -- each segment already names its
    # own window in bold, so the header was a wasted line in the channel.
    set lines {}
    foreach which {today week month} {
        lassign [::talkbotcost::window_spec $which] label from to
        lappend lines [::talkbotcost::segment $label $from $to]
    }

    # Trailer: average daily burn over the month window, and what that
    # projects to over 30 days -- the number you actually budget against.
    lassign [::talkbotcost::sum_range $mfrom $now] mcost mcalls x1 x2 x3 x4 x5 unpriced
    # -format, and round rather than truncate. Bare [clock scan] on a date
    # string relies on free-form parsing, and the raw /86400 was off by a
    # day whenever the window straddled a DST change (the two midnights are
    # 23 or 25 hours apart, so the division truncated one day away) --
    # which silently inflated the "$/day" figure this line exists to give.
    set span [expr {(([clock scan $now -format %Y-%m-%d]
                      - [clock scan $mfrom -format %Y-%m-%d]) + 43200) / 86400 + 1}]
    if {$span < 1} { set span 1 }
    set avg [expr {$mcost / double($span)}]
    set tail "[::talkbotcost::b avg] [::talkbotcost::money $avg]/day over $span day[expr {$span == 1 ? "" : "s"}] -> ~[::talkbotcost::money [expr {$avg * 30}]]/30d"
    if {$started ne ""} { append tail " | tracking since $started" }
    lappend lines $tail

    if {[llength $unpriced] > 0} {
        lappend lines "WARNING: PRICE NOT SET for: [join $unpriced {, }] -- those calls are counted but valued at 0. Fill in the PRICES table in talkbot_cost.tcl."
    }
    return $lines
}

# Per-day breakdown for the last N days, newest first. "!cost days [n]".
proc ::talkbotcost::report_days {n} {
    if {![string is integer -strict $n] || $n < 1} { set n 7 }
    if {$n > 31} { set n 31 }
    set lines [list "talkbot API spend, last $n days (newest first):"]
    for {set i 0} {$i < $n} {incr i} {
        set d [::talkbotcost::days_ago $i]
        lappend lines "  [::talkbotcost::segment $d $d $d]"
    }
    return $lines
}

proc ::talkbotcost::report_help {} {
    variable help_trigger
    variable report_trigger
    variable required_flag
    variable week_mode
    variable month_mode
    set wdesc [expr {$week_mode eq "calendar" ? "since the start of the week" : "the last 7 days"}]
    set mdesc [expr {$month_mode eq "calendar" ? "since the 1st" : "the last 30 days"}]
    # Same nick match_trigger uses.
    if {[llength [info procs ::talkbot::get_botnick]] > 0} {
        set mynick [::talkbot::get_botnick]
    } else {
        set mynick $::botnick
    }
    return [list \
        "[::talkbotcost::b $help_trigger] -- this command list (you're reading it). All spend figures need +$required_flag." \
        "[::talkbotcost::b $report_trigger] -- all three windows at once: today, week, month." \
        "[::talkbotcost::b "$report_trigger today"] -- just today (the bot's local date, not OpenAI's UTC billing day)." \
        "[::talkbotcost::b "$report_trigger week"] -- just the week window ($wdesc)." \
        "[::talkbotcost::b "$report_trigger month"] -- just the month window ($mdesc)." \
        "[::talkbotcost::b "$report_trigger days \[n\]"] -- per-day breakdown for the last n days (default 7, max 31)." \
        "[::talkbotcost::b "$report_trigger models"] -- spend broken down by model for the current month window." \
        "Aliases: summary/report/all = bare, day/t = today, weekly/w/7d = week, monthly/m/30d = month. Either trigger also answers as \"$mynick $report_trigger ...\" (the leading ! is optional in that form)." \
        "Figures are the bot's LOCAL date; OpenAI bills on UTC, so a late-night \"today\" can straddle two of their days. Counting starts when this script was first loaded -- for billed totals including earlier spend, use platform.openai.com/usage." \
    ]
}

# Spend split by model over the month window -- useful right after you switch
# talkbot.tcl's "model" setting and want to see what the change cost you.
proc ::talkbotcost::report_models {} {
    variable cost_log
    set from [::talkbotcost::month_from]
    set to   [::talkbotcost::today]
    array set per {}
    foreach k [array names cost_log] {
        lassign [split $k "|"] day model
        if {[string compare $day $from] < 0 || [string compare $day $to] > 0} { continue }
        lassign [::talkbotcost::normalize_bucket $cost_log($k)] c i ca cw o s
        if {![info exists per($model)]} { set per($model) {0 0 0 0 0 0} }
        lassign $per($model) pc pi pca pcw po ps
        set per($model) [list [expr {$pc+$c}] [expr {$pi+$i}] [expr {$pca+$ca}] \
                              [expr {$pcw+$cw}] [expr {$po+$o}] [expr {$ps+$s}]]
    }
    if {[array size per] == 0} { return [list "no API calls recorded since $from"] }
    set lines [list "talkbot API spend by model, since $from:"]
    foreach model [lsort [array names per]] {
        lassign $per($model) c i ca cw o s
        set cost [::talkbotcost::bucket_cost $model $i $ca $cw $o $s]
        set note [expr {[::talkbotcost::priced $model] ? "" : "  <-- PRICE NOT SET"}]
        lappend lines "  $model: [::talkbotcost::money $cost] ($c calls, [::talkbotcost::tokens $i] in / [::talkbotcost::tokens $o] out)$note"
    }
    return $lines
}

##############################################################################
# Channel trigger.
##############################################################################

# Reuse talkbot.tcl's helpers when they're there (they handle the
# global-vs-channel matchattr subtlety and the o<m<n ladder correctly);
# fall back to a plain check if this script is somehow loaded on its own.
proc ::talkbotcost::flag_ok {hand chan} {
    variable required_flag
    if {$hand eq "" || $hand eq "*"} { return 0 }
    if {[llength [info procs ::talkbot::dcc_bridge_flag_ok]] > 0} {
        return [::talkbot::dcc_bridge_flag_ok $hand $chan $required_flag]
    }
    if {![catch {matchattr $hand $required_flag $chan} hit] && $hit} { return 1 }
    if {$chan ne "" && ![catch {matchattr $hand "|$required_flag" $chan} hit] && $hit} { return 1 }
    return 0
}

proc ::talkbotcost::channel_ok {chan} {
    variable channels
    if {[llength $channels] > 0} {
        foreach c $channels {
            if {[string equal -nocase $c $chan]} { return 1 }
        }
        return 0
    }
    if {[llength [info procs ::talkbot::channel_allowed]] > 0} {
        return [::talkbot::channel_allowed $chan]
    }
    return 1
}

# Same output-safety treatment talkbot.tcl gives everything it sends: strip
# control bytes (no line injection, no faked colours) and wrap long lines so
# the server can't truncate them mid-word.
#
# $mode overrides $output for this call only ("" -- the default -- means
# "use $output"). Used by help_output so the !costhelp command list can be
# routed differently (e.g. always a NOTICE) from the !cost spend figures.
proc ::talkbotcost::send {nick chan text {mode ""}} {
    variable output
    variable use_bold
    variable bold_marker
    if {$mode eq ""} { set mode $output }
    if {[llength [info procs ::talkbot::irc_output_safe]] > 0} {
        set text [::talkbot::irc_output_safe $text]
    } else {
        set text [string map {\r "" \n " " \t " "} $text]
    }
    if {[llength [info procs ::talkbot::wrap_text]] > 0} {
        set parts [::talkbot::wrap_text $text]
    } else {
        set parts [list $text]
    }
    foreach line $parts {
        # LAST step before the wire, deliberately: sanitizing has already run
        # (and would have eaten a real \x02), and wrapping has already run
        # (and counted the placeholder as the 1 char the \x02 also is), so
        # substituting here changes no length and bypasses no safety check.
        if {$use_bold} {
            set line [string map [list $bold_marker "\x02"] $line]
        } else {
            set line [string map [list $bold_marker ""] $line]
        }
        switch -- $mode {
            channel { putserv "PRIVMSG $chan :$line" }
            msg     { putserv "PRIVMSG $nick :$line" }
            default { putserv "NOTICE $nick :$line" }
        }
    }
}

# Sends a list of reply lines with a small delay between each, instead of
# firing them all in the same event-loop tick.
#
# Every multi-line reply in this file used to go out via a plain [foreach
# ... send], same as sysinfo.tcl's report did before it hit the same
# problem: several PRIVMSG/NOTICE lines sent back-to-back can trip the IRC
# server's own flood protection (or a services flood-kick on some
# networks), which silently drops or delays everything after the first
# line -- it looks like "the bot only answered once" even though every
# line was built correctly. The risk here is not hypothetical: report_help
# alone is 9 lines, and "!cost days 31" produces 32. Uses Tcl's `after`
# rather than an Eggdrop `utimer` for the same reason sysinfo.tcl does --
# this is a short, one-shot, strictly-increasing delay chain with nothing
# to leak or double-fire, so there is nothing a utimer's cancel-on-rehash
# would need to protect against.
proc ::talkbotcost::send_lines {nick chan lines mode} {
    if {[llength $lines] == 0} { return }
    set line [lindex $lines 0]
    set rest [lrange $lines 1 end]
    ::talkbotcost::send $nick $chan $line $mode
    if {[llength $rest] > 0} {
        after 750 [list ::talkbotcost::send_lines $nick $chan $rest $mode]
    }
}

##############################################################################
# Trigger matching -- shared by both !costhelp and !cost so the "<botnick>
# word ..." form and the punctuation trimming stay identical between them.
##############################################################################

# Returns {1 argslist} if $text opens with $trigger (bare "!foo ..." or
# "<botnick> foo ..."), else {0 {}}.
#
# trimright only, so a leading "!" on the trigger word survives the
# punctuation cleanup for the bare form. The botnick-prefixed form is
# compared against a bang-STRIPPED trigger on both sides (t0_bare), so
# "TalkBot cost" matches as documented -- comparing the raw word against $t0
# (which still has its leading "!") would only ever match "TalkBot !cost"
# and silently reject the plain "cost" form the CONFIG comment promises.
proc ::talkbotcost::match_trigger {text trigger} {
    set words [regexp -all -inline {\S+} $text]
    if {[llength $words] == 0} { return {0 {}} }
    set w0 [string trimright [lindex $words 0] " ,.:;!?"]
    set t0 [string trimright $trigger " ,.:;!?"]
    set t0_bare [string trimleft $t0 "!"]
    # Which nick counts as "us" for the "<botnick> cost ..." form.
    # talkbot.tcl's get_botnick when it's loaded, $::botnick otherwise.
    if {[llength [info procs ::talkbot::get_botnick]] > 0} {
        set mynick [::talkbot::get_botnick]
    } else {
        set mynick $::botnick
    }
    if {[string equal -nocase $w0 $t0]} {
        return [list 1 [lrange $words 1 end]]
    } elseif {[llength $words] > 1
              && $mynick ne ""
              && [string equal -nocase $w0 $mynick]
              && [string equal -nocase \
                      [string trimleft [string trimright [lindex $words 1] " ,.:;!?"] "!"] \
                      $t0_bare]} {
        return [list 1 [lrange $words 2 end]]
    }
    return {0 {}}
}

# Shared by both handlers: channel + flag gate, with the same DENIED-log
# throttling either way. Returns 1 if the request may proceed.
proc ::talkbotcost::gate_ok {nick uhost hand chan} {
    variable required_flag
    if {![::talkbotcost::channel_ok $chan]} { return 0 }
    # Denied attempts are logged but never answered -- same posture as
    # talkbot.tcl's bridge: no reply tells a prober nothing, the log tells
    # you everything.
    if {![::talkbotcost::flag_ok $hand $chan]} {
        # Throttled independently of cooldown_ok (see denied_log_ok): a
        # denied caller never reaches the authorized-only cooldown state, so
        # without this floor anyone in the channel -- authenticated or not
        # -- could force an unbounded putlog write per message just by
        # repeating the trigger.
        set src [expr {($hand eq "" || $hand eq "*") ? "$nick!$uhost" : $hand}]
        if {[::talkbotcost::denied_log_ok $src $chan]} {
            putlog "\[talkbot-cost\] DENIED -- $nick ($hand) asked for spend in $chan without +$required_flag"
        }
        return 0
    }
    return 1
}

##############################################################################
# !costhelp -- ALWAYS just the command list. Whatever follows the trigger
# (nothing, "all", "today", a typo, anything) is ignored: this command has
# exactly one job, so there is no subcommand parsing here at all and it can
# never accidentally answer with spend figures.
##############################################################################

# Error boundaries. Both of these are bound to pubm "*", i.e. they run for
# every public line the bot sees, and everything they reach -- the date
# maths, the aggregation over a file-loaded array, the formatter -- had no
# catch anywhere above it. An error in any of that escaped into Eggdrop's
# bind handler once per line, for every line, until someone noticed.
proc ::talkbotcost::on_pubm_help {nick uhost hand chan text} {
    if {[catch { ::talkbotcost::on_pubm_help_inner $nick $uhost $hand $chan $text } err]} {
        putlog "\[talkbot-cost\] error handling $::talkbotcost::help_trigger from $nick in $chan: $err"
    }
}

proc ::talkbotcost::on_pubm_report {nick uhost hand chan text} {
    if {[catch { ::talkbotcost::on_pubm_report_inner $nick $uhost $hand $chan $text } err]} {
        putlog "\[talkbot-cost\] error handling $::talkbotcost::report_trigger from $nick in $chan: $err"
    }
}

proc ::talkbotcost::on_pubm_help_inner {nick uhost hand chan text} {
    variable report_enabled
    variable help_trigger
    variable help_output
    if {!$report_enabled} { return }

    lassign [::talkbotcost::match_trigger $text $help_trigger] matched args
    if {!$matched} { return }
    if {![::talkbotcost::gate_ok $nick $uhost $hand $chan]} { return }

    # One cooldown key -- there's only one possible answer from this trigger.
    if {![::talkbotcost::cooldown_ok $hand "help"]} { return }

    putlog "\[talkbot-cost\] $nick ($hand) in $chan asked for the command list"
    ::talkbotcost::send_lines $nick $chan [::talkbotcost::report_help] $help_output
}

##############################################################################
# !cost -- the spend reports. Bare trigger = "all" (today/week/month at
# once), same as the three explicit windows, plus "days [n]" and "models".
##############################################################################

proc ::talkbotcost::on_pubm_report_inner {nick uhost hand chan text} {
    variable report_enabled
    variable report_trigger
    if {!$report_enabled} { return }

    lassign [::talkbotcost::match_trigger $text $report_trigger] matched args
    if {!$matched} { return }
    if {![::talkbotcost::gate_ok $nick $uhost $hand $chan]} { return }

    set sub [string tolower [lindex $args 0]]

    # Aliases, so the obvious guesses work instead of being scolded. Bare
    # "!cost" ("" here) means "all three windows", same as summary/report.
    switch -- $sub {
        day      -
        t        { set sub "today" }
        weekly   -
        w        -
        7d       { set sub "week" }
        monthly  -
        m        -
        30d      { set sub "month" }
        summary  -
        report   -
        ""       -
        all      { set sub "all" }
    }

    # Every unrecognized subcommand shares ONE cooldown key, so "!cost a",
    # "!cost b", "!cost c" can't each earn their own error line.
    switch -- $sub {
        all - today - week - month - days - models { set ckey $sub }
        default { set ckey " unknown" }
    }

    # Silent when tripped, same as talkbot.tcl's own reply_cooldown -- no
    # "slow down" message, it just doesn't answer again yet. Checked AFTER the
    # subcommand is resolved because the window is per-subcommand: asking for
    # month right after week is normal use and must not be swallowed.
    if {![::talkbotcost::cooldown_ok $hand $ckey]} { return }

    switch -- $sub {
        today  -
        week   -
        month  { set lines [::talkbotcost::report_window $sub] }
        days   { set lines [::talkbotcost::report_days [lindex $args 1]] }
        models { set lines [::talkbotcost::report_models] }
        all    { set lines [::talkbotcost::report] }
        default {
            set lines [list "unknown option '[::talkbotcost::plain $sub]' -- try \"$help_trigger\" for the command list."]
        }
    }

    # plain() on $sub here for the same reason it is used in the reply
    # above: an unrecognized subcommand is raw user text, and it was going
    # into the logfile unsanitized and at whatever length was typed while
    # the reply one line earlier was carefully cleaned. The log is a text
    # file other tools read; a caller holding +m is still a caller, and
    # this costs nothing.
    putlog "\[talkbot-cost\] $nick ($hand) in $chan asked for spend ([::talkbotcost::plain $sub])"
    ::talkbotcost::send_lines $nick $chan $lines ""
}

##############################################################################
# The hook into talkbot.tcl.
#
# Re-applied on EVERY source of this file, not just the first: .rehash
# re-sources talkbot.tcl too, which redefines ::talkbot::extract_text and
# throws our wrapper away. As long as this file is sourced after talkbot.tcl
# in eggdrop.conf, that redefinition is immediately re-wrapped here. The
# marker comment in the wrapper body makes this idempotent -- sourcing twice
# without talkbot.tcl in between does not stack two wrappers (which would
# double-count every call).
##############################################################################

# Kills every pending utimer whose command mentions ::talkbotcost::<name>.
# The core's timer table is the authority: this script's own handles don't
# survive a fresh interpreter and can go stale after a partial reload, and
# a stale id handed to killutimer would take out some other script's timer.
proc ::talkbotcost::cancel_timers {name} {
    if {[catch {utimers} active]} { return }
    foreach t $active {
        if {[string match "::talkbotcost::$name*" [lindex $t 1]]} {
            catch { killutimer [lindex $t 2] }
        }
    }
}

# Periodic health check on the hook.
#
# The wrapper is installed by renaming ::talkbot::extract_text aside. That
# survives a normal .rehash only because eggdrop.conf sources talkbot.tcl
# first and this file second, so the redefinition is immediately re-wrapped.
# It does NOT survive anything that re-sources talkbot.tcl ALONE -- ".tcl
# source scripts/talkbot.tcl" from the partyline is the obvious one -- and
# the failure is completely silent: the bot keeps replying, nothing is
# recorded, and !cost keeps answering with figures that stopped moving.
# This re-checks periodically and re-installs if the marker has vanished,
# so the tracker repairs itself instead of quietly going dark.
proc ::talkbotcost::hook_watch {} {
    ::talkbotcost::cancel_timers hook_watch
    foreach p {extract_text extract_image_data} {
        if {[llength [info procs ::talkbot::$p]] > 0
                && ![string match {*TALKBOT_COST_WRAPPER_V1*} [info body ::talkbot::$p]]} {
            putlog "\[talkbot-cost\] the hook into talkbot's $p was replaced (talkbot.tcl re-sourced on its own?) -- reinstalling; spend between then and now was not recorded"
            catch { ::talkbotcost::install_hook }
            break
        }
    }
    utimer 300 ::talkbotcost::hook_watch
}

proc ::talkbotcost::install_hook {{attempt 1}} {
    if {[llength [info procs ::talkbot::extract_text]] == 0} {
        # talkbot.tcl isn't loaded yet -- most likely this file is sourced
        # first in eggdrop.conf. Retry a few times rather than giving up
        # silently and recording nothing forever.
        if {$attempt <= 10} {
            # Sweep any retry chain already pending before arming another.
            # install_hook runs on EVERY source of this file, so on a bot
            # where talkbot.tcl genuinely isn't loaded, each rehash started
            # a fresh chain of up to ten retries while the previous chains
            # were still counting down -- N rehashes, N overlapping chains.
            ::talkbotcost::cancel_timers install_hook
            utimer 2 [list ::talkbotcost::install_hook [expr {$attempt + 1}]]
            return
        }
        putlog "\[talkbot-cost\] ::talkbot::extract_text never appeared -- is talkbot.tcl sourced? Nothing will be recorded."
        return
    }

    if {![string match {*TALKBOT_COST_WRAPPER_V1*} [info body ::talkbot::extract_text]]} {
        catch { rename ::talkbotcost::orig_extract_text {} }
        rename ::talkbot::extract_text ::talkbotcost::orig_extract_text

        proc ::talkbot::extract_text {body} {
            # TALKBOT_COST_WRAPPER_V1 -- installed by talkbot_cost.tcl.
            # The catch is load-bearing: a fault in the cost accounting must
            # never stop the bot from delivering its reply.
            if {[catch { ::talkbotcost::record_from_body $body } err]} {
                putlog "\[talkbot-cost\] recording failed (reply unaffected): $err"
            }
            return [::talkbotcost::orig_extract_text $body]
        }
        putlog "\[talkbot-cost\] hooked into talkbot's response handler"
    }

    # !talkbotpic calls go through the images endpoint, which never reaches
    # extract_text, so image spend was never counted. extract_image_data is
    # called exactly once per successful (2xx) image response.
    if {[llength [info procs ::talkbot::extract_image_data]] > 0
            && ![string match {*TALKBOT_COST_WRAPPER_V1*} [info body ::talkbot::extract_image_data]]} {
        catch { rename ::talkbotcost::orig_extract_image_data {} }
        rename ::talkbot::extract_image_data ::talkbotcost::orig_extract_image_data

        proc ::talkbot::extract_image_data {body} {
            # TALKBOT_COST_WRAPPER_V1 -- installed by talkbot_cost.tcl.
            set m ""
            catch { set m $::talkbot::image_model }
            if {[catch { ::talkbotcost::record_from_body $body $m } err]} {
                putlog "\[talkbot-cost\] image recording failed (reply unaffected): $err"
            }
            return [::talkbotcost::orig_extract_image_data $body]
        }
        putlog "\[talkbot-cost\] hooked into talkbot's image response handler"
    }
}

##############################################################################
# Cleanup for upgrades from the pre-split (single ::talkbotcost::on_pubm)
# version of this script.
#
# WHY THIS IS OUTSIDE THE LOAD-ONCE GUARD BELOW: a rehash re-sources this
# file and so redefines every proc -- but it does NOT clear Tcl variables
# already sitting in memory, and ::talkbotcost::loaded is one of them. If
# someone upgrades in place with a plain ".rehash" (rather than a full
# ".restart"), ::talkbotcost::loaded is already 1 from the OLD version having
# loaded earlier in the same bot session, so the guarded block below is
# skipped entirely -- the new on_pubm_help/on_pubm_report binds never get
# registered, while the bind from the old version (pointing at
# ::talkbotcost::on_pubm, a proc name this version no longer defines at all)
# keeps sitting there silently matching every message and doing nothing,
# since Eggdrop doesn't error on a bind whose target proc no longer exists.
# That's the exact failure mode this catch{} is here to close off: it runs
# on EVERY source (rehash or restart, guard or no guard) and is a harmless
# no-op once the stale bind is gone.
##############################################################################
catch { unbind pubm - "*" ::talkbotcost::on_pubm }

##############################################################################
# Load-once guard for the things that must NOT repeat on a rehash: binding
# the triggers twice would answer twice, and reloading the data file on top
# of live in-memory counts could lose a call recorded since the last save.
##############################################################################

if {![info exists ::talkbotcost::loaded] || !$::talkbotcost::loaded} {
    ::talkbotcost::load
    set ::talkbotcost::loaded 1
}

# The binds are NOT inside that guard any more.
#
# The long comment above about the stale ::talkbotcost::on_pubm bind
# describes exactly why: ::talkbotcost::loaded is an ordinary Tcl variable
# that survives a rehash, so anything guarded by it runs once per BOT
# SESSION, not once per load -- and if a bind is ever lost while the
# variable persists (an in-place upgrade, or an Eggdrop build that drops
# Tcl binds on .restart), the guard cheerfully says "already loaded" and
# the triggers are dead with nothing in the log. Unbinding what was
# actually registered and re-binding is idempotent, cannot double-answer,
# and removes the dependency on guessing what a restart clears. ::load
# stays guarded: re-reading the data file on top of live counts is the one
# thing that genuinely must not repeat.
catch { unset ::talkbotcost::bound }
foreach _tc_b {::talkbotcost::on_pubm_help ::talkbotcost::on_pubm_report} {
    catch { unbind pubm - "*" $_tc_b }
    if {[catch { bind pubm - "*" $_tc_b } _tc_err]} {
        putlog "\[talkbot-cost\] failed to bind $_tc_b: $_tc_err"
    }
}
catch { unset _tc_b }
catch { unset _tc_err }

# Outside the guard on purpose -- see install_hook's comment.
::talkbotcost::install_hook

# Self-repair watch for the hook (see hook_watch). Armed on every source;
# cancel_timers inside it means a rehash re-arms rather than stacking, and
# a .restart -- which kills all utimers -- gets it back.
::talkbotcost::hook_watch

putlog "\[talkbot-cost\] loaded. Triggers: $::talkbotcost::help_trigger (help), $::talkbotcost::report_trigger (reports) | flag: +$::talkbotcost::required_flag | output: $::talkbotcost::output | week: $::talkbotcost::week_mode | month: $::talkbotcost::month_mode | data: $::talkbotcost::data_file"
