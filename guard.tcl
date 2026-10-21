##############################################################################
# guard.tcl -- Eggdrop join monitor
#
# Behavior:
#   - Watches joins to configured channels.
#   - Waits check_delay seconds after a user joins.
#   - Drops the check if the user parts, quits or is kicked before it is
#     due (which also frees that host's per-host tracking slot).
#   - Skips the check if the user is a trusted handle in the bot's
#     userlist. Never WHOISes a user holding +o/+v/+h, unconditionally.
#   - Queues a WHOIS and sends it at a rate-limited pace.
#   - Checks the WHOIS "channels" line for #TeenWankin membership.
#   - If found, bans and kicks ONLY that user, and ONLY in the watched
#     channel(s) whose join triggered the check, and only if the ban mask
#     wouldn't catch bystanders.
#   - Does NOT set +R and does NOT enable channel restrictions.
#   - Every ban it sets is recorded, listable and removable -- see
#     "Removing bans" below.
#
# ---------------------------------------------------------------------------
# Removing bans
# ---------------------------------------------------------------------------
#   Bans are timed (ban_lifetime_mins, default 24h) and expire on their
#   own. To remove one early:
#
#     Just unset it, from any client, like any other ban:
#       /mode #chan -b *!*ident@host
#       (or your client's /unban, or ChanServ, or another bot)
#
#     No command and no bot access needed -- anyone the CHANNEL lets set
#     modes can lift one of these bans, which on IRC means channel ops.
#     This works because of honor_manual_unban below; see the note on
#     re-enforcement.
#
#     Partyline (needs +m or +n):
#       .guard bans                     list every ban this script set
#       .guard unban <chan> <mask>      remove one (mask may be a glob)
#       .guard unban <chan> *           remove all of them on that channel
#       .guard unbanall                 remove all of them everywhere
#       .guard status                   queue/table/timer counters
#
#     In-channel (channel ops only, on a watched channel; set
#     pub_command_enabled 0 to disable):
#       !guard bans
#       !guard unban <mask>
#
#   The .guard/!guard paths call killchanban AND push a -b mode, so the
#   ban goes away in the channel and from the bot's own ban list at the
#   same time.
#
#   Why "/mode -b" needs help: a ban set with newchanban lives in the
#   BOT's channel ban list as well as in the channel, and Eggdrop
#   re-enforces what is in that list -- so unsetting one by hand normally
#   gets it put straight back within seconds, which is why a special
#   command used to be the only way to lift one. on_mode_unban (bound to
#   "-b") now watches for a manual removal and calls killchanban itself,
#   dropping the ban from the bot's list so nothing re-adds it. A plain
#   /mode -b is therefore final, and .guard unban is just a convenience
#   for people who are already on the partyline.
#
#   Set honor_manual_unban 0 to go back to the old behavior, where the
#   bot re-enforces its own bans for their full lifetime and .guard /
#   !guard are the only ways to lift one.
#
#   The old "pushmode +b" fallback is recorded for the same reason: a raw
#   mode ban is invisible to .bans, so nothing could ever list or lift it.
#
# Established hardening (earlier passes):
#   - Ban/kick scoped to the triggering channel only.
#   - Exact-token match on the WHOIS channel list (no substring match).
#   - Ban mask never falls back to a network-wide "*!*@*".
#   - Mode/kick calls wrapped in catch.
#   - Kick reason neutral; justification logged privately, not broadcast.
#   - RPL_WHOISCHANNELS (319) parsed at the correct field offset, and
#     accumulated across continuation lines.
#   - 319 replies correlated against checks this script actually sent.
#   - Nick changes carry the check over, preserving the original deadline.
#   - WHOIS output rate limited so a join burst can't flood the bot off.
#   - Trusted handles (+b/+f/+m/+n/+o) and the bot itself are exempt.
#   - Bans are timed and tracked (newchanban), with a rolling ban budget.
#   - One sweeper timer services all pending checks (no timer per user).
#   - Case-folded (rfc1459) keys throughout.
#
# ---------------------------------------------------------------------------
# Fixed in this pass
# ---------------------------------------------------------------------------
#   XI.  state_load DID NOT DECLARE pending / whois_queue / pending_fields /
#        whois_queue_fields, AND ITS ERROR HANDLER CRASHED THE WHOLE SCRIPT
#        LOAD. Two compounding bugs, hit together the first time a rehash
#        or restart happened with a non-empty guard.state on disk:
#        (a) state_load referenced $pending_fields and $whois_queue_fields,
#            and wrote to "pending"/"whois_queue", without declaring any of
#            the four as "variable" in the proc -- so the length checks on
#            every PEND/QUEUE line threw "no such variable", and even on a
#            clean parse the loaded data was never actually written back to
#            the namespace arrays (pending/whois_queue stayed empty).
#        (b) Both state_save's and state_load's own failure-path log lines
#            wrote literal "[guard]" inside a double-quoted string instead
#            of "\[guard\]" -- everywhere else in this file escapes it, but
#            these two didn't, so evaluating that string tried to RUN a
#            command named "guard". The moment (a) threw inside state_load's
#            catch, its handler hit (b) and threw "invalid command name
#            guard" -- uncaught, since it happened inside the catch's own
#            error branch -- which killed the source of the whole script and
#            took the config load (and the bot's connection) down with it:
#                Tcl error in file 'f.conf': invalid command name "guard"
#                ... (procedure "state_load" line 70) ...
#                * CONFIG FILE NOT LOADED (NOT FOUND, OR ERROR)
#        state_load now declares all four variables, and both putlog lines
#        are properly escaped, so a bad/legacy state file logs one line and
#        is safely ignored -- which is what this code always intended.
#
#   X.   on_nick HAD THE WRONG ARITY AND THREW ON EVERY NICK CHANGE. The
#        previous pass "fixed" this proc to a 4-argument signature (nick
#        uhost hand newnick) on the belief that Eggdrop's nick bind carries
#        no channel argument. It does: per tcl-commands.doc, the callback
#        is "nick user@host handle channel newnick" (5 args), fired once
#        per channel the bot shares with the renaming user. Confirmed
#        live: "wrong # args: should be ::guard::on_nick nick uhost hand
#        newnick" on every nick change on the network. Every rename during
#        that window silently skipped BOTH pending-check and in-flight-WHOIS
#        carry handling -- functionally reopening item 4/A below (a rename
#        during a check voided it) for as long as the bad signature was
#        live. on_nick now takes {nick uhost hand chan newnick}; $chan is
#        accepted but not filtered on, since the carry logic already
#        applies across every watched channel for the renaming nick in one
#        pass, and Eggdrop calling this proc again for a second shared
#        channel just finds nothing left to carry.
#
# ---------------------------------------------------------------------------
# Fixed in the previous pass
# ---------------------------------------------------------------------------
#   0.   LEAVING THE CHANNEL DID NOT RELEASE THE PENDING CHECK, AND THAT
#        WAS A COMPLETE BYPASS. Nothing was bound to part, sign (quit) or
#        kick, so an entry stayed in the pending table until its deadline
#        -- up to check_delay, 5 minutes at the defaults -- whether or not
#        the user was still there. max_per_mask (3) counts outstanding
#        pending checks per HOST, on the reasoning that one ban covers the
#        host, which only holds while those users are present. So: join,
#        part, rename, three times over, and the host's three slots are
#        full of users who have gone. The fourth join is refused by the
#        cap in on_join, which logs and returns -- and since on_join has
#        already fired for that user, nothing ever creates an entry for
#        them. The three stale entries do expire on schedule, but expiring
#        them checks nobody: check_user tests onchan for the nick that
#        left. Four joins and three parts from a single client, in a few
#        seconds, and the joiner is never WHOISed for the life of their
#        session. part/sign/kick now release the entry immediately, which
#        frees the slot. Only the pending table is touched: an in-flight
#        WHOIS is left to expire on its own, since the user may still be
#        on another watched channel and enforce() re-tests onchan anyway.
#
#   I.   NICK-SQUAT VOIDED AN IN-FLIGHT CHECK (two-account evasion).
#        whois_pending is keyed by the nick the WHOIS went out under,
#        because that is the nick the server answers with; a rename
#        deliberately leaves the key alone and only moves element 2. But
#        pump_whois then did an unconditional clear_whois_pending on the
#        nick it was about to query. So: user A joins, the WHOIS goes out
#        under "A", A renames to "B" (entry stays keyed "A", element 2 now
#        "B"), user C takes the nick "A" and joins. C's check reaches
#        pump_whois, which clears key "A" -- killing A/B's correlation
#        entry AND killutimer'ing its timeout timer -- and installs C's.
#        A/B's 319 then arrived under key "A" and matched C's entry, so
#        A/B was never enforced against and C was enforced against on
#        A/B's reply. Two cooperating clients could clear each other's
#        checks on demand. pump_whois now detects the collision (an entry
#        on this key whose element 2 no longer folds to the key) and holds
#        the new check at the front of the queue instead of clobbering;
#        the old entry is gone within whois_timeout_secs at the latest.
#
#   II.  REHASH WAS A FREE PASS, AND REFILLED THE BAN BUDGET. Every join
#        check in flight (pending, whois_queue, whois_pending) was thrown
#        away on reload, so anyone who had joined inside the last
#        check_delay seconds -- 5 minutes at the defaults -- was never
#        checked at all. ban_times was reset too, so a rehash restored the
#        full max_bans_per_window budget on demand. Only the TIMERS cannot
#        survive a reload; the data can. pending, mask_count, whois_queue
#        and ban_times now persist, malformed/stale entries are dropped by
#        an explicit format check, mask_count is REBUILT from pending (so
#        it cannot drift across the reload), in-flight WHOISes are handed
#        back to the queue to be re-sent, and the sweeper/pump timers are
#        re-armed if there is anything left to do. our_bans keeps its
#        existing carry-across behavior.
#
#   III. UNBOUNDED whois_chanbuf FROM SERVER-SUPPLIED TEXT. Each 319 line
#        was appended with no cap, and the settle debounce is pushed back
#        by every new line, so a hostile or broken server could stream 319
#        continuations and grow the buffer for as long as the
#        whois_timeout_secs backstop allowed. Capped at
#        max_chanbuf_bytes; past the cap the buffer stops growing, which
#        cannot cause a false ban (a match is acted on the moment it is
#        seen) and is logged.
#
#   IV.  A BAD status_prefixes VALUE THREW INSIDE A RAW BIND. The value is
#        spliced into a regexp character class, so a stray "]" or "^" made
#        strip_prefix throw on EVERY 319 -- silently disabling the entire
#        check while the script still looked loaded. The expression is now
#        compiled and tested once at load; a value that will not compile
#        falls back to the default with a loud log, and strip_prefix is
#        additionally failure-tolerant.
#
#   V.   expire_our_bans MEASURED OLD RECORDS AGAINST THE NEW LIFETIME.
#        our_bans survives a reload by design, but the cutoff used the
#        CURRENT ban_lifetime_mins, so lowering it made the bot forget
#        bans that were still in force (leaving them unlistable and
#        unliftable by command -- the exact failure the record exists to
#        prevent), and raising it kept dead records around. Each record
#        now carries the lifetime it was set with; 4-element records from
#        an older version are still read correctly.
#
#   VI.  !guardhelp WAS AN UNAUTHENTICATED NOTICE AMPLIFIER. It was bound
#        -|- with no channel restriction, so anyone in ANY channel the bot
#        sat in could make it emit up to nine NOTICEs per line typed, as
#        fast as they could type. It is now limited to watched channels
#        and rate limited per nick (pub_help_cooldown). The "options"
#        topic also published check_delay, whois_rate_secs and the watched
#        channel list to anyone who asked -- i.e. exactly how long an
#        evader has to part the target channel before the WHOIS lands --
#        and is now restricted to channel ops.
#
#   VII. UNBOUNDED LISTING OUTPUT. ".guard bans" / "!guard bans" emitted
#        one line per record with no cap; with a busy channel's worth of
#        records that is a self-inflicted flood. Capped at
#        max_ban_list_lines with an "and N more" tail.
#
#  VIII. Smaller items: the queried nick is shape-checked before it is
#        interpolated into "WHOIS $nick" (nicks come off the wire);
#        ".guard unban" validates the channel before acting on it;
#        remove_ban no longer reports failure for the expected case of
#        killchanban having nothing to remove (a pushmode-fallback ban);
#        enforce logs when the bot is not opped, instead of silently
#        recording a ban that cannot take effect; ishalfop is probed
#        rather than assumed (it does not exist on every 1.6.x build).
#
#   IX.  Dead code removed: the "deferrals" field was threaded through
#        pending_add, the pending tuple, on_join, on_nick, sweep and
#        check_user's signature and never read by anything -- a leftover
#        of the removed status-deferral path, which is now an outright
#        exemption. The pending tuple is 5 elements as a result, and the
#        format check in II drops any 6-element entry left over from a
#        previous version on the upgrade rehash. Also removed: the unbind
#        of raw 318 to ::guard::on_whois_end, a proc that has never
#        existed in this file, and an unreachable empty-nick fallback in
#        on_whois_channels.
#
# ---------------------------------------------------------------------------
# Fixed in earlier passes
# ---------------------------------------------------------------------------
#   A. A RENAME WHILE A WHOIS WAS IN FLIGHT PERMANENTLY EXEMPTED THE USER.
#      rekey_whois_pending MOVED the whois_pending entry onto the new
#      nick's key and carried the OLD timer id across with it -- one line
#      after clear_whois_pending_key, called to vacate the old key, had
#      already killutimer'd that very timer. The moved entry was left with
#      a dead backstop. Worse, the key it moved TO is not the key the
#      server answers under: the query went out for the OLD nick, so the
#      319 (or the 401) came back under the old nick, matched nothing, and
#      cleared nothing either. Net effect: whois_pending and whois_chanbuf
#      grew an entry that NOTHING could remove, and since queue_whois
#      early-returns on an existing in-flight entry, that user was never
#      WHOISed again for the life of the process. That is a self-service
#      permanent exemption, available to anyone who renamed inside the
#      reply window, and it followed them through later renames.
#      The entry is no longer rekeyed at all (proc renamed to
#      carry_whois_nick to say so). The key stays the nick the query was
#      sent under, so the reply still correlates and the original timeout
#      timer stays live and valid -- a rename cannot extend the deadline
#      either. Only the CURRENT nick, element 2, follows the rename, and
#      enforcement now acts on that instead of on the nick in the reply
#      text. That also completes what item 4 below only half-fixed: a
#      rename between query and reply now lands the ban/kick on the nick
#      the user is actually using, rather than voiding the check.
#      whois_chanbuf and the settle timer no longer need hand-carrying
#      between keys, since the key no longer moves.
#
#   B. RENAMING pub_command AND REHASHING LEAKED THE OLD BIND. The teardown
#      unbinds $pub_command -- the value it holds AFTER the config block at
#      the top of this file has just re-run, i.e. the NEW trigger, which
#      was never bound. The old trigger stayed bound with no way to remove
#      it short of a restart. Pub binds pointing at ::guard::pub_guard are
#      now swept by proc name, so the old trigger goes regardless of what
#      it was called.
#
#   C. HITTING max_whois_pending DISCARDED THE WHOLE QUEUE. The cap was
#      tested after the entry had already been dequeued, and used continue,
#      so once it was reached every remaining entry was pulled off and
#      thrown away inside one tick. It is now tested before the dequeue and
#      breaks, leaving the queue intact for the next pump. (Reachable at
#      all only because of A: in-flight entries that could never expire
#      meant the cap could be reached by accumulation.)
#
#   1. RELOAD LEFT PERMANENTLY POISONED STATE.  "array set a {}" is a
#      merge, not a reset -- it does not clear an existing array.  On
#      rehash the cleanup killed every whois_pending timer and then left
#      the entries themselves in place, so queue_whois's "already in
#      flight" early-return matched forever and any nick with a WHOIS
#      outstanding at reload time was NEVER checked again.  Stale
#      mask_count entries wedged max_per_mask the same way.  (Item II
#      above revisits this: the arrays that can safely be carried are now
#      carried DELIBERATELY, with a format check, rather than being
#      cleared or left to rot.)
#
#   2. PER-MASK CAP WAS DEFEATED BY THE IDENT.  Pending checks were
#      capped per BAN mask, and with ban_mask_style "identhost" that mask
#      contains the ident -- which the client chooses at registration.  A
#      cloner varying the ident got a distinct key per clone and sailed
#      past max_per_mask.  Accounting now uses host_mask (*!*@host), which
#      the client cannot vary from one connection, and is independent of
#      ban_mask_style.  Bans still use the narrow identhost mask.
#
#   3. A FLOOD COULD STARVE THE WHOIS QUEUE.  The queue was a flat FIFO
#      500 deep drained at one WHOIS per 3s -- a ~25 minute backlog
#      against a 120s check window, and once full every further join was
#      dropped unchecked.  Now: the same per-host-mask cap applies on
#      queue insertion, so one flooder cannot occupy the queue; and
#      entries older than whois_queue_max_age are discarded at pump time
#      instead of being sent long after they stopped meaning anything.
#
#   4. A NICK CHANGE AFTER THE WHOIS WENT OUT VOIDED THE CHECK.  on_nick
#      carried the pending entry over but not the in-flight correlation
#      entry, which is keyed by nick.  The 319 came back under the old
#      nick, failed the onchan test and returned silently.  (Superseded by
#      A above, which does this without moving the key.)
#
#   5. EMPTY / UNSAFE IDENT SILENTLY WIDENED THE MASK.  An ident of "~~~"
#      trimmed to empty and fell back to "*!*@host" -- the shared-host
#      mask this script exists to avoid.  An ident containing glob
#      metacharacters was interpolated straight into the mask and into
#      collateral_count's string match.  Both now yield no mask at all,
#      which means kick-only.  Failing to a kick is safe; failing to a
#      wildcard is not.
#
#   6. BAN BUDGET WAS CONSUMED BY FAILURES.  ban_budget_ok appended to the
#      window as a side effect of being asked, so every failed ban still
#      burned one of max_bans_per_window.  Split into ban_budget_check
#      (pure) and ban_budget_record (called only after a ban lands).
#
#   7. CHECKS WERE KEYED BY NICK ALONE, LOSING CHANNELS.  A user joining a
#      second watched channel while a check was in flight was never
#      checked there -- queue_whois returned early on the nick.  The
#      correlation entry now carries a LIST of triggering channels and
#      enforcement runs over all of them.  (Harmless with one watched
#      channel; a live grenade the moment a second is added.)
#
#   8. BANS COULD NOT BE REMOVED.  Nothing listed or lifted them, and the
#      pushmode fallback set bans the bot's ban list did not know about,
#      so .bans could not see them and killchanban could not remove them.
#      Every ban is now recorded in our_bans (surviving rehash), the
#      pushmode fallback is recorded too, and .guard / !guard remove them
#      through killchanban plus an explicit -b.  See "Removing bans".
#      Beyond that, a ban no longer requires a bot command to lift at
#      all: on_mode_unban watches for a manual -b on one of our masks and
#      calls killchanban itself, so Eggdrop stops re-enforcing it and the
#      manual removal is final.  Anyone the channel lets set modes can
#      undo one of these bans with no bot access whatsoever
#      (honor_manual_unban).
#
#   9. HARDCODED STATUS PREFIXES / MIXED CASE COMPARISON.  The WHOIS
#      channel-token prefix set is now configurable (status_prefixes), and
#      the target-channel comparison uses the same rfc1459 casefold as
#      every other comparison rather than string equal -nocase.
#
#  10. "ident@host" was split on every "@" rather than the first, so a
#      host containing one produced a wrong mask.  Split at the first @.
#
# Remaining known limits (genuine, not deferrable):
#   - casemapping and status_prefixes are fixed config values, not read
#     from the server's 005 (RPL_ISUPPORT) CASEMAPPING= / PREFIX= tokens.
#     The defaults match DALnet and most classic networks.
#   - The whole approach trusts the WHOIS channel list, which omits
#     +s/+p channels on most ircds. Users can hide membership there.
#   - A distributed flood from many distinct hosts still gets every
#     distinct host checked, which is correct, but at whois_rate_secs
#     apart. Sustained joins above that rate will age entries out of the
#     queue. That is logged loudly rather than hidden.
#   - A user granted +o/+v/+h around the check window is never WHOISed.
#     Deliberate operator policy, not an oversight.
#   - (Outdated note removed: pending, queued and in-flight checks, ban
#     records and the ban budget are written to state_file and restored
#     after a restart.)
##############################################################################

namespace eval ::guard {
    # Channels this script monitors:
    #   variable watch_channels {#channel1 #channel2}
    #   variable watch_channels {#channel1}
    #   variable watch_channels {*}
    #   variable watch_channels {all}
    # "*" and "all" mean every channel the bot is currently in.
    set watch_channels {#chan #chan}
    set target_channel "#TeenWankin"
    set kick_reason "removed."

    # IRC casemapping for nick/channel comparisons. "rfc1459" (the
    # default, and what DALnet and most classic networks use) treats
    # [ ] \ ~ as the uppercase forms of { } | ^, in addition to normal
    # A-Z/a-z folding -- so "|Ghost|" and "|ghost|" are the same nick,
    # and so is a rename to "{Ghost}". Set to "strict-rfc1459" (same,
    # but ~ does NOT fold with ^) or "ascii" (plain A-Z/a-z only) if
    # your network's 005 CASEMAPPING= token says otherwise.
    set casemapping "rfc1459"

    # Channel status prefixes to strip from a WHOIS channel token, per
    # your network's 005 PREFIX= token. Use only prefix symbols here: the
    # value is spliced into a regexp character class, so the characters
    # that are special inside one (close-bracket, caret, backslash) and a
    # literal dash must not appear. A value that will not compile is
    # rejected at load with a log line and the default is used instead --
    # it used to make strip_prefix throw on every 319, which disabled the
    # whole check while the script still looked loaded.
    set status_prefixes {@%+~&!*}

    # Timing
    set check_delay 300          ;# 5 minutes after join before checking
    set sweep_interval 5         ;# how often the sweeper services due checks

    # Channel-status handling. A user holding +o/+v/+h is never WHOISed,
    # unconditionally -- no deferral, no recheck, no eventual WHOIS once
    # status is dropped.

    # Pending checks. Key: casefolded "nick,chan".
    # Value: {uhost deadline nick chan hostmask}   (5 elements)
    # The element count is part of the on-rehash format check in
    # restore_state; if you add a field here, bump the check with it.
    variable pending
    variable pending_fields 5
    set max_pending 5000         ;# memory guard only, not a timer guard
    variable mask_count               ;# hostmask -> outstanding pending checks
    set max_per_mask 3           ;# a ban covers the whole host anyway
    variable sweep_timer

    # our_bans (below) is only pruned by expire_our_bans, and that used
    # to run solely as a side effect of sweep() -- which stops
    # rescheduling itself the moment the pending table drains to empty,
    # and only restarts on the next join. On a quiet watched channel,
    # ban records that already expired on the actual channel just sit in
    # our_bans, unpruned, until something happens to join. This timer is
    # independent of pending/sweep and just keeps running.
    variable ban_expire_timer
    set ban_expire_interval 300

    # Outgoing WHOIS pacing.
    # Queue entries: {nick chanlist enqueued hostmask}   (4 elements)
    variable whois_queue
    variable whois_queue_fields 4
    variable whois_queue_timer
    set whois_rate_secs 3
    set max_whois_queue 500
    # Drop a queued check older than this rather than acting on stale
    # data. Must comfortably exceed check_delay.
    set whois_queue_max_age 300

    # In-flight WHOIS correlation. Key: casefolded nick the query was
    # SENT under (that is the nick the server answers with).
    # Value: {chanlist timerid nick}   -- element 2 is the CURRENT nick.
    variable whois_pending
    # Defensive cap only: at one WHOIS per whois_rate_secs against a
    # whois_timeout_secs deadline, in-flight count cannot exceed
    # ceil(timeout/rate) anyway (~10 at the defaults).
    set max_whois_pending 200
    set whois_timeout_secs 30

    # RPL_WHOISCHANNELS (319) is not guaranteed to be a single line: a
    # nick sitting in enough channels gets its channel list split across
    # several 319 replies to stay under the server's line-length limit.
    # Acting (or concluding "not found") on only the first line means a
    # long enough channel list pushes target_channel onto a later line
    # that is never inspected -- silent evasion by joining lots of other
    # channels. whois_chanbuf accumulates every 319 seen so far for a
    # nick; whois_settle_timer is a short debounce that is pushed back by
    # each new 319 line and only concludes "not found" once no further
    # line has arrived within whois_settle_secs. Key: casefolded nick.
    variable whois_chanbuf
    variable whois_settle_timer
    set whois_settle_secs 2
    # Hard cap on accumulated 319 text per nick. The content is entirely
    # server-supplied and each line pushes the settle deadline back, so
    # without a cap the buffer grows for as long as lines keep arriving.
    # Overrunning it cannot cause a false ban: a match is acted on the
    # instant it is seen, so the only thing lost past the cap is the
    # ability to find the target channel in text the server is still
    # sending, which is logged.
    set max_chanbuf_bytes 8192

    # Ban policy.
    set ban_lifetime_mins 1440
    set max_bans_per_window 5
    set ban_window_secs 60
    variable ban_times

    # Bans this script set, so they can be listed and removed.
    # Key: "casefoldedchan,mask"
    # Value: {chan mask when method lifetime_mins}
    # Deliberately NOT cleared on rehash -- a ban outlives a reload, and
    # forgetting it here is what made bans unremovable before. The
    # lifetime is stored WITH the record because the record outlives the
    # config: expiring old records against a newly-lowered
    # ban_lifetime_mins used to drop records for bans still in force.
    # 4-element records written by an older version are still read.
    variable our_bans

    # Treat a manual "/mode -b" as final: when anyone unsets one of this
    # script's bans, drop it from the bot's channel ban list too, so
    # Eggdrop does not re-enforce it a moment later. This is what lets a
    # ban be lifted with no bot command and no bot access at all -- the
    # channel's own op requirement for setting modes is the only gate.
    #
    # Set to 0 to restore the stricter behavior: the bot re-adds its own
    # bans until they expire, and .guard / !guard are the only way out.
    set honor_manual_unban 1

    # Also honor a manual -b on a mask this script did NOT set (another
    # script's ban, a leftover, a hand-set ban). Off by default: removing
    # another script's ban from the shared list is not this script's
    # business, and Eggdrop re-adding it is that script's intent.
    set honor_manual_unban_foreign 0

    # In-channel "!guard" command for channel ops. Partyline .guard is
    # always available to +m/+n regardless of this setting.
    set pub_command_enabled 1
    set pub_command "!guard"

    # Persistent safety state. A rehash carries live state in memory and a
    # full Eggdrop restart restores pending/queued checks, bans and the
    # rolling ban budget from this file. In-flight WHOISes are re-queued.
    # The file contains only this script's bookkeeping.
    set state_file "scripts/guard.state"
    variable state_loaded 0
    variable state_version 1

    # !guardhelp throttle. The help bind answers anyone (it has to, it is
    # help), so it is the one place an unprivileged user can make the bot
    # emit several NOTICEs per line typed. Per-nick cooldown, seconds.
    set pub_help_cooldown 30
    variable help_last

    # Cap on lines emitted by a "bans" listing, partyline or channel.
    set max_ban_list_lines 25

    # "identhost" -> *!*ident@host (narrow, recommended)
    # "host"      -> *!*@host      (wide, catches shared hosts)
    set ban_mask_style "identhost"

    # Kick-but-never-ban if the host or computed mask matches any of
    # these glob patterns. Empty by default -- max_collateral below
    # handles shared hosts automatically. Example entries:
    #   {*.gateway.example.net *!*@webchat.* }
    set ban_never_masks {}

    # Maximum OTHER users on the channel the ban mask may match before
    # the ban is downgraded to a kick. 0 = the mask must hit only the
    # offender.
    set max_collateral 0

    # Handles with any of these flags (global|channel) are never acted
    # on. Checked alongside a global +b (bot) test.
    set exempt_flags "fmno|fmno"

    # --- (re)load cleanup ---------------------------------------------
    #
    # TIMERS cannot survive a reload -- their ids refer to a schedule this
    # script is about to stop owning -- so every one of them is killed
    # here and re-armed at the bottom by restore_state.
    #
    # DATA can survive, and now does. Throwing pending/whois_queue/
    # ban_times away on rehash meant a reload was a free pass for anyone
    # who had joined within the last check_delay seconds, and refilled the
    # rolling ban budget on demand. What is carried is validated by
    # restore_state rather than trusted: entries that do not match the
    # current tuple format (e.g. written by an older version of this file)
    # are dropped there, not silently misread.
    #
    # NOTE: "array set a {}" is a MERGE and does not clear an existing
    # array. Anything that must start empty is array unset first.

    if {[info exists sweep_timer] && $sweep_timer ne ""} {
        catch {killutimer $sweep_timer}
    }
    set sweep_timer ""

    if {[info exists ban_expire_timer] && $ban_expire_timer ne ""} {
        catch {killutimer $ban_expire_timer}
    }
    set ban_expire_timer ""

    if {[info exists whois_queue_timer] && $whois_queue_timer ne ""} {
        catch {killutimer $whois_queue_timer}
    }
    set whois_queue_timer ""

    # A pending debounced save. prerehash already wrote the file; the
    # restore at the bottom marks it dirty again.
    if {[info exists state_save_timer] && $state_save_timer ne ""} {
        catch {killutimer $state_save_timer}
    }
    set state_save_timer ""

    # In-flight WHOISes: the timeout timer dies with the reload, so the
    # entry cannot stay in flight. Hand each one back to the queue to be
    # re-sent instead of dropping the check on the floor. Element 2 is the
    # CURRENT nick (see carry_whois_nick), which is the nick worth
    # querying now -- not the key, which is whatever it was called when
    # the original query went out.
    set _carry {}
    if {[info exists whois_pending]} {
        foreach {key val} [array get whois_pending] {
            catch {killutimer [lindex $val 1]}
            if {[catch {llength $val} _l] || $_l < 3} { continue }
            set _n [lindex $val 2]
            if {$_n eq ""} { continue }
            lappend _carry [list $_n [lindex $val 0]]
        }
    }
    array unset whois_pending
    array set whois_pending {}

    if {[info exists whois_settle_timer]} {
        foreach {key tid} [array get whois_settle_timer] {
            catch {killutimer $tid}
        }
    }
    array unset whois_settle_timer
    array set whois_settle_timer {}
    array unset whois_chanbuf
    array set whois_chanbuf {}

    # Carried across the reload; validated in restore_state.
    if {![info exists pending]}     { array set pending {} }
    if {![info exists mask_count]}  { array set mask_count {} }
    if {![info exists our_bans]}    { array set our_bans {} }
    if {![info exists whois_queue]} { set whois_queue {} }
    if {![info exists ban_times]}   { set ban_times {} }

    # Throttle bookkeeping only -- safe to drop, and starting empty means
    # a rehash is not itself throttled.
    array unset help_last
    array set help_last {}

    # status_prefixes is spliced into a regexp character class below. A
    # value containing "]", "^" or "\" produces an expression that will
    # not compile, and the failure surfaced once per 319 inside a raw
    # bind -- i.e. the check silently stopped working. Validate once,
    # here, and fall back rather than ship a broken matcher.
    set prefix_re "^\[${status_prefixes}\]*(\[#&!+\].*)$"
    if {[catch {regexp $prefix_re "#test"}]} {
        putlog "\[guard\] status_prefixes '${status_prefixes}' does not form a valid regexp character class; falling back to the default"
        set status_prefixes {@%+~&!}
        set prefix_re "^\[${status_prefixes}\]*(\[#&!+\].*)$"
    }

    # --- small helpers -------------------------------------------------

    # Fold a nick or channel to its canonical comparison form per
    # $casemapping. Used everywhere two nicks (a tracked one and one
    # from a join/nick-change/WHOIS reply) need to be recognized as the
    # same identity, regardless of which case variant either arrived in.
    proc casefold {s} {
        variable casemapping
        set s [string tolower $s]
        if {$casemapping eq "ascii"} { return $s }
        # rfc1459: [ ] \ are the uppercase forms of { } | ; ~ <-> ^ too,
        # except under strict-rfc1459 where ~ does not fold.
        set map [list "\[" "\{" "\]" "\}" "\\" "|"]
        if {$casemapping ne "strict-rfc1459"} {
            lappend map "~" "^"
        }
        return [string map $map $s]
    }

    # All tracking keys are case-folded: IRC nicks are case-insensitive,
    # and servers do not always echo back the case we sent.
    proc nkey {nick chan} {
        return "[casefold $nick],[casefold $chan]"
    }

    # A nick arriving off the wire is interpolated into "WHOIS $nick" and
    # handed to putserv. Nicks cannot contain whitespace or NUL/CR/LF, so
    # anything that does is either a malformed server line or an attempt
    # to append a second command to the line -- refuse it rather than
    # send it. Also bounds the length: no network permits a 400-character
    # nick, and putserv has a line budget to protect.
    proc irc_safe_nick {n} {
        if {$n eq ""} { return 0 }
        if {[string length $n] > 64} { return 0 }
        if {[regexp {[\s:,*?!@]} $n]} { return 0 }
        if {[string first "\x00" $n] >= 0} { return 0 }
        return 1
    }

    proc channel_allowed {chan} {
        variable watch_channels

        # "*" or "all" means every channel the bot can observe.  This keeps
        # the configuration useful for installations that do not want to
        # maintain a growing channel list.  A normal Tcl list still works
        # for per-channel operation, e.g. {#mafia #prototype}.
        set c [casefold [string trim $chan]]
        foreach w $watch_channels {
            set w [string trim $w]
            set wf [casefold $w]
            if {$wf eq "*" || $wf eq "all"} { return 1 }
            if {$wf eq $c} { return 1 }
        }
        return 0
    }

    # ishalfop is not present on every Eggdrop build (it postdates parts
    # of the 1.6 line), and an unknown command here would throw inside a
    # bind. Probe it once instead of assuming.
    variable have_ishalfop [expr {[llength [info commands ishalfop]] > 0}]

    proc has_status {nick chan} {
        variable have_ishalfop
        if {[isop $nick $chan]} { return 1 }
        if {[isvoice $nick $chan]} { return 1 }
        if {$have_ishalfop && [ishalfop $nick $chan]} { return 1 }
        return 0
    }

    # A string is glob-safe if it cannot alter the meaning of a mask it
    # is interpolated into. Idents are client-supplied on registration
    # and not every ircd restricts them, so this is checked rather than
    # assumed. Written as string first rather than a regexp class so the
    # escaping is unambiguous on Tcl 8.4.
    proc glob_safe {s} {
        if {$s eq ""} { return 0 }
        foreach c [list "*" "?" "\[" "\]" "\\"] {
            if {[string first $c $s] >= 0} { return 0 }
        }
        # A second @ in the host would make the generated ban mask
        # ambiguous (split_uhost deliberately splits only at the first @).
        # Reject control/whitespace as well; never let malformed server data
        # become a mode argument.
        if {[string first "@" $s] >= 0} { return 0 }
        if {[regexp {\s|[\x00-\x1f\x7f]} $s]} { return 0 }
        return 1
    }

    # Split "ident@host" at the FIRST @ only. Returns {ident host}, or
    # {} if there is no usable host part.
    proc split_uhost {uhost} {
        set at [string first "@" $uhost]
        if {$at < 0} { return {} }
        set ident [string range $uhost 0 [expr {$at - 1}]]
        set host  [string range $uhost [expr {$at + 1}] end]
        if {$host eq ""} { return {} }
        return [list $ident $host]
    }

    # Host-only mask. This is the PENDING-ACCOUNTING key, deliberately
    # independent of ban_mask_style and of the ident: the ident is chosen
    # by the client, so counting per ban mask let a cloner mint a fresh
    # key per connection and walk straight past max_per_mask. The host is
    # the thing a clone flood actually shares.
    proc host_mask {uhost} {
        set p [split_uhost $uhost]
        if {![llength $p]} { return "" }
        return "*!*@[string tolower [lindex $p 1]]"
    }

    # The ban mask this uhost would produce, or "" if no mask can be
    # derived safely. "" means kick-only: it is never a licence to fall
    # back to something wider.
    proc ban_mask {uhost} {
        variable ban_mask_style

        set p [split_uhost $uhost]
        if {![llength $p]} { return "" }
        set ident [lindex $p 0]
        set host  [lindex $p 1]

        # A host with glob metacharacters in it (spoofed cloak, odd
        # vhost) would widen both the ban and collateral_count's match.
        if {![glob_safe $host]} { return "" }

        if {$ban_mask_style ne "identhost"} { return "*!*@$host" }

        # Strip identd decoration so the mask matches the user with or
        # without a tilde.
        set bare [string trimleft $ident "~^=+-"]

        # An ident that is entirely decoration ("~~~") used to trim to
        # empty and fall back to "*!*@host" -- the shared-host mask this
        # script exists to avoid. Same for an ident carrying glob
        # metacharacters. Both now mean no mask: kick, do not ban.
        if {![glob_safe $bare]} { return "" }

        return "*!*$bare@$host"
    }

    # Trusted-user / self check. Deliberately fails CLOSED toward
    # "leave them alone": if the userlist lookup errors for any reason
    # we treat the nick as exempt rather than ban on a failed lookup.
    proc is_exempt {nick chan {hand ""}} {
        variable exempt_flags

        if {[isbotnick $nick]} { return 1 }

        if {[catch {
            if {$hand eq "" || $hand eq "*"} {
                set hand [nick2hand $nick $chan]
            }
            set result 0
            if {$hand ne "" && $hand ne "*"} {
                if {[matchattr $hand b]} { set result 1 }
                if {!$result && [matchattr $hand $exempt_flags $chan]} { set result 1 }
            }
            set result
        } out]} {
            putlog "\[guard\] userlist lookup failed for $nick on $chan ($out); treating as exempt"
            return 1
        }

        return $out
    }

    # --- pending table -------------------------------------------------
    #
    # One sweeper timer services the whole table. Nothing here allocates
    # a timer per user, which is what previously forced max_pending down
    # to a level a join-flood could exhaust.

    proc pending_add {nick uhost chan deadline} {
        variable pending
        variable mask_count

        set key [nkey $nick $chan]
        if {[info exists pending($key)]} { pending_del $key }

        # The accounting mask is stored with the entry rather than
        # recomputed on removal, so the counters cannot drift if config
        # is changed at runtime while checks are in flight.
        set m [host_mask $uhost]
        set pending($key) [list $uhost $deadline $nick $chan $m]

        if {$m ne ""} {
            if {[info exists mask_count($m)]} {
                incr mask_count($m)
            } else {
                set mask_count($m) 1
            }
        }

        start_sweeper
        catch {state_save}
    }

    proc pending_del {key} {
        variable pending
        variable mask_count

        if {![info exists pending($key)]} { return }

        set m [lindex $pending($key) 4]
        unset pending($key)

        if {$m ne "" && [info exists mask_count($m)]} {
            incr mask_count($m) -1
            if {$mask_count($m) <= 0} { unset mask_count($m) }
        }
    }

    proc mask_pending_count {uhost} {
        variable mask_count
        set m [host_mask $uhost]
        if {$m ne "" && [info exists mask_count($m)]} { return $mask_count($m) }
        return 0
    }

    proc start_sweeper {} {
        variable sweep_timer
        variable sweep_interval

        if {$sweep_timer ne ""} { return }
        set sweep_timer [utimer $sweep_interval ::guard::sweep]
    }

    proc sweep {} {
        variable pending
        variable sweep_timer

        set sweep_timer ""
        set now [unixtime]

        # array get is a snapshot, so mutating the table inside the
        # loop is safe.
        foreach {key val} [array get pending] {
            if {[lindex $val 1] > $now} { continue }

            set uhost [lindex $val 0]
            set nick  [lindex $val 2]
            set chan  [lindex $val 3]

            pending_del $key
            catch {check_user $nick $uhost $chan}
        }

        if {[array size pending]} { start_sweeper }
    }

    # our_bans bookkeeping cleanup, on its own schedule -- independent of
    # sweep/pending, so it keeps running on a quiet channel instead of
    # stalling between joins. Always reschedules itself; there is no
    # "nothing left to do" stopping condition here the way there is for
    # the join-driven sweeper.
    proc schedule_ban_expire {} {
        variable ban_expire_timer
        variable ban_expire_interval

        if {$ban_expire_timer ne ""} { return }
        set ban_expire_timer [utimer $ban_expire_interval ::guard::ban_expire_tick]
    }

    proc ban_expire_tick {} {
        variable ban_expire_timer
        set ban_expire_timer ""
        catch {expire_our_bans}
        schedule_ban_expire
    }

    # --- join / nick tracking ------------------------------------------

    proc on_join {nick uhost hand chan} {
        variable pending
        variable max_pending
        variable max_per_mask
        variable check_delay

        if {[isbotnick $nick]} { return }
        if {![channel_allowed $chan]} { return }
        if {[is_exempt $nick $chan $hand]} { return }

        # Per-HOST cap. Anything we would ban for one of these we would
        # ban for all of them with a mask covering the same host, so
        # tracking more than a handful gains nothing -- and letting
        # clones fill the table is exactly how the old cap was bypassed.
        # Keyed on host, not on the ban mask, because the ident in the
        # ban mask is chosen by the client.
        set key [nkey $nick $chan]
        if {![info exists pending($key)]} {
            if {[mask_pending_count $uhost] >= $max_per_mask} {
                putlog "\[guard\] $max_per_mask checks already pending for host mask [host_mask $uhost]; not tracking $nick on $chan separately (one ban covers the host)"
                return
            }
        }

        if {[array size pending] >= $max_pending} {
            putlog "\[guard\] pending table full ($max_pending) -- this should not happen with per-host capping; skipping $nick on $chan"
            return
        }

        # Absolute deadline, so it survives a nick change intact.
        pending_add $nick $uhost $chan [expr {[unixtime] + $check_delay}]
    }

    # A user who has left the channel has no pending check to serve, and
    # holding their entry until its deadline is not merely wasteful -- it
    # is a bypass of the per-host cap, and the cheapest one available.
    #
    # max_per_mask (3) counts OUTSTANDING pending checks per host mask, on
    # the stated assumption that "one ban covers the host" -- which is only
    # true while those users are actually on the channel. Nothing released
    # an entry when they were not:
    #
    #   join as n1, part; /nick n2, join, part; /nick n3, join, part
    #     -> mask_count(*!*@host) == 3, all for users no longer present
    #   /nick n4, join
    #     -> mask_pending_count hits the cap, on_join logs and RETURNS
    #
    # n4 is now sitting in the channel with no pending entry, and on_join
    # has already fired for them, so nothing will ever create one. The
    # three stale entries do expire on their own deadline, but expiring
    # them does not retroactively check n4 -- check_user tests
    # "onchan n1 $chan", which is false, and returns. Four joins and three
    # parts from one client, inside a few seconds, and the joiner is
    # permanently unchecked.
    #
    # Releasing the entry the moment the user leaves closes that: the slot
    # is freed immediately, so the next join from that host is tracked
    # normally. It does not create a new way to defer a check either --
    # pending_add already replaces an existing nick,chan entry with a fresh
    # deadline, so part-and-rejoin could always reset the clock, and doing
    # it costs the evader their presence in the channel for the gap.
    #
    # Only the pending table is touched. An in-flight WHOIS is left alone
    # deliberately: the user may still be on a second watched channel, the
    # reply is correlated by nick rather than by channel, and enforce()
    # already re-tests onchan before acting. It expires on its own.
    proc drop_pending {nick chan} {
        variable pending
        if {![channel_allowed $chan]} { return }
        set key [nkey $nick $chan]
        if {![info exists pending($key)]} { return }
        pending_del $key
    }

    # PART and QUIT. Eggdrop's part bind carries a reason on 1.8+ and not
    # on some older builds, and sign's arity has moved around similarly,
    # so the trailing argument is defaulted rather than required -- a proc
    # whose arity does not match what the bind passes throws inside the
    # bind on every part.
    proc on_part {nick uhost hand chan {msg ""}} {
        drop_pending $nick $chan
    }

    # sign (QUIT) fires once per channel shared with the bot.
    proc on_sign {nick uhost hand chan {reason ""}} {
        drop_pending $nick $chan
    }

    # On a kick it is the TARGET who left, not the kicker in $nick.
    proc on_kick {nick uhost hand chan target {reason ""}} {
        drop_pending $target $chan
    }

    # Carry an outstanding check over to a new nick. The original
    # deadline is preserved -- re-arming a fresh delay here would let a
    # user postpone the check forever by renaming just before each window
    # expired.
    #
    # Both tracking stages are carried, not just the pending table: an
    # in-flight WHOIS is correlated BY NICK, so a rename after the query
    # went out used to leave the 319 arriving under a key whose channel
    # test then failed, silently voiding the check.
    proc on_nick {nick uhost hand chan newnick} {
        variable pending

        # Eggdrop's nick bind is: oldnick uhost hand channel newnick (see
        # tcl-commands.doc) -- fired once per channel the bot shares with
        # the user, so a user on two watched channels triggers this twice
        # for one rename. $chan is deliberately unused below: the update
        # is already applied across every pending entry for the old nick
        # regardless of channel (a rename is global), so a second firing
        # for a second shared channel just finds nothing left to carry --
        # harmless, not a reason to filter on $chan here.
        if {$newnick eq "" || ![irc_safe_nick $newnick]} { return }
        if {[isbotnick $newnick]} {
            carry_whois_nick $nick $newnick
            foreach key [array names pending] {
                if {[casefold [lindex $pending($key) 2]] eq [casefold $nick]} {
                    pending_del $key
                }
            }
            return
        }

        carry_whois_nick $nick $newnick

        # A nick change is global, so update every pending check for the
        # old nick regardless of which watched channel it belongs to.  Keep
        # the original deadline and host accounting intact.
        set old [casefold $nick]
        foreach key [array names pending] {
            set val $pending($key)
            if {[casefold [lindex $val 2]] ne $old} { continue }
            set chan [lindex $val 3]
            pending_del $key
            pending_add $newnick [lindex $val 0] $chan [lindex $val 1]
        }
    }

    # Carry an in-flight check across a rename.
    #
    # The whois_pending KEY is deliberately not touched. It is the nick the
    # WHOIS was SENT under, and that is the nick the server answers with --
    # a 319 or a 401 for a renamed user still arrives under the old nick,
    # so moving the key (what this proc used to do) meant the reply
    # correlated with nothing and the entry was never cleared by anything.
    # It also carried the OLD timer id to the new key one line after
    # clear_whois_pending_key had already killutimer'd that timer, leaving
    # the moved entry with a dead backstop as well. Between the two, the
    # entry became unremovable, and since queue_whois early-returns on an
    # existing in-flight entry, the user was never WHOISed again for the
    # life of the process.
    #
    # Only element 2 -- the CURRENT nick, which is what enforcement acts on
    # -- follows the rename. Because the key stays put, the accumulated 319
    # buffer and the settle debounce stay correlated on their own with no
    # hand-carrying, and the original timeout timer stays live and valid,
    # so a rename cannot extend the check's deadline either.
    #
    # The cost of the key staying put is that the vacated nick can be taken
    # by someone else while the entry is still keyed to it; see pump_whois,
    # which refuses to overwrite an entry in that state.
    proc carry_whois_nick {oldnick newnick} {
        variable whois_pending
        variable whois_queue

        set ok [casefold $oldnick]
        set nk [casefold $newnick]
        if {$ok eq $nk} { return }

        # Matched on element 2, not on the key: after one rename the key is
        # still the originally-queried nick, so a SECOND rename has to find
        # the entry by who the user is called now. array names is a
        # snapshot, so clearing inside the loop is safe.
        foreach key [array names whois_pending] {
            if {[casefold [lindex $whois_pending($key) 2]] ne $ok} { continue }
            if {[isbotnick $newnick]} {
                clear_whois_pending_key $key
                continue
            }
            set val $whois_pending($key)
            set whois_pending($key) [list [lindex $val 0] [lindex $val 1] $newnick]
        }

        # A still-QUEUED entry has not been sent yet, so it does have to
        # follow the rename outright -- otherwise we WHOIS a nick that no
        # longer exists and get a 401 instead of a 319.
        set out {}
        foreach item $whois_queue {
            if {[casefold [lindex $item 0]] eq $ok} {
                lappend out [list $newnick [lindex $item 1] [lindex $item 2] [lindex $item 3]]
            } else {
                lappend out $item
            }
        }
        set whois_queue $out
    }

    proc check_user {nick uhost chan} {
        if {![validchan $chan]} { return }
        if {![onchan $nick $chan]} { return }

        # Channel status: permanent, unconditional exemption. A user
        # holding +o/+v/+h is never WHOISed, full stop -- no deferral,
        # no recheck window, no eventual WHOIS once status drops.
        if {[has_status $nick $chan]} {
            putlog "\[guard\] $nick on $chan has +o/+v/+h; exempt, not WHOISing"
            return
        }

        if {[is_exempt $nick $chan]} {
            putlog "\[guard\] skipping WHOIS for $nick on $chan (trusted handle)"
            return
        }

        queue_whois $nick $chan $uhost
    }

    # --- WHOIS pacing ---------------------------------------------------

    # Add $chan to a channel list without duplicating it (case-folded).
    proc chanlist_add {chans chan} {
        set c [casefold $chan]
        foreach existing $chans {
            if {[casefold $existing] eq $c} { return $chans }
        }
        lappend chans $chan
        return $chans
    }

    proc queue_whois {nick chan uhost} {
        variable whois_queue
        variable max_whois_queue
        variable whois_pending
        variable max_per_mask

        set k [casefold $nick]
        set hm [host_mask $uhost]

        # Already in flight. The triggering channel is ACCUMULATED rather
        # than dropped: this used to return early, so a user joining a
        # second watched channel mid-check was never checked there.
        #
        # Matched on the CURRENT nick (element 2) rather than on the array
        # key, because a rename updates element 2 and deliberately leaves
        # the key -- the nick the WHOIS actually went out under -- alone.
        # Looking up by key would miss a renamed user's in-flight check and
        # queue a duplicate WHOIS for them.
        set inflight ""
        foreach key [array names whois_pending] {
            if {[casefold [lindex $whois_pending($key) 2]] eq $k} {
                set inflight $key
                break
            }
        }
        if {$inflight ne ""} {
            set val $whois_pending($inflight)
            set whois_pending($inflight) [list \
                [chanlist_add [lindex $val 0] $chan] \
                [lindex $val 1] [lindex $val 2]]
            catch {state_save}
            return
        }

        # Already queued -- merge the channel into the existing entry.
        # (Plain loop rather than "lsearch -index 0" so this still works
        # on the older Tcl 8.4 some Eggdrop builds bundle.)
        set idx -1
        set i 0
        foreach item $whois_queue {
            if {[casefold [lindex $item 0]] eq $k} {
                set idx $i
                break
            }
            incr i
        }
        if {$idx >= 0} {
            set item [lindex $whois_queue $idx]
            set whois_queue [lreplace $whois_queue $idx $idx \
                [list [lindex $item 0] [chanlist_add [lindex $item 1] $chan] \
                      [lindex $item 2] [lindex $item 3]]]
            catch {state_save}
            return
        }

        # Per-host cap on the QUEUE as well as the pending table. Without
        # this, a clone flood fills a 500-deep FIFO drained at one entry
        # per whois_rate_secs and starves every other check behind it.
        if {$hm ne ""} {
            set n 0
            foreach item $whois_queue {
                if {[lindex $item 3] eq $hm} { incr n }
            }
            if {$n >= $max_per_mask} {
                putlog "\[guard\] $max_per_mask checks already queued for host mask $hm; not queueing $nick on $chan (one ban covers the host)"
                return
            }
        }

        if {[llength $whois_queue] >= $max_whois_queue} {
            putlog "\[guard\] whois queue full ($max_whois_queue deep); skipping check for $nick on $chan -- sustained join flood from many distinct hosts, investigate"
            return
        }

        lappend whois_queue [list $nick [list $chan] [unixtime] $hm]
        catch {state_save}
        schedule_pump
    }

    proc schedule_pump {} {
        variable whois_queue_timer
        variable whois_rate_secs

        if {$whois_queue_timer ne ""} { return }
        set whois_queue_timer [utimer $whois_rate_secs ::guard::pump_whois]
    }

    # Send at most one queued WHOIS, then reschedule if work remains.
    # This is what enforces the outgoing rate limit.
    proc pump_whois {} {
        variable whois_queue
        variable whois_queue_timer
        variable whois_pending
        variable max_whois_pending
        variable whois_timeout_secs
        variable whois_queue_max_age

        set whois_queue_timer ""

        set now [unixtime]
        set sent 0

        while {[llength $whois_queue] && !$sent} {
            # Tested BEFORE the dequeue, and it breaks rather than
            # continuing. The old test sat after the entry had already
            # been pulled off the queue and used continue, so reaching the
            # cap threw away every remaining entry inside a single tick --
            # one log line each -- instead of applying backpressure.
            # Breaking here leaves the queue intact and the reschedule
            # below re-arms, so entries either go out once a slot frees or
            # age out through whois_queue_max_age with their own log.
            if {[array size whois_pending] >= $max_whois_pending} {
                putlog "\[guard\] whois_pending full ($max_whois_pending); holding [llength $whois_queue] queued check(s) until a slot frees"
                break
            }

            set item [lindex $whois_queue 0]
            set whois_queue [lrange $whois_queue 1 end]

            set nick  [lindex $item 0]
            set chans [lindex $item 1]
            set when  [lindex $item 2]

            # Queue entries normally come from our own code, but state can
            # survive a rehash. Never feed an unvalidated timestamp to expr.
            if {![string is integer -strict $when]} {
                putlog "\[guard\] dropping malformed queued WHOIS for '$nick' (bad enqueue timestamp)"
                continue
            }

            # A check that has waited longer than whois_queue_max_age is
            # answering a question about a join that is now ancient.
            # Discard it loudly rather than pretending the queue is
            # keeping up.
            if {$when ne "" && ($now - $when) > $whois_queue_max_age} {
                putlog "\[guard\] discarding stale queued check for $nick ([expr {$now - $when}]s old, max $whois_queue_max_age) -- the WHOIS queue is not keeping up with join volume"
                continue
            }

            # The nick goes straight into a line handed to putserv. It
            # arrived off the wire, so it is checked rather than trusted.
            if {![irc_safe_nick $nick]} {
                putlog "\[guard\] refusing to WHOIS a malformed nick ('[string range $nick 0 31]'); dropping that check"
                continue
            }

            # Re-validate right before sending -- conditions change while
            # an entry waits its turn. Keep only the channels still valid.
            set live {}
            foreach c $chans {
                if {[validchan $c] && [onchan $nick $c] \
                        && ![has_status $nick $c] && ![is_exempt $nick $c]} {
                    lappend live $c
                }
            }
            if {![llength $live]} { continue }

            set k [casefold $nick]

            # Key-collision guard. whois_pending is keyed by the nick the
            # query went out under, and a rename deliberately leaves that
            # key alone (see carry_whois_nick). So an entry sitting on this
            # key whose element 2 no longer folds TO this key belongs to
            # someone who has renamed away from the nick we are about to
            # query -- meaning a DIFFERENT user now holds it. Overwriting
            # would kill the first user's correlation entry and its timeout
            # timer, voiding their check and mis-crediting their 319 to the
            # newcomer: a two-account evasion where a partner takes your
            # nick to clear your check. Put this one back at the head of
            # the queue instead; the stale entry is gone within
            # whois_timeout_secs at the latest, and this entry keeps its
            # original timestamp so it can still age out normally.
            if {[info exists whois_pending($k)]
                    && [casefold [lindex $whois_pending($k) 2]] ne $k} {
                putlog "\[guard\] a WHOIS sent under the nick '$nick' is still outstanding for a user who has since renamed away from it; holding the check for the current '$nick' rather than overwriting theirs"
                set whois_queue [linsert $whois_queue 0 $item]
                break
            }

            clear_whois_pending $nick
            set tid [utimer $whois_timeout_secs [list ::guard::whois_expire $k]]
            # Record the triggering channels; they are the only channels
            # enforcement may act on when the reply comes back.
            set whois_pending($k) [list $live $tid $nick]
            # Plain WHOIS, not "WHOIS nick nick" -- the two-argument
            # form is a server-routed remote query, throttled much
            # harder on most networks for no added benefit here.
            putserv "WHOIS $nick"
            set sent 1
        }

        catch {state_save}
        if {[llength $whois_queue]} { schedule_pump }
    }

    # Clears every piece of in-flight state for one casefolded key: the
    # main whois_pending correlation entry (and its timeout timer), the
    # 319-accumulation buffer, and the settle debounce timer (and its
    # timer). All three are always torn down together so none of them
    # can outlive the other two and leak.
    proc clear_whois_pending_key {k} {
        variable whois_pending
        variable whois_chanbuf
        variable whois_settle_timer

        if {[info exists whois_pending($k)]} {
            catch {killutimer [lindex $whois_pending($k) 1]}
            unset whois_pending($k)
        }
        if {[info exists whois_settle_timer($k)]} {
            catch {killutimer $whois_settle_timer($k)}
            unset whois_settle_timer($k)
        }
        catch {unset whois_chanbuf($k)}
        catch {state_save}
    }

    proc clear_whois_pending {nick} {
        clear_whois_pending_key [casefold $nick]
    }

    # Backstop cleanup if a reply never arrives (nick vanished between
    # request and reply, netsplit, etc). This is the ONLY cleanup path
    # besides a 319: binding 318 would let another script's WHOIS reply
    # clear an entry we are still waiting on, silently voiding the check.
    proc whois_expire {key} {
        clear_whois_pending_key $key
    }

    # The settle debounce fired: no further 319 line arrived within
    # whois_settle_secs of the last one seen, so the accumulated channel
    # list (checked as each line arrived -- see on_whois_channels) is
    # everything this WHOIS is going to tell us. target_channel was not
    # in it. Conclude "not found" and tear down.
    proc whois_settle {k} {
        clear_whois_pending_key $k
    }

    # ERR_NOSUCHNICK (401): "<ournick> <targetnick> :No such nick".
    # Unambiguous -- that nick does not exist, so drop the entry.
    proc on_nosuchnick {from keyword text} {
        if {[regexp {^\S+\s+(\S+)} $text -> nick]} {
            clear_whois_pending $nick
        }
    }

    # --- enforcement -----------------------------------------------------

    # Rolling budget so this script can never mass-ban a channel or
    # exhaust its ban list, however many hits arrive at once.
    #
    # Split into a pure check and an explicit record: the old combined
    # version appended to the window as a side effect of being ASKED, so
    # a ban that then failed still burned one of max_bans_per_window.
    #
    # The window survives a rehash (see restore_state): resetting it on
    # reload meant ".rehash" was a budget refill on demand.
    proc ban_budget_check {} {
        variable ban_times
        variable max_bans_per_window
        variable ban_window_secs

        set cutoff [expr {[unixtime] - $ban_window_secs}]
        set keep {}
        foreach t $ban_times {
            if {$t > $cutoff} { lappend keep $t }
        }
        set ban_times $keep

        return [expr {[llength $ban_times] < $max_bans_per_window}]
    }

    proc ban_budget_record {} {
        variable ban_times
        lappend ban_times [unixtime]
        catch {state_save}
    }

    # How many OTHER users currently on the channel this mask would hit.
    # This is the automatic, network-agnostic guard against banning a
    # whole shared gateway, vhost or NAT along with the offender.
    proc collateral_count {chan mask exclude_nick} {
        set n 0
        foreach u [chanlist $chan] {
            if {[casefold $u] eq [casefold $exclude_nick]} { continue }
            set uh [getchanhost $u $chan]
            if {$uh eq ""} { continue }
            if {[string match -nocase $mask "$u!$uh"]} { incr n }
        }
        return $n
    }

    proc ban_forbidden {mask host} {
        variable ban_never_masks
        foreach pat $ban_never_masks {
            if {[string match -nocase $pat $host]} { return 1 }
            if {[string match -nocase $pat $mask]} { return 1 }
        }
        return 0
    }

    # Strip status prefixes from a WHOIS channel token without eating a
    # leading "&" or "!", which are channel types as well as prefixes.
    # prefix_re is compiled and validated at load; the catch is a second
    # belt so a surprise here degrades to "no prefix stripped" instead of
    # throwing out of the raw bind and killing the whole 319 handler.
    proc strip_prefix {tok} {
        variable prefix_re
        if {[catch {regexp $prefix_re $tok -> bare} ok]} { return $tok }
        if {$ok} { return $bare }
        return $tok
    }

    # --- ban bookkeeping (so bans can be listed and removed) -------------

    # NOTE: no quotes around the element name. In Tcl a quote that is not
    # the first character of a word is a literal character, so
    # our_bans("$chan,$mask") would key on a name with quote marks in it
    # and ban_forget would never find what ban_record wrote. Everything
    # between the first ( and the last ) is already the element name.
    proc ban_key {chan mask} {
        return "[casefold $chan],$mask"
    }

    proc ban_record {chan mask method} {
        variable our_bans
        variable ban_lifetime_mins
        set our_bans([ban_key $chan $mask]) \
            [list $chan $mask [unixtime] $method $ban_lifetime_mins]
        catch {state_save}
    }

    # The lifetime a record was SET with, not the currently configured
    # one. our_bans outlives the config across a rehash, so measuring an
    # old record against a newly-lowered ban_lifetime_mins used to drop
    # records for bans that were still in force -- leaving them unlistable
    # and unliftable by command, which is the exact failure the record
    # exists to prevent. Records written before the field existed fall
    # back to the current value, which is the old behavior for them.
    proc ban_lifetime_of {v} {
        variable ban_lifetime_mins
        if {[llength $v] >= 5} {
            set l [lindex $v 4]
            if {[string is integer -strict $l] && $l > 0} { return $l }
        }
        return $ban_lifetime_mins
    }

    proc ban_forget {chan mask} {
        variable our_bans
        catch {unset our_bans([ban_key $chan $mask])}
        catch {state_save}
    }

    # Remove a ban this script set: killchanban takes it out of the bot's
    # channel ban list (without which Eggdrop simply re-enforces it after
    # any manual -b), and the explicit pushmode takes it off the channel.
    # Both are attempted regardless of how the ban was originally set.
    #
    # A killchanban failure is NOT counted against the return value: the
    # ban may legitimately never have been in the bot's list at all (the
    # pushmode fallback path in enforce), and reporting that as a failed
    # removal was misleading -- the -b is what actually lifts it.
    proc remove_ban {chan mask} {
        set ok 1
        if {[catch {killchanban $chan $mask} err]} {
            putlog "\[guard\] killchanban $chan $mask: $err (expected if this was a pushmode-fallback ban)"
        }
        if {[catch {pushmode $chan -b $mask} err2]} {
            putlog "\[guard\] pushmode -b failed for $mask on $chan: $err2"
            set ok 0
        }
        catch {flushmode $chan}
        ban_forget $chan $mask
        putlog "\[guard\] removed ban $mask on $chan"
        return $ok
    }

    # Forget records for bans that have already aged out on their own, so
    # the list stays a useful picture of what is actually in force. The
    # 300s pad keeps a record slightly past its nominal expiry so a ban
    # the server has not dropped yet is still listable.
    proc expire_our_bans {} {
        variable our_bans

        set now [unixtime]
        set changed 0
        foreach {k v} [array get our_bans] {
            set when [lindex $v 2]
            if {![string is integer -strict $when]} {
                unset our_bans($k)
                set changed 1
                continue
            }
            if {($now - $when) > (([ban_lifetime_of $v] * 60) + 300)} {
                unset our_bans($k)
                set changed 1
            }
        }
        if {$changed} { catch {state_save} }
    }

    proc ban_list {{chan ""}} {
        variable our_bans
        catch {expire_our_bans}
        set out {}
        foreach {k v} [array get our_bans] {
            if {$chan ne "" && [casefold [lindex $v 0]] ne [casefold $chan]} { continue }
            lappend out $v
        }
        return $out
    }

    # Is this exact mask one this script set on this channel? Masks are
    # compared case-insensitively: the mask that comes back on a mode
    # change is echoed by the server and need not match our casing.
    proc ban_ours {chan mask} {
        variable our_bans
        set c [casefold $chan]
        foreach {k v} [array get our_bans] {
            if {[casefold [lindex $v 0]] eq $c \
                    && [string equal -nocase [lindex $v 1] $mask]} {
                return [lindex $v 1]
            }
        }
        return ""
    }

    # Someone unset a ban by hand (any client, any op, ChanServ, another
    # bot -- this fires on the mode itself, not on a command). Take the
    # ban out of the bot's channel ban list so Eggdrop's own enforcement
    # does not put it straight back. Without this, a manual /mode -b on
    # one of these bans is undone within seconds and the only way to lift
    # one is a bot command.
    #
    # This fires for our own removals too (remove_ban pushes -b), which
    # is harmless: killchanban and ban_forget are both idempotent.
    proc on_mode_unban {nick uhost hand chan mode victim} {
        variable honor_manual_unban
        variable honor_manual_unban_foreign

        if {!$honor_manual_unban} { return }
        if {![channel_allowed $chan]} { return }

        set mask [string trim $victim]
        if {$mask eq ""} { return }

        set ours [ban_ours $chan $mask]
        if {$ours eq "" && !$honor_manual_unban_foreign} { return }
        if {$ours ne ""} { set mask $ours }

        # killchanban is the part that matters. The ban is already off
        # the channel -- this stops the bot from restoring it.
        if {[catch {killchanban $chan $mask} err]} {
            # Expected when the ban was set by the pushmode fallback and
            # never entered the bot's list; nothing to re-enforce then.
            putlog "\[guard\] killchanban $chan $mask after manual -b: $err"
        }
        ban_forget $chan $mask

        set who $nick
        if {$uhost ne ""} { set who "$nick!$uhost" }
        putlog "\[guard\] $who removed ban $mask on $chan by mode; dropped from the bot's ban list, it will not be re-added"
    }

    # RPL_WHOISCHANNELS (319).
    #
    # Not guaranteed to be one line: a nick in enough channels gets its
    # channel list split across several 319 replies so each line stays
    # under the server's length limit. Concluding "not found" (or even
    # just clearing our state) after only the first line means a long
    # enough channel list can push target_channel onto a line that is
    # never looked at -- pad your join count and evade the check. So:
    # accumulate every line seen for this nick, check the full buffer
    # each time, and only give up on "not found" once a short settle
    # window has passed with no further line arriving. A real hit is
    # still acted on the instant it's seen, with no added delay.
    proc on_whois_channels {from keyword text} {
        variable target_channel
        variable whois_pending
        variable whois_chanbuf
        variable whois_settle_timer
        variable whois_settle_secs
        variable max_chanbuf_bytes

        # Raw format: "<ourbotnick> <queriednick> :chan1 chan2 chan3 ..."
        # The first token is OUR nick (the recipient of the numeric), not
        # the nick being described -- it must be skipped, not captured.
        if {![regexp {^\S+\s+(\S+)\s+:?(.*)$} $text -> nick chanlist]} {
            return
        }

        # Act only on a WHOIS this script requested. Any other 319 the
        # bot happens to see for a nick we are NOT checking is ignored.
        #
        # The key is the nick the query was SENT under, which is what the
        # server answers with. Enforcement, though, has to act on whatever
        # the user is called NOW: see carry_whois_nick, where a rename
        # between query and reply updates element 2 and leaves the key
        # alone. Acting on the nick out of the reply text (what this used
        # to do) meant a renamed user's kick targeted a nick that was no
        # longer on the channel, and the check evaporated silently.
        set k [casefold $nick]
        if {![info exists whois_pending($k)]} { return }
        set entry $whois_pending($k)
        set chans [lindex $entry 0]
        set who [lindex $entry 2]

        # The accumulated text is entirely server-supplied and every line
        # pushes the settle deadline back, so the buffer is capped. Going
        # over cannot produce a false ban -- a match is acted on the
        # moment it is seen -- so the cap only bounds how much text we
        # will hold while waiting.
        if {![info exists whois_chanbuf($k)]} {
            set whois_chanbuf($k) $chanlist
        } elseif {[string length $whois_chanbuf($k)] < $max_chanbuf_bytes} {
            append whois_chanbuf($k) " " $chanlist
        } else {
            putlog "\[guard\] 319 channel list for $nick exceeded ${max_chanbuf_bytes}B; not accumulating further lines for this WHOIS"
        }

        # Whole-token match so "#TeenWankinTownHall" can't false-positive.
        # Compared with the same rfc1459 casefold used everywhere else.
        set found 0
        set want [casefold $target_channel]
        foreach tok [split $whois_chanbuf($k)] {
            if {$tok eq ""} { continue }
            if {[casefold [strip_prefix $tok]] eq $want} {
                set found 1
                break
            }
        }

        if {$found} {
            clear_whois_pending_key $k
            # Only the channel(s) whose join triggered this check, and
            # against the nick the user is using now, not the one queried.
            foreach chan $chans {
                catch {enforce $who $chan}
            }
            return
        }

        # Not found in anything seen so far -- but there may be another
        # 319 line still coming. Push the settle deadline back rather
        # than concluding now. Real continuation lines arrive back to
        # back; a single-line reply (the common case) still resolves
        # within whois_settle_secs instead of waiting out the full
        # whois_timeout_secs backstop.
        if {[info exists whois_settle_timer($k)]} {
            catch {killutimer $whois_settle_timer($k)}
        }
        set whois_settle_timer($k) [utimer $whois_settle_secs [list ::guard::whois_settle $k]]
    }

    proc enforce {nick chan} {
        variable target_channel
        variable kick_reason
        variable ban_lifetime_mins
        variable max_collateral

        if {![channel_allowed $chan]} { return }
        if {![validchan $chan]} { return }
        if {![onchan $nick $chan]} { return }

        # Re-check exemptions immediately before acting: the reply is
        # asynchronous and state may have moved since the request.
        if {[has_status $nick $chan]} {
            putlog "\[guard\] $nick on $chan matched $target_channel but now has +o/+v/+h; no action"
            return
        }
        if {[is_exempt $nick $chan]} {
            putlog "\[guard\] $nick on $chan matched $target_channel but is a trusted handle; no action"
            return
        }

        # Not a reason to stop -- Eggdrop will apply a recorded ban when
        # it is next opped -- but silently recording a ban and a kick that
        # cannot happen looks like the script did its job when it did not.
        if {![botisop $chan]} {
            putlog "\[guard\] not opped on $chan; the ban/kick for $nick will not take effect until the bot has ops"
        }

        set uhost [getchanhost $nick $chan]
        set p [split_uhost $uhost]
        set host ""
        if {[llength $p]} { set host [lindex $p 1] }
        set banmask [ban_mask $uhost]

        if {$host eq "" || $banmask eq ""} {
            # No safe, specific mask -- never fall back to a wildcard.
            # An empty or glob-bearing ident lands here rather than
            # widening the mask to the whole host.
            putlog "\[guard\] could not derive a safe mask for $nick on $chan (uhost='$uhost'); kicking only"
            catch {putkick $chan $nick $kick_reason}
            return
        }

        if {[ban_forbidden $banmask $host]} {
            putlog "\[guard\] $banmask matches ban_never_masks; kicking $nick from $chan without banning"
            catch {putkick $chan $nick $kick_reason}
            return
        }

        set others [collateral_count $chan $banmask $nick]
        if {$others > $max_collateral} {
            putlog "\[guard\] $banmask would also match $others other user(s) on $chan (shared host/gateway?); kicking $nick without banning"
            catch {putkick $chan $nick $kick_reason}
            return
        }

        if {![ban_budget_check]} {
            putlog "\[guard\] ban budget exhausted; kicking $nick from $chan without banning ($banmask). Possible coordinated join wave -- check the channel."
            catch {putkick $chan $nick $kick_reason}
            return
        }

        # Timed, tracked ban (visible to .bans and to ".guard bans",
        # expires on its own) rather than a raw permanent +b that
        # accumulates forever and can fill the channel's ban list.
        set banned 0
        if {[catch {newchanban $chan $banmask guard $kick_reason $ban_lifetime_mins} err]} {
            putlog "\[guard\] newchanban failed for $banmask on $chan: $err; falling back to pushmode"
            if {[catch {pushmode $chan +b $banmask} err2]} {
                putlog "\[guard\] pushmode also failed for $banmask on $chan: $err2"
            } else {
                # Record it anyway. A raw mode ban is invisible to .bans,
                # so without this record nothing could ever list or lift
                # it -- which is how bans became unremovable before.
                ban_record $chan $banmask pushmode
                set banned 1
            }
        } else {
            ban_record $chan $banmask newchanban
            set banned 1
        }

        if {$banned} { ban_budget_record }

        if {[catch {putkick $chan $nick $kick_reason} err]} {
            putlog "\[guard\] putkick failed for $nick on $chan: $err"
        }

        if {$banned} {
            putlog "\[guard\] banned/kicked $nick ($banmask) from $chan for ${ban_lifetime_mins}m (WHOIS listed $target_channel) -- lift early with /mode $chan -b $banmask, or .guard unban $chan $banmask"
        }
    }

    # --- operator commands: listing and removing bans --------------------

    proc fmt_ban {v} {
        set chan   [lindex $v 0]
        set mask   [lindex $v 1]
        set when   [lindex $v 2]
        set method [lindex $v 3]
        set life   [ban_lifetime_of $v]

        set age 0
        if {[string is integer -strict $when]} {
            set age [expr {([unixtime] - $when) / 60}]
        }
        set left [expr {$life - $age}]
        if {$left < 0} { set left 0 }
        return "$chan $mask (set ${age}m ago, ${left}m left, $method)"
    }

    # One line of listing output, to a partyline idx or to a channel user.
    # Written as an explicit two-way dispatch rather than a command prefix
    # plus {*} expansion, which Tcl 8.4 -- still bundled with some Eggdrop
    # builds -- does not have.
    proc emit_line {sink target line} {
        if {$sink eq "dcc"} {
            putdcc $target $line
        } else {
            puthelp "NOTICE $target :guard: $line"
        }
    }

    # Emit a ban listing, capped so a one-word command cannot turn a long
    # record set into a self-inflicted flood.
    proc emit_ban_list {sink target l} {
        variable max_ban_list_lines
        set n 0
        foreach v $l {
            if {$n >= $max_ban_list_lines} {
                emit_line $sink $target "... and [expr {[llength $l] - $n}] more (narrow it down by channel)"
                break
            }
            emit_line $sink $target "  [fmt_ban $v]"
            incr n
        }
    }

    # Partyline: .guard bans | .guard unban <chan> <mask> | .guard unbanall
    #            .guard status
    proc dcc_guard {hand idx text} {
        variable pending
        variable whois_queue
        variable whois_pending
        variable our_bans
        variable ban_times
        variable max_bans_per_window
        variable ban_window_secs

        set argv [split [string trim $text]]
        set cmd [string tolower [lindex $argv 0]]

        switch -- $cmd {
            bans {
                set chan [lindex $argv 1]
                set l [ban_list $chan]
                if {![llength $l]} {
                    set where "on record"
                    if {$chan ne ""} { set where "on record for $chan" }
                    putdcc $idx "guard: no bans $where."
                    return 0
                }
                putdcc $idx "guard: [llength $l] ban(s) on record:"
                emit_ban_list dcc $idx $l
                putdcc $idx "guard: remove with .guard unban <chan> <mask>"
            }
            unban {
                set chan [lindex $argv 1]
                set mask [lindex $argv 2]
                if {$chan eq "" || $mask eq ""} {
                    putdcc $idx "Usage: .guard unban <channel> <mask|glob|*>"
                    return 0
                }
                # killchanban/pushmode against a channel the bot does not
                # have will just error into the log; say so up front
                # instead.
                if {![validchan $chan]} {
                    putdcc $idx "guard: $chan is not a channel this bot is on."
                    return 0
                }
                set n 0
                foreach v [ban_list $chan] {
                    if {[string match -nocase $mask [lindex $v 1]]} {
                        remove_ban [lindex $v 0] [lindex $v 1]
                        putdcc $idx "guard: removed [lindex $v 1] on [lindex $v 0]"
                        incr n
                    }
                }
                if {!$n} {
                    # Not one of ours -- but an op asking to lift a ban
                    # should not have to care who set it. Pass it through
                    # if it is shaped like an actual ban mask
                    # (nick!user@host); refuse a bare search glob, which
                    # killchanban would not match anyway.
                    if {[string first "!" $mask] >= 0 && [string first "@" $mask] >= 0} {
                        remove_ban $chan $mask
                        putdcc $idx "guard: no record of $mask on $chan; sent killchanban and -b anyway"
                    } else {
                        putdcc $idx "guard: nothing on record matching $mask on $chan (give a full nick!user@host mask to remove a ban this script did not set)"
                    }
                }
            }
            unbanall {
                set n 0
                foreach v [ban_list] {
                    remove_ban [lindex $v 0] [lindex $v 1]
                    incr n
                }
                putdcc $idx "guard: removed $n ban(s)."
            }
            status {
                catch {ban_budget_check}
                putdcc $idx "guard status:"
                putdcc $idx "  pending join checks:   [array size pending]"
                putdcc $idx "  whois queue depth:     [llength $whois_queue]"
                putdcc $idx "  whois in flight:       [array size whois_pending]"
                putdcc $idx "  ban records held:      [array size our_bans]"
                putdcc $idx "  ban budget used:       [llength $ban_times]/$max_bans_per_window per ${ban_window_secs}s"
            }
            default {
                putdcc $idx "guard commands:"
                putdcc $idx "  .guard bans \[channel\]            list bans this script set"
                putdcc $idx "  .guard unban <channel> <mask>   remove one (mask may be a glob, or *)"
                putdcc $idx "  .guard unbanall                 remove every ban this script set"
                putdcc $idx "  .guard status                   queue/table/budget counters"
            }
        }
        return 0
    }

    # Per-nick throttle for the public help bind. That bind has to answer
    # unprivileged users -- it is help -- which made it the one place
    # anyone could make the bot emit several NOTICEs per line typed. The
    # table prunes itself on every call, so it cannot grow.
    proc help_throttled {nick} {
        variable help_last
        variable pub_help_cooldown

        set now [unixtime]
        foreach {k t} [array get help_last] {
            if {![string is integer -strict $t] || ($now - $t) > $pub_help_cooldown} {
                unset help_last($k)
            }
        }

        set k [casefold $nick]
        if {[info exists help_last($k)]} { return 1 }
        set help_last($k) $now
        return 0
    }

    # In-channel help. Intentionally separate from !guard so the help
    # command remains available even when pub_command_enabled is 0.
    #
    # Restricted to watched channels and throttled per nick: it was bound
    # -|- with no channel test, so anyone in any channel the bot sat in
    # could drive up to nine NOTICEs per line typed out of it. The
    # "options" topic is further restricted to channel ops -- publishing
    # check_delay and the watched channel list tells an evader exactly how
    # long they have to part the target channel before the WHOIS lands.
    proc pub_guardhelp {nick uhost hand chan text} {
        variable watch_channels
        variable target_channel
        variable check_delay
        variable ban_lifetime_mins
        variable max_bans_per_window
        variable ban_window_secs
        variable whois_rate_secs
        variable pub_command_enabled
        variable pub_command

        if {![channel_allowed $chan]} { return }
        if {[help_throttled $nick]} { return }

        set topic [string tolower [string trim $text]]

        switch -- $topic {
            commands {
                puthelp "NOTICE $nick :guard commands:"
                puthelp "NOTICE $nick :\x02!guardhelp\x02                 show this help"
                puthelp "NOTICE $nick :\x02!guardhelp commands\x02        show command usage"
                puthelp "NOTICE $nick :\x02!guardhelp options\x02         show current guard settings (channel ops)"
                if {$pub_command_enabled} {
                    puthelp "NOTICE $nick :\x02$pub_command bans\x02              list guard bans (channel ops)"
                    puthelp "NOTICE $nick :\x02$pub_command unban <mask>\x02      remove matching guard bans (channel ops)"
                } else {
                    puthelp "NOTICE $nick :in-channel guard commands are disabled on this bot"
                }
                puthelp "NOTICE $nick :Partyline: .guard bans | .guard unban <chan> <mask> | .guard unbanall | .guard status (bot operators)"
                puthelp "NOTICE $nick :A guard ban can also be lifted by any channel op with a plain /mode $chan -b <mask> -- it is not re-added."
            }
            options {
                if {![isop $nick $chan]} {
                    puthelp "NOTICE $nick :!guardhelp options is available to channel ops on a watched channel."
                    return
                }
                puthelp "NOTICE $nick :guard options:"
                set watch_desc [join $watch_channels]
                set watch_all 0
                foreach w $watch_channels {
                    if {[casefold [string trim $w]] eq "*" || [casefold [string trim $w]] eq "all"} {
                        set watch_all 1
                        break
                    }
                }
                if {$watch_all} { set watch_desc "all channels (*)" }
                puthelp "NOTICE $nick :watched channels: $watch_desc"
                puthelp "NOTICE $nick :target checked by WHOIS: $target_channel"
                puthelp "NOTICE $nick :WHOIS delay after join: ${check_delay}s"
                puthelp "NOTICE $nick :WHOIS pacing: 1 request every ${whois_rate_secs}s"
                puthelp "NOTICE $nick :ban lifetime: ${ban_lifetime_mins}m"
                puthelp "NOTICE $nick :ban budget: $max_bans_per_window ban(s) per ${ban_window_secs}s"
                puthelp "NOTICE $nick :in-channel $pub_command commands: [expr {$pub_command_enabled ? "enabled" : "disabled"}]"
                puthelp "NOTICE $nick :trusted/statused users are exempt from WHOIS checks"
                puthelp "NOTICE $nick :guard-owned ban records and the ban budget survive a full bot restart"
            }
            bans {
                if {![isop $nick $chan]} {
                    puthelp "NOTICE $nick :$pub_command bans is available to channel ops on a watched channel."
                    return
                }
                puthelp "NOTICE $nick :$pub_command bans - lists bans recorded by guard for $chan."
            }
            unban {
                if {![isop $nick $chan]} {
                    puthelp "NOTICE $nick :$pub_command unban is available to channel ops on a watched channel."
                    return
                }
                puthelp "NOTICE $nick :$pub_command unban <mask|glob|*> - removes matching guard bans on $chan."
                puthelp "NOTICE $nick :Or just /mode $chan -b <mask> - guard honors a manual unban and will not re-add it."
            }
            "" {
                puthelp "NOTICE $nick :guard help: \x02!guardhelp\x02 commands | \x02!guardhelp\x02 options | \x02!guardhelp\x02 bans | \x02!guardhelp\x02 unban"
                puthelp "NOTICE $nick :Guard watches joins, waits before WHOIS, and bans/kicks only when the target channel is found."
            }
            default {
                puthelp "NOTICE $nick :Unknown help topic. Topics: \x02commands\x02, \x02options\x02, \x02bans\x02, \x02unban\x02 -- or \x02!guardhelp\x02 on its own."
            }
        }
    }

    # In-channel: !guard bans | !guard unban <mask>   (channel ops only)
    proc pub_guard {nick uhost hand chan text} {
        variable pub_command_enabled
        variable pub_command

        if {!$pub_command_enabled} { return }
        if {![channel_allowed $chan]} { return }
        if {![isop $nick $chan]} { return }

        set argv [split [string trim $text]]
        set cmd [string tolower [lindex $argv 0]]

        switch -- $cmd {
            bans {
                set l [ban_list $chan]
                if {![llength $l]} {
                    puthelp "NOTICE $nick :guard: no bans on record for $chan."
                    return
                }
                puthelp "NOTICE $nick :guard: [llength $l] ban(s) on record for $chan:"
                emit_ban_list notice $nick $l
            }
            unban {
                set mask [lindex $argv 1]
                if {$mask eq ""} {
                    puthelp "NOTICE $nick :Usage: $pub_command unban <mask|glob|*>"
                    return
                }
                set n 0
                foreach v [ban_list $chan] {
                    if {[string match -nocase $mask [lindex $v 1]]} {
                        remove_ban [lindex $v 0] [lindex $v 1]
                        incr n
                    }
                }
                puthelp "NOTICE $nick :guard: removed $n ban(s) matching $mask on $chan."
                putlog "\[guard\] $nick ($uhost) removed $n ban(s) matching $mask on $chan"
            }
            default {
                puthelp "NOTICE $nick :guard: $pub_command bans | $pub_command unban <mask>"
            }
        }
    }

    # --- state carried across a rehash -----------------------------------
    #
    # Runs at the very bottom, once every helper above exists. Everything
    # it touches was left in place by the cleanup block at the top rather
    # than being cleared, because dropping it meant a reload was a free
    # pass for every check in flight and a refill of the ban budget.
    #
    # Nothing here is trusted just because it was already in the array:
    # entries are validated against the CURRENT tuple format, so a rehash
    # from an older version of this file drops the entries it cannot read
    # instead of misindexing them. mask_count is rebuilt from pending from
    # scratch, so the two cannot drift apart across the reload.
    proc state_path {} {
        variable state_file
        return [file normalize $state_file]
    }

    # Every join, rename, queue change and WHOIS reply used to call this
    # directly, rewriting the WHOLE file (up to max_pending + max_whois_queue
    # entries) each time -- so a join flood became a full file rewrite per
    # join, in the bot's single event loop. Now it only marks the state
    # dirty; one write happens state_save_delay seconds later, and the
    # lifecycle events (rehash/restart/die) write immediately.
    variable state_save_timer
    if {![info exists state_save_timer]} { set state_save_timer "" }
    set state_save_delay 5

    proc state_save {} {
        variable state_save_timer
        variable state_save_delay
        if {$state_save_timer ne ""} { return 1 }
        set state_save_timer [utimer $state_save_delay ::guard::state_flush]
        return 1
    }

    proc state_flush {} {
        variable state_save_timer
        if {$state_save_timer ne ""} {
            catch {killutimer $state_save_timer}
            set state_save_timer ""
        }
        return [state_write]
    }

    proc state_write {} {
        variable our_bans
        variable ban_times
        variable state_file
        variable state_version
        variable pending
        variable pending_fields
        variable whois_queue
        variable whois_queue_fields
        variable whois_pending

        set path [state_path]
        set dir [file dirname $path]
        if {[catch {
            if {![file isdirectory $dir]} { file mkdir $dir }
            set tmp "${path}.tmp.[pid]"
            # EXCL + 0600 from creation: a plain TRUNC open follows a
            # symlink planted at the predictable temp name.
            catch {file delete -- $tmp}
            set fh [open $tmp {WRONLY CREAT EXCL} 0600]
            fconfigure $fh -translation lf -encoding utf-8
            puts $fh [list GUARD_STATE $state_version]
            foreach {k v} [array get our_bans] {
                # Only serialize well-formed script-owned records.
                if {[catch {llength $v} n] || $n < 4} { continue }
                puts $fh [list BAN $k $v]
            }
            foreach t $ban_times {
                if {[string is integer -strict $t]} { puts $fh [list TIME $t] }
            }
            foreach {pk pv} [array get pending] {
                if {[catch {llength $pv} pn] || $pn != $pending_fields} { continue }
                if {![string is integer -strict [lindex $pv 1]]} { continue }
                puts $fh [list PEND $pk $pv]
            }
            foreach qv $whois_queue {
                if {[catch {llength $qv} qn] || $qn != $whois_queue_fields} { continue }
                puts $fh [list QUEUE $qv]
            }
            # In-flight WHOISes are saved as queue entries for their CURRENT
            # nick. A restart drops the query and its reply, so without this
            # anyone whose WHOIS was out at that moment was never checked.
            set qnow [unixtime]
            foreach {wk wv} [array get whois_pending] {
                if {[catch {llength $wv} wn] || $wn < 3} { continue }
                set wnick [lindex $wv 2]
                if {![irc_safe_nick $wnick] || ![llength [lindex $wv 0]]} { continue }
                puts $fh [list QUEUE [list $wnick [lindex $wv 0] $qnow ""]]
            }
            close $fh
            catch {file attributes $tmp -permissions 0600}
            file rename -force $tmp $path
        } err]} {
            catch {close $fh}
            catch {file delete -force $tmp}
            putlog "\[guard\] state save failed: $err"
            return 0
        }
        return 1
    }

    proc state_load {} {
        variable our_bans
        variable ban_times
        variable state_loaded
        variable state_version
        variable state_file
        variable pending
        variable pending_fields
        variable whois_queue
        variable whois_queue_fields

        if {$state_loaded} { return }
        set state_loaded 1
        set path [state_path]
        if {![file exists $path]} { return }

        if {[catch {
            # lstat: refuse a symlink or a FIFO (which would block the open).
            if {[file type $path] ne "file"} { error "state file is not a regular file" }
            if {[file size $path] > 8388608} { error "state file exceeds 8 MiB safety limit" }
            set fh [open $path {RDONLY NONBLOCK}]
            fconfigure $fh -blocking 1
            fconfigure $fh -translation lf -encoding utf-8
            set lines [split [read $fh] "\n"]
            close $fh
            set good 0
            set loaded_bans {}
            set loaded_pending {}
            set loaded_queue {}
            set loaded_times {}
            foreach line $lines {
                if {$line eq ""} { continue }
                # Each state line was written with Tcl [list], so keep it
                # as a Tcl list.  Plain split would destroy the nested BAN
                # record at its spaces and silently truncate loaded state.
                if {[catch {llength $line} parts_n] || !$parts_n} { continue }
                set parts $line
                set tag [lindex $parts 0]
                if {$tag eq "GUARD_STATE" && [lindex $parts 1] == $state_version} {
                    set good 1
                } elseif {$tag eq "BAN" && [llength $parts] >= 3} {
                    set key [lindex $parts 1]
                    set val [lindex $parts 2]
                    if {[catch {llength $val} n] || $n < 4} { continue }
                    set when [lindex $val 2]
                    if {![string is integer -strict $when]} { continue }
                    lappend loaded_bans [list $key $val]
                } elseif {$tag eq "PEND" && [llength $parts] >= 3} {
                    set pk [lindex $parts 1]
                    set pv [lindex $parts 2]
                    if {[catch {llength $pv} pn] || $pn != $pending_fields} { continue }
                    if {![string is integer -strict [lindex $pv 1]]} { continue }
                    lappend loaded_pending [list $pk $pv]
                } elseif {$tag eq "QUEUE" && [llength $parts] >= 2} {
                    set qv [lindex $parts 1]
                    if {[catch {llength $qv} qn] || $qn != $whois_queue_fields} { continue }
                    lappend loaded_queue $qv
                } elseif {$tag eq "TIME" && [string is integer -strict [lindex $parts 1]]} {
                    lappend loaded_times [lindex $parts 1]
                }
            }
            if {!$good} { error "invalid or incompatible state header" }
            array unset our_bans
            array set our_bans {}
            foreach pair $loaded_bans {
                set our_bans([lindex $pair 0]) [lindex $pair 1]
            }
            array unset pending
            array set pending {}
            foreach pair $loaded_pending {
                set pending([lindex $pair 0]) [lindex $pair 1]
            }
            set whois_queue $loaded_queue
            set ban_times $loaded_times
        } err]} {
            catch {close $fh}
            putlog "\[guard\] state load failed; ignoring state file: $err"
            array unset our_bans
            array set our_bans {}
            array unset pending
            array set pending {}
            set whois_queue {}
            set ban_times {}
        }
    }

    # Writes now (not debounced). Returns 0: an evnt handler returning 1
    # tells Eggdrop to skip its own handling of a signal event.
    proc lifecycle_save {type} {
        catch {state_flush}
        return 0
    }

    proc restore_state {carry} {
        variable pending
        variable pending_fields
        variable mask_count
        variable whois_queue
        variable whois_queue_fields
        variable max_whois_queue
        variable max_pending
        variable ban_times

        set now [unixtime]

        # --- pending: drop anything not in the current format ---
        set dropped 0
        foreach {key val} [array get pending] {
            # llength on a value that is not a well-formed list throws, so
            # the length test is the thing being caught here, not just
            # compared -- a corrupt entry must be dropped, not propagated
            # as an error out of the load.
            if {[catch {llength $val} n] || $n != $pending_fields
                    || ![string is integer -strict [lindex $val 1]]
                    || ![irc_safe_nick [lindex $val 2]]
                    || [lindex $val 3] eq ""
                    || ![channel_allowed [lindex $val 3]]} {
                unset pending($key)
                incr dropped
            }
        }
        if {$dropped} {
            putlog "\[guard\] dropped $dropped invalid pending check(s) from restored state"
        }

        # Never restore more than the configured memory guard.  A valid but
        # oversized state file must not bypass max_pending after a restart.
        set pkeys [array names pending]
        if {[llength $pkeys] > $max_pending} {
            set extra [expr {[llength $pkeys] - $max_pending}]
            foreach key [lrange $pkeys 0 [expr {$extra - 1}]] { unset pending($key) }
            putlog "\[guard\] trimmed $extra restored pending check(s) to max_pending=$max_pending"
        }

        # --- rebuild mask_count from pending so it cannot drift ---
        array unset mask_count
        array set mask_count {}
        foreach {key val} [array get pending] {
            set m [lindex $val 4]
            if {$m eq ""} { continue }
            if {[info exists mask_count($m)]} {
                incr mask_count($m)
            } else {
                set mask_count($m) 1
            }
        }

        # --- whois_queue: drop malformed entries ---
        set q {}
        foreach item $whois_queue {
            if {[catch {llength $item} n] || $n != $whois_queue_fields} { continue }
            if {![irc_safe_nick [lindex $item 0]]} { continue }
            if {[catch {llength [lindex $item 1]} cn] || !$cn} { continue }
            if {![string is integer -strict [lindex $item 2]]} { continue }

            # The stored host mask is accounting metadata, not a trusted
            # command argument. Rebuild it from the current channel host
            # where possible; if it is malformed, retaining a stale/broad
            # value could defeat the per-host queue cap.
            set hm [lindex $item 3]
            if {$hm ne "" && ![glob_safe $hm]} { set hm "" }
            lappend q [list [lindex $item 0] [lindex $item 1]                 [lindex $item 2] $hm]
        }
        set whois_queue $q
        if {[llength $whois_queue] > $max_whois_queue} {
            set dropped_q [expr {[llength $whois_queue] - $max_whois_queue}]
            set whois_queue [lrange $whois_queue 0 [expr {$max_whois_queue - 1}]]
            putlog "\[guard\] trimmed $dropped_q restored queued WHOIS(es) to max_whois_queue=$max_whois_queue"
        }

        # --- hand in-flight WHOISes back to the queue ---
        # Their timeout timers died with the reload, so they cannot stay
        # in flight; re-sending the query is the only way to finish the
        # check. The enqueue timestamp is NOW rather than the original, so
        # a reload does not immediately age them out -- the check_delay
        # has already been served by this point.
        set restored 0
        foreach c $carry {
            set nick  [lindex $c 0]
            set chans [lindex $c 1]
            if {![irc_safe_nick $nick]} { continue }
            if {![llength $chans]} { continue }

            set k [casefold $nick]
            set idx -1
            set i 0
            foreach item $whois_queue {
                if {[casefold [lindex $item 0]] eq $k} { set idx $i ; break }
                incr i
            }
            if {$idx >= 0} {
                set item [lindex $whois_queue $idx]
                set merged [lindex $item 1]
                foreach ch $chans { set merged [chanlist_add $merged $ch] }
                set whois_queue [lreplace $whois_queue $idx $idx \
                    [list [lindex $item 0] $merged [lindex $item 2] [lindex $item 3]]]
                continue
            }
            if {[llength $whois_queue] >= $max_whois_queue} { continue }

            set hm ""
            foreach ch $chans {
                set uh [getchanhost $nick $ch]
                if {$uh ne ""} { set hm [host_mask $uh] ; break }
            }
            lappend whois_queue [list $nick $chans $now $hm]
            incr restored
        }

        # --- ban budget window: sanity only; ban_budget_check prunes it
        # against the real window on every use.
        set keep {}
        foreach t $ban_times {
            if {[string is integer -strict $t] && $t <= $now} { lappend keep $t }
        }
        set ban_times $keep

        catch {expire_our_bans}

        if {[array size pending] || [llength $whois_queue] || $restored} {
            putlog "\[guard\] carried [array size pending] pending check(s) and [llength $whois_queue] queued WHOIS(es) across the reload ($restored re-queued from in flight)"
        }

        # Re-arm the timers the cleanup block killed, but only where
        # there is something for them to do. schedule_ban_expire always
        # runs: our_bans needs pruning whether or not anything joined.
        if {[array size pending]} { start_sweeper }
        if {[llength $whois_queue]} { schedule_pump }
        schedule_ban_expire
    }

    # --- binds ------------------------------------------------------------

    # Restore script-owned persistent state once per process.  Rehashes keep
    # the live arrays and therefore do not overwrite newer in-memory data.
    state_load

    catch {unbind join - * ::guard::on_join}
    catch {unbind nick - * ::guard::on_nick}
    catch {unbind part - * ::guard::on_part}
    catch {unbind sign - * ::guard::on_sign}
    catch {unbind kick - * ::guard::on_kick}
    catch {unbind raw - 319 ::guard::on_whois_channels}
    catch {unbind raw - 401 ::guard::on_nosuchnick}
    catch {unbind mode - "* -b" ::guard::on_mode_unban}
    catch {unbind dcc mn|- guard ::guard::dcc_guard}
    # Swept by PROC name, not by trigger. pub_command is a config value, so
    # an operator who renames the trigger and rehashes would otherwise
    # leave the OLD trigger bound for the life of the process: the unbind
    # below can only ever name the CURRENT value, which was never bound in
    # the first place. Every other bind in this block uses a literal
    # trigger that cannot drift, so this is the only one that needs it.
    if {![catch {binds pub} pubbinds]} {
        foreach b $pubbinds {
            if {[lindex $b 4] eq "::guard::pub_guard"} {
                catch {unbind pub [lindex $b 1] [lindex $b 2] [lindex $b 4]}
            }
        }
    }
    catch {unbind pub -|- $pub_command ::guard::pub_guard}
    catch {unbind pub -|- !guardhelp ::guard::pub_guardhelp}
    # Deliberately NOT bound: raw 318. See whois_expire.

    bind join - * ::guard::on_join
    bind nick - * ::guard::on_nick
    # Release the pending entry when the user leaves, so a stale check
    # cannot hold one of that host's max_per_mask slots against the next
    # real join. See drop_pending.
    bind part - * ::guard::on_part
    bind sign - * ::guard::on_sign
    bind kick - * ::guard::on_kick
    bind raw - 319 ::guard::on_whois_channels
    bind raw - 401 ::guard::on_nosuchnick
    # Fires on any -b in any channel, from any source (op, server,
    # services, another bot). channel_allowed filters inside the proc.
    bind mode - "* -b" ::guard::on_mode_unban
    bind dcc mn|- guard ::guard::dcc_guard
    foreach _ev {prerehash prerestart die sigterm sigquit} {
        catch {unbind evnt - $_ev ::guard::lifecycle_save}
        catch {bind evnt - $_ev ::guard::lifecycle_save}
    }
    unset -nocomplain _ev
    if {$pub_command_enabled} {
        bind pub -|- $pub_command ::guard::pub_guard
    }
    bind pub -|- !guardhelp ::guard::pub_guardhelp

    # Validate, re-queue and re-arm. Also (re)starts the independent
    # our_bans cleanup schedule.
    restore_state $_carry

    # The cleanup block at the top runs at namespace-eval level, not inside
    # a proc, so its scratch variables become real ::guard:: namespace
    # variables. Drop them rather than leave three stray names behind on
    # every load. _l and _n only exist if the carry loop ran at all.
    unset _carry
    catch {unset _l}
    catch {unset _n}
}

putlog "guard.tcl loaded: swept delayed checks, per-host capping, rate-limited WHOIS, collateral-checked timed bans. Pending and in-flight checks now survive a rehash. Bans can be lifted by anyone who can set channel modes -- a plain /mode -b sticks and is not re-added. Also: .guard bans / .guard unban <chan> <mask> / .guard status, or !guard in-channel for ops."
