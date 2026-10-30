#!/usr/bin/env bash
#
# phone-automounter — udiskie-style automounting for phones, built on gio/gvfs.
#
# What it does, from the user's point of view:
#
#   1. You plug the phone in.  Nothing shows up yet: a phone that is still on
#      "charging only" exposes no usable storage, so there is nothing to show.
#   2. You pick "File transfer" (or "Photo transfer") on the phone.  It gets
#      mounted through gvfs and appears as /media/<Phone> right away.
#   3. You use it like any other folder.
#   4. The cable comes loose, the phone locks again, the mode changes, gvfs
#      dies — /media/<Phone> disappears, exactly like a USB stick pulled out.
#   5. Plug it back in and it comes back.
#
# Design notes:
#
#   * Event driven.  The only source of wake-ups is `gio mount --monitor`,
#     which pushes volume/mount events over D-Bus with millisecond latency.
#     There is no polling of the filesystem and no busy loop.
#   * Every event triggers a full *reconciliation* rather than an incremental
#     state update: we re-read the truth from gvfs and make /media match it.
#     Missed, duplicated or out-of-order events therefore cannot desynchronise
#     us, which is what makes reconnect storms harmless.
#   * A slow resync timer (default 30s) exists only as a watchdog for state
#     gvfs can change without emitting an event — e.g. the storage list
#     appearing when you unlock the phone.  While a device is still pending the
#     timer speeds up automatically, then backs off again to idle.
#   * /media entries are *symlinks*, never directories.  Together with the
#     guards in safe_remove_link() this makes it structurally impossible for
#     this script to delete anything on the phone: the only removal it ever
#     performs is unlink(1) on a path that (a) is a symlink, (b) sits directly
#     in /media, and (c) whose link text names a gvfs mount *root*.  unlink(1)
#     cannot recurse and does not follow symlinks.  There is no `rm` in this
#     file at all.
#
# Requirements: bash 4.2+, glib (gio, gdbus), gvfs with its fuse daemon
# running, and write permission on /media.
#
# Usage: ./automounter.sh [options]      (--help for the list)

# Deliberately no `set -e`: this is a long running daemon and one unexpected
# non-zero exit status must never take it down.  Errors are handled where they
# happen.
set -o pipefail
shopt -s nullglob

readonly APP_NAME="phone-automounter"
readonly APP_VERSION="1.0.0"

# ─────────────────────────────────────────────────────────────────────────────
# Configuration — every value can be overridden from the environment or CLI
# ─────────────────────────────────────────────────────────────────────────────

MEDIA_DIR=${MEDIA_DIR:-/media}
GVFS_ROOT=${GVFS_ROOT:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gvfs}

# gvfs URI schemes we treat as "a phone":
#   mtp      — Android and most phones in File transfer mode
#   gphoto2  — phones in Photo transfer (PTP) mode, cameras
#   afc      — iPhone / iPad (gvfs-afc)
PHONE_SCHEMES=${PHONE_SCHEMES:-"mtp gphoto2 afc"}

# Watchdog reconcile, seconds.  0 disables it (pure event mode).
RESYNC_INTERVAL=${RESYNC_INTERVAL:-30}
# Used only while some device is pending (mount retry queued, or mounted but
# not sharing storage yet), so flipping the phone to File transfer is noticed
# at once even if gvfs emits no event for it.
FAST_RESYNC_INTERVAL=${FAST_RESYNC_INTERVAL:-3}
# How long a device stays in that fast lane before we fall back to the slow
# watchdog (the phone is probably just staying in charging mode).
PENDING_WINDOW=${PENDING_WINDOW:-150}

# Event coalescing: gvfs emits bursts of 4-6 events per plug/unplug.
DEBOUNCE=${DEBOUNCE:-0.4}

# Longest we are willing to sit inside the `read` builtin.  Bash only runs
# signal traps once a builtin returns, and a `read` with a timeout does not
# return early when a signal arrives — so without this bound a Ctrl-C or a
# `systemctl stop` would be acted on up to RESYNC_INTERVAL seconds later and
# the /media links would linger until then.  Nothing is polled on a tick: it
# wakes up, compares two integers and goes back to sleep (measured idle cost:
# 0% CPU).  Device events still arrive through the pipe in milliseconds.
TICK_INTERVAL=${TICK_INTERVAL:-1}

# Timeouts.  Every single call into gvfs is wrapped, because a half-dead gvfs
# backend is the classic way for a script like this to hang forever.
PROBE_TIMEOUT=${PROBE_TIMEOUT:-8}
MOUNT_TIMEOUT=${MOUNT_TIMEOUT:-25}
UNMOUNT_TIMEOUT=${UNMOUNT_TIMEOUT:-15}
LIST_TIMEOUT=${LIST_TIMEOUT:-10}
STAT_TIMEOUT=${STAT_TIMEOUT:-5}

# Consecutive failed health probes before a link is torn down.  Unplugging is
# detected from events, not from probes, so these only catch the exotic case of
# a mount gvfs still lists but that no longer works.  Keep the count generous:
# MTP serialises everything over one USB channel, so a large copy in progress
# can stall an unrelated probe, and we must not yank the folder mid-transfer.
MAX_PROBE_FAILURES=${MAX_PROBE_FAILURES:-3}
# Mount retry backoff, seconds.
MOUNT_RETRY_BASE=${MOUNT_RETRY_BASE:-4}
MOUNT_RETRY_MAX=${MOUNT_RETRY_MAX:-120}

# When a phone we had already published gets unmounted while still plugged in,
# that is almost always the user ejecting it from a file manager — so we leave
# it alone until it is unplugged and connected again, like udiskie does.  Set
# to 1 to mount it straight back instead.
REMOUNT_ALWAYS=${REMOUNT_ALWAYS:-0}

NOTIFY=${NOTIFY:-1}
NOTIFY_TIMEOUT=${NOTIFY_TIMEOUT:-5000}
LOG_DEBUG=${LOG_DEBUG:-0}
USE_COLOR=${USE_COLOR:-auto}            # auto | 1 | 0
KEEP_LINKS_ON_EXIT=${KEEP_LINKS_ON_EXIT:-0}
RUN_ONCE=0

LOCK_FILE=${LOCK_FILE:-${XDG_RUNTIME_DIR:-/tmp}/$APP_NAME.lock}

# ─────────────────────────────────────────────────────────────────────────────
# Runtime state.  Everything is keyed by the device's gvfs URI: the only
# identifier that stays stable across mount/unmount of the same phone.
# ─────────────────────────────────────────────────────────────────────────────

declare -A LINK_PATH=()        # uri -> the /media/<name> symlink we own
declare -A LINK_TARGET=()      # uri -> exact link text we wrote (re-verified on removal)
declare -A DEV_NAME=()         # uri -> human readable name
declare -A PROBE_FAILS=()      # uri -> consecutive failed health probes
declare -A MOUNT_FAILS=()      # uri -> consecutive failed mount attempts
declare -A MOUNT_NEXT_TRY=()   # uri -> epoch seconds, mount backoff
declare -A PENDING_UNTIL=()    # uri -> epoch seconds, fast-lane deadline
declare -A SEEN_VOLUME=()      # uri -> 1, device was present on the previous pass
declare -A WAS_PUBLISHED=()    # uri -> 1, we had it linked at least once this connection
declare -A NOTIFIED_WAITING=() # uri -> 1, "not sharing yet" notice already sent
declare -A SAID_ONCE=()        # "uri|tag" -> 1, log-once bookkeeping

# Snapshot of gvfs, refreshed by refresh_gvfs_state()
declare -A VOL_NAME=() VOL_TYPE=() VOL_DEV=() VOL_CANMOUNT=()
declare -A MOUNT_PRESENT=() MOUNT_NAME=()
declare -a VOL_URIS=() MOUNT_URIS=()

MONITOR_FD=
MONITOR_PID=
MONITOR_RESTARTS=0
NOTIFY_BACKEND=
NOTIFY_UNAVAILABLE=0
STOP_REQUESTED=0

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────

setup_logging() {
    local color=0
    case $USE_COLOR in
        1|yes|true|always) color=1 ;;
        0|no|false|never)  color=0 ;;
        *) [[ -t 1 && -z ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]] && color=1 ;;
    esac

    if ((color)); then
        C_RESET=$'\e[0m';  C_DIM=$'\e[2m';     C_BOLD=$'\e[1m'
        C_RED=$'\e[31m';   C_GREEN=$'\e[32m';  C_YELLOW=$'\e[33m'
        C_BLUE=$'\e[34m';  C_MAGENTA=$'\e[35m'; C_CYAN=$'\e[36m'
    else
        C_RESET= C_DIM= C_BOLD= C_RED= C_GREEN= C_YELLOW= C_BLUE= C_MAGENTA= C_CYAN=
    fi

    # Only use the nicer glyphs where the locale can actually render them.
    if [[ ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} == *[Uu][Tt][Ff]* ]]; then
        G_DEBUG='·'; G_EVENT='⇄'; G_INFO='i'; G_ACTION='→'
        G_OK='✓';    G_WARN='⚠'; G_ERROR='✗'; G_RULE='─'
    else
        G_DEBUG='.'; G_EVENT='~'; G_INFO='i'; G_ACTION='>'
        G_OK='+';    G_WARN='!'; G_ERROR='x'; G_RULE='-'
    fi
}

# log_line <colour> <glyph> <label> <message...>
log_line() {
    local color=$1 glyph=$2 label=$3; shift 3
    printf '%s%(%H:%M:%S)T%s %s%s %-6s%s %s\n' \
        "$C_DIM" -1 "$C_RESET" "$color" "$glyph" "$label" "$C_RESET" "$*"
}

log_debug()  { ((LOG_DEBUG)) && log_line "$C_DIM"     "$G_DEBUG"  "debug"  "$*"; return 0; }
log_event()  { log_line "$C_CYAN"    "$G_EVENT"  "event"  "$*"; }
log_info()   { log_line "$C_BLUE"    "$G_INFO"   "info"   "$*"; }
log_action() { log_line "$C_MAGENTA" "$G_ACTION" "action" "$*"; }
log_ok()     { log_line "$C_GREEN"   "$G_OK"     "ok"     "$*"; }
log_warn()   { log_line "$C_YELLOW"  "$G_WARN"   "warn"   "$*" >&2; }
log_error()  { log_line "$C_RED"     "$G_ERROR"  "error"  "$*" >&2; }

# Emphasise a value inside a log message.
em() { printf '%s%s%s' "$C_BOLD" "$1" "$C_RESET"; }
dim() { printf '%s%s%s' "$C_DIM" "$1" "$C_RESET"; }

# Log something at most once per (device, tag); afterwards it drops to debug.
# Keeps a phone that is plugged in but idle from flooding the console.
# log_once <uri> <tag> <level> <message...>
log_once() {
    local uri=$1 tag=$2 level=$3; shift 3
    local key="$uri|$tag"
    if [[ -n ${SAID_ONCE[$key]:-} ]]; then
        log_debug "$*"
        return 1
    fi
    SAID_ONCE[$key]=1
    "log_$level" "$*"
    return 0
}

forget_once_flags() {
    local uri=$1 key
    for key in "${!SAID_ONCE[@]}"; do
        [[ $key == "$uri|"* ]] && unset -v "SAID_ONCE[$key]"
    done
}

print_banner() {
    local rule; printf -v rule "%0.s$G_RULE" {1..68}
    printf '\n  %s%s%s  %s\n' "$C_BOLD" "$APP_NAME" "$C_RESET" \
        "$(dim "v$APP_VERSION · udiskie-style phone mounting through gio/gvfs")"
    printf '  %s\n' "$(dim "$rule")"
    printf '  %-11s %s\n' 'media dir' "$MEDIA_DIR"
    printf '  %-11s %s\n' 'gvfs root' "$GVFS_ROOT"
    printf '  %-11s %s\n' 'schemes'   "${PHONE_SCHEMES// /, }"
    if ((RESYNC_INTERVAL > 0)); then
        printf '  %-11s %s\n' 'resync' "${RESYNC_INTERVAL}s watchdog, ${FAST_RESYNC_INTERVAL}s while a device is pending"
    else
        printf '  %-11s %s\n' 'resync' 'disabled (events only)'
    fi
    printf '  %-11s %s\n' 'notifies' "${NOTIFY_BACKEND:-disabled}"
    printf '  %s\n\n' "$(dim "$rule")"
}

# ─────────────────────────────────────────────────────────────────────────────
# Desktop notifications
# ─────────────────────────────────────────────────────────────────────────────

detect_notify_backend() {
    NOTIFY_BACKEND=
    NOTIFY_UNAVAILABLE=0
    ((NOTIFY)) || return 0          # switched off on purpose, nothing to look for
    if command -v notify-send >/dev/null 2>&1; then
        NOTIFY_BACKEND=notify-send
    elif command -v gdbus >/dev/null 2>&1; then
        # gdbus ships with glib, same package as gio, so this always works
        # even without libnotify installed.
        NOTIFY_BACKEND=gdbus
    else
        NOTIFY=0
        NOTIFY_UNAVAILABLE=1
    fi
    return 0
}

# notify <icon> <low|normal|critical> <summary> <body>
notify() {
    ((NOTIFY)) || return 0
    local icon=$1 urgency=$2 summary=$3 body=$4

    case $NOTIFY_BACKEND in
        notify-send)
            timeout -k 2 5 notify-send --app-name="$APP_NAME" --icon="$icon" \
                --urgency="$urgency" --expire-time="$NOTIFY_TIMEOUT" \
                -- "$summary" "$body" >/dev/null 2>&1 \
                || log_debug "notify-send failed (no notification daemon?)"
            ;;
        gdbus)
            local level=1
            case $urgency in low) level=0 ;; critical) level=2 ;; esac
            timeout -k 2 5 gdbus call --session \
                --dest org.freedesktop.Notifications \
                --object-path /org/freedesktop/Notifications \
                --method org.freedesktop.Notifications.Notify \
                "$APP_NAME" 0 "$icon" "$summary" "$body" '[]' \
                "{'urgency': <byte $level>}" "$NOTIFY_TIMEOUT" >/dev/null 2>&1 \
                || log_debug "gdbus notify failed (no notification daemon?)"
            ;;
    esac
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Environment checks
# ─────────────────────────────────────────────────────────────────────────────

check_environment() {
    local fatal=0 tool

    if ! command -v gio >/dev/null 2>&1; then
        log_error "$(em gio) is not in PATH; it ships with glib"
        log_error "on NixOS: add $(em glib) to environment.systemPackages and rebuild"
        fatal=1
    fi
    for tool in timeout readlink unlink ln sleep awk; do
        command -v "$tool" >/dev/null 2>&1 \
            || { log_error "required tool missing: $(em "$tool")"; fatal=1; }
    done

    if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} && ! -S ${XDG_RUNTIME_DIR:-/nonexistent}/bus ]]; then
        log_error "no D-Bus session bus here; gio cannot reach gvfs"
        fatal=1
    fi

    if [[ ! -d $MEDIA_DIR ]]; then
        log_error "$(em "$MEDIA_DIR") does not exist"
        fatal=1
    elif [[ ! -w $MEDIA_DIR ]]; then
        log_error "$(em "$MEDIA_DIR") is not writable by $(id -un); cannot manage links there"
        fatal=1
    fi

    ((fatal)) && return 1

    if [[ ! -d $GVFS_ROOT ]]; then
        log_warn "gvfs fuse root $(em "$GVFS_ROOT") is missing"
        log_warn "gvfsd-fuse is what gives a phone a real filesystem path; without it"
        log_warn "there is nothing to link to. Check that it is running."
    elif ! gvfs_root_is_mounted; then
        log_warn "$(em "$GVFS_ROOT") exists but is not a gvfsd-fuse mount point"
    fi

    if ((NOTIFY)); then
        log_debug "notifications via $NOTIFY_BACKEND"
    elif ((NOTIFY_UNAVAILABLE)); then
        log_warn "neither notify-send nor gdbus found: desktop notifications disabled"
    else
        log_debug "desktop notifications disabled by request"
    fi
    return 0
}

gvfs_root_is_mounted() {
    [[ -r /proc/self/mountinfo ]] || return 0      # cannot tell; assume fine
    grep -qF " $GVFS_ROOT " /proc/self/mountinfo 2>/dev/null
}

# Single instance: two of these fighting over the same /media would be a mess.
acquire_lock() {
    command -v flock >/dev/null 2>&1 || {
        log_debug "flock unavailable; running without a single-instance lock"
        return 0
    }
    # The braces matter: without them the 2>/dev/null would become a permanent
    # redirection of the shell's own stderr, silencing every warning we log.
    if ! { exec {LOCK_FD}>"$LOCK_FILE"; } 2>/dev/null; then
        log_debug "cannot open lock file $LOCK_FILE; continuing without a lock"
        return 0
    fi
    if ! flock -n "$LOCK_FD"; then
        log_error "another $APP_NAME instance is already running $(dim "(lock: $LOCK_FILE)")"
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# URI helpers
# ─────────────────────────────────────────────────────────────────────────────

uri_scheme() { printf '%s' "${1%%://*}"; }

uri_host() {
    local u=$1 rest
    [[ $u == *://* ]] || { printf ''; return; }
    rest=${u#*://}
    printf '%s' "${rest%%/*}"
}

# Canonical form carries exactly one trailing slash, so a volume's
# activation_root and a mount's location compare equal.
uri_canonical() {
    [[ -n $1 ]] || { printf ''; return; }
    printf '%s/' "${1%/}"
}

percent_decode() {
    local s=$1
    s=${s//\\/\\\\}                 # keep printf %b from eating backslashes
    printf '%b' "${s//%/\\x}"
}

is_phone_scheme() {
    local scheme=$1 s
    for s in $PHONE_SCHEMES; do
        [[ $scheme == "$s" ]] && return 0
    done
    return 1
}

is_phone_uri() { is_phone_scheme "${1%%://*}"; }

# ─────────────────────────────────────────────────────────────────────────────
# Reading the truth out of gvfs
# ─────────────────────────────────────────────────────────────────────────────

# `gio mount --list -i` prints a nested Drive -> Volume -> Mount tree.  It is
# the only way to get, in one shot, both the device identity (a Volume, which
# exists for as long as the hardware is plugged in) and the mount state (a
# Mount).  We flatten it into tab separated records instead of depending on the
# indentation, and split mount lines on the LAST " -> " so a device name
# containing that string cannot confuse us.
IFS= read -r -d '' GIO_LIST_PARSER <<'AWK'
function flush_volume() {
    if (in_vol) {
        printf "V\t%s\t%s\t%s\t%s\t%s\n", vname, vroot, vtype, vdev, vcanmount
        in_vol = 0
    }
}
/^[[:space:]]*Drive\([0-9]+\):/ { flush_volume(); next }
/^[[:space:]]*Volume\([0-9]+\):/ {
    flush_volume()
    line = $0
    sub(/^[[:space:]]*Volume\([0-9]+\): /, "", line)
    in_vol = 1; vname = line; vroot = ""; vtype = ""; vdev = ""; vcanmount = "0"
    next
}
/^[[:space:]]*Mount\([0-9]+\):/ {
    flush_volume()
    line = $0
    sub(/^[[:space:]]*Mount\([0-9]+\): /, "", line)
    cut = 0; pos = 1
    while ((hit = index(substr(line, pos), " -> ")) > 0) {
        cut = pos + hit - 1
        pos = cut + 4
    }
    if (cut > 0) { mname = substr(line, 1, cut - 1); muri = substr(line, cut + 4) }
    else         { mname = line; muri = "" }
    printf "M\t%s\t%s\n", mname, muri
    next
}
in_vol && /^[[:space:]]*Type: / {
    line = $0; sub(/^[[:space:]]*Type: /, "", line); vtype = line; next
}
in_vol && /^[[:space:]]*activation_root=/ {
    line = $0; sub(/^[[:space:]]*activation_root=/, "", line); vroot = line; next
}
in_vol && /^[[:space:]]*unix-device: / {
    line = $0; sub(/^[[:space:]]*unix-device: /, "", line)
    gsub(/^'|'$/, "", line); vdev = line; next
}
in_vol && /^[[:space:]]*can_mount=/ {
    line = $0; sub(/^[[:space:]]*can_mount=/, "", line); vcanmount = line; next
}
END { flush_volume() }
AWK

# Fills VOL_* / MOUNT_* / VOL_URIS / MOUNT_URIS.  Returns 1 if gvfs could not
# be queried at all — in that case the caller must NOT conclude that devices
# disappeared, or a momentary D-Bus glitch would unlink every phone.
refresh_gvfs_state() {
    local raw rc
    raw=$(timeout -k 2 "$LIST_TIMEOUT" gio mount --list -i 2>/dev/null); rc=$?
    if ((rc != 0)); then
        log_warn "could not query gvfs $(dim "(gio mount --list exited $rc)"); keeping previous state"
        return 1
    fi

    VOL_NAME=(); VOL_TYPE=(); VOL_DEV=(); VOL_CANMOUNT=()
    MOUNT_PRESENT=(); MOUNT_NAME=()
    VOL_URIS=(); MOUNT_URIS=()

    local kind f2 f3 f4 f5 f6 uri
    while IFS=$'\t' read -r kind f2 f3 f4 f5 f6; do
        uri=$(uri_canonical "$f3")
        [[ -n $uri ]] || continue
        is_phone_uri "$uri" || continue
        case $kind in
            V)
                if [[ -z ${VOL_NAME[$uri]+x} ]]; then
                    VOL_URIS+=("$uri")
                fi
                VOL_NAME[$uri]=$f2
                VOL_TYPE[$uri]=$f4
                VOL_DEV[$uri]=$f5
                VOL_CANMOUNT[$uri]=$f6
                ;;
            M)
                # gvfs reports the same mount twice (the proxy shadow mount and
                # the bare daemon mount); keying by URI deduplicates them.
                if [[ -z ${MOUNT_PRESENT[$uri]:-} ]]; then
                    MOUNT_URIS+=("$uri")
                    MOUNT_PRESENT[$uri]=1
                    MOUNT_NAME[$uri]=$f2
                fi
                ;;
        esac
    done < <(printf '%s\n' "$raw" | awk "$GIO_LIST_PARSER")

    log_debug "gvfs: ${#VOL_URIS[@]} phone volume(s), ${#MOUNT_URIS[@]} phone mount(s)"
    return 0
}

# Map a gvfs URI to its directory under the fuse root.  gvfsd-fuse names each
# mount directory after the mount spec, e.g. mtp://Nothing_A001_0019/ becomes
# <root>/mtp:host=Nothing_A001_0019.  We try that direct form first and fall
# back to comparing percent-decoded hosts, so differences in escaping between
# gvfs versions cannot break the mapping.
fuse_path_for_uri() {
    local uri=$1 scheme host candidate entry kv key val decoded_host
    scheme=$(uri_scheme "$uri")
    host=$(uri_host "$uri")
    [[ -n $scheme && -n $host ]] || return 1

    candidate="$GVFS_ROOT/$scheme:host=$host"
    if timeout -k 2 "$STAT_TIMEOUT" test -d "$candidate" 2>/dev/null; then
        printf '%s' "$candidate"
        return 0
    fi

    decoded_host=$(percent_decode "$host")
    for candidate in "$GVFS_ROOT/$scheme:"*; do
        entry=${candidate##*/}
        entry=${entry#*:}                      # drop the "scheme:" prefix
        while [[ -n $entry ]]; do              # walk the key=value,key=value list
            kv=${entry%%,*}
            [[ $entry == *,* ]] && entry=${entry#*,} || entry=
            key=${kv%%=*}; val=${kv#*=}
            if [[ $key == host && $(percent_decode "$val") == "$decoded_host" ]]; then
                printf '%s' "$candidate"
                return 0
            fi
        done
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Health probes.  These go through gio, i.e. through gvfs' own D-Bus plumbing,
# so a wedged backend surfaces as an error instead of a hung filesystem call.
# ─────────────────────────────────────────────────────────────────────────────

# Is the mount alive at all?
probe_alive() {
    timeout -k 2 "$PROBE_TIMEOUT" gio info -a standard::type -- "$1" >/dev/null 2>&1
}

# Does the phone actually expose a storage?  A phone that is plugged in but
# still on "charging only", or locked, or that has not granted access yet,
# mounts with an empty root — precisely the state we must not publish.
#
# The three-way answer matters.  MTP talks to the device over a single USB
# channel, so while a big file is being copied an unrelated listing can simply
# time out.  That is *not* evidence that the storage went away, and treating it
# as such would unpublish the phone in the middle of the user's transfer.  Only
# a listing that succeeds and comes back empty is real evidence.
#   ok      — at least one storage is there
#   empty   — the device answered, and has nothing to share
#   unknown — could not ask right now (busy, timeout, transient error)
probe_storage_state() {
    local out rc
    out=$(timeout -k 2 "$LIST_TIMEOUT" gio list -- "$1" 2>/dev/null); rc=$?
    if ((rc != 0)); then
        printf 'unknown'
    elif [[ -n $out ]]; then
        printf 'ok'
    else
        printf 'empty'
    fi
}

# Does the symlink have something real to point at?
probe_fuse_path() {
    timeout -k 2 "$STAT_TIMEOUT" test -d "$1" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Mounting / unmounting
# ─────────────────────────────────────────────────────────────────────────────

mount_device() {
    local uri=$1 name=$2 err rc fails delay
    log_action "mounting $(em "$name") $(dim "($uri)")"
    err=$(timeout -k 2 "$MOUNT_TIMEOUT" gio mount -- "$uri" 2>&1); rc=$?
    if ((rc == 0)); then
        MOUNT_FAILS[$uri]=0
        MOUNT_NEXT_TRY[$uri]=0
        return 0
    fi

    fails=$(( ${MOUNT_FAILS[$uri]:-0} + 1 ))
    MOUNT_FAILS[$uri]=$fails
    delay=$(( MOUNT_RETRY_BASE * (1 << ( (fails > 6 ? 6 : fails) - 1 )) ))
    ((delay > MOUNT_RETRY_MAX)) && delay=$MOUNT_RETRY_MAX
    MOUNT_NEXT_TRY[$uri]=$(( EPOCHSECONDS + delay ))

    err=${err//$'\n'/ }
    if log_once "$uri" mount-failed error \
            "mount failed for $(em "$name"): ${err:-unknown error (exit $rc)}"; then
        log_info "retrying in ${delay}s $(dim '(backs off on repeated failures)')"
    else
        log_debug "mount attempt #$fails failed for $name; next try in ${delay}s"
    fi
    return 1
}

# Only ever used on a gvfs mount with no hardware behind it any more.
# Unmounting never touches data on the device.
unmount_stale() {
    local uri=$1 name=$2
    log_action "releasing stale gvfs mount of $(em "$name") so it can reattach cleanly"
    if timeout -k 2 "$UNMOUNT_TIMEOUT" gio mount -u -f -- "$uri" >/dev/null 2>&1; then
        log_ok "stale mount released $(dim "($uri)")"
    else
        log_debug "could not release stale mount $uri (gvfs may have done it already)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# /media link management
#
# Safety model, strictest first:
#   * we only ever create symlinks, never directories, so /media never holds a
#     real mount point that could be recursively deleted;
#   * a link counts as ours only if its *link text* — readlink, which resolves
#     nothing — starts with the gvfs fuse root AND names a mount root of a
#     phone scheme.  A link pointing at a path *inside* the phone is rejected;
#   * removal goes through safe_remove_link(), which re-validates all of the
#     above and then calls unlink(1): one directory entry, no recursion, no
#     dereferencing.  The phone's contents are not reachable from there even in
#     principle.
# ─────────────────────────────────────────────────────────────────────────────

# Is this link text one we are allowed to manage?
target_is_managed() {
    local target=$1 entry scheme
    [[ -n $target ]] || return 1
    [[ $target == "$GVFS_ROOT"/* ]] || return 1
    entry=${target#"$GVFS_ROOT"/}
    entry=${entry%/}
    [[ -n $entry && $entry != */* ]] || return 1     # a mount root, never a sub-path
    [[ $entry == *:* ]] || return 1
    scheme=${entry%%:*}
    is_phone_scheme "$scheme"
}

# Is this path a plain, direct, non-tricky child of MEDIA_DIR?
link_path_is_sane() {
    local path=$1 base
    [[ -n $path ]] || return 1
    [[ $path == "$MEDIA_DIR"/* ]] || return 1
    base=${path#"$MEDIA_DIR"/}
    [[ -n $base && $base != */* && $base != . && $base != .. ]] || return 1
    [[ $base != *$'\n'* ]] || return 1
    return 0
}

sanitise_name() {
    local name=$1
    name=${name//$'\n'/ }
    name=${name//$'\t'/ }
    name=${name//\//_}
    name=${name//\\/_}
    name=${name//$'\r'/}
    while [[ $name == *"  "* ]]; do name=${name//  / }; done
    name=${name# }; name=${name% }
    # never start with . or -, both are awkward in a directory listing
    while [[ $name == .* || $name == -* ]]; do name=${name:1}; done
    ((${#name} > 60)) && name=${name:0:60}
    printf '%s' "$name"
}

# A short, stable discriminator from the device URI, for when two phones want
# the same name (two identical handsets, for instance).
short_id() {
    local host seg id
    host=$(percent_decode "$(uri_host "$1")")
    # MTP hosts look like Vendor_Model_Serial, so the last underscore-separated
    # field is the part that actually distinguishes two identical handsets.
    seg=${host##*_}
    id=${seg//[^[:alnum:]]/}
    [[ -z $id ]] && id=${host//[^[:alnum:]]/}
    if ((${#id} > 6)); then printf '%s' "${id: -6}"
    else printf '%s' "${id:-dev}"
    fi
}

display_name_for() {
    local uri=$1 name
    name=$(sanitise_name "${VOL_NAME[$uri]:-}")
    if [[ -z $name ]]; then
        name=$(sanitise_name "${MOUNT_NAME[$uri]:-}")
        # gvfs names the bare daemon mount after the backend ("mtp"), which is
        # useless as a folder name.
        [[ $name == "${uri%%://*}" ]] && name=
    fi
    [[ -z $name ]] && name=$(sanitise_name "$(percent_decode "$(uri_host "$uri")")")
    printf '%s' "${name:-Phone-$(short_id "$uri")}"
}

# May we claim MEDIA_DIR/<name> for this device?
#   0 = free, or already exactly the link we want
#   1 = occupied by something we must not touch
candidate_is_available() {
    local path=$1 uri=$2 target=$3 existing other

    [[ ! -e $path && ! -L $path ]] && return 0

    if [[ -L $path ]]; then
        existing=$(readlink -- "$path" 2>/dev/null)
        [[ $existing == "$target" ]] && return 0        # already what we want
        if target_is_managed "$existing"; then
            # A phone link, but for a different device.  If a device we are
            # currently tracking owns it, hands off; otherwise it is a leftover
            # we may recycle.
            for other in "${!LINK_PATH[@]}"; do
                [[ ${LINK_PATH[$other]} == "$path" && $other != "$uri" ]] && return 1
            done
            return 0
        fi
        return 1                                        # someone else's symlink
    fi

    return 1    # a real file or directory — e.g. a udiskie USB mount point
}

choose_link_path() {
    local uri=$1 target=$2 base path cand i
    base=$(display_name_for "$uri")

    local -a candidates=("$base" "$base-$(short_id "$uri")")
    for ((i = 2; i <= 20; i++)); do candidates+=("$base-$i"); done

    for cand in "${candidates[@]}"; do
        path="$MEDIA_DIR/$cand"
        link_path_is_sane "$path" || continue
        if candidate_is_available "$path" "$uri" "$target"; then
            printf '%s' "$path"
            return 0
        fi
        log_debug "name '$cand' is taken by something we do not manage"
    done
    return 1
}

# The one and only place in this program that removes anything.
safe_remove_link() {
    local path=$1 expected=${2:-} target

    if ! link_path_is_sane "$path"; then
        log_error "refusing to remove $(em "$path"): not a direct child of $MEDIA_DIR"
        return 1
    fi

    # -L uses lstat, so it never follows the link: whether a live phone sits
    # behind it is irrelevant here.
    if [[ ! -L $path ]]; then
        if [[ -e $path ]]; then
            log_error "refusing to remove $(em "$path"): it is a real file or directory, not our symlink"
            return 1
        fi
        log_debug "nothing to remove at $path (already gone)"
        return 0
    fi

    target=$(readlink -- "$path" 2>/dev/null)
    if [[ -n $expected && $target != "$expected" ]]; then
        log_error "refusing to remove $(em "$path"): link text changed" \
                  "$(dim "(now '$target', expected '$expected')")"
        return 1
    fi
    if ! target_is_managed "$target"; then
        log_error "refusing to remove $(em "$path"): '$target' is not a gvfs phone mount root"
        return 1
    fi

    # unlink(1) removes exactly one directory entry.  It has no recursive mode
    # and does not dereference the symlink.
    unlink -- "$path" 2>/dev/null && return 0
    [[ ! -L $path && ! -e $path ]] && return 0      # someone else got there first
    log_error "failed to remove symlink $(em "$path")"
    return 1
}

create_link() {
    local uri=$1 target=$2 path

    if ! path=$(choose_link_path "$uri" "$target"); then
        log_error "no free name left in $MEDIA_DIR for $(em "$(display_name_for "$uri")")"
        return 1
    fi

    # Recycle our own leftover link at that exact path first.
    if [[ -L $path ]]; then
        safe_remove_link "$path" || return 1
    fi

    # -T guarantees ln can never create the link *inside* an existing
    # directory, and without -f it refuses to clobber anything.
    if ! ln -s -T -- "$target" "$path" 2>/dev/null; then
        log_error "could not create symlink $(em "$path") -> $target"
        return 1
    fi

    LINK_PATH[$uri]=$path
    LINK_TARGET[$uri]=$target
    return 0
}

remove_link() {
    # Two statements on purpose: bash expands every word of a single `local`
    # before assigning any of them, so `uri` is not yet visible on that line.
    local uri=$1 rc=0
    local path=${LINK_PATH[$uri]:-} target=${LINK_TARGET[$uri]:-}
    [[ -n $path ]] || return 0
    safe_remove_link "$path" "$target" || rc=1
    unset -v "LINK_PATH[$uri]" "LINK_TARGET[$uri]"
    return $rc
}

# Links left behind by a previous run (or a crash) that no live device claims.
# Only links we are allowed to manage are even considered, so everything else
# in /media — including udiskie's real USB mount directories — is untouched.
# sweep_unclaimed_links [reason]
sweep_unclaimed_links() {
    local reason=${1:-stale} path target claimed uri
    for path in "$MEDIA_DIR"/*; do
        [[ -L $path ]] || continue
        target=$(readlink -- "$path" 2>/dev/null)
        target_is_managed "$target" || continue

        claimed=0
        for uri in "${!LINK_PATH[@]}"; do
            [[ ${LINK_PATH[$uri]} == "$path" ]] && { claimed=1; break; }
        done
        ((claimed)) && continue

        log_info "clearing $reason phone link $(em "$path") $(dim "-> $target")"
        safe_remove_link "$path"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Reconciliation — the heart of the program
# ─────────────────────────────────────────────────────────────────────────────

forget_device() {
    local uri=$1
    unset -v "PROBE_FAILS[$uri]" "MOUNT_FAILS[$uri]" "MOUNT_NEXT_TRY[$uri]" \
             "PENDING_UNTIL[$uri]" "SEEN_VOLUME[$uri]" "DEV_NAME[$uri]" \
             "WAS_PUBLISHED[$uri]" "NOTIFIED_WAITING[$uri]"
    forget_once_flags "$uri"
}

mark_pending() {
    [[ -n ${PENDING_UNTIL[$1]:-} ]] || PENDING_UNTIL[$1]=$(( EPOCHSECONDS + PENDING_WINDOW ))
}

clear_pending() { unset -v "PENDING_UNTIL[$1]"; }

# Is anything worth re-checking soon?  Decides the read timeout of the loop.
has_pending_work() {
    local uri
    for uri in "${!PENDING_UNTIL[@]}"; do
        (( PENDING_UNTIL[$uri] > EPOCHSECONDS )) && return 0
    done
    return 1
}

# Hardware present, mounted and healthy -> make sure /media shows it.
attach_device() {
    local uri=$1 name=$2 fuse

    if ! fuse=$(fuse_path_for_uri "$uri"); then
        log_once "$uri" no-fuse warn \
            "$(em "$name") is mounted but has no directory under $GVFS_ROOT yet"
        mark_pending "$uri"
        return 1
    fi
    if ! probe_fuse_path "$fuse"; then
        log_once "$uri" bad-fuse warn "$(em "$name"): $fuse is not readable"
        mark_pending "$uri"
        return 1
    fi
    case $(probe_storage_state "$uri") in
        empty)
            # Plugged in and mounted, but the phone is not sharing anything
            # yet: "charging only", locked, or access not granted.
            log_once "$uri" waiting info \
                "$(em "$name") is connected but not sharing storage yet" \
                "$(dim '— choose "File transfer" on the phone')"
            if [[ -z ${NOTIFIED_WAITING[$uri]:-} ]]; then
                NOTIFIED_WAITING[$uri]=1
                notify phone low "Phone connected" \
                    "$name is not sharing files yet — choose \"File transfer\" on the device"
            fi
            mark_pending "$uri"
            return 1
            ;;
        unknown)
            log_debug "$name did not answer a storage listing yet; retrying shortly"
            mark_pending "$uri"
            return 1
            ;;
    esac

    if ! create_link "$uri" "$fuse"; then
        log_once "$uri" link-failed warn "could not publish $(em "$name") in $MEDIA_DIR"
        mark_pending "$uri"
        return 1
    fi

    PROBE_FAILS[$uri]=0
    WAS_PUBLISHED[$uri]=1
    clear_pending "$uri"
    unset -v "NOTIFIED_WAITING[$uri]"
    forget_once_flags "$uri"
    log_ok "$(em "$name") is available at $(em "${LINK_PATH[$uri]}")"
    notify phone normal "Phone mounted" "$name is available at ${LINK_PATH[$uri]}"
    return 0
}

# Gone or unusable -> make /media forget about it.
# detach_device <uri> <name> <reason> [quiet]
detach_device() {
    local uri=$1 name=$2 reason=$3 quiet=${4:-0}
    local path=${LINK_PATH[$uri]:-}

    if [[ -z $path ]]; then
        log_debug "$name detached ($reason); nothing was linked"
        return 0
    fi

    if remove_link "$uri"; then
        log_ok "$(em "$name") removed from $(em "$path") $(dim "($reason)")"
        ((quiet)) || notify phone normal "Phone disconnected" "$name is gone from $path"
    else
        log_error "$(em "$name"): could not cleanly remove $path, leaving it alone"
    fi
    return 0
}

# Keep an already-published device honest: our link must still be ours, and
# the mount behind it must still answer.
verify_linked_device() {
    local uri=$1 name=$2
    # Second statement: see remove_link() — $uri is not visible on its own line.
    local path=${LINK_PATH[$uri]:-} target=${LINK_TARGET[$uri]:-}
    local actual fails

    if [[ ! -L $path ]]; then
        log_warn "$(em "$path") is no longer our symlink; disowning it"
        unset -v "LINK_PATH[$uri]" "LINK_TARGET[$uri]"
        return 1
    fi
    actual=$(readlink -- "$path" 2>/dev/null)
    if [[ $actual != "$target" ]]; then
        log_warn "$(em "$path") was repointed by something else; disowning it"
        unset -v "LINK_PATH[$uri]" "LINK_TARGET[$uri]"
        return 1
    fi

    # Two ways a published phone can go bad while gvfs still lists the mount:
    # the backend wedges (nothing answers), or the device drops its storage and
    # leaves an empty folder behind.  The second one used to go unnoticed: the
    # link stayed, the folder looked empty and not a single line was logged.
    local reason=
    if ! probe_fuse_path "$target" || ! probe_alive "$uri"; then
        reason="stopped responding"
    elif [[ $(probe_storage_state "$uri") == empty ]]; then
        reason="stopped sharing its storage"
    else
        PROBE_FAILS[$uri]=0
        return 0
    fi

    fails=$(( ${PROBE_FAILS[$uri]:-0} + 1 ))
    PROBE_FAILS[$uri]=$fails
    if ((fails < MAX_PROBE_FAILURES)); then
        log_warn "$(em "$name") $reason $(dim "(attempt $fails/$MAX_PROBE_FAILURES)"); re-checking shortly"
        mark_pending "$uri"
        return 2
    fi
    log_warn "$(em "$name") $reason"
    detach_device "$uri" "$name" "$reason"
    PROBE_FAILS[$uri]=0
    return 1
}

reconcile() {
    refresh_gvfs_state || return 0      # gvfs unreachable: change nothing

    local -A present=()
    local uri name

    # ---- devices whose hardware is present --------------------------------
    for uri in "${VOL_URIS[@]}"; do
        # A probe can take seconds; do not make a shutdown wait for all of them.
        ((STOP_REQUESTED)) && return 0
        present[$uri]=1
        name=$(display_name_for "$uri")
        DEV_NAME[$uri]=$name

        if [[ -z ${SEEN_VOLUME[$uri]:-} ]]; then
            SEEN_VOLUME[$uri]=1
            log_info "device appeared: $(em "$name") $(dim "($uri)")"
            mark_pending "$uri"
        fi

        if [[ -z ${MOUNT_PRESENT[$uri]:-} ]]; then
            # Present but not mounted.
            [[ -n ${LINK_PATH[$uri]:-} ]] && detach_device "$uri" "$name" "no longer mounted"

            # If we had already published it and it is still plugged in, the
            # unmount came from somewhere else — the user ejecting it in a file
            # manager, almost always.  Respect that instead of fighting it.
            if [[ -n ${WAS_PUBLISHED[$uri]:-} ]] && ((! REMOUNT_ALWAYS)); then
                log_once "$uri" released info \
                    "$(em "$name") was ejected while still plugged in; leaving it unmounted" \
                    "$(dim '— unplug and reconnect it to get it back')"
                clear_pending "$uri"
                continue
            fi

            if [[ ${VOL_CANMOUNT[$uri]:-0} != 1 ]]; then
                log_once "$uri" cannot-mount info "$(em "$name") cannot be mounted right now"
                mark_pending "$uri"
                continue
            fi
            if (( ${MOUNT_NEXT_TRY[$uri]:-0} > EPOCHSECONDS )); then
                log_debug "$name: mount retry backed off for $(( MOUNT_NEXT_TRY[$uri] - EPOCHSECONDS ))s"
                mark_pending "$uri"
                continue
            fi
            if ! mount_device "$uri" "$name"; then
                mark_pending "$uri"
                continue
            fi
            # gvfs publishes the mount asynchronously; re-read before deciding.
            refresh_gvfs_state || continue
            if [[ -z ${MOUNT_PRESENT[$uri]:-} ]]; then
                log_debug "$name mounted but not published yet; picking it up next pass"
                mark_pending "$uri"
                continue
            fi
        fi

        # ---- mounted ----
        if [[ -n ${LINK_PATH[$uri]:-} ]]; then
            verify_linked_device "$uri" "$name"
        else
            attach_device "$uri" "$name"
        fi
    done

    # ---- mounts with no hardware behind them ------------------------------
    # This is the dangerous "the folder is there but it is not really a phone
    # any more" case: the cable was pulled while gvfs kept the mount around.
    for uri in "${MOUNT_URIS[@]}"; do
        [[ -n ${present[$uri]:-} ]] && continue
        name=${DEV_NAME[$uri]:-$(display_name_for "$uri")}
        log_warn "$(em "$name") still has a gvfs mount but the device is gone"
        detach_device "$uri" "$name" "device removed"
        unmount_stale "$uri" "$name"
        forget_device "$uri"
    done

    # ---- devices we were tracking that vanished completely ----------------
    for uri in "${!SEEN_VOLUME[@]}"; do
        [[ -n ${present[$uri]:-} ]] && continue
        name=${DEV_NAME[$uri]:-$(display_name_for "$uri")}
        log_info "device disappeared: $(em "$name")"
        detach_device "$uri" "$name" "device unplugged"
        forget_device "$uri"
    done

    # ---- expire the fast lane ---------------------------------------------
    for uri in "${!PENDING_UNTIL[@]}"; do
        if [[ -z ${present[$uri]:-} ]] || (( PENDING_UNTIL[$uri] <= EPOCHSECONDS )); then
            clear_pending "$uri"
        fi
    done

    sweep_unclaimed_links
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Event loop
# ─────────────────────────────────────────────────────────────────────────────

start_monitor() {
    stop_monitor
    # glib flushes every line as it prints it, so this pipe delivers events in
    # real time.  LC_ALL=C keeps the event labels in English for the log; the
    # device names themselves pass through as raw UTF-8 bytes.
    # The monitor must not inherit the lock file descriptor: if this process is
    # ever SIGKILLed the orphaned monitor would keep holding the lock and no
    # new instance could ever start.
    exec {MONITOR_FD}< <(
        [[ -n ${LOCK_FD:-} ]] && exec {LOCK_FD}>&-
        export LC_ALL=C
        exec gio mount --monitor 2>&1
    )
    MONITOR_PID=$!
    if [[ -z $MONITOR_FD || -z $MONITOR_PID ]]; then
        log_error "could not start 'gio mount --monitor'"
        MONITOR_FD=
        return 1
    fi
    log_debug "event monitor running (pid $MONITOR_PID)"
    return 0
}

stop_monitor() {
    if [[ -n $MONITOR_PID ]]; then
        kill "$MONITOR_PID" 2>/dev/null
        MONITOR_PID=
    fi
    if [[ -n $MONITOR_FD ]]; then
        exec {MONITOR_FD}<&- 2>/dev/null
        MONITOR_FD=
    fi
}

# gio prints lines like:  Mount added:        'A001'
# Any line other than its banner means something changed; reconcile() then
# reads the real state, so we never depend on parsing these.
is_monitor_banner() { [[ $1 == Monitoring\ events* || -z $1 ]]; }

pretty_event() {
    local line=${1//\'/}
    while [[ $line == *"  "* ]]; do line=${line//  / }; done
    printf '%s' "${line%:}"
}

# Swallow the rest of an event burst so one plug/unplug costs one reconcile.
drain_event_burst() {
    local extra count=0
    while IFS= read -r -t "$DEBOUNCE" -u "$MONITOR_FD" extra; do
        is_monitor_banner "$extra" || log_event "$(pretty_event "$extra")"
        count=$((count + 1))
        ((count >= 50)) && break        # pathological storm: stop coalescing
    done
    return 0
}

event_loop() {
    local line rc delay interval next_resync=0

    while ((! STOP_REQUESTED)); do
        if [[ -z $MONITOR_FD ]]; then
            if ! start_monitor; then
                log_warn "retrying monitor start in 5s"
                sleep 5
                continue
            fi
            # Reconcile *after* the monitor is listening, so a device that
            # shows up during startup cannot slip through unnoticed.  The
            # reconcile also adopts links left by a previous run and clears the
            # ones no live device claims.
            reconcile
            next_resync=0
            log_info "watching for phone events $(dim '(Ctrl-C to stop)')"
        fi

        # Work out when the watchdog is next due.  A device that is still
        # pending pulls the deadline in; events reset it.
        if has_pending_work; then
            interval=$FAST_RESYNC_INTERVAL
        else
            interval=$RESYNC_INTERVAL
        fi
        if ((interval <= 0)); then
            next_resync=0                                   # watchdog disabled
        elif ((next_resync == 0 || next_resync > EPOCHSECONDS + interval)); then
            next_resync=$((EPOCHSECONDS + interval))
        fi

        # The loop is woken by events, not by this timeout; see TICK_INTERVAL
        # for why we never block in `read` for longer than that.
        IFS= read -r -t "$TICK_INTERVAL" -u "$MONITOR_FD" line; rc=$?

        ((STOP_REQUESTED)) && break

        if ((rc == 0)); then
            is_monitor_banner "$line" || log_event "$(pretty_event "$line")"
            drain_event_burst
            reconcile
            next_resync=0
        elif ((rc > 128)); then
            # A tick (or a signal) rather than an event.
            if ((next_resync > 0 && EPOCHSECONDS >= next_resync)); then
                log_debug "watchdog resync (every ${interval}s)"
                reconcile
                next_resync=0
            fi
        else
            # EOF or error: the monitor died (gvfs restart, D-Bus drop, ...).
            MONITOR_RESTARTS=$((MONITOR_RESTARTS + 1))
            stop_monitor
            log_warn "event monitor stopped; reconnecting $(dim "(restart #$MONITOR_RESTARTS)")"
            delay=$(( MONITOR_RESTARTS > 5 ? 10 : 2 ))
            sleep "$delay"
        fi
    done
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Lifecycle
# ─────────────────────────────────────────────────────────────────────────────

on_signal() {
    STOP_REQUESTED=1
    printf '\n'
    log_info "shutting down"
}

cleanup() {
    stop_monitor
    if ((KEEP_LINKS_ON_EXIT)); then
        ((${#LINK_PATH[@]})) && log_info "leaving ${#LINK_PATH[@]} link(s) in $MEDIA_DIR as requested"
    else
        local uri
        for uri in "${!LINK_PATH[@]}"; do
            detach_device "$uri" "${DEV_NAME[$uri]:-phone}" "automounter stopping" 1
        done
    fi
    log_info "stopped"
}

usage() {
    cat <<EOF
$APP_NAME v$APP_VERSION — udiskie-style phone automounting through gio/gvfs

Usage: ${0##*/} [options]

Options:
  --media-dir DIR   where to publish the phone links    (default: $MEDIA_DIR)
  --schemes "a b"   gvfs schemes treated as phones      (default: $PHONE_SCHEMES)
  --resync SECS     watchdog interval, 0 = events only  (default: $RESYNC_INTERVAL)
  --no-resync       same as --resync 0
  --remount-always  mount a phone straight back even after it was ejected
  --no-notify       do not send desktop notifications
  --keep-links      leave the links in place on exit
  --once            reconcile once and exit (handy for testing)
  --debug           verbose logging
  --color WHEN      always | never | auto               (default: $USE_COLOR)
  -h, --help        this text
  -V, --version     print the version

Each option also has an environment variable: MEDIA_DIR, GVFS_ROOT,
PHONE_SCHEMES, RESYNC_INTERVAL, FAST_RESYNC_INTERVAL, PENDING_WINDOW, DEBOUNCE,
TICK_INTERVAL, MAX_PROBE_FAILURES, MOUNT_RETRY_BASE, MOUNT_RETRY_MAX,
REMOUNT_ALWAYS, NOTIFY, LOG_DEBUG, USE_COLOR, KEEP_LINKS_ON_EXIT, LOCK_FILE,
PROBE_TIMEOUT, MOUNT_TIMEOUT, UNMOUNT_TIMEOUT, LIST_TIMEOUT, STAT_TIMEOUT.
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            --media-dir)  MEDIA_DIR=${2:-}; shift 2 ;;
            --schemes)    PHONE_SCHEMES=${2:-}; shift 2 ;;
            --resync)     RESYNC_INTERVAL=${2:-0}; shift 2 ;;
            --no-resync)  RESYNC_INTERVAL=0; shift ;;
            --remount-always) REMOUNT_ALWAYS=1; shift ;;
            --no-notify)  NOTIFY=0; shift ;;
            --keep-links) KEEP_LINKS_ON_EXIT=1; shift ;;
            --once)       RUN_ONCE=1; shift ;;
            --debug)      LOG_DEBUG=1; shift ;;
            --color)
                case ${2:-} in
                    always|yes|1) USE_COLOR=1 ;;
                    never|no|0)   USE_COLOR=0 ;;
                    *)            USE_COLOR=auto ;;
                esac
                shift 2 ;;
            -h|--help)    usage; exit 0 ;;
            -V|--version) printf '%s %s\n' "$APP_NAME" "$APP_VERSION"; exit 0 ;;
            *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
    done
    # Numeric settings must be numeric, or the arithmetic below would misbehave.
    local var
    for var in RESYNC_INTERVAL FAST_RESYNC_INTERVAL PENDING_WINDOW TICK_INTERVAL \
               MAX_PROBE_FAILURES MOUNT_RETRY_BASE MOUNT_RETRY_MAX \
               PROBE_TIMEOUT MOUNT_TIMEOUT UNMOUNT_TIMEOUT LIST_TIMEOUT STAT_TIMEOUT; do
        [[ ${!var} =~ ^[0-9]+$ ]] || {
            printf '%s must be a non-negative integer (got: %s)\n' "$var" "${!var}" >&2
            exit 2
        }
    done
    # A zero tick would turn the event loop into a busy wait.
    ((TICK_INTERVAL >= 1)) || TICK_INTERVAL=1
    ((MAX_PROBE_FAILURES >= 1)) || MAX_PROBE_FAILURES=1
    MEDIA_DIR=${MEDIA_DIR%/}
    GVFS_ROOT=${GVFS_ROOT%/}
    [[ -n $MEDIA_DIR && -n $GVFS_ROOT ]] || { printf 'media dir and gvfs root cannot be empty\n' >&2; exit 2; }
}

main() {
    parse_args "$@"
    setup_logging
    detect_notify_backend
    check_environment || exit 1
    acquire_lock || exit 1

    if ((RUN_ONCE)); then
        log_info "single reconcile pass"
        reconcile
        log_info "done"
        exit 0
    fi

    trap on_signal INT TERM HUP
    trap cleanup EXIT

    print_banner
    event_loop
}

# Only run when executed, so tests.sh can source this file and exercise the
# individual functions.
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    main "$@"
fi
