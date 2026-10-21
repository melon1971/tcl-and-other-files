##############################################################################
# autorestrict.tcl -- Eggdrop script: channel +R after a kick
#
# Behavior:
#   - Ban-based triggering has been REMOVED (see item 30). This script no
#     longer looks at +b at all -- the only thing that can trigger a fresh
#     +R is a KICK. Two independent paths can report one (see item 34):
#       (a) a NATIVE kick on a managed channel, from a TRUSTED SOURCE (see
#           trusted_masks -- the actual kicker's nick!user@host); or
#       (b) a channel message/notice matching the phrase "has been kicked
#           from #chan" (kick_notice_regexp), from a TRUSTED SOURCE -- here
#           that gates who is trusted to SEND us that report, not any
#           kicker name that may appear inside its text.
#     Everything else is ignored completely and silently -- it will not
#     push +R.
#   - A qualifying kick (native or reported) turns on +R for the affected
#     channel, and starts a countdown to turn it back off (-R): normally
#     restrict_seconds (default 15 minutes), but ESCALATED to
#     escalate_seconds (default 45 minutes) if this report arrives within
#     escalate_window_seconds (default 10 minutes) of the last time -R
#     actually fired on that channel, whatever caused that -R. See item
#     32 below.
#   - If +R is already on for that channel, a qualifying kick does
#     NOTHING further -- it is never pushed twice, and (since ban-based
#     extension is gone) nothing restarts or extends the countdown once
#     it is running.
#   - ONLY a +R this script itself pushed (in response to a qualifying
#     kick) is timed for removal. See item 35 below. A +R set any other
#     way -- an op by hand, another script, however it got there -- is
#     left completely alone: no timer, no tracking, and this script never
#     touches it. It will never be set TWICE for the same episode: if a
#     countdown is already running for the channel, a fresh +R
#     notification does not start a second one.
#   - If a human (or another script/bot) removes +R manually before the
#     countdown finishes, the countdown is cancelled and +R is NOT put back
#     on its own. It only comes back the next time +R is set again.
#   - This script never pushes a redundant +R: it checks the channel's
#     live mode first and only sets +R if it is not already on.
#   - Channel users can ask !restricthelp (public, no flags required) to
#     see why the channel is +R, in plain language, with the current
#     numbers filled in. Ops keep .autorestrict on the partyline for
#     status/off/clear (master flag).
#
# Load with (in your eggdrop.conf):
#   source scripts/autorestrict.tcl
#
# ---------------------------------------------------------------------------
# Fixed in this pass
# ---------------------------------------------------------------------------
#   The root cause behind most of these: the script kept a private model of
#   the channel's mode and never once reconciled it against reality. It now
#   asks the channel (getchanmode) at every decision point, and tracks
#   whether the +R currently on is one IT set.
#
#   1. RE-SOURCING LEFT STALE STATE AND ORPHANED TIMERS.  "array set a {}"
#      is a merge, not a reset, and no pending timer was ever killed. On a
#      second source, active($chan) survived as 1, so trigger read
#      was_active as true and +R was NEVER SET AGAIN -- exactly the failure
#      the old comment said it was guarding against. The old utimer stayed
#      live and fired -R on the old schedule, and the stale timer id left
#      in timer_id() could later be handed to killutimer after Eggdrop had
#      recycled it, killing ANOTHER script's timer.  Timers are now killed
#      and the timer array is array unset; ownership and deadline are
#      deliberately KEPT across a reload and the countdown is re-armed from
#      the stored deadline (resync_all), so a reload no longer strands a +R
#      this script is responsible for.
#
#   2. +R COULD BE LEFT ON PERMANENTLY.  Three separate paths:
#        (a) expire pushed -R with no botonchan/botisop test and no retry,
#            so being deopped or split at the 45-minute mark silently lost
#            the mode change while the state was cleared anyway;
#        (b) a bot rejoin cancelled the pending -R and forgot the channel,
#            while the +R itself survived the bot's absence;
#        (c) nothing noticed the bot being deopped or leaving.
#      expire now verifies it can act, retries on retry_seconds while it
#      cannot, and keeps the deadline so a rejoin resumes it. on_join
#      reconciles against the real mode instead of wiping state. The
#      retry loop gives up only after max_overdue_secs, with a log line.
#
#   3. IT REMOVED A +R AN OPERATOR SET DELIBERATELY.  getchanmode was never
#      called and +R by another party was never noticed, so "was_active"
#      only ever reflected what this script did. An op's permanent +R,
#      followed by any kick, got a 45-minute countdown attached to it and
#      was then dropped. Ownership is now explicit: a +R this script did
#      not set is recorded as unowned and is never removed or timed.
#
#      NOTE: item 26 below (a later, deliberate behaviour change, not a
#      bug fix) temporarily superseded the "never removed or timed" half
#      of this, making any +R get timed for removal regardless of who set
#      it -- but item 35 (further below) reverted that half again, per a
#      later request: an operator's own +R is once more never removed or
#      timed. The fix in THIS item still stands for what it actually
#      guarded against: the countdown that removes it is not a byproduct
#      of some unrelated kick 45 minutes later, and a currently-running
#      countdown is never restarted just because another +R notification
#      comes in.
#
#   4. CHANNEL MATCHING WAS CASE-SENSITIVE.  lsearch -exact meant a server
#      presenting #Mafia against a configured #mafia silently did nothing
#      at all, and the per-channel arrays keyed on the raw string, so two
#      casings of one channel became two independent countdowns. Matching
#      and all state keys are now casefolded (rfc1459).
#
#   5. NO VERIFICATION THAT EITHER MODE TOOK.  pushmode calls are now
#      wrapped in catch, and ownership is only claimed once the +R is
#      actually queued.
#
#   6. force_restart EXTENDED THE COUNTDOWN WITHOUT RE-CHECKING OPS.  A ban
#      while +R was already on re-armed the timer with no test that the bot
#      could still lift it later. It now re-checks, and warns if it cannot.
#
#   7. ONLY THE FAILURE PATH WAS LOGGED.  Setting +R, extending it, and
#      lifting it are now all logged, with who triggered it and when it is
#      due off, so an op can tell why a channel went registered-only.
#
#   8. ANY SINGLE BAN BOUGHT 45 MINUTES, RENEWABLE WITHOUT LIMIT, including
#      by bans replayed by the server during a netjoin. Extensions are now
#      capped at max_total_secs from the moment +R first went on, and modes
#      coming from a server rather than a user are ignored
#      (ignore_server_modes).
#
#   9. on_kick FIRED WHEN THE BOT ITSELF WAS KICKED and logged once per
#      kick while unopped -- free log volume during a kick flood. Kicks of
#      the bot are ignored and the "cannot act" warning is rate limited per
#      channel (warn_cooldown).
#
#  10. $::botnick read directly instead of isbotnick (missing rfc1459 case
#      equivalence), and "bind mode - *" invoked the proc for every mode
#      change on every channel. Both tightened.
#
#  11. STATE DID NOT SURVIVE A REAL BOT RESTART (.restart / process
#      relaunch), only a re-source. "state" is a plain Tcl array, so a
#      full restart wiped it. The next kick/ban after a restart then saw
#      +R already on with owned=0 (nothing recorded it), treated it as an
#      operator's deliberate +R, and left it on forever with no timer --
#      the exact permanent-+R failure mode item 2/3 fixed for reloads,
#      just reachable via a different path. State is now mirrored to a
#      flat file (state_file) on every st_put/st_clear and reloaded from
#      it on a fresh interpreter (state array not yet existing), so
#      resync_all has something to re-arm from even after a hard restart.
#
#  12. DEAD CODE: an unbind for ::autorestrict::on_mode, a proc that has
#      never existed in this script (leftover from an earlier generic
#      "bind mode - *" design, superseded by the specific +b/+R/-R binds
#      below). It was a harmless no-op catch{}, but confusing; removed.
#
# ---------------------------------------------------------------------------
# Fixed in the pass after that
# ---------------------------------------------------------------------------
#  13. LEAKED utimers ON EVERY REJOIN. on_join armed `utimer 10 resync`
#      with nothing tracking or deduplicating it, so a flapping netsplit
#      queued one resync per rejoin -- and unlike the -R countdown these
#      ids were in no array, so the reload cleanup could not kill them
#      either. They are tracked per channel now, replaced rather than
#      stacked, and the (re)load sweep matches the CORE timer table by
#      command name (the same technique used for expire) instead of
#      trusting an in-namespace id table that a fresh interpreter does
#      not have.
#
#  14. A KICK FLOOD REWROTE THE STATE FILE ONCE PER KICK. st_put/st_clear
#      call st_save unconditionally, and trigger re-recorded "+R is not
#      ours" on every single kick while an operator's +R was up -- so a
#      flood turned into one temp-file-create + rename per kick. Both
#      accessors now no-op when nothing actually changed.
#
#  15. st_load TRUSTED THE STATE FILE COMPLETELY: no type check on the
#      path, an unbounded read, no validation of any field. A file the
#      bot writes is not automatically a file only the bot can write --
#      it sits in the working directory with a predictable name, which
#      is why st_save already defends against a planted symlink. The
#      read side now applies the same defenses as the write side, caps
#      what it reads, validates every field (channel shape, integer
#      ranges, sane deadlines), and drops bad records instead of
#      arming a countdown from them. A garbage deadline previously
#      defeated the max_overdue_secs give-up check outright.
#      st_load also leaked the file channel if [gets] errored mid-read.
#
#  16. NO CONFIG VALIDATION. restrict_seconds 0 (or a typo) armed an
#      instant-expiry loop; a negative retry_seconds or an empty
#      state_file path failed in stranger ways. All knobs are checked
#      at load and forced to their defaults with a log line.
#
#  17. THE LOAD BANNER HARDCODED "45 minutes" and the header docs
#      hardcoded the same, so editing restrict_seconds made the script
#      describe itself incorrectly. Both derive from the variable now.
#
#  18. NO WAY TO SEE WHAT IT WAS DOING. There was no command at all: an
#      op wondering why a channel was +R had only the log. Added
#      .autorestrict (master flag) with status/off/clear subcommands
#      and its own usage text.
#
#  19. BINDS WERE UNBOUND BY LITERAL VALUE, so editing a mask or flag
#      left the old bind live alongside the new one after a rehash.
#      What was actually registered is tracked and unbound instead.
#
#  21. REMOVING A CHANNEL FROM restrict_channels STRANDED ITS +R AND
#      LEAKED ITS RECORD. state survives a rehash by design and is
#      reloaded from disk after a restart, but resync -- the only thing
#      that ever revisits a stored record -- returned immediately for a
#      channel no longer in restrict_channels. So the record was never
#      armed, never cleared, and came back to the same early return on
#      every reload: a channel this script still held an owned +R on kept
#      it, with no countdown and nothing tracking it, and .autorestrict
#      status kept printing "ours, +R, due off in Nm" off a deadline no
#      timer would ever reach. resync now drops the record and logs which
#      case it was, loudly when the +R was ours, matching what the
#      max_overdue_secs give-up path already does.
#
#  22. THREE STRAY NAMESPACE VARIABLES. The (re)load timer sweep runs at
#      namespace-eval level, where `if` and `catch` create no scope, so
#      its loop variables k, v and u persisted as ::autorestrict::
#      namespace variables after every load. The bind block at the bottom
#      already unsets b and err for exactly this reason; these three were
#      missed.
#
#  20. from_server ONLY RECOGNISED an empty or "*" uhost. Eggdrop builds
#      differ in what they pass for a server-sourced mode; a server name
#      in $nick with no user handle is now also treated as one, so the
#      netjoin-replay defense (item 8) doesn't depend on which shape a
#      given build uses.
#
# ---------------------------------------------------------------------------
# Added after that (behaviour change, not a bug fix)
# ---------------------------------------------------------------------------
#  23. TRIGGER SOURCE IS NOW RESTRICTED (trusted_masks). Previously ANY
#      kick and ANY ban by anyone set the channel +R, so a single op
#      clearing out one troublemaker -- or any other bot in the channel
#      doing routine enforcement -- put the whole channel on
#      registered-only for 45 minutes. A kick/ban now only counts if the
#      source matches trusted_masks (default *!*@dal.ninja); everyone
#      else's is ignored silently, both for the initial +R and for the
#      ban-extends-the-countdown path.
#
#      This narrows what the script reacts to, so nothing that used to be
#      lifted can start being stranded by it: ownership, the countdown,
#      resync and the give-up path are untouched, and a +R already owned
#      still expires on schedule even if no further trusted event arrives.
#      Note it is a host match, not an Eggdrop user-flag check -- the bot
#      does not need the setter in its userfile.
#
#  24. ADDED !restricthelp, MERGED INTO THIS FILE RATHER THAN SHIPPED AS
#      ITS OWN SCRIPT. .autorestrict was DCC/master-only, so a channel
#      user hit with +R had no way to ask the bot anything about it --
#      only ops on the partyline could. !restricthelp (public, rate
#      limited, config-validated, rehash-safe -- same patterns as
#      masterhelp.tcl and the same bound-list tracking as the five binds
#      above) answers that in-channel: overview/trigger/ban/kick/scope/
#      manual topics, built fresh on every call straight from this
#      script's own restrict_seconds/max_total_secs/restrict_channels/
#      trusted_masks -- not a copy of those numbers, so editing one and
#      rehashing can never leave the help text describing stale behavior.
#      A cooldown sweep for its own rate-limit tables piggybacks on the
#      generic "kill every pending ::autorestrict::* utimer" reload sweep
#      already at the top of this file, so it needed no separate dedup
#      logic of its own.
#
#      If an earlier standalone restricthelp.tcl is still being sourced
#      alongside this one, REMOVE IT (or stop sourcing it) before loading
#      this version -- two scripts both binding "pub - !restricthelp"
#      means the trigger answers twice per use, against two independent
#      rate-limit tables, and only one of the two ever reads this
#      script's live config.
#
#  25. AUDIT PASS OVER THE HELP COMMAND ITSELF. Four defects, three of
#      them carried over from the standalone version:
#
#      (a) THE percmd COOLDOWN TABLE WAS KEYED ON A CONSTANT. cmd_help
#          passed $help_trigger as the "topic", so every call from one
#          user produced an identical key and help_last_percmd became a
#          byte-for-byte duplicate of help_last_global -- twice the
#          memory for zero extra throttling -- while the variable's own
#          comment advertised the key as "id,topic". Under scope
#          "percmd" it also meant the per-topic limit did not exist.
#
#      (b) FIXING (a) NAIVELY WOULD HAVE BEEN WORSE. The topic comes
#          straight from the user, so keying on it raw lets
#          "!restricthelp <4kb of junk>", repeated with fresh junk each
#          time, mint unlimited distinct multi-kilobyte array keys --
#          precisely the attack help_id already caps nick and host
#          against. Unrecognised topics now collapse into one shared
#          bucket, bounding a user's key count by the topic list.
#
#      (c) NO channel_allowed GATE. It was the only bind here without
#          one, so it answered in every channel the bot sits in and told
#          people in unmanaged channels that "this channel" goes +R,
#          naming a managed scope belonging to some other channel.
#
#      (d) THE TARGET OF A REPLY WAS UNSANITIZED while its text was.
#          pub_safe strips control bytes but leaves spaces, which is
#          correct for a message body and wrong for a target: a space
#          there splits "$verb $target :$text" into a different IRC
#          command. Targets now go through pub_target instead.
#
#      Ordering matters in the fix for (c): the rate-limit check runs
#      BEFORE the not-managed-here reply, not after. The obvious
#      arrangement -- bail out early on an unmanaged channel -- would
#      have left that one reply path unthrottled in exactly the channels
#      where anyone could hold down the trigger.
#
#  26. ANY +R NOW STARTS THE REMOVAL COUNTDOWN, NOT JUST ONE THIS SCRIPT
#      SET ITSELF. Items 3/23 above deliberately made this script leave
#      an operator's (or anyone else's) +R alone forever. In practice
#      that meant a manually-set +R -- or one set by another script, or
#      seen already on join -- never came back off on its own, which
#      turned out not to be what was wanted: the request is for +R on a
#      managed channel to ALWAYS be temporary, regardless of who set it,
#      while the TRIGGER (what causes a fresh +R to go on, and what
#      restarts an already-running countdown) stays restricted to
#      trusted_masks exactly as before.
#
#      What changed, concretely:
#        - on_mode_restrict_on (the confirmed +R echo) now claims and
#          times ANY +R it did not itself just push, instead of recording
#          it as "not ours, leave alone". It only skips doing this if a
#          countdown is ALREADY running for that channel -- so a trusted
#          ban's own +R-then-extend sequence, or two +R notifications
#          arriving close together, never starts a second, overlapping
#          countdown.
#        - resync (join / reload reconciliation) does the same: +R found
#          on the channel with nothing tracking it gets claimed and timed
#          from now, rather than being left permanently alone.
#        - trigger()'s "already +R but nothing tracked it yet" edge case
#          (which should now be rare, since the two paths above claim it
#          first) also claims and times it rather than leaving it alone,
#          for the same reason.
#        - Untouched: what causes trigger() to PUSH a fresh +R (a trusted
#          kick or ban), what RESTARTS an already-running countdown (a
#          fresh trusted ban only), the "never push +R if already on"
#          check, the "never push -R unless the live mode is actually on"
#          check in expire, and the max_total_secs cap.
#        - .autorestrict status/help, !restricthelp's text, and the load
#          banner are updated to describe this rather than the old
#          "never removed" behaviour, so nobody reads stale docs.
#
#      NOTE: item 35 (further below) reverts this item's claiming behaviour
#      again, per a later request -- a +R this script did not push itself
#      is back to never being claimed or timed, on all three paths listed
#      above. This item's description is kept as a historical record of
#      what changed and why at the time.
#
#  27. REMOVED THE trigger_delay_seconds DELAY BEFORE PUSHING +R (was
#      inconsistently 0 by default but silently forced to 3 on any
#      invalid value). Per request, a trusted kick/ban now decides
#      whether to push +R immediately, with no artificial wait -- it
#      still checks the channel's LIVE mode first via chan_has_mode and
#      only pushes +R if that check shows it is not already on, so this
#      does not reopen the double-+R problem the delay was never actually
#      needed to prevent (that race was already closed unconditionally by
#      the pending() flag in trigger(), delay or no delay -- see that
#      comment). trigger_delay_seconds is kept as a knob (default 0, and
#      now correctly forced back to 0 rather than 3 on an invalid value)
#      in case a real race against an external actor is ever observed,
#      but it no longer runs by default.
#
#  28. `.autorestrict off` COULD STRAND +R. It cancelled the only -R timer
#      before pushmode, then returned immediately on a pushmode error. That
#      left state owned=1 but no timer, so status still showed a countdown
#      while nothing could ever reach expire(). It also cleared state
#      immediately after a successful queue, even though pushmode returning
#      only means the MODE was queued, not that the server confirmed it.
#      The off path now keeps ownership until -R is actually observed,
#      retries failed queue attempts, and schedules an immediate confirmation
#      check after a successful queue. This preserves the same "never strand
#      a +R" invariant as expire(), including across deop/split/retry paths.
#
#  29. CONFIG/STATE HARDENING. restrict_channels is validated once at load
#      time (bad entries dropped, list bounded); help_trigger is constrained
#      to a safe single IRC token; oversized state files are rejected before
#      reading; and malformed in-memory state left over from a previous
#      source/revision is discarded instead of reaching timer/mode code.
#
# ---------------------------------------------------------------------------
# Added after that (deliberate behaviour change: bans removed, per request)
# ---------------------------------------------------------------------------
#  30. BAN-BASED TRIGGERING REMOVED ENTIRELY. Per request, this script no
#      longer reacts to +b in any way. Removed outright:
#        - on_mode_ban and its "bind mode - * +b" registration.
#        - max_total_secs (the extension-cap knob) and its validation --
#          it existed solely to bound repeated ban-driven extensions, which
#          no longer happen.
#        - ignore_server_modes / from_server -- these existed solely to stop
#          a netjoin replaying old +b's from extending the countdown, which
#          is no longer a code path at all.
#        - trigger_delay_seconds / schedule_trigger -- these existed solely
#          to avoid a race between on_kick and on_mode_ban firing in the
#          same event tick. With only one trigger source left, that race
#          cannot happen, so the delay machinery is gone rather than kept
#          as dead config.
#        - trigger()'s $force_restart parameter and its whole
#          countdown-restart/extend branch. Item 26's "claim an untracked
#          +R" behaviour is UNCHANGED and kept (it is not ban-specific --
#          see the header bullet on it above) but trigger() now does
#          nothing at all, on purpose, when +R is already on AND already
#          timed: no restart, no extension, no re-log, matching the
#          request that an already-set +R is never set (or touched) again.
#
#  31. THE NATIVE "bind kick" EVENT WAS REMOVED AS A TRIGGER, THEN
#      RESTORED (see item 34). This item originally replaced on_kick with
#      a specific TEXT match: a channel message or notice containing the
#      phrase "has been kicked from #chan" (kick_notice_regexp, NOT
#      anchored to the whole line -- see that variable's comment), watched
#      via bind pubm and/or bind notc per kick_notice_watch_pubm/
#      kick_notice_watch_notc. The target channel (the one that gets +R)
#      is parsed OUT OF THE MESSAGE TEXT, not taken from where the message
#      was posted -- this is what lets a central kick-log/relay channel
#      restrict a DIFFERENT channel than the one the report was seen in.
#
#      That text-matching path is still here and still works exactly as
#      described, for anyone who does have such a relay. But nothing about
#      this network actually posts that phrase as a channel message or
#      notice -- "has been kicked from #chan" only ever appears as an IRC
#      CLIENT'S OWN DISPLAY of the native KICK command, which this script
#      never saw at all once this item removed "bind kick". The upshot:
#      with only the text-matching path, this script could never trigger
#      on a real kick on this network -- see item 34, which restores a
#      native trigger alongside this one.
#
#      Trust for a matching TEXT message is anchored to whoever actually
#      SENT that message (checked against trusted_masks) -- NOT to any
#      kicker name that may appear inside the message text, which is just
#      free-form text as far as that path is concerned and must never be
#      trusted on its own: anyone who can talk in a channel/notice the bot
#      hears could type a lookalike line otherwise. If trusted_masks is
#      meant to authorize a specific operator for the text path, it must
#      therefore list the mask of whatever actually POSTS these kick
#      reports (a services pseudo-client, a relay bot, etc.), not
#      necessarily that operator's own hostmask, unless their own client
#      is what sends the report text directly.
#
#  32. ESCALATING DURATION, PER REQUEST. +R no longer always lasts the
#      same length of time. restrict_seconds (default 5m) is the normal
#      duration; if a qualifying kick report arrives within
#      escalate_window_seconds (default 10m) of the last time -R actually
#      fired on that channel, the fresh +R this time lasts
#      escalate_seconds (default 45m) instead. This tracks, per channel,
#      the unixtime of the last CONFIRMED -R (on_mode_restrict_off, which
#      fires for -R however it happened -- this script's own expire(), a
#      manual .autorestrict off, an op typing it by hand, anything) in a
#      new in-memory-only "last_off" array; trigger() consults it only in
#      the "+R is currently off, push a fresh one" branch -- claiming an
#      already-on, untracked +R (item 26) never escalates, since that is
#      not a kick report pushing anything.
#
#      last_off is deliberately NOT mirrored to state_file the way
#      "state" is: losing it across a real restart just means one
#      escalation window resets to normal, which is a far smaller
#      consequence than what state_file's persistence protects against
#      (a stranded +R). state_record_valid/st_load's "deadline can't be
#      absurdly far in the future" sanity bound is now measured against
#      whichever of restrict_seconds/escalate_seconds is larger, since an
#      escalated record's deadline legitimately sits further out than
#      restrict_seconds alone would allow.
#
# ---------------------------------------------------------------------------
# Audit pass (dead code / bugs / vulns / leaks / rehash-restart-array bugs)
# ---------------------------------------------------------------------------
#  33. Two defects found on a full read-through, neither previously flagged:
#        (a) st_load's "refusing state ... file is missing/unreadable or
#            larger than 256KiB" log line was missing its line-continuation
#            backslash, so it printed with a long run of literal spaces
#            baked into the string instead of the intended single space.
#            Cosmetic only -- it never affected which files were accepted
#            or rejected -- but a garbled log line is exactly the kind of
#            thing an op reads while trying to diagnose a real problem, so
#            it is fixed.
#        (b) last_off($c) (item 32) was never removed when resync() drops a
#            channel that has been taken out of restrict_channels -- state,
#            the timer and the resync record are all cleaned up on that
#            path, but last_off was not, so a config edit that shrinks
#            restrict_channels left one stale, never-reclaimed entry behind
#            per removed channel forever. Bounded (restrict_channels is
#            itself capped at 128 entries) and harmless on its own -- it
#            cannot strand a mode or affect any other channel's escalation
#            -- but it is a genuine small leak, so resync() now clears it
#            in the same place it already clears everything else for a
#            channel it no longer manages.
#      Everything else examined -- every array's init-once guard, every
#      bind's unbind-by-record handling, the symlink/size/type defenses on
#      both sides of state_file, the pending()/isbotnick double-+R guards,
#      the retry/give-up paths in expire() and dcc_cmd's off subcommand,
#      and the config validation block -- held up: no further dead code,
#      unbounded growth, or restart/rehash-unsafe state was found.
#
# ---------------------------------------------------------------------------
# Confirmed defect fix (this pass)
# ---------------------------------------------------------------------------
#  34. THE SCRIPT COULD NEVER ACTUALLY TRIGGER ON THIS NETWORK. Confirmed
#      directly: the "has been kicked from #chan" line item 31 relies on
#      is only ever produced by the reporter's own IRC CLIENT as its local
#      display of the native KICK command -- nothing posts that phrase as
#      an actual channel PRIVMSG/NOTICE the bot receives. Since item 31
#      also removed the native "bind kick" trigger, there was, in practice,
#      NO working trigger path at all: a real kick on a managed channel did
#      nothing, ever, regardless of who did the kicking.
#
#      Fix: restored a native "bind kick" trigger (on_native_kick), used
#      ALONGSIDE the existing text-matching path rather than instead of
#      it, so a future relay/log-bot setup (what item 31 was originally
#      for) still works unmodified. For a native kick, trust is anchored
#      to the ACTUAL KICKER's nick!user@host (Eggdrop's own kick bind
#      arguments), checked against trusted_masks exactly like the text
#      path checks a message's sender -- not to any name embedded in a
#      reason string. The bot's own kicks are ignored (isbotnick), the
#      same guard the old pre-item-31 on_kick had (see item 9). Both
#      paths funnel into the same trigger()/escalation/state machinery
#      unchanged: which source fired is irrelevant past that point.
#
# ---------------------------------------------------------------------------
# Deliberate behaviour change, per request (reverts part of item 26)
# ---------------------------------------------------------------------------
#  35. A +R THIS SCRIPT DID NOT PUSH ITSELF IS NEVER TIMED, PERIOD. Item 26
#      made ANY +R on a managed channel -- however it got there -- start a
#      removal countdown, on the reasoning that +R on a managed channel
#      should always be temporary. Per request, that is reverted: only a
#      +R this script's OWN pushmode call actually put on the channel is
#      tracked and timed for removal. A +R set any other way -- an op by
#      hand, another script, one already sitting on the channel at
#      (re)join/reload -- is left completely alone: no ownership claim, no
#      timer, no state record, and no log line beyond noting that it was
#      seen. This restores the item-3/23 behaviour for the "someone else's
#      +R" case specifically, while everything item 26 also touched that is
#      NOT about foreign +R -- escalation, the long-kicker duration, the
#      "never push twice" guard, -R always being logged via
#      on_mode_restrict_off -- is unchanged.
#
#      Concretely, four paths stopped claiming/timing untracked +R:
#        - on_mode_restrict_on's "unrelated +R" branch (an op/another
#          script sets +R with nothing of ours pending) -- no longer calls
#          st_put/arm_timer at all.
#        - on_mode_restrict_on's deferred-collision branch (someone else's
#          +R lands while this script's own push for a kick is being held
#          by push_delay_seconds) -- the held push is still cancelled (no
#          duplicate +R), but their +R is no longer adopted and timed; it
#          is simply left alone, same as any other foreign +R.
#        - deferred_fire's "already on when our push came due" branch --
#          same change: don't push a duplicate, and don't time theirs either.
#        - trigger()'s "already +R but nothing tracking it" branch and
#          resync()'s "+R found on (re)join/reload with nothing tracking
#          it" branch -- both now leave it alone instead of claiming it.
#      external_restrict_seconds (the 45m foreign-+R timeout this reverts)
#      is removed as dead config along with its validation, since nothing
#      reads it any more.
#
#      Untouched: a +R this script DID push itself (deferred_fire's success
#      path) is tracked and timed exactly as before, including escalation,
#      the long-kicker duration, and extend_to lengthening an
#      already-OWNED timer for a long-kicker kick. .autorestrict status
#      will now show more channels as "not tracked" whenever +R there was
#      set by something other than this script -- that is expected, not a
#      regression: ops can still remove it by hand (.mode $chan -R, or
#      .autorestrict off refuses with that same suggestion for an untracked
#      channel, as it always did).
##############################################################################

# ---------------------------------------------------------------------------
# Latest pass: duplicate +R race, dal.ninja kicks
# ---------------------------------------------------------------------------
#   - DUPLICATE +R: an op (zero) sets +R in the same second as the kick, but
#     the bot's live mode view cannot see it yet at kick time, so it pushed a
#     second +R right behind it. The push is now HELD push_delay_seconds and
#     the live mode is re-checked right before it goes out; a +R from someone
#     else arriving during the hold cancels ours (no duplicate) -- per item
#     35 above, theirs is no longer adopted and timed, just left alone.
#   - push_delay_seconds shortened 3 -> 1 (the enforced floor) at the user's
#     request, for a snappier +R after a qualifying kick. This narrows the
#     window described above: a hand-set +R whose echo arrives more than
#     ~1s after the kick will no longer be caught by the deferred($c) check
#     before this script's own push fires, so the two can land as two
#     separate, genuinely duplicate +R's on the wire in that case -- rarer
#     at 1s than at 3s, but not impossible. If duplicate +R's start showing
#     up in the log again, raise this back up.
#   - Kicks from long_kicker_masks (*!*@dal.ninja) always get
#     long_restrict_seconds (45m); if a shorter countdown is already running
#     it is lengthened (never shortened).
#   - A +R set by someone else that is not part of a kick we are handling is
#     no longer tracked or timed by this script at all (item 35).
#   - Escalation is unchanged: a kick within escalate_window_seconds of the
#     last -R is 45m, otherwise restrict_seconds (see below).
##############################################################################

# ---------------------------------------------------------------------------
# Config tuning, per request
# ---------------------------------------------------------------------------
#   - restrict_seconds (normal +R duration) raised 5m -> 15m (300 -> 900).
#     Its invalid-value fallback was raised to match, so a bad config value
#     forces the new default rather than reverting to the old one.
#   - push_delay_seconds' invalid-value fallback corrected 3 -> 1 to match
#     the enforced floor and the value actually in effect since the "Latest
#     pass" section above shortened it -- the fallback had been left at the
#     old default, so an out-of-range config value would have silently
#     landed back on 3s instead of the intended 1s.
##############################################################################

namespace eval ::autorestrict {

    # How long +R stays on after a NORMAL trigger, in seconds. 15 min = 900s.
    set restrict_seconds 900

    # If a qualifying kick report arrives within escalate_window_seconds
    # of the last time -R actually went back off on that channel, the
    # fresh +R this time lasts escalate_seconds instead of restrict_seconds
    # -- i.e. a kick shortly after the last restriction lifted is treated
    # as a sign of ongoing trouble and gets the long timeout. 10 min = 600s
    # window, 45 min = 2700s escalated duration, by default. This compares
    # against the last CONFIRMED -R (see on_mode_restrict_off), whatever
    # caused it (this script's own expire, an op's manual -R, whatever) --
    # not against when +R first went on.
    set escalate_window_seconds 600
    set escalate_seconds        2700

    # Kicks from these hosts are ALWAYS restricted for long_restrict_seconds
    # (default 45m), regardless of the restrict_seconds/escalation logic
    # above. Same
    # mask syntax as trusted_masks (matched against nick!user@host and the
    # bare user@host). Applies to native kicks only: for the text-report
    # path the sender is a relay, not the kicker.
    set long_kicker_masks {*!*@dal.ninja}
    set long_restrict_seconds 2700

    # (external_restrict_seconds removed, item 35: a +R someone else set is
    # never timed by this script at all any more, so there is no duration
    # to configure for it.)

    # After a qualifying kick the +R push is held back this many seconds
    # and the channel mode is re-checked right before it goes out. Ops
    # here set +R by hand within the same second as the kick, and the
    # bot's live mode view cannot see that +R yet at kick time -- pushing
    # immediately is what produced the duplicate "+R" by Fizbin right
    # after zero's own. If someone else's +R shows up during the wait the
    # push is cancelled (no duplicate) -- their +R is left alone, per
    # item 35.
    # Lowered to 1 (the floor enforced below) for a faster +R after a
    # kick; see "Latest pass" above for the tradeoff.
    set push_delay_seconds 1

    # Which channels this script manages. A LIST of channels limits it to
    # those (matched case-insensitively, rfc1459); an EMPTY list means
    # every channel the bot is on. The comment here used to describe the
    # empty-list behaviour while the value below was already a one-channel
    # list, which reads as though the default were bot-wide. It is not.
    set restrict_channels {#chan #chan}

    # WHO is allowed to TRIGGER a restriction -- that is, cause a fresh +R
    # to be pushed. For a native kick (item 34) this gates the ACTUAL
    # KICKER's nick!user@host. For a text-matched kick report (item 31)
    # this gates who is trusted to SEND us that report, NOT the kicker
    # named inside the message's text: that name is free-form text as far
    # as the text path is concerned and must never be trusted on its own --
    # anyone who can talk in a channel/notice the bot hears could type a
    # lookalike line otherwise. If these masks are meant to authorize a
    # specific operator for the text path, they must match whatever
    # actually POSTS the kick-report text (a services pseudo-client, a
    # relay/log bot, etc.) -- not necessarily that operator's own
    # hostmask, unless their own client is what sends the report directly.
    #
    # This is now (per item 35) the ONLY thing that decides whether a +R
    # ever gets timed for removal at all: only a +R this script itself
    # pushed, in response to a trigger from one of these masks, is timed.
    # An already-set +R from anyone else is never adopted or timed,
    # regardless of source.
    #
    # Each entry is a glob matched case-insensitively against BOTH
    # "nick!user@host" and the bare "user@host", so either shape works:
    #     *!~zero@dal.ninja      (full mask)
    #     ~zero@dal.ninja        (user@host only -- matches any nick)
    #     *!*@dal.ninja          (anyone from that host)
    # Note this is a literal host match, NOT an Eggdrop user-flag check:
    # it does not care whether the sender is a recognised bot user, only
    # that their host matches.
    #
    # An EMPTY list means "anyone's kick/report triggers it", which is how
    # this script behaved before this knob existed.
    #
    # Untrusted messages/kicks are ignored SILENTLY on purpose: logging
    # them would hand a flood of lookalike lines the same free log volume
    # that items 9 and 14 in the header exist to prevent.
    # ".autorestrict status" prints the configured masks so an op can
    # still tell why nothing fired.
    #
    # WORTH KNOWING: if identd ever starts answering on dal.ninja hosts,
    # the ident prefix may change (e.g. losing a leading "~"). If a trust
    # mask here stops matching after that, widen it rather than
    # collapsing to a bare "*", which would also match unrelated idents on
    # the same host and defeat the point of the setting.
    set trusted_masks {}

    # How often expire retries when it cannot act (bot deopped, split, off
    # the channel), and how long it keeps trying before giving up. "0
    # disables it" convention: expire's give-up check is only ever
    # `$max_overdue_secs > 0 && ...`, so 0 here does not mean "give up
    # immediately" -- it means never give up, and expire retries forever
    # every retry_seconds until it can act. Documented here because that
    # reading is the opposite of what "0" suggests at a glance.
    set retry_seconds 60
    set max_overdue_secs 86400   ;# 24h past the deadline; 0 = never give up

    # Minimum seconds between "cannot act on $chan" log lines per channel.
    set warn_cooldown 300

    # Where ownership/deadline state is mirrored to disk so it survives a
    # full bot restart, not just a re-source. Relative paths are relative
    # to the eggdrop process's working directory.
    set state_file "autorestrict.state"

    # --- kick-report detection (item 31, text path) ----------------------
    #
    # This is the OPTIONAL text-matching path, for a relay/log-bot setup.
    # It runs ALONGSIDE the native kick trigger (item 34, on_native_kick),
    # not instead of it. Every public channel message and/or notice the
    # bot sees (per the two watch flags below) is tested against this
    # regexp. The key phrase this keys off is literally "has been kicked
    # from #chan" -- deliberately NOT anchored to the start/end of the
    # line, so it still matches regardless of what a specific network's
    # notifier puts before or after that phrase (a timestamp, a bot
    # prefix, colour codes, etc.). The single capture group is the
    # CHANNEL TO RESTRICT, taken from the message text itself, not from
    # where the message arrived -- this is what lets a central
    # kick-log/relay channel restrict a DIFFERENT channel than the one the
    # report was seen in. Example message this matches:
    #     someuser [user@host] has been kicked from #mafia by op [user@host]: reason
    # If your kick-report source phrases it differently, change this to
    # match -- but keep it to exactly one capture group (the channel);
    # handle_kick_text only ever reads capture group 1.
    #
    # NOTE: an IRC client's own local display of a native KICK (e.g. "X
    # has been kicked from #chan by Y: reason" printed in someone's mIRC/
    # HexChat/etc. window) is NOT a message this regexp will ever see --
    # it is never sent over the wire as a PRIVMSG/NOTICE. That case is
    # handled by on_native_kick below instead.
    set kick_notice_regexp {has been kicked from (\S+)}

    # Which event types are scanned for a match. Both default on; turn
    # either off if your kick-report source only ever uses one of them, to
    # avoid running the regexp against traffic that can never match it.
    set kick_notice_watch_pubm 1   ;# public channel messages
    set kick_notice_watch_notc 1   ;# notices

    # --- public !restricthelp command ------------------------------------
    #
    # autorestrict's only OTHER interface is .autorestrict, DCC partyline,
    # master-flag only. A channel user who gets hit with +R has no way to
    # ask the bot anything about it -- this is that answer, in-channel.
    # Kept in this file (rather than a separate script) so the help text
    # can read help_menu's numbers straight out of the SAME namespace
    # variables the rest of the script actually runs on: editing
    # restrict_seconds, trusted_masks, etc. and rehashing changes what
    # !restricthelp says immediately, with nothing else to keep in sync.
    set help_trigger  "!restricthelp"
    set help_flags    "-|-"      ;# who may use it: -|- everyone
    set help_output   "notice"   ;# notice | msg | channel

    # Rate limiting for !restricthelp. Deliberately separate from
    # warn_cooldown above: warn_cooldown throttles this script's OWN log
    # lines per channel, keyed on the channel; this throttles a USER
    # spamming the help command, keyed on the caller. Conflating them
    # would mean a channel full of people asking for help once each could
    # still trip a per-channel log cooldown meant for repeated failures.
    set help_ratelimit_secs         15
    set help_ratelimit_scope        "both"   ;# global | percmd | both
    set help_ratelimit_cleanup_secs 3600
    set help_ratelimit_maxentries   5000

    # help_last_global: id -> unixtime of last !restricthelp use (any topic)
    # help_last_percmd: id,bucket -> unixtime of last use of that bucket,
    #   where bucket is a REAL topic name, "(index)" for the bare command,
    #   or "(unknown)" for anything unrecognised. It is deliberately not
    #   the raw argument -- see the bucket-resolution comment in cmd_help
    #   for why keying an array on unbounded user input is a memory bug.
    variable help_last_global
    variable help_last_percmd
    if {![array exists help_last_global]} { array set help_last_global {} }
    if {![array exists help_last_percmd]} { array set help_last_percmd {} }

    # --- internal state, keyed by CASEFOLDED channel -------------------
    #
    # state($c) = {chan owned deadline retries started}
    #   chan     -- the channel name as the server presents it
    #   owned    -- 1 if this script's own pushmode call is what put +R on
    #               (and is therefore timing it for removal). Per item 35
    #               this is back to meaning "did we set it", not merely
    #               "are we timing it" -- a +R set any other way is never
    #               claimed, so a record only ever exists here for a +R
    #               this script itself pushed.
    #   deadline -- unixtime the -R is due (absolute, so it survives a
    #               reload, a rejoin, and a retry loop)
    #   retries  -- consecutive failed expire attempts
    #   started  -- unixtime this +R episode began. No longer used for an
    #               extension cap (that was ban-only machinery, removed in
    #               item 30); kept in the record purely so the on-disk
    #               state format doesn't change shape.
    variable state
    variable timer_id    ;# timer_id($c) utimer id of the pending -R, if any
    variable resync_id   ;# resync_id($c) utimer id of the pending post-join resync
    variable warn_time   ;# warn_time($c) unixtime of the last warning log

    # pending($c) -- set the instant this script queues a +R push for a
    # channel, cleared once the server echoes the mode back (or on
    # failure/timeout). chan_has_mode only reflects CONFIRMED server
    # state, so it lags a queued pushmode by up to a network round trip.
    # If the same kick report somehow reaches handle_kick_text twice in
    # the same tick (e.g. it was both a pubm and a notc, with both watch
    # flags on), both calls would otherwise see "+R is off" via
    # chan_has_mode and both push +R -- exactly the double +R this flag
    # exists to prevent. It is a purely in-memory guard against the script
    # racing ITSELF. This also protects the new native-kick path: a kick
    # reported both natively and via a relay's text message in the same
    # tick still only pushes +R once.
    variable pending
    if {![array exists pending]} { array set pending {} }

    # deferred($c) = {utimer_id duration why tag}: a +R this script has
    # decided to push but is holding for push_delay_seconds (see above).
    variable deferred
    if {![array exists deferred]} { array set deferred {} }

    # last_off($c) -- unixtime of the last CONFIRMED -R on that channel
    # (see on_mode_restrict_off), used only to decide whether the NEXT +R
    # should escalate to escalate_seconds. Deliberately in-memory only,
    # not mirrored to state_file the way "state" is: losing this array on
    # a real bot restart just means the escalation window resets (a fresh
    # kick right after a restart gets the normal restrict_seconds, not the
    # escalated one) rather than every countdown surviving forever, which
    # is a far smaller consequence than what state_file protects against.
    variable last_off
    if {![info exists last_off]} { array set last_off {} }

    # --- config validation ---------------------------------------------
    # None of these were checked. restrict_seconds 0 or negative makes
    # arm_timer floor at 1 second, so +R goes on and comes straight back
    # off in a loop; retry_seconds 0 does the same to the retry path.
    if {![string is integer -strict $restrict_seconds] || $restrict_seconds < 60} {
        putlog "\[autorestrict\] invalid restrict_seconds; forcing 900."
        set restrict_seconds 900
    }
    if {![string is integer -strict $escalate_window_seconds] \
            || $escalate_window_seconds < 0} {
        putlog "\[autorestrict\] invalid escalate_window_seconds; forcing 600."
        set escalate_window_seconds 600
    }
    if {![string is integer -strict $escalate_seconds] \
            || $escalate_seconds < 60} {
        putlog "\[autorestrict\] invalid escalate_seconds; forcing 2700."
        set escalate_seconds 2700
    }
    if {$escalate_seconds < $restrict_seconds} {
        putlog "\[autorestrict\] escalate_seconds below restrict_seconds;\
            raising it to match."
        set escalate_seconds $restrict_seconds
    }
    if {![string is integer -strict $long_restrict_seconds] \
            || $long_restrict_seconds < 60} {
        putlog "\[autorestrict\] invalid long_restrict_seconds; forcing 2700."
        set long_restrict_seconds 2700
    }
    if {![string is integer -strict $push_delay_seconds] \
            || $push_delay_seconds < 1 || $push_delay_seconds > 30} {
        putlog "\[autorestrict\] invalid push_delay_seconds; forcing 1."
        set push_delay_seconds 1
    }
    if {[catch { llength $long_kicker_masks }]} {
        putlog "\[autorestrict\] long_kicker_masks is not a valid list; forcing empty."
        set long_kicker_masks {}
    }
    if {![string is integer -strict $retry_seconds] || $retry_seconds < 5} {
        putlog "\[autorestrict\] invalid retry_seconds; forcing 60."
        set retry_seconds 60
    }
    if {![string is integer -strict $max_overdue_secs] || $max_overdue_secs < 0} {
        putlog "\[autorestrict\] invalid max_overdue_secs; forcing 86400."
        set max_overdue_secs 86400
    }
    if {![string is integer -strict $warn_cooldown] || $warn_cooldown < 0} {
        putlog "\[autorestrict\] invalid warn_cooldown; forcing 300."
        set warn_cooldown 300
    }
    if {[string trim $state_file] eq ""} {
        putlog "\[autorestrict\] empty state_file; forcing autorestrict.state."
        set state_file "autorestrict.state"
    }
    # kick_notice_regexp must actually compile -- a typo'd/unbalanced
    # regexp would otherwise throw on every single message the bot sees
    # (once per watch flag that's on), which is the same "one bad config
    # value takes out every event" failure this file checks everything
    # else against. It also must capture at least 1 group (the channel),
    # since parse_kick_notice always reads capture group 1; checked
    # against a known-good sample of the default message shape, so it
    # only actually verifies the count when the configured pattern still
    # matches that shape -- a customized pattern for a differently worded
    # source is trusted on group count and will surface a mismatch at
    # runtime (parse_kick_notice logs and drops the message rather than
    # erroring the bind).
    if {[catch {
        set _kn_test [regexp -inline -- $kick_notice_regexp \
            "testnick \[test@host\] has been kicked from #test by testop \[t@h\]: test"]
    } _kn_err]} {
        putlog "\[autorestrict\] kick_notice_regexp does not compile ($_kn_err);\
            forcing the default pattern."
        set kick_notice_regexp {has been kicked from (\S+)}
    } elseif {[llength $_kn_test] > 0 && [llength $_kn_test] < 2} {
        putlog "\[autorestrict\] kick_notice_regexp compiles but captures no\
            groups against the default message shape; forcing the default\
            pattern."
        set kick_notice_regexp {has been kicked from (\S+)}
    }
    unset -nocomplain _kn_test _kn_err
    if {$kick_notice_watch_pubm ni {0 1}} {
        putlog "\[autorestrict\] invalid kick_notice_watch_pubm; forcing 1."
        set kick_notice_watch_pubm 1
    }
    if {$kick_notice_watch_notc ni {0 1}} {
        putlog "\[autorestrict\] invalid kick_notice_watch_notc; forcing 1."
        set kick_notice_watch_notc 1
    }
    if {($kick_notice_watch_pubm || $kick_notice_watch_notc)
            && ![llength $trusted_masks]} {
        putlog "\[autorestrict\] trusted_masks is empty, so the kick-report\
            TEXT path is off (anyone could type the phrase). Native kicks\
            still trigger +R."
    }
    # trusted_masks must be a well-formed list of non-empty masks. A stray
    # brace makes it an invalid list, and llength/foreach would throw on
    # every single matching message -- so it is checked once here instead.
    # A lone "*" is accepted but called out: it matches everything and so
    # silently defeats the whole point of the setting.
    if {[catch { llength $trusted_masks } _tm_n]} {
        putlog "\[autorestrict\] trusted_masks is not a valid list; forcing\
            an empty list (any kick/ban will trigger +R)."
        set trusted_masks {}
    } else {
        set _tm_clean {}
        foreach _tm $trusted_masks {
            if {[string trim $_tm] eq ""} { continue }
            lappend _tm_clean [string trim $_tm]
        }
        if {[llength $_tm_clean] != [llength $trusted_masks]} {
            putlog "\[autorestrict\] dropped [expr {[llength $trusted_masks] -
                [llength $_tm_clean]}] empty entr(y/ies) from trusted_masks."
        }
        set trusted_masks $_tm_clean
        if {[lsearch -exact $trusted_masks "*"] >= 0} {
            putlog "\[autorestrict\] warning: trusted_masks contains a bare\
                \"*\", which matches every source -- any kick/ban will\
                trigger +R."
        }
        unset -nocomplain _tm _tm_clean
    }
    unset -nocomplain _tm_n

    # --- !restricthelp config validation --------------------------------
    if {[string trim $help_trigger] eq "" || [string length $help_trigger] > 32
            || [regexp {[[:cntrl:][:space:]]} $help_trigger]
            || ![string match "!*" $help_trigger]} {
        putlog "\[autorestrict\] invalid help_trigger; forcing !restricthelp."
        set help_trigger "!restricthelp"
    }
    if {$help_output ni {channel msg notice}} {
        putlog "\[autorestrict\] invalid help_output \"$help_output\"; forcing notice."
        set help_output "notice"
    }
    if {$help_ratelimit_scope ni {global percmd both}} {
        putlog "\[autorestrict\] invalid help_ratelimit_scope; forcing both."
        set help_ratelimit_scope "both"
    }
    if {![string is integer -strict $help_ratelimit_secs] || $help_ratelimit_secs < 0} {
        putlog "\[autorestrict\] invalid help_ratelimit_secs; forcing 15."
        set help_ratelimit_secs 15
    }
    if {![string is integer -strict $help_ratelimit_cleanup_secs]
            || $help_ratelimit_cleanup_secs < 60} {
        putlog "\[autorestrict\] invalid help_ratelimit_cleanup_secs; forcing 3600."
        set help_ratelimit_cleanup_secs 3600
    }
    if {![string is integer -strict $help_ratelimit_maxentries]
            || $help_ratelimit_maxentries < 100} {
        putlog "\[autorestrict\] invalid help_ratelimit_maxentries; forcing 5000."
        set help_ratelimit_maxentries 5000
    }

    # --- (re)load cleanup ----------------------------------------------
    #
    # NOTE: "array set a {}" is a MERGE and does not clear an existing
    # array. Pending timers must also be killed by hand or they fire on
    # the old schedule, and their ids -- once recycled by Eggdrop -- can
    # be handed to killutimer and take out another script's timer.
    #
    # state is deliberately PRESERVED: a +R this script is timing outlives
    # a reload, and forgetting we're timing it is what stranded the mode
    # before. resync_all (called at the bottom) re-arms the countdowns
    # from the stored deadlines.

    # Kill by id where we have ids, then sweep the CORE utimer table by
    # command name as well. The id table only exists in this namespace, so
    # it is empty in a fresh interpreter and can be stale after a partial
    # reload -- the core's own table is the authority, and every timer this
    # script arms runs a command starting with ::autorestrict::, which no
    # other script emits. This is what catches the post-join resync timers
    # that item 13 leaked; they were never in any id table at all.
    if {[info exists timer_id]} {
        foreach {k v} [array get timer_id] {
            catch { killutimer $v }
        }
    }
    catch {
        foreach u [utimers] {
            if {[string match "::autorestrict::*" [lindex $u 1]]} {
                catch { killutimer [lindex $u 2] }
            }
        }
    }
    # The two loops above run at namespace-eval level -- `if` and `catch`
    # do not create a scope in Tcl -- so their loop variables became real
    # ::autorestrict::k, ::autorestrict::v and ::autorestrict::u namespace
    # variables and stayed there for the life of the process. Same stray-
    # name leak the bind block at the bottom already cleans up for b/err;
    # cleaned here too rather than left as three names nothing reads.
    catch { unset k }
    catch { unset v }
    catch { unset u }

    array unset timer_id
    array set timer_id {}

    array unset resync_id
    array set resync_id {}

    array unset warn_time
    array set warn_time {}

    # Their utimers were swept above. A held +R push is re-armed rather
    # than dropped (by its casefolded key, which Eggdrop's case-insensitive
    # channel lookups accept): dropping it meant a qualifying kick within
    # push_delay_seconds of a .rehash never got its +R at all.
    foreach {_dc _dv} [array get deferred] {
        lassign $_dv _did _ddur _dwhy _dtag
        set deferred($_dc) [list \
            [utimer $push_delay_seconds [list ::autorestrict::deferred_fire $_dc]] \
            $_ddur $_dwhy $_dtag]
    }
    unset -nocomplain _dc _dv _did _ddur _dwhy _dtag

    # pending($c) is normally cleared by the +R echo or by a 5s utimer --
    # and that utimer was just swept. If the echo never comes (the server
    # refused the mode, the bot was deopped), pending stayed 1 for good and
    # trigger refused every later kick on that channel until a restart.
    array unset pending
    array set pending {}

    # Only load from disk on a genuinely fresh interpreter (real bot
    # restart). If "state" already exists, this is a re-source/rehash and
    # the in-memory copy is more current than whatever was last flushed.
    # (st_load isn't defined yet at this point in the file, so just flag
    # it here; the actual load happens near the bottom, right before
    # resync_all.)
    set ::autorestrict::need_state_load [expr {![info exists state]}]
    if {$::autorestrict::need_state_load} { array set state {} }

    #-------------------------------------------------------------------
    # Casefold a channel name (rfc1459) so #Mafia and #mafia are one
    # channel with one countdown, not two.
    #-------------------------------------------------------------------
    proc casefold {s} {
        return [string map [list "\[" "\{" "\]" "\}" "\\" "|" "~" "^"] \
            [string tolower $s]]
    }

    #-------------------------------------------------------------------
    # Should this channel be managed by the script?
    #-------------------------------------------------------------------
    proc channel_allowed {chan} {
        variable restrict_channels
        if {[llength $restrict_channels] == 0} { return 1 }
        set c [casefold $chan]
        foreach w $restrict_channels {
            if {[casefold $w] eq $c} { return 1 }
        }
        return 0
    }

    #-------------------------------------------------------------------
    # Was this kick/ban set by someone allowed to trigger a restriction?
    #
    # Matched against both "nick!user@host" and the bare "user@host" so a
    # mask can be written either way (see trusted_masks). Case-insensitive,
    # since hostnames are and IRC nicks effectively are.
    #
    # A source with no uhost at all (a server-sourced mode on some builds,
    # see from_server) can only match if a configured mask happens to be
    # broad enough to cover the bare nick -- it is never trusted implicitly.
    #-------------------------------------------------------------------
    proc trusted_source {nick uhost} {
        variable trusted_masks
        if {[llength $trusted_masks] == 0} { return 1 }
        set full "${nick}!${uhost}"
        foreach m $trusted_masks {
            if {[string match -nocase $m $full]} { return 1 }
            if {$uhost ne "" && [string match -nocase $m $uhost]} { return 1 }
        }
        return 0
    }

    # Is this source one of long_kicker_masks (e.g. *!*@dal.ninja)?
    proc long_source {nick uhost} {
        variable long_kicker_masks
        set full "${nick}!${uhost}"
        foreach m $long_kicker_masks {
            if {[string match -nocase $m $full]} { return 1 }
            if {$uhost ne "" && [string match -nocase $m $uhost]} { return 1 }
        }
        return 0
    }

    #-------------------------------------------------------------------
    # Does the channel actually have mode $m set right now?
    #   1  = yes, 0 = no, -1 = cannot tell (bot not on the channel)
    # This is the reconciliation the old version never did.
    #-------------------------------------------------------------------
    proc clear_pending {c} {
        variable pending
        catch { unset pending($c) }
    }

    proc chan_has_mode {chan m} {
        if {![validchan $chan] || ![botonchan $chan]} { return -1 }
        if {[catch { getchanmode $chan } modes]} { return -1 }
        # "+tnR", or "+tnkl key 50" -- flags are the first word.
        set flags [lindex [split [string trim $modes]] 0]
        if {$flags eq ""} { return -1 }
        if {[string index $flags 0] eq "+"} {
            set flags [string range $flags 1 end]
        }
        return [expr {[string first $m $flags] >= 0}]
    }

    #-------------------------------------------------------------------
    # State accessors. Everything is keyed on the casefolded name; the
    # server's own spelling is carried inside the record for mode calls.
    #-------------------------------------------------------------------
    proc state_record_valid {v} {
        variable max_overdue_secs
        variable restrict_seconds
        variable escalate_seconds
        if {[llength $v] != 5} { return 0 }
        lassign $v chan owned deadline retries started
        if {![valid_chan_name $chan]} { return 0 }
        if {$owned ni {0 1}} { return 0 }
        if {![string is integer -strict $deadline] || $deadline < 0} { return 0 }
        if {![string is integer -strict $retries] || $retries < 0 || $retries > 1000000} { return 0 }
        if {![string is integer -strict $started] || $started < 0} { return 0 }
        set now [unixtime]
        # A live in-memory record may legitimately be overdue, but a
        # deadline cannot be absurdly far in the future. This also protects
        # against stale/mutated state surviving a rehash. Bounded by
        # escalate_seconds (the longer of the two durations this script can
        # ever set), not restrict_seconds -- an escalated +R's deadline is
        # legitimately further out.
        set longest [expr {max($restrict_seconds, $escalate_seconds)}]
        set max_deadline [expr {$now + $longest + $max_overdue_secs + 86400}]
        if {$deadline > $max_deadline} { return 0 }
        if {$started > $now + 86400} { return 0 }
        return 1
    }

    proc st_get {chan} {
        variable state
        set c [casefold $chan]
        if {![info exists state($c)]} { return {} }
        set v $state($c)
        if {![state_record_valid $v]} {
            putlog "\[autorestrict\] dropping malformed in-memory state for $chan."
            catch { cancel_timer $chan }
            unset state($c)
            st_save
            return {}
        }
        return $v
    }

    # Both accessors now write the state file only when the record
    # actually changed. They used to call st_save unconditionally, and
    # trigger re-recorded the identical "not ours" record on every kick
    # while an operator's +R was up -- so a kick flood became one
    # create-temp-file-and-rename per kick. Same for st_clear on a
    # channel that was not being tracked, which -R floods hit.
    proc st_put {chan owned deadline retries started} {
        variable state
        set c   [casefold $chan]
        set rec [list $chan $owned $deadline $retries $started]
        if {[info exists state($c)] && $state($c) eq $rec} { return }
        set state($c) $rec
        st_save
    }

    proc st_clear {chan} {
        variable state
        set c [casefold $chan]
        if {![info exists state($c)]} { return }
        unset state($c)
        st_save
    }

    #-------------------------------------------------------------------
    # Mirror "state" to disk (tab-separated, one channel per line) so a
    # real bot restart -- not just a re-source -- has something to
    # resync_all from. Written to a temp file and renamed into place so
    # a crash mid-write can't leave a half-written file behind.
    #-------------------------------------------------------------------
    proc st_save {} {
        variable state
        variable state_file
        set tmp "${state_file}.tmp"
        if {[catch {
            # O_EXCL + mode 0600 instead of a plain "w". The temp name is
            # predictable and lives in the bot's working directory, so on a
            # shared host another local account could pre-plant a symlink
            # there and have the bot write through it. EXCL refuses to open
            # an existing path -- including a symlink -- so the worst case
            # is a logged failure, not a clobbered file. Same defense as
            # mafia.tcl's save_db and melons_poems.tcl's save_state.
            catch { file delete -- $tmp }
            set fh [open $tmp {WRONLY CREAT TRUNC EXCL} 0600]
            foreach {c v} [array get state] {
                # v = {chan owned deadline retries started}; tab-joined,
                # channel names can't contain tabs.
                puts $fh [join $v "\t"]
            }
            close $fh
            file rename -force -- $tmp $state_file
        } err]} {
            putlog "\[autorestrict\] warning: couldn't save state to\
                $state_file: $err"
            catch { close $fh }
            catch { file delete -- $tmp }
        }
    }

    #-------------------------------------------------------------------
    # Load "state" from disk. Only meaningful right after a fresh
    # interpreter start, before anything has mutated the array; called
    # near the bottom of this file once st_put/st_clear exist.
    #-------------------------------------------------------------------
    # SECURITY: this is the read-side mirror of st_save's symlink defense
    # and it had none of it. The path is predictable and lives in the
    # bot's working directory, so the same local account st_save guards
    # against could point it at /dev/zero (unbounded read -> the bot OOMs
    # at every start) or a writerless FIFO (the open blocks forever,
    # wedging the single-threaded event loop before the script finishes
    # loading), and every field was fed straight into the state array
    # unchecked. A non-numeric or far-future deadline was the worst of
    # those: expire's max_overdue_secs give-up test compares against it,
    # so garbage there meant a channel retried forever, and a bogus
    # channel name went on to be handed to pushmode.
    #
    # Four layers: [file type] (lstat) refuses a symlink; NONBLOCK makes
    # a FIFO raced into place after that check return instead of hang;
    # the read is capped; and every record is validated field by field,
    # with bad records dropped and counted rather than loaded.
    proc st_load {} {
        variable state
        variable state_file
        variable restrict_seconds
        variable escalate_seconds
        variable max_overdue_secs

        if {![file exists $state_file]} { return }
        if {[catch { file type $state_file } ftype] || $ftype ne "file"} {
            putlog "\[autorestrict\] refusing state at $state_file --\
                not a regular file ($ftype)."
            return
        }
        if {[catch { file size $state_file } fsize] || $fsize > 262144} {
            putlog "\[autorestrict\] refusing state at $state_file --\
                file is missing/unreadable or larger than 256KiB."
            return
        }
        if {[catch {
            set fh [open $state_file {RDONLY NONBLOCK}]
            fconfigure $fh -blocking 1
            set data [read $fh 262144]
            close $fh
        } err]} {
            catch { close $fh }
            putlog "\[autorestrict\] warning: couldn't read $state_file:\
                $err"
            return
        }

        set now [unixtime]
        # A deadline further out than the longest legitimate one this
        # script can produce (one full restriction plus the whole overdue
        # grace window) is not something it wrote. Bounded by
        # escalate_seconds, not restrict_seconds -- see state_record_valid.
        set longest [expr {max($restrict_seconds, $escalate_seconds)}]
        set max_deadline [expr {$now + $longest + $max_overdue_secs + 86400}]
        set n 0
        set bad 0
        foreach line [split $data "\n"] {
            if {[string trim $line] eq ""} { continue }
            set v [split $line "\t"]
            if {[llength $v] != 5} { incr bad ; continue }
            lassign $v chan owned deadline retries started
            if {![valid_chan_name $chan]} { incr bad ; continue }
            if {$owned ni {0 1}} { incr bad ; continue }
            if {![string is integer -strict $deadline] || $deadline < 0
                    || $deadline > $max_deadline} { incr bad ; continue }
            if {![string is integer -strict $retries] || $retries < 0
                    || $retries > 1000000} { incr bad ; continue }
            if {![string is integer -strict $started] || $started < 0
                    || $started > $now + 86400} { incr bad ; continue }
            # An unowned record carries no deadline and nothing to do;
            # keeping it only re-asserts "not ours", which the live mode
            # check establishes anyway.
            if {!$owned} { continue }
            set state([casefold $chan]) \
                [list $chan $owned $deadline $retries $started]
            incr n
            if {$n >= 512} { break }
        }
        if {$n > 0} {
            putlog "\[autorestrict\] loaded $n saved channel state(s) from\
                $state_file"
        }
        if {$bad > 0} {
            putlog "\[autorestrict\] ignored $bad malformed record(s) in\
                $state_file"
        }
    }

    # A channel name this script is willing to act on: a normal IRC
    # channel token, no spaces, commas or control characters, and short
    # enough to be real. Used to validate anything read back from disk
    # before it can reach pushmode.
    proc valid_chan_name {chan} {
        if {[string length $chan] < 2 || [string length $chan] > 64} { return 0 }
        if {![string match {[#&+!]*} $chan]} { return 0 }
        if {[regexp {[[:cntrl:][:space:],]} $chan]} { return 0 }
        return 1
    }

    # restrict_channels is a user-editable list and is consumed directly
    # from event handlers. Validate it once at load time so a malformed list
    # cannot turn every kick/mode/join path into a Tcl error. Entries are
    # exact channel names (case-insensitive), not glob patterns.
    if {[catch { llength $restrict_channels } _rc_n]} {
        putlog "\[autorestrict\] restrict_channels is not a valid list; forcing an empty list (manage every channel)."
        set restrict_channels {}
    } else {
        set _rc_clean {}
        set _rc_bad 0
        foreach _rc $restrict_channels {
            set _rc [string trim $_rc]
            if {![valid_chan_name $_rc]} {
                incr _rc_bad
                continue
            }
            lappend _rc_clean $_rc
        }
        if {$_rc_bad > 0} {
            putlog "\[autorestrict\] dropped $_rc_bad invalid channel entr(y/ies) from restrict_channels."
        }
        if {[llength $_rc_clean] > 128} {
            putlog "\[autorestrict\] restrict_channels has more than 128 entries; keeping the first 128."
            set _rc_clean [lrange $_rc_clean 0 127]
        }
        set restrict_channels $_rc_clean
        unset -nocomplain _rc _rc_clean _rc_bad
    }
    unset -nocomplain _rc_n

    proc st_owned {chan} {
        set v [st_get $chan]
        if {![llength $v]} { return 0 }
        return [lindex $v 1]
    }

    #-------------------------------------------------------------------
    # Rate-limited warning, so a kick flood against an unopped bot can't
    # be turned into unbounded log volume.
    #-------------------------------------------------------------------
    # Everything that reaches putlog from the network (nicks, ban masks)
    # goes through here first. The IRC server should never relay a control
    # character in either, but the logfile is a text file read by other
    # tools and every other string this bot logs is sanitized.
    proc logsafe {s {maxlen 63}} {
        regsub -all {[[:cntrl:]]} $s "" s
        return [string range $s 0 $maxlen]
    }

    proc warn {chan msg} {
        variable warn_time
        variable warn_cooldown

        set c [casefold $chan]
        set now [unixtime]
        if {[info exists warn_time($c)] \
                && ($now - $warn_time($c)) < $warn_cooldown} {
            return
        }
        set warn_time($c) $now
        putlog "\[autorestrict\] $msg"
    }

    #-------------------------------------------------------------------
    # Cancel any pending -R timer for $chan, if one exists.
    #-------------------------------------------------------------------
    proc cancel_timer {chan} {
        variable timer_id
        set c [casefold $chan]
        if {[info exists timer_id($c)] && $timer_id($c) ne ""} {
            catch { killutimer $timer_id($c) }
            unset timer_id($c)
        }
    }

    #-------------------------------------------------------------------
    # (Re)arm the -R timer for $chan to fire at absolute time $deadline.
    #-------------------------------------------------------------------
    proc arm_timer {chan deadline} {
        variable timer_id
        cancel_timer $chan
        set secs [expr {$deadline - [unixtime]}]
        if {$secs < 1} { set secs 1 }
        set timer_id([casefold $chan]) \
            [utimer $secs [list ::autorestrict::expire $chan]]
    }

    #-------------------------------------------------------------------
    # Turn +R on for $chan if it isn't already. Per item 30, that is now
    # the ONLY thing this proc does when +R is already on: it never
    # restarts or extends a running countdown any more (that was ban-only
    # behavior). "why" is a free-text fragment appended to the log line.
    #
    # Every decision here is made against the CHANNEL'S REAL MODE, not
    # against a private flag that could have drifted.
    #-------------------------------------------------------------------
    proc trigger {chan {why ""} {long 0}} {
        variable restrict_seconds
        variable escalate_seconds
        variable escalate_window_seconds
        variable long_restrict_seconds
        variable push_delay_seconds
        variable last_off
        variable pending
        variable deferred

        if {![channel_allowed $chan]} { return }
        if {![validchan $chan]} { return }

        set now [unixtime]
        set is_on [chan_has_mode $chan R]

        if {$is_on == -1} {
            warn $chan "can't act on $chan -- bot is not on the channel."
            return
        }

        set c [casefold $chan]

        # Duration for this kick: restrict_seconds normally; escalated
        # (escalate_seconds) if within escalate_window_seconds of the last
        # -R; and always at least long_restrict_seconds for a kick from
        # long_kicker_masks.
        set dur $restrict_seconds
        set tag ""
        if {[info exists last_off($c)] \
                && ($now - $last_off($c)) <= $escalate_window_seconds} {
            set dur $escalate_seconds
            set tag "ESCALATED (kick within\
                [expr {$escalate_window_seconds / 60}]m of the last -R)"
        }
        if {$long && $long_restrict_seconds > $dur} {
            set dur $long_restrict_seconds
            set tag "LONG (kicker matches long_kicker_masks)"
        }

        # A push for this channel is already being held: fold this kick
        # into it (keep the longer duration), never queue a second one.
        if {[info exists deferred($c)]} {
            lassign $deferred($c) id odur owhy otag
            if {$dur > $odur} { set deferred($c) [list $id $dur $owhy $tag] }
            return
        }

        # A push already went out but the server has not echoed it yet.
        if {!$is_on && [info exists pending($c)] && $pending($c)} {
            return
        }

        # --- +R is not set: hold the push briefly, then re-check. -------
        if {!$is_on} {
            if {![botisop $chan]} {
                warn $chan "can't set +R on $chan -- bot is not opped there.\
                    Will retry on the next kick report."
                return
            }
            set id [utimer $push_delay_seconds \
                [list ::autorestrict::deferred_fire $chan]]
            set deferred($c) [list $id $dur $why $tag]
            return
        }

        # --- +R already on -----------------------------------------------
        if {![st_owned $chan]} {
            # +R is already on but this script did not push it itself --
            # per item 35, never claim or time a +R we did not set, even
            # in response to a qualifying kick.
            putlog "\[autorestrict\] +R already on $chan${why}; not set by\
                this script, so not timing it."
            return
        }
        # Already on and timed: no second +R and no restart -- except a
        # kick from a long_kicker_masks host, which lengthens (never
        # shortens) the running countdown to the long duration.
        if {$long} { extend_to $chan $dur $why }
        return
    }

    #-------------------------------------------------------------------
    # Lengthen a running countdown so it is due off $dur seconds from now.
    # Never shortens. Returns 1 if it changed anything.
    #-------------------------------------------------------------------
    proc extend_to {chan dur {why ""}} {
        set v [st_get $chan]
        if {![llength $v] || ![lindex $v 1]} { return 0 }
        set deadline [expr {[unixtime] + $dur}]
        if {$deadline <= [lindex $v 2]} { return 0 }
        st_put $chan 1 $deadline 0 [lindex $v 4]
        arm_timer $chan $deadline
        putlog "\[autorestrict\] +R on $chan lengthened; now due off in\
            [expr {$dur / 60}]m${why}"
        return 1
    }

    #-------------------------------------------------------------------
    # The held +R push comes due. Re-check the LIVE channel mode first:
    # if someone else set +R while we waited, do not push a duplicate.
    #-------------------------------------------------------------------
    proc deferred_fire {chan} {
        variable deferred
        variable pending

        set c [casefold $chan]
        if {![info exists deferred($c)]} { return }
        lassign $deferred($c) id dur why tag
        unset deferred($c)

        if {![channel_allowed $chan] || ![validchan $chan]} { return }

        set now [unixtime]
        set is_on [chan_has_mode $chan R]
        if {$is_on == -1} {
            warn $chan "can't act on $chan -- bot is not on the channel."
            return
        }

        if {$is_on} {
            # Someone else's +R landed during the wait. If it's already
            # OUR owned timer running (e.g. our own push somehow already
            # confirmed), a fresh kick can still lengthen it. Otherwise,
            # per item 35, it is not our +R to time -- leave it alone.
            if {[st_owned $chan]} {
                extend_to $chan $dur $why
                putlog "\[autorestrict\] +R already on $chan when our push\
                    was due; NOT pushing a duplicate. Due off in\
                    [expr {$dur / 60}]m${why}"
            } else {
                putlog "\[autorestrict\] +R already on $chan when our push\
                    was due; NOT pushing a duplicate, and not timing theirs\
                    -- not set by this script."
            }
            return
        }

        if {![botisop $chan]} {
            warn $chan "can't set +R on $chan -- bot is not opped there.\
                Will retry on the next kick report."
            return
        }

        set pending($c) 1
        if {[catch { pushmode $chan +R } err]} {
            putlog "\[autorestrict\] pushmode +R failed on $chan: $err"
            catch { unset pending($c) }
            return
        }
        utimer 5 [list ::autorestrict::clear_pending $c]

        set deadline [expr {$now + $dur}]
        st_put $chan 1 $deadline 0 $now
        arm_timer $chan $deadline
        if {$tag ne ""} {
            putlog "\[autorestrict\] +R set on $chan${why}; $tag; due off\
                in [expr {$dur / 60}]m"
        } else {
            putlog "\[autorestrict\] +R set on $chan${why}; due off in\
                [expr {$dur / 60}]m"
        }
    }

    #-------------------------------------------------------------------
    # Fired by the timer: turn -R back off and clear our state.
    #
    # Unlike the old version this verifies it can actually act, and if it
    # can't it RETRIES rather than clearing the state and stranding the
    # channel in +R with nothing tracking it.
    #-------------------------------------------------------------------
    proc expire {chan} {
        variable timer_id
        variable retry_seconds
        variable max_overdue_secs

        catch { unset timer_id([casefold $chan]) }

        set v [st_get $chan]
        if {![llength $v]} { return }

        if {![validchan $chan]} {
            st_clear $chan
            return
        }

        # Not (or no longer) being timed by us any more (manual -R and a
        # later manual +R that we haven't reconciled yet, say).
        if {![lindex $v 1]} {
            st_clear $chan
            return
        }

        set now [unixtime]
        set deadline [lindex $v 2]
        set retries  [lindex $v 3]
        set started  [lindex $v 4]

        set is_on [chan_has_mode $chan R]

        # Someone/something already took it off. Nothing to do -- do NOT
        # push a redundant -R.
        if {$is_on == 0} {
            putlog "\[autorestrict\] +R on $chan is already off; clearing state"
            st_clear $chan
            return
        }

        # Can't act: bot is off the channel, split, or deopped. Keep the
        # deadline and try again -- this is the path that used to lose
        # the mode change silently and leave +R on forever.
        if {$is_on == -1 || ![botisop $chan]} {
            if {$max_overdue_secs > 0 \
                    && ($now - $deadline) > $max_overdue_secs} {
                putlog "\[autorestrict\] giving up on removing +R from $chan\
                    -- [expr {($now - $deadline) / 60}]m overdue and still\
                    unable to act. Remove it by hand if it is still set."
                st_clear $chan
                return
            }
            incr retries
            st_put $chan 1 $deadline $retries $started
            if {$retries == 1 || ($retries % 10) == 0} {
                warn $chan "can't remove +R from $chan yet (not opped or not on\
                    channel); retry $retries, trying again every\
                    ${retry_seconds}s."
            }
            arm_timer $chan [expr {$now + $retry_seconds}]
            return
        }

        if {[catch { pushmode $chan -R } err]} {
            putlog "\[autorestrict\] pushmode -R failed on $chan: $err;\
                retrying in ${retry_seconds}s"
            incr retries
            st_put $chan 1 $deadline $retries $started
            arm_timer $chan [expr {$now + $retry_seconds}]
            return
        }

        st_clear $chan
        putlog "\[autorestrict\] -R set on $chan (restriction expired)"
    }

    #-------------------------------------------------------------------
    # Kick-report text matching (item 31, optional relay path). Runs
    # alongside the native kick trigger (item 34, on_native_kick), not
    # instead of it.
    #-------------------------------------------------------------------

    # Tests $text against kick_notice_regexp and returns the captured
    # channel name, or {} if it doesn't match (or the pattern captures no
    # groups at all -- config validation forces a working default, but
    # this is the runtime backstop for a customized pattern that slipped
    # past that check).
    proc parse_kick_notice {text} {
        variable kick_notice_regexp
        if {[catch {
            set m [regexp -inline -- $kick_notice_regexp $text]
        } err]} {
            putlog "\[autorestrict\] kick_notice_regexp failed at runtime:\
                $err"
            return {}
        }
        if {![llength $m]} { return {} }
        if {[llength $m] < 2} {
            putlog "\[autorestrict\] kick_notice_regexp matched but captured\
                no groups; ignoring this message."
            return {}
        }
        return [lindex $m 1]
    }

    # Common handler for both the pubm and notc binds below. $nick/$uhost
    # here are the SENDER of the message, not anything parsed out of its
    # text -- trust is anchored to them (see the trusted_masks comment).
    proc handle_kick_text {nick uhost hand text} {
        variable trusted_masks
        # With trusted_masks empty, trusted_source accepts everyone. That is
        # fine for a NATIVE kick (only an op can kick), but this path only
        # needs someone to TYPE the phrase -- in any channel the bot is in,
        # or in a private /notice to it from anywhere on the network -- to
        # put a managed channel on +R for 15-45 minutes, repeatably. The
        # text path therefore only runs once trusted_masks names the relay
        # that is allowed to send these reports.
        if {![llength $trusted_masks]} { return }
        set tchan [parse_kick_notice $text]
        if {$tchan eq ""} { return }

        # Only a message from a trusted sender restricts the channel.
        # Silent by design -- see the trusted_masks comment.
        if {![trusted_source $nick $uhost]} { return }

        # The target channel comes from the MESSAGE TEXT, not from where
        # the message was posted -- reject anything that isn't a
        # plausible channel name before it goes anywhere near pushmode.
        if {![valid_chan_name $tchan]} { return }

        trigger $tchan " (kick reported by [logsafe $nick]:\
            [logsafe $text 200])"
    }

    #-------------------------------------------------------------------
    # bind pubm: a channel message matching the kick-report shape.
    #-------------------------------------------------------------------
    proc on_pubm_kick_notice {nick uhost hand chan text} {
        handle_kick_text $nick $uhost $hand $text
    }

    #-------------------------------------------------------------------
    # bind notc: a notice matching the kick-report shape. Eggdrop's notc
    # bind signature is (nick host handle text dest) -- there is no
    # "chan" argument the way pubm has one, which is fine here since the
    # restricted channel is parsed out of $text regardless.
    #-------------------------------------------------------------------
    proc on_notc_kick_notice {nick uhost hand text dest} {
        handle_kick_text $nick $uhost $hand $text
    }

    #-------------------------------------------------------------------
    # bind kick (item 34): the ACTUAL native KICK event, restored as a
    # trigger source. This is what fires on a real kick on this network --
    # nothing here posts the text-report phrase as a real message, so
    # without this the script had no working trigger at all (confirmed
    # directly, not guessed).
    #
    # Eggdrop's kick bind gives the ACTUAL KICKER as nick/uhost/hand --
    # trust is anchored to them, exactly the way handle_kick_text anchors
    # trust to a text report's sender, and for the same reason: the
    # kicked victim's nick and the kick reason are attacker-influenced
    # free text and are never used for the trust decision, only for the
    # log line.
    #-------------------------------------------------------------------
    proc on_native_kick {nick uhost hand chan victim reason} {
        if {[isbotnick $nick]} { return }  ;# ignore the bot's own kicks
        if {[isbotnick $victim]} { return }  ;# ignore kicks OF the bot (it is leaving, nothing to restrict)
        if {![channel_allowed $chan]} { return }
        if {![trusted_source $nick $uhost]} { return }
        trigger $chan " (kicked by [logsafe $nick]: [logsafe $victim] --\
            [logsafe $reason 200])" [long_source $nick $uhost]
    }

    #-------------------------------------------------------------------
    # bind mode "* +R": +R appeared, from ANY source. Per item 35, this
    # only ever times it if it is THIS SCRIPT's own pending push landing
    # (the isbotnick check below), or lengthens a countdown this script is
    # already OWN-timing for a long-kicker kick. A +R this script did not
    # push itself is never claimed or timed here, regardless of source.
    #-------------------------------------------------------------------
    proc on_mode_restrict_on {nick uhost hand chan mode victim} {
        variable long_restrict_seconds
        variable deferred

        if {![channel_allowed $chan]} { return }
        set c [casefold $chan]
        # The confirmed echo of a +R landing closes the pending window
        # regardless of who set it -- our own push is done either way.
        clear_pending $c
        # Our own push already claimed and timed this in deferred_fire.
        if {[isbotnick $nick]} { return }

        set now [unixtime]
        set long [long_source $nick $uhost]

        # Someone else set +R while our own push for a kick was being
        # held: same episode. Cancel our push (no duplicate +R). Per item
        # 35, their +R is NOT adopted or timed -- it is simply left alone,
        # exactly like any other +R this script did not push itself.
        if {[info exists deferred($c)]} {
            lassign $deferred($c) id dur why tag
            catch { killutimer $id }
            unset deferred($c)
            if {[st_owned $chan]} {
                if {$long && $long_restrict_seconds > $dur} {
                    set dur $long_restrict_seconds
                }
                extend_to $chan $dur $why
                putlog "\[autorestrict\] +R set on $chan by [logsafe $nick]\
                    while our own +R was pending -- cancelled ours, no\
                    duplicate; due off in [expr {$dur / 60}]m${why}"
            } else {
                putlog "\[autorestrict\] +R set on $chan by [logsafe $nick]\
                    while our own +R was pending -- cancelled ours, no\
                    duplicate; not timing theirs -- not set by this script."
            }
            return
        }

        # Already being timed: no second countdown. A +R from a
        # long_kicker_masks host still lengthens it to the long duration.
        if {[st_owned $chan]} {
            if {$long} { extend_to $chan $long_restrict_seconds " (+R by [logsafe $nick])" }
            return
        }

        # Unrelated +R (an op by hand, another script): per item 35, this
        # script never claims or times a +R it did not push itself. Left
        # alone -- an op can remove it manually.
        putlog "\[autorestrict\] +R set on $chan by [logsafe $nick]; not set\
            by this script, so not timing it."
    }

    #-------------------------------------------------------------------
    # bind mode "* -R": someone removed +R by hand -> stop tracking it and
    # drop any pending timer, but do NOT put +R back on.
    #-------------------------------------------------------------------
    proc on_mode_restrict_off {nick uhost hand chan mode victim} {
        variable last_off
        if {![channel_allowed $chan]} { return }
        # Record this regardless of who removed it or whether it was ours
        # to track -- see escalate_window_seconds/escalate_seconds: the
        # NEXT qualifying kick report is escalated to the long duration if
        # it lands within escalate_window_seconds of THIS moment.
        set last_off([casefold $chan]) [unixtime]
        cancel_timer $chan
        if {[llength [st_get $chan]] && ![isbotnick $nick]} {
            putlog "\[autorestrict\] +R removed from $chan by [logsafe $nick];\
                countdown cancelled, it will not be reapplied until the\
                next +R"
        }
        st_clear $chan
    }

    #-------------------------------------------------------------------
    # bind join: if the BOT itself (re)joins a channel, reconcile against
    # the channel's real mode instead of wiping our state.
    #
    # The old version cancelled the pending -R and forgot the channel. But
    # channel modes outlive the bot's absence, so after a netsplit the
    # channel was still +R with nothing left to lift it.
    #-------------------------------------------------------------------
    # Replaces any resync already pending for this channel instead of
    # stacking another one. A flapping netsplit fires this bind once per
    # rejoin, and the old version armed an untracked utimer every time --
    # so the queue grew with the flapping, each entry re-running the same
    # reconciliation, and nothing could cancel them (they were in no id
    # table, so not even a rehash cleared them).
    proc arm_resync {chan} {
        variable resync_id
        set c [casefold $chan]
        if {[info exists resync_id($c)]} {
            catch { killutimer $resync_id($c) }
            unset resync_id($c)
        }
        set resync_id($c) [utimer 10 [list ::autorestrict::resync $chan]]
    }

    proc on_join {nick uhost hand chan} {
        if {![isbotnick $nick]} { return }
        if {![channel_allowed $chan]} { return }
        # The mode list isn't populated the instant we join; give the
        # server a moment before reconciling.
        arm_resync $chan
    }

    #-------------------------------------------------------------------
    # Reconcile stored state against the channel's actual mode.
    #-------------------------------------------------------------------
    proc resync {chan} {
        variable resync_id
        # This firing consumed the handle; drop it so the table can't
        # accumulate ids for timers that no longer exist (and so a later
        # arm_resync never hands a recycled id to killutimer, which would
        # kill some other script's timer).
        catch { unset resync_id([casefold $chan]) }

        # No longer a channel this script manages -- an operator has
        # edited restrict_channels since the record was written. Returning
        # here (what this used to do) left the record in "state" forever:
        # resync_all is the only thing that ever revisits it, and it lands
        # right back on this line every time. Nothing armed a timer for it
        # and nothing cleared it, so a channel we still held a timed +R on
        # stayed +R with no countdown -- the exact stranding this script
        # exists to prevent, reached through a config edit rather than a
        # crash -- while ".autorestrict status" went on reporting it as
        # "ours, +R, due off in Nm" off a deadline no timer would ever
        # reach. Drop the record, and say so loudly when it was a timed
        # +R, the same way the max_overdue_secs give-up path does: the
        # mode is now the operator's to lift.
        if {![channel_allowed $chan]} {
            variable last_off
            # last_off is not part of "state" and resync is the only path
            # that ever revisits a channel dropped from restrict_channels,
            # so this is also the only chance to stop carrying a stale
            # entry for it forever (a small, bounded leak otherwise -- see
            # item 32 -- rather than anything that could strand a mode).
            catch { unset last_off([casefold $chan]) }
            set v [st_get $chan]
            if {[llength $v]} {
                cancel_timer $chan
                st_clear $chan
                if {[lindex $v 1]} {
                    putlog "\[autorestrict\] $chan is no longer in\
                        restrict_channels; dropping its state. This script\
                        was timing a +R there and will NOT lift it now --\
                        remove it by hand if it is still set."
                } else {
                    putlog "\[autorestrict\] $chan is no longer in\
                        restrict_channels; dropping its state (its mode is\
                        untouched)."
                }
            }
            return
        }
        if {![validchan $chan]} { st_clear $chan ; return }

        set v [st_get $chan]
        set is_on [chan_has_mode $chan R]

        if {$is_on == -1} { return }   ;# still can't see it; try later

        if {!$is_on} {
            # Whatever we thought, +R is not set. Nothing to time.
            if {[llength $v]} {
                cancel_timer $chan
                st_clear $chan
                putlog "\[autorestrict\] $chan is not +R; cleared stale state"
            }
            return
        }

        # +R is on but nothing is timing it -- per item 35, this script
        # never claims a +R it did not push itself, including one already
        # sitting on the channel at (re)join/reload. Left alone.
        if {![llength $v] || ![lindex $v 1]} {
            putlog "\[autorestrict\] $chan already +R on (re)join/reload;\
                not set by this script, so not timing it."
            return
        }

        # Already timed: resume the countdown from the stored absolute
        # deadline.
        set deadline [lindex $v 2]
        arm_timer $chan $deadline
        set left [expr {($deadline - [unixtime]) / 60}]
        if {$left < 0} { set left 0 }
        putlog "\[autorestrict\] resumed +R countdown on $chan; due off in ${left}m"
    }

    proc resync_all {} {
        variable state
        foreach {c v} [array get state] {
            if {[catch { resync [lindex $v 0] } err]} {
                putlog "\[autorestrict\] resync failed for [logsafe [lindex $v 0]]: $err"
            }
        }
    }

    #=====================================================================
    # PUBLIC HELP COMMAND (!restricthelp)
    #
    # Everything below answers the in-channel !restricthelp trigger. It
    # reads restrict_seconds/restrict_channels/trusted_masks directly --
    # no copy, no separate config -- so the help text can never drift out
    # of sync with what the rest of this script actually does.
    #=====================================================================

    proc help_id {nick host} {
        set nick [string range $nick 0 64]
        set host [string range $host 0 128]
        return [string tolower "$nick!$host"]
    }

    # Returns 1 (and does NOT record a hit) if the caller is still on
    # cooldown. Returns 0 and records this hit if they're clear to proceed.
    # Same shape as trusted_source/chan_has_mode above: read the two scope
    # flags once, test only the table(s) that scope actually uses, and
    # write only those same tables on a clear hit -- under "global" or
    # "percmd" alone, the unused table would otherwise fill with entries
    # nothing ever consults, burning memory until the sweep ages them out.
    proc help_ratelimited {nick host topic} {
        variable help_ratelimit_secs
        variable help_ratelimit_scope
        variable help_ratelimit_maxentries
        variable help_last_global
        variable help_last_percmd

        set now [unixtime]
        set id  [help_id $nick $host]
        set key "$id,$topic"
        set blocked 0

        set use_global [expr {$help_ratelimit_scope eq "global" || $help_ratelimit_scope eq "both"}]
        set use_percmd [expr {$help_ratelimit_scope eq "percmd" || $help_ratelimit_scope eq "both"}]

        if {$use_global} {
            if {[info exists help_last_global($id)]
                    && ($now - $help_last_global($id)) < $help_ratelimit_secs} {
                set blocked 1
            }
        }
        if {!$blocked && $use_percmd} {
            if {[info exists help_last_percmd($key)]
                    && ($now - $help_last_percmd($key)) < $help_ratelimit_secs} {
                set blocked 1
            }
        }

        if {!$blocked} {
            if {$use_global} {
                if {[array size help_last_global] >= $help_ratelimit_maxentries} {
                    help_evict_oldest help_last_global
                }
                set help_last_global($id) $now
            }
            if {$use_percmd} {
                if {[array size help_last_percmd] >= $help_ratelimit_maxentries} {
                    help_evict_oldest help_last_percmd
                }
                set help_last_percmd($key) $now
            }
        }
        return $blocked
    }

    # Removes the single oldest (smallest-timestamp) entry from the named
    # cooldown array, so a fast burst of distinct callers can inflate
    # neither table past help_ratelimit_maxentries regardless of how
    # quickly it arrives -- the time-based sweep below only ages out
    # entries once they're already stale, which a burst of all-fresh
    # entries is by definition not yet. arrname is only ever set
    # internally, from help_ratelimited above, never from user input.
    proc help_evict_oldest {arrname} {
        upvar #0 ::autorestrict::$arrname arr
        set oldest_key ""
        set oldest_val 0
        foreach k [array names arr] {
            if {$oldest_key eq "" || $arr($k) < $oldest_val} {
                set oldest_key $k
                set oldest_val $arr($k)
            }
        }
        if {$oldest_key ne ""} { unset arr($oldest_key) }
    }

    # Text bound for the channel/query, as opposed to logsafe (which is
    # for a short fragment embedded in a log line). Same control-byte
    # strip, longer cap.
    proc pub_safe {s} {
        regsub -all {[\r\n\001]} $s "" s
        return [string range $s 0 400]
    }

    # A PRIVMSG/NOTICE target, which has stricter rules than message text:
    # text may contain spaces, a target may not. pub_safe alone is not
    # enough here -- it strips control bytes but leaves spaces, and a
    # space in the target would split "$verb $target :$text" into a
    # different IRC command than intended rather than merely looking odd.
    # Take the first whitespace-delimited word and drop a leading ":" (which
    # would otherwise start the trailing parameter early).
    proc pub_target {s} {
        regsub -all {[\r\n\001]} $s "" s
        set s [lindex [split [string trim $s]] 0]
        if {[string index $s 0] eq ":"} { set s [string range $s 1 end] }
        return [string range $s 0 63]
    }

    proc help_send {nick chan text} {
        variable help_output
        set text [pub_safe $text]

        switch -- $help_output {
            channel { set target $chan; set verb PRIVMSG }
            msg     { set target $nick; set verb PRIVMSG }
            notice  { set target $nick; set verb NOTICE  }
            default { set target $nick; set verb NOTICE  }
        }
        # The target is sanitized too, not just the text -- see pub_target
        # for why it needs stricter treatment than the message body. The
        # server should never relay a nick that needs this, which is
        # exactly the assumption logsafe above also refuses to rely on.
        set target [pub_target $target]
        if {$target eq ""} {
            set target [pub_target $nick]
            set verb   NOTICE
        }
        if {$target eq "" || $text eq ""} { return }

        # puthelp: the full index is eight lines, and on putserv a few
        # !restricthelp users could hold up the bot's own mode/kick traffic.
        puthelp "$verb $target :$text"
    }

    proc help_minutes {secs} {
        if {![string is integer -strict $secs] || $secs <= 0} { return "an unknown amount of time" }
        set m [expr {$secs / 60}]
        if {$m < 1} { set m 1 }
        return "${m}m"
    }

    # Builds the topic list fresh on every call, straight from the live
    # config variables -- see the section banner above.
    proc help_menu {} {
        variable restrict_seconds
        variable escalate_seconds
        variable escalate_window_seconds
        variable restrict_channels
        variable trusted_masks

        set restrict_txt  [help_minutes $restrict_seconds]
        set escalate_txt  [help_minutes $escalate_seconds]
        set window_txt    [help_minutes $escalate_window_seconds]

        if {[llength $restrict_channels]} {
            set chan_txt $restrict_channels
        } else {
            set chan_txt "every channel the bot is on"
        }

        if {[llength $trusted_masks]} {
            set trust_txt "a kick from, or a kick report whose sender\
                matches: $trusted_masks"
        } else {
            set trust_txt "a kick by any channel op"
        }

        return [list \
            [list overview  "This channel goes \x02+R\x02 (registered users only) for $restrict_txt after a qualifying kick, then reverts to normal on its own. It is automatic and temporary -- nobody has to remember to undo it. This only applies to +R this bot itself sets; +R set any other way (an op by hand, another script) is left alone and this bot will not touch it."] \
            [list trigger   "Only $trust_txt causes a FRESH +R to be pushed. A kick or report from anyone else never pushes +R -- and see \x02manual\x02: a +R this bot did not push itself is never timed for removal either."] \
            [list kick      "A qualifying kick turns +R on if it is not already on. If +R is already on, nothing further happens -- it is never restarted or extended."] \
            [list escalate  "Normally +R lasts $restrict_txt. If another qualifying kick arrives within $window_txt of the last time +R actually came back off, this one lasts $escalate_txt instead."] \
            [list scope     "Managed here: $chan_txt."] \
            [list manual    "Ops can lift or reconfigure this on the bot's partyline with \x02.autorestrict\x02 (status/off/clear -- master flag). Only a +R this bot pushed itself is tracked and timed -- +R set by an op or another script is left alone; remove it by hand if you want it off."] \
        ]
    }

    proc help_footer {} {
        return "This is background automation, not a moderation action against you personally -- ask a channel op if you have questions about why you were kicked."
    }

    proc cmd_help {nick host hand chan arg} {
        variable help_trigger

        set sub [string tolower [string trim $arg]]
        set menu [help_menu]

        # The cooldown bucket has to be resolved BEFORE rate limiting,
        # because it is part of the percmd key.
        #
        # Two bugs fixed here at once:
        #
        #  a) this used to pass $help_trigger, a CONSTANT, as the "topic".
        #     Every call from one user produced the identical key and
        #     help_last_percmd became a byte-for-byte duplicate of
        #     help_last_global -- twice the memory for zero extra
        #     throttling -- while the variable's own comment advertised
        #     the key as "id,topic". Under scope "percmd" it also meant
        #     the per-topic limit did not exist.
        #
        #  b) keying on the raw argument instead would be worse: $arg is
        #     attacker-controlled and unbounded, so "!restricthelp <4kb of
        #     junk>", repeated with different junk, would mint an unlimited
        #     number of distinct keys, each one a 4kb array key. help_id
        #     already caps nick and host for precisely this reason.
        #     Anything that is not a real topic collapses into one shared
        #     bucket, so a user's key count is bounded by the topic list
        #     rather than by what they can type.
        set valid 0
        foreach entry $menu {
            if {$sub eq [lindex $entry 0]} { set valid 1 ; break }
        }
        if {$sub eq ""} {
            set bucket "(index)"
        } elseif {$valid} {
            set bucket $sub
        } else {
            set bucket "(unknown)"
        }

        # Rate limiting comes before ANY reply path below, including the
        # not-managed-here one. Gating the channel check ahead of it would
        # leave that reply unthrottled, which is a flood vector: the bot
        # sits in channels this script does not manage, and anyone there
        # could hold down the trigger for an unlimited stream of replies.
        if {[help_ratelimited $nick $host $bucket]} { return }

        # Every other bind in this script gates on channel_allowed; this
        # one was the exception. Without it the command answered in EVERY
        # channel the bot sits in, and confidently told people in channels
        # this script does not manage that "this channel goes +R after a
        # kick or ban", naming a managed scope that is some other channel
        # entirely -- advice that is simply false where it was being read.
        # Answer honestly rather than either lying or ignoring them.
        if {![channel_allowed $chan]} {
            help_send $nick $chan "This channel is not managed by the\
                auto-restrict script -- nothing here sets it +R\
                automatically, so $help_trigger has nothing to explain\
                about this channel."
            return
        }

        if {$sub eq ""} {
            help_send $nick $chan "Why is this channel +R? Topics -- use \"$help_trigger <topic>\" for one, or read on for all of them:"
            foreach entry $menu {
                lassign $entry topic desc
                help_send $nick $chan "\x02$topic\x02 -- $desc"
            }
            help_send $nick $chan [help_footer]
            return
        }

        foreach entry $menu {
            lassign $entry topic desc
            if {$sub eq $topic} {
                help_send $nick $chan "\x02$topic\x02 -- $desc"
                return
            }
        }

        set topics {}
        foreach entry $menu { lappend topics [lindex $entry 0] }
        help_send $nick $chan "No such topic \"[pub_safe $sub]\". Topics: $topics"
    }

    # Arms/re-arms the stale-cooldown-entry sweep for the help ratelimit
    # tables. No dedup logic needed here the way schedule_cleanup patterns
    # elsewhere need it: this proc's own name starts with
    # ::autorestrict::, so the generic "sweep every ::autorestrict::*
    # utimer by command name" loop at the top of this file already kills
    # any pending one before this is ever called again on a rehash.
    proc help_schedule_cleanup {} {
        variable help_ratelimit_cleanup_secs
        catch { utimer $help_ratelimit_cleanup_secs ::autorestrict::help_cleanup }
    }

    proc help_cleanup {} {
        variable help_last_global
        variable help_last_percmd
        variable help_ratelimit_secs

        set keep 7200
        if {($help_ratelimit_secs * 2) > $keep} { set keep [expr {$help_ratelimit_secs * 2}] }
        set cutoff [expr {[unixtime] - $keep}]

        foreach key [array names help_last_global] {
            if {$help_last_global($key) < $cutoff} { unset help_last_global($key) }
        }
        foreach key [array names help_last_percmd] {
            if {$help_last_percmd($key) < $cutoff} { unset help_last_percmd($key) }
        }

        help_schedule_cleanup
    }

    #-------------------------------------------------------------------
    # .autorestrict -- partyline status/control (master 'm' flag).
    #
    # There was no command at all before this: an op wondering why a
    # channel was +R had only the log. Added .autorestrict (master flag)
    # with status/off/clear subcommands.
    #
    #   .autorestrict              status of every tracked channel
    #   .autorestrict status       same
    #   .autorestrict off <chan>   lift +R now (only a +R this script is timing)
    #   .autorestrict clear <chan> stop tracking, leave the mode alone
    #   .autorestrict help         this list
    #-------------------------------------------------------------------
    proc dcc_usage {idx} {
        variable restrict_seconds
        variable escalate_seconds
        variable escalate_window_seconds
        variable trusted_masks
        variable help_trigger
        putdcc $idx "\002.autorestrict\002 -- +R after a qualifying kick,\
            lifted after [expr {$restrict_seconds / 60}]m normally. +R set\
            any other way is left alone (not tracked, not timed)."
        putdcc $idx "  .autorestrict \[status\]      -- what is tracked right now"
        putdcc $idx "  .autorestrict off <chan>   -- queue -R now; keep tracking until the server confirms it"
        putdcc $idx "  .autorestrict clear <chan> -- forget the channel, leave its mode alone"
        putdcc $idx "  A qualifying kick only starts the countdown if it isn't already running -- it is never restarted or extended."
        putdcc $idx "  If another qualifying kick lands within\
            [expr {$escalate_window_seconds / 60}]m of the last time +R\
            actually came back off on that channel, the next +R lasts\
            [expr {$escalate_seconds / 60}]m instead of\
            [expr {$restrict_seconds / 60}]m."
        if {[llength $trusted_masks]} {
            putdcc $idx "  Only a kick from, or a kick report from,\
                $trusted_masks pushes a fresh +R; anyone else's is ignored\
                silently as a trigger."
        }
        putdcc $idx "  Only a +R this script pushed itself gets timed for\
            removal -- +R set any other way (an op by hand, another\
            script) is left alone."
        putdcc $idx "  Channel users can ask \x02$help_trigger\x02 for the same info in-channel."
    }

    proc dcc_cmd {hand idx text} {
        variable state
        variable restrict_channels
        variable trusted_masks
        variable retry_seconds
        set args [split [string trim $text]]
        set sub  [string tolower [lindex $args 0]]
        set chan [lindex $args 1]

        switch -- $sub {
            "" - "status" {
                if {[llength $restrict_channels]} {
                    putdcc $idx "autorestrict: managing $restrict_channels"
                } else {
                    putdcc $idx "autorestrict: managing every channel the bot is on"
                }
                # Untrusted kicks/reports are dropped without a log line,
                # so this is the only place an op can see why nothing fired.
                if {[llength $trusted_masks]} {
                    putdcc $idx "  triggered only by: $trusted_masks"
                } else {
                    putdcc $idx "  triggered by: anyone's native kick (trusted_masks is empty; kick-report text is ignored)"
                }
                set now [unixtime]
                set any 0
                foreach c [lsort [array names state]] {
                    lassign $state($c) ch owned deadline retries started
                    set any 1
                    set mode [chan_has_mode $ch R]
                    if {$mode == 1} {
                        set modetxt "+R"
                    } elseif {$mode == 0} {
                        set modetxt "not +R"
                    } else {
                        set modetxt "mode unknown"
                    }
                    if {$owned} {
                        set left [expr {($deadline - $now) / 60}]
                        if {$left < 0} { set left 0 }
                        set note ""
                        if {$retries > 0} { set note " (retrying, $retries so far)" }
                        putdcc $idx [format "  %-20s timed, %s, due off in %dm%s" \
                            $ch $modetxt $left $note]
                    } else {
                        putdcc $idx [format "  %-20s not tracked (%s)" \
                            $ch $modetxt]
                    }
                }
                if {!$any} { putdcc $idx "  nothing tracked." }
            }
            "off" {
                if {$chan eq "" || ![validchan $chan]} {
                    putdcc $idx "Usage: .autorestrict off <channel>"
                    return 1
                }
                if {![st_owned $chan]} {
                    putdcc $idx "Not tracking a +R on $chan -- refusing.\
                        Use .mode $chan -R by hand if you want it off."
                    return 1
                }
                # Do NOT cancel or clear tracking until the server confirms
                # the mode change. pushmode only queues the IRC MODE line; a
                # successful return does not prove that -R reached the
                # channel. If the bot is split/deopped immediately after this
                # command, clearing the timer here would strand +R exactly
                # like the old failure path did.
                #
                # Keep the original episode record on a push failure and let
                # expire() retry it. For a successful queue, make the retry
                # deadline immediate so the confirmation is checked promptly;
                # on_mode_restrict_off will cancel/clear it when -R is actually
                # observed. If no confirmation arrives, expire() keeps
                # retrying under the normal overdue policy.
                set v [st_get $chan]
                if {![llength $v]} {
                    putdcc $idx "Tracking state disappeared for $chan; refusing to queue -R."
                    return 1
                }
                set started [lindex $v 4]
                if {![string is integer -strict $started] || $started < 0} {
                    set started [unixtime]
                }
                set now [unixtime]
                if {[catch { pushmode $chan -R } err]} {
                    set retries [lindex $v 3]
                    if {![string is integer -strict $retries] || $retries < 0} {
                        set retries 0
                    }
                    incr retries
                    # Preserve the episode deadline on failure. The timer is
                    # re-armed for a near-term retry, while expire() still
                    # uses the original deadline for overdue accounting.
                    st_put $chan 1 [lindex $v 2] $retries $started
                    arm_timer $chan [expr {$now + $::autorestrict::retry_seconds}]
                    putdcc $idx "pushmode -R failed on $chan: $err; retained tracking and will retry in $retry_seconds seconds."
                    return 1
                }

                # pushmode succeeded only in queuing the request. Move the
                # next check to now rather than waiting for the old deadline.
                st_put $chan 1 $now 0 $started
                arm_timer $chan $now
                putlog "\[autorestrict\] -R on $chan forced by $hand; queued and awaiting server confirmation"
                putdcc $idx "-R queued for $chan; tracking retained until the server confirms it."
            }
            "clear" {
                if {$chan eq ""} {
                    putdcc $idx "Usage: .autorestrict clear <channel>"
                    return 1
                }
                cancel_timer $chan
                st_clear $chan
                putlog "\[autorestrict\] tracking for $chan cleared by $hand\
                    (channel mode left as-is)"
                putdcc $idx "Cleared tracking for $chan. Its mode was not changed."
            }
            default { dcc_usage $idx }
        }
        return 1
    }

    # Binds. Each registration is recorded in ::autorestrict::bound and it
    # is that record -- not the literal values written here -- that gets
    # unbound on the next load. Unbinding by literal is a guaranteed no-op
    # the moment a mask or flag is edited, which would leave the old bind
    # live alongside the new one: every event firing twice, two
    # independent -R countdowns, and the first utimer id leaked. This also
    # correctly handles kick_notice_watch_pubm/_notc being flipped off on a
    # rehash -- the pubm/notc entry simply won't be in the fresh list below,
    # and the generic unbind-by-record loop here still removes whatever was
    # bound for it last time.
    variable bound
    if {![info exists bound]} { set bound {} }
    foreach b $bound {
        catch { unbind [lindex $b 0] [lindex $b 1] [lindex $b 2] [lindex $b 3] }
    }
    set bound {}
    # Clear the historical literal registrations too, for the first load of
    # this revision on a bot still carrying the previous (ban-triggering)
    # revision's binds -- on_kick and on_mode_ban no longer exist (item 30/
    # 31), so these are pure cleanup and are never re-bound below.
    catch { unbind kick - * ::autorestrict::on_kick }
    catch { unbind mode - "* +b" ::autorestrict::on_mode_ban }
    catch { unbind mode - "* +R" ::autorestrict::on_mode_restrict_on }
    catch { unbind mode - "* -R" ::autorestrict::on_mode_restrict_off }
    catch { unbind join - * ::autorestrict::on_join }
    catch { unbind dcc m autorestrict ::autorestrict::dcc_cmd }

    # Precise masks: the old "bind mode - *" invoked the proc for every
    # mode change on every channel and then discarded almost all of them.
    # pubm/notc can't be narrowed that way (the channel to restrict is
    # inside the message text, not knowable from a mask), so those two
    # are gated by kick_notice_watch_pubm/_notc instead, each only added
    # to the list below when its flag is on. "bind kick - *" is likewise
    # unnarrowable (any channel, any kicker) -- channel_allowed and
    # trusted_source inside on_native_kick do the filtering instead.
    #
    # The pub bind uses $help_flags/$help_trigger (config, not literal)
    # the same way masterhelp.tcl binds its own !bhelp -- unlike the fixed
    # binds above, this one's trigger/flags are meant to be edited, so it
    # has to be looked up here, not hardcoded. The generic bound-tracking
    # loop above already handles unbinding whatever this resolved to on
    # the PREVIOUS load, so a rehash that edits either one still can't
    # leave a stale bind behind.
    set to_bind [list \
            [list kick - *        ::autorestrict::on_native_kick] \
            [list mode - "* +R"   ::autorestrict::on_mode_restrict_on] \
            [list mode - "* -R"   ::autorestrict::on_mode_restrict_off] \
            [list join - *        ::autorestrict::on_join] \
            [list dcc  m autorestrict ::autorestrict::dcc_cmd] \
            [list pub  $help_flags $help_trigger ::autorestrict::cmd_help]]
    if {$kick_notice_watch_pubm} {
        lappend to_bind [list pubm - * ::autorestrict::on_pubm_kick_notice]
    }
    if {$kick_notice_watch_notc} {
        lappend to_bind [list notc - * ::autorestrict::on_notc_kick_notice]
    }
    foreach b $to_bind {
        if {[catch { bind [lindex $b 0] [lindex $b 1] [lindex $b 2] [lindex $b 3] } err]} {
            putlog "\[autorestrict\] failed to bind [lindex $b 0]\
                [lindex $b 2]: $err"
        } else {
            lappend bound $b
        }
    }
    catch { unset b }
    catch { unset err }
    catch { unset to_bind }

    # Actually load from disk now, if this was flagged above as a fresh
    # interpreter (real restart) rather than a re-source.
    if {[info exists ::autorestrict::need_state_load] \
            && $::autorestrict::need_state_load} {
        catch { st_load }
    }
    catch { unset ::autorestrict::need_state_load }

    # Re-arm countdowns preserved across this (re)load.
    catch { resync_all }

    # Arm the !restricthelp cooldown sweep. Safe to call unconditionally
    # on every (re)load -- see help_schedule_cleanup for why no dedup
    # logic is needed here.
    catch { help_schedule_cleanup }
}

# Banner derived from the configured value rather than the hardcoded "45
# minutes" this used to print, which went stale the moment restrict_seconds
# was edited and described the script incorrectly to whoever read the log.
putlog "autorestrict.tcl loaded: +R this script pushes after a qualifying\
kick is removed after\
[expr {$::autorestrict::restrict_seconds / 60}] minutes normally, or\
[expr {$::autorestrict::escalate_seconds / 60}] minutes if another\
qualifying kick lands within\
[expr {$::autorestrict::escalate_window_seconds / 60}] minutes of the\
last time +R actually came back off; only a trusted\
kick (or, if configured, a trusted relay's kick-report message) pushes a\
fresh +R; it never sets +R twice and never restarts\
or extends a running countdown; +R set any other way is left alone (not\
tracked, not timed); the countdown survives a rehash, a deop,\
a netsplit and a restart.\
.autorestrict on the partyline for status,\
$::autorestrict::help_trigger in-channel for the same explanation; .autorestrict off retains tracking until -R is confirmed."
