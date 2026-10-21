########################################################################
# mafia.tcl - Mafia-style crime/RPG game for Eggdrop
#
# Become the Don. Do crimes, deal drugs, buy guns, shoot/knife rivals,
# dodge the cops, hide, heal, rob, and climb the ranks.
#
# Install:
#   1. Drop this file AND Mafia.cfg into your eggdrop scripts/ dir (same
#      directory, both files).
#   2. Add:  source scripts/mafia.tcl
#   3. .rehash or restart the bot.
#
# Data is stored in a SQLite database (mafia.sqlite3) next to the bot,
# autosaved every few minutes. All tunable settings live in Mafia.cfg --
# edit that file and .rehash to change them; you should rarely need to
# touch this file at all. This mirrors the Duck Hunt script's layout:
# one main .tcl (engine + content) and one .cfg (settings) sourced from
# inside the namespace.
########################################################################

# Reload hygiene: Eggdrop's .rehash sources this file into the same Tcl
# interpreter.  Clean up the previous instance before recreating the namespace,
# otherwise self-rescheduling utimers, binds, SQLite commands, and stale arrays
# can survive and accumulate across rehashes.
if {[namespace exists ::mafia]} {
    if {[llength [info commands ::mafia::rehash_cleanup]]} {
        if {[catch {::mafia::rehash_cleanup} __mafia_cleanup_err]} {
            catch {putlog "mafia.tcl: previous-instance cleanup warning: $__mafia_cleanup_err"}
        }
    } else {
        # Upgrade fallback for versions that predate rehash_cleanup.
        foreach __v {autosave_timer_id drug_market_timer_id pimp_market_timer_id blackmarket_timer_id jail_timer_id hospital_timer_id} {
            if {[info exists ::mafia::$__v]} {
                set __tid [set ::mafia::$__v]
                if {$__tid ne "" && [llength [info commands killutimer]]} {
                    catch {killutimer $__tid}
                }
            }
        }
        if {[llength [info commands ::mafia::mafia_db]]} {
            catch {::mafia::mafia_db close}
        }
    }
    catch {namespace delete ::mafia}
    # -nocomplain, and one name per call: a single unset aborts on the FIRST
    # name that isn't set, so with a clean cleanup (no __mafia_cleanup_err)
    # the loop variables were never unset and leaked into the global scope on
    # every rehash.
    foreach __leftover {__mafia_cleanup_err __v __tid} {
        unset -nocomplain $__leftover
    }
    unset -nocomplain __leftover
}

# Resolve Mafia.cfg next to this file, so the install step stays "drop the
# files in scripts/ and source mafia.tcl" no matter the bot's working
# directory.
#
# The existence check belongs HERE, at file scope, not inside the namespace
# eval below. `return` inside a namespace eval only ends that one block: the
# eleven blocks after it -- including the init bootstrap at the bottom of the
# file -- would still be evaluated with not one setting defined, so instead of
# the single clean message below the operator got a cascade of "no such
# variable" errors and a half-loaded script. At file scope `return` aborts the
# whole source, which is what this message has always claimed to do.
set ::mafia_config_file [file join [file dirname [file normalize [info script]]] Mafia.cfg]
if {![file exists $::mafia_config_file]} {
    putlog "mafia.tcl: FATAL: configuration file not found at $::mafia_config_file -- loading aborted. Re-download Mafia.cfg alongside mafia.tcl."
    return
}

# mafia_core.tcl - namespace setup + all static config/data tables
# (config vars, ranks, levels, crimes, shop items, resale, bling, fence/
#  black market data, jobs data, drugs data, pimp market data, player
#  state array). Sourced FIRST -- every other module depends on this.
namespace eval mafia {
    catch {package require sqlite3}

    ##### ---------------- CONFIG ---------------- #####
    # Every tunable setting below (chan through pimp_collect_cooldown, plus
    # the account-cleanup and max_health/max_level knobs further down) lives
    # in Mafia.cfg, not here -- same split as Duck Hunt's Duck_Hunt.tcl /
    # Duck_Hunt.cfg: this file is the game engine and content, the .cfg is
    # the one place an operator edits settings, and a .rehash picks up cfg
    # edits without touching this file. See config_file below for the path.
    variable config_file    ""          ;# resolved at source-time, see the bottom of this CONFIG block
    variable db_file        ""          ;# resolved full path, set by init_db
    variable db                         ;# sqlite3 command handle, set by init_db
    variable db_ready       0
    variable db_in_txn      0
    variable bound_prefix   ""          ;# actual prefix currently registered with Eggdrop binds
    variable jail_timer_id
    variable hospital_timer_id
    variable cleanup_timer_id
    if {![info exists cleanup_timer_id]} { set cleanup_timer_id "" }
    # Generation tokens that invalidate callbacks surviving killutimer/rehash
    # races.
    #
    # Seeded from the clock, not from a constant. The namespace is deleted and
    # re-created on every rehash, so a fixed starting value would reset to the
    # same number on every load. A stale callback from the previous instance
    # that outlived killutimer would then carry a token matching the new one,
    # pass the guard, and reschedule itself: a duplicate timer chain, which is
    # the precise failure these tokens exist to prevent. A clock seed cannot
    # collide across reloads.
    #
    # One token PER timer chain, not one shared counter. A single shared
    # timer_epoch used to be bumped by every start_*_timer call -- so calling
    # start_drug_market_timer (say) also invalidated the already-scheduled
    # autosave/hospital/jail/etc callbacks, since they carried an older token
    # than the now-current shared value. Each start_*_timer call during init
    # was silently killing every timer chain started before it; only the very
    # last one started (auto_cleanup) ever kept rescheduling itself. That is
    # why hospital/jail release notifications never posted: hospital_expiry_timer
    # fired once, saw its token no longer matched, and quietly stopped
    # rescheduling. Separate tokens mean starting/restarting one chain can
    # never invalidate another.
    foreach __epoch_var {autosave_epoch drug_market_epoch pimp_market_epoch
                         blackmarket_epoch jail_epoch hospital_epoch cleanup_epoch} {
        variable $__epoch_var
        if {![info exists $__epoch_var]} {
            if {[catch {set $__epoch_var [clock microseconds]}]} {
                set $__epoch_var [clock seconds]
            }
        }
    }
    catch {unset __epoch_var}

    # admin_flags (the Eggdrop flags allowed to use !mafiaadmin) is set in
    # Mafia.cfg along with every other operator setting -- see the note on
    # casino_collect_cooldown below.

    # Settings the !mafiaadmin config command is allowed to view/change.
    # Every name here MUST be a real ::mafia:: variable: cmd_admin_config
    # reads each one with [set ::mafia::$key] when listing, so a key with no
    # variable behind it makes bare "!mafiaadmin config" die partway through
    # the listing with an uncaught Tcl error. "jail_bribe_cash" was exactly
    # that -- it never existed (the real knobs are jail_bribe_min/max, both
    # already listed below).
    variable admin_config_keys {
        chan cmd_prefix output_mode admin_flags save_interval
        start_cash jail_time hospital_time hide_time
        crime_cooldown attack_cooldown rob_cooldown deal_cooldown streetfight_cooldown
        npcfight_cooldown hitfight_cooldown stealthfight_cooldown wiretap_cooldown
        gamble_cooldown job_cooldown boss_cooldown pimp_collect_cooldown
        casino_collect_cooldown dealer_collect_cooldown
        inactive_days cleanup_warn_days auto_cleanup_interval_days
        dealer_refund_pct
        encounter_min_gap encounter_max_gap encounter_response_time encounter_daily_limit jail_bribe_min jail_bribe_max jail_risk_multiplier
        legend_drop_pct legend_roll_cooldown
    }

    ##### ---------------- LOAD CONFIGURATION FROM Mafia.cfg ---------------- #####
    # The path was resolved and its existence verified at file scope above
    # (see the comment there for why the check cannot live in here). Every
    # "variable NAME value" line in Mafia.cfg lands as ::mafia::NAME because
    # source runs in this namespace's context, exactly like Duck_Hunt.cfg
    # does inside ::DuckHunt.
    set config_file $::mafia_config_file
    uplevel #0 [list namespace eval ::mafia [list source $config_file]]

    ##### ---------------- ACCOUNT CLEANUP ---------------- #####
    # A player is "inactive" once last_seen is this many days old. Mirrors
    # the manual !mafiaadmin prune broom: prune defaults to this value when
    # no <days> is given, !mafiaadmin nearing uses cleanup_warn_days to flag
    # accounts approaching (but not yet past) the cutoff, and the recurring
    # timer below sweeps automatically on the same threshold.
    # (inactive_days, cleanup_warn_days, auto_cleanup_interval_days,
    # auto_cleanup_poll_secs, max_health and max_level are all set in
    # Mafia.cfg, sourced above.)
    # Reserved pseudo-player key for small bits of bot-wide state (currently
    # just the last-auto-cleanup timestamp) that need to survive restarts but
    # aren't tied to any real player. Piggybacks on the existing generic
    # players-array persistence instead of a new DB table. Not a legal IRC
    # nick (double-underscore-wrapped, and cmd_register refuses it), so it
    # can never collide with a real player row.
    variable meta_key "__mafia_meta__"

    # One boss per tier (20 tiers, levels 1-1000 in blocks of 50). Beating
    # the boss of your current tier is what opens the level cap into the
    # next tier -- xp keeps accruing normally, but your effective level
    # (and the stat/gear scaling tied to it) won't climb past the tier
    # ceiling until the boss standing in the doorway goes down.
    # Boss every 50 levels. Don is the player title from Lv.500-999;
    # defeating Tier 20 at Lv.1000+ promotes the player to Master Don.
    variable boss_names {
        "Street Boss" "Executive" "Syndicate Captain" "Kingpin" "Crime Lord"
        "Executive Chief" "Mogul" "Tycoon" "Supreme Chief" "Godfather"
        "Syndicate Baron" "Empire Chief" "Crime Baron" "Titan" "Grand Boss"
        "Supreme Boss" "Shadow Don" "Immortal Don" "Ice Factory Boss" "Master Don"
    }

    ##### ---------------- RANKS ---------------- #####
    # Level milestones -> rank title.  Titles are intentionally spread out
    # across levels 1-500; Don is reached at level 500 (the highest rank
    # title -- separate from the Master Don boss-tier title at Lv.1000+).
    # These values are the XP thresholds for the corresponding levels.
    # Level 1   = 0 XP
    # Level 50  = 21,315 XP
    # Level 100 = 80,190 XP
    # Level 150 = 176,565 XP
    # Level 200 = 310,440 XP
    # Level 250 = 481,815 XP
    # Level 300 = 690,690 XP
    # Level 350 = 937,065 XP
    # Level 400 = 1,220,940 XP
    # Level 450 = 1,542,315 XP
    # Level 500 = 1,901,190 XP (DON)
    variable ranks {
        0        "Street Punk"
        21315    "Associate"
        80190    "Soldier"
        176565   "Made Man"
        310440   "Enforcer"
        481815   "Capo"
        690690   "Underboss"
        937065   "Consigliere"
        1220940  "Boss"
        1542315  "Executive"
        1901190  "Don"
    }

    ##### ---------------- LEVELS (1000, unlimited past that) ---------------- #####
    # ranks stop at Don (Lv500); levels continue to max_level=1000 and beyond
    # (Lv1000+ is reachable only after beating Master Don).
    variable level_thresholds {}   ;# built at load by build_level_thresholds -- max_level comes from Mafia.cfg

    ##### ---------------- CRIMES ---------------- #####
    # name -> {min_xp cash_min cash_max xp_min xp_max fail_chance jail_risk flavor_success flavor_fail}
    variable crimes
    array set crimes {
        pickpocket {0    20  100   1  3  10 5  "You lift a fat wallet off a tourist."          "Your mark feels your hand and yells for the cops."}
        shoplift   {0    30  140   1  4  15 8  "You walk out with a bag full of merchandise."   "A rent-a-cop tackles you at the door."}
        carjack    {50   150 450  3  8  25 15 "You hotwire a nice ride and vanish into traffic." "The alarm blares and a cop was two blocks away."}
        burglary   {150  300 800  5  12 30 18 "You crack the safe and clean the place out."    "The homeowner comes home early and calls it in."}
        armored_truck {400 900 2200 10 20 40 25 "You crack the armored truck wide open."       "The guards open fire and the cops box you in."}
        bank_heist {900  2500 6000 20 40 50 35 "You blow the vault and walk away rich."         "Silent alarm. SWAT was waiting outside."}
        extortion  {200  250 700  6  14 25 15 "The shop owner pays up rather than see his windows broken." "He calls the cops the second you leave."}
        drive_by   {600  700 1600 12 22 35 30 "You spray the rival corner and peel out clean."  "You miss your window and a witness gets your plate."}
        poison     {800  600 1400 14 24 30 28 "The mark's drink never had a chance -- clean and quiet." "The mark tastes it and spits it out, screaming for help."}
        contract_hit {1500 2000 5000 25 45 45 40 "One shot, one confirmed kill. The family is pleased." "Your target survives and now everyone knows your face."}
        gang_war   {2000 1800 4500 30 50 55 30 "Your crew routs the rival gang off the block for good." "The rival crew was ready and your crew takes the losses."}
        murder     {3000 3000 7000 35 60 50 45 "The Don's rival is found in the river. No loose ends."  "It goes loud. Sirens everywhere before you're two blocks out."}
    }

    ##### ---------------- SHOP ITEMS ---------------- #####
    # type: weapon/armor/tool. Armor shop key -> {display price damage_reduction evasion_pct}
    variable shop_weapons
    array set shop_weapons {
        fists           {"Bare Fists"          0     7}
        magnum          {"Magnum Revolver"     1300  53}
        gold_smg        {"Gold-Plated SMG"     5500  105}
        rifle           {"Assault Rifle"       8000  126}
        sniper          {"Sniper Rifle"        15000 182}
        minigun         {"Minigun"             22000 210}
        mini_cannon     {"Mini Cannon"         750000 280}
        siege_cannon    {"Siege Cannon"        1500000 335}
        titan_cannon    {"Titan Cannon"        3000000 375}
        apocalypse_cannon {"Apocalypse Cannon"   5000000 475}
        singularity_cannon {"Singularity Cannon" 8000000 575}
        voidbreaker     {"Voidbreaker"         10000000 620}
        eclipse_railgun {"Eclipse Railgun"     15000000 680}
        oblivion_cannon {"Oblivion Cannon"       20000000 1200}
        reckoning_railgun {"Reckoning Railgun"    30000000 1650}
        apex_annihilator {"Apex Annihilator"      45000000 2150}
        celestial_destroyer {"Celestial Destroyer" 175000000 2750}
        finality_cannon {"Finality Cannon"       350000000 3400}
    }
    # Every firearm in shop_weapons must be listed here: cmd_attack (shoot) and
    # cmd_headshot both gate on membership, so a firearm missing from this list
    # can be bought and equipped but can never shoot anyone. The five late-game
    # rungs (oblivion_cannon .. finality_cannon) were added to shop_weapons and
    # weapon_order without being added here, which meant buying the best weapon
    # in the game -- up to $350,000,000 -- silently disabled shoot and headshot
    # for that player until they re-equipped something cheaper. Keep this list
    # in sync with shop_weapons. (Melee/knife has no such list: it works with
    # whatever is equipped -- see cmd_attack. The former melee_weapons list held
    # only "fists", which made knife unreachable for any armed player, so it is
    # gone rather than left as a second table to keep in sync.)
    variable gun_weapons  {magnum gold_smg rifle sniper minigun mini_cannon siege_cannon titan_cannon apocalypse_cannon singularity_cannon voidbreaker eclipse_railgun oblivion_cannon reckoning_railgun apex_annihilator celestial_destroyer finality_cannon}
    # Weakest-to-strongest ordering used to hand NPCs and bosses a realistic
    # loadout for their level, instead of an abstract damage number.
    variable weapon_order {fists magnum gold_smg rifle sniper minigun mini_cannon siege_cannon titan_cannon apocalypse_cannon singularity_cannon voidbreaker eclipse_railgun oblivion_cannon reckoning_railgun apex_annihilator celestial_destroyer finality_cannon}
    variable armor_order  {none vest riot titanium battle_suit aegis_battle imperial_power fortress_plate singularity_aegis void_shroud phantom_shell oblivion_plate reckoning_aegis apex_bastion celestial_aegis finality_bastion}
    variable shop_armor
    array set shop_armor {
        none        {"No Armor"            0     0 0}
        vest        {"Kevlar Vest"         500   21 5}
        riot        {"Riot Gear"           5000  77 7}
        titanium    {"Titanium Plate Armor" 28000 140 10}
        battle_suit {"Battle Suit"           800000 161 12}
        aegis_battle {"Aegis Battle Armor"  1800000 185 15}
        imperial_power {"Imperial Power Armor" 3000000 205 17}
        fortress_plate {"Fortress Plate Armor" 5000000 260 20}
        singularity_aegis {"Singularity Aegis" 8000000 325 22}
        void_shroud     {"Void Shroud"      10000000 350 25}
        phantom_shell   {"Phantom Shell"    15000000 380 27}
        oblivion_plate {"Oblivion Plate"       18000000 820 30}
        reckoning_aegis {"Reckoning Aegis"      30000000 1150 32}
        apex_bastion {"Apex Bastion"            45000000 1500 35}
        celestial_aegis {"Celestial Aegis"      175000000 1950 38}
        finality_bastion {"Finality Bastion"     350000000 2450 40}
    }
    # Five late-game shop rungs. There are NO level requirements on these
    # shop items: the only purchase gate is having enough money. Boss gear
    # remains per-tier (1-20) and is always stronger than the shop gear.

    # Late shop armor
    # (see the cloak switch in pvp_reaction, mafia_commands_combat.tcl) on
    # top of their flat armor_reduce value above -- the two top armor tiers
    # in the shop, priced and gated accordingly.
    variable shop_tools
    array set shop_tools {
        lockpick     {"Lockpick Set"          200   "crime"}
        medkit       {"Medkit"                250   "heal"}
        wiretap      {"Wiretap Kit"           2500  "surveillance"}
        heat_detector {"Heat Detector"        3200  "jail"}
        spy_watch    {"Spy Watch Camera"      2800  "surveillance"}
        armored_car  {"Armored Car"           6500  "crime"}
        drone_cam    {"Recon Drone"           4200  "surveillance"}
        threat_scanner {"Threat Scanner"         5000  "counter"}
        tactical_shield {"Tactical Shield"       7500  "block"}
        smoke_screen {"Smoke Screen"             6500  "dodge"}
        escape_rig   {"Escape Rig"             900000 "dodge"}
        riot_visor      {"Riot Visor"          9500    "surveillance"}
        ghost_cloak     {"Ghost Cloak"         1200000 "dodge"}
        biometric_ledger {"Biometric Ledger"   12000   "crime"}
    }

    ##### ---------------- RESALE (mafia sell) ---------------- #####
    # % of the original shop price a player gets back when selling gear
    # (weapons/armor/tools/bling) back to the shop. Per-kind overrides let
    # e.g. bling hold its value differently than tools; anything not listed
    # in shop_resale_pct_by_kind falls back to shop_resale_pct.
    variable shop_resale_pct 40
    variable shop_resale_pct_by_kind
    array set shop_resale_pct_by_kind {
        weapon 40
        armor  40
        tool   50
        bling  60
    }
    # Experienced players negotiate better resale deals: +1% resale for
    # every 10 levels, capped at +30% (hit at Lv.300). A Lv.1 player still
    # gets the base rate above; a maxed-out Don gets noticeably more cash
    # for the exact same trade-in.
    variable shop_resale_level_bonus_per10 1
    variable shop_resale_level_bonus_cap   30

    # Looks up {price kind} for an item key across all four shop tables.
    # Returns {-1 ""} if the item isn't sold anywhere.
    proc shop_item_lookup {item} {
        variable shop_weapons
        variable shop_armor
        variable shop_tools
        variable shop_bling
        variable boss_weapons
        variable boss_armor
        variable boss_bling
        variable boss_tools
        if {[info exists shop_weapons($item)]} { return [list [lindex $shop_weapons($item) 1] weapon] }
        if {[info exists shop_armor($item)]}   { return [list [lindex $shop_armor($item) 1] armor] }
        if {[info exists shop_tools($item)]}   { return [list [lindex $shop_tools($item) 1] tool] }
        if {[info exists shop_bling($item)]}   { return [list [lindex $shop_bling($item) 1] bling] }
        if {[info exists boss_weapons($item)]} {
            set s [lindex $boss_weapons($item) 1]
            return [list [expr {max(1000,int($s*$s*4))}] weapon]
        }
        if {[info exists boss_armor($item)]} {
            set s [lindex $boss_armor($item) 1]
            return [list [expr {max(1000,int($s*$s*3))}] armor]
        }
        if {[info exists boss_bling($item)]} {
            # Master Ice Factory (Tier 20, the last-tier bling) is pinned to
            # a flat 50,000,000 rather than falling out of the s*s*700
            # curve -- that curve gave it a value (~2.1M) far below even
            # the top SHOP-purchasable bling (Ice Gold, 75,000,000), which
            # didn't fit it being the single best piece of bling in the
            # game. Every other boss bling tier keeps the original formula.
            if {$item eq "master_ice_factory"} { return [list 50000000 bling] }
            set s [lindex $boss_bling($item) 1]
            return [list [expr {max(1000,int($s*$s*700))}] bling]
        }
        if {[info exists boss_tools($item)]} {
            return [list 10000 tool]
        }
        return [list -1 ""]
    }

    # Resale % bonus from player level, on top of the flat per-kind rate.
    proc resale_level_bonus_pct {nick} {
        variable shop_resale_level_bonus_per10
        variable shop_resale_level_bonus_cap
        if {$nick eq ""} { return 0 }
        set lvl [player_level $nick]
        set bonus [expr {int($lvl/10)*$shop_resale_level_bonus_per10}]
        if {$bonus > $shop_resale_level_bonus_cap} { set bonus $shop_resale_level_bonus_cap }
        return $bonus
    }

    proc gear_upgrade_ok {nick item kind {slot ""}} {
        variable players
        set k [string tolower $nick]
        switch -- $kind {
            weapon { return [expr {[weapon_dmg $item $nick] > [weapon_dmg $players($k,weapon) $nick]}] }
            armor  { return [expr {[armor_reduce $item $nick] > [armor_reduce $players($k,armor) $nick]}] }
            bling {
                set field [expr {$slot eq "" ? "bling" : $slot}]
                set cur [getf $nick $field "none"]
                set newscore [expr {[bling_bonus_pct $item $nick]*100.0 + [bling_econ_pct $item $nick]}]
                set oldscore [expr {[bling_bonus_pct $cur $nick]*100.0 + [bling_econ_pct $cur $nick]}]
                return [expr {$newscore > $oldscore}]
            }
            default { return 1 }
        }
    }

    # True if $item is a boss drop (weapon/armor/bling) rather than an
    # ordinary shop purchase. Boss gear can be re-looted indefinitely: sell
    # it, it's no longer "owned", the next boss win re-drops it. Ordinary
    # shop gear has no such farm loop, so only boss gear needs throttling.
    proc is_boss_gear_item {item} {
        variable boss_weapons
        variable boss_armor
        variable boss_bling
        return [expr {[info exists boss_weapons($item)] || [info exists boss_armor($item)] || [info exists boss_bling($item)]}]
    }

    # Cash you get back for selling one unit of $item. Pass $nick to fold
    # in that player's level-based resale bonus; omit it (or pass "") for
    # the flat base rate.
    #
    # Boss gear (weapon/armor/bling) is drop-once-per-item: once sold, the
    # item becomes "not owned" again and the next boss win simply re-drops
    # it, turning the boss into a repeatable cash faucet with no additional
    # risk or effort beyond the fight itself. The first sale of a given
    # boss item pays full resale (that's the genuine reward for the win);
    # every sale after that for the same nick+item is throttled hard, so
    # Master Don and friends stay worth farming for their rare/first drops
    # without becoming a low-effort cash loop.
    variable boss_gear_resale_throttle_pct 15
    proc resale_value {item {nick ""}} {
        variable shop_resale_pct
        variable shop_resale_pct_by_kind
        variable boss_gear_resale_throttle_pct
        variable players
        lassign [shop_item_lookup $item] price kind
        if {$price < 0} { return 0 }
        set pct [expr {[info exists shop_resale_pct_by_kind($kind)] ? $shop_resale_pct_by_kind($kind) : $shop_resale_pct}]
        set pct [expr {$pct + [resale_level_bonus_pct $nick]}]
        if {$pct > 95} { set pct 95 }
        set val [expr {int($price*($pct/100.0))}]
        # Non-creating read: getf would seed boss_gear_resold_<item> into the
        # player array just for asking, which is how the junk rows cleaned up
        # in pass 7 got there in the first place.
        if {$nick ne "" && [is_boss_gear_item $item]} {
            set rk [string tolower $nick]
            if {[info exists players($rk,boss_gear_resold_$item)] &&
                $players($rk,boss_gear_resold_$item)} {
                set val [expr {int($val*($boss_gear_resale_throttle_pct/100.0))}]
            }
        }
        return $val
    }

    # Marks $item as having been sold once already by $nick, so any future
    # re-drop-and-resell of the same item is throttled by resale_value.
    proc mark_boss_gear_resold {nick item} {
        variable players
        if {![is_boss_gear_item $item]} { return }
        set k [string tolower $nick]
        set players($k,boss_gear_resold_$item) 1
    }

    # Short suffix for sell messages, e.g. " (level bonus: +12% resale)".
    # Empty string at Lv.1-9 where the bonus is 0, so low-level sales stay
    # unannotated.
    proc resale_bonus_note {nick} {
        set bonus [resale_level_bonus_pct $nick]
        if {$bonus <= 0} { return "" }
        return " (level bonus: +${bonus}% resale)"
    }

    ##### ---------------- ICE (BLING) ---------------- #####
    # A prestige gear slot, separate from weapon/armor. Each tier gives a
    # flat percentage bonus applied to all four core stats (pickpocket,
    # dexterity, accuracy, stealth). key -> {display price stat_bonus_pct}
    # Ice is the most valuable thing a player can wear: the bonus applies to
    # ALL FOUR core stats at once and carries a matching economy bonus
    # (cheaper drug/pimp buys, better drug/pimp sales), which compounds with
    # everything else. It is priced accordingly -- every tier is a serious
    # cash sink, and the ladder escalates roughly 3x a rung, so the top two
    # tiers are a genuine long-term goal rather than a casual purchase for
    # anyone running a mature pimp operation. Compare the gear ladder: the
    # best weapon and the best armor in the shop are 15,000,000 each, and
    # Ice Gold is worth several of either.
    # Boss gear remains the strongest equipment for its corresponding tier.
    # Late shop gear is deliberately slightly below the matching Tier 11-20
    # boss weapon/armor, preserving boss drops as the best gear in each tier.
    # blackice/icegold are the top two SHOP-purchasable bling tiers,
    # sitting above whiteice and below the boss-exclusive Ice Factory
    # (50%, Tier 19 drop) / Master Ice Factory (55%, Tier 20/Master Don
    # drop) tiers in boss_bling below -- shop progression tops out here,
    # boss progression carries it the rest of the way.
    variable shop_bling
    array set shop_bling {
        none     {"No Bling"          0         0.0}
        silver   {"Silver"            25000     2.5}
        gold     {"Gold"              120000    5.0}
        puregold {"Pure Gold"         400000    7.5}
        diamonds {"Diamond"           1200000   10.0}
        ice      {"Iced-Out"          3500000   12.5}
        whiteice {"White Ice"         9000000   16.0}
        blackice {"Black Ice"         35000000  35.0}
        icegold  {"Ice Gold"          75000000  40.0}
    }
    variable bling_tiers {none silver gold puregold diamonds ice whiteice blackice icegold}

    ##### ---------------- ICE SLOT ---------------- #####
    # A single jewelry slot (field: bling), drawing from the shop_bling +
    # boss_bling catalog. Kept as a one-element list (rather than a bare
    # variable) so the generic bling_slots loops elsewhere (stat/econ bonus
    # calculation, inventory display, sell) don't need special-casing.
    variable bling_slots        {bling}
    variable bling_slot_label
    array set bling_slot_label {
        bling   "Bling"
    }

    ##### ---------------- BOSS / BLACK MARKET GEAR ---------------- #####
    # Boss-exclusive loot. Deliberately kept in separate arrays from
    # shop_weapons/shop_armor (not merged in) so this gear:
    #   - never shows up in `mafia shop`
    #   - can't be bought with `mafia buy`
    #   - can be sold back after it is no longer equipped
    # The only way to acquire it is beating a boss. Format is {display stat}.
    # Boss gear is the best gear FOR ITS TIER, not an absolute ceiling
    # above every item in the game -- a player kitted out in top shop/
    # whiteice gear (280 dmg / 161 armor / 16.0% bling) will beat the
    # early tiers easily and consistently. The early tiers (roughly 1-4)
    # sit below that shop ceiling on purpose; from the middle tiers on,
    # boss gear pulls ahead and by Tier 10 it's clearly the best in the
    # game, rewarding the long climb. Boss gear is kept out of
    # weapon_order/armor_order, same as this table, so it never shows up
    # as regular NPC/hitman loadout -- only bosses drop it.
    variable boss_weapons
    array set boss_weapons {
        street_reaper       {"Street Reaper"             180}
        executive_magnum   {"Executive Magnum"           240}
        syndicate_rifle    {"Syndicate Rifle"            310}
        kingpin_smg        {"Kingpin Suppressor"         390}
        crime_lord_cannon  {"Crime Lord Cannon"           480}
        executive_rifle   {"Executive War Rifle"          580}
        mogul_carbine      {"Mogul Carbine"               690}
        tycoon_cannon      {"Tycoon Cannon"               820}
        supreme_railgun    {"Supreme Railgun"              960}
        godfather_cannon   {"Godfather Cannon"            1100}
        syndicate_hammer   {"Syndicate Hammer"            1300}
        empire_rifle       {"Empire Rifle"                1520}
        baron_cannon       {"Crime Baron Cannon"           1760}
        titan_railgun      {"Titan Railgun"               2020}
        grand_cannon       {"Grand Boss Cannon"            2300}
        supreme_cannon     {"Supreme Boss Cannon"          2600}
        shadow_reaper      {"Shadow Reaper"                2920}
        immortal_arsenal   {"Immortal Arsenal"             3260}
        ice_factory_weapon {"Ice Factory Weapon"            3620}
        masterdon_weapon   {"Master Don's Executioner"     4000}
    }
    # Tiers 1-10 unchanged from the Lv.500-cap era. late-game (added with
    # the Lv.1000 cap) were re-tuned upward from their original launch
    # values (1250/1400/1550/1700/1850/2000/2150/2300/2400/2500) -- the
    # +150ish flat per-tier growth that worked through Tier 10 was too
    # shallow once the difficulty ramp (boss_difficulty_multiplier) and the
    # later-tier HP curve both got steeper too; this keeps boss-gear
    # progression the thing that actually lets a player close the gap
    # tier-to-tier, rather than lagging behind it.
    variable boss_weapon_order {street_reaper executive_magnum syndicate_rifle kingpin_smg crime_lord_cannon executive_rifle mogul_carbine tycoon_cannon supreme_railgun godfather_cannon syndicate_hammer empire_rifle baron_cannon titan_railgun grand_cannon supreme_cannon shadow_reaper immortal_arsenal ice_factory_weapon masterdon_weapon}

    # Boss armor key -> {display damage_reduction evasion_pct}
    variable boss_armor
    array set boss_armor {
        street_plate       {"Street Boss Plate"             105 5}
        executive_armor    {"Executive Armor"               135 7}
        syndicate_rig      {"Syndicate Exo Rig"              170 9}
        kingpin_shell      {"Kingpin Shell"                  210 11}
        crime_lord_armor   {"Crime Lord Armor"               260 12}
        executive_hardsuit {"Executive Hardsuit"              320 14}
        mogul_exosuit      {"Mogul Exosuit"                   390 16}
        tycoon_plate       {"Tycoon Plate"                    470 18}
        supreme_shell      {"Supreme Shell"                   560 20}
        godfather_armor    {"Godfather Armor"                 660 22}
        syndicate_aegis    {"Syndicate Aegis"                 900 24}
        empire_hardsuit    {"Empire Hardsuit"                1050 26}
        baron_exosuit      {"Crime Baron Exosuit"            1220 27}
        titan_plate        {"Titan Plate"                    1400 29}
        grand_shell        {"Grand Boss Shell"               1600 31}
        supreme_aegis      {"Supreme Boss Aegis"             1820 33}
        shadow_shroud      {"Shadow Shroud"                  2060 35}
        immortal_armor     {"Immortal Armor"                 2320 37}
        ice_factory_armor  {"Ice Factory Armor"              2600 38}
        masterdon_armor    {"Master Don's Eternal Armor"     2900 40}
    }
    # Same story as boss_weapons above: Tiers 1-10 untouched, late-game
    # re-tuned upward (originally 770/890/1010/1140/1270/1400/1530/1660/
    # 1750/1850) to keep armor reduction climbing in step with how much
    # harder the boss you're wearing it against now hits.
    variable boss_armor_order {street_plate executive_armor syndicate_rig kingpin_shell crime_lord_armor executive_hardsuit mogul_exosuit tycoon_plate supreme_shell godfather_armor syndicate_aegis empire_hardsuit baron_exosuit titan_plate grand_shell supreme_aegis shadow_shroud immortal_armor ice_factory_armor masterdon_armor}

    variable boss_bling
    array set boss_bling {
        street_ice         {"Street Ice"             10.0 10.0}
        executive_ice      {"Executive Ice"          12.0 12.0}
        syndicate_ice      {"Syndicate Ice"          14.0 14.0}
        kingpin_ice        {"Kingpin Ice"            16.0 16.0}
        crime_lord_ice     {"Crime Lord Ice"         18.0 18.0}
        executive_goldice  {"Executive Gold Ice"     20.0 20.0}
        mogul_ice           {"Mogul Ice"              22.0 22.0}
        tycoon_ice          {"Tycoon Ice"             24.0 24.0}
        supreme_ice         {"Supreme Ice"            27.0 27.0}
        godfather_ice       {"Godfather Ice"          30.0 30.0}
        syndicate_ice2      {"Syndicate Crown Ice"    33.0 33.0}
        empire_ice          {"Empire Ice"             36.0 36.0}
        baron_ice           {"Baron Ice"              39.0 39.0}
        titan_ice           {"Titan Ice"              42.0 42.0}
        grand_ice           {"Grand Boss Ice"         44.0 44.0}
        supreme_ice2        {"Supreme Boss Ice"       46.0 46.0}
        shadow_ice          {"Shadow Ice"             47.5 47.5}
        immortal_ice        {"Immortal Ice"           49.0 49.0}
        ice_factory         {"Ice Factory"             50.0 50.0}
        master_ice_factory  {"Master Ice Factory"      55.0 55.0}
    }
    variable boss_bling_order {street_ice executive_ice syndicate_ice kingpin_ice crime_lord_ice executive_goldice mogul_ice tycoon_ice supreme_ice godfather_ice syndicate_ice2 empire_ice baron_ice titan_ice grand_ice supreme_ice2 shadow_ice immortal_ice ice_factory master_ice_factory}

    # Boss tools are permanent bonus sources, not inventory consumables.
    variable boss_tools
    array set boss_tools {
        street_charm        {"Street Boss Charm"        "bonus"}
        executive_chip      {"Executive Chip"            "bonus"}
        syndicate_core      {"Syndicate Core"             "bonus"}
        kingpin_token       {"Kingpin Token"              "bonus"}
        crime_lord_relic    {"Crime Lord Relic"           "bonus"}
        executive_matrix    {"Executive Matrix"           "bonus"}
        mogul_module        {"Mogul Module"               "bonus"}
        tycoon_engine       {"Tycoon Engine"              "bonus"}
        supreme_drive       {"Supreme Drive"              "bonus"}
        godfather_seal      {"Godfather Seal"             "bonus"}
        syndicate_eye       {"Syndicate Eye"              "bonus"}
        empire_reactor      {"Empire Reactor"             "bonus"}
        baron_relic         {"Baron Relic"                "bonus"}
        titan_core          {"Titan Core"                 "bonus"}
        grand_engine        {"Grand Boss Engine"          "bonus"}
        supreme_matrix      {"Supreme Boss Matrix"        "bonus"}
        shadow_device       {"Shadow Device"              "bonus"}
        immortal_core       {"Immortal Core"              "bonus"}
        ice_factory_core    {"Ice Factory Core"           "bonus"}
        masterdon_core      {"Master Don's Core"           "bonus"}
    }
    variable boss_tool_order {street_charm executive_chip syndicate_core kingpin_token crime_lord_relic executive_matrix mogul_module tycoon_engine supreme_drive godfather_seal syndicate_eye empire_reactor baron_relic titan_core grand_engine supreme_matrix shadow_device immortal_core ice_factory_core masterdon_core}

    variable boss_loot_bonus_mult 1.5

    ##### ---------------- LEGENDARY (BLACK MARKET SET) ---------------- #####
    # Four legendary pieces -- weapon, armor, bling (ice) and a tool -- that
    # sit ABOVE boss gear at every point in the game. They are not bought and
    # not dropped by any boss: the only source is a very rare find while
    # shopping the black market (see maybe_legend_drop), and a piece can drop
    # at ANY level.
    #
    # They "tier to your level": a legendary piece has no fixed stat line.
    # Its damage/armor/ice value is derived live from the boss piece for the
    # player's own level bracket (tier = ceil(level/50), clamped 1-20) and
    # then multiplied by legend_mult, so it is always the strongest item the
    # player could be holding for where they actually are -- at Lv.30 and at
    # Lv.1200 alike. That is why weapon_dmg/armor_reduce/bling_bonus_pct all
    # take an optional nick: for a legendary key the value is per-player.
    #
    # Collecting more of the set pays off super-linearly. Per pieces held
    # (1-4): stat bonus 10/20/30/50 percent on all four core stats, and a
    # collection bonus of 25/50/75/100 percent on pimp/casino/dealer
    # collections. The set bonus is counted on pieces OWNED (collected), not
    # equipped -- the tool has no slot to equip into.
    #
    # Legendary gear can never be sold: it is absent from shop_item_lookup,
    # so the shop refuses it and every bulk-sell path skips it. That also
    # closes the sell-and-refarm loop the boss-gear resale throttle exists
    # to blunt.
    variable legend_items
    array set legend_items {
        eclipse_cannon {weapon "Eclipse Syndicate Cannon"}
        eclipse_plate  {armor  "Eclipse Syndicate Plate"}
        eclipse_ice    {bling  "Eclipse Syndicate Ice"}
        eclipse_core   {tool   "Eclipse Syndicate Core"}
    }
    variable legend_order {eclipse_cannon eclipse_plate eclipse_ice eclipse_core}
    # How far above the same-tier boss piece a legendary piece sits.
    variable legend_mult 1.30
    # Index = pieces owned - 1.
    variable legend_stat_pct_by_count    {10 20 30 50}
    variable legend_collect_pct_by_count {25 50 75 100}
    # Drop tuning. Guarded with info exists so an operator can override either
    # in Mafia.cfg (which is sourced BEFORE this file's body) without this
    # line silently stomping the configured value on every load.
    #   legend_drop_pct     -- percent chance per eligible black-market roll
    #   legend_roll_cooldown-- seconds between eligible rolls, per player
    # Together these are what make the set rare: at the defaults a player
    # gets one 5% roll every 10 minutes, so a single piece averages a few
    # hours of active black-market trading and the full set considerably
    # longer -- and no amount of cash can buy the roll faster.
    variable legend_drop_pct
    if {![info exists legend_drop_pct]}      { set legend_drop_pct 5 }
    variable legend_roll_cooldown
    if {![info exists legend_roll_cooldown]} { set legend_roll_cooldown 600 }

    ##### ---------------- FENCE / BLACK MARKET ---------------- #####
    # item -> {display base_value crimes_that_drop_it}
    variable fence_goods
    array set fence_goods {
        electronics {"Hot Electronics"  250  {burglary}}
        jewelry     {"Stolen Jewelry"   400  {burglary}}
        car         {"Stolen Car"       900  {carjack}}
        bonds       {"Bearer Bonds"     1500 {armored_truck bank_heist}}
        art         {"Stolen Art"       3000 {bank_heist}}
    }
    # crime -> chance% of also dropping a good, and which goods it can drop
    variable fence_drop_table
    array set fence_drop_table {
        burglary       {45 {electronics jewelry}}
        carjack        {50 {car}}
        armored_truck  {45 {bonds}}
        bank_heist     {50 {bonds art}}
    }
    # rank -> fence cut (% the fence keeps)
    #
    # Every title in `ranks` must appear here. fence_cut_for walks this list
    # looking for the player's rank and falls back to 0.30 when it finds no
    # entry -- and "Executive" (the rank between Boss and Don, ranks[9]) was
    # missing, so reaching it was a PUNISHMENT: a Boss handing goods to the
    # fence for a 10% cut was suddenly charged the 0.30 fallback, worse than
    # every rank above Associate, until they hit Don and it snapped back to 8%.
    # 0.09 keeps the curve monotonic between Boss (0.10) and Don (0.08).
    variable fence_cut_by_rank {
        "Street Punk"  0.32
        "Associate"    0.30
        "Soldier"      0.27
        "Made Man"     0.24
        "Enforcer"     0.21
        "Capo"         0.18
        "Underboss"    0.15
        "Consigliere"  0.12
        "Boss"         0.10
        "Executive"    0.09
        "Don"          0.08
    }
    variable goods_decay_interval 600   ;# seconds; value drops per interval held
    variable goods_decay_pct      5     ;# % value lost per interval
    variable goods_decay_floor    0.40  ;# never worth less than 40% of base

    # black market consumables, restocked randomly from this pool
    variable blackmarket_pool
    array set blackmarket_pool {
        fake_id      {"Fake ID"            2000 "auto-beats your next jail roll"}
        ghost_plates {"Ghost Plates"       1200 "-15 jail risk on your next crime"}
        insider_tip  {"Insider Tip"        3500 "guarantees success on your next crime"}
        burner_phone {"Burner Phone"       800  "skips your next deal cooldown"}
        laser_cutter {"Laser Cutter"       4200 "-20 jail risk on your next crime"}
        emp_device   {"EMP Device"         5500 "auto-beats your next jail roll"}
        thermal_scope {"Thermal Scope"     2600 "-10 fail chance on your next crime"}
        micro_camera {"Micro Spy Camera"   1800 "-10 fail chance on your next crime"}
        exploding_pen {"Exploding Pen"     3000 "guarantees success on your next crime"}
        submersible_car {"Submersible Car" 6800 "-20 jail risk on your next crime"}
    }
    variable blackmarket_stock   ;# currently available: item -> price
    array set blackmarket_stock {}
    # Plain default (not a forced re-assignment): on rehash this file is
    # re-sourced, and a bare "variable x {value}" at namespace scope
    # OVERWRITES an already-running timer's id with "", which breaks the
    # killutimer guard in start_blackmarket_timer and leaks a duplicate
    # timer every rehash. Only set the default the first time.
    variable blackmarket_timer_id
    if {![info exists blackmarket_timer_id]} { set blackmarket_timer_id "" }
    variable blackmarket_restock_secs 1200   ;# 20 min
    variable blackmarket_size 3

    ##### ---------------- JOBS (tiered by level bracket) ---------------- #####
    # job_cooldown is set in Mafia.cfg -- see the note on
    # casino_collect_cooldown above.
    variable job_cash_mult 14  ;# large job cash multiplier; job XP is level-based (1-10 levels)
    variable jobs
    array set jobs {
        slowyard {0 713 1359 22 47 21 7 "The shipment crosses clean, nobody looks twice at the truck. (Smuggling run at downtown.)" "Customs pulls the truck for a random inspection. (Smuggling run at downtown.)" 1}
        finalraven {0 1014 1442 9 31 13 9 "The witness suddenly can't remember a thing. (Witness tampering at uptown.)" "The witness records the conversation and hands it to the DA. (Witness tampering at uptown.)" 1}
        closedyard {0 204 1174 20 71 16 9 "The cash comes out the other side spotless. (Money laundering op at the junkyard.)" "A bank compliance officer flags the transfers. (Money laundering op at the junkyard.)" 1}
        silentdocks {0 719 1943 8 35 21 12 "The rival crew's operation goes up in smoke -- literally. (Rival sabotage at the penthouse district.)" "You're spotted planting the charge and have to run. (Rival sabotage at the penthouse district.)" 1}
        deepdice {0 468 1084 29 52 11 12 "The eye in the sky never catches the switch. (Casino skim at the rail yard.)" "Pit boss makes you as a cheat before you cash out. (Casino skim at the rail yard.)" 1}
        sharpalley {0 854 1868 24 43 21 13 "The shipment crosses clean, nobody looks twice at the truck. (Smuggling run at the north side.)" "Customs pulls the truck for a random inspection. (Smuggling run at the north side.)" 1}
        emptyrumor {0 925 1401 43 78 20 15 "The witness suddenly can't remember a thing. (Witness tampering at the warehouse district.)" "The witness records the conversation and hands it to the DA. (Witness tampering at the warehouse district.)" 1}
        frozenjoker {0 543 1660 12 31 20 9 "You walk out with the whole client ledger on a thumb drive. (Data heist at the penthouse district.)" "IT security traces the breach back to your laptop. (Data heist at the penthouse district.)" 1}
        velvetqueen {0 626 1909 14 55 14 13 "The target never sees it coming. Clean, quiet, paid in full. (Assassination contract at uptown.)" "The target's crew was ready and the job turns into a shootout. (Assassination contract at uptown.)" 1}
        velvetace {0 908 1667 21 55 21 16 "You walk out with the whole client ledger on a thumb drive. (Data heist at the industrial park.)" "IT security traces the breach back to your laptop. (Data heist at the industrial park.)" 1}
        calmwolf {0 500 1442 54 86 12 13 "Every shop on the block pays up without a word of trouble. (Protection racket at the junkyard.)" "One owner calls it in instead of paying. (Protection racket at the junkyard.)" 1}
        coldwhisper {0 1290 1910 51 88 22 18 "The crates move without ATF ever catching wind. (Gunrunning deal at the rail yard.)" "An informant tips off the feds before the handoff. (Gunrunning deal at the rail yard.)" 1}
        opensignal {0 215 1435 28 70 14 7 "The car's stripped for parts before dawn -- clean money. (Chop shop run at the financial district.)" "The VIN doesn't scrub clean and a cop runs the plate. (Chop shop run at the financial district.)" 1}
        opentiger {0 794 1407 49 97 16 16 "You take the truck at the light and vanish into the yard. (Cargo hijack at the penthouse district.)" "The driver hits a silent alarm under the dash. (Cargo hijack at the penthouse district.)" 1}
        coppersnake {0 692 1230 23 75 18 10 "The rival crew's operation goes up in smoke -- literally. (Rival sabotage at the old quarter.)" "You're spotted planting the charge and have to run. (Rival sabotage at the old quarter.)" 1}
        doubletunnel {0 967 1733 22 47 18 13 "Your crew claims the block and the old owners back off quiet. (Territory grab at the marina.)" "The old owners fight back harder than expected. (Territory grab at the marina.)" 1}
        tangledcrown {0 374 926 48 75 22 16 "Every shop on the block pays up without a word of trouble. (Protection racket at the docks.)" "One owner calls it in instead of paying. (Protection racket at the docks.)" 1}
        lastace {0 280 1070 32 87 17 14 "The mark hands over the cash rather than see his family hurt. (Shakedown at the junkyard.)" "The mark calls your bluff and calls the cops instead. (Shakedown at the junkyard.)" 1}
        rustysnake {0 173 1265 54 78 20 14 "You skim the pension fund without anyone noticing. (Union racketeering at the subway tunnels.)" "An auditor flags the books before you can cover it. (Union racketeering at the subway tunnels.)" 1}
        goldendocks {0 378 1074 35 62 17 6 "You skim the pension fund without anyone noticing. (Union racketeering at the harbor.)" "An auditor flags the books before you can cover it. (Union racketeering at the harbor.)" 1}
        ironraven {22125 1053 2943 30 145 18 22 "You skim the pension fund without anyone noticing. (Union racketeering at the airport.)" "An auditor flags the books before you can cover it. (Union racketeering at the airport.)" 2}
        quietdice {22125 1136 2300 64 119 22 21 "The cash comes out the other side spotless. (Money laundering op at the junkyard.)" "A bank compliance officer flags the transfers. (Money laundering op at the junkyard.)" 2}
        ironledger {22125 2775 4289 79 116 15 14 "The cash comes out the other side spotless. (Money laundering op at downtown.)" "A bank compliance officer flags the transfers. (Money laundering op at downtown.)" 2}
        dirtyvault {22125 559 1903 89 134 15 20 "The target never sees it coming. Clean, quiet, paid in full. (Assassination contract at the financial district.)" "The target's crew was ready and the job turns into a shootout. (Assassination contract at the financial district.)" 2}
        coldviper {22125 2503 4922 33 84 24 16 "Your guy walks out the front gate in a guard's uniform. (Prison break at uptown.)" "The escape route is blocked and the alarm goes up. (Prison break at uptown.)" 2}
        coppertiger {22125 1407 3338 94 183 17 17 "The witness suddenly can't remember a thing. (Witness tampering at the industrial park.)" "The witness records the conversation and hands it to the DA. (Witness tampering at the industrial park.)" 2}
        lasttiger {22125 1956 4182 100 182 21 17 "You take the truck at the light and vanish into the yard. (Cargo hijack at the strip.)" "The driver hits a silent alarm under the dash. (Cargo hijack at the strip.)" 2}
        burningfox {22125 1337 2648 25 103 14 18 "The rival crew's operation goes up in smoke -- literally. (Rival sabotage at the warehouse district.)" "You're spotted planting the charge and have to run. (Rival sabotage at the warehouse district.)" 2}
        wetpawn {22125 2732 4034 17 61 25 19 "The witness suddenly can't remember a thing. (Witness tampering at the financial district.)" "The witness records the conversation and hands it to the DA. (Witness tampering at the financial district.)" 2}
        silentviper {22125 598 3303 21 98 15 17 "The car's stripped for parts before dawn -- clean money. (Chop shop run at the financial district.)" "The VIN doesn't scrub clean and a cop runs the plate. (Chop shop run at the financial district.)" 2}
        doubleviper {22125 2310 3599 86 137 25 18 "The fake bills pass every register in the district. (Counterfeit run at the rail yard.)" "A teller catches the watermark and hits the silent alarm. (Counterfeit run at the rail yard.)" 2}
        ironking {22125 1317 3774 77 164 17 10 "Your crew claims the block and the old owners back off quiet. (Territory grab at the border crossing.)" "The old owners fight back harder than expected. (Territory grab at the border crossing.)" 2}
        slowraven {22125 1773 3491 69 163 25 9 "The shipment crosses clean, nobody looks twice at the truck. (Smuggling run at the marina.)" "Customs pulls the truck for a random inspection. (Smuggling run at the marina.)" 2}
        silentyard {22125 1971 4313 60 108 17 12 "The shipment crosses clean, nobody looks twice at the truck. (Smuggling run at the docks.)" "Customs pulls the truck for a random inspection. (Smuggling run at the docks.)" 2}
        redwarehouse {22125 2159 3297 71 129 18 16 "You take the truck at the light and vanish into the yard. (Cargo hijack at the subway tunnels.)" "The driver hits a silent alarm under the dash. (Cargo hijack at the subway tunnels.)" 2}
        velvetdebt {22125 2137 4642 87 134 14 19 "The fake bills pass every register in the district. (Counterfeit run at uptown.)" "A teller catches the watermark and hits the silent alarm. (Counterfeit run at uptown.)" 2}
        coldfox {22125 704 3452 113 178 16 15 "The witness suddenly can't remember a thing. (Witness tampering at downtown.)" "The witness records the conversation and hands it to the DA. (Witness tampering at downtown.)" 2}
        closedrook {22125 1197 3818 68 110 16 15 "Your guy walks out the front gate in a guard's uniform. (Prison break at the border crossing.)" "The escape route is blocked and the alarm goes up. (Prison break at the border crossing.)" 2}
        fastwhisper {22125 1408 4156 75 146 20 20 "You're in and out before the alarm even finishes ringing. (Smash-and-grab at the underpass.)" "The display case shatters wrong and security is on you in seconds. (Smash-and-grab at the underpass.)" 2}
        openwire {22125 956 2195 54 116 14 18 "The witness suddenly can't remember a thing. (Witness tampering at the border crossing.)" "The witness records the conversation and hands it to the DA. (Witness tampering at the border crossing.)" 2}
        loadedcrown {81750 3558 6148 40 100 27 19 "The witness suddenly can't remember a thing. (Witness tampering at the docks.)" "The witness records the conversation and hands it to the DA. (Witness tampering at the docks.)" 3}
        wetdeal {81750 1139 2677 156 220 20 13 "The cash comes out the other side spotless. (Money laundering op at the airport.)" "A bank compliance officer flags the transfers. (Money laundering op at the airport.)" 3}
        royalraven {81750 3260 5529 129 198 27 15 "The mark pays to keep the photos out of the papers. (Blackmail job at uptown.)" "The mark goes to the police instead of paying. (Blackmail job at uptown.)" 3}
        loadedqueen {81750 657 4499 46 153 28 21 "Your crew claims the block and the old owners back off quiet. (Territory grab at the junkyard.)" "The old owners fight back harder than expected. (Territory grab at the junkyard.)" 3}
        closedwire {81750 1790 4164 78 217 29 17 "Your crew claims the block and the old owners back off quiet. (Territory grab at the airport.)" "The old owners fight back harder than expected. (Territory grab at the airport.)" 3}
        deepghost {81750 2116 3958 102 214 23 24 "The fake bills pass every register in the district. (Counterfeit run at the rail yard.)" "A teller catches the watermark and hits the silent alarm. (Counterfeit run at the rail yard.)" 3}
        midnightfavor {81750 2372 6222 170 236 19 20 "Every shop on the block pays up without a word of trouble. (Protection racket at downtown.)" "One owner calls it in instead of paying. (Protection racket at downtown.)" 3}
        calmcrown {81750 1581 3429 115 281 19 15 "You take the truck at the light and vanish into the yard. (Cargo hijack at the airport.)" "The driver hits a silent alarm under the dash. (Cargo hijack at the airport.)" 3}
        crookedtiger {81750 1141 4241 165 309 22 21 "You walk out with the whole client ledger on a thumb drive. (Data heist at the strip.)" "IT security traces the breach back to your laptop. (Data heist at the strip.)" 3}
        openshadow {81750 3230 6807 102 275 28 13 "The cash comes out the other side spotless. (Money laundering op at downtown.)" "A bank compliance officer flags the transfers. (Money laundering op at downtown.)" 3}
        luckywhisper {81750 967 2711 167 240 22 16 "The family pays fast and quiet -- textbook job. (Kidnap-for-ransom at the rail yard.)" "The mark's bodyguards were waiting and it goes sideways. (Kidnap-for-ransom at the rail yard.)" 3}
        burningwire {81750 3434 6144 78 219 28 25 "The mark pays to keep the photos out of the papers. (Blackmail job at the boardwalk.)" "The mark goes to the police instead of paying. (Blackmail job at the boardwalk.)" 3}
        crookedfox {81750 2496 4830 39 104 28 18 "You skim the pension fund without anyone noticing. (Union racketeering at the airport.)" "An auditor flags the books before you can cover it. (Union racketeering at the airport.)" 3}
        midnightrook {81750 509 3181 59 194 22 14 "You skim the pension fund without anyone noticing. (Union racketeering at the docks.)" "An auditor flags the books before you can cover it. (Union racketeering at the docks.)" 3}
        wetviper {81750 3385 6442 169 224 19 13 "The rival crew's operation goes up in smoke -- literally. (Rival sabotage at the subway tunnels.)" "You're spotted planting the charge and have to run. (Rival sabotage at the subway tunnels.)" 3}
        brokenhawk {81750 642 3460 175 299 20 18 "The family pays fast and quiet -- textbook job. (Kidnap-for-ransom at the subway tunnels.)" "The mark's bodyguards were waiting and it goes sideways. (Kidnap-for-ransom at the subway tunnels.)" 3}
        ironblade {81750 1757 4556 36 205 23 15 "The family pays fast and quiet -- textbook job. (Kidnap-for-ransom at the docks.)" "The mark's bodyguards were waiting and it goes sideways. (Kidnap-for-ransom at the docks.)" 3}
        royalfox {81750 1943 5542 130 308 27 23 "The fake bills pass every register in the district. (Counterfeit run at the warehouse district.)" "A teller catches the watermark and hits the silent alarm. (Counterfeit run at the warehouse district.)" 3}
        loadedrook {81750 4036 6007 71 237 24 12 "The family pays fast and quiet -- textbook job. (Kidnap-for-ransom at the financial district.)" "The mark's bodyguards were waiting and it goes sideways. (Kidnap-for-ransom at the financial district.)" 3}
        royalwolf {81750 3699 6691 89 177 20 24 "The building goes up clean, insurance money guaranteed. (Arson job at the harbor.)" "A fire marshal spots accelerant before you're even off the block. (Arson job at the harbor.)" 3}
        tangledpier {178875 984 6600 91 215 29 20 "The shipment crosses clean, nobody looks twice at the truck. (Smuggling run at the underpass.)" "Customs pulls the truck for a random inspection. (Smuggling run at the underpass.)" 4}
        closedrooftop {178875 2493 4447 203 325 28 20 "The target never sees it coming. Clean, quiet, paid in full. (Assassination contract at the financial district.)" "The target's crew was ready and the job turns into a shootout. (Assassination contract at the financial district.)" 4}
        tangleddice {178875 2953 7590 199 402 28 25 "You skim the pension fund without anyone noticing. (Union racketeering at uptown.)" "An auditor flags the books before you can cover it. (Union racketeering at uptown.)" 4}
        crookeddeal {178875 893 3598 101 219 31 19 "The witness suddenly can't remember a thing. (Witness tampering at the harbor.)" "The witness records the conversation and hands it to the DA. (Witness tampering at the harbor.)" 4}
        goldenbridge {178875 5554 10874 123 276 28 24 "The car's stripped for parts before dawn -- clean money. (Chop shop run at the warehouse district.)" "The VIN doesn't scrub clean and a cop runs the plate. (Chop shop run at the warehouse district.)" 4}
        deepdocks {178875 3822 7140 100 184 33 21 "The cash comes out the other side spotless. (Money laundering op at the warehouse district.)" "A bank compliance officer flags the transfers. (Money laundering op at the warehouse district.)" 4}
        blackshadow {178875 5077 8452 128 311 23 25 "You're in and out before the alarm even finishes ringing. (Smash-and-grab at the airport.)" "The display case shatters wrong and security is on you in seconds. (Smash-and-grab at the airport.)" 4}
        calmwire {178875 3238 6019 219 368 30 19 "The eye in the sky never catches the switch. (Casino skim at the junkyard.)" "Pit boss makes you as a cheat before you cash out. (Casino skim at the junkyard.)" 4}
        burningwhisper {178875 3963 8146 176 281 25 21 "The mark hands over the cash rather than see his family hurt. (Shakedown at the harbor.)" "The mark calls your bluff and calls the cops instead. (Shakedown at the harbor.)" 4}
        secretghost {178875 5709 9935 138 351 22 19 "The crates move without ATF ever catching wind. (Gunrunning deal at the industrial park.)" "An informant tips off the feds before the handoff. (Gunrunning deal at the industrial park.)" 4}
        paperledger {178875 4188 8588 154 340 29 25 "The target never sees it coming. Clean, quiet, paid in full. (Assassination contract at the boardwalk.)" "The target's crew was ready and the job turns into a shootout. (Assassination contract at the boardwalk.)" 4}
        paperwolf {178875 4543 7694 203 297 26 23 "You take the truck at the light and vanish into the yard. (Cargo hijack at the airport.)" "The driver hits a silent alarm under the dash. (Cargo hijack at the airport.)" 4}
        burningrumor {178875 1432 5117 207 359 25 27 "The mark pays to keep the photos out of the papers. (Blackmail job at the harbor.)" "The mark goes to the police instead of paying. (Blackmail job at the harbor.)" 4}
        doublewhisper {178875 867 3006 97 291 31 28 "You take the truck at the light and vanish into the yard. (Cargo hijack at the old quarter.)" "The driver hits a silent alarm under the dash. (Cargo hijack at the old quarter.)" 4}
        dirtypawn {178875 4062 7415 218 389 29 21 "Every shop on the block pays up without a word of trouble. (Protection racket at the casino district.)" "One owner calls it in instead of paying. (Protection racket at the casino district.)" 4}
        rustywhisper {178875 712 3346 234 415 25 17 "The fake bills pass every register in the district. (Counterfeit run at the old quarter.)" "A teller catches the watermark and hits the silent alarm. (Counterfeit run at the old quarter.)" 4}
        tangledalley {178875 1078 4880 66 255 24 27 "The cash comes out the other side spotless. (Money laundering op at the casino district.)" "A bank compliance officer flags the transfers. (Money laundering op at the casino district.)" 4}
        recklessviper {178875 5245 9605 228 414 31 28 "The rival crew's operation goes up in smoke -- literally. (Rival sabotage at the airport.)" "You're spotted planting the charge and have to run. (Rival sabotage at the airport.)" 4}
        burningengine {178875 5155 10568 75 269 29 19 "The cash comes out the other side spotless. (Money laundering op at the marina.)" "A bank compliance officer flags the transfers. (Money laundering op at the marina.)" 4}
        fastfavor {178875 4937 10667 195 329 26 22 "The fake bills pass every register in the district. (Counterfeit run at the rail yard.)" "A teller catches the watermark and hits the silent alarm. (Counterfeit run at the rail yard.)" 4}
        emptydice {313500 2760 7202 215 387 34 19 "Every shop on the block pays up without a word of trouble. (Protection racket at the strip.)" "One owner calls it in instead of paying. (Protection racket at the strip.)" 5}
        closedwolf {313500 2734 8088 122 393 29 19 "The family pays fast and quiet -- textbook job. (Kidnap-for-ransom at the old quarter.)" "The mark's bodyguards were waiting and it goes sideways. (Kidnap-for-ransom at the old quarter.)" 5}
        calmharbor {313500 3550 10212 282 479 26 21 "The mark hands over the cash rather than see his family hurt. (Shakedown at the marina.)" "The mark calls your bluff and calls the cops instead. (Shakedown at the marina.)" 5}
        paperdice {313500 7146 14147 54 340 35 24 "The mark hands over the cash rather than see his family hurt. (Shakedown at the underpass.)" "The mark calls your bluff and calls the cops instead. (Shakedown at the underpass.)" 5}
        finaldocks {313500 3721 8384 243 441 34 29 "Your guy walks out the front gate in a guard's uniform. (Prison break at downtown.)" "The escape route is blocked and the alarm goes up. (Prison break at downtown.)" 5}
        slowpawn {313500 2646 8862 156 316 32 25 "The witness suddenly can't remember a thing. (Witness tampering at the junkyard.)" "The witness records the conversation and hands it to the DA. (Witness tampering at the junkyard.)" 5}
        secretrumor {313500 3593 9122 128 338 28 27 "You're in and out before the alarm even finishes ringing. (Smash-and-grab at the underpass.)" "The display case shatters wrong and security is on you in seconds. (Smash-and-grab at the underpass.)" 5}
        sharpqueen {313500 4067 11132 57 169 36 24 "The witness suddenly can't remember a thing. (Witness tampering at downtown.)" "The witness records the conversation and hands it to the DA. (Witness tampering at downtown.)" 5}
        paperblade {313500 2328 4956 177 365 31 21 "The family pays fast and quiet -- textbook job. (Kidnap-for-ransom at the casino district.)" "The mark's bodyguards were waiting and it goes sideways. (Kidnap-for-ransom at the casino district.)" 5}
        brokendocks {313500 3604 8926 186 469 32 22 "The rival crew's operation goes up in smoke -- literally. (Rival sabotage at the harbor.)" "You're spotted planting the charge and have to run. (Rival sabotage at the harbor.)" 5}
        finaltunnel {313500 998 7633 70 250 29 28 "Every shop on the block pays up without a word of trouble. (Protection racket at the border crossing.)" "One owner calls it in instead of paying. (Protection racket at the border crossing.)" 5}
        doublewolf {313500 7018 9489 170 312 26 27 "Every shop on the block pays up without a word of trouble. (Protection racket at the docks.)" "One owner calls it in instead of paying. (Protection racket at the docks.)" 5}
        dirtyshadow {313500 1874 7970 102 337 29 25 "The family pays fast and quiet -- textbook job. (Kidnap-for-ransom at the financial district.)" "The mark's bodyguards were waiting and it goes sideways. (Kidnap-for-ransom at the financial district.)" 5}
        midnightecho {313500 2214 9394 102 392 28 22 "You skim the pension fund without anyone noticing. (Union racketeering at the north side.)" "An auditor flags the books before you can cover it. (Union racketeering at the north side.)" 5}
        calmrook {313500 1050 5822 236 428 37 21 "The shipment crosses clean, nobody looks twice at the truck. (Smuggling run at the penthouse district.)" "Customs pulls the truck for a random inspection. (Smuggling run at the penthouse district.)" 5}
        closedghost {313500 6497 13852 168 285 37 30 "Every shop on the block pays up without a word of trouble. (Protection racket at the penthouse district.)" "One owner calls it in instead of paying. (Protection racket at the penthouse district.)" 5}
        blackalley {313500 1831 8684 65 244 34 24 "The target never sees it coming. Clean, quiet, paid in full. (Assassination contract at the junkyard.)" "The target's crew was ready and the job turns into a shootout. (Assassination contract at the junkyard.)" 5}
        glassace {313500 4984 9996 50 248 33 19 "You walk out with the whole client ledger on a thumb drive. (Data heist at uptown.)" "IT security traces the breach back to your laptop. (Data heist at uptown.)" 5}
        deepbridge {313500 6046 12029 122 324 28 29 "The mark hands over the cash rather than see his family hurt. (Shakedown at the north side.)" "The mark calls your bluff and calls the cops instead. (Shakedown at the north side.)" 5}
        doublebridge {313500 5885 12510 291 501 32 31 "The cash comes out the other side spotless. (Money laundering op at the rail yard.)" "A bank compliance officer flags the transfers. (Money laundering op at the rail yard.)" 5}
        dirtyrooftop {485625 3652 8336 98 350 37 24 "Your crew claims the block and the old owners back off quiet. (Territory grab at the rail yard.)" "The old owners fight back harder than expected. (Territory grab at the rail yard.)" 6}
        calmdice {485625 6011 14157 248 530 30 28 "The rival crew's operation goes up in smoke -- literally. (Rival sabotage at the penthouse district.)" "You're spotted planting the charge and have to run. (Rival sabotage at the penthouse district.)" 6}
        coldtunnel {485625 5006 9416 235 477 35 25 "The eye in the sky never catches the switch. (Casino skim at the industrial park.)" "Pit boss makes you as a cheat before you cash out. (Casino skim at the industrial park.)" 6}
        quietwhisper {485625 5565 8321 318 525 31 24 "The mark pays to keep the photos out of the papers. (Blackmail job at the rail yard.)" "The mark goes to the police instead of paying. (Blackmail job at the rail yard.)" 6}
        blackblade {485625 5560 14443 177 530 40 32 "The mark hands over the cash rather than see his family hurt. (Shakedown at the border crossing.)" "The mark calls your bluff and calls the cops instead. (Shakedown at the border crossing.)" 6}
        frozenraven {485625 7507 10321 101 361 33 27 "Your guy walks out the front gate in a guard's uniform. (Prison break at the casino district.)" "The escape route is blocked and the alarm goes up. (Prison break at the casino district.)" 6}
        deeprooftop {485625 6451 13888 242 594 38 29 "The fake bills pass every register in the district. (Counterfeit run at the strip.)" "A teller catches the watermark and hits the silent alarm. (Counterfeit run at the strip.)" 6}
        dirtysnake {485625 7122 14303 223 513 41 28 "You walk out with the whole client ledger on a thumb drive. (Data heist at the marina.)" "IT security traces the breach back to your laptop. (Data heist at the marina.)" 6}
        frozenengine {485625 3071 7632 115 323 35 22 "You skim the pension fund without anyone noticing. (Union racketeering at the strip.)" "An auditor flags the books before you can cover it. (Union racketeering at the strip.)" 6}
        recklessshadow {485625 2581 7026 301 552 41 30 "The witness suddenly can't remember a thing. (Witness tampering at the industrial park.)" "The witness records the conversation and hands it to the DA. (Witness tampering at the industrial park.)" 6}
        midnightsignal {485625 3330 6826 153 414 33 26 "The cash comes out the other side spotless. (Money laundering op at the junkyard.)" "A bank compliance officer flags the transfers. (Money laundering op at the junkyard.)" 6}
        glassshadow {485625 1127 9600 327 501 34 21 "The building goes up clean, insurance money guaranteed. (Arson job at the strip.)" "A fire marshal spots accelerant before you're even off the block. (Arson job at the strip.)" 6}
        brokenqueen {485625 3405 11791 118 479 31 34 "The car's stripped for parts before dawn -- clean money. (Chop shop run at the subway tunnels.)" "The VIN doesn't scrub clean and a cop runs the plate. (Chop shop run at the subway tunnels.)" 6}
        paperdocks {485625 3341 9859 299 634 35 23 "You're in and out before the alarm even finishes ringing. (Smash-and-grab at the penthouse district.)" "The display case shatters wrong and security is on you in seconds. (Smash-and-grab at the penthouse district.)" 6}
        finalblade {485625 8721 15307 112 255 36 28 "The car's stripped for parts before dawn -- clean money. (Chop shop run at the rail yard.)" "The VIN doesn't scrub clean and a cop runs the plate. (Chop shop run at the rail yard.)" 6}
        finalwarehouse {485625 6168 14464 81 268 32 33 "Every shop on the block pays up without a word of trouble. (Protection racket at the penthouse district.)" "One owner calls it in instead of paying. (Protection racket at the penthouse district.)" 6}
        doublejoker {485625 1709 6415 114 437 39 30 "Your crew claims the block and the old owners back off quiet. (Territory grab at the strip.)" "The old owners fight back harder than expected. (Territory grab at the strip.)" 6}
        dryengine {485625 7366 14319 248 588 37 25 "The mark pays to keep the photos out of the papers. (Blackmail job at the financial district.)" "The mark goes to the police instead of paying. (Blackmail job at the financial district.)" 6}
        tangledrooftop {485625 3513 10844 84 244 42 24 "Your crew claims the block and the old owners back off quiet. (Territory grab at the marina.)" "The old owners fight back harder than expected. (Territory grab at the marina.)" 6}
        emptyhawk {485625 6422 9760 134 366 32 29 "You take the truck at the light and vanish into the yard. (Cargo hijack at the rail yard.)" "The driver hits a silent alarm under the dash. (Cargo hijack at the rail yard.)" 6}
        glassecho {695250 1228 7702 293 661 38 24 "Every shop on the block pays up without a word of trouble. (Protection racket at the industrial park.)" "One owner calls it in instead of paying. (Protection racket at the industrial park.)" 7}
        loadedfavor {695250 5817 14703 295 459 44 27 "The fake bills pass every register in the district. (Counterfeit run at the strip.)" "A teller catches the watermark and hits the silent alarm. (Counterfeit run at the strip.)" 7}
        coppercrown {695250 4426 11036 121 527 37 34 "You skim the pension fund without anyone noticing. (Union racketeering at the penthouse district.)" "An auditor flags the books before you can cover it. (Union racketeering at the penthouse district.)" 7}
        coldwarehouse {695250 3515 7227 93 305 46 28 "The family pays fast and quiet -- textbook job. (Kidnap-for-ransom at the rail yard.)" "The mark's bodyguards were waiting and it goes sideways. (Kidnap-for-ransom at the rail yard.)" 7}
        brokenpawn {695250 5913 12638 126 493 45 28 "The mark pays to keep the photos out of the papers. (Blackmail job at the penthouse district.)" "The mark goes to the police instead of paying. (Blackmail job at the penthouse district.)" 7}
        quietking {695250 9384 16935 315 667 35 33 "The crates move without ATF ever catching wind. (Gunrunning deal at the rail yard.)" "An informant tips off the feds before the handoff. (Gunrunning deal at the rail yard.)" 7}
        glassdice {695250 6465 14538 191 332 35 27 "The car's stripped for parts before dawn -- clean money. (Chop shop run at the marina.)" "The VIN doesn't scrub clean and a cop runs the plate. (Chop shop run at the marina.)" 7}
        calmqueen {695250 1524 10916 407 672 43 24 "Your crew claims the block and the old owners back off quiet. (Territory grab at the penthouse district.)" "The old owners fight back harder than expected. (Territory grab at the penthouse district.)" 7}
        whitealley {695250 9687 18152 289 559 36 33 "The building goes up clean, insurance money guaranteed. (Arson job at the border crossing.)" "A fire marshal spots accelerant before you're even off the block. (Arson job at the border crossing.)" 7}
        goldencellar {695250 2679 9657 241 578 39 29 "The mark hands over the cash rather than see his family hurt. (Shakedown at the border crossing.)" "The mark calls your bluff and calls the cops instead. (Shakedown at the border crossing.)" 7}
        crookedjoker {695250 6588 13088 418 799 38 34 "The shipment crosses clean, nobody looks twice at the truck. (Smuggling run at the industrial park.)" "Customs pulls the truck for a random inspection. (Smuggling run at the industrial park.)" 7}
        frozenvault {695250 1786 8639 108 397 38 29 "The crates move without ATF ever catching wind. (Gunrunning deal at the subway tunnels.)" "An informant tips off the feds before the handoff. (Gunrunning deal at the subway tunnels.)" 7}
        goldenwolf {695250 9616 19501 63 468 41 30 "The shipment crosses clean, nobody looks twice at the truck. (Smuggling run at the underpass.)" "Customs pulls the truck for a random inspection. (Smuggling run at the underpass.)" 7}
        tangledtunnel {695250 9679 15770 381 764 44 31 "The car's stripped for parts before dawn -- clean money. (Chop shop run at the boardwalk.)" "The VIN doesn't scrub clean and a cop runs the plate. (Chop shop run at the boardwalk.)" 7}
        deeptiger {695250 5560 13187 130 405 41 35 "The car's stripped for parts before dawn -- clean money. (Chop shop run at the boardwalk.)" "The VIN doesn't scrub clean and a cop runs the plate. (Chop shop run at the boardwalk.)" 7}
        dryace {695250 1657 9946 374 624 45 26 "Your guy walks out the front gate in a guard's uniform. (Prison break at the warehouse district.)" "The escape route is blocked and the alarm goes up. (Prison break at the warehouse district.)" 7}
        crookedace {695250 1409 9061 271 446 37 37 "The target never sees it coming. Clean, quiet, paid in full. (Assassination contract at the subway tunnels.)" "The target's crew was ready and the job turns into a shootout. (Assassination contract at the subway tunnels.)" 7}
        deepwhisper {695250 3109 11543 141 524 45 28 "The shipment crosses clean, nobody looks twice at the truck. (Smuggling run at the casino district.)" "Customs pulls the truck for a random inspection. (Smuggling run at the casino district.)" 7}
        blackecho {695250 7992 17958 310 679 37 31 "The cash comes out the other side spotless. (Money laundering op at the rail yard.)" "A bank compliance officer flags the transfers. (Money laundering op at the rail yard.)" 7}
        slowwire {695250 7469 12158 369 757 45 26 "The witness suddenly can't remember a thing. (Witness tampering at the old quarter.)" "The witness records the conversation and hands it to the DA. (Witness tampering at the old quarter.)" 7}
        tangledcontract {942375 8155 17306 475 881 42 40 "Every shop on the block pays up without a word of trouble. (Protection racket at the rail yard.)" "One owner calls it in instead of paying. (Protection racket at the rail yard.)" 8}
        frozenviper {942375 6248 17853 148 523 46 34 "You're in and out before the alarm even finishes ringing. (Smash-and-grab at the strip.)" "The display case shatters wrong and security is on you in seconds. (Smash-and-grab at the strip.)" 8}
        hollowpawn {942375 10399 20162 305 616 41 38 "You walk out with the whole client ledger on a thumb drive. (Data heist at the harbor.)" "IT security traces the breach back to your laptop. (Data heist at the harbor.)" 8}
        stolenbridge {942375 7631 15040 469 826 38 32 "The fake bills pass every register in the district. (Counterfeit run at the penthouse district.)" "A teller catches the watermark and hits the silent alarm. (Counterfeit run at the penthouse district.)" 8}
        ironrumor {942375 7682 13757 325 490 40 35 "Your guy walks out the front gate in a guard's uniform. (Prison break at the underpass.)" "The escape route is blocked and the alarm goes up. (Prison break at the underpass.)" 8}
        deepviper {942375 3001 13797 123 539 45 27 "Your crew claims the block and the old owners back off quiet. (Territory grab at the harbor.)" "The old owners fight back harder than expected. (Territory grab at the harbor.)" 8}
        deepyard {942375 3886 8694 312 594 43 36 "The family pays fast and quiet -- textbook job. (Kidnap-for-ransom at the marina.)" "The mark's bodyguards were waiting and it goes sideways. (Kidnap-for-ransom at the marina.)" 8}
        crookedecho {942375 6740 16549 234 701 49 39 "The crates move without ATF ever catching wind. (Gunrunning deal at uptown.)" "An informant tips off the feds before the handoff. (Gunrunning deal at uptown.)" 8}
        wetcellar {942375 1945 6649 192 662 48 31 "Your guy walks out the front gate in a guard's uniform. (Prison break at the subway tunnels.)" "The escape route is blocked and the alarm goes up. (Prison break at the subway tunnels.)" 8}
        frozenharbor {942375 8467 13662 461 932 49 40 "The fake bills pass every register in the district. (Counterfeit run at uptown.)" "A teller catches the watermark and hits the silent alarm. (Counterfeit run at uptown.)" 8}
        wetfox {942375 4082 12571 86 256 43 39 "The shipment crosses clean, nobody looks twice at the truck. (Smuggling run at the casino district.)" "Customs pulls the truck for a random inspection. (Smuggling run at the casino district.)" 8}
        luckytiger {942375 7230 16954 292 513 41 35 "The car's stripped for parts before dawn -- clean money. (Chop shop run at the strip.)" "The VIN doesn't scrub clean and a cop runs the plate. (Chop shop run at the strip.)" 8}
        finalking {942375 4307 10675 161 348 47 40 "The mark hands over the cash rather than see his family hurt. (Shakedown at the penthouse district.)" "The mark calls your bluff and calls the cops instead. (Shakedown at the penthouse district.)" 8}
        frozencellar {942375 5302 17038 370 590 41 34 "The crates move without ATF ever catching wind. (Gunrunning deal at the junkyard.)" "An informant tips off the feds before the handoff. (Gunrunning deal at the junkyard.)" 8}
        slowrook {942375 5540 9276 483 868 42 37 "You skim the pension fund without anyone noticing. (Union racketeering at the casino district.)" "An auditor flags the books before you can cover it. (Union racketeering at the casino district.)" 8}
        burningdebt {942375 2567 13387 248 695 42 37 "The witness suddenly can't remember a thing. (Witness tampering at the industrial park.)" "The witness records the conversation and hands it to the DA. (Witness tampering at the industrial park.)" 8}
        frozenrooftop {942375 8841 17373 173 516 45 28 "The mark hands over the cash rather than see his family hurt. (Shakedown at the rail yard.)" "The mark calls your bluff and calls the cops instead. (Shakedown at the rail yard.)" 8}
        finalfox {942375 10727 20191 366 664 49 31 "The fake bills pass every register in the district. (Counterfeit run at the underpass.)" "A teller catches the watermark and hits the silent alarm. (Counterfeit run at the underpass.)" 8}
        lastecho {942375 5854 9569 361 533 47 38 "You're in and out before the alarm even finishes ringing. (Smash-and-grab at the underpass.)" "The display case shatters wrong and security is on you in seconds. (Smash-and-grab at the underpass.)" 8}
        rustypawn {942375 5127 14482 184 656 41 36 "Your guy walks out the front gate in a guard's uniform. (Prison break at the strip.)" "The escape route is blocked and the alarm goes up. (Prison break at the strip.)" 8}
        velvetledger {1227000 11823 17453 543 1030 52 30 "You skim the pension fund without anyone noticing. (Union racketeering at the old quarter.)" "An auditor flags the books before you can cover it. (Union racketeering at the old quarter.)" 9}
        tangleddebt {1227000 2076 12092 455 688 43 34 "The target never sees it coming. Clean, quiet, paid in full. (Assassination contract at the casino district.)" "The target's crew was ready and the job turns into a shootout. (Assassination contract at the casino district.)" 9}
        lastblade {1227000 4407 11735 148 590 47 38 "The eye in the sky never catches the switch. (Casino skim at the marina.)" "Pit boss makes you as a cheat before you cash out. (Casino skim at the marina.)" 9}
        hollowblade {1227000 4225 12474 548 960 54 34 "The cash comes out the other side spotless. (Money laundering op at the rail yard.)" "A bank compliance officer flags the transfers. (Money laundering op at the rail yard.)" 9}
        midnightrumor {1227000 9203 14475 153 434 52 41 "The eye in the sky never catches the switch. (Casino skim at the warehouse district.)" "Pit boss makes you as a cheat before you cash out. (Casino skim at the warehouse district.)" 9}
        deepfox {1227000 7522 13040 485 853 42 34 "The crates move without ATF ever catching wind. (Gunrunning deal at the subway tunnels.)" "An informant tips off the feds before the handoff. (Gunrunning deal at the subway tunnels.)" 9}
        deepledger {1227000 8981 19058 425 974 52 34 "The witness suddenly can't remember a thing. (Witness tampering at the warehouse district.)" "The witness records the conversation and hands it to the DA. (Witness tampering at the warehouse district.)" 9}
        emptyshadow {1227000 11991 22116 136 647 45 37 "Your crew claims the block and the old owners back off quiet. (Territory grab at the underpass.)" "The old owners fight back harder than expected. (Territory grab at the underpass.)" 9}
        dryjoker {1227000 10728 20141 549 1027 45 40 "You're in and out before the alarm even finishes ringing. (Smash-and-grab at the junkyard.)" "The display case shatters wrong and security is on you in seconds. (Smash-and-grab at the junkyard.)" 9}
        royalpier {1227000 13016 22006 413 788 43 32 "Every shop on the block pays up without a word of trouble. (Protection racket at the casino district.)" "One owner calls it in instead of paying. (Protection racket at the casino district.)" 9}
        goldentunnel {1227000 6516 18626 140 355 45 38 "The car's stripped for parts before dawn -- clean money. (Chop shop run at the docks.)" "The VIN doesn't scrub clean and a cop runs the plate. (Chop shop run at the docks.)" 9}
        secretdocks {1227000 8962 19079 424 970 53 38 "The family pays fast and quiet -- textbook job. (Kidnap-for-ransom at the underpass.)" "The mark's bodyguards were waiting and it goes sideways. (Kidnap-for-ransom at the underpass.)" 9}
        sharphawk {1227000 13434 20004 534 912 52 31 "The mark hands over the cash rather than see his family hurt. (Shakedown at the penthouse district.)" "The mark calls your bluff and calls the cops instead. (Shakedown at the penthouse district.)" 9}
        stolensignal {1227000 8216 16838 97 616 47 33 "Your guy walks out the front gate in a guard's uniform. (Prison break at the junkyard.)" "The escape route is blocked and the alarm goes up. (Prison break at the junkyard.)" 9}
        whitewhisper {1227000 5398 15379 131 648 47 38 "The rival crew's operation goes up in smoke -- literally. (Rival sabotage at the casino district.)" "You're spotted planting the charge and have to run. (Rival sabotage at the casino district.)" 9}
        silentfavor {1227000 8053 16612 178 406 49 31 "You walk out with the whole client ledger on a thumb drive. (Data heist at the docks.)" "IT security traces the breach back to your laptop. (Data heist at the docks.)" 9}
        calmfox {1227000 1879 6746 483 819 45 32 "You take the truck at the light and vanish into the yard. (Cargo hijack at the junkyard.)" "The driver hits a silent alarm under the dash. (Cargo hijack at the junkyard.)" 9}
        midnighttunnel {1227000 2654 15773 187 653 45 43 "Your crew claims the block and the old owners back off quiet. (Territory grab at the boardwalk.)" "The old owners fight back harder than expected. (Territory grab at the boardwalk.)" 9}
        finaldebt {1227000 3947 8032 222 462 44 38 "The fake bills pass every register in the district. (Counterfeit run at the harbor.)" "A teller catches the watermark and hits the silent alarm. (Counterfeit run at the harbor.)" 9}
        finalvault {1227000 3331 7792 148 321 47 42 "You skim the pension fund without anyone noticing. (Union racketeering at the industrial park.)" "An auditor flags the books before you can cover it. (Union racketeering at the industrial park.)" 9}
        silentrook {1549125 7006 11758 268 587 46 35 "The fake bills pass every register in the district. (Counterfeit run at the penthouse district.)" "A teller catches the watermark and hits the silent alarm. (Counterfeit run at the penthouse district.)" 10}
        hollowwhisper {1549125 3564 9099 577 990 58 38 "The mark hands over the cash rather than see his family hurt. (Shakedown at the airport.)" "The mark calls your bluff and calls the cops instead. (Shakedown at the airport.)" 10}
        rustyace {1549125 3488 15387 605 902 55 33 "The cash comes out the other side spotless. (Money laundering op at the penthouse district.)" "A bank compliance officer flags the transfers. (Money laundering op at the penthouse district.)" 10}
        crookedengine {1549125 9206 14210 152 581 52 39 "The cash comes out the other side spotless. (Money laundering op at the strip.)" "A bank compliance officer flags the transfers. (Money laundering op at the strip.)" 10}
        recklessjoker {1549125 13373 25134 165 390 51 42 "The shipment crosses clean, nobody looks twice at the truck. (Smuggling run at the border crossing.)" "Customs pulls the truck for a random inspection. (Smuggling run at the border crossing.)" 10}
        slowfox {1549125 3769 12768 422 801 55 41 "The family pays fast and quiet -- textbook job. (Kidnap-for-ransom at uptown.)" "The mark's bodyguards were waiting and it goes sideways. (Kidnap-for-ransom at uptown.)" 10}
        secretblade {1549125 9984 24397 530 764 58 44 "The target never sees it coming. Clean, quiet, paid in full. (Assassination contract at the casino district.)" "The target's crew was ready and the job turns into a shootout. (Assassination contract at the casino district.)" 10}
        ironecho {1549125 13512 21528 530 945 49 39 "The shipment crosses clean, nobody looks twice at the truck. (Smuggling run at the subway tunnels.)" "Customs pulls the truck for a random inspection. (Smuggling run at the subway tunnels.)" 10}
        sharpfox {1549125 8234 19543 187 531 52 38 "The eye in the sky never catches the switch. (Casino skim at the casino district.)" "Pit boss makes you as a cheat before you cash out. (Casino skim at the casino district.)" 10}
        papershadow {1549125 4202 16466 158 388 47 34 "You skim the pension fund without anyone noticing. (Union racketeering at the north side.)" "An auditor flags the books before you can cover it. (Union racketeering at the north side.)" 10}
        whitequeen {1549125 13901 24500 223 691 46 42 "The mark hands over the cash rather than see his family hurt. (Shakedown at the warehouse district.)" "The mark calls your bluff and calls the cops instead. (Shakedown at the warehouse district.)" 10}
        blackdice {1549125 7102 13598 510 875 56 45 "The witness suddenly can't remember a thing. (Witness tampering at the subway tunnels.)" "The witness records the conversation and hands it to the DA. (Witness tampering at the subway tunnels.)" 10}
        silentharbor {1549125 6414 20745 409 773 47 42 "The mark hands over the cash rather than see his family hurt. (Shakedown at the docks.)" "The mark calls your bluff and calls the cops instead. (Shakedown at the docks.)" 10}
        emptyviper {1549125 4237 16631 319 558 51 46 "The cash comes out the other side spotless. (Money laundering op at the boardwalk.)" "A bank compliance officer flags the transfers. (Money laundering op at the boardwalk.)" 10}
        midnightpier {1549125 3584 12642 321 918 52 46 "The witness suddenly can't remember a thing. (Witness tampering at the north side.)" "The witness records the conversation and hands it to the DA. (Witness tampering at the north side.)" 10}
        stolenrumor {1549125 11754 25369 116 611 56 46 "The witness suddenly can't remember a thing. (Witness tampering at the junkyard.)" "The witness records the conversation and hands it to the DA. (Witness tampering at the junkyard.)" 10}
        quietace {1549125 4657 13628 406 763 51 33 "You skim the pension fund without anyone noticing. (Union racketeering at downtown.)" "An auditor flags the books before you can cover it. (Union racketeering at downtown.)" 10}
        whiterumor {1549125 10980 22040 161 417 57 43 "The building goes up clean, insurance money guaranteed. (Arson job at the old quarter.)" "A fire marshal spots accelerant before you're even off the block. (Arson job at the old quarter.)" 10}
        opencrown {1549125 13926 27111 310 686 52 40 "You're in and out before the alarm even finishes ringing. (Smash-and-grab at uptown.)" "The display case shatters wrong and security is on you in seconds. (Smash-and-grab at uptown.)" 10}
        rustywire {1549125 7764 17363 422 1003 55 42 "The eye in the sky never catches the switch. (Casino skim at the industrial park.)" "Pit boss makes you as a cheat before you cash out. (Casino skim at the industrial park.)" 10}
    }

    ##### ---------------- DRUGS ---------------- #####
    # drug -> {base_price volatility}
    variable drugs
    array set drugs {
        weed    {50   20}
        coke    {200  60}
        meth    {120  50}
        heroin  {350  100}
        pills   {30   15}
    }
    variable drug_price_arr    ;# array: drug_price_arr(name) -> current price (live lookups)
    array set drug_price_arr {}

    ##### ---------------- PIMP MARKET ---------------- #####
    # Fictional adult NPC workers; this is an in-game economy only.
    # tier -> {base_cost volatility payout_per_15m bust_chance jail_minutes}
    variable pimp_workers
    array set pimp_workers {
        celebrity     {100000 30 12000  1 20}
        escort         {50000 25  6000  1 18}
        hooker         {15000 25  1800  1 15}
        street_corner  {5000  30   600  1 12}
        crack_ho       {2000  35   300  1 10}
        financier      {150000 0  9000  0  0}
        silent_partner {350000 0 25000  0  0}

        strategist      {750000 0 10000 0 0}
        enforcer        {1250000 0 12000 0 0}
        accountant      {1750000 0 14000 0 0}
        fixer           {2500000 0 16000 0 0}
        kingmaker       {5000000 0 22000 0 0}
    }
    # Display order for !mafia pimp prices/workers/collect. The two special
    # tiers (financier, silent_partner) are legitimate/laundered operations
    # with 0% bust_chance -- they NEVER get busted or thrown in pimp jail,
    # unlike every street-level tier above them. silent_partner's payout is
    # roughly double celebrity's, at a steeper buy-in, for players who'd
    # rather pay up front for guaranteed, risk-free income than gamble on
    # bust chance with the cheaper tiers.
    variable pimp_worker_order {celebrity escort hooker street_corner crack_ho financier silent_partner strategist enforcer accountant fixer kingmaker}
    variable pimp_special_workers {financier silent_partner strategist enforcer accountant fixer kingmaker}
    variable pimp_price_arr
    array set pimp_price_arr {}
    # See blackmarket_timer_id above: don't clobber a live timer id on rehash.
    variable pimp_market_timer_id
    if {![info exists pimp_market_timer_id]} { set pimp_market_timer_id "" }
    variable pimp_cycle_secs 900

    ##### ---------------- CASINO OPERATIONS ---------------- #####
    # Passive-income gambling houses, run the same buy-then-collect way as
    # the pimp market: !mafia gamble buy <tier> [qty], !mafia gamble collect.
    # The old !mafia gamble <amount> <dice|slots|cards> quick-bet game above
    # still works unchanged for players who prefer a straight wager.
    # tier -> {base_cost payout_per_cycle}
    # Casino floors are never raided -- unlike pimping or dealing, running a
    # casino carries zero bust chance. (Intentional; not called out in the
    # help text.)
    variable casino_tiers
    array set casino_tiers {
        card_table        {50000    5000}
        roulette_wheel     {150000   14000}
        slot_hall          {400000   32000}
        high_roller_room   {1000000  75000}
        private_casino     {2500000  170000}
    }
    variable casino_tier_order {card_table roulette_wheel slot_hall high_roller_room private_casino}
    variable casino_cycle_secs 900          ;# seconds per payout cycle
    # casino_collect_cooldown is set in Mafia.cfg (it is an admin_config_keys
    # tunable, so it must not be re-declared here -- this file is evaluated
    # AFTER the .cfg is sourced, and a "variable NAME value" line down here
    # silently overwrites whatever the operator put in the .cfg).

    ##### ---------------- DRUG DEALER OPERATIONS ---------------- #####
    # Passive-income distribution network: buy dealers (!mafia drug dealer
    # buy <tier> [qty]), stock them with product (!mafia drug supply <tier>
    # <qty>, priced off the live street market), then collect on a timer
    # (!mafia drug collect), same shape as the pimp market. A dealer with no
    # supply in stock earns nothing on collect. Dealers can get busted like
    # pimp workers and sit in dealer jail until release.
    # tier -> {base_cost capacity_per_cycle payout_per_unit bust_chance jail_minutes supply_cost_per_unit}
    variable dealer_tiers
    array set dealer_tiers {
        corner_boy      {8000    20   140   3 12 60}
        block_captain   {25000   50   120   2 15 55}
        distributor     {75000   150  100   1 20 50}
        cartel_broker    {200000  400  85    1 25 45}
    }
    variable dealer_tier_order {corner_boy block_captain distributor cartel_broker}
    variable dealer_cycle_secs 900          ;# seconds per supply-consumption cycle
    # dealer_collect_cooldown and dealer_refund_pct are set in Mafia.cfg --
    # see the note on casino_collect_cooldown above.

    ##### ---------------- STATE ---------------- #####
    variable players            ;# array: players(nick,field) -> value
    variable game_gen 0          ;# incrementing generation counter to invalidate stale timers
    # Unlike db_shadow below, this was being unconditionally reset with a bare
    # `array set players {}` -- on a live bot that wipes every in-memory
    # player field (cash, cooldowns, jail/hospital state, etc.) back to empty
    # on every .rehash until save_db/load_db repopulates it, which is a race
    # any player action during that window can lose. Guard it exactly like
    # db_shadow so rehash only initializes it the first time the script loads.
    if {![info exists players]} { array set players {} }
    # Mirrors exactly what is currently on disk in player_data, keyed the
    # same way as players() (nick,field). Populated from the real rows at
    # load and kept in sync by save_db, so a save only has to write the
    # handful of fields that actually changed instead of deleting and
    # reinserting the whole table -- see save_db for why that matters.
    if {![info exists db_shadow]} { array set db_shadow {} }

}
# mafia_util.tcl - low-level helpers: player init/lookup, level/xp math,
# skill stats, formatting, jail/hospital/hide checks, weapon/armor/bling
# lookups, economy normalization, gear-ownership helpers.
namespace eval mafia {
    ##### =====================================================
    #####                 UTILITY HELPERS
    ##### =====================================================

    proc exists_player {nick} {
        variable players
        set k [string tolower $nick]
        return [info exists players($k,cash)]
    }

    proc new_player {nick} {
        variable players
        variable start_cash
        variable max_health
        set k [string tolower $nick]
        set players($k,name)       $nick
        set players($k,cash)       $start_cash
        set players($k,bank)       0
        set players($k,xp)         0
        set players($k,health)     $max_health
        set players($k,weapon)     fists
        set players($k,armor)      none
        set players($k,jail_until) 0
        set players($k,hosp_until) 0
        set players($k,hide_until) 0
        set players($k,last_crime) 0
        set players($k,last_attack) 0
        set players($k,last_pvp_reaction) 0
        set players($k,last_rob)    0
        set players($k,last_deal)  0
        set players($k,last_street) 0
        set players($k,last_npc)    0
        set players($k,last_hit)    0
        set players($k,last_stealth) 0
        set players($k,last_wiretap) 0
        set players($k,last_boss)   0
        set players($k,boss_tier_cleared) 0
        set players($k,last_seen)   [now]
        set players($k,last_chan)   ""
        set players($k,jail_notified) 0
        set players($k,kills)      0
        set players($k,deaths)     0
        set players($k,items)      [list]
        set players($k,owned_weapons) [list fists]
        set players($k,owned_armor)   [list none]
        set players($k,stat_pickpocket) 10
        set players($k,stat_dexterity)  10
        set players($k,stat_accuracy)   10
        set players($k,stat_stealth)    10
        foreach d [array names ::mafia::drugs] {
            set players($k,drug,$d) 0
        }
        foreach t [array names ::mafia::pimp_workers] {
            set players($k,pimp,$t) 0
            set players($k,pimp_jail,$t) 0
            set players($k,pimp_jail_until,$t) 0
            set players($k,pimp_last,$t) [now]
        }
    }

    # Reads a player field, memoizing the default into the array so repeat
    # reads are cheap. That memoizing write is the reason a dozen call sites
    # in this script carry "non-creating read" comments and hand-rolled
    # [info exists] probes: asking getf about a field the player never had
    # CREATES it, and save_db then writes it to SQLite forever.
    #
    # The unbounded half of that is fixed here rather than at every caller:
    # a nick with no ",cash" row is not a player, so seeding fields under it
    # manufactures a phantom account that no sweep can ever collect --
    # exists_player stays false, so prune/cleanup/leaderboards all skip it
    # while save_db faithfully persists its rows on every command. One
    # mistyped nick reaching any getf path was enough to leak a row set
    # permanently. Registered players keep the original memoizing behavior,
    # so nothing else about the hot path changes.
    #
    # meta_key is deliberately allowed through: it is the bot-wide pseudo
    # player (last_auto_cleanup) and legitimately has no cash row.
    proc getf {nick field {default 0}} {
        variable players
        variable meta_key
        set k [string tolower $nick]
        if {[info exists players($k,$field)]} { return $players($k,$field) }
        if {[info exists players($k,cash)] || $k eq $meta_key} {
            set players($k,$field) $default
        }
        return $default
    }

    # Non-creating counterpart to getf: returns the stored value if there is
    # one and the default otherwise, WITHOUT writing the default back into the
    # player array.
    #
    # A dozen call sites in this script carry hand-rolled [info exists] probes
    # and a "non-creating read" comment for exactly this reason; the dealer and
    # casino systems were added later and never got them, so every
    # display/sweep loop over those two catalogs seeded a zero row per tier.
    # Measured against the live save: loading the bot and typing nothing but
    # `!mafia dealer` and `!mafia gamble status` -- two read-only commands --
    # permanently added 21 rows (5 casino, 4 dealer, 4 dealer_jail,
    # 4 dealer_jail_until, 4 dealer_supply) and save_db then wrote them to
    # SQLite on every command afterwards, forever. Neither
    # normalize_player_economy (which deliberately refuses to create them) nor
    # prune_retired_fields (the keys are valid catalog keys, just empty) can
    # collect them, so they only ever accumulate. Use this in any read path
    # whose default means "the player has none of these".
    proc peekf {nick field {default 0}} {
        variable players
        set k [string tolower $nick]
        if {[info exists players($k,$field)]} { return $players($k,$field) }
        return $default
    }

    # Clamp a configurable interval/delay before it is used as a utimer delay
    # or as a divisor. Mafia.cfg is hand-edited and is NOT filtered by
    # cmd_admin_config's range checks, so a 0 (or a typo, or a deleted line)
    # reaches these sites directly. A zero-delay self-rescheduling utimer is a
    # runaway loop that pins the bot's event loop, and a zero divisor turns
    # every collect/fence command into an uncaught Tcl error -- which the
    # dispatcher answers with a full rollback and "that action failed
    # cleanly", for every player, forever.
    proc cfg_interval {value default {minimum 1}} {
        if {![string is integer -strict $value] || $value < $minimum} {
            if {![string is integer -strict $default] || $default < $minimum} {
                return $minimum
            }
            return $default
        }
        return $value
    }

    # Single source of truth for dynamic player HP caps. This avoids commands
    # accidentally using the old global 100-HP baseline after level scaling.
    proc player_max_health {nick} {
        variable max_health
        set v [getf $nick health_max $max_health]
        if {![string is integer -strict $v] || $v < $max_health} {
            set v $max_health
        }
        return $v
    }

    proc touch {nick chan} {
        variable players
        set k [string tolower $nick]
        if {![exists_player $nick]} { return }
        normalize_player_economy $nick
        set players($k,last_seen) [now]
        set players($k,last_chan) $chan
        if {![in_hospital $nick] && ![in_jail $nick]} {
            maybe_random_encounter $nick $chan
        }
    }

    proc rank_for_xp {xp} {
        variable ranks
        set best "Street Punk"
        foreach {thresh title} $ranks {
            if {$xp >= $thresh} { set best $title }
        }
        return $best
    }

    proc build_level_thresholds {} {
        variable level_thresholds
        variable max_level
        set thresholds [list 0]
        set cum 0
        for {set l 1} {$l < $max_level} {incr l} {
            incr cum [expr {60 + $l*15}]
            lappend thresholds $cum
        }
        set level_thresholds $thresholds
    }

    proc xp_for_level {lvl} {
        if {$lvl <= 1} { return 0 }
        set n [expr {$lvl-1}]
        return [expr {60*$n + (15*$n*($n+1))/2}]
    }

    proc level_for_xp {xp} {
        variable level_thresholds
        if {![string is integer -strict $xp] || $xp < 0} { set xp 0 }
        set last [lindex $level_thresholds end]
        if {$xp <= $last} {
            set lo 1
            set hi [llength $level_thresholds]
            while {$lo < $hi} {
                set mid [expr {($lo+$hi+1)/2}]
                if {[lindex $level_thresholds [expr {$mid-1}]] <= $xp} {
                    set lo $mid
                } else {
                    set hi [expr {$mid-1}]
                }
            }
            return $lo
        }
        set disc [expr {4556.25 + 30.0*$xp}]
        set n [expr {int(floor((-67.5 + sqrt($disc))/15.0))}]
        if {$n < 0} { set n 0 }
        while {[xp_for_level [expr {$n+2}]] <= $xp} { incr n }
        while {$n > 0 && [xp_for_level [expr {$n+1}]] > $xp} { incr n -1 }
        return [expr {$n+1}]
    }

    proc player_level {nick} {
        variable players
        set k [string tolower $nick]
        if {![info exists players($k,xp)]} { return 1 }
        # Level is driven purely by XP now. Boss-tier progress no longer caps
        # it -- a player can be Lv.1158 while still stuck on Tier 16, exactly
        # as it worked for the uncapped Lv1-500 climb. Tier gating (which
        # boss you're allowed to challenge) is enforced separately in
        # cmd_boss via level_for_xp/boss_tier_cleared, not here.
        return [level_for_xp $players($k,xp)]
    }

    proc xp_to_next_level {xp} {
        # max_level bounds the stat curve (see stat_target_for_level), not the
        # player's actual level progression -- XP/leveling is unbounded above
        # Lv1000 (Lv1001, Lv1002, ...), so this must never early-return 0 just
        # because the player has reached max_level.
        set lvl [level_for_xp $xp]
        return [expr {[xp_for_level [expr {$lvl+1}]] - $xp}]
    }

    ##### =====================================================
    #####                 SKILL STATS (0-100%)
    ##### =====================================================
    # pickpocket, dexterity, accuracy, stealth all start at 10% and climb
    # toward a 100% cap as the player levels, spread across all 500 levels
    # so the climb is gradual rather than front-loaded. Stats only ever
    # rise -- sync_level_stats is safe to call after any xp change.

    proc stat_target_for_level {lvl} {
        variable max_level
        if {$lvl <= 1} { return 10 }
        if {$lvl <= $max_level} { return [expr {int(10 + (90.0 * ($lvl - 1)) / ($max_level - 1))}] }
        return [expr {100 + ($lvl - $max_level)}]
    }

    proc sync_level_stats {nick} {
        variable players
        set k [string tolower $nick]
        if {![exists_player $nick]} { return }
        set lvl [player_level $nick]
        # Player max HP increases by 50 every 100 levels through Lv.500
        # (Lv1-99=100, Lv100-199=150, ..., Lv500=350) -- unchanged, this
        # half of the curve was never the problem.
        #
        # Past Lv.500 a new boss tier unlocks every 50 levels (Tier 11-20),
        # and boss weapon/armor now climbs much faster tier-to-tier than
        # the old +50-per-100-levels HP curve did. Past Lv.500, HP instead
        # grows +40 every 50 levels so the pool keeps pace with a new boss
        # tier appearing, rather than only ticking up once per 100 levels
        # while two tiers' worth of boss gear escalation goes by. This is
        # what actually made Tier 11+ feel unwinnable even in full
        # current-tier-appropriate gear: HP wasn't the part compensating.
        if {$lvl <= 500} {
            set hpmax [expr {100 + 50*int($lvl/100)}]
        } else {
            set hpmax [expr {350 + 40*int(($lvl-500)/50)}]
        }
        set oldmax [getf $nick health_max 100]
        if {$hpmax > $oldmax} {
            set players($k,health) [expr {[getf $nick health $oldmax] + ($hpmax-$oldmax)}]
        }
        set players($k,health_max) $hpmax
        if {[getf $nick health $hpmax] > $hpmax} { set players($k,health) $hpmax }
        set target [stat_target_for_level $lvl]
        foreach stat {pickpocket dexterity accuracy stealth} {
            set cur [getf $nick stat_$stat 10]
            if {$target > $cur} { set players($k,stat_$stat) $target }
        }
    }

    proc get_stat {nick stat} {
        # stat is one of: pickpocket dexterity accuracy stealth
        set v [expr {[getf $nick stat_$stat 10] + [boss_bonus_pct $nick stat_$stat]}]
        # The legendary set bonus is a flat percentage on all four core stats
        # and stacks with ice and pimp specialists, same as they stack with
        # each other. It is driven by pieces COLLECTED, not equipped, so the
        # tool (which has no slot) counts toward it too.
        set pct [expr {[player_bling_pct $nick] + [pimp_bonus_pct $nick stats] + [legend_stat_pct $nick]}]
        if {$pct > 0} {
            set v [expr {$v * (1.0 + ($pct/100.0))}]
        }
        set v [expr {int(round($v))}]
        if {$v < 0}   { set v 0 }
        return $v
    }

    proc dodge_roll {nick} {
        # dexterity: chance to fully avoid an incoming hit, capped at 50%.
        set dex [get_stat $nick dexterity]
        set chance [expr {($dex + [boss_bonus_pct $nick dodge]) / 2.0}]
        if {$chance > 50} { set chance 50 }
        return [expr {int(rand()*100) < $chance}]
    }

    proc stealth_ambush_mult {nick} {
        # stealth: scales the surprise-attack power multiplier.
        set st [get_stat $nick stealth]
        return [expr {1.15 + ($st / 100.0) * 0.6}]
    }

    # Under 1,000,000: plain "$<amount>". At or above one million, or one
    # billion, abbreviate to one decimal digit -- "$544.1m", "$1.8b" -- and
    # always truncate (floor) that digit rather than rounding to nearest, so
    # the displayed figure never overstates what the player actually has
    # (e.g. 544161142 -> "$544.1m", never "$544.2m").
    proc fmt_cash {amt} {
        if {![string is integer -strict $amt]} { set amt [expr {int($amt)}] }
        set neg [expr {$amt < 0}]
        set mag [expr {$neg ? -$amt : $amt}]
        if {$mag >= 1000000000} {
            set whole [expr {$mag / 1000000000}]
            set tenth [expr {($mag / 100000000) % 10}]
            set out "\$${whole}.${tenth}b"
        } elseif {$mag >= 1000000} {
            set whole [expr {$mag / 1000000}]
            set tenth [expr {($mag / 100000) % 10}]
            set out "\$${whole}.${tenth}m"
        } else {
            set out "\$[format %d $mag]"
        }
        return [expr {$neg ? "-$out" : $out}]
    }

    proc now {} { return [clock seconds] }

    proc time_left {ts} {
        set diff [expr {$ts - [now]}]
        if {$diff <= 0} { return 0 }
        return $diff
    }

    proc fmt_secs {s} {
        if {$s < 60} { return "${s}s" }
        set m [expr {$s / 60}]
        set r [expr {$s % 60}]
        return "${m}m ${r}s"
    }

    # Non-throwing reads, for the same reason has_item is one: these three are
    # asked about OTHER players (cmd_stats/cmd_attack/cmd_headshot/cmd_rob all
    # test the target, whose row nothing normalizes), and a raw
    # $players($k,jail_until) on a row that predates the field -- or any
    # partially written row -- made those commands die with "no such element in
    # array", which the dispatcher reports as a failed transaction and rolls
    # back. Absent means "not jailed / not hospitalized / not hiding", which is
    # what every caller already means by a false return. A non-integer stamp is
    # treated the same way rather than thrown at time_left's arithmetic;
    # normalize_player_economy repairs it on that player's next command.
    proc timed_state_left {nick field} {
        variable players
        set k [string tolower $nick]
        if {![info exists players($k,$field)]} { return 0 }
        set v $players($k,$field)
        if {![string is integer -strict $v] || $v <= 0} { return 0 }
        return [time_left $v]
    }

    proc in_jail {nick} {
        return [expr {[timed_state_left $nick jail_until] > 0}]
    }

    proc in_hospital {nick} {
        return [expr {[timed_state_left $nick hosp_until] > 0}]
    }

    proc is_hidden {nick} {
        return [expr {[timed_state_left $nick hide_until] > 0}]
    }

    # Boss-exclusive gear (boss_weapons/boss_armor, see mafia_core.tcl)
    # lives outside shop_weapons/shop_armor on purpose so it never shows
    # up in the shop, can't be bought, and can't be sold back. These two
    # helpers are the single place that treats "valid gear" as "shop OR
    # boss table" -- use them (not a raw [info exists shop_weapons(...)])
    # anywhere ownership/equip validity is checked, so boss loot doesn't
    # get silently stripped as "unknown gear".
    # Reduces a display name or typed argument string to a bare
    # alphanumeric run (lowercase, no spaces/underscores/punctuation), so
    # "Syndicate Crown Ice", "syndicate_ice2"'s display, and a user typing
    # "syndicate crown ice" all normalize to the same "syndicatecrownice"
    # string regardless of how the words are separated.
    proc normalize_item_text {text} {
        return [regsub -all {[^a-z0-9]} [string tolower $text] ""]
    }

    # Maps every known item's normalized DISPLAY name back to its internal
    # key, across all eight item tables (shop + boss weapons/armor/bling,
    # shop tools). Built fresh each call -- the tables are small and this is
    # only invoked from item-resolving commands, not hot loops.
    proc item_display_name_index {} {
        variable shop_weapons
        variable shop_armor
        variable shop_tools
        variable shop_bling
        variable boss_weapons
        variable boss_armor
        variable boss_bling
        array set idx {}
        foreach key [array names shop_weapons] {
            set norm [normalize_item_text [lindex $shop_weapons($key) 0]]
            if {$norm ne ""} { set idx($norm) $key }
        }
        foreach key [array names shop_armor] {
            set norm [normalize_item_text [lindex $shop_armor($key) 0]]
            if {$norm ne ""} { set idx($norm) $key }
        }
        foreach key [array names shop_tools] {
            set norm [normalize_item_text [lindex $shop_tools($key) 0]]
            if {$norm ne ""} { set idx($norm) $key }
        }
        foreach key [array names shop_bling] {
            set norm [normalize_item_text [lindex $shop_bling($key) 0]]
            if {$norm ne ""} { set idx($norm) $key }
        }
        foreach key [array names boss_weapons] {
            set norm [normalize_item_text [lindex $boss_weapons($key) 0]]
            if {$norm ne ""} { set idx($norm) $key }
        }
        foreach key [array names boss_armor] {
            set norm [normalize_item_text [lindex $boss_armor($key) 0]]
            if {$norm ne ""} { set idx($norm) $key }
        }
        foreach key [array names boss_bling] {
            set norm [normalize_item_text [lindex $boss_bling($key) 0]]
            if {$norm ne ""} { set idx($norm) $key }
        }
        # Legendary pieces resolve by display name too, so "!mafia equip
        # eclipse syndicate plate" works exactly like the boss gear does.
        variable legend_items
        foreach key [array names legend_items] {
            set norm [normalize_item_text [lindex $legend_items($key) 1]]
            if {$norm ne ""} { set idx($norm) $key }
        }
        return [array get idx]
    }

    # Item names are stored with underscores (kingpin_ice) but users type
    # them with spaces (kingpin ice). The internal key does not always
    # match the display name word-for-word once punctuation, tier suffixes,
    # or reordered words are involved (key syndicate_ice2 displays as
    # "Syndicate Crown Ice"; key baron_cannon displays as "Crime Baron
    # Cannon"; key blackice has no underscore at all). So resolution tries,
    # in order: (1) the typed text matched against every known item's
    # display name, ignoring spaces/underscores/case -- this is what makes
    # those irregular items resolve; (2) the old space-joined-as-underscore
    # heuristic, for keys that do match their words directly; (3) just the
    # first word, for single-word item names. Given the raw arg list, so
    # both "!mafia equip kingpin ice" and "!mafia equip fists" resolve.
    proc resolve_item_key {argl} {
        set argl [string tolower $argl]
        if {[llength $argl] < 1} { return "" }
        set typed_norm [normalize_item_text [join $argl ""]]
        if {$typed_norm ne ""} {
            array set name_idx [item_display_name_index]
            if {[info exists name_idx($typed_norm)]} { return $name_idx($typed_norm) }
        }
        set joined [join $argl "_"]
        if {[known_item_key $joined]} { return $joined }
        set first [lindex $argl 0]
        if {[known_item_key $first]} { return $first }
        # Nothing matched exactly; return the joined form so downstream
        # "no such item" messages still show something sensible.
        return $joined
    }

    proc known_item_key {key} {
        variable shop_weapons
        variable shop_armor
        variable shop_tools
        variable shop_bling
        variable boss_weapons
        variable boss_armor
        variable boss_bling
        return [expr {
            [info exists shop_weapons($key)] || [info exists shop_armor($key)] ||
            [info exists shop_tools($key)]   || [info exists shop_bling($key)] ||
            [info exists boss_weapons($key)] || [info exists boss_armor($key)] ||
            [info exists boss_bling($key)]   || [is_legend_item $key]
        }]
    }

    ##### =====================================================
    #####                 LEGENDARY SET HELPERS
    ##### =====================================================
    # See the legend_items block in mafia_core.tcl for the design notes. These
    # helpers are the single place that knows a legendary key's stats are
    # per-player rather than per-item, so every lookup below (weapon_dmg,
    # armor_reduce, armor_evasion, bling_bonus_pct, bling_econ_pct) just
    # forwards to them when it sees a legendary key.

    proc is_legend_item {item} {
        variable legend_items
        return [info exists legend_items($item)]
    }

    proc legend_kind {item} {
        variable legend_items
        if {![info exists legend_items($item)]} { return "" }
        return [lindex $legend_items($item) 0]
    }

    proc legend_name {item} {
        variable legend_items
        if {![info exists legend_items($item)]} { return "Unknown Relic" }
        return [lindex $legend_items($item) 1]
    }

    # Which boss tier a legendary piece mirrors for this player: the last
    # boss tier they have actually CLEARED (boss_tier_cleared), not their
    # raw level bracket. This makes the bonus permanent within a tier --
    # leveling up alone no longer changes a legendary piece's stats, only
    # beating the next tier's boss does, at which point every legendary
    # piece the player holds steps up to 30% above THAT boss's gear and
    # stays there until the tier after. A player who has cleared nothing
    # yet (boss_tier_cleared 0) still gets tier-1 stats, matching the game's
    # own floor rather than a legendary piece worth nothing. An empty nick
    # (a display/comparison with no player context) falls back to the top
    # tier, which is the safest direction -- it can never understate a
    # legendary piece and make something else look like an upgrade over it.
    proc legend_tier {{nick ""}} {
        if {$nick eq ""} { return 20 }
        set cleared [getf $nick boss_tier_cleared 0]
        if {![string is integer -strict $cleared]} { set cleared 0 }
        set t [expr {$cleared < 1 ? 1 : $cleared}]
        if {$t > 20} { return 20 }
        return $t
    }

    proc legend_weapon_dmg {{nick ""}} {
        variable boss_weapons
        variable boss_weapon_order
        variable legend_mult
        set key [lindex $boss_weapon_order [expr {[legend_tier $nick]-1}]]
        if {![info exists boss_weapons($key)]} { return 5 }
        return [expr {int(ceil([lindex $boss_weapons($key) 1]*$legend_mult))}]
    }

    proc legend_armor_reduce {{nick ""}} {
        variable boss_armor
        variable boss_armor_order
        variable legend_mult
        set key [lindex $boss_armor_order [expr {[legend_tier $nick]-1}]]
        if {![info exists boss_armor($key)]} { return 0 }
        return [expr {int(ceil([lindex $boss_armor($key) 1]*$legend_mult))}]
    }

    proc legend_armor_evasion {{nick ""}} {
        # Evasion is hard-capped at 40 for every armor in the game (see
        # armor_evasion), so the legendary plate cannot exceed it either --
        # it simply reaches the cap earlier than boss armor does.
        variable boss_armor
        variable boss_armor_order
        set key [lindex $boss_armor_order [expr {[legend_tier $nick]-1}]]
        if {![info exists boss_armor($key)]} { return 0 }
        set pct [lindex $boss_armor($key) 2]
        if {![string is integer -strict $pct]} { return 0 }
        incr pct 3
        if {$pct < 0}  { return 0 }
        if {$pct > 40} { return 40 }
        return $pct
    }

    proc legend_bling_bonus_pct {{nick ""}} {
        variable boss_bling
        variable boss_bling_order
        variable legend_mult
        set key [lindex $boss_bling_order [expr {[legend_tier $nick]-1}]]
        if {![info exists boss_bling($key)]} { return 0.0 }
        # Rounded to two decimals: this value is summed into player_bling_pct
        # and printed straight into !mafia stats/inventory, and an unrounded
        # 55*1.15 lands on 63.249999999999996 in IEEE doubles.
        return [expr {round([lindex $boss_bling($key) 1]*$legend_mult*100.0)/100.0}]
    }

    proc legend_bling_econ_pct {{nick ""}} {
        variable boss_bling
        variable boss_bling_order
        variable legend_mult
        set key [lindex $boss_bling_order [expr {[legend_tier $nick]-1}]]
        if {![info exists boss_bling($key)]} { return 0 }
        return [expr {int(round([lindex $boss_bling($key) 2]*$legend_mult))}]
    }

    # How many of the four pieces this player has COLLECTED. Deliberately a
    # non-creating read (see boss_bonus_pct): this runs on every stat lookup,
    # so seeding four zero rows per player here would put them straight back
    # into the database on every command.
    proc legend_pieces_owned {nick} {
        variable players
        variable legend_order
        set k [string tolower $nick]
        set n 0
        foreach item $legend_order {
            if {[info exists players($k,legend_$item)] &&
                [string is integer -strict $players($k,legend_$item)] &&
                $players($k,legend_$item)} { incr n }
        }
        return $n
    }

    # Percentage added to all four core stats for holding part of the set.
    proc legend_stat_pct {nick} {
        variable legend_stat_pct_by_count
        set n [legend_pieces_owned $nick]
        if {$n < 1} { return 0 }
        if {$n > [llength $legend_stat_pct_by_count]} { set n [llength $legend_stat_pct_by_count] }
        return [lindex $legend_stat_pct_by_count [expr {$n-1}]]
    }

    # Percentage added to pimp/casino/dealer collection payouts.
    proc legend_collect_pct {nick} {
        variable legend_collect_pct_by_count
        set n [legend_pieces_owned $nick]
        if {$n < 1} { return 0 }
        if {$n > [llength $legend_collect_pct_by_count]} { set n [llength $legend_collect_pct_by_count] }
        return [lindex $legend_collect_pct_by_count [expr {$n-1}]]
    }

    proc legend_collect_mult {nick} {
        return [expr {1.0 + ([legend_collect_pct $nick]/100.0)}]
    }

    proc is_valid_weapon_key {key} {
        variable shop_weapons
        variable boss_weapons
        return [expr {[info exists shop_weapons($key)] || [info exists boss_weapons($key)] ||
                      [legend_kind $key] eq "weapon"}]
    }

    proc is_valid_armor_key {key} {
        variable shop_armor
        variable boss_armor
        return [expr {[info exists shop_armor($key)] || [info exists boss_armor($key)] ||
                      [legend_kind $key] eq "armor"}]
    }

    proc is_valid_bling_key {key} {
        variable shop_bling
        variable boss_bling
        return [expr {[info exists shop_bling($key)] || [info exists boss_bling($key)] ||
                      [legend_kind $key] eq "bling"}]
    }

    # $nick is optional throughout: it is only consulted for LEGENDARY keys,
    # whose stats scale with the holder's level. Pass it wherever the item
    # being measured belongs to a specific player (their own loadout, or a
    # PvP target's armor); omit it for catalog/shop displays.
    proc weapon_dmg {key {nick ""}} {
        variable shop_weapons
        variable boss_weapons
        if {[info exists shop_weapons($key)]} { return [lindex $shop_weapons($key) 2] }
        if {[info exists boss_weapons($key)]} { return [lindex $boss_weapons($key) 1] }
        if {[legend_kind $key] eq "weapon"} { return [legend_weapon_dmg $nick] }
        return 5
    }

    proc armor_reduce {key {nick ""}} {
        variable shop_armor
        variable boss_armor
        if {[info exists shop_armor($key)]} { return [lindex $shop_armor($key) 2] }
        if {[info exists boss_armor($key)]} { return [lindex $boss_armor($key) 1] }
        if {[legend_kind $key] eq "armor"} { return [legend_armor_reduce $nick] }
        return 0
    }

    proc armor_evasion {key {nick ""}} {
        # Evasion is an armor property only. Dexterity, weapons, tools, bling,
        # and boss bonuses do not modify this percentage. 0% is reserved for
        # no armor; the weakest real armor starts at 5% and the strongest
        # armor tops out at 40%.
        variable shop_armor
        variable boss_armor
        set key [string tolower $key]
        if {[info exists shop_armor($key)]} {
            set pct [lindex $shop_armor($key) 3]
        } elseif {[info exists boss_armor($key)]} {
            set pct [lindex $boss_armor($key) 2]
        } elseif {[legend_kind $key] eq "armor"} {
            return [legend_armor_evasion $nick]
        } else {
            return 0
        }
        if {![string is integer -strict $pct]} { return 0 }
        if {$pct < 0} { return 0 }
        if {$pct > 40} { return 40 }
        return $pct
    }

    proc armor_evasion_roll {nick} {
        # Roll the equipped armor's evasion on every incoming attack. This is
        # deliberately separate from pvp_reaction's 20-second reactive
        # cooldown, so a 40% armor stat actually remains a 40% per-hit chance.
        variable players
        set k [string tolower $nick]
        if {![info exists players($k,armor)]} { return 0 }
        set pct [armor_evasion $players($k,armor) $nick]
        return [expr {$pct > 0 && int(rand()*100) < $pct}]
    }

    # Safe display-name lookups -- never crash on a corrupted/unknown
    # weapon or armor key, just fall back to a placeholder.
    proc weapon_name {key} {
        variable shop_weapons
        variable boss_weapons
        if {[info exists shop_weapons($key)]} { return [lindex $shop_weapons($key) 0] }
        if {[info exists boss_weapons($key)]} { return [lindex $boss_weapons($key) 0] }
        if {[legend_kind $key] eq "weapon"} { return [legend_name $key] }
        return "Unknown Weapon"
    }

    proc armor_name {key} {
        variable shop_armor
        variable boss_armor
        if {[info exists shop_armor($key)]} { return [lindex $shop_armor($key) 0] }
        if {[info exists boss_armor($key)]} { return [lindex $boss_armor($key) 0] }
        if {[legend_kind $key] eq "armor"} { return [legend_name $key] }
        return "Unknown Armor"
    }

    proc bling_name {key} {
        variable shop_bling
        variable boss_bling
        if {[info exists shop_bling($key)]} { return [lindex $shop_bling($key) 0] }
        if {[info exists boss_bling($key)]} { return [lindex $boss_bling($key) 0] }
        if {[legend_kind $key] eq "bling"} { return [legend_name $key] }
        return "No Bling"
    }

    proc bling_bonus_pct {key {nick ""}} {
        variable shop_bling
        variable boss_bling
        if {[info exists shop_bling($key)]} { return [lindex $shop_bling($key) 2] }
        if {[info exists boss_bling($key)]} { return [lindex $boss_bling($key) 1] }
        if {[legend_kind $key] eq "bling"} { return [legend_bling_bonus_pct $nick] }
        return 0.0
    }

    # Separate economy bonus per bling tier: discounts drug buys and boosts
    # drug sales and pimp collections, flat regardless of the specific drug
    # or worker tier involved. Silver=5% up to Ice=25%.
    variable bling_econ_table
    array set bling_econ_table {
        none     0
        silver   5
        gold     10
        puregold 15
        diamonds 20
        ice      25
        whiteice 30
        blackice 35
        icegold  40
    }

    proc bling_econ_pct {key {nick ""}} {
        variable bling_econ_table
        variable boss_bling
        if {[info exists bling_econ_table($key)]} { return $bling_econ_table($key) }
        if {[info exists boss_bling($key)]} { return [lindex $boss_bling($key) 2] }
        if {[legend_kind $key] eq "bling"} { return [legend_bling_econ_pct $nick] }
        return 0
    }

    # Percentage bonus applied to a player's core stats, based on equipped
    # bling (single Chain slot -- see bling_slots in mafia_core.tcl).
    proc player_bling_pct {nick} {
        variable bling_slots
        set total 0.0
        foreach slot $bling_slots {
            set b [getf $nick $slot "none"]
            set total [expr {$total + [bling_bonus_pct $b $nick]}]
        }
        return $total
    }

    # Economy bonus (drug buy discount / drug+pimp sell bonus) from the
    # equipped Chain.
    proc player_bling_econ_pct {nick} {
        variable bling_slots
        set total 0
        foreach slot $bling_slots {
            set b [getf $nick $slot "none"]
            set total [expr {$total + [bling_econ_pct $b $nick]}]
        }
        return $total
    }

    proc pimp_bonus_pct {nick kind} {
        switch -- $kind {
            stats  { set tiers {strategist kingmaker} }
            damage { set tiers {enforcer kingmaker} }
            cash   { set tiers {accountant kingmaker} }
            xp     { set tiers {fixer kingmaker} }
            default { return 0.0 }
        }
        set total 0.0
        foreach tier $tiers {
            set count [getf $nick pimp,$tier 0]
            if {$count <= 0} continue
            switch -- $tier {
                strategist { set per 5.0 }
                enforcer   { set per 10.0 }
                accountant { set per 10.0 }
                fixer      { set per 10.0 }
                kingmaker  { set per 5.0 }
                default    { set per 0.0 }
            }
            # Extra specialists stack, but only the first five copies of a
            # given specialist type contribute. This keeps the passive bonus
            # meaningful without allowing giant worker counts to explode it.
            set effective [expr {min(5,$count)}]
            set total [expr {$total + ($per*$effective)}]
        }
        return $total
    }

    proc pimp_damage_mult {nick} {
        return [expr {1.0 + [pimp_bonus_pct $nick damage]/100.0}]
    }
    proc pimp_cash_mult {nick} {
        return [expr {1.0 + [pimp_bonus_pct $nick cash]/100.0}]
    }
    proc pimp_xp_mult {nick} {
        return [expr {1.0 + [pimp_bonus_pct $nick xp]/100.0}]
    }
    proc reward_cash {nick amount} {
        variable players
        set k [string tolower $nick]
        set amount [expr {max(0,int(round($amount*[pimp_cash_mult $nick])))}]
        incr players($k,cash) $amount
        return $amount
    }
    proc reward_xp {nick amount} {
        variable players
        set k [string tolower $nick]
        set amount [expr {max(0,int(round($amount*[pimp_xp_mult $nick])))}]
        set before $players($k,xp)
        incr players($k,xp) $amount
        # XP and levels continue normally. Tier bosses gate access to the next
        # tier's jobs/NPCs/hits/CPU progression, not XP accumulation.
        sync_level_stats $nick
        return [expr {$players($k,xp) - $before}]
    }

    # Normalize persisted/in-memory economy state at command and save boundaries.
    # This is deliberately conservative: it only repairs impossible values and
    # duplicate ownership entries. It does not invent cash, XP, drugs, workers,
    # or rewards. Keeping these invariants centralized makes unusual command
    # ordering and stale/corrupt database state much harder to turn into an
    # economy exploit.
    proc normalize_player_economy {nick} {
        variable players
        variable max_health
        variable shop_weapons
        variable shop_armor
        variable shop_tools
        variable shop_bling
        variable boss_bling
        variable boss_tools
        variable drugs
        variable pimp_workers
        variable fence_goods
        set k [string tolower $nick]
        if {![info exists players($k,cash)]} { return 0 }

        # Remove retired catalog entries from legacy saves so deleted gear
        # cannot remain usable or be sold through stale state.
        foreach item {pistol smg assassin_blade shotgun laser_pistol rocket_launcher getaway nightvision headshot_kit bribe heavy ghost exo stealth} {
            if {[info exists players($k,owned_weapons)]} {
                set idx [lsearch -exact $players($k,owned_weapons) $item]
                while {$idx >= 0} {
                    set players($k,owned_weapons) [lreplace $players($k,owned_weapons) $idx $idx]
                    set idx [lsearch -exact $players($k,owned_weapons) $item]
                }
            }
            if {[info exists players($k,owned_armor)]} {
                set idx [lsearch -exact $players($k,owned_armor) $item]
                while {$idx >= 0} {
                    set players($k,owned_armor) [lreplace $players($k,owned_armor) $idx $idx]
                    set idx [lsearch -exact $players($k,owned_armor) $item]
                }
            }
            if {[info exists players($k,items)]} {
                set idx [lsearch -exact $players($k,items) $item]
                while {$idx >= 0} {
                    set players($k,items) [lreplace $players($k,items) $idx $idx]
                    set idx [lsearch -exact $players($k,items) $item]
                }
            }
        }

        # Retired per-player field: jail_risk_multiplier is a namespace config
        # value, but job/crime used to read it through getf, which created
        # and persisted a copy of it on every player row. Drop any stored copy
        # so old saves stop carrying (and reloading) it.
        catch {unset players($k,jail_risk_multiplier)}

        # Money/XP/quantities can never be negative.
        foreach field {cash bank xp kills deaths} {
            if {![info exists players($k,$field)] || ![string is integer -strict $players($k,$field)]} {
                set players($k,$field) 0
            } elseif {$players($k,$field) < 0} {
                set players($k,$field) 0
            }
        }

        # boss_tier_cleared gates which boss tier a player may challenge
        # (see cmd_boss); pin it to a sane 0-20 integer before using it.
        if {![info exists players($k,boss_tier_cleared)] ||
            ![string is integer -strict $players($k,boss_tier_cleared)] ||
            $players($k,boss_tier_cleared) < 0} {
            set players($k,boss_tier_cleared) 0
        } elseif {$players($k,boss_tier_cleared) > 20} {
            set players($k,boss_tier_cleared) 20
        }

        # Reconcile boss-tool ownership/bonus pairs. apply_boss_tool_bonus
        # always writes boss_tool_$item and boss_tool_bonus_$item together,
        # but a legacy/corrupt row can end up with the ownership flag set
        # and no bonus record to revoke on sale -- the tool would then sell
        # for cash with nothing to reconcile against boss_bonus_$stat. The
        # original stat/amount can't be recovered, so drop the ownership
        # flag rather than let it cash out for free.
        foreach item [array names boss_tools] {
            if {![info exists players($k,boss_tool_$item)]} { continue }
            set owned $players($k,boss_tool_$item)
            if {[string is integer -strict $owned] && $owned} {
                set bonus [expr {[info exists players($k,boss_tool_bonus_$item)] ? $players($k,boss_tool_bonus_$item) : ""}]
                set parts [split $bonus "|"]
                if {[llength $parts] != 2 || ![string is integer -strict [lindex $parts 1]]} {
                    unset -nocomplain players($k,boss_tool_$item)
                    unset -nocomplain players($k,boss_tool_bonus_$item)
                }
            } else {
                # Not owned: "0" and "absent" mean the same thing here, and
                # reading this with getf is what created the row -- one per
                # boss tool, 20 per player, rewritten to the database on every
                # command. Drop it (and any orphaned bonus record with it).
                unset -nocomplain players($k,boss_tool_$item)
                unset -nocomplain players($k,boss_tool_bonus_$item)
            }
        }

        # Same story for the bonus counters themselves: a zero bonus is
        # indistinguishable from no bonus, and boss_bonus_pct returns 0 for
        # an absent one.
        foreach bstat {dodge headshot rob block resist_jail
                       stat_pickpocket stat_dexterity stat_accuracy stat_stealth} {
            if {![info exists players($k,boss_bonus_$bstat)]} { continue }
            set bval $players($k,boss_bonus_$bstat)
            if {![string is integer -strict $bval] || $bval <= 0} {
                unset -nocomplain players($k,boss_bonus_$bstat)
            }
        }

        # Retired jewelry slots. Ice used to occupy four slots; it is a single
        # Chain slot now (bling_slots), so earring/grill/ring fields left in an
        # old save are dead weight that gets loaded and re-saved forever.
        variable bling_slots
        foreach retired_slot {earring grill ring} {
            if {[lsearch -exact $bling_slots $retired_slot] >= 0} { continue }
            catch {unset players($k,$retired_slot)}
        }

        # Do not clamp XP by boss progression. Players may level normally;
        # tier-sensitive content performs its own boss-clear gate.

        # Never trust a persisted health_max blindly; derive the authoritative
        # cap from level progression and repair stale/corrupt saves.
        sync_level_stats $nick
        set dynmax [player_max_health $nick]
        if {![info exists players($k,health)] || ![string is integer -strict $players($k,health)]} {
            set players($k,health) $dynmax
        }
        if {$players($k,health) < 0} { set players($k,health) 0 }
        if {$players($k,health) > $dynmax} { set players($k,health) $dynmax }

        # Legendary ownership flags are the authority for the whole set: the
        # stat/collection bonus is counted off them, and the gear entries in
        # owned_weapons/owned_armor/owned_bling/items are downstream of them.
        # Normalize them the same non-creating way as the boss-tool flags --
        # "0" and "absent" mean the same thing, so a zero row is dropped
        # rather than persisted four-per-player forever.
        variable legend_order
        foreach __li $legend_order {
            if {![info exists players($k,legend_$__li)]} { continue }
            set __lv $players($k,legend_$__li)
            if {![string is integer -strict $__lv] || $__lv <= 0} {
                unset -nocomplain players($k,legend_$__li)
            } elseif {$__lv != 1} {
                # A flag is a flag; a count would silently multiply the set
                # bonus if a hand-edited row said 7.
                set players($k,legend_$__li) 1
            }
        }
        if {![info exists players($k,legend_roll_last)] ||
            ![string is integer -strict $players($k,legend_roll_last)] ||
            $players($k,legend_roll_last) < 0} {
            catch {unset players($k,legend_roll_last)}
        }

        # Renamed tier: whitegold -> icegold ("White Gold" -> "Ice Gold").
        # Map any stored copy across BEFORE the ownership validation below,
        # which drops items that aren't in the catalog -- otherwise a player
        # who already bought it would silently lose a 75,000,000 purchase.
        if {[info exists players($k,owned_bling)]} {
            set idx [lsearch -exact $players($k,owned_bling) whitegold]
            while {$idx >= 0} {
                set players($k,owned_bling) [lreplace $players($k,owned_bling) $idx $idx icegold]
                set idx [lsearch -exact $players($k,owned_bling) whitegold]
            }
        }
        if {[info exists players($k,bling)] && $players($k,bling) eq "whitegold"} {
            set players($k,bling) icegold
        }

        # Deduplicate and validate owned bling. Lists are sets in the economy:
        # buying the same non-tool gear twice is rejected, and tools are unique.
        # A legendary key in an ownership list is only real if the matching
        # legend_<item> flag is set. The flag and the list entry are always
        # written together by grant_legend_piece in one command, so a list
        # entry without its flag means the row was edited or truncated --
        # drop it rather than mint the strongest item in the game for free.
        # (Same "equipped/owned is a reference, not proof" discipline applied
        # to weapon/armor below.)
        lassign {owned_bling shop_bling none} field shop default
        set cleaned {}
        if {[info exists players($k,$field)]} {
            foreach item $players($k,$field) {
                if {[is_legend_item $item] &&
                    !([info exists players($k,legend_$item)] && $players($k,legend_$item))} { continue }
                if {([info exists ${shop}($item)] || [info exists boss_bling($item)] ||
                     [legend_kind $item] eq "bling") && [lsearch -exact $cleaned $item] < 0} {
                    lappend cleaned $item
                }
            }
        }
        if {[lsearch -exact $cleaned $default] < 0} {
            set cleaned [linsert $cleaned 0 $default]
        }
        set players($k,$field) $cleaned

        # Owned weapons/armor: valid if they're in the shop OR the
        # boss/black-market gear tables (looted from bosses -- never sold,
        # never in the shop, but still real, keepable gear).
        set cleaned {}
        if {[info exists players($k,owned_weapons)]} {
            foreach item $players($k,owned_weapons) {
                if {[is_legend_item $item] &&
                    !([info exists players($k,legend_$item)] && $players($k,legend_$item))} { continue }
                if {[is_valid_weapon_key $item] && [lsearch -exact $cleaned $item] < 0} {
                    lappend cleaned $item
                }
            }
        }
        if {[lsearch -exact $cleaned fists] < 0} { set cleaned [linsert $cleaned 0 fists] }
        set players($k,owned_weapons) $cleaned

        set cleaned {}
        if {[info exists players($k,owned_armor)]} {
            foreach item $players($k,owned_armor) {
                if {[is_legend_item $item] &&
                    !([info exists players($k,legend_$item)] && $players($k,legend_$item))} { continue }
                if {[is_valid_armor_key $item] && [lsearch -exact $cleaned $item] < 0} {
                    lappend cleaned $item
                }
            }
        }
        if {[lsearch -exact $cleaned none] < 0} { set cleaned [linsert $cleaned 0 none] }
        set players($k,owned_armor) $cleaned

        # The reverse repair: a set flag whose gear entry went missing puts
        # the piece back in the right ownership list. The flag is what the
        # player actually earned, so losing the equippable item to a partial
        # write would be a silent downgrade rather than an exploit.
        foreach __li $legend_order {
            if {![info exists players($k,legend_$__li)] || !$players($k,legend_$__li)} { continue }
            switch -- [legend_kind $__li] {
                weapon { if {[lsearch -exact $players($k,owned_weapons) $__li] < 0} { lappend players($k,owned_weapons) $__li } }
                armor  { if {[lsearch -exact $players($k,owned_armor) $__li] < 0}   { lappend players($k,owned_armor) $__li } }
                bling  { if {[lsearch -exact $players($k,owned_bling) $__li] < 0}   { lappend players($k,owned_bling) $__li } }
            }
        }

        # Equipped gear must be owned and must still be valid (shop or boss).
        if {![info exists players($k,weapon)] ||
            ![is_valid_weapon_key $players($k,weapon)]} {
            set players($k,weapon) fists
        }
        # Equipped gear is a reference, not proof of ownership. If an old or
        # corrupted save says a player is equipped with an item absent from the
        # ownership set, fall back to the safest owned/default item instead of
        # silently minting that gear.
        if {![info exists players($k,weapon)] ||
            ![is_valid_weapon_key $players($k,weapon)] ||
            [lsearch -exact $players($k,owned_weapons) $players($k,weapon)] < 0} {
            set players($k,weapon) [lindex $players($k,owned_weapons) 0]
            if {![is_valid_weapon_key $players($k,weapon)]} { set players($k,weapon) fists }
        }

        if {![info exists players($k,armor)] ||
            ![is_valid_armor_key $players($k,armor)] ||
            [lsearch -exact $players($k,owned_armor) $players($k,armor)] < 0} {
            set players($k,armor) [lindex $players($k,owned_armor) 0]
            if {![is_valid_armor_key $players($k,armor)]} { set players($k,armor) none }
        }

        if {![info exists players($k,bling)] ||
            ![is_valid_bling_key $players($k,bling)] ||
            [lsearch -exact $players($k,owned_bling) $players($k,bling)] < 0} {
            set players($k,bling) [lindex $players($k,owned_bling) 0]
            if {![is_valid_bling_key $players($k,bling)]} { set players($k,bling) none }
        }

        # looted_gear records which gear has already dropped for this player
        # (see npc_fight_core). It is a set of real weapon/armor keys; keep it
        # deduplicated and free of retired items so it can't grow unbounded,
        # and drop the field entirely once nothing valid is left in it.
        if {[info exists players($k,looted_gear)]} {
            set cleaned {}
            foreach item $players($k,looted_gear) {
                if {([is_valid_weapon_key $item] || [is_valid_armor_key $item]) &&
                    [lsearch -exact $cleaned $item] < 0} {
                    lappend cleaned $item
                }
            }
            if {[llength $cleaned]} {
                set players($k,looted_gear) $cleaned
            } else {
                unset -nocomplain players($k,looted_gear)
            }
        }

        # Tools are a one-of-each inventory. Remove unknown/duplicate entries.
        set clean_tools {}
        if {[info exists players($k,items)]} {
            foreach item $players($k,items) {
                # Same flag gate as the gear lists: the legendary tool is only
                # real inventory if its ownership flag says it was earned.
                if {[is_legend_item $item] &&
                    !([info exists players($k,legend_$item)] && $players($k,legend_$item))} { continue }
                if {([info exists shop_tools($item)] || [info exists boss_tools($item)] ||
                     [legend_kind $item] eq "tool") && [lsearch -exact $clean_tools $item] < 0} {
                    lappend clean_tools $item
                }
            }
        }
        set players($k,items) $clean_tools
        # ...and the reverse repair for the tool half of the set.
        foreach __li $legend_order {
            if {[legend_kind $__li] ne "tool"} { continue }
            if {![info exists players($k,legend_$__li)] || !$players($k,legend_$__li)} { continue }
            if {[lsearch -exact $players($k,items) $__li] < 0} {
                lappend players($k,items) $__li
            }
        }
        catch {unset __li __lv}

        # Drug quantities are non-negative integers. Only current market
        # drugs are consumed by commands, so validate those explicitly.
        foreach d [array names drugs] {
            if {![info exists players($k,drug,$d)] ||
                ![string is integer -strict $players($k,drug,$d)] ||
                $players($k,drug,$d) < 0} {
                set players($k,drug,$d) 0
            } elseif {$players($k,drug,$d) > 1000000} {
                set players($k,drug,$d) 1000000
            }
        }

        # Worker counts are quantities too. Keep them finite and integer-safe.
        # Jail-until and last-run are timestamps/state, not worker quantities.
        foreach tier [array names pimp_workers] {
            foreach field {pimp pimp_jail} {
                if {![info exists players($k,$field,$tier)] ||
                    ![string is integer -strict $players($k,$field,$tier)] ||
                    $players($k,$field,$tier) < 0} {
                    set players($k,$field,$tier) 0
                } elseif {$players($k,$field,$tier) > 1000000} {
                    set players($k,$field,$tier) 1000000
                }
            }
            foreach field {pimp_jail_until pimp_last} {
                if {![info exists players($k,$field,$tier)] ||
                    ![string is integer -strict $players($k,$field,$tier)] ||
                    $players($k,$field,$tier) < 0} {
                    set players($k,$field,$tier) [now]
                    if {$field eq "pimp_jail_until"} {
                        set players($k,$field,$tier) 0
                    }
                }
            }
        }

        # Dealer network and casino floors are quantities on exactly the same
        # footing as pimp workers above, and were simply never added here when
        # those two systems landed. Without this, a malformed persisted value
        # turns the next `incr players($k,dealer_supply,$tier)` (or the
        # casino/dealer collect arithmetic) into an uncaught Tcl error, which
        # the dispatcher answers with "that Mafia action failed cleanly" and a
        # full command rollback -- for every command the player types, forever.
        # Deliberately non-creating (see the boss_tool/boss_bonus passes
        # above): unlike pimp tiers, new_player does not seed dealer/casino
        # rows, so testing with [info exists] first and skipping absent ones
        # repairs corrupt values without manufacturing 30 zero rows per player
        # that would then be written to the database on every single command.
        variable dealer_tiers
        variable casino_tiers
        foreach tier [array names dealer_tiers] {
            foreach field {dealer dealer_jail dealer_supply} {
                if {![info exists players($k,$field,$tier)]} continue
                if {![string is integer -strict $players($k,$field,$tier)] ||
                    $players($k,$field,$tier) < 0} {
                    set players($k,$field,$tier) 0
                } elseif {$players($k,$field,$tier) > 1000000} {
                    set players($k,$field,$tier) 1000000
                }
            }
            foreach field {dealer_jail_until dealer_last} {
                if {![info exists players($k,$field,$tier)]} continue
                if {![string is integer -strict $players($k,$field,$tier)] ||
                    $players($k,$field,$tier) < 0} {
                    set players($k,$field,$tier) [expr {$field eq "dealer_jail_until" ? 0 : [now]}]
                }
            }
        }
        foreach tier [array names casino_tiers] {
            if {[info exists players($k,casino,$tier)]} {
                if {![string is integer -strict $players($k,casino,$tier)] ||
                    $players($k,casino,$tier) < 0} {
                    set players($k,casino,$tier) 0
                } elseif {$players($k,casino,$tier) > 1000000} {
                    set players($k,casino,$tier) 1000000
                }
            }
            if {[info exists players($k,casino_last,$tier)] &&
                (![string is integer -strict $players($k,casino_last,$tier)] ||
                 $players($k,casino_last,$tier) < 0)} {
                set players($k,casino_last,$tier) [now]
            }
        }

        # Black-market consumables are also quantities. Never allow malformed
        # persisted values to become usable inventory. A generous ceiling keeps
        # corrupt/admin-generated values from becoming enormous integer work or
        # an accidental economy faucet while remaining far above normal play.
        # Deliberately non-creating, for the same reason as the boss_tool and
        # boss_bonus passes above: use_bm_item and cmd_blackbuy both treat
        # "absent" and 0 identically, so seeding a zero row for all ten pool
        # items on every command only ever added ten junk rows per player to
        # rewrite to the database forever. Repair what is there; invent nothing.
        foreach item [array names ::mafia::blackmarket_pool] {
            if {![info exists players($k,bm,$item)]} { continue }
            if {![string is integer -strict $players($k,bm,$item)] ||
                $players($k,bm,$item) < 0} {
                unset -nocomplain players($k,bm,$item)
            } elseif {$players($k,bm,$item) == 0} {
                unset -nocomplain players($k,bm,$item)
            } elseif {$players($k,bm,$item) > 1000000} {
                set players($k,bm,$item) 1000000
            }
        }

        # Hot goods are also quantities defined by fence_goods. Cap malformed
        # persisted quantities and validate their timestamps so a bad database
        # value cannot poison every subsequent fence sale with arithmetic errors.
        # Non-creating, same reasoning as the black-market pass above: every
        # reader of goods,<item> (cmd_goods, cmd_fence, sell_all_goods,
        # maybe_drop_goods) already tests [info exists] first.
        foreach item [array names fence_goods] {
            if {![info exists players($k,goods,$item)]} {
                catch {unset players($k,goods_ts,$item)}
                continue
            }
            if {![string is integer -strict $players($k,goods,$item)] ||
                $players($k,goods,$item) < 0} {
                set players($k,goods,$item) 0
            } elseif {$players($k,goods,$item) > 1000000} {
                set players($k,goods,$item) 1000000
            }
            if {$players($k,goods,$item) <= 0} {
                unset -nocomplain players($k,goods,$item)
                catch {unset players($k,goods_ts,$item)}
            } elseif {[info exists players($k,goods_ts,$item)] &&
                      (![string is integer -strict $players($k,goods_ts,$item)] ||
                       $players($k,goods_ts,$item) < 0)} {
                set players($k,goods_ts,$item) [now]
            }
        }

        # Cooldowns/timestamps are state, not rewards. Repair missing or
        # malformed values so legacy rows cannot turn an otherwise valid command
        # into an uncaught Tcl error. Future timestamps are retained: they can
        # legitimately arise from clock adjustments and should not grant an
        # unintended immediate cooldown bypass.
        foreach field {last_crime last_job last_deal last_gamble last_attack last_pvp_reaction last_rob
                       last_wiretap last_street last_hit last_stealth last_npc last_boss pimp_collect_last
                       casino_collect_last dealer_collect_last
                       jail_until jail_notified hosp_until hosp_notified hide_until last_chan} {
            if {$field eq "last_chan"} {
                if {![info exists players($k,$field)]} { set players($k,$field) "" }
            } elseif {![info exists players($k,$field)] ||
                      ![string is integer -strict $players($k,$field)] ||
                      $players($k,$field) < 0} {
                set players($k,$field) 0
            }
        }

        # autoheal is read as a boolean by maybe_autoheal on every damage
        # event. A non-numeric persisted value there makes that `if` an
        # uncaught Tcl error -- i.e. every fight the player takes gets rolled
        # back with "that Mafia action failed cleanly". Non-creating: absent
        # already means off.
        if {[info exists players($k,autoheal)]} {
            if {![string is integer -strict $players($k,autoheal)] || $players($k,autoheal) <= 0} {
                unset -nocomplain players($k,autoheal)
            } elseif {$players($k,autoheal) != 1} {
                set players($k,autoheal) 1
            }
        }

        # A pending revenge crew is persisted, so a malformed row would be fed
        # straight into run_npc_battle as NPC hit points. Either all four
        # fields are sane or the encounter is dropped.
        if {[info exists players($k,revenge_name)] ||
            [info exists players($k,revenge_hp)] ||
            [info exists players($k,revenge_weapon)] ||
            [info exists players($k,revenge_armor)]} {
            set __rev_ok 1
            foreach __rf {revenge_name revenge_hp revenge_weapon revenge_armor} {
                if {![info exists players($k,$__rf)] || $players($k,$__rf) eq ""} { set __rev_ok 0 }
            }
            if {$__rev_ok && (![string is integer -strict $players($k,revenge_hp)] ||
                              $players($k,revenge_hp) < 1)} { set __rev_ok 0 }
            if {$__rev_ok && (![is_valid_weapon_key $players($k,revenge_weapon)] ||
                              ![is_valid_armor_key $players($k,revenge_armor)])} { set __rev_ok 0 }
            if {!$__rev_ok} {
                foreach __rf {revenge_name revenge_hp revenge_weapon revenge_armor} {
                    unset -nocomplain players($k,$__rf)
                }
            }
            catch {unset __rev_ok __rf}
        }

        return 1
    }

    # Sweep for player fields whose dynamic key no longer exists in any
    # catalog: drugs, hot goods, black-market items, pimp tiers, boss tools
    # and boss gear that were renamed or retired between versions.
    #
    # normalize_player_economy cannot catch these. It validates the CURRENT
    # catalog by iterating the catalog and checking the player's field for
    # each entry -- it never walks the player's own key set, so an orphaned
    # key is simply never looked at again. It stays resident in the players
    # array and gets rewritten to the database on every single save, forever.
    # That is how earring/grill/ring (a retired four-slot ice design) and
    # jail_risk_multiplier were still sitting in the live save years later.
    #
    # Deliberately NOT run per command: this walks the player's whole key set,
    # while everything else on the hot path is O(catalog). Orphans can only
    # appear across a version change, so load/rehash is the right time and the
    # only time it is called.
    proc prune_retired_fields {} {
        variable players
        variable drugs
        variable fence_goods
        variable blackmarket_pool
        variable pimp_workers
        variable boss_tools
        variable boss_weapons
        variable boss_armor
        variable boss_bling
        variable dealer_tiers
        variable casino_tiers
        variable legend_items
        set boss_gear [concat [array names boss_weapons] [array names boss_armor] [array names boss_bling]]
        # field prefix -> the set its suffix has to belong to. Longest first
        # where one prefix contains another (boss_tool_bonus_ before
        # boss_tool_), because the first match wins.
        set families [list \
            "drug,"            [array names drugs] \
            "goods_ts,"        [array names fence_goods] \
            "goods,"           [array names fence_goods] \
            "bm,"              [array names blackmarket_pool] \
            "pimp_jail_until," [array names pimp_workers] \
            "pimp_jail,"       [array names pimp_workers] \
            "pimp_last,"       [array names pimp_workers] \
            "pimp,"            [array names pimp_workers] \
            "dealer_jail_until," [array names dealer_tiers] \
            "dealer_jail,"     [array names dealer_tiers] \
            "dealer_supply,"   [array names dealer_tiers] \
            "dealer_last,"     [array names dealer_tiers] \
            "dealer,"          [array names dealer_tiers] \
            "casino_last,"     [array names casino_tiers] \
            "casino,"          [array names casino_tiers] \
            "boss_tool_bonus_" [array names boss_tools] \
            "boss_tool_"       [array names boss_tools] \
            "boss_gear_resold_" $boss_gear \
            "boss_bonus_"      {dodge headshot rob block resist_jail
                                stat_pickpocket stat_dexterity stat_accuracy stat_stealth} \
            "legend_"          [concat [array names legend_items] {roll_last}]]
        # One pass over the whole array, not one pass per player: the check
        # only depends on the field half of the key, so doing it per nick
        # would be O(players x keys) for no reason. Field = everything after
        # the FIRST comma, matching save_db's own key convention (fields such
        # as drug,weed contain commas of their own).
        set removed 0
        foreach key [array names players] {
            set comma [string first "," $key]
            if {$comma < 1} { continue }
            set field [string range $key [expr {$comma+1}] end]
            foreach {fprefix valid} $families {
                set flen [string length $fprefix]
                if {![string equal -length $flen $fprefix $field]} { continue }
                if {[lsearch -exact $valid [string range $field $flen end]] < 0} {
                    unset -nocomplain players($key)
                    incr removed
                }
                break
            }
        }
        # Orphan sweep: rows filed under a nick that has no ",cash" row.
        #
        # ",cash" is what exists_player tests and what every player sweep in
        # this script keys off (save_db's normalize pass, prune, auto-cleanup,
        # the leaderboards, the load-time repair loop). A nick without one is
        # therefore invisible to all of them -- but NOT to save_db's second
        # loop, which walks the raw array and writes every key it finds. So an
        # orphaned row set is immortal: never played, never pruned, never
        # counted, and rewritten to SQLite on every single command forever.
        # getf's memoizing write was the way they got created (now fixed at
        # the source above); this collects the ones already on disk.
        #
        # meta_key is the one legitimate cash-less row set (last_auto_cleanup,
        # the bot-wide cleanup clock) and must survive the sweep -- deleting it
        # would restart the auto-cleanup interval on every load.
        # An array, not a list: this is checked once per KEY, so a linear
        # lsearch would make the sweep O(players x keys) -- 68 million string
        # compares at 500 players. Hashed lookup keeps it linear in keys.
        variable meta_key
        array set live_nicks {}
        foreach key [array names players "*,cash"] {
            set comma [string first "," $key]
            if {$comma < 1} { continue }
            set live_nicks([string range $key 0 [expr {$comma-1}]]) 1
        }
        set live_nicks($meta_key) 1
        foreach key [array names players] {
            set comma [string first "," $key]
            if {$comma < 1} {
                # A key with no comma at all matches no player/field shape
                # this script ever writes; it is corruption either way.
                unset -nocomplain players($key)
                incr removed
                continue
            }
            if {![info exists live_nicks([string range $key 0 [expr {$comma-1}]])]} {
                unset -nocomplain players($key)
                incr removed
            }
        }
        return $removed
    }

    # Ownership tracking for weapons/armor/bling, so !equip can't hand out
    # gear that was never bought. For legacy saves that predate ownership
    # lists, the currently equipped valid item is preserved as owned exactly
    # once. Once an ownership list exists, however, NEVER infer ownership from
    # the equipped field: doing so can mint free gear if a persisted row is
    # inconsistent or maliciously modified.
    proc ensure_gear_lists {nick} {
        variable players
        variable shop_weapons
        variable shop_armor
        variable shop_bling
        variable boss_bling
        set k [string tolower $nick]

        if {![info exists players($k,weapon)] || ![is_valid_weapon_key $players($k,weapon)]} {
            set players($k,weapon) fists
        }
        if {![info exists players($k,armor)] || ![is_valid_armor_key $players($k,armor)]} {
            set players($k,armor) none
        }
        if {![info exists players($k,bling)] || ![is_valid_bling_key $players($k,bling)]} {
            set players($k,bling) none
        }

        if {![info exists players($k,owned_weapons)]} {
            set players($k,owned_weapons) [list fists]
            if {$players($k,weapon) ne "fists"} {
                lappend players($k,owned_weapons) $players($k,weapon)
            }
        }
        if {![info exists players($k,owned_armor)]} {
            set players($k,owned_armor) [list none]
            if {$players($k,armor) ne "none"} {
                lappend players($k,owned_armor) $players($k,armor)
            }
        }
        if {![info exists players($k,owned_bling)]} {
            set players($k,owned_bling) [list none]
            if {$players($k,bling) ne "none"} {
                lappend players($k,owned_bling) $players($k,bling)
            }
        }
    }

    proc item_owned_weapon {nick item} {
        variable players
        ensure_gear_lists $nick
        set k [string tolower $nick]
        return [expr {[lsearch -exact $players($k,owned_weapons) $item] >= 0}]
    }

    proc item_owned_armor {nick item} {
        variable players
        ensure_gear_lists $nick
        set k [string tolower $nick]
        return [expr {[lsearch -exact $players($k,owned_armor) $item] >= 0}]
    }

    proc item_owned_bling {nick item} {
        variable players
        ensure_gear_lists $nick
        set k [string tolower $nick]
        return [expr {[lsearch -exact $players($k,owned_bling) $item] >= 0}]
    }

    proc tool_name {key} {
        variable shop_tools
        variable boss_tools
        if {[info exists shop_tools($key)]} { return [lindex $shop_tools($key) 0] }
        if {[info exists boss_tools($key)]} { return [lindex $boss_tools($key) 0] }
        if {[legend_kind $key] eq "tool"} { return [legend_name $key] }
        return "Unknown Tool"
    }

    # Non-throwing read. pvp_reaction consults this up to eight times against
    # the DEFENDER, and no PvP command normalizes the defender's row -- only
    # the attacker's. A row that predates the tools inventory (or any partially
    # written row) therefore made every shoot/headshot aimed at that player die
    # with "no such element in array", which the dispatcher reports as a failed
    # transaction and rolls back. Absent means "owns nothing", which is what
    # every caller already means by a false return.
    proc has_item {nick item} {
        variable players
        set k [string tolower $nick]
        if {![info exists players($k,items)]} { return 0 }
        return [expr {[lsearch -exact $players($k,items) $item] >= 0}]
    }

    proc boss_bonus_pct {nick stat} {
        variable players
        # Deliberately a non-creating read. getf seeds its default INTO the
        # player array, so asking for a bonus the player never earned created
        # the row and persisted it. get_stat calls this four times on almost
        # every command, which is where the boss_bonus_stat_* zero rows in
        # live saves came from.
        set k [string tolower $nick]
        set v 0
        if {[info exists players($k,boss_bonus_$stat)]} {
            set v $players($k,boss_bonus_$stat)
            if {![string is integer -strict $v]} { set v 0 }
        }
        set cap [boss_bonus_cap $stat]
        if {$cap ne "" && $v > $cap} { return $cap }
        return $v
    }

    # Chance-based bonus categories (dodge/headshot/rob/block/resist_jail)
    # stack additively across up to 20 boss tools with no natural ceiling.
    # Combat routines already clamp some of these at the point of use, but
    # the underlying storage should also be normalized so a raw read of
    # boss_bonus_pct never returns an absurd value. Stat_* categories are
    # left uncapped here -- they run through get_stat's own scaling.
    proc boss_bonus_cap {stat} {
        switch -- $stat {
            dodge       { return 50 }
            headshot    { return 95 }
            rob         { return 95 }
            block       { return 50 }
            resist_jail { return 90 }
            default     { return "" }
        }
    }

    proc boss_tool_tier {item} {
        # 1-20 tier index for a boss tool key, used to scale the permanent
        # bonus it rolls -- a flat 1-3%/1-2% roll made Tier 1's Street Boss
        # Charm and Tier 20's Master Don's Core worth the exact same
        # permanent bonus, which didn't match every other boss-gear slot
        # (weapon/armor/bling) climbing hard tier to tier.
        variable boss_tool_order
        set idx [lsearch -exact $boss_tool_order $item]
        if {$idx < 0} { return 1 }
        return [expr {$idx+1}]
    }

    proc apply_boss_tool_bonus {nick tool} {
        variable players
        set k [string tolower $nick]
        if {[getf $nick boss_tool_$tool 0]} { return "" }
        set choices {dodge headshot rob stat_pickpocket stat_dexterity stat_accuracy stat_stealth block resist_jail}
        set stat [lindex $choices [expr {int(rand()*[llength $choices])}]]
        set tier [boss_tool_tier $tool]
        # Base roll unchanged (keeps Tier 1 feeling the same as before);
        # a tier-scaled bonus is layered on top so the ladder actually
        # climbs. +0 at Tier 1, up to +9 (non-stat) / +6 (stat) at Tier 20.
        set tier_bonus [expr {int(($tier-1)*0.5)}]
        set amount [expr {1+int(rand()*3)+$tier_bonus}]
        if {[string match "stat_*" $stat]} {
            set tier_bonus [expr {int(($tier-1)*0.32)}]
            set amount [expr {1+int(rand()*2)+$tier_bonus}]
        }
        set players($k,boss_tool_$tool) 1
        set players($k,boss_tool_bonus_$tool) "$stat|$amount"
        incr players($k,boss_bonus_$stat) $amount
        switch -- $stat {
            stat_pickpocket { set label "Pickpocket stat" }
            stat_dexterity { set label "Dexterity stat" }
            stat_accuracy { set label "Accuracy stat" }
            stat_stealth { set label "Stealth stat" }
            resist_jail { set label "jail resistance" }
            default { set label $stat }
        }
        return "+$amount% $label"
    }

    proc catch_mod {nick} {
        # percentage points shaved off any "chance of getting caught" roll
        variable players
        set k [string tolower $nick]
        set mod 0
        if {[has_item $nick heat_detector]} { incr mod 7 }
        if {[has_item $nick spy_watch]} { incr mod 4 }
        if {[has_item $nick drone_cam]} { incr mod 4 }
        if {[has_item $nick riot_visor]} { incr mod 5 }
        return $mod
    }

    proc give_item {nick item} {
        variable players
        set k [string tolower $nick]
        if {![has_item $nick $item]} {
            lappend players($k,items) $item
        }
    }

    proc take_item {nick item} {
        variable players
        set k [string tolower $nick]
        if {![info exists players($k,items)]} { return 0 }
        set idx [lsearch -exact $players($k,items) $item]
        if {$idx >= 0} {
            set players($k,items) [lreplace $players($k,items) $idx $idx]
            return 1
        }
        return 0
    }

}
# mafia_persistence.tcl - SQLite persistence: schema, save/load, autosave
# timer, legacy flatfile migration.
namespace eval mafia {
    ##### =====================================================
    #####                 PERSISTENCE (SQLite)
    ##### =====================================================
    # Every players($k,field) entry is stored as one row in player_data,
    # keyed by (nick,field). This mirrors the old flat-file's schema-free
    # shape -- any field the game code adds later (new stats, new items,
    # etc.) is persisted automatically with no table migration required.

    proc db_exec {sql} {
        variable db
        variable db_ready
        variable db_in_txn
        if {!$db_ready || $db eq ""} { return -code error "mafia database unavailable" }
        # uplevel so that any $varname bind references inside $sql resolve
        # against the caller's local variables (sqlite3's binding looks at
        # the immediate calling frame of `eval`), enabling safe parameterized
        # queries instead of manual string concatenation.
        if {[catch {uplevel 1 [list $db eval $sql]} result opts]} {
            putlog "mafia.tcl: database error: $result"
            if {$db_in_txn} {
                catch {$db eval {ROLLBACK}}
                set db_in_txn 0
            }
            return -options $opts $result
        }
        return $result
    }

    proc db_begin {} {
        variable db
        variable db_ready
        variable db_in_txn
        if {!$db_ready || $db eq ""} { return -code error "mafia database unavailable" }
        if {$db_in_txn} { return -code error "nested mafia transaction" }
        if {[catch {$db eval {BEGIN IMMEDIATE}} err]} {
            return -code error $err
        }
        set db_in_txn 1
        return 1
    }

    proc db_abort {} {
        variable db
        variable db_in_txn
        if {$db_in_txn} { catch {$db eval {ROLLBACK}} }
        set db_in_txn 0
        return 1
    }

    proc db_commit {} {
        variable db
        variable db_in_txn
        if {!$db_in_txn} { return 1 }
        if {[catch {$db eval {COMMIT}} err]} {
            catch {$db eval {ROLLBACK}}
            set db_in_txn 0
            return -code error $err
        }
        set db_in_txn 0
        return 1
    }

    proc ensure_db_dir {} {
        variable db_dir
        if {$db_dir eq ""} { set db_dir [pwd] }
        if {![file exists $db_dir]} { file mkdir $db_dir }
    }

    proc init_db {} {
        variable db
        variable db_dir
        variable db_file
        variable db_ready

        if {[catch {package require sqlite3} err]} {
            putlog "mafia.tcl: sqlite3 package is required: $err"
            return 0
        }

        ensure_db_dir
        set db_file [file join $db_dir mafia.sqlite3]

        # Defensive close in case a partial prior load (e.g. a .rehash) left
        # a handle open.
        if {[llength [info commands ::mafia::mafia_db]]} {
            catch {::mafia::mafia_db close}
        }
        if {[catch {sqlite3 ::mafia::mafia_db $db_file} err]} {
            putlog "mafia.tcl: cannot open database $db_file: $err"
            return 0
        }
        set db ::mafia::mafia_db
        set db_ready 1
        catch {$db timeout 3000}

        if {[catch {db_exec {
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS player_data (
                nick  TEXT NOT NULL,
                field TEXT NOT NULL,
                value TEXT NOT NULL,
                PRIMARY KEY (nick, field)
            );
            CREATE TABLE IF NOT EXISTS market (
                drug  TEXT PRIMARY KEY,
                price INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS pimp_market (
                tier  TEXT PRIMARY KEY,
                price INTEGER NOT NULL
            );
        }} err]} {
            putlog "mafia.tcl: schema init failed: $err"
            catch {$db close}
            set db ""
            set db_ready 0
            return 0
        }
        return 1
    }

    # Rebuild db_shadow from what is actually on disk.
    #
    # db_shadow is save_db's record of the committed row set, and save_db
    # updates it INSIDE the transaction, row by row, as it issues each
    # INSERT/DELETE. If the transaction then fails and rolls back, every one of
    # those in-memory shadow entries describes a row the database never
    # accepted -- so on the next save those fields compare "unchanged" and are
    # skipped, and the on-disk value stays wrong FOREVER (until a reload),
    # silently, with no further error. That is the one failure mode the
    # diff-based save introduced over the old rewrite-everything save, and it
    # is why every failed save has to resync the shadow before returning.
    #
    # If the resync itself cannot read the database, the shadow is emptied
    # instead: an empty shadow makes the next save re-issue every INSERT (which
    # is idempotent -- INSERT OR REPLACE), which is strictly safer than trusting
    # entries that may be fiction.
    proc resync_db_shadow {} {
        variable db
        variable db_ready
        variable db_shadow
        if {!$db_ready || $db eq ""} {
            array unset db_shadow
            return 0
        }
        set fresh {}
        if {[catch {
            $db eval {SELECT nick, field, value FROM player_data} row {
                lappend fresh $row(nick),$row(field) $row(value)
            }
        } err]} {
            putlog "mafia.tcl: could not resync the save shadow ($err); forcing a full rewrite on the next save."
            array unset db_shadow
            return 0
        }
        array unset db_shadow
        array set db_shadow $fresh
        return 1
    }

    proc save_db {{quiet 0}} {
        variable players
        variable drug_price_arr
        variable pimp_price_arr
        variable db_ready
        variable db_shadow
        if {!$db_ready} { return 0 }
        if {[catch {db_begin} err]} {
            putlog "mafia.tcl: save transaction failed: $err"
            return 0
        }
        if {[catch {
            # player_data used to be rewritten wholesale every save (DELETE
            # the whole table, reinsert every row of every player), which
            # scales with the total number of players ever registered, not
            # with how much actually changed. Instead diff the in-memory
            # players() array against db_shadow -- our record of what is
            # currently on disk -- and only touch the rows that differ, so a
            # save costs O(fields actually changed since the last save)
            # rather than O(entire roster). Bound parameters (variables
            # referenced by name inside the SQL, resolved by the sqlite3
            # binding) are used instead of manual quoting/concatenation, so
            # a nick, field, or stored value can never be interpreted as SQL
            # regardless of its contents.
            # Normalize each player once before serialization so impossible
            # negative/duplicate economy state cannot be made durable.
            # Normalize each player once. The old implementation kept a
            # linear list and used lsearch for every player, making this O(N^2)
            # during every autosave. With a large roster that can monopolize
            # Eggdrop's single-threaded event loop long enough to delay IRC
            # PONG/output processing. Use a temporary Tcl array as a set so the
            # sweep stays O(N). The array is local to this proc and is released
            # automatically when save_db returns.
            array set normalized_nicks {}
            foreach key [array names players "*,cash"] {
                set comma0 [string first "," $key]
                if {$comma0 < 1} { continue }
                set saved_nick [string range $key 0 [expr {$comma0-1}]]
                if {[info exists normalized_nicks($saved_nick)]} { continue }
                set normalized_nicks($saved_nick) 1
                normalize_player_economy $saved_nick
            }
            unset -nocomplain normalized_nicks
            array set current_set {}
            foreach key [array names players] {
                set comma [string first "," $key]
                if {$comma < 1} { continue }
                set p_field [string range $key [expr {$comma+1}] end]
                # Encounter state is transient: its live utimer cannot survive a
                # process restart or a script reload. Never persist it, otherwise
                # a restored future enc_until can create a phantom encounter with
                # no timer and allow resolution of stale state.
                if {$p_field in {enc_type enc_name enc_until enc_gen enc_timer_id}} {
                    continue
                }
                set current_set($key) 1
                set p_value $players($key)
                if {[info exists db_shadow($key)] && $db_shadow($key) eq $p_value} {
                    continue
                }
                set p_nick [string range $key 0 [expr {$comma-1}]]
                db_exec {INSERT OR REPLACE INTO player_data(nick,field,value) VALUES($p_nick,$p_field,$p_value)}
                set db_shadow($key) $p_value
            }
            # Anything that was on disk last save but no longer exists in
            # players() (admin reset/prune, retired-field cleanup, etc.) has
            # to be explicitly deleted -- it will never show up as a "changed"
            # key above since it is simply absent now.
            foreach key [array names db_shadow] {
                if {[info exists current_set($key)]} { continue }
                set comma [string first "," $key]
                if {$comma < 1} { unset db_shadow($key); continue }
                set p_nick  [string range $key 0 [expr {$comma-1}]]
                set p_field [string range $key [expr {$comma+1}] end]
                db_exec {DELETE FROM player_data WHERE nick=$p_nick AND field=$p_field}
                unset db_shadow($key)
            }
            db_exec "DELETE FROM market"
            foreach {p_drug p_price} [array get drug_price_arr] {
                db_exec {INSERT INTO market(drug,price) VALUES($p_drug,$p_price)}
            }
            db_exec "DELETE FROM pimp_market"
            foreach {p_tier p_price} [array get pimp_price_arr] {
                db_exec {INSERT INTO pimp_market(tier,price) VALUES($p_tier,$p_price)}
            }
            db_commit
        } err]} {
            catch {db_abort}
            # The aborted transaction committed nothing, but the loops above
            # already recorded their writes in db_shadow. Discard that record
            # and re-read the real row set -- see resync_db_shadow.
            catch {resync_db_shadow}
            putlog "mafia.tcl: save error: $err"
            return 0
        }
        if {!$quiet} { putlog "mafia.tcl: game data saved." }
        return 1
    }

    proc load_db {} {
        variable players
        variable drug_price_arr
        variable pimp_price_arr
        variable db
        variable db_ready
        variable db_shadow
        if {!$db_ready} { return }
        if {[catch {
            array unset db_shadow
            $db eval {SELECT nick, field, value FROM player_data} row {
                set players($row(nick),$row(field)) $row(value)
                set db_shadow($row(nick),$row(field)) $row(value)
            }
            array unset drug_price_arr
            $db eval {SELECT drug, price FROM market} row {
                set drug_price_arr($row(drug)) $row(price)
            }
            array unset pimp_price_arr
            $db eval {SELECT tier, price FROM pimp_market} row {
                set pimp_price_arr($row(tier)) $row(price)
            }

            # Encounter timers are not persistent resources. Older database
            # versions may still contain their fields, so clear any restored
            # encounter state defensively after loading.
            # UNSET rather than blank them out. Encounter state is not a
            # player field any more (it lives in chan_enc, keyed by channel),
            # and save_db refuses to persist these names -- so writing ""/0
            # back into players() only manufactured five permanently resident,
            # never-persisted, never-read keys per legacy player. Removing them
            # is what "clear defensively" was meant to do, and it lets save_db's
            # delete pass drop the rows from SQLite as well.
            foreach key [array names players *,enc_type] {
                set k [string range $key 0 [expr {[string first "," $key]-1}]]
                foreach f {enc_type enc_name enc_until enc_gen enc_timer_id} {
                    unset -nocomplain players($k,$f)
                }
            }

            # Health-curve migration: older databases may contain a stale
            # health_max/health pair from before the post-Lv.500 curve was
            # accelerated. Recalculate every loaded player's HP from level
            # immediately after loading, so the live state and SQLite state
            # agree. sync_level_stats only raises HP when max HP increased and
            # clamps over-max health, preserving legitimate current damage.
            set __health_migrated 0
            # Iterate ",cash" rows, not ",level": level is DERIVED from xp
            # (player_level/level_for_xp) and has never been a stored player
            # field, so this loop matched zero keys and the migration below
            # never ran for anybody. ",cash" is the same row every other
            # player sweep in this script keys off (save_db, prune, cleanup).
            foreach __key [array names players "*,cash"] {
                set __comma [string first "," $__key]
                if {$__comma <= 0} { continue }
                set __nick [string range $__key 0 [expr {$__comma-1}]]
                if {[catch {
                    set __before_max [getf $__nick health_max 100]
                    # Was $::__mafia::max_health -- a namespace that does not
                    # exist ("__mafia" vs "mafia"). Every iteration threw, was
                    # swallowed by the catch below, and hit the `continue`, so
                    # even with the key pattern fixed nothing would migrate.
                    set __before_hp  [getf $__nick health $::mafia::max_health]
                    sync_level_stats $__nick
                    if {$players($__nick,health_max) != $__before_max ||
                        $players($__nick,health) != $__before_hp} {
                        incr __health_migrated
                    }
                }]} {
                    # A malformed legacy player row must not abort loading the
                    # rest of the database.
                    continue
                }
            }
            if {$__health_migrated > 0} {
                putlog "mafia.tcl: migrated HP for $__health_migrated player(s) to the current level-based health curve."
            }
            catch {unset __health_migrated __key __comma __nick __before_max __before_hp}
        } err]} {
            putlog "mafia.tcl: load error: $err"
        }
    }

    # See blackmarket_timer_id in mafia_core.tcl: don't clobber a live
    # timer id on rehash, or the old timer can never be killed and leaks.
    variable autosave_timer_id
    if {![info exists autosave_timer_id]} { set autosave_timer_id "" }

    proc autosave_timer {{epoch ""}} {
        variable save_interval
        variable autosave_timer_id
        variable autosave_epoch
        variable db
        variable db_ready
        if {$epoch ne "" && $epoch != $autosave_epoch} { return }
        # Schedule the next run first so a transient save error cannot kill the
        # recurring chain.  Clamp defensively in case state was corrupted.
        set delay [expr {[string is integer -strict $save_interval] && $save_interval >= 1 ? $save_interval * 60 : 300}]
        set autosave_timer_id [utimer $delay [list ::mafia::autosave_timer $autosave_epoch]]
        if {[catch {save_db 1} err]} {
            putlog "mafia.tcl: autosave callback error: $err"
        }
        # Every command rewrites the whole player_data table, so the WAL fills
        # to SQLite's default 1000-page (~4MB) autocheckpoint ceiling and then
        # stays that size forever -- the file is recycled in place, never
        # shortened. A live save was observed at 36KB of database against a
        # 4.1MB WAL holding 9 live frames. Truncate on the autosave cycle (not
        # per command) so the on-disk WAL tracks the real data size. Failure is
        # harmless: a busy checkpoint just leaves the WAL as it was.
        if {$db_ready && $db ne ""} {
            catch {$db eval {PRAGMA wal_checkpoint(TRUNCATE)}}
        }
    }

    # Cancels any previously-scheduled autosave chain before starting a new
    # one. Without this, every script reload (.rehash) leaves the old
    # self-rescheduling utimer chain running forever alongside the new one,
    # so reloads silently multiply background saves/db writes over time.
    proc start_autosave_timer {} {
        variable autosave_timer_id
        variable autosave_epoch
        incr autosave_epoch
        if {$autosave_timer_id ne "" && [llength [info commands killutimer]]} {
            catch {killutimer $autosave_timer_id}
        }
        autosave_timer $autosave_epoch
    }

    # One-time upgrade path: if this is the first run against a fresh SQLite
    # database and an old-style flat-file save (mafia.db) is sitting next to
    # the bot, pull it in so nobody's progress is lost by upgrading. Runs at
    # most once -- the moment the SQLite database has any player rows, or
    # there's no legacy file, this is a no-op.
    proc migrate_legacy_flatfile {} {
        variable players
        variable drug_price_arr
        variable db
        variable db_ready
        if {!$db_ready} { return }
        set cnt 0
        catch {set cnt [$db onecolumn {SELECT COUNT(*) FROM player_data}]}
        if {$cnt > 0} { return }
        set legacy "mafia.db"
        if {![file exists $legacy]} { return }
        # SECURITY: this file used to be `source`d directly into the live
        # bot interpreter, which means anything capable of writing/replacing
        # "mafia.db" (a stray upload, a symlink, a bug elsewhere) could run
        # arbitrary Tcl with full bot privileges -- exec, socket, file I/O,
        # the works. Instead, run it inside a Tcl safe interpreter, which
        # has all dangerous commands (exec, file, socket, exit, load, etc.)
        # removed, and only pull out the two plain data arrays we expect.
        set si ""
        if {[catch {
            set si [interp create -safe]
            # `source` is one of the commands a -safe interpreter hides, so
            # sourcing from inside it always failed with "invalid command
            # name source" and no legacy save was ever migrated. Read the
            # file out here (trusted side, no evaluation) and evaluate its
            # contents inside the safe interpreter instead -- same sandbox,
            # minus the command that isn't there.
            set lf [open $legacy r]
            set legacy_code [read $lf]
            close $lf
            # A -safe interpreter removes dangerous COMMANDS, but it does not
            # bound execution: `while {1} {}` in a corrupt or hostile mafia.db
            # would hang Eggdrop's single-threaded event loop forever, with the
            # bot frozen mid-load and no way in. Cap both wall time and command
            # count so a malformed legacy save fails loudly instead of wedging
            # the bot. The caps are far above anything a real save needs (these
            # files are plain `array set` data).
            catch {interp limit $si time -seconds [expr {[clock seconds]+10}] -granularity 1}
            catch {interp limit $si command -value 5000000 -granularity 100}
            $si eval $legacy_code
            set legacy_players {}
            catch {set legacy_players [$si eval {array get ::mafia::__players}]}
            set legacy_prices {}
            catch {set legacy_prices [$si eval {array get ::mafia::__drugprices}]}
            interp delete $si
            set si ""
            if {[llength $legacy_players] > 0} { array set players $legacy_players }
            if {[llength $legacy_prices] > 0}  { array set drug_price_arr $legacy_prices }
        } err]} {
            if {$si ne ""} { catch {interp delete $si} }
            putlog "mafia.tcl: legacy flat-file migration failed: $err"
            return
        }
        if {[save_db 1]} {
            if {[catch {file rename -force $legacy "${legacy}.migrated"} err]} {
                putlog "mafia.tcl: legacy save migrated to SQLite, but could not rename $legacy: $err"
            } else {
                putlog "mafia.tcl: migrated legacy flat-file save ($legacy) into SQLite."
            }
        } else {
            # Do not destroy the only remaining legacy copy if the SQLite
            # transaction failed. A later restart can retry the migration.
            putlog "mafia.tcl: legacy migration was not finalized because the SQLite save failed; keeping $legacy."
        }
    }

}
# mafia_markets.tcl - drug market, gambling, fence/black market, and pimp
# market/operation systems.
namespace eval mafia {
    ##### =====================================================
    #####                 DRUG MARKET
    ##### =====================================================

    proc roll_drug_prices {} {
        variable drugs
        variable drug_price_arr
        array unset drug_price_arr
        foreach {name info} [array get drugs] {
            lassign $info base vol
            set swing [expr {int((rand()*2 - 1) * $vol)}]
            set price [expr {$base + $swing}]
            if {$price < 5} { set price 5 }
            set drug_price_arr($name) $price
        }
    }

    proc drug_price {name} {
        variable drug_price_arr
        if {[info exists drug_price_arr($name)]} { return $drug_price_arr($name) }
        return 50
    }

    # See blackmarket_timer_id in mafia_core.tcl: don't clobber a live
    # timer id on rehash, or the old timer can never be killed and leaks.
    variable drug_market_timer_id
    if {![info exists drug_market_timer_id]} { set drug_market_timer_id "" }

    proc drug_market_timer {{epoch ""}} {
        variable drug_market_timer_id
        variable drug_market_epoch
        if {$epoch ne "" && $epoch != $drug_market_epoch} { return }
        # Keep the timer chain alive even if a market roll unexpectedly fails.
        set drug_market_timer_id [utimer 900 [list ::mafia::drug_market_timer $drug_market_epoch]]
        if {[catch {roll_drug_prices} err]} {
            putlog "mafia.tcl: drug market timer error: $err"
        }
    }

    ##### ---------------- GAMBLING ---------------- #####
    # gamble_cooldown is set in Mafia.cfg -- see the note on
    # casino_collect_cooldown in the CONFIG section above.
    variable gamble_games
    array set gamble_games {
        dice  {49 2.0 "The dice come up in your favor."       "Craps out. House takes it."}
        slots {40 2.5 "Three cherries -- jackpot!"             "Two bars and a lemon. Better luck next pull."}
        cards {45 2.2 "You draw the winning hand."             "The dealer beats you by a nose."}
    }

    # Strict integer guard used on command input. Tcl integers are arbitrary
    # precision, so accepting an attacker-supplied million-digit integer can
    # turn a harmless command into a CPU/memory exhaustion primitive before the
    # normal numeric range check even runs.
    # Plain decimal only. [string is integer] also accepts 0x10 (16) and a
    # leading-zero 010, which expr then reads as OCTAL 8 -- "!mafia deposit
    # 010" deposited $8. Leading zeros, hex and +signs are refused.
    proc command_integer {value {max_digits 12}} {
        if {[string length $value] > $max_digits} { return 0 }
        if {![regexp {^-?(0|[1-9][0-9]*)$} $value]} { return 0 }
        return [string is integer -strict $value]
    }

    proc cmd_gamblegames {nick chan} {
        variable gamble_games
        game_msg $nick $chan "Games: [join [lsort [array names gamble_games]] {, }] -- ${mafia::cmd_prefix}mafia gamble <amount> <game>"
    }

    proc cmd_gamble {nick chan args} {
        if {![need_registered $nick $chan]} return
        normalize_player_economy $nick
        if {[blocked_state $nick $chan]} return
        variable players
        variable gamble_games
        variable gamble_cooldown
        set k [string tolower $nick]
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia gamble <amount> \[dice|slots|cards\] | prices | buy <tier> \[qty\] | collect | status"
            return
        }

        # Casino operation subcommands live under the same top-level command
        # as the quick-bet games, distinguished by name (no casino tier is
        # named dice/slots/cards, so there's no ambiguity with the bet game).
        set maybe_sub [string tolower [lindex $args 0]]
        switch -- $maybe_sub {
            prices  { cmd_casinoprices $nick $chan; return }
            buy     { cmd_casino_buy $nick $chan {*}[lrange $args 1 end]; return }
            collect -
            run     { cmd_casino_collect $nick $chan; return }
            status  -
            floors  { cmd_casino_status $nick $chan; return }
        }

        set amt [lindex $args 0]
        set game [string tolower [expr {[llength $args] > 1 ? [lindex $args 1] : "dice"}]]
        if {![info exists gamble_games($game)]} {
            game_msg $nick $chan "No such game. See ${mafia::cmd_prefix}mafia games"
            return
        }
        if {![command_integer $amt 12] || $amt < 10} {
            game_msg $nick $chan "$nick: minimum bet is [fmt_cash 10]."
            return
        }
        if {$amt > $players($k,cash)} {
            game_msg $nick $chan "$nick: you only have [fmt_cash $players($k,cash)] on hand."
            return
        }
        if {[info exists players($k,last_gamble)]} {
            set elapsed [expr {[now] - $players($k,last_gamble)}]
            if {$elapsed < $gamble_cooldown} {
                game_msg $nick $chan "$nick: the pit boss says slow down. [fmt_secs [expr {$gamble_cooldown - $elapsed}]] before your next bet."
                return
            }
        }
        set players($k,last_gamble) [now]
        lassign $gamble_games($game) win_pct payout win_msg lose_msg
        set roll [expr {int(rand()*100)}]
        if {$roll < $win_pct} {
            set winnings [expr {int($amt*$payout) - $amt}]
            set players($k,cash) [expr {$players($k,cash)+$winnings}]
            game_msg $nick $chan "$nick: $win_msg You bet [fmt_cash $amt] and walk away with +[fmt_cash $winnings]."
        } else {
            set players($k,cash) [expr {$players($k,cash)-$amt}]
            game_msg $nick $chan "$nick: $lose_msg You're out [fmt_cash $amt]."
        }
    }

    ##### ---------------- CASINO OPERATIONS (impl) ---------------- #####

    proc casino_label {tier} {
        return [string map {_ " "} $tier]
    }

    proc cmd_casinoprices {nick chan} {
        variable casino_tiers
        variable casino_tier_order
        set out {}
        foreach tier $casino_tier_order {
            lassign $casino_tiers($tier) cost payout
            lappend out "\002[casino_label $tier]\002: [fmt_cash $cost]"
        }
        game_msg $nick $chan "Casino floors -- [join $out { | }] -- ${mafia::cmd_prefix}mafia gamble buy <tier> \[qty\]"
    }

    proc cmd_casino_status {nick chan} {
        variable casino_tier_order
        set out {}
        foreach tier $casino_tier_order {
            lappend out "[casino_label $tier]:[peekf $nick casino,$tier 0]"
        }
        game_msg $nick $chan "$nick's casino holdings -- [join $out { | }]"
    }

    proc cmd_casino_buy {nick chan args} {
        variable casino_tiers
        variable players
        set k [string tolower $nick]
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia gamble buy <tier> \[qty\]"
            return
        }
        set tier [string tolower [lindex $args 0]]
        if {![info exists casino_tiers($tier)]} {
            game_msg $nick $chan "Unknown casino tier. Use ${mafia::cmd_prefix}mafia gamble prices."
            return
        }
        set qty [expr {[llength $args] > 1 ? [lindex $args 1] : 1}]
        if {![command_integer $qty 12] || $qty < 1 || $qty > 100000} {
            game_msg $nick $chan "$nick: quantity must be 1-100000."
            return
        }
        lassign $casino_tiers($tier) cost payout
        set econ_pct [player_bling_econ_pct $nick]
        set total [expr {int(round($cost*$qty * (1.0 - ($econ_pct/100.0))))}]
        if {$players($k,cash) < $total} {
            game_msg $nick $chan "$nick: you need [fmt_cash $total], you have [fmt_cash $players($k,cash)]."
            return
        }
        set players($k,cash) [expr {$players($k,cash)-$total}]
        # Same back-pay guard as the pimp market: restart the clock when a
        # tier goes from zero floors to some, so idle time before the buy
        # can't be cashed in as instant back-pay.
        if {[peekf $nick casino,$tier 0] <= 0} { set players($k,casino_last,$tier) [now] }
        incr players($k,casino,$tier) $qty
        if {![info exists players($k,casino_last,$tier)]} { set players($k,casino_last,$tier) [now] }
        if {$econ_pct > 0} {
            game_msg $nick $chan "$nick opens $qty [casino_label $tier](s) for [fmt_cash $total]. (bling discount: -${econ_pct}%)"
        } else {
            game_msg $nick $chan "$nick opens $qty [casino_label $tier](s) for [fmt_cash $total]."
        }
    }

    proc cmd_casino_collect {nick chan} {
        variable casino_tiers
        variable casino_tier_order
        variable casino_cycle_secs
        variable casino_collect_cooldown
        variable players
        set k [string tolower $nick]
        set collect_last [getf $nick casino_collect_last 0]
        set elapsed [expr {[now]-$collect_last}]
        if {$elapsed < $casino_collect_cooldown} {
            game_msg $nick $chan "$nick: the count isn't ready yet. [fmt_secs [expr {$casino_collect_cooldown-$elapsed}]] left."
            return
        }
        set players($k,casino_collect_last) [now]
        set econ_pct [player_bling_econ_pct $nick]
        # Legendary set collection bonus: +25% per piece held, so the full
        # four-piece set doubles every collection. Applied on top of the ice
        # economy bonus rather than folded into it, so the two read separately
        # in the payout message.
        set legend_pct [legend_collect_pct $nick]
        set legend_mult_c [legend_collect_mult $nick]
        set total 0
        # Guarded divisor -- see goods_value. Resolved once, then used for both
        # the cycle count and the clock advance so the two can never disagree.
        set cycle_secs [cfg_interval $casino_cycle_secs 900]
        foreach tier $casino_tier_order {
            set active [peekf $nick casino,$tier 0]
            if {$active < 1} {
                # Only touch the clock for a tier this player actually tracks.
                # Unconditionally stamping it CREATED a casino_last row for
                # every tier the player has never bought -- see peekf.
                if {[info exists players($k,casino_last,$tier)]} {
                    set players($k,casino_last,$tier) [now]
                }
                continue
            }
            set last [peekf $nick casino_last,$tier [now]]
            set cycles [expr {int(([now]-$last)/$cycle_secs)}]
            if {$cycles < 1} continue
            lassign $casino_tiers($tier) cost payout
            set earned_per [expr {max(1,int($payout*(1.0+($econ_pct/100.0))*$legend_mult_c))}]
            set total [expr {$total + ($active*$cycles*$earned_per)}]
            set players($k,casino_last,$tier) [expr {$last + ($cycles*$cycle_secs)}]
        }
        if {$total > 0} { incr players($k,cash) $total }
        set bling_note ""
        if {$econ_pct > 0} { append bling_note " (bling bonus: +${econ_pct}%)" }
        if {$legend_pct > 0} { append bling_note " (legendary set: +${legend_pct}%)" }
        if {$total == 0} {
            game_msg $nick $chan "$nick: no count is ready yet. Casino cycles run every 15m."
        } else {
            game_msg $nick $chan "$nick collects [fmt_cash $total] from the house.${bling_note}"
        }
    }

    ##### ---------------- FENCE / BLACK MARKET (impl) ---------------- #####

    proc maybe_drop_goods {nick cname} {
        variable fence_drop_table
        variable players
        if {![info exists fence_drop_table($cname)]} return
        lassign $fence_drop_table($cname) chance pool
        if {[expr {int(rand()*100)}] >= $chance} return
        set item [lindex $pool [expr {int(rand()*[llength $pool])}]]
        set k [string tolower $nick]
        if {![info exists players($k,goods,$item)]} { set players($k,goods,$item) 0 }
        if {$players($k,goods,$item) == 0} { set players($k,goods_ts,$item) [now] }
        incr players($k,goods,$item)
        variable fence_goods
        set disp [lindex $fence_goods($item) 0]
        return $disp
    }

    proc goods_value {nick item} {
        variable fence_goods
        variable goods_decay_interval
        variable goods_decay_pct
        variable goods_decay_floor
        variable players
        set k [string tolower $nick]
        set base [lindex $fence_goods($item) 1]
        set ts [expr {[info exists players($k,goods_ts,$item)] ? $players($k,goods_ts,$item) : [now]}]
        # Guarded divisor: a 0 in Mafia.cfg makes this "divide by zero", and
        # every fence/goods command then dies and rolls back permanently.
        set intervals [expr {int(([now]-$ts)/[cfg_interval $goods_decay_interval 3600])}]
        set mult [expr {max($goods_decay_floor, 1.0 - ($goods_decay_pct/100.0)*$intervals)}]
        return [expr {int($base*$mult)}]
    }

    proc fence_cut_for {nick} {
        variable fence_cut_by_rank
        variable players
        set k [string tolower $nick]
        set rank [rank_for_xp $players($k,xp)]
        foreach {r cut} $fence_cut_by_rank {
            if {$r eq $rank} { return $cut }
        }
        return 0.30
    }

    proc cmd_goods {nick chan} {
        if {![need_registered $nick $chan]} return
        variable fence_goods
        variable players
        set k [string tolower $nick]
        set out [list]
        foreach item [lsort [array names fence_goods]] {
            set qty [expr {[info exists players($k,goods,$item)] ? $players($k,goods,$item) : 0}]
            if {$qty > 0} {
                lappend out "$item x$qty (worth ~[fmt_cash [goods_value $nick $item]] ea)"
            }
        }
        if {[llength $out] == 0} {
            game_msg $nick $chan "$nick: you're not holding any hot goods right now."
        } else {
            game_msg $nick $chan "$nick's hot goods -- [join $out {, }]"
        }
    }

    proc cmd_fence {nick chan args} {
        if {![need_registered $nick $chan]} return
        normalize_player_economy $nick
        if {[blocked_state $nick $chan]} return
        variable fence_goods
        variable players
        set k [string tolower $nick]
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia fence <item> \[qty\] -- see ${mafia::cmd_prefix}mafia goods"
            return
        }
        set item [string tolower [lindex $args 0]]
        if {![info exists fence_goods($item)]} {
            game_msg $nick $chan "The fence doesn't want that. See ${mafia::cmd_prefix}mafia goods"
            return
        }
        set have [expr {[info exists players($k,goods,$item)] ? $players($k,goods,$item) : 0}]
        set qty [expr {[llength $args] > 1 ? [lindex $args 1] : $have}]
        if {![command_integer $qty 12] || $qty < 1} {
            game_msg $nick $chan "$nick: quantity must be a positive number."
            return
        }
        if {$qty > $have} {
            game_msg $nick $chan "$nick: you only have $have [lindex $fence_goods($item) 0]."
            return
        }
        set unit_val [goods_value $nick $item]
        set cut [fence_cut_for $nick]
        set payout [expr {int($unit_val*(1.0-$cut)*$qty)}]
        incr players($k,goods,$item) [expr {-$qty}]
        if {$players($k,goods,$item) <= 0} {
            set players($k,goods,$item) 0
            catch {unset players($k,goods_ts,$item)}
        }
        set players($k,cash) [expr {$players($k,cash)+$payout}]
        game_msg $nick $chan "$nick: the fence takes $qty [lindex $fence_goods($item) 0] off your hands for [fmt_cash $payout] (his cut: [expr {int($cut*100)}]%)."
    }

    proc roll_blackmarket_stock {} {
        variable blackmarket_pool
        variable blackmarket_stock
        variable blackmarket_size
        array unset blackmarket_stock
        set names [array names blackmarket_pool]
        set picked {}
        set n [expr {min($blackmarket_size,[llength $names])}]
        while {[llength $picked] < $n} {
            set cand [lindex $names [expr {int(rand()*[llength $names])}]]
            if {[lsearch -exact $picked $cand] < 0} { lappend picked $cand }
        }
        foreach item $picked {
            set base [lindex $blackmarket_pool($item) 1]
            set swing [expr {int($base*(rand()*0.3-0.15))}]
            set blackmarket_stock($item) [expr {$base+$swing}]
        }
    }

    proc blackmarket_timer {{epoch ""}} {
        variable blackmarket_timer_id
        variable blackmarket_epoch
        if {$epoch ne "" && $epoch != $blackmarket_epoch} { return }
        variable blackmarket_restock_secs
        set delay [expr {[string is integer -strict $blackmarket_restock_secs] && $blackmarket_restock_secs >= 1 ? $blackmarket_restock_secs : 900}]
        set blackmarket_timer_id [utimer $delay [list ::mafia::blackmarket_timer $blackmarket_epoch]]
        if {[catch {roll_blackmarket_stock} err]} {
            putlog "mafia.tcl: black market timer error: $err"
        }
    }

    proc start_blackmarket_timer {} {
        variable blackmarket_timer_id
        variable blackmarket_epoch
        incr blackmarket_epoch
        if {[info exists blackmarket_timer_id] && $blackmarket_timer_id ne "" && [llength [info commands killutimer]]} {
            catch {killutimer $blackmarket_timer_id}
        }
        set blackmarket_timer_id [utimer 5 [list ::mafia::blackmarket_timer $blackmarket_epoch]]
    }

    proc cmd_blackmarket {nick chan} {
        variable blackmarket_stock
        variable blackmarket_pool
        if {[array size blackmarket_stock] == 0} { roll_blackmarket_stock }
        set out [list]
        foreach item [array names blackmarket_stock] {
            set disp [lindex $blackmarket_pool($item) 0]
            set eff  [lindex $blackmarket_pool($item) 2]
            lappend out "$item: $disp - [fmt_cash $blackmarket_stock($item)] ($eff)"
        }
        game_msg $nick $chan "\002Black Market\002 (restocks periodically) -- [join $out {  |  }]"
    }

    proc cmd_blackbuy {nick chan args} {
        if {![need_registered $nick $chan]} return
        normalize_player_economy $nick
        variable blackmarket_stock
        variable blackmarket_pool
        variable players
        if {[array size blackmarket_stock] == 0} { roll_blackmarket_stock }
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia blackbuy <item> -- see ${mafia::cmd_prefix}mafia blackmarket"
            return
        }
        # Black market keys are single underscored tokens (emp_device, etc)
        # but players often type them with a space; try the joined form
        # first so e.g. "blackbuy emp device" resolves like "blackbuy emp_device".
        set joined [string tolower [join $args "_"]]
        if {[info exists blackmarket_stock($joined)]} {
            set item $joined
        } else {
            set item [string tolower [lindex $args 0]]
        }
        if {![info exists blackmarket_stock($item)]} {
            game_msg $nick $chan "Not on the black market right now. See ${mafia::cmd_prefix}mafia blackmarket"
            return
        }
        set k [string tolower $nick]
        set price $blackmarket_stock($item)
        if {$players($k,cash) < $price} {
            game_msg $nick $chan "$nick: you need [fmt_cash $price], you have [fmt_cash $players($k,cash)]."
            return
        }
        set players($k,cash) [expr {$players($k,cash)-$price}]
        if {![info exists players($k,bm,$item)]} { set players($k,bm,$item) 0 }
        incr players($k,bm,$item)
        game_msg $nick $chan "$nick: picked up a [lindex $blackmarket_pool($item) 0] off the black market for [fmt_cash $price]. ([lindex $blackmarket_pool($item) 2])"
        # Rare legendary find while shopping the back room. Rate-limited and
        # low-probability inside maybe_legend_drop; a no-op once the set is
        # complete.
        maybe_legend_drop $nick $chan
    }

    proc use_bm_item {nick item} {
        variable players
        set k [string tolower $nick]
        if {[info exists players($k,bm,$item)] && $players($k,bm,$item) > 0} {
            incr players($k,bm,$item) -1
            return 1
        }
        return 0
    }

    ##### ---------------- LEGENDARY DROPS (BLACK MARKET) ---------------- #####

    # Hands $nick one legendary piece and wires it into the ordinary gear
    # plumbing so it can be equipped/displayed like anything else. The
    # legend_<item> flag is the authority (normalize_player_economy repairs
    # the lists from it and refuses list entries without it), so it is set
    # first and the list entry second.
    proc grant_legend_piece {nick chan item} {
        variable players
        variable legend_order
        if {![is_legend_item $item]} { return 0 }
        set k [string tolower $nick]
        ensure_gear_lists $nick
        if {[info exists players($k,legend_$item)] && $players($k,legend_$item)} { return 0 }
        set players($k,legend_$item) 1
        set kind [legend_kind $item]
        set equipped_note ""
        switch -- $kind {
            weapon {
                if {[lsearch -exact $players($k,owned_weapons) $item] < 0} {
                    lappend players($k,owned_weapons) $item
                }
                if {[gear_upgrade_ok $nick $item weapon]} {
                    set players($k,weapon) $item
                    set equipped_note " -- equipped ([weapon_dmg $item $nick] dmg)"
                }
            }
            armor {
                if {[lsearch -exact $players($k,owned_armor) $item] < 0} {
                    lappend players($k,owned_armor) $item
                }
                if {[gear_upgrade_ok $nick $item armor]} {
                    set players($k,armor) $item
                    set equipped_note " -- equipped ([armor_reduce $item $nick] dmg reduction, [armor_evasion $item $nick]% evasion)"
                }
            }
            bling {
                if {[lsearch -exact $players($k,owned_bling) $item] < 0} {
                    lappend players($k,owned_bling) $item
                }
                if {[gear_upgrade_ok $nick $item bling bling]} {
                    set players($k,bling) $item
                    set equipped_note " -- equipped (+[format %.1f [bling_bonus_pct $item $nick]]% stats, +[bling_econ_pct $item $nick]% econ)"
                }
            }
            tool {
                give_item $nick $item
            }
        }
        set held [legend_pieces_owned $nick]
        game_msg $nick $chan "\002\00308*** LEGENDARY FIND ***\003\002 $nick turns up the \002[legend_name $item]\002 in the back of the black market${equipped_note}."
        game_msg $nick $chan "$nick: legendary set $held/4 -- +[legend_stat_pct $nick]% to all stats, +[legend_collect_pct $nick]% on pimp/casino/dealer collections. ${mafia::cmd_prefix}mafia legend for details."
        if {$held >= [llength $legend_order]} {
            game_msg $nick $chan "\002\00304$nick has assembled the COMPLETE legendary set.\003\002 Nothing in the game hits harder."
        }
        return 1
    }

    # Very rare legendary find, rolled when a player buys from the black
    # market. Two independent gates keep it rare and un-buyable:
    #   * one eligible roll per legend_roll_cooldown seconds, per player, so
    #     spamming cheap purchases cannot convert cash into rolls; and
    #   * legend_drop_pct on the roll itself.
    # The cooldown stamp is written whenever a roll is actually spent (win or
    # lose) and NOT when the player already holds all four, so a completed
    # set stops touching the row entirely. Level is irrelevant: a piece can
    # drop at any level and then scales with the holder (see legend_tier).
    proc maybe_legend_drop {nick chan} {
        variable players
        variable legend_order
        variable legend_drop_pct
        variable legend_roll_cooldown
        set k [string tolower $nick]
        if {![info exists players($k,cash)]} { return "" }

        set missing {}
        foreach item $legend_order {
            if {![info exists players($k,legend_$item)] || !$players($k,legend_$item)} {
                lappend missing $item
            }
        }
        if {![llength $missing]} { return "" }

        set pct $legend_drop_pct
        if {![string is double -strict $pct] || $pct <= 0} { return "" }
        if {$pct > 100} { set pct 100 }
        set cd $legend_roll_cooldown
        if {![string is integer -strict $cd] || $cd < 0} { set cd 600 }

        set last 0
        if {[info exists players($k,legend_roll_last)] &&
            [string is integer -strict $players($k,legend_roll_last)]} {
            set last $players($k,legend_roll_last)
        }
        if {[now] - $last < $cd} { return "" }
        set players($k,legend_roll_last) [now]

        # Basis points rather than percent, so a fractional legend_drop_pct
        # (0.5, say) is honoured instead of truncating to zero.
        if {int(rand()*10000) >= int(round($pct*100))} { return "" }
        set item [lindex $missing [expr {int(rand()*[llength $missing])}]]
        grant_legend_piece $nick $chan $item
        return $item
    }

    proc cmd_legend {nick chan} {
        if {![need_registered $nick $chan]} return
        variable players
        variable legend_order
        set k [string tolower $nick]
        set held [legend_pieces_owned $nick]
        set out {}
        foreach item $legend_order {
            set have [expr {[info exists players($k,legend_$item)] && $players($k,legend_$item)}]
            lappend out "[legend_name $item] ([legend_kind $item]): [expr {$have ? "\002HELD\002" : "missing"}]"
        }
        game_msg $nick $chan "\002Legendary set\002 ($held/4) -- [join $out { | }]"
        if {$held > 0} {
            game_msg $nick $chan "$nick: set bonus +[legend_stat_pct $nick]% to all four core stats, +[legend_collect_pct $nick]% on pimp/casino/dealer collections. Tier [legend_tier $nick] scaling (Lv.[player_level $nick]): weapon [legend_weapon_dmg $nick] dmg | armor [legend_armor_reduce $nick] reduction, [legend_armor_evasion $nick]% evasion | ice +[format %.1f [legend_bling_bonus_pct $nick]]% stats, +[legend_bling_econ_pct $nick]% econ."
        }
        game_msg $nick $chan "Legendary pieces are never sold and never dropped by a boss -- they turn up rarely while trading on the black market (${mafia::cmd_prefix}mafia blackbuy), at any level, and their stats re-scale as you level."
    }

    # Same reload-safety fix as start_autosave_timer above.
    proc start_drug_market_timer {} {
        variable drug_market_timer_id
        variable drug_market_epoch
        incr drug_market_epoch
        if {$drug_market_timer_id ne "" && [llength [info commands killutimer]]} {
            catch {killutimer $drug_market_timer_id}
        }
        drug_market_timer $drug_market_epoch
    }

    ##### =====================================================
    #####                 PIMP MARKET / OPERATION
    ##### =====================================================

    proc roll_pimp_prices {} {
        variable pimp_workers
        variable pimp_price_arr
        array unset pimp_price_arr
        foreach {tier info} [array get pimp_workers] {
            lassign $info base vol payout bust jail
            set swing [expr {int((rand()*2 - 1) * $vol)}]
            set price [expr {$base + int($base*$swing/100.0)}]
            if {$price < 100} { set price 100 }
            set pimp_price_arr($tier) $price
        }
    }

    proc pimp_price {tier} {
        variable pimp_price_arr
        if {[info exists pimp_price_arr($tier)]} { return $pimp_price_arr($tier) }
        variable pimp_workers
        if {[info exists pimp_workers($tier)]} { return [lindex $pimp_workers($tier) 0] }
        return 0
    }

    proc pimp_label {tier} {
        return [string map {_ " "} $tier]
    }

    proc pimp_release_jail {nick tier} {
        variable players
        set k [string tolower $nick]
        set until [getf $nick pimp_jail_until,$tier 0]
        if {$until > 0 && $until <= [now]} {
            set jailed [getf $nick pimp_jail,$tier 0]
            if {$jailed > 0} {
                incr players($k,pimp,$tier) $jailed
            }
            set players($k,pimp_jail,$tier) 0
            set players($k,pimp_jail_until,$tier) 0
        }
    }

    # $bust_chance is a PERCENTAGE and is deliberately allowed to be
    # fractional: the callers scale the table's bust_chance by 1/8 per cycle,
    # and the street pimp tiers are all bust_chance 1, i.e. 0.125% per
    # worker-cycle. The small-n loop used to roll `int(rand()*100) <
    # $bust_chance`, which compares an integer 0-99 against that fraction --
    # only a roll of exactly 0 could ever be below 0.125, turning a 0.125%
    # risk into a flat 1%, and the callers' own int() truncation flattened
    # every real chance to 0 before it even got here. Between them, NOTHING in
    # the game could ever be busted: pimp_jail/dealer_jail, the release
    # helpers, the "jail:N" roster column, `pimp replace`, and the "(no bust
    # risk)" tag that distinguishes the special tiers were all unreachable
    # code. Compare against the unrounded percentage instead, so the roll is
    # the probability the tables actually specify.
    proc pimp_bust_count {active cycles bust_chance} {
        # Never iterate once per worker: a player can own up to 100,000 workers,
        # so a naive per-worker roll would let one command consume millions of
        # CPU operations and stall the Eggdrop event loop. Aggregate the rolls.
        if {![string is double -strict $bust_chance]} { return 0 }
        if {$active <= 0 || $cycles <= 0 || $bust_chance <= 0} { return 0 }
        if {$bust_chance >= 100} { return $active }
        set n [expr {$active * $cycles}]
        set p [expr {$bust_chance / 100.0}]
        if {$n <= 500} {
            set busted 0
            for {set i 0} {$i < $n} {incr i} {
                if {rand()*100 < $bust_chance} { incr busted }
            }
            return [expr {min($active,$busted)}]
        }
        # Normal approximation to Binomial(n,p), with continuity noise.
        set mean [expr {$n*$p}]
        set variance [expr {$n*$p*(1.0-$p)}]
        set u1 [expr {max(1.0e-12,rand())}]
        set u2 [expr {rand()}]
        set z [expr {sqrt(-2.0*log($u1))*cos(6.283185307179586*$u2)}]
        set busted [expr {int($mean + $z*sqrt($variance) + 0.5)}]
        if {$busted < 0} { set busted 0 }
        if {$busted > $active} { set busted $active }
        return $busted
    }

    proc cmd_pimpprices {nick chan} {
        variable pimp_worker_order
        variable pimp_special_workers
        set out {}
        foreach tier $pimp_worker_order {
            set tag [expr {[lsearch -exact $pimp_special_workers $tier] >= 0 ? " (no bust risk)" : ""}]
            lappend out "[pimp_label $tier]: [fmt_cash [pimp_price $tier]]$tag"
        }
        game_msg $nick $chan "\002Pimp market\002 -- [join $out { | }] (fluctuates every 15m)"
    }

    proc cmd_pimp {nick chan args} {
        if {![need_registered $nick $chan]} return
        normalize_player_economy $nick
        if {[blocked_state $nick $chan]} return
        variable pimp_workers
        variable players
        variable pimp_cycle_secs
        set k [string tolower $nick]
        set sub [expr {[llength $args] ? [string tolower [lindex $args 0]] : "prices"}]

        if {$sub eq "prices"} { cmd_pimpprices $nick $chan; return }

        if {$sub eq "workers" || $sub eq "status"} {
            variable pimp_worker_order
            variable pimp_special_workers
            set out {}
            foreach tier $pimp_worker_order {
                pimp_release_jail $nick $tier
                set active [getf $nick pimp,$tier 0]
                set jtxt ""
                if {[lsearch -exact $pimp_special_workers $tier] < 0} {
                    set jailed [getf $nick pimp_jail,$tier 0]
                    set jtxt [expr {$jailed > 0 ? " jail:$jailed" : ""}]
                }
                lappend out "[pimp_label $tier]:$active$jtxt"
            }
            game_msg $nick $chan "$nick's pimp roster -- [join $out { | }]"
            return
        }

        if {$sub eq "buy" || $sub eq "hire"} {
            if {[llength $args] < 2} {
                game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia pimp buy <celebrity|escort|hooker|street_corner|crack_ho|financier|silent_partner> \[qty\]"
                return
            }
            # Support both:
            #   !mafia pimp buy crack ho 5
            #   !mafia pimp buy 5 crack ho
            # Pimp tiers may contain spaces, so never parse the tier as one word.
            set buyargs [lrange $args 1 end]
            set qty 1

            # Trailing quantity
            if {[llength $buyargs] > 1 && [string is integer -strict [lindex $buyargs end]]} {
                set qty [lindex $buyargs end]
                set buyargs [lrange $buyargs 0 end-1]
            }

            # Leading quantity
            if {[llength $buyargs] > 1 && [string is integer -strict [lindex $buyargs 0]]} {
                set qty [lindex $buyargs 0]
                set buyargs [lrange $buyargs 1 end]
            }

            # Preserve multi-word pimp tiers and normalize input.
            set tier [string tolower [string trim [join $buyargs " "]]]

            # Accept display-style spaces for internal underscore tier names.
            if {![info exists pimp_workers($tier)]} {
                set tier_key [string map {" " "_"} $tier]
                if {[info exists pimp_workers($tier_key)]} {
                    set tier $tier_key
                }
            }

            if {![info exists pimp_workers($tier)]} {
                game_msg $nick $chan "Unknown tier. Use ${mafia::cmd_prefix}mafia pimp prices."
                return
            }
            if {![command_integer $qty 12] || $qty < 1 || $qty > 100000} {
                game_msg $nick $chan "$nick: quantity must be 1-100000."
                return
            }
            set price [pimp_price $tier]
            set base_total [expr {$price*$qty}]
            set econ_pct [player_bling_econ_pct $nick]
            set total [expr {int(round($base_total * (1.0 - ($econ_pct/100.0))))}]
            if {$total < 0 || $players($k,cash) < $total} {
                game_msg $nick $chan "$nick: you need [fmt_cash $total], you have [fmt_cash $players($k,cash)]."
                return
            }
            set players($k,cash) [expr {$players($k,cash)-$total}]
            # Restart the payout clock when a tier goes from no active workers
            # to some. pimp_last keeps ticking while a tier sits empty, so
            # without this a player could register, wait weeks, hire workers
            # and immediately collect weeks of back-pay for workers who were
            # never on the street.
            if {[getf $nick pimp,$tier 0] <= 0} { set players($k,pimp_last,$tier) [now] }
            incr players($k,pimp,$tier) $qty
            if {![info exists players($k,pimp_last,$tier)]} { set players($k,pimp_last,$tier) [now] }
            if {$econ_pct > 0} {
                game_msg $nick $chan "$nick hires $qty [pimp_label $tier](s) for [fmt_cash $total]. (bling discount: -${econ_pct}%)"
            } else {
                game_msg $nick $chan "$nick hires $qty [pimp_label $tier](s) for [fmt_cash $total]."
            }
            return
        }

        # "pimp replace" is gone. It was a second, word-for-word copy of the
        # buy path above -- same price lookup, same bling discount, same
        # back-pay guard, same `incr players($k,pimp,$tier)` -- differing only
        # in printing "hires N replacement hooker(s)" instead of "hires N
        # hooker(s)". Busted workers are not consumed (they sit in pimp_jail
        # until pimp_release_jail returns them), so there was never anything
        # for a "replace" to replace: it just bought more workers under a
        # second name, in duplicated code that had to be kept in sync with buy
        # by hand. Use "pimp buy <tier> [qty]".

        if {$sub eq "sell" || $sub eq "fire"} {
            if {[llength $args] < 2} {
                game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia pimp sell <celebrity|escort|hooker|street_corner|crack_ho|financier|silent_partner> \[qty\]"
                return
            }
            # Same tier/qty parsing as "pimp buy" -- tiers may contain
            # spaces, and qty may come before or after the tier words.
            set sellargs [lrange $args 1 end]
            set qty 1

            if {[llength $sellargs] > 1 && [string is integer -strict [lindex $sellargs end]]} {
                set qty [lindex $sellargs end]
                set sellargs [lrange $sellargs 0 end-1]
            }
            if {[llength $sellargs] > 1 && [string is integer -strict [lindex $sellargs 0]]} {
                set qty [lindex $sellargs 0]
                set sellargs [lrange $sellargs 1 end]
            }

            set tier [string tolower [string trim [join $sellargs " "]]]
            if {![info exists pimp_workers($tier)]} {
                set tier_key [string map {" " "_"} $tier]
                if {[info exists pimp_workers($tier_key)]} {
                    set tier $tier_key
                }
            }
            if {![info exists pimp_workers($tier)]} {
                game_msg $nick $chan "Unknown tier. Use ${mafia::cmd_prefix}mafia pimp prices."
                return
            }
            if {![command_integer $qty 12] || $qty < 1 || $qty > 100000} {
                game_msg $nick $chan "$nick: quantity must be 1-100000."
                return
            }
            pimp_release_jail $nick $tier
            set active [getf $nick pimp,$tier 0]
            if {$active < 1} {
                game_msg $nick $chan "$nick: no active [pimp_label $tier](s) to sell. (Jailed workers can't be sold.)"
                return
            }
            if {$qty > $active} { set qty $active }
            variable shop_resale_pct
            set price [pimp_price $tier]
            set total [expr {int(round($price*$qty*($shop_resale_pct/100.0)))}]
            incr players($k,pimp,$tier) [expr {-$qty}]
            incr players($k,cash) $total
            game_msg $nick $chan "$nick sells $qty [pimp_label $tier](s) for [fmt_cash $total]. (${shop_resale_pct}% resale)"
            return
        }

        if {$sub eq "collect" || $sub eq "run"} {
            variable pimp_collect_cooldown
            set collect_last [getf $nick pimp_collect_last 0]
            set elapsed [expr {[now]-$collect_last}]
            if {$elapsed < $pimp_collect_cooldown} {
                game_msg $nick $chan "$nick: the operation isn't ready for another pickup. [fmt_secs [expr {$pimp_collect_cooldown-$elapsed}]] left."
                return
            }
            set players($k,pimp_collect_last) [now]
            set total 0
            set busts 0
            set econ_pct [player_bling_econ_pct $nick]
            # See cmd_casino_collect: legendary set collection bonus.
            set legend_pct [legend_collect_pct $nick]
            set legend_mult_c [legend_collect_mult $nick]
            variable pimp_worker_order
            # Guarded divisor -- see goods_value/cmd_casino_collect.
            set cycle_secs [cfg_interval $pimp_cycle_secs 900]
            foreach tier $pimp_worker_order {
                pimp_release_jail $nick $tier
                set active [getf $nick pimp,$tier 0]
                if {$active < 1} {
                    # Nobody working this tier (all busted, or none hired):
                    # advance the clock so idle time can't be collected later
                    # as back-pay once workers are hired or released.
                    set players($k,pimp_last,$tier) [now]
                    continue
                }
                set last [getf $nick pimp_last,$tier [now]]
                set cycles [expr {int(([now]-$last)/$cycle_secs)}]
                if {$cycles < 1} continue
                lassign $pimp_workers($tier) base vol payout bust jail
                set rate [expr {double([pimp_price $tier])/$base}]
                set earned_per [expr {max(1,int($payout*$rate*(1.0+($econ_pct/100.0))*$legend_mult_c))}]
                # Earnings are calculated before bust rolls, matching the risk/reward
                # feel of the drug market while keeping the economy predictable.
                set total [expr {$total + ($active*$cycles*$earned_per)}]
                # No int(): the tables' bust_chance divided by 8 is a fraction
                # for every tier in the game, and truncating it to a whole
                # number made every bust chance exactly 0 -- see
                # pimp_bust_count.
                set bustchance [expr {max(0.0,($bust / 8.0)-[catch_mod $nick])}]
                set busted [pimp_bust_count $active $cycles $bustchance]
                if {$busted > 0} {
                    incr players($k,pimp,$tier) [expr {-$busted}]
                    if {$players($k,pimp,$tier) < 0} { set players($k,pimp,$tier) 0 }
                    incr players($k,pimp_jail,$tier) $busted
                    set new_until [expr {[now]+($jail*60)}]
                    if {[peekf $nick pimp_jail_until,$tier 0] < $new_until} {
                        set players($k,pimp_jail_until,$tier) $new_until
                    }
                    incr busts $busted
                }
                set players($k,pimp_last,$tier) [expr {$last + ($cycles*$cycle_secs)}]
            }
            if {$total > 0} { incr players($k,cash) $total }
            set bling_note ""
            if {$econ_pct > 0} { append bling_note " (bling bonus: +${econ_pct}%)" }
            if {$legend_pct > 0} { append bling_note " (legendary set: +${legend_pct}%)" }
            if {$total == 0 && $busts == 0} {
                game_msg $nick $chan "$nick: no payout is ready yet. Pimp cycles run every 15m."
            } elseif {$busts > 0} {
                game_msg $nick $chan "$nick collects [fmt_cash $total]${bling_note}. $busts worker(s) got busted and are in jail; wait for release or hire more with ${mafia::cmd_prefix}mafia pimp buy."
            } else {
                game_msg $nick $chan "$nick collects [fmt_cash $total] from the operation.${bling_note}"
            }
            return
        }

        game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia pimp prices | buy <tier> \[qty\] | sell <tier> \[qty\] | collect | workers"
    }

    proc pimp_market_timer {{epoch ""}} {
        variable pimp_market_timer_id
        variable pimp_market_epoch
        if {$epoch ne "" && $epoch != $pimp_market_epoch} { return }
        set pimp_market_timer_id [utimer 900 [list ::mafia::pimp_market_timer $pimp_market_epoch]]
        if {[catch {roll_pimp_prices} err]} {
            putlog "mafia.tcl: pimp market timer error: $err"
        }
    }

    proc start_pimp_market_timer {} {
        variable pimp_market_timer_id
        variable pimp_market_epoch
        incr pimp_market_epoch
        if {$pimp_market_timer_id ne "" && [llength [info commands killutimer]]} {
            catch {killutimer $pimp_market_timer_id}
        }
        pimp_market_timer $pimp_market_epoch
    }

    ##### ---------------- DRUG DEALER OPERATIONS (impl) ---------------- #####
    # Passive-income distribution network. Structurally identical to the
    # pimp market (buy -> supply/idle -> collect on a timer, with bust risk
    # busting active dealers into dealer jail), except dealers additionally
    # need product in stock (bought via !mafia drug supply) before a collect
    # cycle pays out anything.

    proc dealer_label {tier} {
        return [string map {_ " "} $tier]
    }

    proc dealer_release_jail {nick tier} {
        variable players
        set k [string tolower $nick]
        set until [peekf $nick dealer_jail_until,$tier 0]
        if {$until > 0 && $until <= [now]} {
            set jailed [peekf $nick dealer_jail,$tier 0]
            if {$jailed > 0} { incr players($k,dealer,$tier) $jailed }
            set players($k,dealer_jail,$tier) 0
            set players($k,dealer_jail_until,$tier) 0
        }
    }

    proc cmd_dealerprices {nick chan} {
        variable dealer_tiers
        variable dealer_tier_order
        set out {}
        foreach tier $dealer_tier_order {
            lassign $dealer_tiers($tier) cost cap payout bust jail supply_cost
            lappend out "\002[dealer_label $tier]\002: [fmt_cash $cost] (supply: [fmt_cash $supply_cost]/unit)"
        }
        game_msg $nick $chan "Dealer roster -- [join $out { | }] -- ${mafia::cmd_prefix}mafia drug dealer buy <tier> \[qty\] | remove <tier> \[qty|all\]"
    }

    proc cmd_dealer_status {nick chan} {
        variable dealer_tier_order
        set out {}
        foreach tier $dealer_tier_order {
            dealer_release_jail $nick $tier
            set active [peekf $nick dealer,$tier 0]
            set jailed [peekf $nick dealer_jail,$tier 0]
            set supply [peekf $nick dealer_supply,$tier 0]
            set jtxt [expr {$jailed > 0 ? " jail:$jailed" : ""}]
            lappend out "[dealer_label $tier]:$active$jtxt supply:$supply"
        }
        game_msg $nick $chan "$nick's dealer network -- [join $out { | }]"
    }

    proc cmd_dealer_buy {nick chan args} {
        variable dealer_tiers
        variable players
        set k [string tolower $nick]
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia drug dealer buy <tier> \[qty\]"
            return
        }
        set tier [string tolower [lindex $args 0]]
        if {![info exists dealer_tiers($tier)]} {
            game_msg $nick $chan "Unknown dealer tier. Use ${mafia::cmd_prefix}mafia drug dealer prices."
            return
        }
        set qty [expr {[llength $args] > 1 ? [lindex $args 1] : 1}]
        if {![command_integer $qty 12] || $qty < 1 || $qty > 100000} {
            game_msg $nick $chan "$nick: quantity must be 1-100000."
            return
        }
        lassign $dealer_tiers($tier) cost cap payout bust jail supply_cost
        set econ_pct [player_bling_econ_pct $nick]
        set total [expr {int(round($cost*$qty * (1.0 - ($econ_pct/100.0))))}]
        if {$players($k,cash) < $total} {
            game_msg $nick $chan "$nick: you need [fmt_cash $total], you have [fmt_cash $players($k,cash)]."
            return
        }
        set players($k,cash) [expr {$players($k,cash)-$total}]
        if {[peekf $nick dealer,$tier 0] <= 0} { set players($k,dealer_last,$tier) [now] }
        incr players($k,dealer,$tier) $qty
        if {![info exists players($k,dealer_last,$tier)]} { set players($k,dealer_last,$tier) [now] }
        if {$econ_pct > 0} {
            game_msg $nick $chan "$nick puts $qty [dealer_label $tier](s) on the street for [fmt_cash $total]. (bling discount: -${econ_pct}%)"
        } else {
            game_msg $nick $chan "$nick puts $qty [dealer_label $tier](s) on the street for [fmt_cash $total]."
        }
        game_msg $nick $chan "Remember to stock them: ${mafia::cmd_prefix}mafia drug supply $tier <qty>."
    }

    proc cmd_dealer_remove {nick chan args} {
        variable dealer_tiers
        variable dealer_refund_pct
        variable players
        set k [string tolower $nick]
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia drug dealer remove <tier> \[qty|all\]"
            return
        }
        set tier [string tolower [lindex $args 0]]
        if {![info exists dealer_tiers($tier)]} {
            game_msg $nick $chan "Unknown dealer tier. Use ${mafia::cmd_prefix}mafia drug dealer prices."
            return
        }
        # Only active (non-jailed) dealers can be let go on purpose -- a
        # busted dealer sitting in dealer jail isn't yours to dismiss until
        # they're released (or you can just wait/replace, per cmd_dealer_buy).
        dealer_release_jail $nick $tier
        set active [peekf $nick dealer,$tier 0]
        if {$active < 1} {
            game_msg $nick $chan "$nick: no active [dealer_label $tier] to let go."
            return
        }
        set qtyarg [expr {[llength $args] > 1 ? [lindex $args 1] : "all"}]
        if {[string tolower $qtyarg] eq "all"} {
            set qty $active
        } else {
            if {![command_integer $qtyarg 12] || $qtyarg < 1} {
                game_msg $nick $chan "$nick: quantity must be a positive number or 'all'."
                return
            }
            set qty [expr {min($qtyarg,$active)}]
        }
        lassign $dealer_tiers($tier) cost cap payout bust jail supply_cost
        set refund [expr {int($cost*$qty*($dealer_refund_pct/100.0))}]
        incr players($k,dealer,$tier) [expr {-$qty}]
        if {$players($k,dealer,$tier) < 1} {
            # Nobody left working the tier: stop the payout clock the same
            # way the buy path starts it, so a later re-buy can't collect
            # idle back-pay for the gap while the tier sat empty.
            set players($k,dealer,$tier) 0
            set players($k,dealer_last,$tier) [now]
        }
        if {$refund > 0} { incr players($k,cash) $refund }
        game_msg $nick $chan "$nick lets $qty [dealer_label $tier](s) go and recoups [fmt_cash $refund] (${dealer_refund_pct}% of cost)."
    }

    proc cmd_drug_supply {nick chan args} {
        variable dealer_tiers
        variable players
        set k [string tolower $nick]
        if {[llength $args] < 2} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia drug supply <tier> <qty>"
            return
        }
        set tier [string tolower [lindex $args 0]]
        if {![info exists dealer_tiers($tier)]} {
            game_msg $nick $chan "Unknown dealer tier. Use ${mafia::cmd_prefix}mafia drug dealer prices."
            return
        }
        set qty [lindex $args 1]
        if {![command_integer $qty 12] || $qty < 1} {
            game_msg $nick $chan "$nick: quantity must be a positive number."
            return
        }
        if {$qty > 1000000} { game_msg $nick $chan "$nick: max 1000000 per supply run."; return }
        lassign $dealer_tiers($tier) cost cap payout bust jail supply_cost
        set econ_pct [player_bling_econ_pct $nick]
        set total [expr {int(round($supply_cost*$qty * (1.0 - ($econ_pct/100.0))))}]
        if {$players($k,cash) < $total} {
            game_msg $nick $chan "$nick: you need [fmt_cash $total], you have [fmt_cash $players($k,cash)]."
            return
        }
        set players($k,cash) [expr {$players($k,cash)-$total}]
        incr players($k,dealer_supply,$tier) $qty
        if {$econ_pct > 0} {
            game_msg $nick $chan "$nick stocks [dealer_label $tier] with $qty units for [fmt_cash $total]. (bling discount: -${econ_pct}%)"
        } else {
            game_msg $nick $chan "$nick stocks [dealer_label $tier] with $qty units for [fmt_cash $total]."
        }
    }

    proc cmd_drug_collect {nick chan} {
        variable dealer_tiers
        variable dealer_tier_order
        variable dealer_cycle_secs
        variable dealer_collect_cooldown
        variable players
        set k [string tolower $nick]
        set collect_last [getf $nick dealer_collect_last 0]
        set elapsed [expr {[now]-$collect_last}]
        if {$elapsed < $dealer_collect_cooldown} {
            game_msg $nick $chan "$nick: the network isn't ready for another pickup. [fmt_secs [expr {$dealer_collect_cooldown-$elapsed}]] left."
            return
        }
        set players($k,dealer_collect_last) [now]
        set total 0
        set busts 0
        set short 0
        set econ_pct [player_bling_econ_pct $nick]
        # See cmd_casino_collect: legendary set collection bonus.
        set legend_pct [legend_collect_pct $nick]
        set legend_mult_c [legend_collect_mult $nick]
        # Guarded divisor -- see goods_value/cmd_casino_collect.
        set cycle_secs [cfg_interval $dealer_cycle_secs 900]
        foreach tier $dealer_tier_order {
            dealer_release_jail $nick $tier
            set active [peekf $nick dealer,$tier 0]
            if {$active < 1} {
                # See cmd_casino_collect: do not create a clock row for a tier
                # the player has never bought into.
                if {[info exists players($k,dealer_last,$tier)]} {
                    set players($k,dealer_last,$tier) [now]
                }
                continue
            }
            set last [peekf $nick dealer_last,$tier [now]]
            set cycles [expr {int(([now]-$last)/$cycle_secs)}]
            if {$cycles < 1} continue
            lassign $dealer_tiers($tier) cost cap payout bust jail supply_cost
            set demand [expr {$active*$cap*$cycles}]
            set supply [peekf $nick dealer_supply,$tier 0]
            set used [expr {min($demand,$supply)}]
            if {$used < $demand} { incr short }
            if {$used > 0} {
                incr players($k,dealer_supply,$tier) [expr {-$used}]
                set earned [expr {max(1,int($used*$payout*(1.0+($econ_pct/100.0))*$legend_mult_c))}]
                set total [expr {$total+$earned}]
            }
            # Bust risk applies to dealers actively moving product, matching
            # the pimp market's risk/reward feel; supply is deducted before
            # bust rolls, same ordering as pimp payout-then-bust.
            # Fractional, same as the pimp collect path -- see pimp_bust_count.
            set bustchance [expr {max(0.0,($bust / 8.0)-[catch_mod $nick])}]
            set busted [pimp_bust_count $active $cycles $bustchance]
            if {$busted > 0} {
                incr players($k,dealer,$tier) [expr {-$busted}]
                if {$players($k,dealer,$tier) < 0} { set players($k,dealer,$tier) 0 }
                incr players($k,dealer_jail,$tier) $busted
                set new_until [expr {[now]+($jail*60)}]
                if {[peekf $nick dealer_jail_until,$tier 0] < $new_until} {
                    set players($k,dealer_jail_until,$tier) $new_until
                }
                incr busts $busted
            }
            set players($k,dealer_last,$tier) [expr {$last + ($cycles*$cycle_secs)}]
        }
        if {$total > 0} { incr players($k,cash) $total }
        set bling_note ""
        if {$econ_pct > 0} { append bling_note " (bling bonus: +${econ_pct}%)" }
        if {$legend_pct > 0} { append bling_note " (legendary set: +${legend_pct}%)" }
        set notes {}
        if {$busts > 0} { lappend notes "$busts dealer(s) got busted and are in dealer jail; wait for release or buy replacements" }
        if {$short > 0} { lappend notes "some dealers ran dry -- restock with ${mafia::cmd_prefix}mafia drug supply <tier> <qty>" }
        if {$total == 0 && $busts == 0} {
            game_msg $nick $chan "$nick: no payout is ready yet. Dealer cycles run every 15m and need supply in stock."
        } else {
            set extra [expr {[llength $notes] ? " ([join $notes {; }])" : ""}]
            game_msg $nick $chan "$nick collects [fmt_cash $total] from the network.${bling_note}${extra}"
        }
    }

}
# mafia_dispatch.tcl - timed-state cleanup helpers and the top-level
# !mafia / !mafiahelp command dispatcher.
namespace eval mafia {
    ##### =====================================================
    #####                 TIMED STATE CLEANUP (game_gen pattern)
    ##### =====================================================
    # jail/hospital/hide expiry are checked lazily via time_left, so no
    # dedicated callback timers are required per-player for those. Random
    # encounters are the one exception: each fired encounter is stamped
    # with the current game_gen and carries its own utimer, scoped to the
    # channel rather than any player (see fire_encounter / clear_chan_encounter
    # / encounter_timeout in mafia_encounters.tcl). Because that state lives
    # outside players(), it is untouched by state_snapshot/state_restore.

    ##### =====================================================
    #####                 COMMAND DISPATCH
    ##### =====================================================
    # Eggdrop's `bind pub` fires on an exact "!command" string and passes
    # everything typed after it as $text, already split-ready. Each raw_*
    # proc is the direct bind target; it checks the channel gate, splits
    # $text into args, and calls the matching cmd_* implementation.

    # chan is a whitespace-separated LIST of channels; empty means every
    # channel the bot is on. A single "#channel" is a one-element list, so an
    # existing single-channel setting behaves exactly as it always did --
    # this only adds the multi-channel case, which used to match nothing at
    # all (the old string compare tested the whole setting against one
    # channel name, so "#one #two" was never equal to either).
    #
    # Split on whitespace with regexp rather than treating the setting as a
    # Tcl list: IRC permits curly braces inside channel names, and a name
    # carrying an unpaired one would make llength/foreach throw an
    # unmatched-brace error instead of simply failing to match.
    proc chan_ok {c} {
        variable chan
        set allowed [regexp -all -inline {\S+} $chan]
        if {[llength $allowed] == 0} { return 1 }
        set c [string tolower $c]
        foreach entry $allowed {
            if {$c eq [string tolower $entry]} { return 1 }
        }
        return 0
    }

    # Pass 10: command-level state transaction.
    #
    # Public commands mutate the in-memory player arrays first and are
    # checkpointed to SQLite afterward.  A Tcl error between two mutations
    # used to leave a half-applied command in memory until the next save.
    # Snapshot all mutable game arrays before dispatch and restore them on
    # ANY command or persistence error.  This is intentionally broader than
    # a per-player snapshot because rob/attack can mutate a second player and
    # market commands can mutate shared state.
    # With persistence enabled the DATABASE is the rollback point, and no
    # in-memory copy is taken at all.
    #
    # save_db commits at the end of every successful command, so the last
    # committed row set is exactly the pre-command state -- the same thing the
    # in-memory snapshot held. Taking that snapshot cost [array get players] on
    # EVERY command whether or not anything went wrong: 274 list elements for
    # one player, 27,400 at a hundred, 137,000 at five hundred, allocated and
    # thrown away on every command purely so a rare error path had something
    # to restore. Now the happy path costs nothing and the error path pays a
    # single read.
    #
    # The in-memory snapshot is still used when the bot is running WITHOUT
    # persistence (init_db failed), because then there is no other rollback
    # source. Both forms are tagged so state_restore knows which it has.
    proc state_snapshot {} {
        variable db_ready
        if {$db_ready} { return [list db] }
        variable players
        variable drug_price_arr
        variable pimp_price_arr
        variable blackmarket_stock
        return [list mem \
            [array get players] \
            [array get drug_price_arr] \
            [array get pimp_price_arr] \
            [array get blackmarket_stock]]
    }

    proc state_restore {snapshot} {
        variable players
        variable drug_price_arr
        variable pimp_price_arr
        variable blackmarket_stock

        switch -- [lindex $snapshot 0] {
            db  { return [state_restore_from_db] }
            mem {
                if {[llength $snapshot] != 5} {
                    return -code error "invalid mafia state snapshot"
                }
                lassign [lrange $snapshot 1 end] p d pp b
                array unset players
                array set players $p
                array unset drug_price_arr
                array set drug_price_arr $d
                array unset pimp_price_arr
                array set pimp_price_arr $pp
                array unset blackmarket_stock
                array set blackmarket_stock $b
                return 1
            }
        }
        return -code error "invalid mafia state snapshot"
    }

    # Roll back by re-reading the last committed state. Everything is read into
    # scratch lists FIRST and only swapped in once every read has succeeded, so
    # a failed or partial read can never leave the live arrays half-populated --
    # which would be far worse than the error being rolled back.
    #
    # blackmarket_stock is deliberately not restored here: it is not persisted,
    # nothing a player owns lives in it, and it is regenerated on its own timer
    # and on demand. A command that rerolled the stock before failing simply
    # leaves the new stock standing.
    proc state_restore_from_db {} {
        variable players
        variable drug_price_arr
        variable pimp_price_arr
        variable db
        variable db_ready
        variable db_shadow
        if {!$db_ready || $db eq ""} {
            return -code error "no rollback source: persistence is unavailable"
        }
        set new_players {}
        set new_drugs {}
        set new_pimp {}
        if {[catch {
            $db eval {SELECT nick, field, value FROM player_data} row {
                lappend new_players $row(nick),$row(field) $row(value)
            }
            $db eval {SELECT drug, price FROM market} row {
                lappend new_drugs $row(drug) $row(price)
            }
            $db eval {SELECT tier, price FROM pimp_market} row {
                lappend new_pimp $row(tier) $row(price)
            }
        } err]} {
            return -code error "rollback read failed: $err"
        }
        array unset players
        array set players $new_players
        array unset drug_price_arr
        array set drug_price_arr $new_drugs
        array unset pimp_price_arr
        array set pimp_price_arr $new_pimp
        # players() is now byte-for-byte what the database holds, so the save
        # shadow has to say the same thing -- it is built from the very rows
        # just read. Leaving a stale shadow here would make the next save skip
        # rows it believes are already written (see resync_db_shadow).
        array unset db_shadow
        array set db_shadow $new_players
        # Transient encounter state is never persisted (see save_db), so a
        # restored row set cannot carry a phantom encounter back in.
        return 1
    }

    proc raw_mafia {nick uhost hand chan text} {
        if {![chan_ok $chan]} { return }
        if {![cmd_throttle_ok $nick]} { return }
        set text [clean_input $text]

        # Snapshot before touch() too: even the command's activity metadata is
        # restored if dispatch or persistence fails.
        set txn_snapshot [state_snapshot]
        set cmd_ok [catch {
            touch $nick $chan
            set args [words $text]
            if {[llength $args] == 0} {
                set sub "help"
                set rest {}
                cmd_help $nick $chan
            } else {
                set sub [string tolower [lindex $args 0]]
                set rest [lrange $args 1 end]

                # Hospital is a hard lock: no shopping, healing, combat,
                # trading, jobs, crimes, or other gameplay is allowed until
                # the timer expires. Jail is similarly locked except for bribe.
                if {$sub ne "register" && [exists_player $nick] && [in_hospital $nick]} {
                    blocked_state $nick $chan
                    return
                }
                if {$sub ne "register" && $sub ne "bribe" && [exists_player $nick] && [in_jail $nick]} {
                    blocked_state $nick $chan
                    return
                }

                # NOTHING may be commented out inside the switch body below,
                # and no explanatory comment may be placed between its
                # pattern/body pairs. A braced switch body is parsed as a LIST
                # of pattern-body pairs, not as a script, so a "#" line there is
                # not a comment: every word in it becomes a pattern or a body,
                # in order. Two such blocks used to sit in this table, and the
                # words in one of them landed as the pattern/body pair
                # {dealer network} AHEAD of the real "dealer -" entry -- so
                # "!mafia dealer" matched the comment, tried to run a command
                # called "network", and answered every player with a rolled-back
                # transaction and "that Mafia action failed cleanly". Notes
                # about individual commands belong here, above the switch:
                #
                #   casino / dealer(s) -- top-level shortcuts, so "!mafia casino
                #     prices" and "!mafia dealer prices" work directly without
                #     players having to know that the casino operation lives
                #     under "!mafia gamble" and the dealer network under
                #     "!mafia drug dealer".
                #   knife / shoot -- cmd_attack's signature is {nick chan args
                #     mode}, where "args" is one ordinary positional parameter
                #     (it is not the trailing catch-all, because "mode" follows
                #     it). The target therefore has to be passed as a ONE-ELEMENT
                #     LIST, never expanded with {*}$rest: expanding it made a
                #     stray word after the nick ("!mafia shoot bob now") call
                #     cmd_attack with too many arguments, i.e. another uncaught
                #     error and another bogus rollback. [lrange $rest 0 0] is
                #     empty when nothing was typed, so the usage message still
                #     works.
                switch -- $sub {
                register   { cmd_register $nick $chan }
                stats      { cmd_stats $nick $chan {*}$rest }
                profile    { cmd_stats $nick $chan {*}$rest }
                crimes     { cmd_crimelist $nick $chan }
                crime      { cmd_crime $nick $chan {*}$rest }
                shop       { cmd_shop $nick $chan {*}$rest }
                buy        { cmd_buy $nick $chan {*}$rest }
                sell       { cmd_sell $nick $chan {*}$rest }
                inventory  -
                inv        { cmd_inventory $nick $chan }
                equip      { cmd_equip $nick $chan {*}$rest }
                hide       { cmd_hide $nick $chan }
                unhide     { cmd_unhide $nick $chan }
                faceoff    { cmd_fight $nick $chan }
                talk       { cmd_talk $nick $chan }
                run        { cmd_run $nick $chan }
                payoff     { cmd_payoff $nick $chan }
                heal       { cmd_heal $nick $chan }
                autoheal   { cmd_autoheal $nick $chan {*}$rest }
                rob        { cmd_rob $nick $chan {*}$rest }
                drug       { cmd_drug $nick $chan {*}$rest }
                dealprices  -
                prices     { cmd_allprices $nick $chan }
                pimp       { cmd_pimp $nick $chan {*}$rest }
                deposit    { cmd_deposit $nick $chan {*}$rest }
                withdraw   { cmd_withdraw $nick $chan {*}$rest }
                bribe      { cmd_bribe $nick $chan }
                topdon     -
                leaderboard { cmd_top $nick $chan }
                don        { cmd_don $nick $chan }
                wiretap    { cmd_wiretap $nick $chan {*}$rest }
                gamble     { cmd_gamble $nick $chan {*}$rest }
                games      { cmd_gamblegames $nick $chan }
                casino     { cmd_gamble $nick $chan {*}$rest }
                dealer     -
                dealers    { cmd_drug $nick $chan dealer {*}$rest }
                fence      { cmd_fence $nick $chan {*}$rest }
                goods      { cmd_goods $nick $chan }
                blackmarket -
                bm         { cmd_blackmarket $nick $chan }
                blackbuy   { cmd_blackbuy $nick $chan {*}$rest }
                legend     -
                legendary  { cmd_legend $nick $chan }
                job      { cmd_job $nick $chan {*}$rest }
                joblist  { cmd_joblist $nick $chan {*}$rest }
                jobtiers -
                jobtier  { cmd_jobtiers $nick $chan }

                knife      { cmd_attack $nick $chan [lrange $rest 0 0] "knife" }
                shoot      { cmd_attack $nick $chan [lrange $rest 0 0] "shoot" }
                headshot   { cmd_headshot $nick $chan {*}$rest }

                street     -
                cpu        { cmd_streetfight $nick $chan }
                npc        { cmd_npcfight $nick $chan }
                hit        { cmd_hitfight $nick $chan }
                revenge    { cmd_revenge $nick $chan }
                stealth    { cmd_stealthfight $nick $chan }
                boss       { cmd_boss $nick $chan {*}$rest }
                fight      {
                    # !mafia fight cpu|street = easy NPC, no kill credit.
                    # !mafia fight npc = tougher/unpredictable NPC, counts as a kill.
                    # !mafia fight hit = hitman NPC.
                    # !mafia fight stealth = stealth NPC.
                    # !mafia fight <nick> = player fight with equipped melee weapon.
                    if {[llength $rest] == 0} {
                        cmd_streetfight $nick $chan
                    } else {
                        set mode [string tolower [lindex $rest 0]]
                        switch -- $mode {
                            cpu - street       { cmd_streetfight $nick $chan }
                            npc                { cmd_npcfight $nick $chan }
                            hit                { cmd_hitfight $nick $chan }
                            revenge            { cmd_revenge $nick $chan }
                            stealth            { cmd_stealthfight $nick $chan }
                            boss               { cmd_boss $nick $chan }
                            player {
                                if {[llength $rest] < 2} {
                                    game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia fight player <nick>"
                                } else {
                                    cmd_attack $nick $chan [list [lindex $rest 1]] "knife"
                                }
                            }
                            default { cmd_attack $nick $chan [list [lindex $rest 0]] "knife" }
                        }
                    }
                }
                default {
                    game_msg $nick $chan "Unknown Mafia command '$sub'. Type !mafiahelp for the command list."
                }
                }
            }

            # Checkpoint only after the complete command returns successfully.
            if {[llength [info commands ::mafia::save_db]]} {
                if {![save_db 1]} {
                    return -code error "post-command persistence checkpoint failed for '$sub'"
                }
            }
        } cmd_result cmd_opts]

        # Only a genuine error (TCL_ERROR == 1) may roll back. The jail and
        # hospital gates above complete the transaction body with a bare
        # `return`, which catch reports as TCL_RETURN (2) -- treating that as
        # a failure meant every command typed by a jailed or hospitalized
        # player was answered with "that Mafia action failed cleanly" on top
        # of the real gate message, and logged as a rolled-back transaction.
        if {$cmd_ok == 1} {
            # Restore memory to exactly the pre-command state.  save_db has
            # its own SQLite transaction, so a failed checkpoint has already
            # rolled the database back.
            if {[catch {state_restore $txn_snapshot} restore_err]} {
                putlog "mafia.tcl: FATAL: command rollback failed for '$nick': $restore_err"
            }
            putlog "mafia.tcl: command transaction rolled back for $nick: $cmd_result"
            # Do not expose internal Tcl/database details to IRC.
            catch {game_msg $nick $chan "$nick: that Mafia action failed cleanly; no game state was applied."}
            return -options $cmd_opts $cmd_result
        }
    }

    proc raw_help {nick uhost hand chan text} {
        if {![chan_ok $chan]} { return }
        if {![cmd_throttle_ok $nick]} { return }
        set text [clean_input $text]
        # touch is the one state-mutating thing help does (last_seen/last_chan,
        # plus the ambient encounter roll). Unlike raw_mafia this path has no
        # snapshot, no rollback and no save_db checkpoint, so an error raised
        # by a corrupt row inside normalize_player_economy would escape
        # uncaught AND leave the player unable to read the help text -- the one
        # command that should always answer. Help itself is read-only, so
        # swallowing a touch failure loses nothing but the activity stamp.
        if {[catch {touch $nick $chan} err]} {
            putlog "mafia.tcl: help touch failed for $nick: $err"
        }
        cmd_help $nick $chan {*}[words $text]
    }

}
# mafia_admin.tcl - !mafiaadmin commands, shared game_msg/jail-expiry/
# registration/blocked-state helpers.
namespace eval mafia {
    ##### =====================================================
    #####                 ADMIN (!mafiaadmin)
    ##### =====================================================

    proc is_admin {hand} {
        variable admin_flags
        return [matchattr $hand $admin_flags]
    }

    # Per-nick command throttle shared by !mafia, !mafiahelp and !mafiaadmin:
    # a bucket of cmd_burst commands, refilled one every cmd_refill_secs
    # (0 = off). Nothing else limited how often a nick could make the bot
    # talk -- "!mafia stats" is 7 lines, so ten of them in a second queued 70
    # lines on the main server queue, delaying every other script's output.
    # Over the limit the command is dropped silently (a reply would just be
    # more of the flood). In-memory only; reset by a rehash, which is fine.
    variable cmd_bucket
    array set cmd_bucket {}
    proc cmd_throttle_ok {nick} {
        variable cmd_bucket
        variable cmd_burst
        variable cmd_refill_secs
        if {$cmd_refill_secs <= 0} { return 1 }
        set k [string tolower $nick]
        set now [clock seconds]
        if {[info exists cmd_bucket($k)]} {
            lassign $cmd_bucket($k) tokens last
            if {$now < $last} { set last $now }
            set tokens [expr {min($cmd_burst, $tokens + ($now - $last) / double($cmd_refill_secs))}]
        } else {
            set tokens $cmd_burst
        }
        if {$tokens < 1} {
            set cmd_bucket($k) [list $tokens $now]
            return 0
        }
        set cmd_bucket($k) [list [expr {$tokens - 1}] $now]
        if {[array size cmd_bucket] > 500} {
            # A full bucket carries no state worth keeping: drop entries
            # idle long enough to have refilled.
            set idle [expr {$cmd_burst * $cmd_refill_secs + 60}]
            foreach n [array names cmd_bucket] {
                if {$now - [lindex $cmd_bucket($n) 1] > $idle} { unset cmd_bucket($n) }
            }
        }
        return 1
    }

    # IRC text from users never legitimately carries control bytes (bold,
    # colour, CTCP \001, NUL): strip them before parsing, so nothing a player
    # types can be echoed back with formatting/CTCP into a reply, and cap it.
    proc clean_input {text} {
        regsub -all {[\x00-\x1f\x7f]} $text " " text
        return [string range [string trim $text] 0 399]
    }

    # Whitespace-run split: [split] turned a double space into an empty
    # word, so "!mafia buy  magnum" looked up item "" ("No such item") and
    # "!mafia deposit  5" was an "invalid amount".
    proc words {text} {
        return [regexp -all -inline {\S+} $text]
    }

    # Bot-wide cap on new accounts per minute. Each registration is ~100
    # persisted rows; without a cap, a client cycling throwaway nicks (each
    # with a fresh per-nick throttle) could create accounts as fast as it
    # can type, growing the database and every per-player sweep.
    variable register_times {}
    proc register_allowed {} {
        variable register_times
        variable register_per_min
        set now [clock seconds]
        set keep {}
        foreach t $register_times { if {$now - $t < 60 && $t <= $now} { lappend keep $t } }
        set register_times $keep
        if {[llength $register_times] >= $register_per_min} { return 0 }
        lappend register_times $now
        return 1
    }

    proc admin_msg {nick msg} {
        # Admin replies are always private.  Never route this through game_msg
        # or the command channel; pub callbacks receive both nick and chan and
        # mixing those up is what causes Eggdrop's "Can't send to channel".
        set target [string trim $nick]
        if {$target eq "" || [string first " " $target] >= 0 ||
            [string first "\r" $target] >= 0 || [string first "\n" $target] >= 0} {
            putlog "mafia.tcl: refusing invalid admin reply target"
            return 0
        }
        set msg [string map [list "\r" " " "\n" " "] $msg]
        # Use NOTICE directly to the requesting nick.  This is deliberately
        # independent of the normal Mafia output mode and cannot become a
        # channel send when output_mode is set to channel.
        putserv "NOTICE $target :$msg"
        return 1
    }

    proc cmd_admin_help {nick chan} {
        variable cmd_prefix
        set p $cmd_prefix
        admin_msg $nick "\002Mafia Admin\002 -- ${p}mafiaadmin help | give <nick> <money|xp> <amount> | reset <nick> | prune \[days\] \[confirm\] | nearing \[days\] | config \[key\] \[value\]"
        admin_msg $nick "  \002give\002    -- add or remove cash/xp from a player. Amount can be negative."
        admin_msg $nick "  \002reset\002   -- wipe a player's data completely (they'll need to register again)."
        admin_msg $nick "  \002prune\002   -- remove players not seen for <days> days (default inactive_days, minimum 7). Reports only unless you add 'confirm'."
        admin_msg $nick "  \002nearing\002 -- list players approaching (but not yet past) the inactivity cutoff, within \[days\] of it (default cleanup_warn_days)."
        admin_msg $nick "  \002config\002  -- with no args, lists every setting. With a key, shows its value. With a key and value, changes it."
        admin_msg $nick "            'config chan' takes one or more channels ('#a' or '#a #b #c'), or empty for every channel the bot is on."
        admin_msg $nick "            Values set here are range-checked, and Mafia.cfg is now range-checked too: an out-of-range or missing setting there is logged on load and replaced with its default."
        admin_msg $nick "            Changes made with 'config' are LIVE ONLY -- a .rehash re-reads Mafia.cfg, so edit that file as well to make a change stick."
        admin_msg $nick "  A sweep also runs automatically every auto_cleanup_interval_days, removing accounts inactive inactive_days+ without confirmation."
        admin_msg $nick "  Orphaned player rows (fields left behind with no account attached) are swept on every load/.rehash, alongside the retired-field prune."
    }

    proc cmd_admin_give {nick chan rest} {
        if {[llength $rest] < 3} {
            admin_msg $nick "Usage: ${::mafia::cmd_prefix}mafiaadmin give <nick> <money|xp> <amount>"
            return
        }
        lassign $rest target field amount
        if {![exists_player $target]} {
            admin_msg $nick "No such player: $target"
            return
        }
        if {![command_integer $amount 12]} {
            admin_msg $nick "Amount must be a whole number (positive or negative)."
            return
        }
        variable players
        set k [string tolower $target]
        switch -- [string tolower $field] {
            money - cash {
                set players($k,cash) [expr {$players($k,cash)+$amount}]
                if {$players($k,cash) < 0} { set players($k,cash) 0 }
                set success_msg "Gave [fmt_cash $amount] to $players($k,name). New balance: [fmt_cash $players($k,cash)]."
            }
            xp {
                set players($k,xp) [expr {$players($k,xp)+$amount}]
                if {$players($k,xp) < 0} { set players($k,xp) 0 }
                sync_level_stats $target
                set success_msg "Gave $amount XP to $players($k,name). New XP: $players($k,xp) (Level [player_level $target], [rank_for_xp $players($k,xp)])."
            }
            default {
                admin_msg $nick "Unknown field '$field'. Use money or xp."
                return
            }
        }
        if {![save_db 1]} { return -code error "admin give persistence failed" }
        admin_msg $nick $success_msg
    }

    proc cmd_admin_reset {nick chan rest} {
        if {[llength $rest] < 1} {
            admin_msg $nick "Usage: ${::mafia::cmd_prefix}mafiaadmin reset <nick>"
            return
        }
        set target [lindex $rest 0]
        if {![exists_player $target]} {
            admin_msg $nick "No such player: $target"
            return
        }
        variable players
        set k [string tolower $target]
        set prefix "${k},"
        set plen [string length $prefix]
        # Literal prefix match, not a glob pattern: IRC nicks may contain
        # [ ] { } \ ` -- all Tcl glob metacharacters -- which would make
        # [array names players "${k},*"] fail to match (or overmatch) such
        # a nick's own keys.
        foreach key [array names players] {
            if {[string equal -length $plen $prefix $key]} {
                unset players($key)
            }
        }
        if {![save_db 1]} { return -code error "admin reset persistence failed" }
        admin_msg $nick "Reset all data for $target."
    }

    # Player rows are never expired by normal play: everyone who ever typed
    # !mafia register stays in the array and in the database forever, which is
    # the one part of the state that grows monotonically with time rather than
    # with the size of the catalog. This is the manual broom.
    #
    # Destructive, so it is dry-run BY DEFAULT: "prune <days>" only reports
    # what it would remove. Nothing is deleted without "prune <days> confirm".
    proc cmd_admin_prune {nick chan rest} {
        variable players
        variable inactive_days
        set p $::mafia::cmd_prefix
        if {[llength $rest] < 1} {
            set days $inactive_days
            set confirm 0
        } elseif {[llength $rest] == 1 && [string tolower [lindex $rest 0]] eq "confirm"} {
            set days $inactive_days
            set confirm 1
        } else {
            set days [lindex $rest 0]
            if {![command_integer $days 5] || $days < 7} {
                admin_msg $nick "prune needs a whole number of days, minimum 7."
                return
            }
            set confirm [expr {[llength $rest] > 1 && [string tolower [lindex $rest 1]] eq "confirm"}]
        }
        set cutoff [expr {[now] - ($days*86400)}]

        set victims {}
        foreach key [array names players "*,cash"] {
            set comma [string first "," $key]
            if {$comma < 1} { continue }
            set k [string range $key 0 [expr {$comma-1}]]
            set seen [expr {[info exists players($k,last_seen)] ? $players($k,last_seen) : 0}]
            if {![string is integer -strict $seen]} { set seen 0 }
            if {$seen < $cutoff} { lappend victims $k }
        }
        if {![llength $victims]} {
            admin_msg $nick "No players have been inactive for $days+ days."
            return
        }

        set shown [lrange $victims 0 14]
        set more [expr {[llength $victims]-[llength $shown]}]
        set tail [expr {$more > 0 ? " (+$more more)" : ""}]
        if {!$confirm} {
            admin_msg $nick "[llength $victims] player(s) inactive for $days+ days: [join $shown {, }]$tail"
            admin_msg $nick "Nothing was removed. Re-run as: ${p}mafiaadmin prune $days confirm"
            return
        }

        # One pass over the array rather than one per victim.
        set prefixes {}
        foreach k $victims { lappend prefixes "${k}," }
        set removed 0
        foreach key [array names players] {
            foreach prefix $prefixes {
                if {[string equal -length [string length $prefix] $prefix $key]} {
                    unset -nocomplain players($key)
                    incr removed
                    break
                }
            }
        }
        if {![save_db 1]} { return -code error "admin prune persistence failed" }
        admin_msg $nick "Pruned [llength $victims] player(s), $removed row(s): [join $shown {, }]$tail"
        putlog "mafia.tcl: admin prune by $nick removed [llength $victims] player(s) inactive for $days+ days ($removed rows)."
    }

    # Read-only lookahead for prune: accounts that are NOT yet past the
    # inactivity cutoff but will be within <days> (default cleanup_warn_days).
    # Purely informational, so it isn't part of the transactional give/reset/
    # prune group below -- nothing here can leave state half-applied.
    proc cmd_admin_nearing {nick chan rest} {
        variable players
        variable inactive_days
        variable cleanup_warn_days
        set days [expr {[llength $rest] >= 1 ? [lindex $rest 0] : $cleanup_warn_days}]
        if {![command_integer $days 5] || $days < 1} {
            admin_msg $nick "nearing needs a whole positive number of days."
            return
        }
        set now_ts [now]
        set hard_cutoff [expr {$now_ts - ($inactive_days*86400)}]
        set warn_cutoff [expr {$now_ts - (($inactive_days-$days)*86400)}]
        set found {}
        foreach key [array names players "*,cash"] {
            set comma [string first "," $key]
            if {$comma < 1} { continue }
            set k [string range $key 0 [expr {$comma-1}]]
            set seen [expr {[info exists players($k,last_seen)] ? $players($k,last_seen) : 0}]
            if {![string is integer -strict $seen]} { set seen 0 }
            # Nearing = already older than the warn threshold, but not yet
            # past the actual prune cutoff (those show up in prune instead).
            if {$seen < $warn_cutoff && $seen >= $hard_cutoff} {
                set days_left [expr {int(($seen - $hard_cutoff)/86400)}]
                lappend found "${k}(${days_left}d left)"
            }
        }
        if {![llength $found]} {
            admin_msg $nick "No players are nearing the ${inactive_days}-day inactivity cutoff (within $days days)."
            return
        }
        set shown [lrange $found 0 14]
        set more [expr {[llength $found]-[llength $shown]}]
        set tail [expr {$more > 0 ? " (+$more more)" : ""}]
        admin_msg $nick "[llength $found] player(s) nearing the ${inactive_days}-day cutoff within $days days: [join $shown {, }]$tail"
    }

    # Automatic, unattended sweep -- unlike !mafiaadmin prune, this never
    # asks for confirmation (there's no one to ask); it just removes accounts
    # past inactive_days and logs what it did, on the recurring timer set up
    # by start_auto_cleanup_timer.
    proc auto_cleanup_run {} {
        variable players
        variable inactive_days
        set cutoff [expr {[now] - ($inactive_days*86400)}]
        set victims {}
        foreach key [array names players "*,cash"] {
            set comma [string first "," $key]
            if {$comma < 1} { continue }
            set k [string range $key 0 [expr {$comma-1}]]
            set seen [expr {[info exists players($k,last_seen)] ? $players($k,last_seen) : 0}]
            if {![string is integer -strict $seen]} { set seen 0 }
            if {$seen < $cutoff} { lappend victims $k }
        }
        if {![llength $victims]} {
            putlog "mafia.tcl: automatic cleanup found no accounts inactive $inactive_days+ days."
            return
        }
        set prefixes {}
        foreach k $victims { lappend prefixes "${k}," }
        # Same snapshot/rollback discipline as the transactional admin
        # commands (see raw_mafiaadmin): this runs unattended off a timer,
        # so a persistence failure here must not leave the deletion applied
        # only in memory with no admin present to notice or retry.
        set cleanup_snapshot [state_snapshot]
        if {[catch {
            set removed 0
            foreach key [array names players] {
                foreach prefix $prefixes {
                    if {[string equal -length [string length $prefix] $prefix $key]} {
                        unset -nocomplain players($key)
                        incr removed
                        break
                    }
                }
            }
            if {![save_db 1]} { error "persistence failed" }
        } cleanup_err]} {
            if {[catch {state_restore $cleanup_snapshot} restore_err]} {
                putlog "mafia.tcl: FATAL: automatic cleanup rollback failed: $restore_err"
            } else {
                putlog "mafia.tcl: automatic cleanup rolled back cleanly: $cleanup_err"
            }
            return
        }
        putlog "mafia.tcl: automatic cleanup removed [llength $victims] player(s) inactive for $inactive_days+ days ($removed rows)."
    }

    proc auto_cleanup_timer {{epoch ""}} {
        variable cleanup_timer_id
        variable cleanup_epoch
        variable auto_cleanup_interval_days
        variable auto_cleanup_poll_secs
        variable meta_key
        variable players
        if {$epoch ne "" && $epoch != $cleanup_epoch} { return }
        # Clamp before it becomes a utimer delay. Unlike every other setting
        # this timer reads, auto_cleanup_poll_secs is cfg-only -- it is not in
        # admin_config_keys, so nothing validates it. A 0 or a typo here makes
        # this chain reschedule itself with no delay, which is an unbreakable
        # busy loop on Eggdrop's single-threaded event loop: the bot stops
        # answering IRC entirely and only a restart clears it.
        set poll [cfg_interval $auto_cleanup_poll_secs 3600 60]
        # Poll on a short, fixed interval rather than sleeping for the whole
        # (up to 180-day) cleanup interval in one utimer. A bot that rehashes
        # or restarts more often than the cleanup interval would otherwise
        # never actually run the sweep: start_auto_cleanup_timer used to
        # reschedule a fresh full-length wait from "now" on every restart,
        # so progress toward the next run was lost every time. Polling and
        # persisting last_auto_cleanup (below) makes the due-check survive
        # restarts instead of restarting the clock.
        set cleanup_timer_id [utimer $poll [list ::mafia::auto_cleanup_timer $cleanup_epoch]]
        set last_run [getf $meta_key last_auto_cleanup 0]
        if {![string is integer -strict $last_run]} { set last_run 0 }
        set due_at [expr {$last_run + ($auto_cleanup_interval_days*86400)}]
        if {[now] < $due_at} { return }
        if {[catch {auto_cleanup_run} err]} {
            putlog "mafia.tcl: automatic cleanup timer error: $err"
            return
        }
        set players($meta_key,last_auto_cleanup) [now]
        catch {save_db 1}
    }

    proc start_auto_cleanup_timer {} {
        variable cleanup_timer_id
        variable cleanup_epoch
        variable auto_cleanup_poll_secs
        variable meta_key
        incr cleanup_epoch
        if {$cleanup_timer_id ne "" && [llength [info commands killutimer]]} {
            catch {killutimer $cleanup_timer_id}
        }
        # First run on a fresh install: seed last_auto_cleanup to now so a
        # brand-new database doesn't immediately sweep everyone who hasn't
        # played in the last few minutes.
        if {![info exists ::mafia::players($meta_key,last_auto_cleanup)]} {
            set ::mafia::players($meta_key,last_auto_cleanup) [now]
        }
        # Same clamp as the callback: the very first schedule has to be safe
        # too, or a bad cfg value busy-loops the bot from load time onward.
        set cleanup_timer_id [utimer [cfg_interval $auto_cleanup_poll_secs 3600 60] [list ::mafia::auto_cleanup_timer $cleanup_epoch]]
    }

    proc cmd_admin_config {nick chan rest} {
        variable admin_config_keys
        set p $::mafia::cmd_prefix
        if {[llength $rest] == 0} {
            admin_msg $nick "\002Mafia Config\002 (${p}mafiaadmin config <key> <value> to change):"
            foreach key $admin_config_keys {
                # A key with no variable behind it (an operator deleted the
                # line from Mafia.cfg, or a new key shipped without one) used
                # to abort the whole listing partway through with an uncaught
                # "no such variable". Report it and keep going instead.
                if {![info exists ::mafia::$key]} {
                    admin_msg $nick "  $key = (NOT SET -- missing from Mafia.cfg)"
                    continue
                }
                set val [set ::mafia::$key]
                if {$val eq ""} { set val "(empty)" }
                admin_msg $nick "  $key = $val"
            }
            return
        }
        set key [string tolower [lindex $rest 0]]
        if {[lsearch -exact $admin_config_keys $key] < 0} {
            admin_msg $nick "Unknown or non-configurable setting '$key'. Type ${p}mafiaadmin config for the list."
            return
        }
        if {[llength $rest] < 2} {
            if {![info exists ::mafia::$key]} {
                admin_msg $nick "$key is not set (missing from Mafia.cfg)."
                return
            }
            admin_msg $nick "$key = [set ::mafia::$key]"
            return
        }
        set value [join [lrange $rest 1 end]]
        if {$key eq "output_mode"} {
            # game_msg lowercases before dispatching, so accept any casing
            # here rather than rejecting a perfectly valid "Notice".
            set value [string tolower $value]
            if {$value ni {notice privmsg channel}} {
                admin_msg $nick "output_mode must be one of: notice, privmsg, channel."
                return
            }
        }
        # chan is the only free-form key with no validation at all. It is a
        # whitespace-separated channel list, so a value carrying CR/LF (or an
        # absurd length) is never a legal setting -- it just silently makes
        # chan_ok match nothing and takes the game offline with no error.
        if {$key eq "chan"} {
            if {[regexp {[\r\n]} $value] || [string length $value] > 400} {
                admin_msg $nick "chan must be a space-separated channel list with no line breaks (or empty for all channels)."
                return
            }
        }
        # cmd_prefix goes straight into `bind pub - "${p}mafia"`. An empty or
        # whitespace-bearing prefix registers binds that can never fire (and
        # silently unbinds the working ones), leaving the game unreachable
        # from IRC with no way to configure it back.
        if {$key eq "cmd_prefix"} {
            if {$value eq "" || [string length $value] > 4 ||
                [regexp {\s} $value] || [string first "\r" $value] >= 0 ||
                [string first "\n" $value] >= 0} {
                admin_msg $nick "cmd_prefix must be 1-4 non-whitespace characters (e.g. ! or .)."
                return
            }
        }
        # admin_flags is fed to matchattr. An empty value makes every user
        # match, handing !mafiaadmin -- give/reset/prune included -- to the
        # whole channel.
        if {$key eq "admin_flags"} {
            if {$value eq "" || [regexp {\s} $value] || [string length $value] > 32} {
                admin_msg $nick "admin_flags must be a non-empty Eggdrop flag string with no spaces (e.g. n, m, or |o)."
                return
            }
        }
        # jail_risk_multiplier is a decimal multiplier (default 0.50), not a
        # whole number. It has to be handled before the integer check below,
        # which otherwise rejected every fractional value -- leaving a
        # configurable key that could never be set back to its own default.
        if {$key eq "jail_risk_multiplier"} {
            if {[string length $value] > 12 || ![string is double -strict $value] ||
                $value < 0 || $value > 10} {
                admin_msg $nick "jail_risk_multiplier must be a number between 0 and 10 (e.g. 0.50)."
                return
            }
            set ::mafia::jail_risk_multiplier $value
            admin_msg $nick "Set $key = $value. (In memory only -- also change it in Mafia.cfg, or the next .rehash/restart puts the old value back.)"
            return
        }
        # Same story: legend_drop_pct is a percentage that is meant to be
        # settable below 1 (it is applied in basis points), so it cannot go
        # through the whole-number check either. 100 would make every
        # eligible black-market roll a legendary find.
        if {$key eq "legend_drop_pct"} {
            if {[string length $value] > 12 || ![string is double -strict $value] ||
                $value < 0 || $value > 100} {
                admin_msg $nick "legend_drop_pct must be a number between 0 and 100 (e.g. 5 or 0.5). 0 disables legendary drops."
                return
            }
            set ::mafia::legend_drop_pct $value
            admin_msg $nick "Set $key = $value. (In memory only -- also change it in Mafia.cfg, or the next .rehash/restart puts the old value back.)"
            return
        }
        if {$key ni {chan cmd_prefix output_mode admin_flags} && ![command_integer $value 12]} {
            admin_msg $nick "$key must be a whole number."
            return
        }
        # Reject timer/config values that could create a zero/negative utimer
        # loop, negative jail durations, or invalid encounter windows.
        if {$key eq "save_interval" && ($value < 1 || $value > 1440)} {
            admin_msg $nick "save_interval must be between 1 and 1440 minutes."
            return
        }
        if {$key in {jail_time hospital_time hide_time} && ($value < 0 || $value > 10080)} {
            admin_msg $nick "$key must be between 0 and 10080 minutes."
            return
        }
        if {$key in {crime_cooldown attack_cooldown rob_cooldown deal_cooldown streetfight_cooldown npcfight_cooldown hitfight_cooldown stealthfight_cooldown wiretap_cooldown gamble_cooldown job_cooldown boss_cooldown pimp_collect_cooldown casino_collect_cooldown dealer_collect_cooldown} && ($value < 0 || $value > 86400)} {
            admin_msg $nick "$key must be between 0 and 86400 seconds."
            return
        }
        # Every other numeric key is bounded above; these were added to
        # admin_config_keys later and were never given a range, so they fell
        # through every check here and were accepted at any value up to twelve
        # digits. dealer_refund_pct is the dangerous one: it is paid out as a
        # percentage of a dealer's purchase price on !mafia drug dealer remove,
        # so anything at or above 100 makes buy-then-remove pay more than it
        # costs -- an unlimited money loop off a single mistyped config value.
        # The cleanup keys matter too: auto_cleanup_run is unattended, so a 0
        # here points a no-confirmation account-deletion sweep at the whole
        # player table.
        if {$key eq "dealer_refund_pct" && ($value < 0 || $value > 99)} {
            admin_msg $nick "dealer_refund_pct must be between 0 and 99 (100+ would pay back more than a dealer costs)."
            return
        }
        if {$key in {inactive_days auto_cleanup_interval_days} && ($value < 7 || $value > 3650)} {
            admin_msg $nick "$key must be between 7 and 3650 days."
            return
        }
        if {$key eq "cleanup_warn_days" && ($value < 1 || $value > 3650)} {
            admin_msg $nick "cleanup_warn_days must be between 1 and 3650 days."
            return
        }
        if {$key eq "start_cash" && ($value < 0 || $value > 1000000000)} {
            admin_msg $nick "start_cash must be between 0 and 1000000000."
            return
        }
        if {$key in {jail_bribe_min jail_bribe_max} && ($value < 0 || $value > 1000000000)} {
            admin_msg $nick "$key must be between 0 and 1000000000."
            return
        }
        # cmd_bribe rolls min + rand()*(max-min+1); an inverted pair makes that
        # range negative and hands out cash instead of charging for the bribe.
        if {$key eq "jail_bribe_min" && $value > $::mafia::jail_bribe_max} {
            admin_msg $nick "jail_bribe_min cannot be greater than jail_bribe_max."
            return
        }
        if {$key eq "jail_bribe_max" && $value < $::mafia::jail_bribe_min} {
            admin_msg $nick "jail_bribe_max cannot be less than jail_bribe_min."
            return
        }
        if {$key eq "encounter_daily_limit" && ($value < 0 || $value > 1000)} {
            admin_msg $nick "encounter_daily_limit must be between 0 and 1000."
            return
        }
        if {$key in {encounter_min_gap encounter_max_gap} && ($value < 0 || $value > 86400)} {
            admin_msg $nick "$key must be between 0 and 86400 seconds."
            return
        }
        if {$key eq "encounter_min_gap" && $value > $::mafia::encounter_max_gap} {
            admin_msg $nick "encounter_min_gap cannot be greater than encounter_max_gap."
            return
        }
        if {$key eq "encounter_max_gap" && $value < $::mafia::encounter_min_gap} {
            admin_msg $nick "encounter_max_gap cannot be less than encounter_min_gap."
            return
        }
        if {$key eq "encounter_response_time" && ($value < 5 || $value > 600)} {
            admin_msg $nick "encounter_response_time must be between 5 and 600 seconds."
            return
        }
        # A 0 here would remove the rate limit entirely and turn legendary
        # drops into a per-purchase roll, which is the one thing the two-gate
        # design exists to prevent.
        if {$key eq "legend_roll_cooldown" && ($value < 30 || $value > 604800)} {
            admin_msg $nick "legend_roll_cooldown must be between 30 and 604800 seconds."
            return
        }
        set ::mafia::$key $value
        if {$key eq "cmd_prefix"} { init_binds }
        if {$key eq "save_interval"} { start_autosave_timer }
        admin_msg $nick "Set $key = $value. (In memory only -- also change it in Mafia.cfg, or the next .rehash/restart puts the old value back.)"
    }

    proc raw_mafiaadmin {nick uhost hand chan text} {
        if {![chan_ok $chan]} { return }
        # Throttled before the access check: anyone could make the bot NOTICE
        # "Access denied." once per line they typed.
        if {![cmd_throttle_ok $nick]} { return }
        if {![is_admin $hand]} {
            admin_msg $nick "Access denied."
            return
        }
        set text [clean_input $text]
        set args [words $text]
        if {[llength $args] == 0} {
            cmd_admin_help $nick $chan
            return
        }
        set sub [string tolower [lindex $args 0]]
        set rest [lrange $args 1 end]
        if {$sub in {give reset prune}} {
            set admin_snapshot [state_snapshot]
            if {[catch {
                switch -- $sub {
                    give  { cmd_admin_give  $nick $chan $rest }
                    reset { cmd_admin_reset $nick $chan $rest }
                    prune { cmd_admin_prune $nick $chan $rest }
                }
            } admin_err admin_opts]} {
                if {[catch {state_restore $admin_snapshot} restore_err]} {
                    putlog "mafia.tcl: FATAL: admin rollback failed for '$nick': $restore_err"
                }
                putlog "mafia.tcl: admin transaction rolled back for $nick: $admin_err"
                catch {admin_msg $nick "$nick: that Mafia admin action failed cleanly; no game state was applied."}
                return -options $admin_opts $admin_err
            }
            return
        }
        switch -- $sub {
            help    { cmd_admin_help $nick $chan }
            config  { cmd_admin_config $nick $chan $rest }
            nearing { cmd_admin_nearing $nick $chan $rest }
            default { admin_msg $nick "Unknown admin command '$sub'. Type ${::mafia::cmd_prefix}mafiaadmin help." }
        }
    }


    # Centralized game output. Set output_mode to notice, privmsg, or channel.
    # notice is the default so game traffic does not pollute the channel.
    proc game_msg {nick chan msg} {
        variable output_mode
        set msg [string map [list "\r" " " "\n" " "] $msg]

        # Never allow a corrupted persistent channel/nick value to inject IRC
        # protocol lines. Normal IRC-supplied nick/channel values already obey
        # these constraints; this primarily protects output paths fed by stored
        # last_chan data.
        # Empty or whitespace-bearing targets are rejected alongside CR/LF, the
        # same way admin_msg already does it: a stored last_chan of "#a #b"
        # would otherwise be pasted in as two protocol parameters, and an empty
        # one produces a malformed NOTICE with the message text as its target.
        if {[string first "\r" $nick] >= 0 || [string first "\n" $nick] >= 0 ||
            [string first "\r" $chan] >= 0 || [string first "\n" $chan] >= 0 ||
            [string length $nick] > 64 || [string length $chan] > 200} {
            putlog "mafia.tcl: refusing unsafe IRC output target"
            return
        }
        set mode [string tolower $output_mode]
        if {$mode eq "channel"} {
            if {$chan eq "" || [string first " " $chan] >= 0} {
                putlog "mafia.tcl: refusing invalid channel output target"
                return
            }
        } elseif {$nick eq "" || [string first " " $nick] >= 0} {
            putlog "mafia.tcl: refusing invalid nick output target"
            return
        }
        switch -- $mode {
            notice  { putserv "NOTICE $nick :$msg" }
            privmsg { putserv "PRIVMSG $nick :$msg" }
            channel { putserv "PRIVMSG $chan :$msg" }
            default {
                putlog "mafia.tcl: invalid output_mode '$output_mode'; using notice"
                putserv "NOTICE $nick :$msg"
            }
        }
    }

    proc jail_expiry_timer {{epoch ""}} {
        variable players
        variable jail_timer_id
        variable jail_epoch
        if {$epoch ne "" && $epoch != $jail_epoch} { return }
        # Schedule first so one malformed player/output error cannot permanently
        # stop jail-expiry processing until the next rehash.
        set jail_timer_id [utimer 5 [list ::mafia::jail_expiry_timer $jail_epoch]]
        set now_ts [now]
        foreach key [array names players *,jail_until] {
            set comma [string first "," $key]
            if {$comma < 1} { continue }
            set k [string range $key 0 [expr {$comma-1}]]
            if {![info exists players($k,jail_until)]} { continue }
            set until $players($k,jail_until)
            # Corrupt/incomplete rows must never turn the periodic timer into
            # an uncaught Tcl error. Validate before doing numeric comparisons.
            if {![command_integer $until 20]} {
                set players($k,jail_until) 0
                set players($k,jail_notified) 0
                continue
            }
            if {$until <= 0 || $now_ts < $until} { continue }
            # A player's name is required before we attempt notification.
            set pname [getf $k name ""]
            if {$pname eq ""} { continue }
            set notified [getf $k jail_notified 0]
            if {![string is integer -strict $notified]} { set notified 0 }
            if {$notified == $until} { continue }
            # Stamp the notification BEFORE the "can we reach them" check, the
            # way hospital_expiry_timer already completes the release before
            # checking. Bailing out first left jail_notified at 0 with
            # jail_until still in the past, so this row was re-examined on
            # every single 5-second tick, forever, for a player who has already
            # been released (in_jail is time-based, so their sentence really is
            # over -- there is just nowhere to announce it).
            set players($k,jail_notified) $until
            set outchan [getf $k last_chan ""]
            if {$outchan eq ""} { continue }
            game_msg $pname $outchan "$pname's jail time is over. You're free to go."
        }
    }

    proc start_jail_expiry_timer {} {
        variable jail_timer_id
        variable jail_epoch
        incr jail_epoch
        if {[info exists jail_timer_id] && $jail_timer_id ne "" && [llength [info commands killutimer]]} {
            catch {killutimer $jail_timer_id}
        }
        set jail_timer_id [utimer 5 [list ::mafia::jail_expiry_timer $jail_epoch]]
    }

    proc hospital_expiry_timer {{epoch ""}} {
        variable players
        variable hospital_timer_id
        variable hospital_epoch
        if {$epoch ne "" && $epoch != $hospital_epoch} { return }
        # Schedule first so one malformed player/output error cannot permanently
        # stop hospital-expiry processing until the next rehash.
        set hospital_timer_id [utimer 5 [list ::mafia::hospital_expiry_timer $hospital_epoch]]
        set now_ts [now]
        foreach key [array names players *,hosp_until] {
            set comma [string first "," $key]
            if {$comma < 1} { continue }
            set k [string range $key 0 [expr {$comma-1}]]
            if {![info exists players($k,hosp_until)]} { continue }
            set until $players($k,hosp_until)
            # Corrupt/incomplete rows must never turn the periodic timer into
            # an uncaught Tcl error. Validate before doing numeric comparisons.
            if {![command_integer $until 20]} {
                set players($k,hosp_until) 0
                set players($k,hosp_notified) 0
                continue
            }
            if {$until <= 0 || $now_ts < $until} { continue }
            # A player's name is required before we attempt notification.
            set pname [getf $k name ""]
            if {$pname eq ""} { continue }
            set notified [getf $k hosp_notified 0]
            if {![string is integer -strict $notified]} { set notified 0 }
            if {$notified == $until} { continue }
            set outchan [getf $k last_chan ""]
            set players($k,hosp_until) 0
            set players($k,hosp_notified) $until
            set dynmax [player_max_health $pname]
            set players($k,health) [expr {int($dynmax / 2)}]
            if {$outchan eq ""} { continue }
            game_msg $pname $outchan "$pname has been released from the hospital, patched up at 50% health."
        }
    }

    proc start_hospital_expiry_timer {} {
        variable hospital_timer_id
        variable hospital_epoch
        incr hospital_epoch
        if {[info exists hospital_timer_id] && $hospital_timer_id ne "" && [llength [info commands killutimer]]} {
            catch {killutimer $hospital_timer_id}
        }
        set hospital_timer_id [utimer 5 [list ::mafia::hospital_expiry_timer $hospital_epoch]]
    }

    proc need_registered {nick chan} {
        if {![exists_player $nick]} {
            game_msg $nick $chan "$nick: you're not in the game yet. Type ${::mafia::cmd_prefix}mafia register to join the family."
            return 0
        }
        return 1
    }

    proc blocked_state {nick chan} {
        # timed_state_left rather than a raw array read: same reasoning as
        # in_jail/in_hospital themselves, and it keeps the displayed remainder
        # and the gate decision reading the exact same value.
        if {[in_jail $nick]} {
            game_msg $nick $chan "$nick: you're in jail for [fmt_secs [timed_state_left $nick jail_until]]. Sit tight or ${::mafia::cmd_prefix}mafia bribe your way out."
            return 1
        }
        if {[in_hospital $nick]} {
            game_msg $nick $chan "$nick: you're laid up in the hospital for [fmt_secs [timed_state_left $nick hosp_until]]."
            return 1
        }
        return 0
    }

}
# mafia_commands_econ.tcl - player-facing economy commands: help, stats,
# jobs, crimes, shop, buy/equip/sell, inventory.
namespace eval mafia {
    ##### =====================================================
    #####                 COMMANDS
    ##### =====================================================

    # !mafiahelp with no argument prints a numbered, alphabetized topic
    # index (one line per topic keyword, e.g. "Account" and "Banking" are
    # listed separately even though they share one underlying help topic).
    # !mafiahelp <topic> prints that topic's commands -- this used to be
    # the separate !mafiaexthelp command, now folded into !mafiahelp itself.
    proc cmd_help {nick chan args} {
        variable cmd_prefix
        set p $cmd_prefix
        if {[llength $args] > 0} {
            set word [lindex $args 0]
            set cat [resolve_help_category $word]
            if {$cat ne ""} {
                send_help_category $nick $chan $cat
                return
            }
            set topic [resolve_help_topic $word]
            if {$topic eq ""} {
                game_msg $nick $chan "No topic matches '$word'. Type ${p}mafiahelp for the topic list."
                return
            }
            send_help_topic $nick $chan $topic
            return
        }
        game_msg $nick $chan "\002Mafia\002 -- become the Don. New here? ${p}mafia register, then ${p}mafia stats and ${p}mafia shop."
        set idx 0
        foreach {cat topics} [help_categories] {
            incr idx
            set names {}
            foreach t $topics { lappend names [string tolower $t] }
            game_msg $nick $chan "\002${idx}. ${cat}:\002 [join $names {, }]. [category_desc $cat]."
        }
        game_msg $nick $chan "Type \002${p}mafiahelp <category|topic>\002 for its commands, e.g. \002${p}mafiahelp fighting\002 or \002${p}mafiahelp combat\002."
    }

    # Four broad groupings over the thirteen underlying help topics, purely
    # for the top-level !mafiahelp index -- resolve_help_topic/send_help_topic
    # and everything else still key off the original thirteen keywords in
    # help_data, so "!mafiahelp combat" etc. are untouched. Order here is
    # the display order for !mafiahelp's numbered index.
    proc help_categories {} {
        return {
            accinfo   {Account Banking Info}
            fighting  {Combat Healing}
            shopinfo  {Inventory Shop Underworld}
            crimeinfo {Casino Crime Drugs Encounters Pimps}
        }
    }

    # One-line blurb for each of the four categories above, shown next to
    # its topic list in !mafiahelp's top-level index. Keep these short --
    # the full per-topic blurbs already live in help_data.
    proc category_desc {cat} {
        switch -- $cat {
            accinfo   { return "manage your character, cash, and stats" }
            fighting  { return "combat and staying healed" }
            shopinfo  { return "gear, carrying capacity, and the black market" }
            crimeinfo { return "earning cash through crime, gambling, and hustles" }
            default   { return "" }
        }
    }

    # Resolves a typed word to one of the four category names above
    # (case-insensitive, exact match only), or "" if it isn't one.
    proc resolve_help_category {word} {
        set norm [string tolower [string trim $word]]
        if {$norm eq ""} { return "" }
        foreach {cat topics} [help_categories] {
            if {[string tolower $cat] eq $norm} { return $cat }
        }
        return ""
    }

    # Lists the sub-topics under a category and points the player at
    # !mafiahelp <topic> for the actual commands.
    proc send_help_category {nick chan cat} {
        variable cmd_prefix
        set p $cmd_prefix
        array set cats [help_categories]
        set names {}
        foreach t $cats($cat) { lappend names [string tolower $t] }
        game_msg $nick $chan "\002$cat\002 covers: [join $names {, }]. Type \002${p}mafiahelp <topic>\002 for one of those, e.g. \002${p}mafiahelp [lindex $names 0]\002."
    }

    ##### =====================================================
    #####                 DETAILED HELP (!mafiahelp <topic>)
    ##### =====================================================
    # Thirteen narrow, single-purpose keywords -- each one owns exactly the
    # commands that belong to it, so "!mafiahelp account" never bleeds into
    # banking, "!mafiahelp drugs" never bleeds into pimps/casino, and so on.
    # Each keyword entry is {aliases {...} blurb "..." cmds {{command
    # description} ...}} -- aliases are the extra words !mafiahelp <word>
    # will match against, on top of the keyword name itself; every alias
    # and command name in here should stay lowercase since matching is
    # case-insensitive. Output is rendered numbered, one command per line,
    # to match the numbered style of !mafiahelp's own topic index.

    proc help_data {} {
        variable cmd_prefix
        set p $cmd_prefix
        return [list \
            Account [list \
                aliases {account register} \
                blurb "create your character; bribe your way out of jail" \
                cmds [list \
                    [list register "create your character. Usage: ${p}mafia register"] \
                    [list bribe    "pay out of jail early. Usage: ${p}mafia bribe"] \
                ] \
            ] \
            Banking [list \
                aliases {bank banking} \
                blurb "move cash to/from the bank so robbers can't touch it" \
                cmds [list \
                    [list deposit  "move cash to the bank (robbers can't touch it). Usage: ${p}mafia deposit <amount|all>"] \
                    [list withdraw "pull cash from the bank. Usage: ${p}mafia withdraw <amount|all>"] \
                ] \
            ] \
            Combat [list \
                aliases {fight fighting pvp} \
                blurb "PvP and NPC fighting, boss fights, robbing, wiretapping" \
                cmds [list \
                    [list fight     "fight cpu|npc|hit|stealth|<nick>. cpu is easy/no kill credit; npc/hit are tougher and count as kills. Usage: ${p}mafia fight <cpu|npc|hit|stealth|nick>"] \
                    [list boss      "challenge the next boss for a guaranteed gear drop on a win. Usage: ${p}mafia boss \[tier 1-20\]"] \
                    [list knife     "melee-attack a player with whatever you have equipped -- no gun needed, but less accurate than shoot. Usage: ${p}mafia knife <nick>"] \
                    [list shoot     "gun down a player; they may duck/block/evade first. Usage: ${p}mafia shoot <nick>"] \
                    [list headshot  "lethal precision shot with a headshot tool bonus; only a hit counts as a kill. Usage: ${p}mafia headshot <nick>"] \
                    [list hit       "fight a hitman NPC (pays richer than a street fight). Usage: ${p}mafia hit"] \
                    [list revenge   "fight a pending hitman revenge crew. Usage: ${p}mafia revenge"] \
                    [list stealth   "sneak-attack a weaker NPC. Usage: ${p}mafia stealth"] \
                    [list rob       "try to steal a player's cash on hand. Usage: ${p}mafia rob <nick>"] \
                    [list wiretap   "listen in on a player for cash and intel. Usage: ${p}mafia wiretap <nick>"] \
                ] \
            ] \
            Healing [list \
                aliases {heal} \
                blurb "patch up with a Medkit, or set up autoheal" \
                cmds [list \
                    [list heal     "fully heal with a Medkit. Usage: ${p}mafia heal"] \
                    [list autoheal "auto-use a Medkit when a hit drops you to/below ${mafia::autoheal_threshold_pct}% health. Usage: ${p}mafia autoheal <on|off>"] \
                ] \
            ] \
            Crime [list \
                aliases {crimes heist heists job jobs joblist jobtier jobtiers} \
                blurb "quick crimes and tiered story jobs for cash/XP" \
                cmds [list \
                    [list crime "attempt a quick crime. Usage: ${p}mafia crime <name>  (list: ${p}mafia crimes)"] \
                    [list job "run a tiered story job for bigger cash/XP. Usage: ${p}mafia job <name>  (list: ${p}mafia joblist \[tier\], your tier: ${p}mafia jobtiers)"] \
                    [list joblist "list available story jobs, all tiers or one. Usage: ${p}mafia joblist \[tier\]"] \
                    [list jobtiers "show your current job tier and how tiers unlock. Usage: ${p}mafia jobtiers"] \
                ] \
            ] \
            Underworld [list \
                aliases {} \
                blurb "fencing stolen goods and browsing the black market" \
                cmds [list \
                    [list fence       "sell stolen goods picked up from crimes. Usage: ${p}mafia fence <item> \[qty\]  (holdings: ${p}mafia goods)"] \
                    [list blackmarket "browse rare black-market stock (also where legendary gear can turn up). Usage: ${p}mafia blackmarket  (buy: ${p}mafia blackbuy <item>)"] \
                ] \
            ] \
            Drugs [list \
                aliases {drug} \
                blurb "the drug market and your dealer network" \
                cmds [list \
                    [list drug "buy/sell drugs (incl. bulk 'all'), your dealer network, and street prices. Usage: ${p}mafia drug prices|buy|sell|dealer|supply|collect"] \
                ] \
            ] \
            Pimps [list \
                aliases {pimp pimping} \
                blurb "pimp workers for passive income" \
                cmds [list \
                    [list pimp "manage workers for passive income. Usage: ${p}mafia pimp prices|buy|sell|collect|workers"] \
                ] \
            ] \
            Casino [list \
                aliases {casinos gamble gambling games} \
                blurb "casino floors, quick-bet dice/slots/cards, and combined price checks" \
                cmds [list \
                    [list casino "show casino floors, slots, dice, cards, and casino options. Usage: ${p}mafia casino"] \
                    [list gamble "quick-bet dice/slots/cards, or run a casino floor for passive income. Usage: ${p}mafia gamble <amt> <game> | prices|buy|collect|status"] \
                    [list prices "one combined price check across drugs, pimps, casino and dealers. Usage: ${p}mafia prices"] \
                ] \
            ] \
            Info [list \
                aliases {stats} \
                blurb "stats/leaderboards -- yours or another player's" \
                cmds [list \
                    [list stats  "show rank/level/cash/health/gear (yours or another player's). Usage: ${p}mafia stats \[nick\]"] \
                    [list don    "show who has reached Don / Master Don. Usage: ${p}mafia don"] \
                    [list topdon "top 5 players by score. Usage: ${p}mafia topdon"] \
                ] \
            ] \
            Shop [list \
                aliases {shopping gear} \
                blurb "browse, buy, and equip gear" \
                cmds [list \
                    [list shop  "list everything buyable. Usage: ${p}mafia shop \[weapons|armor|tools|ice\]"] \
                    [list buy   "buy a weapon/armor/tool/ice. Usage: ${p}mafia buy <item>"] \
                    [list equip "equip an owned weapon/armor/bling. Usage: ${p}mafia equip <item>"] \
                ] \
            ] \
            Inventory [list \
                aliases {inv} \
                blurb "what you're carrying, your legendary set progress, and selling/liquidating gear" \
                cmds [list \
                    [list inventory "list what you're carrying. Usage: ${p}mafia inventory"] \
                    [list legend    "your legendary set progress -- 4 pieces that outclass boss gear and re-scale to your level, only found rarely on the black market. Usage: ${p}mafia legend"] \
                    [list sell      "sell gear back, or liquidate gear/drugs/goods/everything at once. Usage: ${p}mafia sell <item|gear|drugs|goods|all>"] \
                ] \
            ] \
            Encounters [list \
                aliases {encounter ambient police thug} \
                blurb "responding to ambient police/street encounters" \
                cmds [list \
                    [list faceoff "fight a pending random encounter. Usage: ${p}mafia faceoff"] \
                    [list talk    "try to talk your way out of one. Usage: ${p}mafia talk"] \
                    [list run     "flee a pending encounter. Usage: ${p}mafia run"] \
                    [list hide    "duck out of sight (also works on an encounter). Usage: ${p}mafia hide  /  ${p}mafia unhide"] \
                    [list payoff  "pay a flat fee to a police encounter to walk. Usage: ${p}mafia payoff"] \
                ] \
            ] \
        ]
    }

    # Keyword names in a fixed, sensible reading order (not alphabetical --
    # Account first, Encounters last). help_index_entries re-sorts its
    # output alphabetically for !mafiahelp's index, but every other consumer
    # (resolve_help_topic, send_help_topic, etc.) just needs a stable
    # iteration order, which this provides.
    proc help_topic_order {} {
        return {Account Banking Combat Healing Crime Underworld \
                Drugs Pimps Casino Info Shop Inventory Encounters}
    }

    # Resolves a typed word (keyword name, partial name, or alias) to
    # exactly one canonical keyword from help_data, or "" if it matches
    # none or matches more than one ambiguously.
    proc resolve_help_topic {word} {
        set data [help_data]
        set norm [string tolower [string trim $word]]
        if {$norm eq ""} { return "" }
        # Exact keyword-name match first (case-insensitive).
        foreach topic [help_topic_order] {
            if {[string tolower $topic] eq $norm} { return $topic }
        }
        # Exact alias match next.
        foreach topic [help_topic_order] {
            set aliases [dict get [dict get $data $topic] aliases]
            if {[lsearch -exact $aliases $norm] >= 0} { return $topic }
        }
        # Finally, a substring match against the keyword name or its
        # aliases, so "!mafiahelp drug" or "!mafiahelp shop" work without
        # the player needing to type the exact keyword.
        set hits {}
        foreach topic [help_topic_order] {
            set aliases [dict get [dict get $data $topic] aliases]
            set hay [string tolower $topic]
            foreach a $aliases { append hay " $a" }
            if {[string first $norm $hay] >= 0 && [lsearch -exact $hits $topic] < 0} {
                lappend hits $topic
            }
        }
        if {[llength $hits] == 1} { return [lindex $hits 0] }
        return ""
    }

    # Renders one keyword's commands, numbered one-per-line to match the
    # numbered style of !mafiahelp's own topic index.
    proc send_help_topic {nick chan topic} {
        variable cmd_prefix
        set p $cmd_prefix
        set data [help_data]
        if {![dict exists $data $topic]} { return }
        set cmds [dict get $data $topic cmds]
        set sorted [lsort -index 0 $cmds]
        game_msg $nick $chan "\002$topic\002 -- [dict get $data $topic blurb]:"
        set idx 0
        foreach entry $sorted {
            lassign $entry cname desc
            incr idx
            game_msg $nick $chan "\002${idx}.\002 \002${p}mafia ${cname}\002: $desc"
        }
    }

    # Returns a flat {word blurb word blurb ...} list, one pair per keyword,
    # alphabetized by word -- the data behind !mafiahelp's numbered index.
    proc help_index_entries {} {
        set data [help_data]
        set pairs {}
        foreach topic [help_topic_order] {
            lappend pairs [list $topic [dict get $data $topic blurb]]
        }
        set pairs [lsort -index 0 $pairs]
        set entries {}
        foreach pair $pairs {
            lassign $pair word blurb
            lappend entries $word $blurb
        }
        return $entries
    }

    proc cmd_register {nick chan} {
        variable players
        variable meta_key
        if {[string tolower $nick] eq $meta_key} {
            game_msg $nick $chan "$nick: that name is reserved. Pick a different nick to join the family."
            return
        }
        if {[exists_player $nick]} {
            game_msg $nick $chan "$nick: you're already in the family."
            return
        }
        if {![register_allowed]} {
            game_msg $nick $chan "$nick: the family is taking on a lot of new blood right now -- try again in a minute."
            return
        }
        new_player $nick
        set players([string tolower $nick],last_chan) $chan
        game_msg $nick $chan "Welcome to the family, $nick. You start with [fmt_cash $mafia::start_cash] and a pair of fists. Type ${::mafia::cmd_prefix}mafiahelp to get started."
    }

    proc cmd_stats {nick chan args} {
        set target $nick
        if {[llength $args] > 0} { set target [lindex $args 0] }
        if {![exists_player $target]} {
            game_msg $nick $chan "$target isn't in the game."
            return
        }
        variable players
        # !mafia stats <nick> reads another player's row field by field, and
        # that row is only ever repaired by commands THEY type. Normalize (and
        # seed the gear lists) before the first read, not after: weapon/armor
        # were read one line ahead of ensure_gear_lists, so on a row that
        # predates those fields the command died on the read it was supposed to
        # be protected from.
        normalize_player_economy $target
        sync_level_stats $target
        ensure_gear_lists $target
        set k [string tolower $target]
        set rank [expr {[getf $target boss_tier_cleared 0] >= 20 ? "Master Don" : [rank_for_xp $players($k,xp)]}]
        set lvl [player_level $target]
        set wpn [weapon_name $players($k,weapon)]
        set arm [armor_name $players($k,armor)]
        set bl [bling_name $players($k,bling)]
        set items $players($k,items)
        set toolstr [expr {[llength $items]>0 ? [join $items {, }] : {none}}]
        set status "on the streets"
        if {[in_jail $target]} {
            set status "in jail ([fmt_secs [timed_state_left $target jail_until]])"
        } elseif {[in_hospital $target]} {
            set status "hospitalized ([fmt_secs [timed_state_left $target hosp_until]])"
        } elseif {[is_hidden $target]} {
            set status "hiding"
        }
        game_msg $nick $chan "\002$players($k,name)\002 \[Lv.$lvl - $rank\] -- HP: $players($k,health)/[getf $target health_max $mafia::max_health] | Cash: [fmt_cash $players($k,cash)] | Bank: [fmt_cash $players($k,bank)] | XP: $players($k,xp) (next Lv in [xp_to_next_level $players($k,xp)])"
        game_msg $nick $chan "Weapon: $wpn | Armor: $arm | Bling: $bl | Total ice bonus: +[player_bling_pct $target]% stats | Kills: $players($k,kills) | Deaths: $players($k,deaths) | Status: $status"
        game_msg $nick $chan "Tools: $toolstr"
        set total_workers 0
        foreach tier [array names ::mafia::pimp_workers] {
            set total_workers [expr {$total_workers + [getf $target pimp,$tier 0] + [getf $target pimp_jail,$tier 0]}]
        }
        set drugstr [list]
        foreach d [array names ::mafia::drugs] {
            set dqty [getf $target drug,$d 0]
            if {$dqty > 0} { lappend drugstr "$d:$dqty" }
        }
        game_msg $nick $chan "Workers: $total_workers"
        game_msg $nick $chan "Drugs: [expr {[llength $drugstr]>0 ? [join $drugstr {, }] : {none}}]"
        game_msg $nick $chan "Pickpocket: [get_stat $target pickpocket]% | Dexterity: [get_stat $target dexterity]% | Accuracy: [get_stat $target accuracy]% | Stealth: [get_stat $target stealth]% | Evasion: [armor_evasion $players($k,armor) $target]% (armor only)"
        set __legend_held [legend_pieces_owned $target]
        if {$__legend_held > 0} {
            game_msg $nick $chan "Legendary set: $__legend_held/4 -- +[legend_stat_pct $target]% all stats, +[legend_collect_pct $target]% collections. See ${mafia::cmd_prefix}mafia legend"
        }
        variable boss_names
        set cleared [getf $target boss_tier_cleared 0]
        # 20 boss tiers, Lv.50 through Lv.1000 (Master Don). This used to read
        # 10, left over from the pre-expansion tier count, so a player halfway
        # through the ladder was told every boss in the game was already dead.
        if {$cleared >= 20} {
            game_msg $nick $chan "Tier: 20/20 -- every boss in the game is dead, Master Don included. Tier 20 stays farmable for gear."
        } else {
            set nexttier [expr {$cleared+1}]
            set bname [lindex $boss_names [expr {$nexttier-1}]]
            set raw [level_for_xp $players($k,xp)]
            if {$raw >= $nexttier*50} {
                game_msg $nick $chan "Tier: $cleared/20 cleared -- Level/XP continue normally."
            } else {
                game_msg $nick $chan "Tier: $cleared/20 cleared -- next stop is \002$bname\002 at Lv.[expr {$nexttier*50}]."
            }
        }
    }

    proc cmd_crimelist {nick chan} {
        variable crimes
        game_msg $nick $chan "Available crimes: [join [lsort [array names crimes]] {, }]  -- use ${mafia::cmd_prefix}mafia crime <name>"
    }

    proc job_tier_for_xp {xp} {
        # bracket 1 = levels 1-50, bracket 2 = 51-100, etc, based on level_for_xp
        set lvl [level_for_xp $xp]
        return [expr {min((($lvl-1)/50)+1, 10)}]
    }

    # A player's XP/level alone can imply a higher tier than they're actually
    # allowed into -- tier N+1 is boss-gated behind clearing tier N. This is
    # the single source of truth for "what tier can this player really play
    # right now", used by both !mafia jobtiers and !mafia joblist so the
    # two commands can't drift out of sync with each other.
    proc job_tier_capped {nick} {
        variable players
        set k [string tolower $nick]
        set xptier [job_tier_for_xp $players($k,xp)]
        set cleared [getf $nick boss_tier_cleared 0]
        set capped [expr {$cleared+1}]
        return [expr {min($xptier,$capped)}]
    }

    proc cmd_jobtiers {nick chan} {
        if {![need_registered $nick $chan]} return
        variable players
        variable boss_names
        set k [string tolower $nick]
        set xptier [job_tier_for_xp $players($k,xp)]
        set cleared [getf $nick boss_tier_cleared 0]
        set capped [expr {$cleared+1}]
        set mytier [job_tier_capped $nick]
        if {$xptier > $capped} {
            set bname [lindex $boss_names [expr {$capped-1}]]
            game_msg $nick $chan "$nick: your job tier is $mytier (Lv.[player_level $nick]) -- XP alone would put you at tier $xptier, but you're locked out until you beat \002$bname\002. Use ${mafia::cmd_prefix}mafia boss."
        } else {
            game_msg $nick $chan "$nick: your job tier is $mytier (Lv.[player_level $nick]). Job tiers run 1-10 across levels 1-500 (separate from the 1-20 boss tiers). Use ${mafia::cmd_prefix}mafia joblist \[tier\] to browse."
        }
    }

    proc cmd_joblist {nick chan args} {
        if {![need_registered $nick $chan]} return
        variable jobs
        variable players
        variable boss_names
        set k [string tolower $nick]
        set mytier [job_tier_capped $nick]
        set tier [expr {[llength $args] > 0 ? [lindex $args 0] : $mytier}]
        if {![command_integer $tier 4] || $tier < 1 || $tier > 10} {
            game_msg $nick $chan "$nick: tier must be 1-10. Usage: ${mafia::cmd_prefix}mafia joblist \[tier\]"
            return
        }
        set names {}
        foreach name [lsort [array names jobs]] {
            lassign $jobs($name) qmin qcmin qcmax qxmin qxmax qfail qjail qsucc qfail_msg qtier
            if {$qtier == $tier} { lappend names $name }
        }
        if {[llength $names] == 0} {
            game_msg $nick $chan "No jobs found for tier $tier."
            return
        }
        if {$tier > $mytier} {
            set bname [lindex $boss_names [expr {$mytier-1}]]
            game_msg $nick $chan "\002Tier $tier jobs\002 ([llength $names] available) -- [join $names {, }]"
            game_msg $nick $chan "$nick: \002heads up\002 -- these are still locked for you. Beat \002$bname\002 with ${mafia::cmd_prefix}mafia boss to unlock tier $tier jobs."
        } else {
            game_msg $nick $chan "\002Tier $tier jobs\002 ([llength $names] available) -- [join $names {, }]"
        }
    }

    proc cmd_job {nick chan args} {
        normalize_player_economy $nick
        variable jobs
        variable job_cooldown
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia job <name> -- see ${mafia::cmd_prefix}mafia joblist \[tier\]"
            return
        }
        set qname [string tolower [lindex $args 0]]
        if {![info exists jobs($qname)]} {
            game_msg $nick $chan "No such job. See ${mafia::cmd_prefix}mafia joblist"
            return
        }
        variable players
        set k [string tolower $nick]
        if {![info exists players($k,last_job)]} { set players($k,last_job) 0 }
        set elapsed [expr {[now] - $players($k,last_job)}]
        if {$elapsed < $job_cooldown} {
            game_msg $nick $chan "$nick: still cleaning up from your last job. [fmt_secs [expr {$job_cooldown - $elapsed}]] left."
            return
        }
        lassign $jobs($qname) min_xp cmin cmax xmin xmax fail jailrisk succ_msg fail_msg tier
        if {$players($k,xp) < $min_xp} {
            game_msg $nick $chan "$nick: too big a job for you yet. Requires $min_xp XP (tier $tier)."
            return
        }
        variable boss_names
        set cleared [getf $nick boss_tier_cleared 0]
        if {$cleared < $tier-1} {
            set bname [lindex $boss_names [expr {$tier-2}]]
            game_msg $nick $chan "$nick: tier $tier jobs are off-limits until you beat \002$bname\002. Use ${mafia::cmd_prefix}mafia boss."
            return
        }
        set players($k,last_job) [now]

        variable jail_risk_multiplier
        set fmod $fail
        set jmod $jailrisk
        if {[has_item $nick lockpick]} { set fmod [expr {max(0,$fmod-5)}] }
        if {[has_item $nick biometric_ledger]} { set fmod [expr {max(0,$fmod-5)}] }
        if {[has_item $nick armored_car]} { set jmod [expr {max(0,$jmod-10)}] }
        # jail_risk_multiplier is a namespace config value. This used to read
        # it through getf, which looks up a PLAYER field -- so the configured
        # value was ignored, the 0.5 default was hardcoded per player, and a
        # junk jail_risk_multiplier field was created and persisted on every
        # player row that ever ran a job or crime.
        set jmod [expr {max(0,int($jmod*$jail_risk_multiplier-[catch_mod $nick]))}]
        if {[use_bm_item $nick ghost_plates]} {
            set jmod [expr {max(0,$jmod-15)}]
            game_msg $nick $chan "$nick: ghost plates keep the cops guessing."
        }
        if {[use_bm_item $nick laser_cutter]} {
            set jmod [expr {max(0,$jmod-20)}]
            game_msg $nick $chan "$nick: the laser cutter makes short work of the lock, in and out."
        }
        if {[use_bm_item $nick submersible_car]} {
            set jmod [expr {max(0,$jmod-20)}]
            game_msg $nick $chan "$nick: you vanish underwater before the cops even arrive."
        }
        if {[use_bm_item $nick thermal_scope]} {
            set fmod [expr {max(0,$fmod-10)}]
            game_msg $nick $chan "$nick: the thermal scope shows you exactly where everyone is."
        }
        if {[use_bm_item $nick micro_camera]} {
            set fmod [expr {max(0,$fmod-10)}]
            game_msg $nick $chan "$nick: the micro camera feeds you eyes on the whole job."
        }
        set forced_win 0
        if {[use_bm_item $nick insider_tip]} {
            set forced_win 1
            game_msg $nick $chan "$nick: your insider tip pays off before you even move."
        }
        if {[use_bm_item $nick exploding_pen]} {
            set forced_win 1
            game_msg $nick $chan "$nick: the exploding pen clears every obstacle in your way."
        }

        set roll [expr {int(rand()*100)}]
        if {!$forced_win && $roll < $fmod} {
            set jroll [expr {int(rand()*100)}]
            if {$jroll < max(0,$jmod-[boss_bonus_pct $nick resist_jail])} {
                if {[use_bm_item $nick fake_id]} {
                    game_msg $nick $chan "$nick: $fail_msg You flash a fake ID and the cops let you walk."
                    return
                }
                if {[use_bm_item $nick emp_device]} {
                    game_msg $nick $chan "$nick: $fail_msg You trigger the EMP and every camera and cruiser nearby goes dark."
                    return
                }
                variable jail_time
                set players($k,jail_until) [expr {[now] + ($jail_time*60)}]
                set players($k,jail_notified) 0
                game_msg $nick $chan "\002BUSTED!\002 $nick: $fail_msg You're hauled off to jail for ${jail_time}m."
            } else {
                game_msg $nick $chan "$nick: $fail_msg You get away empty-handed."
            }
            return
        }
        variable job_cash_mult
        set cash [expr {($cmin + int(rand()*($cmax-$cmin+1))) * max(14,$job_cash_mult)}]
        set oldrank [rank_for_xp $players($k,xp)]
        set oldlvl  [player_level $nick]
        # Use the player's RAW xp-derived level here, not the boss-tier-capped
        # player_level, so a player sitting right at their xp ceiling still
        # gets a sensible target_level instead of one based on a lower
        # capped level.
        #
        # The target level used to be min(500,...) and the target XP came from
        # indexing level_thresholds, both left over from the Lv.500 era. At
        # Lv.500+ the target collapsed onto the player's own level, so
        # target_xp - current xp went negative and every job paid out the
        # max(1,...) floor: exactly 1 XP, forever, at the level where jobs
        # are the main XP source. xp_for_level is the same curve without the
        # 1000-entry table's ceiling, so this now keeps working above Lv.1000
        # where levels are unbounded.
        set current_level [level_for_xp $players($k,xp)]
        set target_level [expr {$current_level + 5 + int(rand()*10)}]
        set target_xp [xp_for_level $target_level]
        set xp [expr {max(1,$target_xp-$players($k,xp))}]
        set cash [reward_cash $nick $cash]
        set xp [reward_xp $nick $xp]
        sync_level_stats $nick
        set newrank [rank_for_xp $players($k,xp)]
        set newlvl  [player_level $nick]
        game_msg $nick $chan "$nick: $succ_msg +[fmt_cash $cash], +$xp XP."
        if {$newlvl > $oldlvl} {
            game_msg $nick $chan "\002$nick leveled up to Lv.$newlvl!\002"
        }
        if {$newrank ne $oldrank} {
            game_msg $nick $chan "\002$nick has been promoted to $newrank!\002"
            if {$newrank eq "Don"} {
                game_msg $nick $chan "\002\00304ALL RISE -- $nick is the new DON of the family!\003\002"
            }
        }
    }

    proc cmd_crime {nick chan args} {
        normalize_player_economy $nick
        variable crimes
        variable crime_cooldown
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia crime <name> -- see ${mafia::cmd_prefix}mafia crimes"
            return
        }
        set cname [string tolower [lindex $args 0]]
        if {![info exists crimes($cname)]} {
            game_msg $nick $chan "No such crime. See ${mafia::cmd_prefix}mafia crimes"
            return
        }
        variable players
        set k [string tolower $nick]
        set elapsed [expr {[now] - $players($k,last_crime)}]
        if {$elapsed < $crime_cooldown} {
            game_msg $nick $chan "$nick: catch your breath. [fmt_secs [expr {$crime_cooldown - $elapsed}]] before you can pull another job."
            return
        }
        lassign $crimes($cname) min_xp cmin cmax xmin xmax fail jailrisk succ_msg fail_msg
        if {$players($k,xp) < $min_xp} {
            game_msg $nick $chan "$nick: you're not experienced enough for that job yet. ($min_xp XP required)"
            return
        }
        set players($k,last_crime) [now]

        # Utility tools reduce risk; baseline jail risk is intentionally
        # lower so normal play does not constantly drain cash through jail.
        variable jail_risk_multiplier
        set fmod $fail
        # Apply the configured multiplier exactly once. It used to be applied
        # here AND again below through getf (which reads a player field, not
        # this config), so crime jail risk was silently quartered instead of
        # halved and the admin config knob did nothing.
        set jmod [expr {int($jailrisk*$jail_risk_multiplier)}]
        if {[has_item $nick lockpick]} { set fmod [expr {max(0,$fmod-5)}] }
        if {[has_item $nick biometric_ledger]} { set fmod [expr {max(0,$fmod-5)}] }
        if {[has_item $nick armored_car]} { set jmod [expr {max(0,$jmod-10)}] }
        if {$cname eq "pickpocket" || $cname eq "shoplift"} {
            set fmod [expr {max(0,$fmod-int([get_stat $nick pickpocket]/5))}]
        }
        set jmod [expr {max(0,int($jmod-[catch_mod $nick]))}]
        if {[use_bm_item $nick ghost_plates]} {
            set jmod [expr {max(0,$jmod-15)}]
            game_msg $nick $chan "$nick: ghost plates keep the cops guessing."
        }
        if {[use_bm_item $nick laser_cutter]} {
            set jmod [expr {max(0,$jmod-20)}]
            game_msg $nick $chan "$nick: the laser cutter makes short work of the lock, in and out."
        }
        if {[use_bm_item $nick submersible_car]} {
            set jmod [expr {max(0,$jmod-20)}]
            game_msg $nick $chan "$nick: you vanish underwater before the cops even arrive."
        }
        if {[use_bm_item $nick thermal_scope]} {
            set fmod [expr {max(0,$fmod-10)}]
            game_msg $nick $chan "$nick: the thermal scope shows you exactly where everyone is."
        }
        if {[use_bm_item $nick micro_camera]} {
            set fmod [expr {max(0,$fmod-10)}]
            game_msg $nick $chan "$nick: the micro camera feeds you eyes on the whole job."
        }
        set forced_win 0
        if {[use_bm_item $nick insider_tip]} {
            set forced_win 1
            game_msg $nick $chan "$nick: your insider tip pays off before you even move."
        }
        if {[use_bm_item $nick exploding_pen]} {
            set forced_win 1
            game_msg $nick $chan "$nick: the exploding pen clears every obstacle in your way."
        }

        set roll [expr {int(rand()*100)}]
        if {!$forced_win && $roll < $fmod} {
            # failed - possible jail
            set jroll [expr {int(rand()*100)}]
            if {$jroll < max(0,$jmod-[boss_bonus_pct $nick resist_jail])} {
                if {[use_bm_item $nick fake_id]} {
                    game_msg $nick $chan "$nick: $fail_msg You flash a fake ID and the cops let you walk."
                    return
                }
                if {[use_bm_item $nick emp_device]} {
                    game_msg $nick $chan "$nick: $fail_msg You trigger the EMP and every camera and cruiser nearby goes dark."
                    return
                }
                variable jail_time
                set players($k,jail_until) [expr {[now] + ($jail_time*60)}]
                set players($k,jail_notified) 0
                game_msg $nick $chan "\002BUSTED!\002 $nick: $fail_msg You're hauled off to jail for ${jail_time}m."
            } else {
                game_msg $nick $chan "$nick: $fail_msg You get away empty-handed."
            }
            return
        }
        set cash [expr {$cmin + int(rand()*($cmax-$cmin+1))}]
        set xp   [expr {$xmin + int(rand()*($xmax-$xmin+1))}]
        set cash [reward_cash $nick $cash]
        set oldrank [rank_for_xp $players($k,xp)]
        set oldlvl  [player_level $nick]
        set xp [reward_xp $nick $xp]
        sync_level_stats $nick
        set newrank [rank_for_xp $players($k,xp)]
        set newlvl  [player_level $nick]
        set gooddisp [maybe_drop_goods $nick $cname]
        if {$gooddisp ne ""} {
            game_msg $nick $chan "$nick: $succ_msg +[fmt_cash $cash], +$xp XP. You also walk off with some $gooddisp -- fence it with ${mafia::cmd_prefix}mafia fence."
        } else {
            game_msg $nick $chan "$nick: $succ_msg +[fmt_cash $cash], +$xp XP."
        }
        if {$newlvl > $oldlvl} {
            game_msg $nick $chan "\002$nick leveled up to Lv.$newlvl!\002"
        }
        if {$newrank ne $oldrank} {
            game_msg $nick $chan "\002$nick has been promoted to $newrank!\002"
            if {$newrank eq "Don"} {
                game_msg $nick $chan "\002\00304ALL RISE -- $nick is the new DON of the family!\003\002"
            }
        }
    }

    proc cmd_shop_weapons {nick chan} {
        variable shop_weapons
        game_msg $nick $chan "\002-- Weapons --\002"
        foreach w [lsort [array names shop_weapons]] {
            lassign $shop_weapons($w) disp price dmg
            game_msg $nick $chan "  $w: $disp - [fmt_cash $price] (dmg $dmg)"
        }
    }

    proc cmd_shop_armor {nick chan} {
        variable shop_armor
        game_msg $nick $chan "\002-- Armor --\002"
        foreach a [lsort [array names shop_armor]] {
            lassign $shop_armor($a) disp price red evasion
            game_msg $nick $chan "  $a: $disp - [fmt_cash $price] (reduces dmg $red, evasion ${evasion}%)"
        }
    }

    proc cmd_shop_tools {nick chan} {
        variable shop_tools
        game_msg $nick $chan "\002-- Tools --\002"
        foreach t [lsort [array names shop_tools]] {
            lassign $shop_tools($t) disp price eff
            game_msg $nick $chan "  $t: $disp - [fmt_cash $price] ($eff)"
        }
    }

    proc cmd_shop_ice {nick chan} {
        variable shop_bling
        variable bling_tiers
        game_msg $nick $chan "\002-- Ice (Bling) --\002"
        foreach b $bling_tiers {
            if {$b eq "none"} continue
            lassign $shop_bling($b) disp price pct
            set econp [bling_econ_pct $b]
            game_msg $nick $chan "  $b: $disp - [fmt_cash $price] (+${pct}% to all stats, -${econp}% drug/pimp buys, +${econp}% drug/pimp sales)"
        }
    }

    proc cmd_shop {nick chan args} {
        if {[llength $args] > 0} {
            set cat [string tolower [lindex $args 0]]
            switch -- $cat {
                weapon - weapons {
                    cmd_shop_weapons $nick $chan
                    game_msg $nick $chan "Buy with ${mafia::cmd_prefix}mafia buy <item>. Equip with ${mafia::cmd_prefix}mafia equip <item>."
                }
                armor {
                    cmd_shop_armor $nick $chan
                    game_msg $nick $chan "Buy with ${mafia::cmd_prefix}mafia buy <item>. Equip with ${mafia::cmd_prefix}mafia equip <item>."
                }
                tool - tools {
                    cmd_shop_tools $nick $chan
                    game_msg $nick $chan "Buy with ${mafia::cmd_prefix}mafia buy <item>."
                }
                ice - bling {
                    cmd_shop_ice $nick $chan
                    game_msg $nick $chan "Buy with ${mafia::cmd_prefix}mafia buy <item>. Equip with ${mafia::cmd_prefix}mafia equip <item>."
                }
                default {
                    game_msg $nick $chan "Unknown category. Usage: ${mafia::cmd_prefix}mafia shop \[weapons|armor|tools|ice\]"
                    return
                }
            }
            return
        }
        game_msg $nick $chan "Categories: \002Weapons\002, \002Armor\002, \002Tools\002, and \002Ice\002."
        game_msg $nick $chan "1. \002Weapons\002: melee and firearms, raise your attack damage."
        game_msg $nick $chan "2. \002Armor\002: gear that reduces incoming damage and grants 5%-40% armor-only evasion."
        game_msg $nick $chan "3. \002Tools\002: utility items for crimes and getaways."
        game_msg $nick $chan "4. \002Ice\002: bling that boosts all stats and shifts drug/pimp economics. Equip it with ${mafia::cmd_prefix}mafia equip <item>."
        game_msg $nick $chan "See a category with ${mafia::cmd_prefix}mafia shop <weapons|armor|tools|ice>."
    }

    proc cmd_buy {nick chan args} {
        if {![need_registered $nick $chan]} return
        normalize_player_economy $nick
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia buy <item>  OR  ${mafia::cmd_prefix}mafia buy drugs all <amt>"
            return
        }

        # "!mafia buy drugs all <amt>" -- bulk-buys <amt> of every drug in
        # one shot instead of running !mafia drug buy <drug> <amt> once per
        # drug. Same cooldown/bust/econ rules as a normal drug buy, just
        # applied once across the whole basket.
        if {[string tolower [lindex $args 0]] eq "drugs"} {
            if {[llength $args] < 3 || [string tolower [lindex $args 1]] ne "all"} {
                game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia buy drugs all <amt>"
                return
            }
            cmd_buy_drugs_all $nick $chan [lindex $args 2]
            return
        }

        variable players
        variable shop_weapons
        variable shop_armor
        variable shop_tools
        variable shop_bling
        ensure_gear_lists $nick
        set item [resolve_item_key $args]
        set k [string tolower $nick]
        set price -1
        set kind ""
        if {[info exists shop_weapons($item)]} { set price [lindex $shop_weapons($item) 1]; set kind weapon }
        if {[info exists shop_armor($item)]}   { set price [lindex $shop_armor($item) 1]; set kind armor }
        if {[info exists shop_tools($item)]}   { set price [lindex $shop_tools($item) 1]; set kind tool }
        if {[info exists shop_bling($item)] && $item ne "none"} { set price [lindex $shop_bling($item) 1]; set kind bling }
        if {$kind eq ""} {
            game_msg $nick $chan "No such item. See ${mafia::cmd_prefix}mafia shop"
            return
        }
        if {$kind eq "weapon" && [lsearch -exact $players($k,owned_weapons) $item] >= 0} {
            game_msg $nick $chan "$nick: you already own that. Use ${mafia::cmd_prefix}mafia equip $item to switch to it."
            return
        }
        if {$kind eq "armor" && [lsearch -exact $players($k,owned_armor) $item] >= 0} {
            game_msg $nick $chan "$nick: you already own that. Use ${mafia::cmd_prefix}mafia equip $item to switch to it."
            return
        }
        if {$kind eq "bling" && [lsearch -exact $players($k,owned_bling) $item] >= 0} {
            game_msg $nick $chan "$nick: you already own that. Use ${mafia::cmd_prefix}mafia equip $item to switch to it."
            return
        }
        if {$kind eq "tool" && [has_item $nick $item]} {
            game_msg $nick $chan "$nick: you already have one of those."
            return
        }
        if {$players($k,cash) < $price} {
            game_msg $nick $chan "$nick: you can't afford that. Need [fmt_cash $price], you have [fmt_cash $players($k,cash)]."
            return
        }
        set players($k,cash) [expr {$players($k,cash)-$price}]
        switch -- $kind {
            weapon {
                lappend players($k,owned_weapons) $item
                if {[gear_upgrade_ok $nick $item weapon]} {
                    set players($k,weapon) $item
                    game_msg $nick $chan "$nick: bought and equipped [weapon_name $item] for [fmt_cash $price]."
                } else {
                    game_msg $nick $chan "$nick: bought [weapon_name $item] for [fmt_cash $price]. Your current weapon is better, so it stays equipped."
                }
            }
            armor {
                lappend players($k,owned_armor) $item
                if {[gear_upgrade_ok $nick $item armor]} {
                    set players($k,armor) $item
                    game_msg $nick $chan "$nick: bought and equipped [armor_name $item] for [fmt_cash $price]."
                } else {
                    game_msg $nick $chan "$nick: bought [armor_name $item] for [fmt_cash $price]. Your current armor is better, so it stays equipped."
                }
            }
            bling {
                lappend players($k,owned_bling) $item
                set pct [bling_bonus_pct $item $nick]
                # Match the weapon/armor rule (and cmd_equip's): buying a
                # weaker chain must never silently unequip a better one.
                if {[gear_upgrade_ok $nick $item bling bling]} {
                    set players($k,bling) $item
                    game_msg $nick $chan "$nick: bought and equipped [bling_name $item] for [fmt_cash $price]. (+${pct}% stats, -[bling_econ_pct $item $nick]% drug/pimp buys, +[bling_econ_pct $item $nick]% drug/pimp sales)"
                } else {
                    game_msg $nick $chan "$nick: bought [bling_name $item] for [fmt_cash $price]. Your current [bling_name $players($k,bling)] is better, so it stays equipped."
                }
            }
            tool { give_item $nick $item; game_msg $nick $chan "$nick: bought [lindex $shop_tools($item) 0] for [fmt_cash $price]." }
        }
    }

    proc cmd_equip {nick chan args} {
        if {![need_registered $nick $chan]} return
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia equip <item>"
            return
        }
        variable players
        variable shop_weapons
        variable shop_armor
        variable shop_bling
        variable boss_bling
        ensure_gear_lists $nick
        set k [string tolower $nick]

        set item [resolve_item_key $args]
        if {$item eq $players($k,weapon) || $item eq $players($k,armor) || $item eq $players($k,bling)} {
            game_msg $nick $chan "$nick: already equipped."
            return
        }
        if {[is_valid_weapon_key $item] && [item_owned_weapon $nick $item]} {
            if {![gear_upgrade_ok $nick $item weapon]} {
                game_msg $nick $chan "$nick: you can't downgrade your weapon. [weapon_name $item] is not stronger than your current [weapon_name $players($k,weapon)]."
                return
            }
            set players($k,weapon) $item
            game_msg $nick $chan "$nick: equipped [weapon_name $item]."
        } elseif {[is_valid_armor_key $item] && [item_owned_armor $nick $item]} {
            if {![gear_upgrade_ok $nick $item armor]} {
                game_msg $nick $chan "$nick: you can't downgrade your armor. [armor_name $item] is not stronger than your current [armor_name $players($k,armor)]."
                return
            }
            set players($k,armor) $item
            game_msg $nick $chan "$nick: equipped [armor_name $item]."
        } elseif {[is_valid_bling_key $item] && [item_owned_bling $nick $item]} {
            if {![gear_upgrade_ok $nick $item bling bling]} {
                game_msg $nick $chan "$nick: you can't downgrade your Chain ice. [bling_name $item] isn't better than what you're wearing."
                return
            }
            set players($k,bling) $item
            game_msg $nick $chan "$nick: equipped [bling_name $item] in your Chain slot. (+[bling_bonus_pct $item $nick]% to all stats, +[bling_econ_pct $item $nick]% econ)"
        } else {
            game_msg $nick $chan "$nick: you don't own that. Buy it first with ${mafia::cmd_prefix}mafia buy."
        }
    }

    # Sells one unit of a single owned gear/tool item back to the shop.
    # Returns 1 on success (cash already applied to $nick), 0 on failure
    # (msg already sent to the player).
    proc sell_one_gear_item {nick chan item} {
        variable players
        ensure_gear_lists $nick
        set k [string tolower $nick]
        # Boss tools are permanent bonuses rather than inventory items, but
        # they can still be sold manually. Selling one removes only that
        # tool's own stored bonus; sell-all never reaches this path.
        # The ownership test must be on the VALUE, not on the key's presence.
        # normalize_player_economy used to create boss_tool_<item> = 0 rows for
        # all 20 tools on every command (getf seeds its default into the
        # array), so [info exists] was true for tools the player had never
        # owned -- selling one paid out 8,000 with no tool involved, unset the
        # row, and the next command recreated it. An unlimited money printer at
        # one command per cycle. Pass 7 stopped manufacturing those rows; this
        # closes the door itself so it cannot reopen.
        if {[info exists ::mafia::boss_tools($item)] &&
            [info exists players($k,boss_tool_$item)] &&
            [string is integer -strict $players($k,boss_tool_$item)] &&
            $players($k,boss_tool_$item)} {
            set val [resale_value $item $nick]
            # Non-creating read -- getf would seed an empty row for a bonus
            # record that isn't there.
            set rec [expr {[info exists players($k,boss_tool_bonus_$item)] ? $players($k,boss_tool_bonus_$item) : ""}]
            if {$rec ne ""} {
                lassign [split $rec |] stat amount
                if {[string is integer -strict $amount] && $amount > 0} {
                    incr players($k,boss_bonus_$stat) [expr {-$amount}]
                    if {$players($k,boss_bonus_$stat) < 0} { set players($k,boss_bonus_$stat) 0 }
                }
            }
            catch {unset players($k,boss_tool_$item)}
            catch {unset players($k,boss_tool_bonus_$item)}
            set players($k,cash) [expr {$players($k,cash)+$val}]
            game_msg $nick $chan "$nick: sold [boss_tool_name $item] back for [fmt_cash $val]. Its permanent bonus was removed."
            return 1
        }
        lassign [shop_item_lookup $item] price kind
        if {$price < 0} {
            # Legendary pieces are deliberately absent from shop_item_lookup:
            # they have no price, cannot be sold at any level, and so cannot
            # be run through a sell-and-refarm loop the way boss gear can.
            if {[is_legend_item $item]} {
                game_msg $nick $chan "$nick: the [legend_name $item] is legendary -- nobody in this city will take it off your hands."
                return 0
            }
            game_msg $nick $chan "$nick: '$item' isn't something the shop buys back."
            return 0
        }
        switch -- $kind {
            weapon {
                if {$item eq "fists"} { game_msg $nick $chan "$nick: bare fists aren't worth anything."; return 0 }
                if {![item_owned_weapon $nick $item]} { game_msg $nick $chan "$nick: you don't own that weapon."; return 0 }
                if {$item eq $players($k,weapon)} { game_msg $nick $chan "$nick: you can't sell your equipped weapon. Equip something else first."; return 0 }
                set val [resale_value $item $nick]
                set idx [lsearch -exact $players($k,owned_weapons) $item]
                set players($k,owned_weapons) [lreplace $players($k,owned_weapons) $idx $idx]
                set players($k,cash) [expr {$players($k,cash)+$val}]
                mark_boss_gear_resold $nick $item
                game_msg $nick $chan "$nick: sold [weapon_name $item] back to the shop for [fmt_cash $val].[resale_bonus_note $nick]"
                return 1
            }
            armor {
                if {$item eq "none"} { game_msg $nick $chan "$nick: no armor to sell."; return 0 }
                if {![item_owned_armor $nick $item]} { game_msg $nick $chan "$nick: you don't own that armor."; return 0 }
                if {$item eq $players($k,armor)} { game_msg $nick $chan "$nick: you can't sell your equipped armor. Equip something else first."; return 0 }
                set val [resale_value $item $nick]
                set idx [lsearch -exact $players($k,owned_armor) $item]
                set players($k,owned_armor) [lreplace $players($k,owned_armor) $idx $idx]
                set players($k,cash) [expr {$players($k,cash)+$val}]
                mark_boss_gear_resold $nick $item
                game_msg $nick $chan "$nick: sold [armor_name $item] back to the shop for [fmt_cash $val].[resale_bonus_note $nick]"
                return 1
            }
            bling {
                variable bling_slots
                variable bling_slot_label
                if {$item eq "none"} { game_msg $nick $chan "$nick: no bling to sell."; return 0 }
                if {![item_owned_bling $nick $item]} { game_msg $nick $chan "$nick: you don't own that bling."; return 0 }
                foreach slot $bling_slots {
                    if {$item eq [getf $nick $slot "none"]} {
                        game_msg $nick $chan "$nick: you can't sell that, it's equipped in your $bling_slot_label($slot) slot. Equip something else there first."
                        return 0
                    }
                }
                set val [resale_value $item $nick]
                set idx [lsearch -exact $players($k,owned_bling) $item]
                set players($k,owned_bling) [lreplace $players($k,owned_bling) $idx $idx]
                set players($k,cash) [expr {$players($k,cash)+$val}]
                mark_boss_gear_resold $nick $item
                game_msg $nick $chan "$nick: sold [bling_name $item] back to the shop for [fmt_cash $val].[resale_bonus_note $nick]"
                return 1
            }
            tool {
                if {![has_item $nick $item]} { game_msg $nick $chan "$nick: you don't own that tool."; return 0 }
                set val [resale_value $item $nick]
                take_item $nick $item
                set players($k,cash) [expr {$players($k,cash)+$val}]
                if {[info exists ::mafia::shop_tools($item)]} {
                    set tname [lindex $::mafia::shop_tools($item) 0]
                } else {
                    set tname [lindex $::mafia::boss_tools($item) 0]
                }
                game_msg $nick $chan "$nick: sold $tname back to the shop for [fmt_cash $val].[resale_bonus_note $nick]"
                return 1
            }
        }
        return 0
    }

    # Liquidates every unequipped, non-boss-exclusive weapon/armor/bling the
    # player owns. Tools are deliberately excluded: they must be sold one at
    # a time. Boss-exclusive gear (boss_weapons/boss_armor/boss_bling) is
    # also excluded here no matter what -- it can only be sold individually
    # via !mafia sell <item>, and never while equipped.
    proc sell_all_gear {nick chan} {
        variable players
        ensure_gear_lists $nick
        set k [string tolower $nick]
        set total 0
        set count 0
        foreach item [lsort $players($k,owned_weapons)] {
            if {$item eq "fists" || $item eq $players($k,weapon)} continue
            # Black-market/boss-exclusive gear isn't in shop_weapons, so the
            # shop won't buy it back -- skip it instead of deleting it for $0.
            if {[lindex [shop_item_lookup $item] 0] < 0} continue
            # Boss-exclusive gear is never touched by bulk "sell all" -- it can
            # only be sold one at a time via !mafia sell <item>, and even then
            # never while equipped. This keeps a fire sale from silently
            # torching hard-won boss loot.
            if {[is_boss_gear_item $item]} continue
            set val [resale_value $item $nick]
            set idx [lsearch -exact $players($k,owned_weapons) $item]
            set players($k,owned_weapons) [lreplace $players($k,owned_weapons) $idx $idx]
            mark_boss_gear_resold $nick $item
            incr total $val
            incr count
        }
        foreach item [lsort $players($k,owned_armor)] {
            if {$item eq "none" || $item eq $players($k,armor)} continue
            if {[lindex [shop_item_lookup $item] 0] < 0} continue
            if {[is_boss_gear_item $item]} continue
            set val [resale_value $item $nick]
            set idx [lsearch -exact $players($k,owned_armor) $item]
            set players($k,owned_armor) [lreplace $players($k,owned_armor) $idx $idx]
            mark_boss_gear_resold $nick $item
            incr total $val
            incr count
        }
        variable bling_slots
        foreach item [lsort $players($k,owned_bling)] {
            if {$item eq "none"} continue
            set equipped 0
            foreach slot $bling_slots {
                if {$item eq [getf $nick $slot "none"]} { set equipped 1; break }
            }
            if {$equipped} continue
            if {[lindex [shop_item_lookup $item] 0] < 0} continue
            if {[is_boss_gear_item $item]} continue
            set val [resale_value $item $nick]
            set idx [lsearch -exact $players($k,owned_bling) $item]
            set players($k,owned_bling) [lreplace $players($k,owned_bling) $idx $idx]
            mark_boss_gear_resold $nick $item
            incr total $val
            incr count
        }
        # Tools are intentionally excluded from all/bulk sales. Every tool,
        # including boss tools if present in legacy data, must be sold manually.
        if {$total > 0} { set players($k,cash) [expr {$players($k,cash)+$total}] }
        if {$count > 0} {
            game_msg $nick $chan "$nick: unloaded $count old item(s) of gear/tools for [fmt_cash $total]."
        }
        return $total
    }

    # Sells every drug the player is holding at the current street price.
    # This is a fast bulk liquidation -- unlike !mafia drug sell it skips
    # the police-bust roll and the deal cooldown, so it's always safe but
    # never worth quite as much as carefully timing individual sales.
    proc sell_all_drugs {nick chan} {
        variable players
        variable drugs
        set k [string tolower $nick]
        set total 0
        set sold_any 0
        set econ_pct [player_bling_econ_pct $nick]
        foreach dname [lsort [array names drugs]] {
            set qty [getf $nick drug,$dname 0]
            if {$qty <= 0} continue
            set price [drug_price $dname]
            set raw [expr {$price*$qty}]
            set payout [expr {int(round($raw * (1.0 + ($econ_pct/100.0))))}]
            set players($k,drug,$dname) 0
            incr total $payout
            set sold_any 1
        }
        if {$sold_any} {
            set players($k,cash) [expr {$players($k,cash)+$total}]
            game_msg $nick $chan "$nick: dumped the whole stash on the street for [fmt_cash $total]."
        }
        return $total
    }

    # Fences every hot good the player is holding, using the normal
    # decayed value and rank-based fence cut -- just done for every item
    # at once instead of one at a time.
    proc sell_all_goods {nick chan} {
        variable players
        variable fence_goods
        set k [string tolower $nick]
        set total 0
        set sold_any 0
        set cut [fence_cut_for $nick]
        foreach item [lsort [array names fence_goods]] {
            set have [expr {[info exists players($k,goods,$item)] ? $players($k,goods,$item) : 0}]
            if {$have <= 0} continue
            set unit_val [goods_value $nick $item]
            set payout [expr {int($unit_val*(1.0-$cut)*$have)}]
            set players($k,goods,$item) 0
            catch {unset players($k,goods_ts,$item)}
            incr total $payout
            set sold_any 1
        }
        if {$sold_any} {
            set players($k,cash) [expr {$players($k,cash)+$total}]
            game_msg $nick $chan "$nick: the fence clears out all your hot goods for [fmt_cash $total] (his cut: [expr {int($cut*100)}]%)."
        }
        return $total
    }

    proc cmd_sell {nick chan args} {
        if {![need_registered $nick $chan]} return
        normalize_player_economy $nick
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia sell <item|gear|drugs|goods|all> -- sells old weapons/armor/bling/tools back to the shop at ${mafia::shop_resale_pct}%+ resale (higher level = better resale rate, up to +${mafia::shop_resale_level_bonus_cap}%). 'sell all' never sells tools or boss-exclusive gear; sell those one at a time with ${mafia::cmd_prefix}mafia sell <item>."
            return
        }
        variable players
        set k [string tolower $nick]
        set what [string tolower [lindex $args 0]]
        switch -- $what {
            all {
                set start $players($k,cash)
                sell_all_gear $nick $chan
                sell_all_drugs $nick $chan
                sell_all_goods $nick $chan
                set gained [expr {$players($k,cash)-$start}]
                if {$gained <= 0} {
                    game_msg $nick $chan "$nick: nothing to sell -- no spare gear, drugs, or hot goods on hand."
                } else {
                    game_msg $nick $chan "$nick: total from the fire sale -- [fmt_cash $gained]. Cash on hand: [fmt_cash $players($k,cash)]."
                }
            }
            gear { sell_all_gear $nick $chan }
            drug -
            drugs { sell_all_drugs $nick $chan }
            good -
            goods { sell_all_goods $nick $chan }
            default {
                # $what is only the first word; resolve the full arg list so
                # multi-word item names like "kingpin ice" (-> kingpin_ice)
                # sell correctly instead of always missing.
                sell_one_gear_item $nick $chan [resolve_item_key $args]
            }
        }
    }

    # NOTE: ownership for weapons/armor is tracked in owned_weapons /
    # owned_armor (see ensure_gear_lists / item_owned_weapon / item_owned_armor
    # near the other gear helpers above). Buying a weapon/armor adds it to
    # the owned list and auto-equips it; !equip can freely switch between
    # anything already owned without rebuying it.

    proc cmd_inventory {nick chan} {
        if {![need_registered $nick $chan]} return
        variable players
        ensure_gear_lists $nick
        set k [string tolower $nick]
        set items $players($k,items)
        set toolstr [list]
        foreach item $items { lappend toolstr [tool_name $item] }
        set total_workers 0
        foreach tier [array names ::mafia::pimp_workers] {
            set total_workers [expr {$total_workers + [getf $nick pimp,$tier 0] + [getf $nick pimp_jail,$tier 0]}]
        }
        set drugstr [list]
        foreach d [array names ::mafia::drugs] {
            set dqty [getf $nick drug,$d 0]
            if {$dqty > 0} { lappend drugstr "$d:$dqty" }
        }
        variable bling_slots
        variable bling_slot_label
        set icestr [list]
        set has_bling 0
        foreach slot $bling_slots {
            set item [getf $nick $slot "none"]
            if {$item ne "none" && $item ne ""} {
                set has_bling 1
                lappend icestr "$bling_slot_label($slot)=[bling_name $item] (+[bling_bonus_pct $item $nick]%)"
            }
        }
        set inv_parts [list "weapon=[weapon_name $players($k,weapon)]"]
        if {$players($k,armor) ne "none" && $players($k,armor) ne ""} {
            lappend inv_parts "armor=[armor_name $players($k,armor)] (evasion [armor_evasion $players($k,armor) $nick]%)"
        }
        if {$has_bling} {
            lappend inv_parts [join $icestr {, }]
            lappend inv_parts "total ice bonus=+[player_bling_pct $nick]% stats, +[player_bling_econ_pct $nick]% econ"
        }
        game_msg $nick $chan "$nick: [join $inv_parts { | }]"
        set ownedw [list]
        foreach w $players($k,owned_weapons) { lappend ownedw [weapon_name $w] }
        set owneda [list]
        foreach a $players($k,owned_armor) { lappend owneda [armor_name $a] }
        set ownedb [list]
        foreach b $players($k,owned_bling) {
            if {$b eq "none" && [llength $players($k,owned_bling)] > 1} { continue }
            lappend ownedb [bling_name $b]
        }
        game_msg $nick $chan "Owned weapons: [join $ownedw {, }]"
        if {[llength $owneda] > 0 && !([llength $owneda] == 1 && [lindex $owneda 0] eq "No Armor")} {
            game_msg $nick $chan "Owned armor: [join $owneda {, }]"
        }
        if {[llength $ownedb] > 0 && !([llength $ownedb] == 1 && [lindex $ownedb 0] eq "No Bling")} {
            game_msg $nick $chan "Owned bling: [join $ownedb {, }]"
        }
        game_msg $nick $chan "Tools: [expr {[llength $toolstr]>0 ? [join $toolstr {, }] : {none}}]"
        game_msg $nick $chan "Workers: $total_workers"
        game_msg $nick $chan "Drugs: [expr {[llength $drugstr]>0 ? [join $drugstr {, }] : {none}}]"
        set legend_held [legend_pieces_owned $nick]
        if {$legend_held > 0} {
            game_msg $nick $chan "Legendary: $legend_held/4 collected -- +[legend_stat_pct $nick]% all stats, +[legend_collect_pct $nick]% collections (${mafia::cmd_prefix}mafia legend)"
        }
    }

}
# mafia_commands_combat.tcl - hide/encounter-response commands and PvP
# combat commands (attack/wiretap/rob).
namespace eval mafia {
    proc cmd_hide {nick chan} {
        normalize_player_economy $nick
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        if {[chan_has_pending_encounter $chan]} {
            resolve_encounter $nick $chan hide
            return
        }
        variable players
        variable hide_time
        set k [string tolower $nick]
        set players($k,hide_until) [expr {[now] + ($hide_time*60)}]
        game_msg $nick $chan "$nick slips into the shadows. \002(hidden for up to ${hide_time}m)\002"
    }

    proc cmd_fight {nick chan} {
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        if {![chan_has_pending_encounter $chan]} {
            game_msg $nick $chan "$nick: nothing's going on to confront right now. Try ${mafia::cmd_prefix}mafia fight cpu to pick a fight."
            return
        }
        resolve_encounter $nick $chan fight
    }

    proc cmd_talk {nick chan} {
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        if {![chan_has_pending_encounter $chan]} {
            game_msg $nick $chan "$nick: no one's around to talk your way out of right now."
            return
        }
        resolve_encounter $nick $chan talk
    }

    proc cmd_run {nick chan} {
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        if {![chan_has_pending_encounter $chan]} {
            game_msg $nick $chan "$nick: nothing to run from right now."
            return
        }
        resolve_encounter $nick $chan run
    }

    proc cmd_payoff {nick chan} {
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        variable players
        variable encounter_payoff_cash
        set k [string tolower $nick]
        if {![chan_has_pending_encounter $chan]} {
            game_msg $nick $chan "$nick: nothing to pay off right now."
            return
        }
        set c [string tolower $chan]
        if {$mafia::chan_enc($c,type) ne "police"} {
            game_msg $nick $chan "$nick: that won't work on them -- try faceoff, talk, run, or hide."
            return
        }
        if {$players($k,cash) < $encounter_payoff_cash} {
            game_msg $nick $chan "$nick: you need [fmt_cash $encounter_payoff_cash] to pay them off (you have [fmt_cash $players($k,cash)])."
            return
        }
        set ename $mafia::chan_enc($c,name)
        set players($k,cash) [expr {$players($k,cash)-$encounter_payoff_cash}]
        clear_chan_encounter $chan
        game_msg $nick $chan "$nick slips $ename [fmt_cash $encounter_payoff_cash] and they wave $nick on. No harm done."
    }

    proc cmd_unhide {nick chan} {
        if {![need_registered $nick $chan]} return
        variable players
        set k [string tolower $nick]
        set players($k,hide_until) 0
        game_msg $nick $chan "$nick steps back out into the open."
    }

    proc cmd_heal {nick chan} {
        normalize_player_economy $nick
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        variable players
        set k [string tolower $nick]
        set hpmax [player_max_health $nick]
        if {$players($k,health) >= $hpmax} {
            game_msg $nick $chan "$nick: you're already at full health."
            return
        }
        if {![has_item $nick medkit]} {
            game_msg $nick $chan "$nick: you need a medkit. Buy one at ${mafia::cmd_prefix}mafia shop."
            return
        }
        take_item $nick medkit
        set players($k,health) $hpmax
        set players($k,hosp_until) 0
        game_msg $nick $chan "$nick uses a medkit and is patched back up to full health."
    }

    # Auto-consumes one medkit and tops the player back up to full health
    # when autoheal is toggled on, they're still alive (health > 0 -- this
    # never reaches into the hospital, it only ever prevents landing
    # there), their health has fallen to or below autoheal_threshold_pct,
    # and they actually own a medkit. A silent no-op otherwise, including
    # when they have no medkit -- so it never spams a "need a medkit"
    # message into the middle of a fight or encounter. Safe to call after
    # any place combat damage is applied.
    proc autoheal_on {nick} {
        # Non-creating read: getf would seed autoheal=0 into the player array
        # just for asking, and this is consulted on every damage event.
        variable players
        set k [string tolower $nick]
        if {![info exists players($k,autoheal)]} { return 0 }
        set v $players($k,autoheal)
        if {![string is integer -strict $v]} { return 0 }
        return [expr {$v != 0}]
    }

    # Mid-combat autoheal, for the round-by-round NPC/boss engine.
    #
    # maybe_autoheal below cannot do this job inside a battle loop:
    # run_npc_battle tracks the player's hit points in a LOCAL ($php) and only
    # writes them back to players(...,health) after the fight is over. So
    # maybe_autoheal saw the player's pre-fight health every time it was
    # called, and on a loss it saw 0 -- which it deliberately refuses to
    # revive from. The net effect was that autoheal never fired in ANY npc,
    # hitman, stealth, revenge or boss fight, which is precisely where a
    # medkit matters: a player could toggle it on, buy a medkit, walk into a
    # boss, get flattened over six rounds and go to hospital with the medkit
    # still in their pocket. This runs the same threshold check against the
    # live in-fight value and returns the hit points to carry on with.
    proc battle_autoheal {nick chan php hpcap} {
        variable players
        variable autoheal_threshold_pct
        set k [string tolower $nick]
        if {![info exists players($k,cash)]} { return $php }
        # Never a revive: once the player is down, the fight is lost.
        if {$php <= 0} { return $php }
        if {$php >= $hpcap} { return $php }
        if {![autoheal_on $nick]} { return $php }
        if {$php*100 > $hpcap*$autoheal_threshold_pct} { return $php }
        if {![has_item $nick medkit]} { return $php }
        take_item $nick medkit
        set players($k,health) $hpcap
        game_msg $nick $chan "$nick: autoheal kicks in mid-fight -- a medkit patches $nick back up to full health ($hpcap HP)."
        return $hpcap
    }

    proc maybe_autoheal {nick chan} {
        variable players
        variable autoheal_threshold_pct
        set k [string tolower $nick]
        if {![info exists players($k,cash)]} { return }
        if {![autoheal_on $nick]} { return }
        if {$players($k,health) <= 0} { return }
        set hpmax [player_max_health $nick]
        if {$players($k,health) >= $hpmax} { return }
        if {$players($k,health)*100 > $hpmax*$autoheal_threshold_pct} { return }
        if {![has_item $nick medkit]} { return }
        take_item $nick medkit
        set players($k,health) $hpmax
        game_msg $nick $chan "$nick: autoheal kicks in -- a medkit patches $nick back up to full health."
    }

    proc cmd_autoheal {nick chan args} {
        if {![need_registered $nick $chan]} return
        variable players
        variable autoheal_threshold_pct
        set k [string tolower $nick]
        if {[llength $args] < 1} {
            set cur [expr {[autoheal_on $nick] ? "ON" : "OFF"}]
            game_msg $nick $chan "$nick: autoheal is currently \002$cur\002. Usage: ${mafia::cmd_prefix}mafia autoheal <on|off> -- auto-uses a medkit when a combat hit drops you to or below ${autoheal_threshold_pct}% health."
            return
        }
        switch -- [string tolower [lindex $args 0]] {
            on  {
                set players($k,autoheal) 1
                game_msg $nick $chan "$nick: autoheal is now \002ON\002. A medkit auto-triggers if a hit drops you to or below ${autoheal_threshold_pct}% health, as long as you're carrying one."
            }
            off {
                # Unset rather than store a zero: "absent" and 0 mean the same
                # thing to autoheal_on, and normalize_player_economy drops the
                # zero row anyway, so writing one just churns a database row.
                unset -nocomplain players($k,autoheal)
                game_msg $nick $chan "$nick: autoheal is now \002OFF\002."
            }
            default {
                game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia autoheal <on|off>"
            }
        }
    }

    proc cmd_bribe {nick chan} {
        normalize_player_economy $nick
        if {![need_registered $nick $chan]} return
        variable players
        variable jail_bribe_min
        variable jail_bribe_max
        set k [string tolower $nick]
        if {![in_jail $nick]} {
            game_msg $nick $chan "$nick: you're not in jail."
            return
        }
        set cost [expr {$jail_bribe_min + int(rand()*($jail_bribe_max-$jail_bribe_min+1))}]
        if {$players($k,cash) < $cost} {
            game_msg $nick $chan "$nick: the guard wants [fmt_cash $cost] to make this disappear. You have [fmt_cash $players($k,cash)]. Or wait out your sentence."
            return
        }
        set players($k,cash) [expr {$players($k,cash)-$cost}]
        set players($k,jail_until) 0
        game_msg $nick $chan "$nick pays off the guard for [fmt_cash $cost] and walks free."
    }

    # PvP defensive reaction: when a player is attacked, they get a reactive
    # chance to completely avoid the hit. Tools improve the odds, while
    # dexterity/accuracy differences still matter. One reaction can trigger
    # per 20 seconds so stacking several tools never makes a player immune.
    proc pvp_reaction {attacker defender mode} {
        # Both PvP attack modes get a defensive reaction.
        #
        # This was "shoot" only, which was harmless while melee meant bare
        # fists doing 7 damage. Now that knife works with whatever weapon is
        # equipped (see cmd_attack), a shoot-only gate would have made melee the
        # single best attack in the game -- full weapon damage with the
        # defender's duck/block chance, threat scanner, tactical shield, smoke
        # screen, escape rig, ghost cloak and boss dodge/block bonuses all
        # switched off. Reacting to a swing is no less plausible than reacting
        # to a shot, and it keeps the two modes separated by hit chance alone,
        # which is the intended difference.
        if {$mode ne "shoot" && $mode ne "knife"} { return "" }
        variable players
        variable boss_tools
        set dk [string tolower $defender]
        set ak [string tolower $attacker]
        if {![info exists players($dk,health)] || $players($dk,health) <= 0} { return "" }

        set nowts [now]
        set last [getf $defender last_pvp_reaction 0]
        if {[expr {$nowts-$last}] < 20} { return "" }

        set dex [get_stat $defender dexterity]
        set acc [get_stat $attacker accuracy]
        set best 0
        set kind ""

        # Natural reflexes: good dexterity can still save an unprepared player.
        set natural [expr {min(18,4+int($dex/8))}]
        if {$dex > $acc} { incr natural 5 }
        if {$natural > $best} { set best $natural; set kind "duck" }

        # Shop tools.
        if {[has_item $defender threat_scanner]} {
            set chance [expr {min(45,18+int($dex/5)+($dex>$acc ? 8 : 0))}]
            if {$chance > $best} { set best $chance; set kind "duck" }
        }
        if {[has_item $defender tactical_shield]} {
            set chance [expr {min(42,16+int($dex/6)+($dex>$acc ? 8 : 0))}]
            if {$chance > $best} { set best $chance; set kind "block" }
        }
        if {[has_item $defender smoke_screen]} {
            set chance [expr {min(40,15+int($dex/6)+($dex>$acc ? 8 : 0))}]
            if {$chance > $best} { set best $chance; set kind "duck" }
        }

        # Escape Rig: the top purchasable tool, priced far past the rest
        # of the shop. Same "best-for-early-game, not an absolute ceiling"
        # design as the other top-tier shop gear -- strong enough to
        # rival the early boss-exclusive tools, but the late-game ones
        # (right below) still pull ahead.
        if {[has_item $defender escape_rig]} {
            set chance [expr {min(46,20+int($dex/5)+($dex>$acc ? 8 : 0))}]
            if {$chance > $best} { set best $chance; set kind "duck" }
        }
        if {[has_item $defender ghost_cloak]} {
            set chance [expr {min(48,21+int($dex/5)+($dex>$acc ? 8 : 0))}]
            if {$chance > $best} { set best $chance; set kind "duck" }
        }

        # Boss-tool bonuses are permanent and stack as separate persistent
        # percentages. They are not consumable inventory items.
        set blockbonus [boss_bonus_pct $defender block]
        if {$blockbonus > 0} {
            set chance [expr {min(92,35+$blockbonus+int($dex/5))}]
            if {$chance > $best} { set best $chance; set kind "block" }
        }
        set dodgebonus [boss_bonus_pct $defender dodge]
        if {$dodgebonus > 0} {
            set chance [expr {min(92,35+$dodgebonus+int($dex/5))}]
            if {$chance > $best} { set best $chance; set kind "duck" }
        }

        if {$best <= 0 || int(rand()*100) >= $best} { return "" }
        set players($dk,last_pvp_reaction) $nowts
        return $kind
    }

    proc cmd_attack {nick chan args mode} {
        normalize_player_economy $nick
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        variable attack_cooldown
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia $mode <nick>"
            return
        }
        set target [lindex $args 0]
        if {[string tolower $target] eq [string tolower $nick]} {
            game_msg $nick $chan "$nick: you can't attack yourself."
            return
        }
        if {![exists_player $target]} {
            game_msg $nick $chan "$target isn't in the game."
            return
        }
        # Repair the DEFENDER's row too, not just the attacker's. Everything
        # below reads the target's health/armor/cash/deaths straight out of the
        # array, and nothing on the PvP path ever normalized the player being
        # shot at -- so a legacy or partially written target row turned every
        # attack aimed at them into an uncaught Tcl error and a rolled-back
        # transaction for the ATTACKER. Same defect has_item was made
        # non-throwing for; this covers the fields it cannot.
        normalize_player_economy $target
        variable players
        set k [string tolower $nick]
        set tk [string tolower $target]

        set elapsed [expr {[now] - $players($k,last_attack)}]
        if {$elapsed < $attack_cooldown} {
            game_msg $nick $chan "$nick: reload. [fmt_secs [expr {$attack_cooldown-$elapsed}]] before you can strike again."
            return
        }
        if {[in_hospital $target]} {
            game_msg $nick $chan "$target is already in the hospital. Let them bleed."
            return
        }
        if {$mode eq "shoot" && [lsearch -exact $::mafia::gun_weapons $players($k,weapon)] < 0} {
            game_msg $nick $chan "$nick: you need a gun equipped to shoot. Try ${mafia::cmd_prefix}mafia knife or ${mafia::cmd_prefix}mafia buy a gun."
            return
        }
        # Melee has no weapon requirement: you can go at somebody with
        # whatever is in your hands, up to and including pistol-whipping them
        # with a Finality Cannon.
        #
        # This used to gate on melee_weapons, which contained exactly one entry
        # -- "fists" -- while cmd_equip refuses to equip anything weaker than
        # what you already carry. So the moment a player bought their first gun
        # (auto-equipped as an upgrade) they could never equip fists again, and
        # knife became permanently unusable for the rest of that character's
        # life: "your equipped weapon isn't a melee weapon", forever. That also
        # broke the dispatcher's "!mafia fight <nick>" shortcut, which routes
        # to knife mode, and contradicted the help text for both.
        #
        # Knife is still the weaker of the two attacks -- shoot rolls a 70 base
        # hit chance against knife's 60 (see below) -- so a player holding a gun
        # has no reason to prefer it. It is the attack that always works.
        set players($k,last_attack) [now]

        # The defender gets a split-second warning/reaction before the shot
        # resolves. A successful duck/block/phase reaction avoids the attack
        # completely and leaves the defender untouched.
        set reaction [pvp_reaction $nick $target $mode]
        if {$reaction ne ""} {
            switch -- $reaction {
                duck   { set verb "ducks" }
                block  { set verb "blocks" }
                phase   { set verb "phases out of" }
                evasion { set verb "evades" }
                default { set verb "avoids" }
            }
            game_msg $nick $chan "$target $verb $nick's $mode completely -- the attack misses without dealing damage."
            return
        }
        if {[armor_evasion_roll $target]} {
            game_msg $nick $chan "$target's [armor_name $players($tk,armor)] evades $nick's $mode -- no damage dealt."
            return
        }

        # hidden targets are hard to find (night vision goggles cut through the dark)
        if {[is_hidden $target]} {
            set findthresh 65
            set findthresh [expr {$findthresh + int([get_stat $target stealth]/5)}]
            if {$findthresh > 90} { set findthresh 90 }
            set findroll [expr {int(rand()*100)}]
            if {$findroll < $findthresh} {
                game_msg $nick $chan "$nick searches for $target but can't find them -- they're laying low."
                return
            }
            set players($tk,hide_until) 0
            game_msg $nick $chan "$nick tracks $target down despite them hiding!"
        }

        # stealth: chance of a guaranteed surprise strike that skips the
        # hit roll entirely and hits harder.
        set stealthstat [get_stat $nick stealth]
        set ambush [expr {int(rand()*100) < int($stealthstat/10)}]

        if {!$ambush} {
            set hitroll [expr {int(rand()*100)}]
            set hitchance [expr {$mode eq "shoot" ? 70 : 60}]
            set hitchance [expr {$hitchance + int([get_stat $nick accuracy]/5) - int([get_stat $target dexterity]/5)}]
            if {$hitchance < 10} { set hitchance 10 }
            if {$hitchance > 95} { set hitchance 95 }
            if {$hitroll >= $hitchance} {
                game_msg $nick $chan "$nick tries to $mode $target and misses completely."
                return
            }
        }

        set dmg [expr {int([weapon_dmg $players($k,weapon) $nick]*[pimp_damage_mult $nick])}]
        set reduce [armor_reduce $players($tk,armor) $target]
        if {$ambush} { set dmg [expr {int($dmg*1.5)}] }
        set net [expr {$dmg - $reduce}]
        if {$net < 1} { set net 1 }
        set players($tk,health) [expr {$players($tk,health) - $net}]
        maybe_autoheal $target $chan
        if {$ambush} {
            game_msg $nick $chan "$nick gets the drop on $target -- they never heard it coming."
        }

        if {$players($tk,health) <= 0} {
            variable hospital_time
            set players($tk,health) 0
            set players($tk,hosp_until) [expr {[now] + ($hospital_time*60)}]
            set players($tk,hosp_notified) 0
            incr players($k,kills)
            incr players($tk,deaths)
            # murder pays big: a hefty cut of their cash PLUS a flat hit bonus
            set steal [expr {int($players($tk,cash) * 0.35)}]
            set hitbonus [expr {150 + int(rand()*350)}]
            set players($tk,cash) [expr {$players($tk,cash)-$steal}]
            set players($k,cash)  [expr {$players($k,cash)+$steal+$hitbonus}]
            set oldlvl [player_level $nick]
            set players($k,xp) [expr {$players($k,xp)+25}]
            sync_level_stats $nick
            set newlvl [player_level $nick]
            game_msg $nick $chan "\002$nick ${mode}s $target down!\002 $target is rushed to the hospital ([fmt_secs [expr {$hospital_time*60}]]). $nick collects [fmt_cash $steal] off the body plus a [fmt_cash $hitbonus] hit bonus."
            if {$newlvl > $oldlvl} {
                game_msg $nick $chan "\002$nick leveled up to Lv.$newlvl!\002"
            }
        } else {
            set players($k,xp) [expr {$players($k,xp)+2+int(rand()*3)}]
            sync_level_stats $nick
            game_msg $nick $chan "$nick ${mode}s $target for $net damage. ($target: $players($tk,health)/[player_max_health $target] HP)"
        }

    }

    proc cmd_headshot {nick chan args} {
        normalize_player_economy $nick
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia headshot <nick>"
            return
        }
        set target [lindex $args 0]
        if {[string tolower $target] eq [string tolower $nick] || ![exists_player $target]} {
            game_msg $nick $chan "$nick: invalid target."
            return
        }
        # See cmd_attack: the defender's row is read directly below, so repair
        # it here rather than letting a legacy row roll the attacker's command
        # back.
        normalize_player_economy $target
        variable players
        variable attack_cooldown
        set k [string tolower $nick]
        set tk [string tolower $target]
        if {[in_hospital $target]} {
            game_msg $nick $chan "$target is already in the hospital."
            return
        }
        if {[lsearch -exact $::mafia::gun_weapons $players($k,weapon)] < 0} {
            game_msg $nick $chan "$nick: you need a gun equipped for a headshot."
            return
        }
        set last [getf $nick last_attack 0]
        if {[expr {[now]-$last}] < $attack_cooldown} {
            game_msg $nick $chan "$nick: reload. [fmt_secs [expr {$attack_cooldown-([now]-$last)}]] before attempting another shot."
            return
        }

        # A headshot requires a permanent boss headshot bonus.
        if {[boss_bonus_pct $nick headshot] <= 0} {
            game_msg $nick $chan "$nick: you need a boss headshot tool bonus."
            return
        }

        set players($k,last_attack) [now]
        set reaction [pvp_reaction $nick $target shoot]
        if {$reaction ne ""} {
            game_msg $nick $chan "$target reacts before the headshot lands and completely avoids it."
            return
        }
        if {[armor_evasion_roll $target]} {
            game_msg $nick $chan "$target's [armor_name $players($tk,armor)] evades the headshot -- no damage dealt."
            return
        }

        set chance [expr {55 + int([get_stat $nick accuracy]/2) - int([get_stat $target dexterity]/4)}]
        incr chance [boss_bonus_pct $nick headshot]
        if {$chance < 15} { set chance 15 }
        if {$chance > 95} { set chance 95 }

        if {int(rand()*100) >= $chance} {
            # A failed headshot is deliberately non-lethal: it can hurt, but
            # only a successful headshot can award the PvP kill.
            set dmg [expr {max(1,int([weapon_dmg $players($k,weapon) $nick]*0.35*[pimp_damage_mult $nick])-[armor_reduce $players($tk,armor) $target])}]
            set maxsafe [expr {max(0,$players($tk,health)-1)}]
            if {$dmg > $maxsafe} { set dmg $maxsafe }
            set players($tk,health) [expr {$players($tk,health)-$dmg}]
            maybe_autoheal $target $chan
            game_msg $nick $chan "$nick fires a precision headshot at $target but misses the kill shot. $target takes $dmg damage. ($players($tk,health)/[player_max_health $target] HP)"
            return
        }

        variable hospital_time
        set players($tk,health) 0
        set players($tk,hosp_until) [expr {[now]+($hospital_time*60)}]
        set players($tk,hosp_notified) 0
        incr players($k,kills)
        incr players($tk,deaths)
        set steal [expr {int($players($tk,cash)*0.35)}]
        set hitbonus [expr {250+int(rand()*750)}]
        set players($tk,cash) [expr {$players($tk,cash)-$steal}]
        set players($k,cash) [expr {$players($k,cash)+$steal+$hitbonus}]
        set oldlvl [player_level $nick]
        incr players($k,xp) 35
        sync_level_stats $nick
        set newlvl [player_level $nick]
        game_msg $nick $chan "\002$nick lands the headshot on $target -- INSTANT KILL.\002 $target is rushed to the hospital. $nick collects [fmt_cash $steal] plus a [fmt_cash $hitbonus] headshot bonus."
        if {$newlvl > $oldlvl} { game_msg $nick $chan "\002$nick leveled up to Lv.$newlvl!\002" }
    }

    proc cmd_wiretap {nick chan args} {
        normalize_player_economy $nick
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        if {![has_item $nick wiretap]} {
            game_msg $nick $chan "$nick: you need a Wiretap Kit for that. Buy one at ${mafia::cmd_prefix}mafia shop."
            return
        }
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia wiretap <nick>"
            return
        }
        set target [lindex $args 0]
        if {[string tolower $target] eq [string tolower $nick]} { game_msg $nick $chan "$nick: can't wiretap yourself."; return }
        if {![exists_player $target]} { game_msg $nick $chan "$target isn't in the game."; return }
        # See cmd_attack: $players($tk,cash) is read directly below.
        normalize_player_economy $target
        variable players
        variable wiretap_cooldown
        set k [string tolower $nick]
        set tk [string tolower $target]
        set last [getf $nick last_wiretap 0]
        set elapsed [expr {[now]-$last}]
        if {$elapsed < $wiretap_cooldown} {
            game_msg $nick $chan "$nick: the line's still hot. [fmt_secs [expr {$wiretap_cooldown-$elapsed}]] before you can tap another call."
            return
        }
        set players($k,last_wiretap) [now]

        set catchchance [expr {max(0,22-[catch_mod $nick])}]
        set roll [expr {int(rand()*100)}]
        if {$roll < $catchchance} {
            variable jail_time
            set players($k,jail_until) [expr {[now] + int($jail_time*45)}]
            set players($k,jail_notified) 0
            game_msg $nick $chan "\002CAUGHT!\002 $nick's tap on $target's line gets traced back. Wire fraud charges -- jail for [fmt_secs [expr {int($jail_time*45)}]]."
            return
        }

        set snippets {
            "a shipment coming in next week"
            "a payoff to a city inspector"
            "a meeting location for a deal"
            "who's been skimming off the top"
            "a buyer looking to move product fast"
            "a tip on an unguarded stash house"
        }
        set snip [lindex $snippets [expr {int(rand()*[llength $snippets])}]]
        set base [expr {60 + int($players($tk,cash)*0.04)}]
        if {$base > 500} { set base 500 }
        set cash [expr {$base + int(rand()*($base*0.6))}]
        set xp [expr {4 + int(rand()*8)}]
        set players($k,cash) [expr {$players($k,cash)+$cash}]
        set oldlvl [player_level $nick]
        set players($k,xp) [expr {$players($k,xp)+$xp}]
        sync_level_stats $nick
        set newlvl [player_level $nick]
        game_msg $nick $chan "$nick taps $target's line and overhears $snip. Sells the info for [fmt_cash $cash]. +$xp XP."
        if {$newlvl > $oldlvl} {
            game_msg $nick $chan "\002$nick leveled up to Lv.$newlvl!\002"
        }
    }

    proc cmd_rob {nick chan args} {
        normalize_player_economy $nick
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        if {[llength $args] < 1} { game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia rob <nick>"; return }
        set target [lindex $args 0]
        if {[string tolower $target] eq [string tolower $nick]} { game_msg $nick $chan "$nick: can't rob yourself."; return }
        if {![exists_player $target]} { game_msg $nick $chan "$target isn't in the game."; return }
        # See cmd_attack: the victim's cash row is read and written directly.
        normalize_player_economy $target
        variable players
        set k [string tolower $nick]
        set tk [string tolower $target]
        if {[is_hidden $target]} { game_msg $nick $chan "$nick can't find $target to rob them -- they're hiding."; return }
        # Robbery can only touch cash carried by the target. Bank funds and
        # any future bank-stored inventory are protected and are never robbery
        # sources.
        if {$players($tk,cash) < 20} { game_msg $nick $chan "$target is broke. Their bank is protected and cannot be robbed."; return }

        variable rob_cooldown
        set last [getf $nick last_rob 0]
        set elapsed [expr {[now] - $last}]
        if {$elapsed < $rob_cooldown} {
            game_msg $nick $chan "$nick: keep a low profile. [fmt_secs [expr {$rob_cooldown-$elapsed}]] before you can rob again."
            return
        }
        # Consume the robbery opportunity before any reward calculation so a
        # successful or failed attempt has exactly one cooldown event.
        set players($k,last_rob) [now]

        set roll [expr {int(rand()*100)}]
        set succthresh [expr {40 + [catch_mod $nick] + int([get_stat $nick pickpocket]/5) + [boss_bonus_pct $nick rob] - int([get_stat $target dexterity]/10)}]
        if {$succthresh < 10} { set succthresh 10 }
        if {$succthresh > 90} { set succthresh 90 }
        if {$roll < $succthresh} {
            set amt [expr {int($players($tk,cash) * (0.1 + rand()*0.25))}]
            set players($tk,cash) [expr {$players($tk,cash)-$amt}]
            set players($k,cash)  [expr {$players($k,cash)+$amt}]
            set players($k,xp)    [expr {$players($k,xp)+2}]
            sync_level_stats $nick
            game_msg $nick $chan "$nick robs $target blind and gets away with [fmt_cash $amt]."
        } else {
            variable jail_time
            set players($k,jail_until) [expr {[now] + (($jail_time*60)/2)}]
            set players($k,jail_notified) 0
            game_msg $nick $chan "$nick gets caught robbing $target and is thrown in jail for [fmt_secs [expr {($jail_time*60)/2}]]."
        }
    }

}
# mafia_npcfights.tcl - NPC generation and battle engine, plus the
# streetfight/npcfight/hitfight/stealthfight/boss commands.
namespace eval mafia {
    ##### =====================================================
    #####                 NPC FIGHTS (streetfight/hitfight/stealthfight)
    ##### =====================================================
    # NPCs are generated fresh each time, scaled loosely off the player's
    # own level so the fight is sometimes easy and sometimes a real risk --
    # they may or may not be stronger than you.

    proc npc_gear_for_level {lvl biasslots {minidx 0}} {
        # Picks a weapon+armor pair scaled to lvl (1-500), with a random
        # variance band so an NPC can show up under-equipped, evenly
        # matched, or better-equipped than a typical player at that level.
        # biasslots shifts the average upward (used for hitmen/bosses).
        # minidx floors both indices so a caller can guarantee "at least
        # some real gear" (index 0 is fists/none) rather than only nudging
        # the average via biasslots -- used for hit/npc tiers so they don't
        # spawn fully unarmed as often at low levels.
        variable weapon_order
        variable armor_order
        variable max_level
        set wn [llength $weapon_order]
        set an [llength $armor_order]
        # The curve used to run 0 -> top-of-ladder across Lv.1-499 and then
        # saturate, because 500 was the level cap when it was written. With
        # the cap at max_level (1000) that left the whole back half of the
        # game handing NPCs identical gear.
        #
        # Two segments instead. Lv.1-500 climbs to what was the top of the
        # ladder in the Lv.500 era (singularity_cannon / singularity_aegis),
        # so every level below 500 rolls exactly the loadouts it always did;
        # Lv.500-1000 climbs from there into the gear added above that old
        # ceiling. Looked up by name rather than by a hardcoded index so
        # inserting or removing shop tiers can't silently shift the split.
        set midw [lsearch -exact $weapon_order singularity_cannon]
        set mida [lsearch -exact $armor_order singularity_aegis]
        if {$midw < 0} { set midw [expr {$wn-1}] }
        if {$mida < 0} { set mida [expr {$an-1}] }
        if {$lvl <= 500} {
            set basew [expr {(($lvl-1)*$midw)/499.0}]
            set basea [expr {(($lvl-1)*$mida)/499.0}]
        } else {
            set upper [expr {max(501,$max_level)}]
            set t [expr {min(1.0,($lvl-500)/double($upper-500))}]
            set basew [expr {$midw + $t*($wn-1-$midw)}]
            set basea [expr {$mida + $t*($an-1-$mida)}]
        }
        set wvar [expr {int(rand()*5)-2+$biasslots}]
        set avar [expr {int(rand()*3)-1+$biasslots}]
        set widx [expr {int(round($basew))+$wvar}]
        set aidx [expr {int(round($basea))+$avar}]
        # [expr], not a bare "$wn-1": that assigns the literal STRING "18-1"
        # and only works at all because lindex happens to accept index
        # arithmetic. Anything that later treats these as numbers -- or a
        # non-lindex use -- breaks on it.
        if {$widx < $minidx} { set widx $minidx }
        if {$widx > $wn-1} { set widx [expr {$wn-1}] }
        if {$aidx < $minidx} { set aidx $minidx }
        if {$aidx > $an-1} { set aidx [expr {$an-1}] }
        return [list [lindex $weapon_order $widx] [lindex $armor_order $aidx]]
    }

    proc boss_gear_for_tier {tier} {
        # Every boss tier has a complete four-piece exclusive set:
        # weapon + armor + bling + combat tool.
        variable boss_weapon_order
        variable boss_armor_order
        variable boss_bling_order
        variable boss_tool_order
        set idx [expr {max(0,min(19,$tier-1))}]
        return [list [lindex $boss_weapon_order $idx] [lindex $boss_armor_order $idx] [lindex $boss_bling_order $idx] [lindex $boss_tool_order $idx]]
    }

    proc boss_tool_name {key} {
        variable boss_tools
        if {[info exists boss_tools($key)]} { return [lindex $boss_tools($key) 0] }
        return "Unknown Boss Tool"
    }

    proc npc_gen {tier lvl} {
        # returns: name hp weapon armor cashmin cashmax xpmin xpmax
        # NPCs now carry a real weapon/armor loadout (same items players can
        # buy) instead of an abstract damage number, so gear genuinely
        # decides these fights -- outgun or outarmor them and you win,
        # walk in with fists and no vest and you're going to eat it.
        switch -- $tier {
            street {
                set names {"a street thug" "a mugger" "a drunk brawler" "a gang lookout" "a pickpocket"}
                set hp   [expr {int((18 + $lvl*1.15) * (0.85+rand()*0.35))}]
                lassign [npc_gear_for_level $lvl -2] weapon armor
                set cmin [expr {int(50 + $lvl*4.5)}]
                set cmax [expr {int(180 + $lvl*12)}]
                set xmin [expr {3 + int($lvl*0.15)}]
                set xmax [expr {7 + int($lvl*0.35)}]
            }
            npc {
                # Distinct from "cpu"/"street": genuinely unpredictable.
                # Base stats sit between street thugs and hitmen, but a
                # wide gear roll means some npcs are a soft touch and
                # others are a nasty surprise. Payouts run richer than
                # street fights to compensate, and wins here count as
                # real kills (unlike cpu fights).
                set names {"a rival soldier" "a wired-up enforcer" "a desperate loan shark" "a trigger-happy lookout" "an ambitious made man"}
                set hp   [expr {int((38 + $lvl*2.25) * (0.9+rand()*0.35))}]
                set groll [expr {rand()*100}]
                if {$groll < 20} {
                    lassign [npc_gear_for_level $lvl 5 2] weapon armor
                    set hp [expr {int($hp*1.25)}]
                    set geartag " \002(heavily upgraded gear)\002"
                } else {
                    lassign [npc_gear_for_level $lvl 2 1] weapon armor
                    set hp [expr {int($hp*1.05)}]
                    set geartag " \002(upgraded gear)\002"
                }
                set cmin [expr {int(180 + $lvl*9)}]
                set cmax [expr {int(560 + $lvl*24)}]
                set xmin [expr {8 + int($lvl*0.3)}]
                set xmax [expr {17 + int($lvl*0.6)}]
            }
            hit {
                set names {"a rival hitman" "a contract killer" "an enforcer sent to whack you" "a masked gunman"}
                set hp   [expr {int((42 + $lvl*2.4) * (0.85+rand()*0.4))}]
                lassign [npc_gear_for_level $lvl 2 1] weapon armor
                # Hitmen pay a richer base reward than ordinary NPCs.
                # at the same level -- computed from that branch's formula
                # directly (not separate hardcoded coefficients) so the two
                # stay locked at exactly 2x even if npc's formula is ever
                # rebalanced. Do not hand-tune these independently.
                set cmin [expr {2 * int(180 + $lvl*9)}]
                set cmax [expr {2 * int(560 + $lvl*24)}]
                set xmin [expr {2 * (8 + int($lvl*0.3))}]
                set xmax [expr {2 * (17 + int($lvl*0.6))}]

                # small chance the hitman shows up with a much better loadout
                set groll [expr {rand()*100}]
                if {$groll < 3} {
                    lassign [npc_gear_for_level $lvl 6 2] weapon armor
                    set hp [expr {int($hp*1.4)}]
                    set cmin [expr {int($cmin*2.2)}]
                    set cmax [expr {int($cmax*2.2)}]
                    set xmin [expr {int($xmin*1.8)}]
                    set xmax [expr {int($xmax*1.8)}]
                    set geartag " \002(armed to the teeth with elite gear)\002"
                } elseif {$groll < 15} {
                    lassign [npc_gear_for_level $lvl 3 1] weapon armor
                    set hp [expr {int($hp*1.15)}]
                    set cmin [expr {int($cmin*1.4)}]
                    set cmax [expr {int($cmax*1.4)}]
                    set xmin [expr {int($xmin*1.3)}]
                    set xmax [expr {int($xmax*1.3)}]
                    set geartag " \002(packing upgraded equipment)\002"
                } else {
                    set geartag ""
                }
            }
            stealth {
                set names {"a rival dealer counting his stash" "a lone guard" "a drunk mobster" "a bookie closing up shop"}
                set hp   [expr {int((20 + $lvl*1.3) * (0.85+rand()*0.35))}]
                lassign [npc_gear_for_level $lvl -1] weapon armor
                set cmin [expr {int(70 + $lvl*6.5)}]
                set cmax [expr {int(260 + $lvl*16)}]
                set xmin [expr {4 + int($lvl*0.2)}]
                set xmax [expr {9 + int($lvl*0.4)}]
            }
            boss {
                set hp   [expr {int((220 + $lvl*5.0) * (0.95+rand()*0.2))}]
                set btier [expr {max(1,int(round($lvl/50.0)))}]
                lassign [boss_gear_for_tier $btier] weapon armor bling tool
                set cmin [expr {int(5000 + $lvl*90)}]
                set cmax [expr {int(12000 + $lvl*220)}]
                set xmin [expr {int(100 + $lvl*0.8)}]
                set xmax [expr {int(220 + $lvl*1.5)}]
            }
        }
        if {$hp < 10} { set hp 10 }
        if {$tier eq "boss"} {
            set name "boss"
        } else {
            set name [lindex $names [expr {int(rand()*[llength $names])}]]
            if {[info exists geartag] && $geartag ne ""} { append name $geartag }
        }
        return [list $name $hp $weapon $armor $cmin $cmax $xmin $xmax]
    }

    proc check_hospital {nick chan} {
        variable players
        variable hospital_time
        set k [string tolower $nick]
        if {$players($k,health) <= 0} {
            set players($k,health) 0
            set players($k,hosp_until) [expr {[now] + ($hospital_time*60)}]
            set players($k,hosp_notified) 0
            game_msg $nick $chan "\002$nick goes down and is rushed to the hospital\002 ([fmt_secs [expr {$hospital_time*60}]])."
        }
    }

    proc boss_difficulty_multiplier {tier} {
        # Boss gear scales upward every 50 levels. bdiff multiplies the
        # boss's effective HP/damage/armor (see run_npc_battle) -- it must
        # ramp UP with tier so Master Don (T20) is genuinely the hardest
        # fight in the game, not the easiest late-game boss. The climb is
        # kept modest (max +10%) because the player's own gear and stats
        # are also at their strongest by T20, so this should stay winnable
        # for a well-built Lv.1000+ player, not just brutal on paper.
        if {$tier <= 10} { return 1.0 }
        if {$tier <= 15} { return 1.03 }
        if {$tier <= 19} { return 1.06 }
        return 1.10
    }

    proc npc_damage_floor {lvl hpcap} {
        # Minimum damage one NPC swing does after the player's armor is
        # subtracted from it.
        #
        # An NPC's damage comes from the shop gear ladder, which tops out at
        # eclipse_railgun (680). A Lv.1000 player wears boss armor reducing
        # 1850, so every swing landed far below zero and got pinned to a flat
        # floor of 1 -- armor at that scale didn't blunt a hit, it erased it,
        # and late-game NPCs were mathematically incapable of hurting anyone
        # (measured: 0.1% of max HP lost per fight).
        #
        # Scaling the floor with the player's own HP pool fixes exactly that
        # case and nothing else: it can only ever apply when armor has already
        # absorbed the entire hit, so a player whose armor does NOT absorb it
        # is completely unaffected. That matters -- scaling NPC damage or HP
        # instead was measured to take an under-armored Lv.1000 player (say,
        # one who sold their boss gear) from winning 19% of NPC fights to
        # winning 0-5%, while barely moving the armored case this is meant to
        # fix. Ramps in from Lv.500; below that nothing changes at all.
        if {$lvl <= 500} { return 1 }
        set r [expr {min(1.0,($lvl-500)/500.0)}]
        return [expr {max(1,int($hpcap*0.12*$r))}]
    }

    proc run_npc_battle {nick chan nname nhp nweapon narmor stealth boss {boss_tier 0}} {
        # A full round-by-round fight against the player's real, persistent
        # HP -- exactly like a player-vs-player scrap. First side to hit
        # zero loses. Gear matters: better weapon/armor genuinely tips it.
        variable players
        # NOTE: this must NOT be "variable max_health; set max_health ..." --
        # that assigns to the namespace-wide 100 HP baseline, permanently
        # raising it to whatever the last fighter's personal cap was (and with
        # it every new player's starting HP and player_max_health's floor).
        # The player's own cap is a local value.
        set hpcap [player_max_health $nick]
        set k [string tolower $nick]
        set lvl [player_level $nick]

        set pdmg_base   [expr {int([weapon_dmg $players($k,weapon) $nick]*[pimp_damage_mult $nick])}]
        set parmor      [armor_reduce $players($k,armor) $nick]
        set ndmg_base   [weapon_dmg $nweapon]
        set narmor_val  [armor_reduce $narmor]
        set narmor_evasion_pct [armor_evasion $narmor]
        set pacc [get_stat $nick accuracy]
        set pdex [get_stat $nick dexterity]

        if {$boss && $boss_tier > 0} {
            set bdiff [boss_difficulty_multiplier $boss_tier]
            # Scale the effective boss profile (not the displayed/loot gear)
            # so difficulty ramps up through T11-T20, peaking at Master Don.
            set nhp [expr {max(100,int(round($nhp*$bdiff)))}]
            set ndmg_base [expr {max(1,int(round($ndmg_base*$bdiff)))}]
            set narmor_val [expr {max(0,int(round($narmor_val*$bdiff)))}]
        }

        # Armor still absorbs the overwhelming majority of every hit; this is
        # only the residue that gets through when it absorbs all of it.
        set ndmg_floor [npc_damage_floor $lvl $hpcap]

        set npc_acc [expr {min(90,32+int($lvl*0.15))}]
        set npc_dex [expr {min(68,20+int($lvl*0.12))}]
        if {$boss} {
            set npc_acc [expr {min(90,38+int($lvl*0.15))}]
            set npc_dex [expr {min(74,23+int($lvl*0.12))}]
        }

        set php $players($k,health)
        if {$php <= 0} { set php $hpcap }
        set start_php $php
        set start_nhp $nhp
        set rounds 0
        set phits 0
        set nhits 0

        set wname [weapon_name $players($k,weapon)]
        set aname [armor_name $narmor]
        if {$boss} {
            game_msg $nick $chan "$nick squares up against \002$nname\002, wielding \002$wname\002 against their \002[weapon_name $nweapon]\002 and \002$aname\002. HP: $php vs $nhp."
        }

        if {$stealth && !$boss} {
            set ambushchance [expr {int([get_stat $nick stealth]/8)}]
            if {int(rand()*100) < $ambushchance} {
                if {int(rand()*100) >= $narmor_evasion_pct} {
                    set dmg [expr {int($pdmg_base*[stealth_ambush_mult $nick]) - $narmor_val}]
                    if {$dmg < 1} { set dmg 1 }
                    set nhp [expr {$nhp-$dmg}]
                    incr phits
                    game_msg $nick $chan "$nick lands a silent opening strike on $nname for $dmg damage!"
                }
            }
        }

        while {$php > 0 && $nhp > 0 && $rounds < 40} {
            incr rounds
            # -- player's swing --
            set hitchance [expr {60 + int($pacc/5) - int($npc_dex/5)}]
            if {$hitchance < 10} { set hitchance 10 }
            if {$hitchance > 95} { set hitchance 95 }
            if {int(rand()*100) < $hitchance} {
                # NPC/boss armor carries the same armor-only evasion stat.
                if {int(rand()*100) >= $narmor_evasion_pct} {
                    set dmg [expr {int($pdmg_base*(0.85+rand()*0.35)) - $narmor_val}]
                    if {$dmg < 1} { set dmg 1 }
                    set nhp [expr {$nhp-$dmg}]
                    incr phits
                }
            }
            if {$nhp <= 0} { break }
            # -- npc's swing --
            set nhitchance [expr {60 + int($npc_acc/5) - int($pdex/5)}]
            if {$nhitchance < 10} { set nhitchance 10 }
            if {$nhitchance > 95} { set nhitchance 95 }
            if {int(rand()*100) < $nhitchance} {
                # Armor evasion is an armor-only defensive stat. It is rolled
                # before the legacy dexterity dodge so the two mechanisms remain
                # independent and the new armor percentage is never modified by
                # another stat.
                set armor_evasion_pct [armor_evasion $players($k,armor) $nick]
                if {int(rand()*100) >= $armor_evasion_pct && ![dodge_roll $nick]} {
                    set ndmg [expr {int($ndmg_base*(0.85+rand()*0.35)) - $parmor}]
                    if {$ndmg < $ndmg_floor} { set ndmg $ndmg_floor }
                    set php [expr {$php-$ndmg}]
                    incr nhits
                    # Autoheal is checked on every hit that lands, against the
                    # live in-fight hit points -- see battle_autoheal for why
                    # maybe_autoheal cannot be used here.
                    set php [battle_autoheal $nick $chan $php $hpcap]
                }
            }
        }

        if {$nhp <= 0 && $php <= 0} {
            # simultaneous knockout -- give the player the benefit
            set nhp 0
        } elseif {$rounds >= 40 && $php > 0 && $nhp > 0} {
            # dragged out too long -- decide on remaining HP%
            set ppct [expr {double($php)/double($start_php)}]
            set npct [expr {double($nhp)/double($start_nhp)}]
            if {$ppct >= $npct} { set nhp 0 } else { set php 0 }
        }

        set players($k,health) [expr {max(0,$php)}]
        maybe_autoheal $nick $chan
        set win [expr {$nhp <= 0}]

        if {$win} {
            if {$boss} {
                game_msg $nick $chan "\002$nick\002 grinds $nname down over $rounds brutal rounds ($phits hits landed, $nhits taken) and puts them on the ground for good."
            } elseif {$stealth} {
                game_msg $nick $chan "$nick slips past $nname's guard and finishes it in $rounds rounds without them ever really landing a clean shot back."
            } else {
                game_msg $nick $chan "$nick outlasts $nname after $rounds rounds of trading hits and leaves them face down."
            }
            if {$php < $start_php} {
                game_msg $nick $chan "$nick takes some damage in the process. ($players($k,health)/$hpcap HP)"
            }
        } else {
            if {$boss} {
                game_msg $nick $chan "\002$nname\002 outlasts $nick after $rounds grueling rounds -- better gear or a sharper edge and this one's winnable."
            } elseif {$stealth} {
                game_msg $nick $chan "$nick's sneak attack on $nname falls apart and it turns into a real fight -- $nick comes out on the losing end after $rounds rounds."
            } else {
                game_msg $nick $chan "$nick goes toe-to-toe with $nname for $rounds rounds and loses the scrap."
            }
            check_hospital $nick $chan
        }
        return $win
    }

    proc npc_fight_core {nick chan tier stealth {count_kill 0}} {
        # count_kill: when true, a win here increments the player's kill
        # count -- used for real "npc" fights, not plain cpu/street fodder.
        variable players
        set k [string tolower $nick]
        set lvl [player_level $nick]
        lassign [npc_gen $tier $lvl] nname nhp nweapon narmor cmin cmax xmin xmax

        set losemin [expr {max(1,int($cmin/3))}]
        set losemax [expr {max($losemin,int($cmax/3))}]
        set lxpmin  [expr {max(1,int($xmin/3))}]
        set lxpmax  [expr {max($lxpmin,int($xmax/3))}]

        set oldlvl [player_level $nick]
        set win [run_npc_battle $nick $chan $nname $nhp $nweapon $narmor $stealth 0]

        if {$win} {
            # Win reward multiplier is tier-specific: hit ("out of your
            # league" contract killers) pays 14x cash and 40x XP, npc pays 4x
            # cash and 4x XP. Street/cpu and stealth pay 3x cash / 8x XP.
            # (Bumped up from the original 10/30, 3/3, 2/6 baseline for
            # faster overall progression.)
            switch -- $tier {
                hit { set cash_mult 14; set xp_mult 40 }
                npc {
                    set cash_mult 4
                    set xp_mult 4
                    # A win over an NPC carrying equipment better than the
                    # player's current loadout is worth a 14x XP payout.
                    if {[weapon_dmg $nweapon] > [weapon_dmg $players($k,weapon) $nick] ||
                        [armor_reduce $narmor] > [armor_reduce $players($k,armor) $nick]} {
                        set xp_mult 14
                    }
                }
                default { set cash_mult 3; set xp_mult 8 }
            }
            set cash [expr {($cmin + int(rand()*($cmax-$cmin+1))) * $cash_mult}]
            set xp   [expr {($xmin + int(rand()*($xmax-$xmin+1))) * $xp_mult}]
            if {$count_kill} { incr players($k,kills) }
        } else {
            set cash [reward_cash $nick [expr {$losemin + int(rand()*($losemax-$losemin+1))}]]
            set xp   [reward_xp $nick [expr {$lxpmin + int(rand()*($lxpmax-$lxpmin+1))}]]
        }
        if {$win} {
            set cash [reward_cash $nick $cash]
            set xp   [reward_xp $nick $xp]
        }
        sync_level_stats $nick
        set newlvl [player_level $nick]
        game_msg $nick $chan "$nick: +[fmt_cash $cash], +$xp XP."
        if {$newlvl > $oldlvl} {
            game_msg $nick $chan "\002$nick leveled up to Lv.$newlvl!\002"
        }

        # Hit/npc equipment drop: whenever the hitman/npc loses (i.e. the
        # player wins), the player walks away with whatever gear that
        # specific hitman/npc was carrying (the same weapon/armor rolled
        # by npc_gen above) -- not a separate loot table. Gear rolls now
        # skew toward real gear more often (see npc_gear_for_level calls
        # above), and an enemy that rolled the "elite"/"upgraded" bonus
        # gear hands that better gear over too. "fists"/"none" are the
        # no-gear baseline, not real items, so they never drop, and
        # already-owned items are skipped since there's nothing new to
        # hand over. Street/stealth/boss fights still never drop gear.
        set can_drop_gear [expr {$win && ($tier eq "hit" || $tier eq "npc")}]
        if {$can_drop_gear} {
            ensure_gear_lists $nick
            # A given piece of gear drops for a player ONCE, ever -- tracked in
            # looted_gear, which is separate from current ownership on purpose.
            #
            # The drop used to test current ownership alone, which made it a
            # money printer at the top of the ladder: the gear roll saturates
            # (a Lv.1000 npc always carries the best shop weapon and armor,
            # since the variance band can no longer reach below the last
            # index), a boss-geared player wins every fight, and SELLING the
            # item makes it droppable again. Fight, loot, sell, repeat on a 12s
            # cooldown -- about 10,500,000 per weapon per cycle, the same
            # sell-and-refarm loop boss_gear_resale_throttle_pct exists to stop
            # for boss gear, just with no throttle on it at all.
            set looted [expr {[info exists players($k,looted_gear)] ? $players($k,looted_gear) : [list]}]
            set loot {}
            if {$nweapon ne "fists" && ![item_owned_weapon $nick $nweapon] &&
                [lsearch -exact $looted $nweapon] < 0} {
                lappend players($k,owned_weapons) $nweapon
                lappend looted $nweapon
                lappend loot "[weapon_name $nweapon] (weapon)"
            }
            if {$narmor ne "none" && ![item_owned_armor $nick $narmor] &&
                [lsearch -exact $looted $narmor] < 0} {
                lappend players($k,owned_armor) $narmor
                lappend looted $narmor
                lappend loot "[armor_name $narmor] (armor)"
            }
            if {[llength $loot]} {
                set players($k,looted_gear) $looted
                game_msg $nick $chan "$nick searches the body and walks off with: [join $loot {, }]. Use ${mafia::cmd_prefix}mafia equip <item> to switch to it."
            }
        }

        # A hit win can create one small-chance revenge encounter. Revenge is
        # now a fightable NPC encounter instead of an automatic percentage-based
        # cash theft. Only one revenge encounter can be pending per player.
        if {$win && $tier eq "hit"} {
            set revenge_chance [expr {3 + int([get_stat $nick stealth]/50)}]
            if {$revenge_chance > 5} { set revenge_chance 5 }
            if {[expr {int(rand()*100)}] < $revenge_chance} {
                lassign [npc_gen npc [player_level $nick]] rname rhp rweapon rarmor rcmin rcmax rxmin rxmax
                set players($k,revenge_name) $rname
                set players($k,revenge_hp) $rhp
                set players($k,revenge_weapon) $rweapon
                set players($k,revenge_armor) $rarmor
                game_msg $nick $chan "$nname's crew comes back looking for revenge. Fight them with !mafia revenge or !mafia fight revenge."
            }
        }
    }

    proc cmd_streetfight {nick chan} {
        normalize_player_economy $nick
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        variable players
        variable streetfight_cooldown
        set k [string tolower $nick]
        set last [getf $nick last_street 0]
        set elapsed [expr {[now]-$last}]
        if {$elapsed < $streetfight_cooldown} {
            game_msg $nick $chan "$nick: give it a minute. [fmt_secs [expr {$streetfight_cooldown-$elapsed}]] before the next street fight."
            return
        }
        set players($k,last_street) [now]
        npc_fight_core $nick $chan street 0
    }

    proc cmd_revenge {nick chan} {
        # Fight a pending hitman revenge crew. Revenge never auto-steals cash:
        # the player gets a chance to fight back. A loss can cost only $1,000-
        # $50,000 (or the player's entire remaining balance if below $1,000).
        normalize_player_economy $nick
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        variable players
        set k [string tolower $nick]
        foreach field {revenge_name revenge_hp revenge_weapon revenge_armor} {
            if {![info exists players($k,$field)] || $players($k,$field) eq ""} {
                game_msg $nick $chan "$nick: you have no revenge crew waiting for you."
                return
            }
        }

        set rname $players($k,revenge_name)
        set rhp $players($k,revenge_hp)
        set rweapon $players($k,revenge_weapon)
        set rarmor $players($k,revenge_armor)
        catch {unset players($k,revenge_name)}
        catch {unset players($k,revenge_hp)}
        catch {unset players($k,revenge_weapon)}
        catch {unset players($k,revenge_armor)}

        game_msg $nick $chan "$nick faces $rname's revenge crew. No backing down now..."
        set oldlvl [player_level $nick]
        set win [run_npc_battle $nick $chan $rname $rhp $rweapon $rarmor 0 0]
        if {$win} {
            set cash [expr {500 + int(rand()*4501)}]
            set xp [expr {100 + int(rand()*401)}]
            set cash [reward_cash $nick $cash]
            set xp [reward_xp $nick $xp]
            sync_level_stats $nick
            game_msg $nick $chan "$nick: you beat the revenge crew and keep your cash. +[fmt_cash $cash], +$xp XP."
            set newlvl [player_level $nick]
            if {$newlvl > $oldlvl} {
                game_msg $nick $chan "\002$nick leveled up to Lv.$newlvl!\002"
            }
        } else {
            set cash [getf $nick cash 0]
            if {$cash > 0} {
                set robamt [expr {1000 + int(rand()*49001)}]
                if {$robamt > 50000} { set robamt 50000 }
                if {$robamt > $cash} { set robamt $cash }
                incr players($k,cash) [expr {-$robamt}]
                game_msg $nick $chan "$rname's crew wins the revenge fight and takes [fmt_cash $robamt] from $nick. They finally back off."
            } else {
                game_msg $nick $chan "$rname's crew wins the revenge fight, but $nick has no cash for them to take. They back off."
            }
        }
        sync_level_stats $nick
    }

    proc cmd_npcfight {nick chan} {
        # Tougher and less predictable than a plain cpu/street scrap --
        # gear rolls swing wide, so some npcs are a soft touch and others
        # hit like a hitman. Payouts run richer than street fights, and
        # wins here count as real kills.
        normalize_player_economy $nick
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        variable players
        variable npcfight_cooldown
        set k [string tolower $nick]
        set last [getf $nick last_npc 0]
        set elapsed [expr {[now]-$last}]
        if {$elapsed < $npcfight_cooldown} {
            game_msg $nick $chan "$nick: no one worth jumping right now. [fmt_secs [expr {$npcfight_cooldown-$elapsed}]] before your next npc fight."
            return
        }
        set players($k,last_npc) [now]
        game_msg $nick $chan "$nick goes looking for trouble on the street. Could be nothing, could be a real fight..."
        npc_fight_core $nick $chan npc 0 1
    }

    proc cmd_hitfight {nick chan} {
        normalize_player_economy $nick
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        variable players
        variable hitfight_cooldown
        set k [string tolower $nick]
        set last [getf $nick last_hit 0]
        set elapsed [expr {[now]-$last}]
        if {$elapsed < $hitfight_cooldown} {
            game_msg $nick $chan "$nick: no hitmen worth taking on right now. [fmt_secs [expr {$hitfight_cooldown-$elapsed}]] cooldown."
            return
        }
        set players($k,last_hit) [now]
        game_msg $nick $chan "$nick goes looking for a hitman to take out. This one might be out of your league..."
        npc_fight_core $nick $chan hit 0
    }

    proc cmd_stealthfight {nick chan} {
        normalize_player_economy $nick
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        variable players
        variable stealthfight_cooldown
        set k [string tolower $nick]
        set last [getf $nick last_stealth 0]
        set elapsed [expr {[now]-$last}]
        if {$elapsed < $stealthfight_cooldown} {
            game_msg $nick $chan "$nick: lay low a bit longer. [fmt_secs [expr {$stealthfight_cooldown-$elapsed}]] before your next sneak attack."
            return
        }
        set players($k,last_stealth) [now]
        npc_fight_core $nick $chan stealth 1
    }

    proc boss_award_loot {nick chan tier weapon armor bling tool {final_mode 0} {first_kill 1}} {
        variable players
        set k [string tolower $nick]
        ensure_gear_lists $nick
        set loot {}

        # Master Don (Tier 20) drops exactly one piece of gear per kill,
        # never the full set: the Master Ice Factory bling on the very first
        # kill, and after that a single random weapon/armor/tool piece per
        # farming run. Earlier bosses still award their full weapon/armor/
        # ice/tool set on their one-time clear.
        set awards [list]
        if {$final_mode} {
            if {$first_kill} {
                lappend awards [list bling $bling]
            } else {
                set pick [lindex {weapon armor tool} [expr {int(rand()*3)}]]
                if {$pick eq "weapon"} { lappend awards [list weapon $weapon] }
                if {$pick eq "armor"}  { lappend awards [list armor $armor] }
                if {$pick eq "tool"}   { lappend awards [list tool $tool] }
            }
        } else {
            lappend awards [list weapon $weapon] [list armor $armor] [list bling $bling] [list tool $tool]
        }

        foreach award $awards {
            lassign $award kind item
            switch -- $kind {
                weapon {
                    if {$item eq "fists" || [item_owned_weapon $nick $item]} continue
                    lappend players($k,owned_weapons) $item
                    lappend loot "[weapon_name $item] (weapon)"
                    if {[gear_upgrade_ok $nick $item weapon]} {
                        set players($k,weapon) $item
                        lappend loot "[weapon_name $item] upgraded"
                    }
                }
                armor {
                    if {$item eq "none" || [item_owned_armor $nick $item]} continue
                    lappend players($k,owned_armor) $item
                    lappend loot "[armor_name $item] (armor)"
                    if {[gear_upgrade_ok $nick $item armor]} {
                        set players($k,armor) $item
                        lappend loot "[armor_name $item] upgraded"
                    }
                }
                bling {
                    if {$item eq "none" || [item_owned_bling $nick $item]} continue
                    lappend players($k,owned_bling) $item
                    if {[gear_upgrade_ok $nick $item bling bling]} {
                        set players($k,bling) $item
                        lappend loot "[bling_name $item] upgraded"
                    } else {
                        lappend loot "[bling_name $item] (bling)"
                    }
                }
                tool {
                    set bonus [apply_boss_tool_bonus $nick $item]
                    if {$bonus ne ""} {
                        lappend loot "[boss_tool_name $item] (permanent: $bonus)"
                    }
                }
            }
        }

        if {[llength $loot]} {
            game_msg $nick $chan "$nick strips the boss for: [join $loot {, }]."
        } elseif {!$final_mode} {
            game_msg $nick $chan "$nick already owns this boss's complete gear set."
        } else {
            game_msg $nick $chan "$nick already owns the available Master Don drop(s); the boss still pays out."
        }
        return $loot
    }

    proc cmd_boss {nick chan args} {
        normalize_player_economy $nick
        if {![need_registered $nick $chan]} return
        if {[blocked_state $nick $chan]} return
        variable players
        variable boss_names
        variable boss_cooldown
        variable boss_loot_bonus_mult
        set k [string tolower $nick]
        set cleared [getf $nick boss_tier_cleared 0]

        if {[llength $args] > 0} {
            set tier [lindex $args 0]
            if {![command_integer $tier 2] || $tier < 1 || $tier > 20} {
                game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia boss \[tier 1-20\]"
                return
            }
            if {$tier > $cleared + 1} {
                game_msg $nick $chan "$nick: Tier $tier is locked. Beat Tier [expr {$cleared+1}] first."
                return
            }
            # Tiers 1-19 are progression fights. Tier 20 remains replayable
            # after its first clear so the Master Don can be farmed.
            if {$tier < 20 && $tier <= $cleared} {
                game_msg $nick $chan "$nick: you already cleared \002[lindex $boss_names [expr {$tier-1}]]\002 (Tier $tier)."
                return
            }
        } else {
            if {$cleared < 20} {
                set tier [expr {$cleared+1}]
            } else {
                set tier 20
            }
        }

        set needed [expr {$tier*50}]
        set raw [level_for_xp $players($k,xp)]
        set bname [lindex $boss_names [expr {$tier-1}]]
        if {$raw < $needed} {
            game_msg $nick $chan "$nick: you're not ready for \002$bname\002 yet. You need Lv.$needed (currently Lv.[player_level $nick])."
            return
        }

        set last [getf $nick last_boss 0]
        set elapsed [expr {[now]-$last}]
        if {$elapsed < $boss_cooldown} {
            game_msg $nick $chan "$nick: you're still nursing wounds from your last run at \002$bname\002. [fmt_secs [expr {$boss_cooldown-$elapsed}]] left."
            return
        }

        set players($k,last_boss) [now]
        lassign [npc_gen boss $needed] _ nhp nweapon narmor cmin cmax xmin xmax
        lassign [boss_gear_for_tier $tier] loot_weapon loot_armor loot_bling loot_tool
        set nweapon $loot_weapon
        set narmor $loot_armor

        # Snapshot before the fight resolves: a Master Don win only counts as
        # the "first kill" (cash/xp/bling payout) if the player hadn't
        # already cleared Tier 20 coming in. Every win after that is a pure
        # gear-farming run -- no cash, no xp, one random item.
        set was_cleared $cleared
        set oldlvl [player_level $nick]
        game_msg $nick $chan "\002$nick\002 challenges \002$bname\002 (Tier $tier, Lv.$needed) -- first to zero hit points loses."
        set win [run_npc_battle $nick $chan $bname $nhp $nweapon $narmor 0 1 $tier]

        if {$win} {
            if {$tier > $cleared} { set players($k,boss_tier_cleared) $tier }
            set is_final [expr {$tier == 20}]
            set first_kill [expr {$is_final ? ($was_cleared < 20) : 1}]

            if {$is_final && !$first_kill} {
                # Farming run: Master Don no longer pays cash or xp, only gear.
                game_msg $nick $chan "\002$nick DEFEATS $bname again!\002 No cash or XP this time -- Master Don only drops gear now."
                boss_award_loot $nick $chan $tier $loot_weapon $loot_armor $loot_bling $loot_tool 1 0
                return
            }

            # Boss rewards scale forever (first-clear/non-final tiers).
            set cash [expr {$cmin + int(rand()*($cmax-$cmin+1))}]
            set xp [expr {$xmin + int(rand()*($xmax-$xmin+1))}]
            set cash [reward_cash $nick $cash]
            set xp [reward_xp $nick $xp]
            sync_level_stats $nick
            set newlvl [player_level $nick]

            game_msg $nick $chan "\002$nick DEFEATS $bname!\002 +[fmt_cash $cash], +$xp XP."
            if {$tier < 20 && $tier > $cleared} {
                game_msg $nick $chan "Tier [expr {$tier+1}] is now open."
            }
            if {$newlvl > $oldlvl} {
                game_msg $nick $chan "\002$nick reached Lv.$newlvl!\002"
            }
            if {$is_final && $first_kill} {
                game_msg $nick $chan "\002$nick has defeated the Master Don and is now MASTER DON!\002"
            }

            set bonus [expr {int((($cmin+$cmax)/2.0)*$boss_loot_bonus_mult)}]
            set bonus [reward_cash $nick $bonus]
            game_msg $nick $chan "\002$nick cleans out $bname's stash: +[fmt_cash $bonus]!\002"
            boss_award_loot $nick $chan $tier $loot_weapon $loot_armor $loot_bling $loot_tool $is_final $first_kill
        } else {
            set cash [reward_cash $nick [expr {max(1,int($cmin/5))}]]
            set xp [reward_xp $nick [expr {max(1,int($xmin/5))}]]
            sync_level_stats $nick
            game_msg $nick $chan "$nick: \002$bname\002 was too much this time -- +[fmt_cash $cash], +$xp XP. No gear drops on a loss."
        }
    }

}
# mafia_encounters.tcl - ambient random police/street encounters.
namespace eval mafia {
    ##### =====================================================
    #####                 RANDOM ENCOUNTERS
    ##### =====================================================
    # Ambient police / street-thug encounters fire on their own timer per
    # channel and are open to the whole channel -- they do not target
    # whoever happened to trigger the ambient check. The encounter is
    # announced to the channel and whichever registered, eligible player
    # responds first (!mafia faceoff/talk/run/hide/payoff) claims it and
    # it resolves against them. Nobody is singled out or forced to react.

    variable encounter_next   ;# array: encounter_next(chan) -> timestamp
    array set encounter_next {}
    variable encounter_day
    array set encounter_day {}
    variable encounter_count
    array set encounter_count {}
    variable encounter_response_time  ;# seconds to respond before it auto-resolves (defined/configured in mafia_core.tcl)
    variable encounter_payoff_cash  50    ;# flat cash cost to pay off a police officer during an encounter

    # Channel-scoped encounter state: chan_enc($c,field) -> value.
    # Fields: type name until gen timer_id. Deliberately NOT stored under
    # players(...) -- it belongs to the channel, not any one player, so it
    # is naturally immune to per-command state_snapshot/state_restore
    # rollback and to the players() persistence layer (never saved, never
    # needs restoring after a rehash/restart; it simply lapses, same as a
    # normal timeout).
    variable chan_enc
    array set chan_enc {}

    proc chan_msg {chan msg} {
        # Encounter announcements are addressed to the whole channel and
        # must be visible to everyone who might want to respond, so this
        # is deliberately independent of the configured output_mode
        # (notice/privmsg would otherwise send an "anyone can join" ambush
        # to nobody in particular).
        set msg [string map [list "\r" " " "\n" " "] $msg]
        # Empty/whitespace-bearing channel rejected too -- see game_msg.
        if {$chan eq "" || [string first " " $chan] >= 0 ||
            [string first "\r" $chan] >= 0 || [string first "\n" $chan] >= 0 ||
            [string length $chan] > 200} {
            putlog "mafia.tcl: refusing unsafe IRC output target"
            return
        }
        putserv "PRIVMSG $chan :$msg"
    }

    proc maybe_random_encounter {nick chan} {
        variable encounter_next
        variable encounter_min_gap
        variable encounter_max_gap
        variable chan_enc
        # encounter_day/encounter_count are declared HERE, not further down
        # next to their first read. The stale-channel prune below reaches them
        # indirectly ([array names $arr]), and an undeclared name inside a proc
        # resolves to a nonexistent LOCAL -- array names returns empty and the
        # unset quietly fails, so the prune walked nothing and both arrays grew
        # a permanent entry per parted channel. Same defect rehash_cleanup
        # already carries a comment about having fixed on its own copy.
        variable encounter_day
        variable encounter_count

        # Prune timestamps for channels the bot has left. Without this,
        # channel churn can leave encounter_next(*) keys resident forever.
        if {[llength [info commands channels]]} {
            set active_channels {}
            foreach active_chan [channels] {
                lappend active_channels [string tolower $active_chan]
            }
            foreach stale_chan [array names encounter_next] {
                if {[lsearch -exact $active_channels $stale_chan] < 0} {
                    catch {unset encounter_next($stale_chan)}
                }
            }
            foreach arr {encounter_day encounter_count} {
                foreach stale_chan [array names $arr] {
                    if {[lsearch -exact $active_channels $stale_chan] < 0} {
                        catch {unset ${arr}($stale_chan)}
                    }
                }
            }
            # Same churn problem applies to chan_enc(chan,field) -- it's
            # keyed by channel, not player, so it's never touched by the
            # per-player persistence/cleanup paths. Without this, a bot that
            # cycles through many channels over a long uptime accumulates
            # five stale array entries per parted channel forever.
            set stale_enc_chans {}
            foreach enc_key [array names chan_enc] {
                set enc_chan [lindex [split $enc_key ","] 0]
                if {[lsearch -exact $active_channels $enc_chan] < 0 &&
                    [lsearch -exact $stale_enc_chans $enc_chan] < 0} {
                    lappend stale_enc_chans $enc_chan
                }
            }
            foreach stale_enc_chan $stale_enc_chans {
                set tid [expr {[info exists chan_enc($stale_enc_chan,timer_id)] ? $chan_enc($stale_enc_chan,timer_id) : ""}]
                if {$tid ne ""} { catch {killutimer $tid} }
                # Literal prefix match, not a glob pattern: IRC channel names
                # may contain [ ] { } \ -- all Tcl glob metacharacters -- and
                # such a channel's keys would never match the pattern, leaking
                # its five chan_enc entries forever.
                set enc_prefix "${stale_enc_chan},"
                set enc_plen [string length $enc_prefix]
                foreach enc_key [array names chan_enc] {
                    if {[string equal -length $enc_plen $enc_prefix $enc_key]} {
                        catch {unset chan_enc($enc_key)}
                    }
                }
            }
        }

        variable encounter_daily_limit
        set c [string tolower $chan]
        set today [clock format [now] -format %Y-%m-%d]
        if {![info exists encounter_day($c)] || $encounter_day($c) ne $today} {
            set encounter_day($c) $today
            set encounter_count($c) 0
        }
        if {$encounter_count($c) >= $encounter_daily_limit} {
            # Resume automatically after the local calendar day rolls over.
            set tomorrow [clock add [clock scan "$today 00:00" -format "%Y-%m-%d %H:%M"] 1 day]
            set encounter_next($c) $tomorrow
            return
        }
        # cmd_admin_config refuses an inverted min/max pair, but Mafia.cfg is
        # not run through that check. With max < min the span goes negative,
        # rand() scales it negative, and the "next encounter" stamp lands in
        # the PAST -- so the gap collapses entirely and an encounter fires on
        # effectively every command typed in the channel. Clamp the span and
        # the floor rather than trusting the pair's ordering.
        set gap_min [cfg_interval $encounter_min_gap 300 0]
        set gap_span [expr {[cfg_interval $encounter_max_gap 900 0] - $gap_min}]
        if {$gap_span < 0} { set gap_span 0 }
        if {![info exists encounter_next($c)]} {
            set encounter_next($c) [expr {[now] + $gap_min + int(rand()*($gap_span+1))}]
            return
        }
        if {[now] < $encounter_next($c)} {
            return
        }
        incr encounter_count($c)
        set encounter_next($c) [expr {[now] + $gap_min + int(rand()*($gap_span+1))}]
        fire_encounter $chan
    }

    proc chan_has_pending_encounter {chan} {
        variable chan_enc
        set c [string tolower $chan]
        if {![info exists chan_enc($c,type)] || $chan_enc($c,type) eq ""} { return 0 }
        return [expr {[time_left $chan_enc($c,until)] > 0}]
    }

    proc clear_chan_encounter {chan} {
        variable chan_enc
        set c [string tolower $chan]
        set tid [expr {[info exists chan_enc($c,timer_id)] ? $chan_enc($c,timer_id) : ""}]
        if {$tid ne ""} { catch {killutimer $tid} }
        set chan_enc($c,type)      ""
        set chan_enc($c,name)      ""
        set chan_enc($c,until)     0
        set chan_enc($c,timer_id)  ""
    }

    proc fire_encounter {chan} {
        variable chan_enc
        variable encounter_response_time
        variable game_gen
        set c [string tolower $chan]
        if {[chan_has_pending_encounter $chan]} { return }  ;# don't stack encounters

        set type [expr {int(rand()*2) == 0 ? "police" : "thug"}]
        if {$type eq "police"} {
            set names {"a beat cop" "a patrol officer" "a suspicious detective"}
        } else {
            set names {"a street thug" "a mugger in a hoodie" "a knife-wielding punk" "a desperate junkie"}
        }
        set ename [lindex $names [expr {int(rand()*[llength $names])}]]

        # cmd_admin_config bounds this to 5-600, but Mafia.cfg is edited by
        # hand and goes through no such check. A 0 or negative value here
        # becomes a zero-delay utimer that fires the timeout callback before
        # anyone can answer, and an "until" stamp already in the past -- so
        # every encounter would announce itself and immediately expire.
        set resp [cfg_interval $encounter_response_time 60 5]

        incr game_gen
        set chan_enc($c,type)  $type
        set chan_enc($c,name)  $ename
        set chan_enc($c,until) [expr {[now] + $resp}]
        set chan_enc($c,gen)   $game_gen

        set p $mafia::cmd_prefix
        if {$type eq "police"} {
            variable encounter_payoff_cash
            chan_msg $chan "\002Police encounter!\002 $ename rolls up on the block. Anyone up for it -- first to ${p}mafia faceoff, ${p}mafia talk, ${p}mafia run, ${p}mafia hide, or ${p}mafia payoff (slip them [fmt_cash $encounter_payoff_cash] and walk) claims it! ([fmt_secs $resp] before they move on)"
        } else {
            chan_msg $chan "\002Ambush!\002 $ename jumps out looking for trouble. Anyone up for it -- first to ${p}mafia faceoff, ${p}mafia talk, ${p}mafia run, or ${p}mafia hide claims it! ([fmt_secs $resp] before they move on)"
        }

        set chan_enc($c,timer_id) [utimer $resp [list ::mafia::encounter_timeout $chan $game_gen]]
    }

    proc encounter_timeout {chan gen} {
        variable chan_enc
        set c [string tolower $chan]
        if {![info exists chan_enc($c,gen)] || $chan_enc($c,gen) != $gen} { return }   ;# already claimed/replaced
        if {![info exists chan_enc($c,type)] || $chan_enc($c,type) eq ""} { return }
        set ename [expr {[info exists chan_enc($c,name)] ? $chan_enc($c,name) : "they"}]
        chan_msg $chan "Nobody steps up -- $ename gets bored and wanders off."
        clear_chan_encounter $chan
    }

    proc resolve_encounter {nick chan choice} {
        variable players
        normalize_player_economy $nick
        variable jail_time
        variable hide_time
        set k [string tolower $nick]

        # Claim it first: read the shared type/name, then immediately clear
        # the channel encounter so a second response arriving right behind
        # this one has nothing left to claim. Eggdrop's single-threaded
        # event loop makes this read-then-clear atomic with respect to
        # other incoming commands.
        if {![chan_has_pending_encounter $chan]} { return }
        set c [string tolower $chan]
        set type  $mafia::chan_enc($c,type)
        set ename $mafia::chan_enc($c,name)
        clear_chan_encounter $chan

        set catchmod [catch_mod $nick]

        if {$type eq "police"} {
            switch -- $choice {
                fight {
                    set roll [expr {int(rand()*100)}]
                    if {$roll < max(5,20+$catchmod)} {
                        game_msg $nick $chan "$nick throws hands with $ename and manages to knock them down and bolt before backup arrives!"
                        set players($k,xp) [expr {$players($k,xp)+3}]
                    } else {
                        set players($k,jail_until) [expr {[now]+($jail_time*60)}]
                        set players($k,jail_notified) 0
                        set dmg [expr {5+int(rand()*15)}]
                        set players($k,health) [expr {$players($k,health)-$dmg}]
                        game_msg $nick $chan "\002Bad move.\002 $nick resists arrest and gets worked over before getting hauled off. Jail for ${jail_time}m."
                        maybe_autoheal $nick $chan
                        check_hospital $nick $chan
                    }
                }
                talk {
                    set roll [expr {int(rand()*100)}]
                    if {$roll < max(10,40+$catchmod)} {
                        game_msg $nick $chan "$nick smooth-talks $ename into letting it slide. Close call."
                    } else {
                        set players($k,jail_until) [expr {[now]+(($jail_time*60)/2)}]
                        set players($k,jail_notified) 0
                        game_msg $nick $chan "$ename isn't buying it. $nick gets cuffed. Jail for [fmt_secs [expr {($jail_time*60)/2}]]."
                    }
                }
                run {
                    set roll [expr {int(rand()*100)}]
                    if {$roll < max(15,45+$catchmod)} {
                        game_msg $nick $chan "$nick bolts and loses $ename in the alleys."
                    } else {
                        set players($k,jail_until) [expr {[now]+($jail_time*60)}]
                        set players($k,jail_notified) 0
                        game_msg $nick $chan "$nick doesn't get far. $ename catches up. Jail for ${jail_time}m."
                    }
                }
                hide {
                    set roll [expr {int(rand()*100)}]
                    if {$roll < max(20,50+$catchmod+[boss_bonus_pct $nick resist_jail])} {
                        set players($k,hide_until) [expr {[now]+($hide_time*60)}]
                        game_msg $nick $chan "$nick ducks into the shadows and $ename walks right past."
                    } else {
                        set players($k,jail_until) [expr {[now]+(($jail_time*60)/2)}]
                        set players($k,jail_notified) 0
                        game_msg $nick $chan "$ename spots $nick trying to hide. Jail for [fmt_secs [expr {($jail_time*60)/2}]]."
                    }
                }
            }
        } else {
            ;# street thug
            switch -- $choice {
                fight {
                    set lvl [player_level $nick]
                    set pdmg [weapon_dmg $players($k,weapon) $nick]
                    set parmor [armor_reduce $players($k,armor) $nick]
                    set ppower [expr {($pdmg + $lvl*0.5) * (0.9+rand()*0.2)}]
                    set npower [expr {(15 + rand()*20) * (0.75+rand()*0.5)}]
                    set total [expr {$ppower+$npower}]
                    set winchance [expr {$total > 0 ? ($ppower/$total) : 0.5}]
                    if {$winchance < 0.2} { set winchance 0.2 }
                    if {$winchance > 0.9} { set winchance 0.9 }
                    if {rand() <= $winchance} {
                        set cash [expr {30+int(rand()*120)}]
                        set players($k,cash) [expr {$players($k,cash)+$cash}]
                        set players($k,xp) [expr {$players($k,xp)+4}]
                        game_msg $nick $chan "$nick fights off $ename and shakes them down for [fmt_cash $cash]."
                    } else {
                        set dmg [expr {8+int(rand()*20)-$parmor}]
                        if {$dmg < 1} { set dmg 1 }
                        set players($k,health) [expr {$players($k,health)-$dmg}]
                        game_msg $nick $chan "$ename gets the better of $nick for $dmg damage."
                        maybe_autoheal $nick $chan
                        check_hospital $nick $chan
                    }
                }
                talk {
                    set roll [expr {int(rand()*100)}]
                    if {$roll < 40} {
                        game_msg $nick $chan "$nick talks $ename down. They back off empty-handed."
                    } else {
                        set amt [expr {$players($k,cash) > 20 ? int($players($k,cash)*(0.03+rand()*0.08)) : 0}]
                        set players($k,cash) [expr {$players($k,cash)-$amt}]
                        game_msg $nick $chan "$ename isn't in a listening mood and shakes $nick down for [fmt_cash $amt]."
                    }
                }
                run {
                    set roll [expr {int(rand()*100)}]
                    if {$roll < 55} {
                        game_msg $nick $chan "$nick outruns $ename, no harm done."
                    } else {
                        set amt [expr {$players($k,cash) > 20 ? int($players($k,cash)*(0.05+rand()*0.15)) : 0}]
                        set players($k,cash) [expr {$players($k,cash)-$amt}]
                        game_msg $nick $chan "$ename catches $nick before they get away. Robbed for [fmt_cash $amt]."
                    }
                }
                hide {
                    set roll [expr {int(rand()*100)}]
                    if {$roll < 60} {
                        set players($k,hide_until) [expr {[now]+($hide_time*60)}]
                        game_msg $nick $chan "$nick melts into a doorway and $ename moves on."
                    } else {
                        set amt [expr {$players($k,cash) > 20 ? int($players($k,cash)*(0.05+rand()*0.1)) : 0}]
                        set players($k,cash) [expr {$players($k,cash)-$amt}]
                        game_msg $nick $chan "$ename spots $nick anyway and grabs [fmt_cash $amt] before taking off."
                    }
                }
            }
        }
    }

}
# mafia_misc.tcl - remaining player commands (deal prices, drug buy/sell,
# bank deposit/withdraw, top, don) and rehash cleanup.
namespace eval mafia {
    proc cmd_dealprices {nick chan} {
        variable drugs
        set out [list]
        foreach d [lsort [array names drugs]] {
            lappend out "$d: [fmt_cash [drug_price $d]]"
        }
        game_msg $nick $chan "\002Drug prices\002 -- [join $out { | }]"
    }

    proc cmd_allprices {nick chan} {
        # Combined market view for !mafia prices.
        cmd_dealprices $nick $chan
        cmd_pimpprices $nick $chan
        cmd_casinoprices $nick $chan
        cmd_dealerprices $nick $chan
    }


    proc cmd_drug {nick chan args} {
        if {![need_registered $nick $chan]} return
        normalize_player_economy $nick
        if {[blocked_state $nick $chan]} return
        variable deal_cooldown
        variable drugs
        if {[llength $args] < 1} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia drug prices \[drug\] | buy <drug|all> <qty> | sell <drug|all> <qty> | dealer prices|buy|remove|status | supply <tier> <qty> | collect"
            return
        }
        set action [string tolower [lindex $args 0]]

        # Drug dealer operation subcommands (passive income network) live
        # under the same top-level !mafia drug command as street dealing.
        if {$action eq "dealer"} {
            set dsub [expr {[llength $args] > 1 ? [string tolower [lindex $args 1]] : "prices"}]
            switch -- $dsub {
                prices  { cmd_dealerprices $nick $chan }
                buy     { cmd_dealer_buy $nick $chan {*}[lrange $args 2 end] }
                remove  -
                fire    { cmd_dealer_remove $nick $chan {*}[lrange $args 2 end] }
                status  -
                workers -
                network { cmd_dealer_status $nick $chan }
                default { game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia drug dealer prices | buy <tier> \[qty\] | remove <tier> \[qty|all\] | status" }
            }
            return
        }
        if {$action eq "dealers"} {
            # Shorthand so !mafia drug dealers behaves like !mafia pimp workers.
            cmd_dealer_status $nick $chan
            return
        }
        if {$action eq "supply"} {
            cmd_drug_supply $nick $chan {*}[lrange $args 1 end]
            return
        }
        if {$action eq "collect"} {
            cmd_drug_collect $nick $chan
            return
        }

        # Bulk drug commands use the exact requested syntax:
        #   !mafia drug buy all <qty>
        #   !mafia drug sell all <qty>
        # <amt> is applied to every drug in the current catalog.
        if {$action eq "buy" && [llength $args] >= 3 && [string tolower [lindex $args 1]] eq "all"} {
            cmd_buy_drugs_all $nick $chan [lindex $args 2]
            return
        }
        if {$action eq "sell" && [llength $args] >= 3 && [string tolower [lindex $args 1]] eq "all"} {
            cmd_sell_drugs_all $nick $chan [lindex $args 2]
            return
        }

        # Prices are informational and do not require a quantity.
        if {$action eq "prices"} {
            set dname [expr {[llength $args] >= 2 ? [string tolower [lindex $args 1]] : "all"}]
            if {$dname eq "all"} {
                cmd_dealprices $nick $chan
                return
            }
            if {![info exists drugs($dname)]} {
                game_msg $nick $chan "No such drug. Use ${mafia::cmd_prefix}mafia drug prices."
                return
            }
            game_msg $nick $chan "$dname street price: [fmt_cash [drug_price $dname]]"
            return
        }

        if {[llength $args] < 3} {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia drug prices \[drug\] | buy <drug|all> <qty> | sell <drug|all> <qty> | dealer prices|buy|remove|status | supply <tier> <qty> | collect"
            return
        }
        set dname [string tolower [lindex $args 1]]
        set qty [lindex $args 2]
        if {![info exists drugs($dname)]} { game_msg $nick $chan "No such drug. See ${mafia::cmd_prefix}mafia drug prices"; return }
        if {![command_integer $qty 12] || $qty < 1} { game_msg $nick $chan "Quantity must be a positive number."; return }
        if {$qty > 10000} { game_msg $nick $chan "$nick: max 10000 per deal."; return }

        variable players
        set k [string tolower $nick]
        set elapsed [expr {[now]-$players($k,last_deal)}]
        if {$elapsed < $deal_cooldown} {
            game_msg $nick $chan "$nick: too hot right now. Wait [fmt_secs [expr {$deal_cooldown-$elapsed}]] before dealing again."
            return
        }
        set price [drug_price $dname]
        set total [expr {$price*$qty}]
        set econ_pct [player_bling_econ_pct $nick]

        if {$action eq "buy"} {
            set buy_total [expr {int(round($total * (1.0 - ($econ_pct/100.0))))}]
            if {$players($k,cash) < $buy_total} { game_msg $nick $chan "$nick: you need [fmt_cash $buy_total], you have [fmt_cash $players($k,cash)]."; return }
            set players($k,last_deal) [now]
            # police bust chance while buying
            set bust [expr {int(rand()*100)}]
            if {$bust < max(0,1-[catch_mod $nick])} {
                variable jail_time
                set players($k,jail_until) [expr {[now]+($jail_time*60)}]
                set players($k,jail_notified) 0
                game_msg $nick $chan "\002RAID!\002 $nick was buying $dname when the cops rolled up. Straight to jail for ${jail_time}m."
                return
            }
            set players($k,cash) [expr {$players($k,cash)-$buy_total}]
            incr players($k,drug,$dname) $qty
            if {$econ_pct > 0} {
                game_msg $nick $chan "$nick buys $qty $dname for [fmt_cash $buy_total]. (bling discount: -${econ_pct}%)"
            } else {
                game_msg $nick $chan "$nick buys $qty $dname for [fmt_cash $buy_total]."
            }
        } elseif {$action eq "sell"} {
            if {[getf $nick drug,$dname 0] < $qty} { game_msg $nick $chan "$nick: you don't have $qty $dname to sell."; return }
            set players($k,last_deal) [now]
            set bust [expr {int(rand()*100)}]
            if {$bust < max(0,2-[catch_mod $nick])} {
                variable jail_time
                set players($k,jail_until) [expr {[now]+($jail_time*60)}]
                set players($k,jail_notified) 0
                incr players($k,drug,$dname) [expr {-$qty}]
                game_msg $nick $chan "\002BUSTED!\002 $nick got caught selling $dname to an undercover cop. Product confiscated, jail for ${jail_time}m."
                return
            }
            set sell_total [expr {int(round($total * (1.0 + ($econ_pct/100.0))))}]
            incr players($k,drug,$dname) [expr {-$qty}]
            set players($k,cash) [expr {$players($k,cash)+$sell_total}]
            set players($k,xp) [expr {$players($k,xp)+int($qty/2)+1}]
            if {$econ_pct > 0} {
                game_msg $nick $chan "$nick sells $qty $dname on the street for [fmt_cash $sell_total]. (bling bonus: +${econ_pct}%)"
            } else {
                game_msg $nick $chan "$nick sells $qty $dname on the street for [fmt_cash $sell_total]."
            }
        } else {
            game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia drug prices \[drug\] | buy <drug|all> <qty> | sell <drug|all> <qty> | dealer prices|buy|remove|status | supply <tier> <qty> | collect"
        }
    }

    # "!mafia buy drugs all <amt>" -- buys <amt> units of every drug at once
    # at current street prices, in a single transaction: one cooldown check,
    # one bust roll, one bling discount, instead of repeating !mafia drug
    # buy <drug> <amt> once per drug in the catalog.
    proc cmd_buy_drugs_all {nick chan qty} {
        if {![need_registered $nick $chan]} return
        normalize_player_economy $nick
        if {[blocked_state $nick $chan]} return
        variable deal_cooldown
        variable jail_time
        variable drugs
        variable players

        if {![command_integer $qty 12] || $qty < 1} { game_msg $nick $chan "Quantity must be a positive number."; return }
        if {$qty > 10000} { game_msg $nick $chan "$nick: max 10000 per drug per deal."; return }

        set k [string tolower $nick]
        set elapsed [expr {[now]-$players($k,last_deal)}]
        if {$elapsed < $deal_cooldown} {
            game_msg $nick $chan "$nick: too hot right now. Wait [fmt_secs [expr {$deal_cooldown-$elapsed}]] before dealing again."
            return
        }

        set dnames [lsort [array names drugs]]
        set econ_pct [player_bling_econ_pct $nick]
        set grand_total 0
        foreach d $dnames {
            set total [expr {[drug_price $d]*$qty}]
            incr grand_total [expr {int(round($total * (1.0 - ($econ_pct/100.0))))}]
        }
        if {$players($k,cash) < $grand_total} {
            game_msg $nick $chan "$nick: buying $qty of every drug ([fmt_cash $grand_total] total) would cost more than you have ([fmt_cash $players($k,cash)]). Try a smaller amount."
            return
        }

        set players($k,last_deal) [now]
        # Single bust roll for the whole run, same base odds as one normal
        # drug buy -- buying in bulk isn't any riskier or safer per trip.
        set bust [expr {int(rand()*100)}]
        if {$bust < max(0,1-[catch_mod $nick])} {
            set players($k,jail_until) [expr {[now]+($jail_time*60)}]
            set players($k,jail_notified) 0
            game_msg $nick $chan "\002RAID!\002 $nick was loading up on product when the cops rolled up. Straight to jail for ${jail_time}m -- nothing bought."
            return
        }

        set players($k,cash) [expr {$players($k,cash)-$grand_total}]
        foreach d $dnames { incr players($k,drug,$d) $qty }
        if {$econ_pct > 0} {
            game_msg $nick $chan "$nick buys $qty of every drug ([join $dnames {, }]) for [fmt_cash $grand_total] total. (bling discount: -${econ_pct}%)"
        } else {
            game_msg $nick $chan "$nick buys $qty of every drug ([join $dnames {, }]) for [fmt_cash $grand_total] total."
        }
    }

    # Sells <qty> units of every drug in one atomic transaction.
    # Uses the normal drug-sale cooldown and one police roll for the whole
    # basket. If the player lacks any requested drug, nothing is sold.
    proc cmd_sell_drugs_all {nick chan qty} {
        if {![need_registered $nick $chan]} return
        normalize_player_economy $nick
        if {[blocked_state $nick $chan]} return
        variable deal_cooldown
        variable jail_time
        variable drugs
        variable players

        if {![command_integer $qty 12] || $qty < 1} {
            game_msg $nick $chan "Quantity must be a positive number."
            return
        }
        if {$qty > 10000} {
            game_msg $nick $chan "$nick: max 10000 per drug per deal."
            return
        }

        set k [string tolower $nick]
        set elapsed [expr {[now]-$players($k,last_deal)}]
        if {$elapsed < $deal_cooldown} {
            game_msg $nick $chan "$nick: too hot right now. Wait [fmt_secs [expr {$deal_cooldown-$elapsed}]] before dealing again."
            return
        }

        set dnames [lsort [array names drugs]]
        foreach d $dnames {
            if {[getf $nick drug,$d 0] < $qty} {
                game_msg $nick $chan "$nick: you need at least $qty $d to sell all."
                return
            }
        }

        set econ_pct [player_bling_econ_pct $nick]
        set grand_total 0
        foreach d $dnames {
            set raw [expr {[drug_price $d]*$qty}]
            incr grand_total [expr {int(round($raw * (1.0 + ($econ_pct/100.0))))}]
        }

        set players($k,last_deal) [now]
        set bust [expr {int(rand()*100)}]
        if {$bust < max(0,2-[catch_mod $nick])} {
            set players($k,jail_until) [expr {[now]+($jail_time*60)}]
            set players($k,jail_notified) 0
            foreach d $dnames { incr players($k,drug,$d) [expr {-$qty}] }
            game_msg $nick $chan "\002BUSTED!\002 $nick got caught selling a full load of product to an undercover cop. All $qty units of each drug confiscated, jail for ${jail_time}m."
            return
        }

        foreach d $dnames { incr players($k,drug,$d) [expr {-$qty}] }
        set players($k,cash) [expr {$players($k,cash)+$grand_total}]
        if {$econ_pct > 0} {
            game_msg $nick $chan "$nick sells $qty of every drug ([join $dnames {, }]) for [fmt_cash $grand_total] total. (bling bonus: +${econ_pct}%)"
        } else {
            game_msg $nick $chan "$nick sells $qty of every drug ([join $dnames {, }]) for [fmt_cash $grand_total] total."
        }
    }

    proc cmd_deposit {nick chan args} {
        if {![need_registered $nick $chan]} return
        normalize_player_economy $nick
        if {[llength $args] < 1} { game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia deposit <amount|all>"; return }
        variable players
        set k [string tolower $nick]
        set amt [lindex $args 0]
        # "all" is sourced from the player's own balance, not from what they
        # typed, so it must not be run through the twelve-digit input guard --
        # command_integer exists to stop a player pasting a million-digit
        # number, and a late-game balance of a trillion or more is a legitimate
        # value that guard would reject. The result: "deposit all" told the
        # richest players on the bot their own cash was an "invalid amount".
        set is_all [expr {$amt eq "all"}]
        if {$is_all} { set amt $players($k,cash) }
        if {(!$is_all && ![command_integer $amt 12]) ||
            ![string is integer -strict $amt] || $amt < 1 || $amt > $players($k,cash)} {
            game_msg $nick $chan "$nick: invalid amount."
            return
        }
        set players($k,cash) [expr {$players($k,cash)-$amt}]
        set players($k,bank) [expr {$players($k,bank)+$amt}]
        game_msg $nick $chan "$nick deposits [fmt_cash $amt] into the family bank. Robbers can't touch bank funds."
    }

    proc cmd_withdraw {nick chan args} {
        if {![need_registered $nick $chan]} return
        normalize_player_economy $nick
        if {[llength $args] < 1} { game_msg $nick $chan "Usage: ${mafia::cmd_prefix}mafia withdraw <amount|all>"; return }
        variable players
        set k [string tolower $nick]
        set amt [lindex $args 0]
        # See cmd_deposit: the "all" value comes from the player's own bank
        # balance, so the typed-input digit cap must not be applied to it.
        set is_all [expr {$amt eq "all"}]
        if {$is_all} { set amt $players($k,bank) }
        if {(!$is_all && ![command_integer $amt 12]) ||
            ![string is integer -strict $amt] || $amt < 1 || $amt > $players($k,bank)} {
            game_msg $nick $chan "$nick: invalid amount."
            return
        }
        set players($k,bank) [expr {$players($k,bank)-$amt}]
        set players($k,cash) [expr {$players($k,cash)+$amt}]
        game_msg $nick $chan "$nick withdraws [fmt_cash $amt] from the family bank."
    }

    proc cmd_top {nick chan} {
        variable players
        set names {}
        foreach key [array names players "*,cash"] {
            set k [lindex [split $key ,] 0]
            lappend names $k
        }
        set names [lsort -unique $names]
        set scored {}
        foreach k $names {
            # One malformed row must not take the whole leaderboard down with
            # it. A row with a cash field but no name -- or with a non-integer
            # cash/bank/xp -- is corrupt rather than something to repair from
            # here, so skip it and keep ranking everybody else. The jail and
            # hospital expiry timers guard the same field the same way.
            #
            # Read with info exists, not getf: getf seeds its default INTO the
            # array, so probing for a missing name would persist an empty one.
            if {![info exists players($k,name)] || $players($k,name) eq ""} { continue }
            if {[catch {
                set lvl [player_level $players($k,name)]
                set score [expr {$players($k,cash)+$players($k,bank)+($players($k,xp)*5)}]
            }]} { continue }
            lappend scored [list $score $players($k,name) $lvl]
        }
        set scored [lsort -integer -decreasing -index 0 $scored]
        game_msg $nick $chan "\002-- Top Mafia --\002"
        set i 1
        foreach entry [lrange $scored 0 4] {
            lassign $entry score pname lvl
            game_msg $nick $chan "  $i. $pname \[Lv.$lvl\] -- score $score"
            incr i
        }
    }

    proc cmd_don {nick chan} {
        variable players
        set names {}
        foreach key [array names players "*,xp"] {
            lappend names [lindex [split $key ,] 0]
        }
        set names [lsort -unique $names]
        set bestxp -1
        set bestname ""
        # Same guard as cmd_top: skip rows missing a name or carrying a
        # non-integer xp instead of letting one corrupt row throw and take the
        # command down. info exists rather than getf, so probing never seeds
        # the missing field into the array.
        set ranked {}
        foreach k $names {
            if {![info exists players($k,name)] || $players($k,name) eq ""} { continue }
            if {![info exists players($k,xp)] || ![string is integer -strict $players($k,xp)]} { continue }
            lappend ranked $k
            if {$players($k,xp) > $bestxp} { set bestxp $players($k,xp); set bestname $players($k,name) }
        }
        set names $ranked
        if {$bestname eq ""} {
            game_msg $nick $chan "No one's in the family yet."
            return
        }
        variable ranks
        # ranks is a flat {threshold title threshold title ...} list, so the
        # last element is the title "Don" -- the Don XP threshold is the
        # element before it. Using `end` printed "1234/Don XP".
        set donxp [lindex $ranks end-1]
        set dons {}
        set master_dons {}
        foreach k $names {
            # Non-creating read, matching the two guards above. This was the
            # last getf left on a whole-table sweep: it seeded a
            # boss_tier_cleared=0 row into EVERY listed player who had never
            # fought a boss, on every !mafia don -- rows that save_db then
            # wrote back to SQLite for good.
            set k_cleared 0
            if {[info exists players($k,boss_tier_cleared)] &&
                [string is integer -strict $players($k,boss_tier_cleared)]} {
                set k_cleared $players($k,boss_tier_cleared)
            }
            if {$k_cleared >= 20} {
                lappend master_dons $players($k,name)
            } elseif {[player_level $players($k,name)] >= 500} {
                lappend dons $players($k,name)
            }
        }
        if {[llength $master_dons] > 0} {
            game_msg $nick $chan "\002Master Don(s):\002 [join $master_dons {, }]."
            if {[llength $dons] > 0} { game_msg $nick $chan "\002Don(s):\002 [join $dons {, }]." }
        } elseif {[llength $dons] > 0} {
            game_msg $nick $chan "\002Don(s) of the family:\002 [join $dons {, }]. Any player can reach Don at Lv.500 -- there's no limit on how many."
        } else {
            set rank [rank_for_xp $bestxp]
            game_msg $nick $chan "No one has reached Don yet. $bestname leads the pack as $rank ($bestxp/$donxp XP)."
        }
    }

    # Tear down every resource owned by this script before a .rehash.  The
    # top-level reload guard calls this while the OLD namespace and its timer IDs
    # still exist, then deletes the namespace so removed/renamed variables and
    # procs cannot linger in memory.
    proc rehash_cleanup {} {
        variable players
        variable encounter_next
        # These two must be declared here as well: `array unset encounter_day`
        # in a proc that never declared it operates on a nonexistent LOCAL
        # variable, so the namespace arrays were never actually cleared.
        variable encounter_day
        variable encounter_count
        variable db
        variable db_ready
        variable db_in_txn
        variable cmd_prefix
        variable bound_prefix

        # Persist the most recent in-memory state before closing the old DB.
        # Rehash cleanup must also tolerate a partially initialized instance.
        if {[info exists db_ready] && $db_ready && [llength [info commands ::mafia::save_db]]} {
            if {![save_db 1]} {
                # Do not pretend the newest state was persisted. The database
                # still contains the last successful snapshot, so close the
                # handle normally and let the new instance load that snapshot.
                putlog "mafia.tcl: rehash cleanup could not save current game state; reloading from last successful database snapshot."
            }
        }

        # Invalidate callbacks first; this also closes killutimer race windows.
        # Each timer chain has its own epoch (see the CONFIG block), so bump
        # them all rather than a single shared counter -- a shared counter
        # would invalidate every OTHER chain's in-flight callback the moment
        # any one of them restarts below, exactly like the bug that used to
        # silently kill the hospital/jail release-notification timers.
        foreach __ev {autosave_epoch drug_market_epoch pimp_market_epoch
                      blackmarket_epoch jail_epoch hospital_epoch cleanup_epoch} {
            variable $__ev
            if {![info exists $__ev]} { set $__ev 1 }
            incr $__ev
        }
        catch {unset __ev}

        # Cancel the seven recurring timer chains owned by this script.
        foreach v {autosave_timer_id drug_market_timer_id pimp_market_timer_id blackmarket_timer_id jail_timer_id hospital_timer_id cleanup_timer_id} {
            if {[info exists ::mafia::$v]} {
                set tid [set ::mafia::$v]
                if {$tid ne "" && [llength [info commands killutimer]]} {
                    catch {killutimer $tid}
                }
                set ::mafia::$v ""
            }
        }

        # Random encounters use one-shot timers scoped to the channel, not
        # the player. Cancel them too so no callback from the old script
        # instance survives into the new one; the encounter itself is not
        # persisted, so it's fine for it to simply lapse across a rehash.
        variable chan_enc
        if {[info exists chan_enc] && [llength [info commands killutimer]]} {
            foreach key [array names chan_enc "*,timer_id"] {
                set tid $chan_enc($key)
                if {$tid ne ""} { catch {killutimer $tid} }
            }
        }

        # Explicitly clear transient arrays during teardown. The namespace is
        # deleted immediately afterward, but clearing them here makes cleanup
        # safe even if a future loader keeps the namespace alive.
        catch {array unset encounter_next}
        catch {array unset encounter_day}
        catch {array unset encounter_count}
        catch {array unset chan_enc}

        # Player state is persisted above; release the old in-memory array now
        # so a failed/partial reload cannot leave a large stale array resident.
        catch {array unset players}

        # Remove binds using the OLD prefix.  This also handles a config change
        # such as ! -> . without leaving the former command triggers registered.
        foreach p [lsort -unique [list $bound_prefix $cmd_prefix]] {
            if {$p eq ""} { continue }
            catch {unbind pub - "${p}mafia"        ::mafia::raw_mafia}
            catch {unbind pub - "${p}mafiahelp"    ::mafia::raw_help}
            catch {unbind pub - "${p}mafiaadmin"   ::mafia::raw_mafiaadmin}
        }
        foreach ev {prerestart die sigterm sigquit sighup} {
            catch {unbind evnt - $ev ::mafia::evnt_save}
        }
        set bound_prefix ""

        # Close the SQLite command explicitly; namespace deletion alone should
        # not be relied upon to release its file descriptors/locks promptly.
        if {[llength [info commands ::mafia::mafia_db]]} {
            catch {::mafia::mafia_db close}
        }
        set db ""
        set db_ready 0
        set db_in_txn 0
        return 1
    }

}
# mafia_init.tcl - bind registration + startup bootstrap. Must be sourced
# LAST: it calls procs defined in every other module.
namespace eval mafia {
    ##### =====================================================
    #####                 INIT
    ##### =====================================================

    ##### =====================================================
    ##### CONFIG VALIDATION -- applied to whatever Mafia.cfg produced
    ##### =====================================================
    #
    # cmd_admin_config carries roughly twenty range checks, and NONE of them
    # apply to Mafia.cfg. That asymmetry is noted in half a dozen comments
    # through this file ("Mafia.cfg is hand-edited and is NOT filtered by
    # cmd_admin_config's range checks") and patched one use site at a time
    # with cfg_interval -- which covers the timer delays and nothing else.
    # The result is that a value the admin command REFUSES is accepted
    # silently when typed into the .cfg instead, including:
    #
    #   admin_flags ""        -- matchattr with an empty flag string matches
    #                            EVERY user, so !mafiaadmin give/reset/prune
    #                            becomes public. The admin command refuses
    #                            this explicitly and says why; the cfg path
    #                            had no check at all.
    #   dealer_refund_pct 100 -- buy a dealer, remove it, profit. Unlimited
    #                            money loop. The .cfg comment asks the
    #                            operator to keep it under 100; nothing
    #                            enforced it.
    #   jail_bribe_min > max  -- cmd_bribe rolls min + rand()*(max-min+1), so
    #                            an inverted pair PAYS the player to leave
    #                            jail. Ordering is enforced by the admin
    #                            command, not by the cfg.
    #   encounter_min_gap > max_gap -- same shape (clamped at the use site,
    #                            but the stored pair stays wrong).
    #   max_level 1           -- stat_target_for_level divides by
    #                            (max_level - 1). A divide-by-zero on every
    #                            command that syncs stats, i.e. all of them.
    #                            max_level is cfg-only (not in
    #                            admin_config_keys), so nothing looked at it.
    #   max_level 50000000    -- build_level_thresholds builds a list with one
    #                            element per level at load. Same knob, other
    #                            direction: the bot allocates a fifty-million
    #                            element list before it finishes sourcing.
    #   any key deleted       -- a missing "variable NAME value" line leaves
    #                            the variable undefined, and the first command
    #                            that reads it dies with "no such variable" --
    #                            for start_cash that is every register, for
    #                            admin_flags every admin command.
    #
    # This runs once at load, after the cfg has been sourced and after this
    # file's own defaults, and applies the SAME bounds the admin command
    # uses, so the two paths can no longer disagree. Every correction is
    # logged with what was found and what it was forced to, because a
    # silently-corrected config is how an operator ends up believing a
    # setting is in effect when it isn't.
    variable config_defaults {
        chan                    {str    ""          400}
        cmd_prefix              {prefix "!"         4}
        output_mode             {enum   "notice"    {notice privmsg channel}}
        admin_flags             {flags  "n|m"       32}
        db_dir                  {str    ""          400}
        save_interval           {int    5           1       1440}
        start_cash              {int    500         0       1000000000}
        jail_time               {int    5           0       10080}
        hospital_time           {int    2           0       10080}
        hide_time               {int    10          0       10080}
        jail_bribe_min          {int    50000       0       1000000000}
        jail_bribe_max          {int    1000000     0       1000000000}
        jail_risk_multiplier    {dbl    0.50        0       10}
        crime_cooldown          {int    8           0       86400}
        attack_cooldown         {int    60          0       86400}
        rob_cooldown            {int    60          0       86400}
        deal_cooldown           {int    90          0       86400}
        streetfight_cooldown    {int    8           0       86400}
        npcfight_cooldown       {int    12          0       86400}
        hitfight_cooldown       {int    15          0       86400}
        stealthfight_cooldown   {int    60          0       86400}
        wiretap_cooldown        {int    100         0       86400}
        boss_cooldown           {int    45          0       86400}
        job_cooldown          {int    8           0       86400}
        gamble_cooldown         {int    20          0       86400}
        pimp_collect_cooldown   {int    3600        0       86400}
        casino_collect_cooldown {int    3600        0       86400}
        dealer_collect_cooldown {int    3600        0       86400}
        dealer_refund_pct       {int    40          0       99}
        autoheal_threshold_pct  {int    25          0       100}
        encounter_min_gap       {int    3600        0       86400}
        encounter_max_gap       {int    10800       0       86400}
        encounter_daily_limit   {int    4           0       1000}
        encounter_response_time {int    25          5       600}
        inactive_days           {int    180         7       3650}
        cleanup_warn_days       {int    14          1       3650}
        auto_cleanup_interval_days {int 180         7       3650}
        auto_cleanup_poll_secs  {int    21600       60      86400}
        max_health              {int    100         1       1000000}
        max_level               {int    1000        2       100000}
        legend_drop_pct         {dbl    5           0       100}
        legend_roll_cooldown    {int    600         30      604800}
        cmd_burst               {int    5           1       100}
        cmd_refill_secs         {int    2           0       3600}
        register_per_min        {int    10          1       1000}
    }

    proc validate_config {} {
        variable config_defaults
        set fixed 0
        foreach {key spec} $config_defaults {
            set kind    [lindex $spec 0]
            set default [lindex $spec 1]
            set a       [lindex $spec 2]
            set b       [lindex $spec 3]
            set have    [info exists ::mafia::$key]
            # if/else rather than a ternary: [set ::mafia::$key] on the
            # not-taken branch would be a read of a variable that does not
            # exist, and this proc's whole job is the case where it doesn't.
            if {$have} { set val [set ::mafia::$key] } else { set val "" }
            set bad ""

            if {!$have} {
                set bad "missing from Mafia.cfg"
            } else {
                switch -- $kind {
                    int {
                        if {![string is integer -strict $val]} {
                            set bad "not a whole number"
                        } elseif {$val < $a || $val > $b} {
                            set bad "outside $a-$b"
                        }
                    }
                    dbl {
                        if {![string is double -strict $val]} {
                            set bad "not a number"
                        } elseif {$val < $a || $val > $b} {
                            set bad "outside $a-$b"
                        }
                    }
                    enum {
                        # game_msg lowercases before dispatching, so accept
                        # any casing rather than rejecting a valid "Notice".
                        set lv [string tolower $val]
                        if {$lv ni $a} {
                            set bad "must be one of: [join $a {, }]"
                        } elseif {$lv ne $val} {
                            set ::mafia::$key $lv
                        }
                    }
                    prefix {
                        if {$val eq "" || [string length $val] > $a ||
                            [regexp {\s} $val]} {
                            set bad "must be 1-$a non-whitespace characters"
                        }
                    }
                    flags {
                        # An empty flag string makes matchattr match everyone.
                        if {$val eq "" || [regexp {\s} $val] ||
                            [string length $val] > $a} {
                            set bad "must be a non-empty flag string with no spaces"
                        }
                    }
                    str {
                        if {[regexp {[\r\n]} $val] || [string length $val] > $a} {
                            set bad "must be a single line of at most $a characters"
                        }
                    }
                }
            }

            if {$bad ne ""} {
                if {$have} { set shown "'$val'" } else { set shown "unset" }
                putlog "mafia.tcl: CONFIG: $key ($shown) is invalid -- $bad; using $default."
                set ::mafia::$key $default
                incr fixed
            }
        }

        # Ordering pairs. Each is enforced by cmd_admin_config and by nothing
        # on the cfg path; the consequence of an inverted pair is not a
        # cosmetic one (see the header comment: an inverted bribe range pays
        # the player), so repair rather than merely clamp at the use site.
        foreach {lo hi label} {
            jail_bribe_min jail_bribe_max "bribe"
            encounter_min_gap encounter_max_gap "encounter gap"
        } {
            if {[set ::mafia::$lo] > [set ::mafia::$hi]} {
                putlog "mafia.tcl: CONFIG: $lo ([set ::mafia::$lo]) is greater than $hi ([set ::mafia::$hi]); swapping them so the $label range is not inverted."
                set tmp [set ::mafia::$lo]
                set ::mafia::$lo [set ::mafia::$hi]
                set ::mafia::$hi $tmp
                incr fixed
            }
        }

        if {$fixed > 0} {
            putlog "mafia.tcl: CONFIG: corrected $fixed setting(s) from Mafia.cfg -- see the lines above. Fix Mafia.cfg so the corrections aren't needed on the next load."
        }
        return $fixed
    }

    proc init_binds {} {
        variable cmd_prefix
        variable bound_prefix
        # Remove both the prefix we actually bound last time and the desired
        # current prefix. This fixes live cmd_prefix changes leaking stale binds.
        foreach p [lsort -unique [list $bound_prefix $cmd_prefix]] {
            if {$p eq ""} { continue }
            catch {unbind pub - "${p}mafia"        ::mafia::raw_mafia}
            catch {unbind pub - "${p}mafiahelp"    ::mafia::raw_help}
            catch {unbind pub - "${p}mafiaadmin"   ::mafia::raw_mafiaadmin}
        }
        set p $cmd_prefix
        bind pub - "${p}mafia"        ::mafia::raw_mafia
        bind pub - "${p}mafiahelp"    ::mafia::raw_help
        bind pub - "${p}mafiaadmin"   ::mafia::raw_mafiaadmin
        set bound_prefix $p
        foreach ev {prerestart die sigterm sigquit sighup} {
            catch {unbind evnt - $ev ::mafia::evnt_save}
            bind evnt - $ev ::mafia::evnt_save
        }
    }

    # Commands checkpoint themselves, but timer-driven changes (jail/hospital
    # releases, market rolls, the auto-cleanup sweep) only reach disk on the
    # autosave, up to save_interval minutes later. A .rehash saves through
    # rehash_cleanup; .restart, .die and the fatal signals had no hook at
    # all, so those changes were lost. evnt handlers must return 0.
    proc evnt_save {type} {
        variable db_ready
        if {[info exists db_ready] && $db_ready} { catch {save_db 1} }
        return 0
    }

    # MUST run before load_db and the normalize sweep below. level_thresholds
    # starts out empty, and level_for_xp does [lindex $level_thresholds end]
    # then compares xp against it -- against an empty list that comparison is
    # a Tcl error ("can't use empty string as operand of <="), not a miss. Both
    # load_db's HP migration and the per-player normalize_player_economy pass
    # reach level_for_xp through sync_level_stats/player_level, and both wrap
    # the call in catch, so building the table afterwards meant every
    # load-time repair silently did nothing on every single startup and
    # rehash. It depends on nothing but max_level, so it belongs up here.
    #
    # And validate_config has to come before even that: build_level_thresholds
    # loops to max_level, so an absurd value there allocates before anything
    # else gets a chance to complain, and a max_level of 1 leaves
    # stat_target_for_level dividing by zero for the rest of the session.
    validate_config
    build_level_thresholds
    if {[init_db]} {
        migrate_legacy_flatfile
        load_db
        # SQLite corruption must never be mistaken for a clean persistent state.
        # Integrity checking is read-only; if it reports anything other than "ok",
        # log it prominently so the operator can restore from a known-good backup.
        catch {
            set __integrity [$mafia::db onecolumn {PRAGMA integrity_check}]
            if {$__integrity ne "ok"} {
                putlog "mafia.tcl: WARNING: SQLite integrity_check reported: $__integrity"
            }
        } __integrity_err
        if {[info exists __integrity_err] && $__integrity_err ne ""} {
            putlog "mafia.tcl: SQLite integrity_check failed to run: $__integrity_err"
        }
        # Repair legacy/corrupt economy values before the first command or save,
        # and sweep out fields left behind by retired/renamed catalog entries.
        # The sweep is load-time only -- see prune_retired_fields.
        set __pruned 0
        catch {set __pruned [prune_retired_fields]}
        if {$__pruned > 0} {
            putlog "mafia.tcl: dropped $__pruned retired player field(s) left over from older catalog entries."
        }
        foreach __key [array names ::mafia::players "*,cash"] {
            set __comma [string first "," $__key]
            if {$__comma > 0} {
                catch {normalize_player_economy [string range $__key 0 [expr {$__comma-1}]]}
            }
        }
        # __key/__comma are loop variables at NAMESPACE scope, so they become
        # ::mafia::__key and ::mafia::__comma and outlive the block -- the
        # same leak the header comment at the top of this file describes
        # fixing for __v/__tid, in the same shape, two thousand lines apart.
        # -nocomplain and one name per call, for the reason given there: a
        # single multi-name unset aborts on the first name that isn't set.
        foreach __leftover {__pruned __integrity __integrity_err __key __comma} {
            unset -nocomplain ::mafia::$__leftover
        }
        unset -nocomplain __leftover
        putlog "mafia.tcl: database ready at $mafia::db_file"
    } else {
        putlog "mafia.tcl: running without persistence -- game data will not be saved."
    }
    if {[array size ::mafia::drug_price_arr] == 0} { roll_drug_prices }
    if {[array size ::mafia::pimp_price_arr] == 0} { roll_pimp_prices }
    init_binds
    start_autosave_timer
    start_drug_market_timer
    start_pimp_market_timer
    start_blackmarket_timer
    start_jail_expiry_timer
    start_hospital_expiry_timer
    start_auto_cleanup_timer
}

putlog "mafia.tcl loaded."
