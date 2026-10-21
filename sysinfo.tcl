# sysinfo.tcl - Eggdrop System Information
# Public command: !sysinfo
# Partyline/DCC command: .sysinfo
#
# Default:
#   - Public command requires Eggdrop +o flag (require_flag)
#   - Public command answers in every channel the bot is on (channels {});
#     set channels to a list of channels to restrict it to just those
#   - Partyline .sysinfo is available to ANY partyline account by default
#     (dcc_flag ""); set dcc_flag to tighten it -- see the note there
#   - 3 public uses per 60 seconds per nick!host
#   - Aggregate network RX/TX only
#   - No IP addresses, MAC addresses, interface names, or hostnames shown
#
# WHAT IT DISCLOSES: distro and kernel version, CPU/GPU model, core count,
# RAM/swap/disk sizing and usage, load, and system uptime. No addresses or
# names, but it is still a description of the host the bot runs on -- which
# is the inventory someone would use to pick a local privilege-escalation
# exploit. That is why the public command is flag-gated by default, and
# why dcc_flag is worth setting on a bot with partyline accounts that
# exist for unrelated reasons.
#
# Install:
#   source scripts/sysinfo.tcl
# Then:
#   .rehash

namespace eval ::sysinfo {
    # Config knobs use plain `set`, so every .rehash applies the edited
    # value. Runtime state that must survive a rehash (flood_db, bound,
    # the static-info cache) is declared with a bare `variable` plus an
    # existence guard instead.
    set public_enabled 1
    set use_color 1

    # Flag required for the PUBLIC !sysinfo command. "" = anyone.
    set require_flag "o"

    # Flag required for the PARTYLINE .sysinfo command.
    #
    # "" (the default) keeps the original behaviour: any partyline account
    # can run it. That asymmetry is worth knowing about rather than
    # stumbling on -- the public command is +o-gated because this report
    # describes the machine the bot runs on (distro and kernel version,
    # CPU, GPU, disk and memory sizing, uptime), which is exactly the
    # inventory someone picks a local privilege-escalation exploit from,
    # while the same report has always been one word away for ANY
    # partyline user, including a +p-only account added for something
    # unrelated. Set this to a flag ("o", "m", "n") to tighten it.
    #
    # Note on choosing one: Eggdrop flags are not hierarchical, so "o"
    # does NOT automatically include an owner who only holds +n. Use
    # "on" (or "mn") if you want both to qualify.
    set dcc_flag ""

    # Which channels the PUBLIC !sysinfo command answers in. Empty list {}
    # (the default) = every channel the bot is on. Non-empty = only those
    # channels, exact match, case-insensitive. Does not affect the
    # partyline .sysinfo command, which has no channel of its own.
    # Validated below: trimmed, must start with #/&/+/!, 2-64 chars, no
    # whitespace/commas/control bytes, capped at 64 entries.
    set channels {}

    set flood_pub 3
    set flood_time 60
    set deny_notice 1
    variable flood_db

    # Max BYTES per line handed to chunk_report.
    #
    # An IRC line is capped at 512 bytes INCLUDING the
    # ":nick!user@host PRIVMSG #chan :" prefix the server prepends and the
    # trailing CRLF -- that prefix is commonly 50-70 bytes, so 500 put
    # every full line past the limit and the server truncated it, which is
    # the exact failure chunk_report was written to prevent. It was
    # lowered to 400 for that reason.
    #
    # Raised to 430. At 400 the full report on a typical box measured 399
    # bytes -- one byte of margin -- so it landed on a single line only
    # until the uptime string grew a digit ("7h 9m 15s" -> "17h 9m 15s"),
    # at which point the last field wrapped to a second line and back
    # again an hour later. 430 leaves ~80 bytes for the prefix and CRLF,
    # which covers a normal nick!user@host and channel name, and gives the
    # report real headroom to stay on one line instead of flapping.
    #
    # This is still not a promise of one line: a long CPU or GPU model
    # string can push the report past 430 on its own, and when it does
    # chunk_report will split it rather than hand the server something to
    # truncate. That is the protocol's limit doing its job. Do not raise
    # this past 450 (the validated ceiling below) chasing a single line --
    # past that the server starts cutting fields off mid-word.
    set max_line_len 430

    # Preserved across a .rehash: `array set x {}` on an existing array is
    # a merge, i.e. already a no-op, but stating the guard makes that
    # deliberate rather than incidental -- rebuilding this table on every
    # rehash would hand everyone a fresh flood allowance, and .rehash is
    # reachable from the partyline.
    if {![array exists flood_db]} { array set flood_db {} }

    proc clean {value {maxlen 180}} {
        # Strip EVERY control character, not just the three whitespace
        # ones this mapped. Everything that reaches here is text from the
        # local machine -- /etc/os-release, /proc/cpuinfo model strings,
        # lspci and nvidia-smi output -- and it is interpolated straight
        # into a "PRIVMSG #chan :" line handed to putserv. CR and LF were
        # handled (those forge a second IRC command), but \x01 was not,
        # and a device or distro string carrying one turns the bot's
        # report into a CTCP that clients render as something else
        # entirely; \x03 paints colour. None of these strings has any
        # legitimate reason to contain a control byte, and a field is not
        # worth trusting just because it came off the local disk.
        regsub -all {[[:cntrl:]]} $value " " value
        regsub -all {\s+} $value " " value
        set value [string trim $value]
        if {[string length $value] > $maxlen} {
            set value [string range $value 0 [expr {$maxlen - 3}]]
            append value "..."
        }
        return $value
    }

    proc exec_safe {args} {
        # -ignorestderr: Tcl's [exec] raises if the child writes ANYTHING
        # to stderr, even when it exits 0 and produced perfectly good
        # output on stdout. lspci and nvidia-smi both warn routinely (no
        # permission for some device, driver/library version mismatch),
        # so "GPU: N/A" on a machine with a working GPU was usually this,
        # not a missing tool. Non-zero exits are still caught below.
        # (A second attempt without -ignorestderr used to follow a failure
        # here; it is strictly less permissive, so it could never succeed
        # where this one failed.)
        if {[catch {set output [exec -ignorestderr {*}$args]}]} {
            return ""
        }
        return [clean $output 400]
    }

    proc read_file {filename} {
        if {![file readable $filename]} {
            return ""
        }
        set fp ""
        if {[catch {
            set fp [open $filename r]
            fconfigure $fp -translation lf
            # Bounded. Every path this is called with is a small /proc or
            # /etc file, but an unbounded [read] on a path that turns out
            # to be something else (a symlink an operator repointed, a
            # /proc file that grows on a busy box) is an easy thing not to
            # leave lying around. 1 MB is orders of magnitude past any of
            # these files.
            set data [read $fp 1048576]
            close $fp
        }]} {
            catch {close $fp}
            return ""
        }
        return $data
    }

    # get_ram/get_swap both call ::sysinfo::safe_int to coerce the
    # already-regex-matched MemTotal/MemAvailable/MemFree/SwapTotal/
    # SwapFree values before subtracting -- but this proc did not exist
    # anywhere in the file. Every call to it raised "invalid command
    # name", uncaught, inside get_ram (and inside get_swap whenever swap
    # is actually configured) -- which build_report calls unconditionally
    # on every single !sysinfo/.sysinfo invocation. On any host with a
    # normal /proc/meminfo (i.e. virtually all of them), that meant the
    # error fired before build_report ever reached chunk_report/
    # send_lines, so BOTH commands were completely broken: no output, no
    # error visible on IRC/partyline, nothing but a Tcl error in the log.
    # Defined here to actually do what its name and call sites imply: a
    # defensive integer coercion that returns 0 for anything that isn't
    # one, rather than raising and taking the whole report down with it.
    proc safe_int {value} {
        if {![string is wideinteger -strict $value]} {
            return 0
        }
        return [expr {wide($value)}]
    }

    proc bytes {value} {
        if {![string is wideinteger -strict $value]} {
            return "N/A"
        }
        set value [expr {wide($value)}]
        if {$value < 1024} {
            return "$value B"
        }
        if {$value < 1048576} {
            return [format "%.2f KB" [expr {$value / 1024.0}]]
        }
        if {$value < 1073741824} {
            return [format "%.2f MB" [expr {$value / 1048576.0}]]
        }
        if {$value < 1099511627776} {
            return [format "%.2f GB" [expr {$value / 1073741824.0}]]
        }
        return [format "%.2f TB" [expr {$value / 1099511627776.0}]]
    }

    proc duration {seconds} {
        if {![string is integer -strict $seconds] || $seconds < 0} {
            return "N/A"
        }
        set days [expr {$seconds / 86400}]
        set hours [expr {($seconds % 86400) / 3600}]
        set mins [expr {($seconds % 3600) / 60}]
        set secs [expr {$seconds % 60}]
        if {$days > 0} {
            return "${days}d ${hours}h ${mins}m ${secs}s"
        }
        if {$hours > 0} {
            return "${hours}h ${mins}m ${secs}s"
        }
        if {$mins > 0} {
            return "${mins}m ${secs}s"
        }
        return "${secs}s"
    }

    proc os_release {field} {
        set data [read_file "/etc/os-release"]
        if {$data eq ""} {
            return ""
        }
        foreach line [split $data "\n"] {
            if {[regexp "^${field}=(.*)$" $line -> value]} {
                return [clean [string trim $value "\"'"] 120]
            }
        }
        return ""
    }

    proc get_os {} {
        set value [os_release "PRETTY_NAME"]
        if {$value ne ""} {
            return $value
        }
        set value [exec_safe uname -s]
        if {$value eq ""} {
            return "N/A"
        }
        return $value
    }

    proc get_kernel {} {
        set value [exec_safe uname -r]
        if {$value eq ""} { return "N/A" }
        return $value
    }

    proc get_arch {} {
        set value [exec_safe uname -m]
        if {$value eq ""} { return "N/A" }
        return $value
    }

    proc get_cpu_model {} {
        set data [read_file "/proc/cpuinfo"]
        if {$data ne ""} {
            foreach line [split $data "\n"] {
                if {[regexp {^model name\s*:\s*(.+)$} $line -> model]} {
                    return [clean $model 150]
                }
                if {[regexp {^Hardware\s*:\s*(.+)$} $line -> model]} {
                    return [clean $model 150]
                }
            }
        }
        set value [exec_safe sysctl -n hw.model]
        if {$value ne ""} {
            return $value
        }
        return "N/A"
    }

    proc get_cpu_cores {} {
        set data [read_file "/proc/cpuinfo"]
        if {$data ne ""} {
            set count 0
            foreach line [split $data "\n"] {
                if {[regexp {^processor\s*:} $line]} {
                    incr count
                }
            }
            if {$count > 0} {
                return $count
            }
        }
        set value [exec_safe nproc]
        if {$value ne "" && [string is integer -strict $value]} {
            return $value
        }
        return "N/A"
    }

    proc get_load {} {
        set data [read_file "/proc/loadavg"]
        if {$data ne ""} {
            set fields [split [string trim $data]]
            if {[llength $fields] >= 3} {
                return "[lindex $fields 0] / [lindex $fields 1] / [lindex $fields 2]"
            }
        }
        return "N/A"
    }

    proc get_ram {} {
        set data [read_file "/proc/meminfo"]
        if {$data eq ""} {
            return [list "N/A" "N/A" "N/A" "N/A"]
        }

        set total 0
        set available 0
        set free 0

        foreach line [split $data "\n"] {
            if {[regexp {^MemTotal:\s+([0-9]+)} $line -> value]} {
                set total [expr {$value * 1024}]
            } elseif {[regexp {^MemAvailable:\s+([0-9]+)} $line -> value]} {
                set available [expr {$value * 1024}]
            } elseif {[regexp {^MemFree:\s+([0-9]+)} $line -> value]} {
                set free [expr {$value * 1024}]
            }
        }

        if {$total <= 0} {
            return [list "N/A" "N/A" "N/A" "N/A"]
        }
        if {$available <= 0} {
            set available $free
        }

        set used [expr {[::sysinfo::safe_int $total] - [::sysinfo::safe_int $available]}]
        if {$used < 0} { set used 0 }

        set percent [expr {(double($used) / double($total)) * 100.0}]

        return [list \
            [bytes $total] \
            [bytes $used] \
            [bytes $available] \
            [format "%.1f%%" $percent]]
    }

    proc get_swap {} {
        set data [read_file "/proc/meminfo"]
        if {$data eq ""} {
            return [list "N/A" "N/A"]
        }

        set total 0
        set free 0

        foreach line [split $data "\n"] {
            if {[regexp {^SwapTotal:\s+([0-9]+)} $line -> value]} {
                set total [expr {$value * 1024}]
            } elseif {[regexp {^SwapFree:\s+([0-9]+)} $line -> value]} {
                set free [expr {$value * 1024}]
            }
        }

        if {$total <= 0} {
            return [list "0 B" "0 B"]
        }

        set used [expr {[::sysinfo::safe_int $total] - [::sysinfo::safe_int $free]}]
        if {$used < 0} { set used 0 }

        return [list [bytes $total] [bytes $used]]
    }

    proc get_gpu {} {
        set value [exec_safe nvidia-smi --query-gpu=name --format=csv,noheader]
        if {$value ne ""} {
            return [clean $value 150]
        }

        set pci [exec_safe lspci]
        if {$pci ne ""} {
            foreach line [split $pci "\n"] {
                if {[regexp -nocase {(vga compatible controller|3d controller|display controller):\s*(.+)$} $line -> type model]} {
                    return [clean $model 150]
                }
            }
        }

        return "N/A"
    }

    proc get_disk {} {
        # Same reasoning as exec_safe's -ignorestderr, applied here too:
        # [exec] raises if the child writes ANYTHING to stderr even on a
        # clean exit -- a df warning (a stale/unreachable mount other than
        # ".", an autofs probe, a quota-support notice on some systems) was
        # enough to turn "Disk: N/A" into the whole-report failure mode
        # this proc didn't otherwise have, on a box where df's actual
        # answer for "." was fine. This didn't go through exec_safe
        # because it needs the raw $df output rather than exec_safe's
        # clean()-and-truncate return value, so the same dual-attempt is
        # inlined here instead.
        if {[catch {set df [exec -ignorestderr df -Pk .]}]} {
            return [list "N/A" "N/A" "N/A"]
        }

        set lines [split $df "\n"]
        if {[llength $lines] < 2} {
            return [list "N/A" "N/A" "N/A"]
        }

        # df wraps onto a second line when the filesystem/device name is
        # too long for the column, putting just the name on its own line
        # and the numeric fields on the next -- so [lindex $lines end]
        # alone can be name-only and silently fail to match. Join
        # everything after the header into one string instead; there's
        # only ever one data row for a single path, so this is safe
        # whether or not df wrapped it.
        set body [join [lrange $lines 1 end] " "]

        if {![regexp {([0-9]+)\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)%\s+\S+\s*$} $body -> total used avail percent]} {
            return [list "N/A" "N/A" "N/A"]
        }

        return [list \
            [bytes [expr {$total * 1024}]] \
            [bytes [expr {$used * 1024}]] \
            "${percent}%"]
    }

    proc get_de {} {
        # Desktop environment / GUI detection. Most of these bots run
        # headless, so "N/A" is the expected common case, not a bug.
        #
        # XDG_CURRENT_DESKTOP is the standard signal, but it only exists in
        # the environment of a process launched from inside the graphical
        # session. An eggdrop typically runs from a system service or a
        # plain login shell with no such environment, so this falls back
        # to scanning /proc for a known DE/WM process -- the same
        # "evidence on the box beats an env var that may never be set
        # here" approach used for GPU detection above.
        global env
        if {[info exists env(XDG_CURRENT_DESKTOP)] && $env(XDG_CURRENT_DESKTOP) ne ""} {
            return [clean $env(XDG_CURRENT_DESKTOP) 60]
        }
        if {[info exists env(DESKTOP_SESSION)] && $env(DESKTOP_SESSION) ne ""} {
            return [clean $env(DESKTOP_SESSION) 60]
        }

        # Fallback: scan running processes for a known DE/WM session or
        # compositor binary, matched against /proc/<pid>/comm. No X/Wayland
        # session access or extra tools required.
        set candidates {
            {plasmashell     KDE Plasma}
            {kwin_x11        KDE Plasma}
            {kwin_wayland    KDE Plasma}
            {gnome-shell     GNOME}
            {cinnamon        Cinnamon}
            {mate-session    MATE}
            {xfce4-session   XFCE}
            {lxsession       LXDE}
            {lxqt-session    LXQt}
            {cosmic-session  COSMIC}
            {cosmic-comp     COSMIC}
            {budgie-wm       Budgie}
            {deepin-session  Deepin}
            {sway            Sway}
            {hyprland        Hyprland}
            {i3              i3}
            {enlightenment   Enlightenment}
        }

        if {[catch {set pids [glob -nocomplain /proc/\[0-9\]*]}]} {
            return "N/A"
        }

        foreach pdir $pids {
            set comm_file [file join $pdir "comm"]
            if {![file readable $comm_file]} {
                continue
            }
            set comm [string trim [read_file $comm_file]]
            if {$comm eq ""} {
                continue
            }
            foreach pair $candidates {
                set proc_name [lindex $pair 0]
                set label [lindex $pair 1]
                if {[string match -nocase "${proc_name}*" $comm]} {
                    return $label
                }
            }
        }

        return "N/A"
    }

    proc get_system_uptime {} {
        set data [read_file "/proc/uptime"]
        if {$data ne ""} {
            set seconds [lindex [split [string trim $data]] 0]
            if {[string is double -strict $seconds]} {
                return [duration [expr {int($seconds)}]]
            }
        }
        return "N/A"
    }

    proc get_network {} {
        set data [read_file "/proc/net/dev"]
        if {$data eq ""} {
            return [list "N/A" "N/A"]
        }

        set rx 0
        set tx 0

        foreach line [split $data "\n"] {
            if {![regexp {^\s*([^:]+):\s*(.+)$} $line -> iface values]} {
                continue
            }

            set iface [string trim $iface]

            # Do not expose or report loopback traffic.
            if {$iface eq "lo"} {
                continue
            }

            set fields [split [string trim $values]]

            if {[llength $fields] < 9} {
                continue
            }

            set in_bytes [lindex $fields 0]
            set out_bytes [lindex $fields 8]

            if {[string is wideinteger -strict $in_bytes]} {
                incr rx $in_bytes
            }
            if {[string is wideinteger -strict $out_bytes]} {
                incr tx $out_bytes
            }
        }

        return [list [bytes $rx] [bytes $tx]]
    }

    # OS, kernel, arch, CPU, core count, GPU and desktop don't change while
    # the bot runs, but they cost the most: uname three times, nvidia-smi
    # and lspci (each can take seconds on a box with a wedged driver), and
    # one open per process in /proc for the desktop scan. All of it runs
    # synchronously in the bot's single event loop, so every !sysinfo
    # froze the whole bot for that long. Cached for static_ttl seconds.
    variable static_cache
    if {![info exists static_cache]} { set static_cache {} }
    set static_ttl 3600

    proc static_info {} {
        variable static_cache
        variable static_ttl
        set now [clock seconds]
        if {[dict exists $static_cache at] && $now - [dict get $static_cache at] < $static_ttl} {
            return $static_cache
        }
        set static_cache [dict create at $now os [get_os] kernel [get_kernel] \
            arch [get_arch] cpu [get_cpu_model] cores [get_cpu_cores] \
            gpu [get_gpu] de [get_de]]
        return $static_cache
    }

    proc build_report {} {
        variable use_color

        set bold ""
        set normal ""

        if {$use_color} {
            set bold "\002"
            set normal "\002"
        }

        set ram [get_ram]
        set swap [get_swap]
        set disk [get_disk]
        set net [get_network]

        set fields {}

        set st [static_info]
        lappend fields "OS: [dict get $st os]"
        lappend fields "Kernel: [dict get $st kernel]"
        lappend fields "Arch: [dict get $st arch]"
        lappend fields "CPU: [dict get $st cpu]"
        lappend fields "CPU Cores: [dict get $st cores]"
        lappend fields "Load: [get_load]"
        lappend fields "RAM: [lindex $ram 1] / [lindex $ram 0] ([lindex $ram 3])"
        lappend fields "RAM Available: [lindex $ram 2]"
        lappend fields "Swap: [lindex $swap 1] / [lindex $swap 0]"
        lappend fields "GPU: [dict get $st gpu]"
        lappend fields "GUI/DE: [dict get $st de]"
        lappend fields "Disk: [lindex $disk 1] / [lindex $disk 0] ([lindex $disk 2])"
        lappend fields "Uptime: [get_system_uptime]"
        lappend fields "Download (RX): [lindex $net 0]"
        lappend fields "Upload (TX): [lindex $net 1]"

        return [list "${bold}System Info${normal}:" $fields]
    }

    # IRC PRIVMSG lines are capped around 512 bytes including the
    # ":nick!user@host PRIVMSG #chan :" prefix the server prepends --
    # packing all ~17 fields into one line (as build_report used to
    # return directly) silently overflowed that limit and got truncated
    # mid-message by the server, dropping whatever came after. This
    # packs fields into as few lines as will fit, each well under the
    # limit, keeping the "|"-joined look without truncation risk.
    # Length as the server counts it: BYTES on the wire, not characters.
    # maxlen is documented in bytes and IRC's limit is in bytes, but this
    # measured characters -- and a non-ASCII distro name, CPU model or GPU
    # string (they exist: a trademark sign, a dash, a CJK vendor name) is
    # 2-4 bytes per character, so a line this counted as 390 could be well
    # past 512 and get truncated. Same failure the chunking exists to stop.
    proc wire_len {s} {
        if {[catch {string length [encoding convertto utf-8 $s]} n]} {
            return [string length $s]
        }
        return $n
    }

    proc chunk_report {fields prefix maxlen} {
        set lines {}
        set current ""
        set is_first_line 1

        foreach field $fields {
            if {$current eq ""} {
                if {$is_first_line} {
                    set current "$prefix | $field |"
                } else {
                    set current "| $field |"
                }
                # A single field that cannot fit on a line of its own was
                # emitted over-length and truncated by the server. clean()
                # caps each field well below maxlen today, so this is a
                # guard rather than a live bug -- but it is the one case
                # the packing loop below can never rescue, because there
                # is nothing to pack it with.
                if {[wire_len $current] > $maxlen} {
                    lappend lines $current
                    set is_first_line 0
                    set current ""
                }
                continue
            }

            set candidate "$current $field |"

            if {[wire_len $candidate] > $maxlen} {
                lappend lines $current
                set is_first_line 0
                set current "| $field |"
            } else {
                set current $candidate
            }
        }

        if {$current ne ""} {
            lappend lines $current
        }

        return $lines
    }

    # Which channels the PUBLIC command is scoped to. Empty = every channel
    # the bot is on; non-empty = exact, case-insensitive match against
    # $channels. Checked first in pub_sysinfo, ahead of the flag/flood
    # checks, and fails silently (no deny_notice) -- a channel that isn't
    # in scope should behave as if the command doesn't exist there at all,
    # the same posture !sysinfo already takes for anyone lacking the flag
    # in an in-scope channel vs. one it just never answers in.
    proc channel_allowed {chan} {
        variable channels
        if {[llength $channels] == 0} { return 1 }
        foreach c $channels {
            if {[string equal -nocase $c $chan]} { return 1 }
        }
        return 0
    }

    proc allowed {hand chan} {
        variable require_flag

        if {$require_flag eq ""} {
            return 1
        }

        if {[catch {set global_ok [matchattr $hand $require_flag]}]} {
            set global_ok 0
        }

        if {$global_ok} {
            return 1
        }

        if {$chan ne "" && $chan ne "*"} {
            # "|flag": a bare flag string is checked against GLOBAL flags
            # even when a channel is passed, so a channel-only +o never
            # qualified here.
            if {[catch {set chan_ok [matchattr $hand "|$require_flag" $chan]}]} {
                set chan_ok 0
            }

            if {$chan_ok} {
                return 1
            }
        }

        return 0
    }

    proc flood_allowed {nick host} {
        variable flood_db
        variable flood_pub
        variable flood_time

        set now [clock seconds]
        set key [string tolower "${nick}!${host}"]

        if {![info exists flood_db($key)]} {
            set flood_db($key) {}
        }

        set recent {}

        foreach timestamp $flood_db($key) {
            if {($now - $timestamp) < $flood_time} {
                lappend recent $timestamp
            }
        }

        if {[llength $recent] >= $flood_pub} {
            set flood_db($key) $recent
            return 0
        }

        lappend recent $now
        set flood_db($key) $recent

        return 1
    }

    # Sending several PRIVMSG/DCC lines back-to-back in the same event
    # loop tick can trip the IRC server's own flood protection (or, on
    # some networks, a services flood-kick) -- the first line lands and
    # the rest get silently dropped or delayed, which looked like
    # "it doesn't print all" even though chunk_report built every line
    # correctly. Spacing sends out with a 1s delay per line keeps well
    # under any reasonable flood threshold. sender is a command prefix
    # (e.g. a lambda closing over $chan or $idx) that puts one line out.
    proc send_lines {lines sender} {
        if {[llength $lines] == 0} { return }
        set line [lindex $lines 0]
        set rest [lrange $lines 1 end]
        uplevel #0 [linsert $sender end $line]
        if {[llength $rest] > 0} {
            after 1000 [list ::sysinfo::send_lines $rest $sender]
        }
    }

    proc pub_sysinfo {nick uhost hand chan arg} {
        variable public_enabled
        variable deny_notice

        if {!$public_enabled} {
            return
        }

        # Channel scope checked first and silently -- a channel outside
        # $channels should look like the bot has no !sysinfo command at
        # all there, not like a permission wall (which is why this, unlike
        # the flag/flood checks below, never sends a deny_notice).
        if {![channel_allowed $chan]} {
            return
        }

        # Permission is checked before consuming a flood slot.
        #
        # The notice here is deliberately generic: "you don't have
        # permission to use !sysinfo" confirms to anyone that the
        # command exists and (once they notice repeated identical
        # replies) that it's flag-gated, letting an unprivileged user
        # enumerate which commands are present on the bot just by
        # trying them. Staying silent isn't an option either without
        # dropping deny_notice's purpose, so this says just enough to
        # explain the non-response without naming the command.
        if {![allowed $hand $chan]} {
            # Throttled like the command itself: anyone at all can trigger
            # this one, so an unthrottled notice per !sysinfo was a way to
            # fill the bot's help queue from the channel.
            if {$deny_notice && [flood_allowed "deny:$nick" $uhost]} {
                puthelp "NOTICE $nick :You do not have permission to use that command."
            }
            return
        }

        if {![flood_allowed $nick $uhost]} {
            if {$deny_notice} {
                puthelp "NOTICE $nick :!sysinfo flood limit exceeded. Please wait."
            }
            return
        }

        variable max_line_len
        lassign [build_report] prefix fields
        set lines [chunk_report $fields $prefix $max_line_len]
        send_lines $lines [list ::sysinfo::say_pub $chan]
    }

    proc say_pub {chan line} {
        putserv "PRIVMSG $chan :$line"
    }

    proc dcc_sysinfo {hand idx arg} {
        variable max_line_len
        lassign [build_report] prefix fields
        set lines [chunk_report $fields $prefix $max_line_len]
        send_lines $lines [list ::sysinfo::say_dcc $idx $hand]
    }

    # Lines after the first go out from an `after` callback a second or
    # more later. If the user has left by then, the idx is invalid (putdcc
    # errored from the event loop) -- or Eggdrop has already handed the same
    # idx to a NEW connection, which would then be sent this host report.
    # Only deliver while the idx still belongs to the handle that asked.
    proc say_dcc {idx hand line} {
        if {[catch {valididx $idx} ok] || !$ok} { return }
        if {[catch {idx2hand $idx} h] || ![string equal -nocase $h $hand]} { return }
        putdcc $idx $line
    }

    proc cleanup_flood {} {
        variable flood_db
        variable flood_time

        set now [clock seconds]

        foreach key [array names flood_db] {
            set recent {}

            foreach timestamp $flood_db($key) {
                if {($now - $timestamp) < $flood_time} {
                    lappend recent $timestamp
                }
            }

            if {[llength $recent] == 0} {
                unset flood_db($key)
            } else {
                set flood_db($key) $recent
            }
        }

        ::sysinfo::schedule_cleanup
    }

    # Schedules (or re-schedules) the flood-table sweep, first killing any
    # copy of this same event that's already pending. Without this, a
    # rehash -- which re-sources this file without resetting the Tcl
    # interpreter -- would stack a brand new self-perpetuating `after`
    # chain on top of whichever one(s) are already running from earlier
    # rehashes: the same bug already found and fixed for mhelp::cleanup in
    # masterhelp.tcl and whocom::cleanup_ratelimit in whocom.tcl. `after`
    # has no "kill by proc name" primitive like eggdrop's
    # utimers/killutimer, so we walk [after info] and cancel any pending
    # event whose script matches this proc.
    proc schedule_cleanup {} {
        foreach id [after info] {
            if {[lindex [after info $id] 0] eq "::sysinfo::cleanup_flood"} {
                catch { after cancel $id }
            }
        }
        catch { after 60000 ::sysinfo::cleanup_flood }
    }

    ##########################################################################
    # Config validation.
    #
    # None of these were checked. flood_pub or flood_time non-integer makes
    # flood_allowed raise on the first public use -- inside the bind, so
    # the command simply stops working with a Tcl error in the log; a
    # max_line_len of 0 or a string makes chunk_report emit one line per
    # field forever, or raise. All of it is reachable by anyone who can
    # type in the channel, so none of it should depend on the config being
    # typo-free.
    ##########################################################################
    proc _cfg_int {name min max default} {
        upvar #0 ::sysinfo::$name v
        if {![info exists v] || ![string is integer -strict $v] || $v < $min
                || ($max ne "" && $v > $max)} {
            set had [expr {[info exists v] ? $v : "<unset>"}]
            putlog "sysinfo: CONFIG: invalid $name ('$had'); forcing $default."
            set v $default
        }
    }

    ::sysinfo::_cfg_int flood_pub     1 10000 3
    ::sysinfo::_cfg_int flood_time    1 86400 60
    # Floor of 120: below that the prefix plus a single field can exceed
    # the line and chunking stops meaning anything. Ceiling of 450 keeps
    # room for the server's own prefix inside 512.
    ::sysinfo::_cfg_int max_line_len 120 450  430

    foreach _b {public_enabled use_color deny_notice} {
        if {[set ::sysinfo::$_b] ni {0 1}} {
            putlog "sysinfo: CONFIG: $_b must be 0 or 1; forcing 1."
            set ::sysinfo::$_b 1
        }
    }
    unset -nocomplain _b
    foreach _f {require_flag dcc_flag} {
        if {[regexp {[^a-zA-Z]} [set ::sysinfo::$_f]]} {
            putlog "sysinfo: CONFIG: $_f ('[set ::sysinfo::$_f]') is not a plain flag string; forcing \"\" (no flag required)."
            set ::sysinfo::$_f ""
        }
    }
    unset -nocomplain _f

    # channels: trim each entry, drop anything malformed rather than let a
    # typo (a name with no #, a pasted comma, a trailing space) sit in the
    # list matching nothing forever with no indication why !sysinfo went
    # quiet in that channel.
    set _clean {}
    foreach _c $channels {
        set _c [string trim $_c]
        if {[string length $_c] < 2 || [string length $_c] > 64
                || ![regexp {^[#&+!]} $_c]
                || [regexp {[\s,\x00-\x1f]} $_c]} {
            putlog "sysinfo: CONFIG: dropping malformed channels entry '$_c'."
            continue
        }
        lappend _clean $_c
        if {[llength $_clean] >= 64} { break }
    }
    set channels $_clean
    unset -nocomplain _c _clean

    ##########################################################################
    # Binds.
    #
    # Tracked and unbound by what was ACTUALLY registered, so changing
    # dcc_flag (or a trigger) and rehashing replaces the old registration
    # instead of leaving it live beside the new one -- a literal
    # "unbind dcc - sysinfo" stops matching the moment that flag is no
    # longer "-", which would leave the OLD, laxer bind answering forever
    # while the operator believes they just tightened it.
    ##########################################################################
    variable bound
    if {![info exists bound]} { set bound {} }
    foreach _b $bound {
        catch { unbind [lindex $_b 0] [lindex $_b 1] [lindex $_b 2] [lindex $_b 3] }
    }
    set bound {}
    # Clear the literal registrations an earlier revision of this file made.
    catch { unbind pub - !sysinfo ::sysinfo::pub_sysinfo }
    catch { unbind dcc - sysinfo ::sysinfo::dcc_sysinfo }

    set _dccflag [expr {$dcc_flag eq "" ? "-" : $dcc_flag}]
    foreach _b [list \
            [list pub - !sysinfo ::sysinfo::pub_sysinfo] \
            [list dcc $_dccflag sysinfo ::sysinfo::dcc_sysinfo]] {
        if {[catch { bind [lindex $_b 0] [lindex $_b 1] [lindex $_b 2] [lindex $_b 3] } _err]} {
            putlog "sysinfo: failed to bind [lindex $_b 0] [lindex $_b 2]: $_err"
        } else {
            lappend bound $_b
        }
    }
    unset -nocomplain _b _err _dccflag

    ::sysinfo::schedule_cleanup

    # Banner built from the live config instead of a hardcoded sentence.
    # It claimed "!sysinfo requires +o" unconditionally, so an operator who
    # was told on every load that it was still gated.
    if {[llength $channels] == 0} {
        set _scope "every channel the bot is on"
    } else {
        set _scope "[join $channels {, }]"
    }
    putlog "sysinfo: loaded - !sysinfo [expr {$require_flag eq "" ? "is open to anyone in the channel" : "requires +$require_flag"}] in $_scope,\
        [expr {$public_enabled ? "enabled" : "DISABLED"}], max $flood_pub use(s) per ${flood_time}s per nick!host;\
        .sysinfo on the partyline [expr {$dcc_flag eq "" ? "is available to any partyline user (see dcc_flag)" : "requires +$dcc_flag"}]."
    unset -nocomplain _scope
}
