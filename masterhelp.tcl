# ============================================================
#  masterhelp.tcl - top-level "!bhelp" menu
#  Points users at the real help commands owned by the other
#  scripts. Does not touch those scripts.
#
#  !dalhelp, !whohelp, !fighthelp, !dcchelp, !costhelp, and !talkbothelp
#  are NOT bound here - dalnet.tcl, whois.tcl, fight.tcl, and talkbot.tcl
#  (talkbot.tcl owns !dcchelp, !costhelp/talkbot_cost.tcl, and its own
#  !talkbothelp) already own those triggers and answer them directly, so
#  this script stays out of the way.
#
#  !dcchelp and !costhelp used to be separate top-level entries here.
#  talkbot.tcl grew its own "!talkbothelp" listing that already covers
#  both of them (along with the mention-trigger AI persona and
#  !talkbotfacts/!talkbotpic), so carrying them as separate lines here
#  just duplicated that index and let the two copies drift. Folded both
#  into the !talkbothelp entry's description instead -- one line, one
#  place that actually has to stay in sync with talkbot.tcl.
#
#  $channel controls where these public help binds actually respond.
#  "*" means all channels; otherwise set one or more channel names separated
#  by spaces, e.g. "#prototype #games". Matching is case-insensitive.
#  An empty value disables public replies. This is a config setting: edit it
#  and rehash.
#
#  $output (channel/msg/notice) is a global setting: it controls where
#  !bhelp answers for EVERY caller, not a per-user or per-call choice.
#  Bot owners (flag n) can change it at runtime for everyone with
#  "!bhelp set <channel|msg|notice>" (aliases pm/dm/privmsg/private also
#  map to msg) -- see masterhelp::parse_mode_arg for the accepted words.
#  A non-owner typing "!bhelp set ..." is told only the owner can do that;
#  everyone still gets the plain menu from a bare "!bhelp". "!bhelp mode"
#  is a read-only query anyone can use to see the current setting.
#
#  The menu previously also advertised "!aihelp -- AI, news, stock,
#  weather, translate commands". Removed: nothing on this bot binds
#  !aihelp, and the AI script's trigger is !skynethelp, so the line
#  pointed users at a command that does not answer. This menu is a plain
#  list of strings with no link to any real bind, so entries here go
#  stale silently -- check a trigger actually exists before adding one.
#
#  The per-entry "Bot may not be on this network" suffix was removed from
#  every description and replaced by a single footer line printed once
#  after the menu (masterhelp::footer). Repeating it on four of ten lines
#  padded each of those lines toward the 512-byte IRC message limit and
#  read as if it applied only to those four.
#
#  !mafiahelp's description was also trimmed: the topic-list and the
#  "!mafiaexthelp is gone" migration note were dropped now that the
#  rename is old news -- !mafiahelp itself documents its own topics.
#
#  Added !openrpghelp. Verified against openrpg.tcl's own bind table
#  (::orpg::pub_binds) before adding, per the warning above: it really is
#  bound there, to ::orpghelp::cmd_help. Its own topic index (Account,
#  Combat, Dungeons, Exploration, Gear, Info, Inventory, Party, PvP,
#  Quests, Shop, Spells, System, Admin) is left to that script to print --
#  this line stays one summary like every other entry, and !openrpghelp
#  answers "!openrpghelp topic" for the detail.
#
#  Added !restricthelp. (It is now bound by restrict.tcl itself, to
#  ::autorestrict::cmd_help; the standalone restricthelp.tcl is gone.) Unlike the other entries here, the script it points to has no
#  public command of its own to answer for otherwise: autorestrict.tcl's
#  only interface is ".autorestrict" on the DCC partyline, master-flag
#  only, so a channel user hit with +R had no way to ask the bot
#  anything about it. !restricthelp is that answer; its own topic index
#  (overview, trigger, ban, kick, scope, manual) is left to that script
#  to print, same as !openrpghelp above.
#
#  Hardening pass: the `bind pub` registration leaked across a rehash
#  that edits $trigger/$flags the same way the cleanup utimer used to
#  leak (see schedule_cleanup below) -- fixed by tracking what was
#  actually bound. Added validation for $output and $trigger to match
#  the existing validation on the rate-limit knobs. Added a hard cap
#  (ratelimit_maxentries) on the cooldown tables so a fast burst of
#  distinct callers can't grow them unbounded between sweeps. Collapsed
#  send()'s duplicated switch into one, so its two cases can't drift
#  out of sync. ratelimited() now only writes the table(s) the active
#  scope actually reads -- under "global" or "percmd" the unused table
#  was still being filled with entries nothing ever consulted, burning
#  memory until the sweep aged them out.
#  Added !bsdhelp and !debhelp. Verified against each script's own `bind
#  pub` (bsdhelp.tcl binds !bsdhelp plus the !fbsdhelp/!obsdhelp/!nbsdhelp
#  shortcuts; debhelp.tcl binds !debhelp) before adding, per the warning
#  above. Both scripts print their own topic index for "!<x>help <topic>"
#  detail, same as !openrpghelp/!restricthelp -- this menu line stays one
#  summary each.
#
#  Added !winhelp to the !oshelp category, alongside !bsdhelp/!debhelp.
#  Verified against winhelp.tcl's own `bind pub` (binds !winhelp to
#  winhelp::cmd) before adding, per the warning above. Same pattern as the
#  other two: winhelp.tcl prints its own topic index for "!winhelp <topic>"
#  detail, so this line stays one summary.
#
#  Added !susehelp to the !oshelp category, alongside !bsdhelp/!debhelp/
#  !winhelp. Verified against susehelp.tcl's own `bind pub` (binds
#  !susehelp to susehelp::cmd) before adding, per the warning above. Same
#  pattern as the other three: susehelp.tcl prints its own topic index for
#  "!susehelp <topic>" detail (about, zypper, repos, yast, systemd,
#  network, ssh, firewall, disks, users, kernel, desktop, build,
#  troubleshoot), so this line stays one summary.
#
#  Hardening pass: masterhelp::cmd's argument tokenizing switched from
#  [split [string trim $arg]] to a \S+ regexp scan -- split's default
#  delimiter set is applied per-character, so "!bhelp set  channel" (two
#  spaces) produced an empty-string list element and silently broke the
#  mode-arg lookup. This was already fixed in bsdhelp.tcl/debhelp.tcl/
#  winhelp.tcl (all three copied this file's pattern) but never backported
#  to the original. Also added "!bhelp mode" as a read-only query of the
#  current output setting, for parity with those same three scripts.
#
#  Restructured the top-level menu into four categories so it stops
#  growing one line per script forever: !oshelp (bsdhelp, debhelp,
#  susehelp, winhelp), !gamehelp (fighthelp, fishhelp, golfhelp,
#  homerunhelp, mafiahelp, openrpghelp, pokerhelp), !irchelp (dalhelp,
#  guardhelp, restricthelp, whohelp), !otherhelp (poemshelp, talkbothelp).
#  $menu now lists just those four triggers; $categories holds each one's
#  sub-list in the same {trigger description} shape, printed by the new
#  masterhelp::cmd_category (shared by all four, so their output can't
#  drift apart) when its trigger fires. All four are bound here -- same
#  as !bhelp, NOT like !dalhelp/!whohelp/etc., which stay unbound because
#  other scripts own and answer them directly (see top of file).
#  bound_subtriggers tracks what was actually bound for these four, same
#  rehash-leak guard as bound_trigger/bound_flags.
#
#  Split !gamehelp into four sub-categories -- it had grown to seven
#  entries and the masterhelp.zip drop added eight more games needing
#  index entries (Duck Hunt, baseball, bowling, battleship, risk,
#  blackjack, casino, cribbage, clue, com, convert, life, monopoly,
#  scrabble, stairs and slides), which would have made !gamehelp's
#  single screen unreadable. !gamehelp's own sub-list is now just an
#  index pointing at !sportgamehelp/!fightgamehelp/!cardgamehelp/
#  !othergamehelp, each of which is bound and printed by the same
#  masterhelp::cmd_category proc as !oshelp/!irchelp/!otherhelp -- just
#  nested one level deeper under $categories. Every trigger added was
#  verified against its own script's `bind pub` before being listed here,
#  per the standing warning above:
#    !sportgamehelp: !duckhunthelp (Duck_Hunt.tcl), !baseballhelp
#      (baseball.tcl), !bowlhelp (bowling.tcl), !fishhelp, !golfhelp,
#      !homerunhelp (all three pre-existing).
#    !fightgamehelp: !bshiphelp (battleship.tcl), !riskhelp (risk.tcl),
#      !mafiahelp and !fighthelp (both pre-existing).
#    !cardgamehelp: !bjhelp (blackjack.tcl), !casinohelp (casino.tcl),
#      !cribbagehelp (cribbage.tcl), !pokerhelp (pre-existing).
#    !othergamehelp: !scrabblehelp (BlackScrabble.tcl), !cluehelp
#      (clue.tcl), !comhelp (com.tcl), !converthelp (convert.tcl),
#      !lifehelp (life.tcl), !monohelp (monopoly.tcl), !stairshelp
#      (StairsAndSlides.tcl), !openrpghelp (pre-existing).
#  Also added !spyhelp (spychan.tcl, verified via its own `bind pub`) to
#  the existing !irchelp sub-list, alphabetically between !restricthelp
#  and !whohelp.
#
#  Moved !comhelp and !converthelp out of !othergamehelp and into
#  !otherhelp -- com.tcl (bot restart/rehash/die) and convert.tcl (unit/
#  currency conversion) are not games, so they belonged in the catch-all
#  category, not the games one. !othergamehelp's own summary line (in its
#  parent !gamehelp sub-list) and !otherhelp's top-level $menu line were
#  both updated to match.
#
#  Added !archhelp and !buntuhelp to !oshelp, alongside !bsdhelp/!debhelp/
#  !susehelp/!winhelp. Both are this bot's own new scripts (archhelp.tcl/
#  buntuhelp.tcl), built as debhelp.tcl's siblings, so the same "verify
#  the bind exists" warning above applies just as much to in-house
#  scripts as third-party ones: confirmed each binds its own trigger
#  (archhelp::cmd to !archhelp, buntuhelp::cmd to !buntuhelp) before
#  listing it here. Same pattern as every other !oshelp entry: each
#  prints its own topic index for "!<x>help <topic>" detail, so these
#  lines stay one summary each. !oshelp's own top-level $menu line was
#  updated to name both.
#
#  Added !linuxhelp to !oshelp, alongside !archhelp/!bsdhelp/!buntuhelp/
#  !debhelp/!susehelp/!winhelp. Verified against linuxhelp.tcl's own
#  `bind pub` (binds !linuxhelp to linuxhelp::cmd) before adding, per the
#  standing warning above. Unlike the other !oshelp entries, linuxhelp.tcl
#  isn't scoped to one distro -- it's the general/distro-agnostic sibling
#  covering core POSIX/GNU shell and userland material shared across all
#  of them (bash, files, text processing, processes, networking, etc, per
#  its own linux_data.tcl). Same pattern as every other !oshelp entry
#  otherwise: it prints its own topic index for "!linuxhelp <topic>"
#  detail, so this line stays one summary. !oshelp's own top-level $menu
#  line was updated to name it.
# ============================================================

namespace eval masterhelp {
    # Config uses plain `set`, so every .rehash applies edits. Runtime state
    # that must survive a rehash ($output, the cooldown tables, the bound_*
    # records) is declared with a bare `variable` plus an `info exists`
    # guard, because `variable name value` ASSIGNS on every source.
    set trigger  "!bhelp"
    set flags    "-|-"      ;# who may use !bhelp: -|- everyone, o ops, n owner...

    # Channel scope for all public help commands in this file.
    # "*" means every channel. Otherwise use one or more channel names,
    # separated by whitespace, e.g. "#help #games". Matching is case-
    # insensitive. This is a configuration setting: edit it and rehash.
    # An empty value disables the public help commands on all channels.
    set channel "#chan #chan"

    # notice | msg | channel. Can also be changed at runtime by
    # "!bhelp set <mode>" and holds until changed again (a rehash keeps it;
    # a restart goes back to this default). The guard is what keeps it:
    # `variable output "notice"` would reset it on every rehash.
    variable output
    if {![info exists output]} { set output "notice" }

    # --- rate limiting ---
    set ratelimit_secs  15        ;# seconds a user must wait between uses

    # Which cooldown(s) a user must clear.
    #   global = one shared cooldown across all mhelp commands per user
    #   percmd = separate cooldown per command per user
    #   both   = user must clear BOTH the global and the per-command cooldown
    set ratelimit_scope "both"

    # How often the stale-entry sweep runs, in SECONDS -- see the utimer in
    # masterhelp::schedule_cleanup (utimer takes seconds; eggdrop's `timer` takes
    # MINUTES, which is what this used to be passed to).
    set ratelimit_cleanup_secs 3600

    # Hard cap on how many distinct cooldown entries last_global/last_percmd
    # may hold at once. The hourly sweep (masterhelp::cleanup) only ages out
    # entries once they're stale, so it can't stop either table from growing
    # past any bound during an actual fast burst of distinct callers -- a
    # flood of unique nick!host ids arriving within the same few seconds is,
    # by definition, all "fresh" and nothing a time-based sweep would touch
    # yet. See the eviction in masterhelp::ratelimited for the actual bound.
    set ratelimit_maxentries 5000

    # Category triggers are only rate limited per trigger (see
    # ratelimited's scope_override), so one user could fire !bhelp and all
    # eight category triggers back to back and pull ~55 lines out of the
    # bot in a few seconds. burst_max replies per ratelimit_secs per user,
    # across every trigger here, caps that.
    set burst_max 3
    variable last_burst                ;# array: id -> list of recent reply times
    if {![array exists last_burst]} { array set last_burst {} }

    variable last_global               ;# array: id -> unixtime of last mhelp use (any command)
    variable last_percmd               ;# array: id,trig -> unixtime of last use of that command
    # Preserve cooldown state across Eggdrop rehashes. Reinitializing these
    # arrays on every source would let users bypass rate limits after a reload.
    if {![array exists last_global]} { array set last_global {} }
    if {![array exists last_percmd]} { array set last_percmd {} }

    # Track the trigger/flags actually registered with `bind`, preserved
    # across rehashes by the same guard pattern as last_global/last_percmd
    # above. Needed so the bind/unbind block at the bottom of this file can
    # unbind the OLD registration by its real former values instead of the
    # new $trigger/$flags -- unbinding by the new values is a guaranteed
    # no-op the moment an admin edits either one, which would leave the old
    # bind permanently active alongside the new one. Same failure mode as
    # the utimer leak fixed in schedule_cleanup below, just for `bind`.
    variable bound_trigger
    variable bound_flags
    if {![info exists bound_trigger]} { set bound_trigger "" }
    if {![info exists bound_flags]}   { set bound_flags   "" }

    ;# Same rehash-leak guard as bound_trigger/bound_flags above, but for
    ;# the category triggers (!oshelp/!gamehelp/!irchelp/!otherhelp and the game subcategories),
    ;# which are always bound under $flags (they don't get their own
    ;# separate flags setting) but still need their OLD registration
    ;# unbound by what was actually bound, not by whatever $flags is now.
    variable bound_subtriggers
    if {![info exists bound_subtriggers]} { set bound_subtriggers {} }

    # ratelimited() tests the scope with two equality checks, so ANY value
    # outside this set matches neither -- and the rate limiter silently
    # turns itself off entirely rather than failing to a safe default. Force
    # a known-good value at load time, the way dalnet.tcl validates its own
    # ratelimitmode.
    if {$ratelimit_scope ni {global percmd both}} {
        putlog "masterhelp.tcl: invalid ratelimit_scope \"$ratelimit_scope\"; forcing both."
        set ratelimit_scope "both"
    }
    if {![string is integer -strict $ratelimit_secs] || $ratelimit_secs < 1} {
        putlog "masterhelp.tcl: invalid ratelimit_secs; forcing 15."
        set ratelimit_secs 15
    }
    if {![string is integer -strict $ratelimit_cleanup_secs] || $ratelimit_cleanup_secs < 60} {
        putlog "masterhelp.tcl: invalid ratelimit_cleanup_secs; forcing 3600."
        set ratelimit_cleanup_secs 3600
    }
    if {![string is integer -strict $ratelimit_maxentries] || $ratelimit_maxentries < 100} {
        putlog "masterhelp.tcl: invalid ratelimit_maxentries; forcing 5000."
        set ratelimit_maxentries 5000
    }
    # $output had no validation at all -- unlike the three knobs above, a
    # typo here degraded silently (falls through to per-user notices via
    # send()'s default case) with no logged warning. Match the others.
    if {$output ni {channel msg notice}} {
        putlog "masterhelp.tcl: invalid output \"$output\"; forcing channel."
        set output "channel"
    }
    # The channel setting is intentionally not restricted to "#" names here:
    # "*" and "all" are special, and Eggdrop may use unusual channel syntax in
    # test/private networks. Runtime matching remains exact.
    if {[string trim $channel] eq ""} {
        putlog "masterhelp.tcl: channel scope is empty; public help is disabled."
    }

    if {[string trim $trigger] eq ""} {
        putlog "masterhelp.tcl: empty trigger; forcing !bhelp."
        set trigger "!bhelp"
    }

    # Top-level menu now lists CATEGORIES, not individual help triggers.
    # {trigger  description} -- same shape/format as the old flat menu, and
    # still printed in exactly the order shown here.
    set menu {
        {!oshelp    "OS/handbook command references -- Arch, BSD, Debian, Linux, openSUSE, Ubuntu, Windows."}
        {!gamehelp  "Bot games -- see !sportgamehelp, !fightgamehelp, !cardgamehelp, !othergamehelp."}
        {!irchelp   "IRC/network services and channel tools -- DALnet, guard, restrict, spychan, who/whois."}
        {!otherhelp "Everything else -- bot control, unit/currency conversion, poems, talkbot AI persona."}
    }

    # Each category's own sub-list, in the same {trigger description} shape
    # as $menu above, printed by masterhelp::cmd_category when its trigger
    # is used. Edit these any time a script's help command changes; keep
    # each sub-list in strict alphabetical order by trigger, same rule as
    # $menu. Do not rely on Tcl dict/array ordering here either.
    #
    # !gamehelp no longer lists individual games directly -- it grew past a
    # single screenful, so it was split into four sub-categories the same
    # way the original flat $menu was split into !oshelp/!gamehelp/!irchelp/
    # !otherhelp (see header). !gamehelp's own sub-list below is just an
    # index pointing at those four triggers; masterhelp::cmd_category is the
    # same shared proc either way, so !sportgamehelp/!fightgamehelp/
    # !cardgamehelp/!othergamehelp are bound and printed identically to
    # !oshelp/!irchelp/!otherhelp -- just one more hop from !gamehelp.
    set categories {
        {!oshelp {
            {!archhelp    "Arch Linux command/documentation reference -- install, pacman, AUR, systemd, network, and more."}
            {!bsdhelp     "BSD command/handbook reference -- FreeBSD, OpenBSD, NetBSD (also !fbsdhelp/!obsdhelp/!nbsdhelp)."}
            {!buntuhelp   "Ubuntu command/documentation reference -- apt, snap, sources, systemd, network, and more."}
            {!debhelp     "Debian command/documentation reference -- apt, sources, systemd, network, disks, and more."}
            {!linuxhelp   "General Linux command/documentation reference -- shell, files, text processing, processes, networking, and more."}
            {!susehelp    "openSUSE command/documentation reference -- zypper, repos, YaST, systemd, network, disks, and more."}
            {!winhelp     "Windows command/documentation reference -- setup, winget, services, network, recovery, and more."}
        }}
        {!gamehelp {
            {!sportgamehelp "Sports games -- duck hunt, baseball, bowling, fishing, golf, homerun."}
            {!fightgamehelp "Fighting/strategy games -- battleship, fight, mafia, risk."}
            {!cardgamehelp  "Card games -- blackjack, casino, cribbage, poker."}
            {!othergamehelp "Other games -- clue, life, monopoly, openrpg, scrabble, stairs and slides."}
        }}
        {!sportgamehelp {
            {!baseballhelp  "!baseball game -- pitch/swing, stats and commands."}
            {!bowlhelp      "!bowl game -- USBC ten-pin bowling, frames, scoring, best, and commands."}
            {!duckhunthelp  "!duckhunt game -- shoot, reload, stats, shop, unarm, lastduck, admin."}
            {!fishhelp      "!fish game -- commands, gear, admin and gameplay."}
            {!golfhelp      "!golf game -- 9/18-hole rounds, shots, gear shop, career stats, leaderboard, and hole-in-one tournament."}
            {!homerunhelp   "!homerun game -- swing/pitch, shop, train and stats."}
        }}
        {!fightgamehelp {
            {!bshiphelp   "!battleship game -- ships, shots, fleet setup and commands."}
            {!fighthelp   "!fight game -- rules, moves, gear, boss/botboss, commands."}
            {!mafiahelp   "!mafia crime/RPG game -- crimes, guns, attacks, ranks and commands."}
            {!riskhelp    "!risk game -- territories, armies, attacks, and commands."}
        }}
        {!cardgamehelp {
            {!bjhelp        "!blackjack game -- betting, hit/stand/double, and commands."}
            {!casinohelp    "!casino games -- table games, betting and commands."}
            {!cribbagehelp  "!cribbage game -- deal, play, pegging, and commands."}
            {!pokerhelp     "!poker Texas Hold\x27em play-money IRC card game -- table, cards, betting, and commands."}
        }}
        {!othergamehelp {
            {!cluehelp     "!clue game -- Clue/Cluedo deduction, setup, suggest/accuse, and commands."}
            {!lifehelp     "!life game -- The Game of LIFE board game: college/career, pay days, houses, retirement, and commands."}
            {!monohelp     "!mono Monopoly game -- start, roll, build, mortgage, trade, jail, status, quit (also !monohelp)."}
            {!openrpghelp  "!openrpg RPG game -- races, classes, spells, gear, dungeons, raids."}
            {!scrabblehelp "!scrabble game -- tiles, plays, scoring, and commands."}
            {!stairshelp   "!stairs and slides board game -- join, dice, stats, and commands."}
        }}
        {!irchelp {
            {!dalhelp     "DALnet services index (ChanServ/NickServ/MemoServ)."}
            {!guardhelp   "channel guard -- commands, options, bans, and unban."}
            {!restricthelp "why the channel goes +R after a kick, who can trigger it, and how long it lasts."}
            {!spyhelp     "spychan botnet channel-relay -- watched channels relayed to a hub, and commands."}
            {!whohelp     "!wi/!wa/!ver lookups, !ip/!dom (domain) lookups."}
        }}
        {!otherhelp {
            {!comhelp     "bot control commands -- !brestart, !brehash, !bdie, !bhelp."}
            {!converthelp "unit/currency conversion commands -- temp, length, weight, volume, currency."}
            {!poemshelp   "poem commands -- !poem, !poems, !autopoem. Works in #poets only."}
            {!talkbothelp "talkbot AI persona -- mention/!talkbotfacts/!talkbotpic. Also !dcchelp and !costhelp."}
        }}
    }

    # Printed once, after the top-level menu AND after each category's
    # sub-list. Replaces the old per-entry "Bot may not be on this
    # network" suffix.
    set footer "If a !help command does not work, the bot may not be on this network."
}

proc masterhelp::id {nick host} {
    # Prevent attacker-controlled oversized array keys.
    set nick [string range $nick 0 64]
    set host [string range $host 0 128]
    return [string tolower "$nick!$host"]
}

# Returns 1 (and does NOT record a hit) if the user is still on cooldown.
# Returns 0 and records this hit if they're clear to proceed.
#
# scope_override, if non-empty, replaces $ratelimit_scope for this call
# only. Needed because !oshelp/!gamehelp/!irchelp/!otherhelp are reached
# by first typing !bhelp -- under the default "both"/"global" scope, that
# !bhelp call fills last_global($id), so the category trigger typed right
# after it hit the *global* cooldown and silently no-op'd, even though the
# category trigger itself had never been used before. Category triggers
# pass "percmd" here so they only ever limit repeats of themselves, never
# get blocked by (or block) the unrelated !bhelp/other-category cooldown.
proc masterhelp::channel_allowed {chan} {
    variable channel

    # Public bind callbacks normally provide a channel. Be explicit here so
    # a malformed/empty callback cannot accidentally pass an allow-list.
    if {$chan eq ""} { return 0 }

    set cfg [string trim $channel]
    if {$cfg eq ""} { return 0 }

    # "*" (or "all") means every channel. Keep this deliberately exact;
    # partial matches such as "#foo*" are not treated as wildcards.
    if {$cfg eq "*" || [string tolower $cfg] eq "all"} { return 1 }

    set wanted [string tolower $chan]
    foreach allowed [regexp -all -inline {\S+} $cfg] {
        if {[string tolower $allowed] eq $wanted} {
            return 1
        }
    }
    return 0
}

proc masterhelp::ratelimited {nick host trig {scope_override ""}} {
    variable ratelimit_secs
    variable ratelimit_scope
    variable ratelimit_maxentries
    variable last_global
    variable last_percmd

    set scope $ratelimit_scope
    if {$scope_override ne ""} { set scope $scope_override }

    set now [clock seconds]
    set id  [masterhelp::id $nick $host]
    set key "$id,$trig"
    set blocked 0

    set use_global [expr {$scope eq "global" || $scope eq "both"}]
    set use_percmd [expr {$scope eq "percmd" || $scope eq "both"}]

    if {$use_global} {
        if {[info exists last_global($id)] && ($now - $last_global($id)) < $ratelimit_secs} {
            set blocked 1
        }
    }
    if {!$blocked && $use_percmd} {
        if {[info exists last_percmd($key)] && ($now - $last_percmd($key)) < $ratelimit_secs} {
            set blocked 1
        }
    }

    variable burst_max
    variable last_burst
    if {!$blocked} {
        set recent {}
        if {[info exists last_burst($id)]} {
            foreach t $last_burst($id) {
                if {$now - $t < $ratelimit_secs} { lappend recent $t }
            }
        }
        if {[llength $recent] >= $burst_max} { set blocked 1 }
    }

    if {!$blocked} {
        if {![info exists last_burst($id)] && [array size last_burst] >= $ratelimit_maxentries} {
            array unset last_burst
        }
        lappend recent $now
        set last_burst($id) $recent
        # Evict the single stalest entry first whenever we're already at
        # the cap, so a fast burst of distinct callers can inflate either
        # table no further than ratelimit_maxentries no matter how quickly
        # it arrives -- see the comment on ratelimit_maxentries above.
        # Only the table(s) the active scope reads are written at all.
        if {$use_global} {
            if {[array size last_global] >= $ratelimit_maxentries} {
                masterhelp::evict_oldest last_global
            }
            set last_global($id) $now
        }
        if {$use_percmd} {
            if {[array size last_percmd] >= $ratelimit_maxentries} {
                masterhelp::evict_oldest last_percmd
            }
            set last_percmd($key) $now
        }
    }
    return $blocked
}

# Removes the single oldest (smallest-timestamp) entry from the named
# cooldown array. Callers pass the array's bare name ("last_global" or
# "last_percmd"); arrname is only ever set internally by ratelimited()
# above, never from user input. Used solely as the hard-cap eviction
# there -- the normal age-based sweep is masterhelp::cleanup.
proc masterhelp::evict_oldest {arrname} {
    upvar #0 ::masterhelp::$arrname arr
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

proc masterhelp::safe {s} {
    regsub -all {[\r\n\001]} $s "" s
    return [string range $s 0 400]
}

proc masterhelp::send {nick chan text} {
    variable output
    set text [masterhelp::safe $text]

    # One switch, not two -- previously target and the PRIVMSG/NOTICE verb
    # were picked by separate switches over the same cases, which could
    # silently drift apart if only one was ever edited. $output is
    # validated at load time to be one of these three; default is kept
    # only as a defensive fallback.
    switch -- $output {
        channel { set target $chan; set verb PRIVMSG }
        msg     { set target $nick; set verb PRIVMSG }
        notice  { set target $nick; set verb NOTICE  }
        default { set target $nick; set verb NOTICE  }
    }

    # Fall back to the caller rather than dropping the line silently when
    # output is "channel" but the bind fired without a channel.
    if {$target eq ""} {
        set target [masterhelp::safe $nick]
        set verb   NOTICE
    }
    if {$target eq "" || $text eq ""} { return }

    # puthelp: a menu is up to 9 lines, which shouldn't hold up the bot's
    # main send queue.
    puthelp "$verb $target :$text"
}


# Arm the recurring stale-entry sweep.
#
# TWO bugs fixed here:
#
#  1. UNIT. This used `timer`, whose argument is MINUTES, not seconds --
#     `utimer` is the seconds variant. Passing ratelimit_cleanup_secs
#     (3600) to `timer` scheduled the sweep 3600 minutes out: 60 hours, or
#     two and a half days, rather than the intended hour. The variable name
#     said seconds and the API wanted minutes, so nothing looked wrong.
#
#  2. REHASH LEAK. Arming was unconditional, and .rehash re-sources this
#     file while any previously-scheduled timer is still pending. Every
#     rehash therefore left the old timer running AND added another, so a
#     bot rehashed N times ran the sweep N+1 times per interval, forever.
#     Kill any pending masterhelp::cleanup before arming a fresh one.
proc masterhelp::schedule_cleanup {} {
    variable ratelimit_cleanup_secs
    catch {
        foreach t [utimers] {
            if {[lindex $t 1] eq "masterhelp::cleanup"} { killutimer [lindex $t 2] }
        }
    }
    catch { utimer $ratelimit_cleanup_secs masterhelp::cleanup }
}

proc masterhelp::cleanup {} {
    variable last_global
    variable last_percmd
    variable ratelimit_secs

    # Keep entries for well beyond any cooldown they could still affect.
    # Derived rather than hardcoded at 7200 so raising ratelimit_secs past
    # two hours can't start discarding live cooldowns.
    set keep 7200
    if {($ratelimit_secs * 2) > $keep} { set keep [expr {$ratelimit_secs * 2}] }
    set cutoff [expr {[clock seconds] - $keep}]

    foreach key [array names last_global] {
        if {$last_global($key) < $cutoff} {
            unset last_global($key)
        }
    }

    foreach key [array names last_percmd] {
        if {$last_percmd($key) < $cutoff} {
            unset last_percmd($key)
        }
    }

    variable last_burst
    foreach key [array names last_burst] {
        if {[lindex $last_burst($key) end] < $cutoff} { unset last_burst($key) }
    }

    masterhelp::schedule_cleanup
}

;# Maps the word after "!bhelp set" to the $output value it selects.
;# Kept as its own lookup (rather than inline in cmd) so the accepted
;# aliases (pm/dm/privmsg/private, all meaning "msg") live in one place.
proc masterhelp::parse_mode_arg {arg} {
    switch -- [string tolower [string trim $arg]] {
        channel                            { return channel }
        msg - pm - dm - privmsg - private  { return msg }
        notice                             { return notice }
        default                            { return "" }
    }
}

;# Prints the sub-list for one category (e.g. "!oshelp") -- the sub-list
;# itself, not the top-level $menu. Shared by all four category triggers
;# below rather than one proc per category, so their output format can't
;# drift apart the way the old per-entry duplication did (see header).
proc masterhelp::cmd_category {cattrig nick host hand chan} {
    variable categories
    variable footer
    if {![masterhelp::channel_allowed $chan]} { return }
    if {[masterhelp::ratelimited $nick $host $cattrig percmd]} { return }
    set items ""
    foreach entry $categories {
        lassign $entry trig sublist
        if {$trig eq $cattrig} { set items $sublist; break }
    }
    if {$items eq ""} {
        ;# Should never happen -- every bound category trigger has a
        ;# matching entry in $categories. Fail quietly rather than with a
        ;# confusing empty-looking reply if that ever drifts out of sync.
        putlog "masterhelp.tcl: cmd_category called for unknown \"$cattrig\""
        return
    }
    masterhelp::send $nick $chan "$cattrig topics -- use any of these for details:"
    foreach entry $items {
        lassign $entry trig desc
        masterhelp::send $nick $chan "Type \x02$trig\x02 -- $desc"
    }
    masterhelp::send $nick $chan $footer
}

proc masterhelp::oshelp_cmd        {nick host hand chan arg} { masterhelp::cmd_category "!oshelp"        $nick $host $hand $chan }
proc masterhelp::gamehelp_cmd      {nick host hand chan arg} { masterhelp::cmd_category "!gamehelp"      $nick $host $hand $chan }
proc masterhelp::irchelp_cmd       {nick host hand chan arg} { masterhelp::cmd_category "!irchelp"       $nick $host $hand $chan }
proc masterhelp::otherhelp_cmd     {nick host hand chan arg} { masterhelp::cmd_category "!otherhelp"     $nick $host $hand $chan }
proc masterhelp::sportgamehelp_cmd {nick host hand chan arg} { masterhelp::cmd_category "!sportgamehelp" $nick $host $hand $chan }
proc masterhelp::fightgamehelp_cmd {nick host hand chan arg} { masterhelp::cmd_category "!fightgamehelp" $nick $host $hand $chan }
proc masterhelp::cardgamehelp_cmd  {nick host hand chan arg} { masterhelp::cmd_category "!cardgamehelp"  $nick $host $hand $chan }
proc masterhelp::othergamehelp_cmd {nick host hand chan arg} { masterhelp::cmd_category "!othergamehelp" $nick $host $hand $chan }

proc masterhelp::cmd {nick host hand chan arg} {
    ;# arg is normally unused -- bare "!bhelp" always prints the full menu
    ;# to whatever $output is currently configured, same as before. The
    ;# one exception is "!bhelp set <mode>": that changes $output itself,
    ;# for every future !bhelp call from every nick, not just this reply.
    ;# It's restricted to the bot owner (flag n) since it's a standing
    ;# config change, not a per-message option.
    variable menu
    variable footer
    variable trigger
    variable output
    if {![masterhelp::channel_allowed $chan]} { return }
    if {[masterhelp::ratelimited $nick $host $trigger]} { return }
    # \S+ tokenizing (not [split [string trim $arg]]): split's default
    # delimiter set is applied per-CHARACTER, so a run of more than one
    # space/tab (e.g. "set  channel") produces empty-string elements in
    # the middle of the list, silently breaking [lindex $args 1]. This was
    # already fixed in bsdhelp.tcl/debhelp.tcl/winhelp.tcl but never
    # backported here.
    set args [regexp -all -inline {\S+} $arg]
    if {[string tolower [lindex $args 0]] eq "set"} {
        set mode [masterhelp::parse_mode_arg [lindex $args 1]]
        if {$mode eq ""} {
            masterhelp::send $nick $chan "Usage: $trigger set <channel|msg|notice> -- channel = reply in the channel, notice = NOTICE to your nickname (private), msg = PRIVMSG to your nickname (private; aliases pm/dm/privmsg/private also mean msg) -- changes where !bhelp answers go, for everyone, until changed again."
            return
        }
        if {![matchattr $hand n]} {
            masterhelp::send $nick $chan "$nick: only the bot owner can change !bhelp's output mode."
            return
        }
        set output $mode
        putlog "masterhelp.tcl: output mode changed to \"$mode\" by [masterhelp::safe $nick]![masterhelp::safe $host]"
        masterhelp::send $nick $chan "!bhelp output mode set to \"$mode\" for everyone."
        return
    }
    # Read-only mode query, same as bsdhelp.tcl/debhelp.tcl/winhelp.tcl --
    # ported here for parity; masterhelp.tcl predates that convention.
    if {[string tolower [lindex $args 0]] eq "mode"} {
        masterhelp::send $nick $chan "$nick: $trigger output mode is currently: $output (channel = reply in the channel, notice = NOTICE to your nickname, msg = PRIVMSG to your nickname). Channel scope: $channel"
        return
    }
    masterhelp::send $nick $chan "Help topics -- use any of these for details:"
    foreach entry $menu {
        lassign $entry trig desc
        masterhelp::send $nick $chan "Type \x02$trig\x02 -- $desc"
    }
    masterhelp::send $nick $chan $footer
}

# Unbind whatever was actually bound last time (bound_trigger/bound_flags,
# preserved across rehash -- see the guard near the top of the namespace
# eval block), NOT the current $trigger/$flags. Unbinding by the current
# config is a guaranteed no-op the moment an admin edits $trigger or
# $flags and rehashes -- the old bind was registered under the old
# values, never the new ones -- which would leave it permanently active
# alongside the new bind instead of being replaced by it.
if {$masterhelp::bound_trigger ne ""} {
    catch { unbind pub $masterhelp::bound_flags $masterhelp::bound_trigger masterhelp::cmd }
    set masterhelp::bound_trigger ""
    set masterhelp::bound_flags   ""
}

# The bind itself is wrapped in catch too: a malformed $flags string would
# otherwise raise an uncaught error here and abort the rest of this file
# mid-source, silently skipping the putlog line below and -- more
# importantly -- skipping masterhelp::schedule_cleanup, leaving no cleanup
# timer armed until the next successful rehash.
if {[catch {bind pub $masterhelp::flags $masterhelp::trigger masterhelp::cmd} err]} {
    putlog "masterhelp.tcl: failed to bind $masterhelp::trigger (flags \"$masterhelp::flags\"): $err"
} else {
    set masterhelp::bound_trigger $masterhelp::trigger
    set masterhelp::bound_flags   $masterhelp::flags
}

;# Unbind whatever category triggers were actually bound last time (by
;# their OLD trigger/flags, preserved in bound_subtriggers across rehash),
;# same reasoning as the !bhelp unbind above.
foreach pair $masterhelp::bound_subtriggers {
    lassign $pair otrig oflags oproc
    catch { unbind pub $oflags $otrig $oproc }
}
set masterhelp::bound_subtriggers {}

foreach pair {
    {!oshelp        masterhelp::oshelp_cmd}
    {!gamehelp      masterhelp::gamehelp_cmd}
    {!irchelp       masterhelp::irchelp_cmd}
    {!otherhelp     masterhelp::otherhelp_cmd}
    {!sportgamehelp masterhelp::sportgamehelp_cmd}
    {!fightgamehelp masterhelp::fightgamehelp_cmd}
    {!cardgamehelp  masterhelp::cardgamehelp_cmd}
    {!othergamehelp masterhelp::othergamehelp_cmd}
} {
    lassign $pair ctrig cproc
    if {[catch {bind pub $masterhelp::flags $ctrig $cproc} err]} {
        putlog "masterhelp.tcl: failed to bind $ctrig (flags \"$masterhelp::flags\"): $err"
    } else {
        lappend masterhelp::bound_subtriggers [list $ctrig $masterhelp::flags $cproc]
    }
}

putlog "masterhelp.tcl loaded (trigger=$masterhelp::trigger, flags=$masterhelp::flags, output=$masterhelp::output): [llength $masterhelp::menu] categories, [llength $masterhelp::bound_subtriggers] category triggers bound"

masterhelp::schedule_cleanup
