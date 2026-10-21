##############################################################################
# mem.tcl -- one-shot memory/state diagnostic for the eggdrop.
#
# Adds a partyline command, .memdiag, that walks a list of NAMESPACES
# (not a hardcoded list of variable names) and reports, for every array
# found in each namespace (including child namespaces):
#   - element count
#   - a rough byte estimate (sum of [string length] of every key+value;
#     NOT a real allocator measurement, just relative weight to rank
#     arrays against each other on THIS bot)
#
# Namespace-based discovery matters whenever you don't have full source
# for something running on the bot: a hardcoded variable list can only
# report what you already knew to ask about; this finds whatever is
# actually there, including runtime-only state that never reaches a .db.
# Scripts that keep state in plain GLOBAL arrays (no namespace) can't be
# discovered that way, so those are tracked by name in global_arrays.
#
# Also reports:
#   - outstanding utimer/timer counts (core eggdrop queues)
#   - [after info] queue length (Tcl-level periodic sweeps); a runaway
#     queue is the rehash-stacking failure mode, and is listed (capped)
#   - [memory info] if this Tcl build has it (most eggdrop builds don't;
#     reports "unavailable" instead of erroring)
#   - VmRSS/VmHWM from /proc/self/status as ground truth (Linux only)
#
# This does NOT explain WHY something is big -- it tells you WHICH
# namespace/array is big, so you know where to go read code next.
#
# Usage (partyline, owner 'n' flag):
#   .memdiag            full report
#   .memdiag force      full report, also measuring arrays that have read/
#                       array traces (those traces WILL fire)
#   .memdiag help       usage summary only (also: ? -h --help)
#   .memdiag <other>    the same full report; the argument is ignored
#                       and a note says so rather than failing silently
#
# Install: drop in your scripts dir and `source` it from your conf (or
# from the partyline: .tcl source scripts/<thisfile>), then run
# .memdiag. Safe to load standalone -- namespaces that don't exist on
# this bot are just noted as "not loaded".
#
# Design notes (why the code looks the way it does):
#   - bytes_of walks the array with a search iterator, one element at a
#     time. [array get] would build a complete copy of the array, and
#     even [array names] builds a list of every key; on the biggest array
#     on the bot either one is the memory spike this tool exists to find.
#     The search token is always released, even if a read fails midway.
#   - measuring a value with [string length] would give a pure list/dict/
#     number its string form permanently (extra memory, in the process
#     being measured). Where this Tcl has tcl::unsupported::representation
#     (8.6+), values that have NO string form yet are skipped, counted, and
#     reported as "unmeasured", so bytes are then a lower bound but nothing
#     is changed. Where it is missing, the old behaviour applies and the
#     report says so.
#   - reading a value or asking an array for its size/keys would FIRE any
#     read (or array) trace another script put on it. So an array with a
#     read/array trace is not touched at all and is listed as "not
#     measured", and a single element with its own read trace has just
#     that value skipped (counted as unmeasured). `.memdiag force`
#     measures them anyway, accepting that those traces fire. Checking
#     for traces (trace info) fires nothing -- but [array exists] DOES fire
#     array traces, and [info exists] on an element fires read traces, so
#     the trace check always comes FIRST: a variable with a read/array
#     trace is never even probed with [array exists] unless forced (it is
#     reported as "not inspected"), and an element's trace is checked
#     before [info exists] touches it.
#   - every array is measured under its own catch, so one unreadable
#     variable (a read trace that errors, a trace that unsets it during
#     the walk) is reported on its own line instead of aborting the report.
#   - arrays are deduplicated by IDENTITY, not by name, across roots AND
#     global_arrays: listing a root plus a namespace beneath it, a
#     namespaced array in global_arrays, or a variable linked with
#     upvar/namespace upvar to an array elsewhere, cannot double-count
#     totals. Identity is found by putting a temporary no-op unset trace
#     (::memdiag::_mark) on each candidate and reading back which markers
#     show up on which name -- a link reports the traces of the variable
#     it points at. The markers are removed again before measuring; they
#     never fire, and no array is written to. An entry whose arrays were
#     all counted earlier says so on its own line, which is the cue to
#     remove it. Leading "::" on entries is ignored.
#   - that detection depends on how Tcl treats traces on linked variables,
#     so every run first SELF-TESTS it on scratch variables (a real array
#     plus one link made with `namespace upvar` and one with `upvar`,
#     in a throwaway namespace that is deleted afterwards). If the test
#     fails the report says so, and falls back to flagging arrays whose
#     element count and byte estimate are identical as "possible alias"
#     (flagged only, never removed from the totals -- distinct arrays
#     can legitimately look alike).
#   - all output goes through `say`, which strips control characters
#     (except bold, ^B) and truncates. [after] scripts, error text and
#     echoed arguments can contain data that originated elsewhere; it must
#     not be able to inject terminal escapes into a partyline session.
#   - the command re-checks the owner flag itself, so loosening the flag
#     on the bind line below does not silently expose internals.
#   - the bind is recorded and unbound by what was ACTUALLY registered, so
#     editing the flag/command name and re-sourcing (or .rehash) replaces
#     the old bind instead of leaving both live.
#   - /proc/self/status is read with a size cap and the channel is closed
#     on every path.
##############################################################################

namespace eval memdiag {

    # Top-level namespaces to scan. Add to this list as you add scripts --
    # you only need the NAMESPACE, not every array inside it; child
    # namespaces (e.g. fishing::fishhelp) are found automatically.
    #
    # Notes:
    #   - dalhelp also covers dalnet_sendnotice_ratelimit.tcl/sendnotice.tcl
    #     (their arrays are declared in `namespace eval dalhelp`).
    #   - orpg and orpghelp (openrpg.tcl) are two separate top-level
    #     namespaces; the recursive scan finds children of a listed root,
    #     not siblings of it, so both need an entry.
    #   - the "bs" NAMESPACE (battleship.tcl) is a different thing from the
    #     "bs" GLOBAL ARRAY in global_arrays (bseen.tcl); they don't
    #     clash. Battleship shows as "bs::<name>", bseen as plain "bs".
    #   - golf and poker keep everything under their own namespace: one
    #     entry each.
    #   - winhelp/susehelp/archhelp/buntuhelp/linuxhelp/debhelp/bsdhelp all
    #     keep rate-limit/output-mode state under their own namespace
    #     (covered here) but load their big topic-data arrays (help/
    #     topic_desc/topic_chapter/help_detail, per OS for bsdhelp) as
    #     plain globals -- see global_arrays. Confirmed against the actual
    #     data files (deb_data.tcl, bsd_data.tcl, etc.), which declare
    #     every one of those with `array set ::name {}` at file scope, no
    #     `namespace eval` wrapping it -- this comment previously claimed
    #     bsdhelp/debhelp kept everything namespaced, which left their
    #     data arrays out of global_arrays entirely (debhelp's ~1-2K
    #     entries and all three BSDs') and meant .memdiag silently
    #     under-reported two of the seven help scripts.
    #
    # IMPORTANT: this variable's value is one braced Tcl list, and "#" has
    # no special meaning INSIDE the braces (it's only a comment at the
    # start of a command). A comment placed inside the list becomes
    # literal list content, and a stray brace in it can break list parsing
    # outright. Keep notes up here, never inside the braces below.
    #
    # This and global_arrays/max_after_listed/max_proc_bytes/max_line
    # below are plain `set`, so the current literal applies on every load
    # and every .rehash (an edit here is picked up by a rehash). `bound`
    # further down is the opposite: it must survive a rehash unchanged,
    # so it is declared with a bare `variable` plus an existence guard.
    set roots {
        homerunsmash
        fishing
        MelonPoems
        dalhelp
        fight
        masterhelp
        whocom
        talkbot
        talkbotcost
        nickserv
        sysinfo
        guard
        autorestrict
        mafia
        casino
        DuckHunt
        Mono
        cribbage
        baseball
        Risk
        convert
        bs
        blackjack
        bowling
        clue
        com
        Life
        orpg
        orpghelp
        golf
        poker
        bsdhelp
        debhelp
        winhelp
        susehelp
        archhelp
        buntuhelp
        linuxhelp
    }

    # Plain-GLOBAL arrays (scripts with no namespace of their own), tracked
    # by name and checked with [array exists ::name]:
    #   spychan.tcl (spy, spy_logseen, spy_helpseen), BlackScrabble.tcl (scrabble),
    #   bseen.tcl (bs, bs_list, bs_flood_hosts, bs_enabled_bychan,
    #   bs_botidle), StairsAndSlides.tcl (stairs, stairs_slides),
    #   dccwhois.tcl (dccwhois_flags), ques5.tcl (web_file).
    #   bs_flood_hosts/bs_enabled_bychan/bs_botidle were missing entirely --
    #   they're declared with `global` + a guarded `array set` inside procs
    #   (not a top-level `array set` at file scope like bs/bs_list), so a
    #   plain read of the file's top level wouldn't turn them up, and the
    #   namespace-recursive scan can't find them either since bseen.tcl has
    #   no namespace. All three are exactly the kind of thing this tool
    #   exists to catch: bs_flood_hosts is keyed per host and only ever
    #   grows within the flood window, bs_enabled_bychan is keyed per
    #   channel, and bs_botidle is keyed per channel (bseen.tcl's own
    #   "audit2-fix" comment notes it used to leak an entry per channel
    #   left forever -- worth being able to see its size even now that it's
    #   pruned).
    # Plus the topic-data arrays of winhelp/win_data.tcl, susehelp/
    # suse_data.tcl, archhelp/arch_data.tcl, buntuhelp/buntu_data.tcl,
    # linuxhelp/linux_data.tcl, debhelp/deb_data.tcl and bsdhelp/
    # bsd_data.tcl (per-OS: freebsd_/openbsd_/netbsd_) -- the LARGEST
    # arrays those scripts hold (the whole help text), including each
    # one's help_detail companion array (the in-depth "<topic> <command>"
    # write-ups, parallel to its help array). debhelp's and bsdhelp's were
    # missing here entirely (see the roots-list note above), and every
    # script's help_detail array was missing even where its help/
    # topic_desc/topic_chapter triad was already tracked.
    # Scripts that hold only scalars/lists in globals need no entry.
    set global_arrays {
        spy
        spy_logseen
        spy_helpseen
        scrabble
        bs
        bs_list
        bs_flood_hosts
        bs_enabled_bychan
        bs_botidle

        stairs
        stairs_slides
        dccwhois_flags
        web_file

        windows_help
        windows_topic_desc
        windows_topic_chapter
        windows_help_detail

        suse_help
        suse_topic_desc
        suse_topic_chapter
        suse_help_detail

        arch_help
        arch_topic_desc
        arch_topic_chapter
        arch_help_detail

        ubuntu_help
        ubuntu_topic_desc
        ubuntu_topic_chapter
        ubuntu_help_detail

        linux_help
        linux_topic_desc
        linux_topic_chapter
        linux_help_detail

        debian_help
        debian_topic_desc
        debian_topic_chapter
        debian_help_detail

        freebsd_help
        freebsd_topic_desc
        freebsd_topic_chapter
        freebsd_help_detail

        openbsd_help
        openbsd_topic_desc
        openbsd_topic_chapter
        openbsd_help_detail

        netbsd_help
        netbsd_topic_desc
        netbsd_topic_chapter
        netbsd_help_detail

        bsdhelp_osname
        bsdhelp_osref
    }

    # Normalise both lists: drop blanks and leading "::", collapse exact
    # duplicates, and give a stable order so two runs list things the same
    # way. (Overlap that survives this -- a root plus a child of it -- is
    # handled per-array at report time.)
    foreach _l {roots global_arrays} {
        set _n {}
        foreach _e [set $_l] {
            set _e [string trimleft $_e :]
            if {$_e ne ""} { lappend _n $_e }
        }
        set $_l [lsort -unique $_n]
    }
    unset -nocomplain _l _n _e

    # Cap on how many [after] events .memdiag prints individually. The
    # queue being huge is exactly what triggers the dump, so one line per
    # entry would make the worse the bug, the harder this floods the
    # partyline.
    set max_after_listed 25

    # Cap on bytes read from /proc/self/status (real file is ~1.5 KB).
    set max_proc_bytes 65536

    # Cap on the length of any single output line.
    set max_line 400

    # What the `bind` at the bottom actually registered last time this
    # file was sourced, preserved across re-source/.rehash so the old bind
    # is removed by what was really registered.
    variable bound
    if {![info exists bound]} { set bound {} }

    # Can we look at a value's internal representation WITHOUT generating
    # its string form? (Tcl 8.6+, tcl::unsupported::representation.)
    variable have_repr [expr {
        ![catch {::tcl::unsupported::representation x} _r]
        && [string match "*string representation*" $_r]}]
    unset -nocomplain _r

    # No-op target for the temporary identity traces (see alias_map_core).
    proc _mark {args} {}

    # Send one line to the partyline: control characters other than bold
    # (^B) are replaced, the line is length-capped, and a dead idx (user
    # disconnected mid-report) is swallowed instead of erroring out.
    proc say {idx line} {
        variable max_line
        regsub -all {[\u0000-\u0001\u0003-\u001f\u007f-\u009f]} $line {?} line
        if {[string length $line] > $max_line} {
            set line "[string range $line 0 [expr {$max_line - 4}]]..."
        }
        return [expr {![catch {putdcc $idx $line}]}]
    }

    # 1 if any trace in a [trace info variable] result has a read or array
    # op (i.e. touching the variable would fire it), else 0.
    proc ops_hit {infos} {
        foreach t $infos {
            if {[catch {lindex $t 0} ops]} { return 1 }
            if {[lsearch -exact $ops read] >= 0 || [lsearch -exact $ops array] >= 0} {
                return 1
            }
        }
        return 0
    }

    # 1 if this array (or the variable a link points at) has a read/array
    # trace. Checking fires nothing. Unknown => treated as traced.
    proc read_traced {name} {
        if {[catch {trace info variable $name} infos]} { return 1 }
        return [ops_hit $infos]
    }

    # Size and weight of one array, or the list "traced 0 0 0" if it has a read/array
    # trace and force is off (nothing is read in that case, not even
    # [array size]). Returns "ok n bytes unmeasured" otherwise.
    proc measure {arrname force} {
        if {!$force && [read_traced $arrname]} { return [list traced 0 0 0] }
        set n [array size $arrname]
        lassign [bytes_of $arrname $force] b sk
        return [list ok $n $b $sk]
    }

    # Rough byte weight of an array: sum of string length of every key and
    # every value. Not real memory (Tcl_Obj overhead, hash buckets and
    # shimmering all add more), but good enough to rank arrays on the SAME
    # bot. Uses a search iterator so neither a copy of the array nor a
    # list of all its keys is ever built; the search is always closed.
    # Values that have no string form yet are not measured (see header)
    # when that can be detected. Returns a list: bytes, unmeasured count. Errors
    # from reads propagate to the caller (which reports that one array as
    # unreadable).
    proc bytes_of {arrname {force 0}} {
        variable have_repr
        upvar #0 $arrname a
        if {![array exists a]} { return {0 0} }
        set total 0
        set skipped 0
        set sid [array startsearch a]
        set rc [catch {
            while {[array anymore a $sid]} {
                set k [array nextelement a $sid]
                incr total [string length $k]
                # An element with its own read trace: reading it -- or even
                # [info exists] on it -- would fire that trace, so check the
                # trace FIRST and leave the value alone (unless forced). If
                # the check itself fails, assume traced.
                if {!$force && ([catch {trace info variable a($k)} ti]
                        || [ops_hit $ti])} {
                    incr skipped
                    continue
                }
                if {[info exists a($k)]} {
                    set v $a($k)
                    if {$have_repr && [string match {*, no string representation} \
                            [::tcl::unsupported::representation $v]]} {
                        incr skipped
                    } else {
                        incr total [string length $v]
                    }
                }
            }
        } err opts]
        catch { array donesearch a $sid }
        if {$rc} { return -options $opts $err }
        return [list $total $skipped]
    }

    # Map every array name to a canonical name so that two names for the
    # SAME array (link via upvar / namespace upvar, or an exact duplicate)
    # get the same canonical name: the first one in $names. Returns a flat
    # name/canonical list for [array set]. Temporary traces are always
    # removed, even if inspection fails.
    proc alias_map_core {names} {
        set uniq {}
        array set u {}
        foreach n $names {
            if {![info exists u($n)]} { set u($n) 1 ; lappend uniq $n }
        }
        set added {}
        set idname {}
        set i 0
        foreach n $uniq {
            incr i
            set cmd [list ::memdiag::_mark $i]
            if {![catch {trace add variable $n unset $cmd}]} {
                lappend added [list $n $cmd]
                lappend idname $i $n
            }
        }
        array set nameof $idname
        set res {}
        catch {
            foreach n $uniq {
                set best ""
                if {![catch {trace info variable $n} infos]} {
                    foreach t $infos {
                        if {[catch {lindex $t 1} c]} { continue }
                        if {[catch {lindex $c 0} c0] || $c0 ne "::memdiag::_mark"} { continue }
                        set id [lindex $c 1]
                        if {$best eq "" || $id < $best} { set best $id }
                    }
                }
                if {$best ne "" && [info exists nameof($best)]} {
                    lappend res $n $nameof($best)
                } else {
                    lappend res $n $n
                }
            }
        }
        foreach a $added {
            catch { trace remove variable [lindex $a 0] unset [lindex $a 1] }
        }
        # Anything the inspection loop didn't reach maps to itself.
        array set have $res
        foreach n $uniq {
            if {![info exists have($n)]} { lappend res $n $n }
        }
        return $res
    }

    # Does identity detection actually work on this Tcl? Builds a real array
    # and two links to it in a scratch namespace (one via `namespace upvar`,
    # one via `upvar`), asks alias_map_core to canonicalise all three, and
    # deletes the scratch namespace again. 1 = all three resolved to the
    # real array, 0 = not (or the test itself failed).
    proc alias_selftest {} {
        set ok 0
        catch {
            namespace eval ::memdiag::_st {
                variable real
                array set real {k v}
                namespace upvar ::memdiag::_st real lnk1
                upvar #0 ::memdiag::_st::real lnk2
            }
            array set m [alias_map_core {::memdiag::_st::real ::memdiag::_st::lnk1 ::memdiag::_st::lnk2}]
            set ok [expr {$m(::memdiag::_st::lnk1) eq "::memdiag::_st::real"
                && $m(::memdiag::_st::lnk2) eq "::memdiag::_st::real"}]
        }
        catch { namespace delete ::memdiag::_st }
        return $ok
    }

    proc human {n} {
        if {$n >= 1048576} { return "[format %.2f [expr {$n/1048576.0}]]MB" }
        if {$n >= 1024}    { return "[format %.2f [expr {$n/1024.0}]]KB" }
        return "${n}B"
    }

    # Is $name an array, asked without firing anything? Returns 1 (array),
    # 0 (not an array / doesn't exist) or "traced" when the variable has a
    # read/array trace and force is off -- [array exists] would fire an
    # array trace (verified on Tcl 8.6), so such a variable is not probed
    # at all. Only [trace info] (which fires nothing) is used first.
    proc array_kind {name force} {
        if {!$force && [read_traced $name]} {
            if {[catch {info exists $name} ex] || !$ex} { return 0 }
            return traced
        }
        if {[catch {array exists $name} isarr]} { return 0 }
        return [expr {$isarr ? 1 : 0}]
    }

    # Recursively find every array variable under a namespace, including
    # child namespaces (e.g. ::fishing::fishhelp::last lives under the
    # ::fishing root). Returns a flat list of {name kind} pairs, kind being
    # "array" or "traced" (see array_kind). [info vars] and
    # [namespace children] are caught so one variable or namespace with a
    # misbehaving trace costs that entry, not the report.
    proc find_arrays {ns force} {
        set found {}
        if {![namespace exists $ns]} { return $found }
        if {![catch {info vars ${ns}::*} vars]} {
            foreach v $vars {
                switch -- [array_kind $v $force] {
                    1      { lappend found $v array }
                    traced { lappend found $v traced }
                }
            }
        }
        if {[catch {namespace children $ns} kids]} { return $found }
        foreach child $kids {
            foreach {v k} [find_arrays $child $force] { lappend found $v $k }
        }
        return $found
    }

    proc usage {idx} {
        say $idx "Usage: .memdiag | .memdiag force | .memdiag help"
        say $idx "  .memdiag        dump tracked array sizes, timer queues and process RSS."
        say $idx "  .memdiag force  same, but also measure arrays with read/array traces"
        say $idx "                  (normally skipped, since measuring would fire those traces)."
        say $idx "  .memdiag help   show this summary (also: ? -h --help)."
        say $idx "  Any other argument is ignored (and noted). Owner ('n') only."
        say $idx "  Read-only: it changes no state."
    }

    proc cmd_memdiag {hand idx text} {
        variable roots
        variable global_arrays
        variable max_after_listed
        variable max_proc_bytes

        # Defence in depth: the bind flag already restricts this, but the
        # report exposes internals, so don't depend on that line alone.
        if {![matchattr $hand n]} {
            say $idx "Access denied: .memdiag is owner-only."
            return 0
        }

        set arg [string tolower [string trim $text]]
        if {$arg in {help ? -h --help}} {
            usage $idx
            return 1
        }

        variable have_repr

        set force 0
        if {$arg eq "force"} {
            set force 1
            set arg ""
        }
        set alias_ok [alias_selftest]
        array set fp {}
        set grand_traced 0

        set sortable {}
        set grand_elems 0
        set grand_bytes 0
        set grand_skipped 0
        set any_loaded 0

        # Phase 1: discover every candidate array.
        array set rootarr {}
        array set gexists {}
        set allnames {}
        foreach ns $roots {
            set rootarr($ns) {}
            if {[namespace exists "::$ns"]} {
                set rootarr($ns) [find_arrays "::$ns" $force]
                foreach {a k} $rootarr($ns) { lappend allnames $a }
            }
        }
        foreach gname $global_arrays {
            switch -- [array_kind "::$gname" $force] {
                1      { set gexists($gname) array  ; lappend allnames "::$gname" }
                traced { set gexists($gname) traced ; lappend allnames "::$gname" }
            }
        }

        # Phase 2: canonical identity per array (see header), so the same
        # array reached under two names is measured and totalled once.
        array set canon [alias_map_core $allnames]
        array set seen {}

        # Phase 3: measure.
        foreach ns $roots {
            if {![namespace exists "::$ns"]} {
                lappend sortable [list -1 $ns "-" "not loaded"]
                continue
            }
            set any_loaded 1
            if {![llength $rootarr($ns)]} {
                lappend sortable [list -1 $ns "-" "namespace loaded, no arrays"]
                continue
            }
            set fresh 0
            foreach {arrname kind} $rootarr($ns) {
                set key $canon($arrname)
                if {[info exists seen($key)]} { continue }
                set seen($key) 1
                incr fresh
                set label [string trimleft $arrname ":"]
                if {$kind eq "traced"} {
                    incr grand_traced
                    lappend sortable [list -1 $label "-" \
                        "not inspected: has a read/array trace (.memdiag force to measure anyway)"]
                    continue
                }
                if {[catch {measure $arrname $force} m]} {
                    lappend sortable [list -1 $label "-" "unreadable ($m)"]
                    continue
                }
                lassign $m st n b sk
                if {$st eq "traced"} {
                    incr grand_traced
                    lappend sortable [list -1 $label "-" \
                        "not measured: has a read/array trace (.memdiag force to measure anyway)"]
                    continue
                }
                incr grand_elems $n
                incr grand_bytes $b
                incr grand_skipped $sk
                set bh [human $b]
                if {$sk} { append bh " (+$sk unmeasured)" }
                if {!$alias_ok} {
                    set f "$n:$b"
                    if {$n > 0 && [info exists fp($f)]} {
                        append bh " (identical to $fp($f): possible alias)"
                    } else {
                        set fp($f) $label
                    }
                }
                lappend sortable [list $b $label $n $bh]
            }
            if {!$fresh} {
                lappend sortable [list -1 $ns "-" \
                    "already counted under another entry -- remove it from the roots list"]
            }
        }

        # Plain-global arrays (scripts with no namespace of their own).
        foreach gname $global_arrays {
            if {![info exists gexists($gname)]} {
                lappend sortable [list -1 $gname "-" "not loaded"]
                continue
            }
            set any_loaded 1
            set fqname "::$gname"
            set key $canon($fqname)
            if {[info exists seen($key)]} {
                lappend sortable [list -1 $gname "-" \
                    "already counted under another entry -- remove it from global_arrays"]
                continue
            }
            set seen($key) 1
            if {$gexists($gname) eq "traced"} {
                incr grand_traced
                lappend sortable [list -1 $gname "-" \
                    "not inspected: has a read/array trace (.memdiag force to measure anyway)"]
                continue
            }
            if {[catch {measure $fqname $force} m]} {
                lappend sortable [list -1 $gname "-" "unreadable ($m)"]
                continue
            }
            lassign $m st n b sk
            if {$st eq "traced"} {
                incr grand_traced
                lappend sortable [list -1 $gname "-" \
                    "not measured: has a read/array trace (.memdiag force to measure anyway)"]
                continue
            }
            incr grand_elems $n
            incr grand_bytes $b
            incr grand_skipped $sk
            set bh [human $b]
            if {$sk} { append bh " (+$sk unmeasured)" }
            if {!$alias_ok} {
                set f "$n:$b"
                if {$n > 0 && [info exists fp($f)]} {
                    append bh " (identical to $fp($f): possible alias)"
                } else {
                    set fp($f) $gname
                }
            }
            lappend sortable [list $b $gname $n $bh]
        }

        set sortable [lsort -integer -decreasing -index 0 $sortable]

        say $idx "\002--- memdiag: array sizes (largest first) ---\002"
        foreach s $sortable {
            # The raw byte count only drove the sort; it isn't displayed.
            lassign $s _ label n bh
            if {$n eq "-"} {
                say $idx [format "  %-30s  %s" $label $bh]
            } else {
                say $idx [format "  %-30s  %6d elems   ~%s" $label $n $bh]
            }
        }
        if {!$any_loaded} {
            say $idx "  \002NOTE:\002 none of the tracked namespaces are loaded on this bot."
            say $idx "  Check you sourced this script on the right bot/process."
        }
        say $idx "\002--- totals ---\002"
        say $idx "  tracked elements: $grand_elems"
        say $idx "  tracked bytes (est, strings only): [human $grand_bytes]"
        if {$grand_skipped} {
            say $idx "  values not measured (no string form yet, or own read trace): $grand_skipped"
        }
        if {$grand_traced} {
            say $idx "  variables not measured (read/array trace): $grand_traced -- bytes are a lower bound"
        }
        if {!$alias_ok} {
            say $idx "  \002WARNING:\002 alias-detection self-test FAILED on this Tcl. Arrays linked"
            say $idx "  with upvar may be counted twice; lines marked 'possible alias' are"
            say $idx "  suspects only and are still included in the totals."
        }
        if {!$have_repr} {
            say $idx "  note: no tcl::unsupported::representation here, so measuring may have"
            say $idx "  given list/number values a string form (one-time extra memory)."
        }

        # Timer queues -- a leaked/duplicated timer chain (the bug several
        # scripts have comments about guarding against) shows up here as a
        # suspiciously large or ever-growing count.
        set ut 0 ; set tm 0 ; set af {}
        catch { set ut [llength [utimers]] }
        catch { set tm [llength [timers]] }
        catch { set af [after info] }
        set afn [llength $af]
        say $idx "\002--- timer/event queues ---\002"
        say $idx "  utimers pending: $ut"
        say $idx "  timers pending:  $tm"
        say $idx "  \[after info\] pending (Tcl-level periodic sweeps): $afn"
        if {$afn > 5} {
            say $idx "  \002NOTE:\002 more than a handful of \[after\] events is unusual --"
            say $idx "  this is the rehash-stacking failure mode multiple scripts"
            say $idx "  guard against. Listing them:"
            set shown 0
            foreach id $af {
                if {$shown >= $max_after_listed} {
                    say $idx "    ... [expr {$afn - $shown}] more not listed."
                    break
                }
                catch { say $idx "    $id -> [string range [after info $id] 0 199]" }
                incr shown
            }
        }

        # Real allocator info, if this Tcl build supports it (most eggdrop
        # builds don't -- that's fine, we just say so).
        say $idx "\002--- Tcl memory info ---\002"
        if {[catch {memory info} meminfo]} {
            say $idx "  unavailable (Tcl not built with --enable-symbols=mem)"
        } else {
            foreach line [split $meminfo "\n"] {
                if {[string trim $line] ne ""} { say $idx "  $line" }
            }
        }

        say $idx "\002--- process RSS (from /proc, if readable) ---\002"
        # Open and read are caught separately so the channel is closed on
        # every path once open succeeds, even if read fails partway.
        if {[catch {open "/proc/self/status" r} f]} {
            say $idx "  unavailable ($f)"
        } else {
            if {[catch {read $f $max_proc_bytes} data]} {
                say $idx "  unavailable ($data)"
            } else {
                foreach line [split $data "\n"] {
                    if {[string match "VmRSS:*" $line] || [string match "VmHWM:*" $line]} {
                        say $idx "  [string trim $line]"
                    }
                }
            }
            catch { close $f }
        }

        if {$arg ne ""} {
            say $idx "(.memdiag takes no arguments -- \"[string range $text 0 39]\" ignored; see .memdiag help.)"
        }
        return 1
    }
}

# Unbind what was actually registered last time (see memdiag::bound), then
# record the new registration. Unbinding the literal values below would
# silently stop matching the moment either is edited.
foreach _md_b $memdiag::bound {
    catch { unbind [lindex $_md_b 0] [lindex $_md_b 1] [lindex $_md_b 2] [lindex $_md_b 3] }
}
set memdiag::bound {}

if {[catch {bind dcc n memdiag memdiag::cmd_memdiag} _md_err]} {
    putlog "mem.tcl: failed to bind .memdiag: $_md_err"
} else {
    lappend memdiag::bound [list dcc n memdiag memdiag::cmd_memdiag]
    putlog "mem.tcl loaded -- .memdiag from the partyline (owner-only, 'n' flag) to dump array/timer sizes."
}
unset -nocomplain _md_b _md_err
