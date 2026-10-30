#!/usr/bin/env bash
#
# tests.sh — safety and logic tests for automounter.sh
#
# The point of this file is the first group of tests: proving that nothing this
# program does can delete data on a phone.  Everything happens in a throwaway
# sandbox under $TMPDIR, with a fake "gvfs root" full of fake "phone files", so
# a regression in the removal guards shows up as a failing test instead of as
# lost photos.
#
# Run: ./tests.sh

set -o pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# Sourcing automounter.sh only defines its functions (it guards on BASH_SOURCE).
# shellcheck source=automounter.sh
source "$HERE/automounter.sh"

PASS=0; FAIL=0
SANDBOX=

ok()   { PASS=$((PASS + 1)); printf '  \e[32m✓\e[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \e[31m✗\e[0m %s\n' "$1"; }
group() { printf '\n\e[1m%s\e[0m\n' "$1"; }

assert_true()  { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
assert_false() { if "${@:2}"; then bad "$1"; else ok "$1"; fi; }
assert_eq() {
    local what=$1 want=$2 got=$3
    if [[ $want == "$got" ]]; then ok "$what"; else bad "$what (want '$want', got '$got')"; fi
}
assert_exists()  { if [[ -e $2 || -L $2 ]]; then ok "$1"; else bad "$1 ($2 is gone)"; fi; }
assert_missing() { if [[ -e $2 || -L $2 ]]; then bad "$1 ($2 still there)"; else ok "$1"; fi; }

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox: a fake /media and a fake gvfs fuse root holding "phone files"
# ─────────────────────────────────────────────────────────────────────────────

setup() {
    SANDBOX=$(mktemp -d -t automounter-tests-XXXXXX) || exit 1
    MEDIA_DIR="$SANDBOX/media"
    GVFS_ROOT="$SANDBOX/gvfs"
    PHONE_SCHEMES="mtp gphoto2 afc"
    LOG_DEBUG=0
    NOTIFY=0
    USE_COLOR=0
    setup_logging

    mkdir -p "$MEDIA_DIR"
    # Two fake phone mounts, each with precious data inside.
    PHONE_A="$GVFS_ROOT/mtp:host=Nothing_A001_0019235AU003966"
    PHONE_B="$GVFS_ROOT/mtp:host=Nothing_A001_0019235AU111111"
    SMB_MOUNT="$GVFS_ROOT/smb-share:server=nas,share=media"
    mkdir -p "$PHONE_A/DCIM/Camera" "$PHONE_B/DCIM/Camera" "$SMB_MOUNT"
    printf 'irreplaceable\n' > "$PHONE_A/DCIM/Camera/holiday.jpg"
    printf 'irreplaceable\n' > "$PHONE_B/DCIM/Camera/holiday.jpg"

    LINK_PATH=(); LINK_TARGET=(); DEV_NAME=(); VOL_NAME=(); MOUNT_NAME=()
}

teardown() {
    [[ -n $SANDBOX && -d $SANDBOX ]] || return 0
    chmod -R u+w "$SANDBOX" 2>/dev/null
    command rm -rf -- "$SANDBOX"
}
trap teardown EXIT

phone_data_intact() {
    [[ -f "$PHONE_A/DCIM/Camera/holiday.jpg" && -f "$PHONE_B/DCIM/Camera/holiday.jpg" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
group_deletion_safety() {
    group "Deletion safety — nothing on the phone may ever be removed"

    # 1. A real directory in /media (what udiskie creates for USB sticks).
    mkdir -p "$MEDIA_DIR/USB_STICK/important"
    printf 'data\n' > "$MEDIA_DIR/USB_STICK/important/file.txt"
    assert_false "refuses to remove a real directory in the media dir" \
        safe_remove_link "$MEDIA_DIR/USB_STICK"
    assert_exists "the real directory survived" "$MEDIA_DIR/USB_STICK/important/file.txt"

    # 2. A symlink pointing somewhere outside the gvfs root.
    ln -s "$SANDBOX" "$MEDIA_DIR/elsewhere"
    assert_false "refuses to remove a symlink pointing outside the gvfs root" \
        safe_remove_link "$MEDIA_DIR/elsewhere"
    assert_exists "that symlink survived" "$MEDIA_DIR/elsewhere"

    # 3. THE regression that cost data before: a link that points at a folder
    #    *inside* the phone rather than at the mount root.
    ln -s "$PHONE_A/DCIM" "$MEDIA_DIR/phone-dcim"
    assert_false "refuses to remove a link pointing inside the phone" \
        safe_remove_link "$MEDIA_DIR/phone-dcim"
    assert_exists "the in-phone link survived" "$MEDIA_DIR/phone-dcim"
    assert_exists "the phone folder it pointed at survived" "$PHONE_A/DCIM/Camera/holiday.jpg"

    # 4. A non-phone gvfs mount (an SMB share, say) is none of our business.
    ln -s "$SMB_MOUNT" "$MEDIA_DIR/nas"
    assert_false "refuses to remove a link to a non-phone gvfs mount" \
        safe_remove_link "$MEDIA_DIR/nas"
    assert_exists "the smb link survived" "$MEDIA_DIR/nas"

    # 5. Our own link, with the target changed behind our back.
    ln -s "$PHONE_A" "$MEDIA_DIR/A001"
    assert_false "refuses to remove when the link text is not what we wrote" \
        safe_remove_link "$MEDIA_DIR/A001" "$PHONE_B"
    assert_exists "the link survived the mismatch" "$MEDIA_DIR/A001"

    # 6. Paths outside the media dir, and traversal attempts.
    ln -s "$PHONE_A" "$SANDBOX/outside-link"
    assert_false "refuses a path outside the media dir" \
        safe_remove_link "$SANDBOX/outside-link"
    assert_exists "the outside link survived" "$SANDBOX/outside-link"
    assert_false "refuses a traversal path" \
        safe_remove_link "$MEDIA_DIR/../gvfs/mtp:host=Nothing_A001_0019235AU003966"
    assert_false "refuses an empty path" safe_remove_link ""
    assert_false "refuses the media dir itself" safe_remove_link "$MEDIA_DIR"
    assert_false "refuses a nested path" safe_remove_link "$MEDIA_DIR/a/b"

    # 7. The happy path: a correct link is removed, and only the link.
    assert_true "removes our own correct link" \
        safe_remove_link "$MEDIA_DIR/A001" "$PHONE_A"
    assert_missing "the link is gone" "$MEDIA_DIR/A001"
    assert_exists "the phone mount root is untouched" "$PHONE_A"
    assert_exists "the phone files are untouched" "$PHONE_A/DCIM/Camera/holiday.jpg"

    # 8. A dangling link into the gvfs root (the device went away) is removable.
    ln -s "$GVFS_ROOT/mtp:host=Gone_Phone_999" "$MEDIA_DIR/Gone"
    assert_true "removes a dangling phone link" safe_remove_link "$MEDIA_DIR/Gone"
    assert_missing "the dangling link is gone" "$MEDIA_DIR/Gone"

    # 9. Removing something that is already gone is not an error.
    assert_true "a missing path is a no-op" safe_remove_link "$MEDIA_DIR/never-existed"

    assert_true "all fake phone data is still intact" phone_data_intact

    # 10. There must be no recursive removal anywhere in the program.
    assert_false "automounter.sh contains no 'rm -r'" \
        grep -qE '(^|[^[:alnum:]_-])rm[[:space:]]+(-[a-zA-Z]*[rR])' "$HERE/automounter.sh"
    assert_false "automounter.sh never calls rmdir, find -delete or gio remove/trash" \
        grep -qE '(rmdir|find[^|]*-delete|gio[[:space:]]+(remove|trash))' "$HERE/automounter.sh"
}

group_target_validation() {
    group "target_is_managed — which link targets we may touch"

    assert_true  "a phone mount root is managed"       target_is_managed "$GVFS_ROOT/mtp:host=X"
    assert_true  "a gphoto2 mount root is managed"     target_is_managed "$GVFS_ROOT/gphoto2:host=%5Busb%3A001%2C006%5D"
    assert_true  "an afc mount root is managed"        target_is_managed "$GVFS_ROOT/afc:host=abcdef,port=3"
    assert_false "a path inside a phone is not"        target_is_managed "$GVFS_ROOT/mtp:host=X/DCIM"
    assert_false "a deep path inside a phone is not"   target_is_managed "$GVFS_ROOT/mtp:host=X/DCIM/Camera"
    assert_false "an smb mount is not"                 target_is_managed "$GVFS_ROOT/smb-share:server=nas"
    assert_false "the gvfs root itself is not"         target_is_managed "$GVFS_ROOT"
    assert_false "an unrelated absolute path is not"   target_is_managed "/home/someone/Pictures"
    assert_false "a relative path is not"              target_is_managed "mtp:host=X"
    assert_false "an empty target is not"              target_is_managed ""
    assert_false "a lookalike prefix is not"           target_is_managed "${GVFS_ROOT}-evil/mtp:host=X"
}

group_link_naming() {
    group "Naming — collisions, duplicates and awkward names"

    local uri_a="mtp://Nothing_A001_0019235AU003966/"
    local uri_b="mtp://Nothing_A001_0019235AU111111/"
    VOL_NAME[$uri_a]="A001"
    VOL_NAME[$uri_b]="A001"          # two identical handsets

    assert_eq "name comes from the volume label" "A001" "$(display_name_for "$uri_a")"

    local path_a path_b
    path_a=$(choose_link_path "$uri_a" "$PHONE_A")
    assert_eq "first phone gets the plain name" "$MEDIA_DIR/A001" "$path_a"
    create_link "$uri_a" "$PHONE_A" >/dev/null
    assert_eq "first link registered" "$MEDIA_DIR/A001" "${LINK_PATH[$uri_a]}"

    path_b=$(choose_link_path "$uri_b" "$PHONE_B")
    assert_false "second identical phone does not reuse the same path" \
        test "$path_b" = "$MEDIA_DIR/A001"
    create_link "$uri_b" "$PHONE_B" >/dev/null
    assert_eq "second link disambiguated by device id" "$MEDIA_DIR/A001-111111" "${LINK_PATH[$uri_b]}"
    assert_eq "second link points at the second phone" "$PHONE_B" "$(readlink "${LINK_PATH[$uri_b]}")"

    # A real directory squatting on the name must be stepped around, not over.
    local uri_c="mtp://Squatted_Phone_42/"
    VOL_NAME[$uri_c]="Squatter"
    mkdir -p "$MEDIA_DIR/Squatter"
    create_link "$uri_c" "$GVFS_ROOT/mtp:host=Squatted_Phone_42" >/dev/null
    assert_true "a real directory on the name is left alone" test -d "$MEDIA_DIR/Squatter"
    assert_false "and is not a symlink now" test -L "$MEDIA_DIR/Squatter"
    assert_eq "the device went to an alternative name" \
        "$MEDIA_DIR/Squatter-42" "${LINK_PATH[$uri_c]}"

    # Hostile / awkward labels.
    assert_eq "slashes are replaced"        "My_Phone"  "$(sanitise_name 'My/Phone')"
    assert_eq "newlines are flattened"      "My Phone"  "$(sanitise_name $'My\nPhone')"
    assert_eq "leading dots are dropped"    "hidden"    "$(sanitise_name '...hidden')"
    assert_eq "leading dashes are dropped"  "rf"        "$(sanitise_name '--rf')"
    assert_eq "whitespace is collapsed"     "A B"       "$(sanitise_name '  A    B  ')"
    assert_eq "an unlabelled device falls back to the host" \
        "Unlabelled_Phone_7" "$(display_name_for 'mtp://Unlabelled_Phone_7/')"
    assert_eq "a backend-only mount name is not used as a folder name" \
        "somehost" "$(MOUNT_NAME['mtp://somehost/']=mtp; display_name_for 'mtp://somehost/')"
}

group_uri_helpers() {
    group "URI and fuse-path helpers"

    assert_eq "scheme"              "mtp"        "$(uri_scheme 'mtp://host/')"
    assert_eq "host"                "host"       "$(uri_host 'mtp://host/')"
    assert_eq "host of a deep uri"  "host"       "$(uri_host 'mtp://host/storage/DCIM')"
    assert_eq "canonical adds one trailing slash" "mtp://host/" "$(uri_canonical 'mtp://host')"
    assert_eq "canonical keeps one trailing slash" "mtp://host/" "$(uri_canonical 'mtp://host/')"
    assert_eq "empty uri stays empty" "" "$(uri_canonical '')"
    assert_eq "percent decoding"    "[usb:001,006]" "$(percent_decode '%5Busb%3A001%2C006%5D')"
    assert_eq "short id from a serial" "003966" "$(short_id 'mtp://Nothing_A001_0019235AU003966/')"
    assert_eq "short id from a usb path" "001006" "$(short_id 'mtp://%5Busb%3A001%2C006%5D/')"

    assert_true  "mtp is a phone scheme"     is_phone_uri "mtp://x/"
    assert_true  "gphoto2 is a phone scheme" is_phone_uri "gphoto2://x/"
    assert_false "smb is not"                is_phone_uri "smb://x/"
    assert_false "sftp is not"               is_phone_uri "sftp://x/"

    assert_eq "direct fuse path lookup" "$PHONE_A" \
        "$(fuse_path_for_uri 'mtp://Nothing_A001_0019235AU003966/')"
    # Escaping mismatch: the URI is percent-encoded, the directory is not.
    mkdir -p "$GVFS_ROOT/gphoto2:host=%5Busb%3A001%2C006%5D"
    assert_eq "fuse path found through decoded-host comparison" \
        "$GVFS_ROOT/gphoto2:host=%5Busb%3A001%2C006%5D" \
        "$(fuse_path_for_uri 'gphoto2://%5Busb%3A001%2C006%5D/')"
    assert_false "unknown device has no fuse path" fuse_path_for_uri 'mtp://Not_Here_1/'
}

group_sweep() {
    group "sweep_unclaimed_links — only our leftovers are cleared"

    LINK_PATH=(); LINK_TARGET=()
    command rm -rf -- "$MEDIA_DIR"; mkdir -p "$MEDIA_DIR"

    mkdir -p "$MEDIA_DIR/USB_STICK"                       # udiskie's real mount
    printf 'x\n' > "$MEDIA_DIR/a-regular-file"
    ln -s "$SMB_MOUNT"      "$MEDIA_DIR/nas"              # foreign gvfs link
    ln -s /home             "$MEDIA_DIR/home-link"        # unrelated link
    ln -s "$PHONE_A/DCIM"   "$MEDIA_DIR/into-phone"       # dangerous shape
    ln -s "$PHONE_A"        "$MEDIA_DIR/leftover-A"       # ours, unclaimed
    ln -s "$PHONE_B"        "$MEDIA_DIR/claimed-B"        # ours, claimed
    LINK_PATH['mtp://Nothing_A001_0019235AU111111/']="$MEDIA_DIR/claimed-B"

    sweep_unclaimed_links "test" >/dev/null 2>&1

    assert_exists  "the USB mount directory is untouched" "$MEDIA_DIR/USB_STICK"
    assert_exists  "a regular file is untouched"          "$MEDIA_DIR/a-regular-file"
    assert_exists  "a foreign gvfs link is untouched"     "$MEDIA_DIR/nas"
    assert_exists  "an unrelated link is untouched"       "$MEDIA_DIR/home-link"
    assert_exists  "an into-the-phone link is untouched"  "$MEDIA_DIR/into-phone"
    assert_exists  "a claimed link is kept"               "$MEDIA_DIR/claimed-B"
    assert_missing "an unclaimed leftover is cleared"     "$MEDIA_DIR/leftover-A"
    assert_true    "phone data survived the sweep"        phone_data_intact
}

group_parser() {
    group "gio mount --list -i parser"

    local fixture
    fixture=$(cat <<'EOF'
Drive(0): Apacer AS2280P4 1TB
  Type: GProxyDrive (GProxyVolumeMonitorUDisks2)
  ids:
   unix-device: '/dev/nvme0n1'
  can_eject=0
Volume(0): A001
  Type: GProxyVolume (GProxyVolumeMonitorMTP)
  ids:
   unix-device: '/dev/bus/usb/001/006'
  activation_root=mtp://Nothing_A001_0019235AU003966/
  themed icons:  [phone]
  can_mount=1
  can_eject=0
  should_automount=1
  Mount(0): A001 -> mtp://Nothing_A001_0019235AU003966/
    Type: GProxyShadowMount (GProxyVolumeMonitorMTP)
    can_unmount=1
    is_shadowed=0
Volume(1): A001
  Type: GProxyVolume (GProxyVolumeMonitorMTP)
  ids:
   unix-device: '/dev/bus/usb/001/007'
  activation_root=mtp://Nothing_A001_0019235AU111111/
  can_mount=1
Volume(2): Backup -> Drive
  Type: GProxyVolume (GProxyVolumeMonitorUDisks2)
  activation_root=
  can_mount=1
Mount(1): mtp -> mtp://Nothing_A001_0019235AU003966/
  Type: GDaemonMount
  can_unmount=1
  is_shadowed=1
Mount(2): nas -> smb://nas/media/
  Type: GDaemonMount
EOF
)
    local out
    out=$(printf '%s\n' "$fixture" | awk "$GIO_LIST_PARSER")

    assert_eq "volume record for the first phone" \
        "V	A001	mtp://Nothing_A001_0019235AU003966/	GProxyVolume (GProxyVolumeMonitorMTP)	/dev/bus/usb/001/006	1" \
        "$(printf '%s\n' "$out" | grep -F 'AU003966/	GProxy')"
    assert_eq "both phone volumes are found" "3" \
        "$(printf '%s\n' "$out" | grep -c '^V')"
    assert_eq "mount lines are split on the last arrow" \
        "M	mtp	mtp://Nothing_A001_0019235AU003966/" \
        "$(printf '%s\n' "$out" | grep -F 'M	mtp	')"
    assert_eq "a name containing an arrow is kept whole" \
        "V	Backup -> Drive" \
        "$(printf '%s\n' "$out" | grep -F 'Backup -> Drive' | cut -f1,2)"

    # Now the same fixture through the state loader, which must keep only
    # phone schemes and must deduplicate the shadow/daemon mount pair.
    refresh_gvfs_state_from() {
        VOL_NAME=(); VOL_TYPE=(); VOL_DEV=(); VOL_CANMOUNT=()
        MOUNT_PRESENT=(); MOUNT_NAME=(); VOL_URIS=(); MOUNT_URIS=()
        local kind f2 f3 f4 f5 f6 uri
        while IFS=$'\t' read -r kind f2 f3 f4 f5 f6; do
            uri=$(uri_canonical "$f3"); [[ -n $uri ]] || continue
            is_phone_uri "$uri" || continue
            case $kind in
                V) [[ -z ${VOL_NAME[$uri]+x} ]] && VOL_URIS+=("$uri")
                   VOL_NAME[$uri]=$f2; VOL_TYPE[$uri]=$f4
                   VOL_DEV[$uri]=$f5;  VOL_CANMOUNT[$uri]=$f6 ;;
                M) if [[ -z ${MOUNT_PRESENT[$uri]:-} ]]; then
                       MOUNT_URIS+=("$uri"); MOUNT_PRESENT[$uri]=1; MOUNT_NAME[$uri]=$f2
                   fi ;;
            esac
        done < <(printf '%s\n' "$1" | awk "$GIO_LIST_PARSER")
    }
    refresh_gvfs_state_from "$fixture"

    assert_eq "only phone volumes are kept"            "2" "${#VOL_URIS[@]}"
    assert_eq "the shadow/daemon mount pair is one mount" "1" "${#MOUNT_URIS[@]}"
    assert_eq "the smb mount is ignored" "" "${MOUNT_PRESENT['smb://nas/media/']:-}"
    assert_eq "can_mount parsed" "1" "${VOL_CANMOUNT['mtp://Nothing_A001_0019235AU111111/']}"
    assert_eq "unix device parsed" "/dev/bus/usb/001/007" \
        "${VOL_DEV['mtp://Nothing_A001_0019235AU111111/']}"
}

group_monitor_lines() {
    group "Monitor line handling"

    assert_true  "the gio banner is recognised" is_monitor_banner "Monitoring events. Press Ctrl+C to quit."
    assert_true  "an empty line is ignored"     is_monitor_banner ""
    assert_false "a mount event is not a banner" is_monitor_banner "Mount added:        'A001'"
    assert_eq "events are tidied up for the log" \
        "Mount added: A001" "$(pretty_event "Mount added:        'A001'")"
    assert_eq "volume events too" \
        "Volume removed: Galaxy S9" "$(pretty_event "Volume removed:     'Galaxy S9'")"
}

# Everything below replaces the gvfs-facing functions with stubs, so the parts
# of the state machine that need real hardware events — a cable being pulled,
# gvfs keeping a mount after the device is gone — can be exercised.  Must run
# last, since the stubs stay in place.
group_reconcile() {
    group "Reconcile state machine (gvfs stubbed: covers unplugging)"

    local URI_A="mtp://Nothing_A001_0019235AU003966/"
    local URI_B="mtp://Nothing_A001_0019235AU111111/"

    STUB_VOLS=(); STUB_MOUNTS=(); STUB_STORAGE_STATE=ok; STUB_ALIVE=1
    MOUNT_CALLS=0; UNMOUNT_CALLS=0

    refresh_gvfs_state() {
        VOL_NAME=(); VOL_TYPE=(); VOL_DEV=(); VOL_CANMOUNT=()
        MOUNT_PRESENT=(); MOUNT_NAME=(); VOL_URIS=(); MOUNT_URIS=()
        local u
        for u in "${STUB_VOLS[@]}"; do
            VOL_URIS+=("$u"); VOL_NAME[$u]="A001"; VOL_CANMOUNT[$u]=1
        done
        for u in "${STUB_MOUNTS[@]}"; do
            MOUNT_URIS+=("$u"); MOUNT_PRESENT[$u]=1; MOUNT_NAME[$u]="mtp"
        done
        return 0
    }
    probe_alive()         { ((STUB_ALIVE)); }
    probe_storage_state() { printf '%s' "$STUB_STORAGE_STATE"; }
    probe_fuse_path()     { [[ -d $1 ]]; }
    mount_device()      { MOUNT_CALLS=$((MOUNT_CALLS + 1)); STUB_MOUNTS+=("$1"); return 0; }
    unmount_stale()     { UNMOUNT_CALLS=$((UNMOUNT_CALLS + 1)); STUB_MOUNTS=(); }
    notify()            { return 0; }

    reset_state() {
        LINK_PATH=(); LINK_TARGET=(); DEV_NAME=(); PROBE_FAILS=(); MOUNT_FAILS=()
        MOUNT_NEXT_TRY=(); PENDING_UNTIL=(); SEEN_VOLUME=(); WAS_PUBLISHED=()
        NOTIFIED_WAITING=(); SAID_ONCE=()
        command rm -rf -- "$MEDIA_DIR"; mkdir -p "$MEDIA_DIR"
        STUB_VOLS=(); STUB_MOUNTS=(); STUB_STORAGE_STATE=ok; STUB_ALIVE=1
        MOUNT_CALLS=0; UNMOUNT_CALLS=0
    }

    # --- plugged in and switched to File transfer -------------------------
    reset_state
    STUB_VOLS=("$URI_A")
    reconcile >/dev/null 2>&1
    assert_eq "an unmounted phone gets mounted once" "1" "$MOUNT_CALLS"
    assert_eq "and published in the media dir" "$MEDIA_DIR/A001" "${LINK_PATH[$URI_A]:-}"
    assert_exists "the symlink is there" "$MEDIA_DIR/A001"
    assert_eq "pointing at the phone's gvfs mount" "$PHONE_A" "$(readlink "$MEDIA_DIR/A001")"

    # --- a second reconcile must be a no-op -------------------------------
    reconcile >/dev/null 2>&1
    assert_eq "a repeat pass does not remount" "1" "$MOUNT_CALLS"
    assert_exists "and keeps the link" "$MEDIA_DIR/A001"

    # --- still on charging only: nothing may appear -----------------------
    reset_state
    STUB_VOLS=("$URI_A"); STUB_STORAGE_STATE=empty
    reconcile >/dev/null 2>&1
    assert_missing "a phone sharing no storage is not published" "$MEDIA_DIR/A001"
    assert_true "it is kept in the fast lane for a retry" has_pending_work

    # --- the device is busy and cannot answer: also not published --------
    reset_state
    STUB_VOLS=("$URI_A"); STUB_STORAGE_STATE=unknown
    reconcile >/dev/null 2>&1
    assert_missing "a phone that cannot answer is not published" "$MEDIA_DIR/A001"

    # --- it then gets switched to File transfer ---------------------------
    reset_state
    STUB_VOLS=("$URI_A"); STUB_STORAGE_STATE=empty
    reconcile >/dev/null 2>&1
    STUB_STORAGE_STATE=ok
    reconcile >/dev/null 2>&1
    assert_exists "it appears as soon as storage shows up" "$MEDIA_DIR/A001"
    assert_false "and leaves the fast lane" has_pending_work

    # --- THE unplug: volume and mount both vanish -------------------------
    reset_state
    STUB_VOLS=("$URI_A")
    reconcile >/dev/null 2>&1
    assert_exists "published before unplugging" "$MEDIA_DIR/A001"
    STUB_VOLS=(); STUB_MOUNTS=()
    reconcile >/dev/null 2>&1
    assert_missing "unplugging removes the link" "$MEDIA_DIR/A001"
    assert_eq "and forgets the device" "" "${LINK_PATH[$URI_A]:-}"
    assert_true "the phone's files are of course untouched" phone_data_intact

    # --- cable pulled but gvfs kept the mount (the inaccessible folder) ---
    reset_state
    STUB_VOLS=("$URI_A")
    reconcile >/dev/null 2>&1
    STUB_VOLS=()                       # hardware gone, mount still registered
    reconcile >/dev/null 2>&1
    assert_missing "a mount with no device behind it is unpublished" "$MEDIA_DIR/A001"
    assert_eq "and the stale gvfs mount is released" "1" "$UNMOUNT_CALLS"

    # --- a published mount quietly loses its storage -----------------------
    # Used to be invisible: the link stayed and the folder just looked empty.
    reset_state
    STUB_VOLS=("$URI_A")
    reconcile >/dev/null 2>&1
    assert_exists "published while sharing storage" "$MEDIA_DIR/A001"
    STUB_STORAGE_STATE=empty
    local i
    for ((i = 0; i < MAX_PROBE_FAILURES; i++)); do reconcile >/dev/null 2>&1; done
    assert_missing "a mount that loses its storage is unpublished" "$MEDIA_DIR/A001"
    assert_true "the phone's files are untouched" phone_data_intact

    # --- busy device: a probe that cannot answer must not unpublish --------
    # MTP serialises over one USB channel, so a big copy can stall a probe.
    reset_state
    STUB_VOLS=("$URI_A")
    reconcile >/dev/null 2>&1
    assert_exists "published before the transfer" "$MEDIA_DIR/A001"
    STUB_STORAGE_STATE=unknown
    for ((i = 0; i < MAX_PROBE_FAILURES + 2; i++)); do reconcile >/dev/null 2>&1; done
    assert_exists "stays published while the device is too busy to answer" "$MEDIA_DIR/A001"

    # --- but a wedged mount is still torn down ----------------------------
    STUB_ALIVE=0
    for ((i = 0; i < MAX_PROBE_FAILURES; i++)); do reconcile >/dev/null 2>&1; done
    assert_missing "a mount that stops responding is unpublished" "$MEDIA_DIR/A001"
    STUB_ALIVE=1

    # --- ejected from a file manager while still plugged in ---------------
    reset_state
    STUB_VOLS=("$URI_A")
    reconcile >/dev/null 2>&1
    assert_eq "mounted once" "1" "$MOUNT_CALLS"
    STUB_MOUNTS=()                     # user ejected it
    reconcile >/dev/null 2>&1
    assert_missing "ejecting removes the link" "$MEDIA_DIR/A001"
    assert_eq "and we do not fight the user by remounting" "1" "$MOUNT_CALLS"
    reconcile >/dev/null 2>&1
    assert_eq "still no remount on later passes" "1" "$MOUNT_CALLS"
    # ...unless asked to
    REMOUNT_ALWAYS=1
    reconcile >/dev/null 2>&1
    assert_eq "--remount-always mounts it straight back" "2" "$MOUNT_CALLS"
    assert_exists "and republishes it" "$MEDIA_DIR/A001"
    REMOUNT_ALWAYS=0

    # --- two phones, one unplugged ----------------------------------------
    reset_state
    STUB_VOLS=("$URI_A" "$URI_B")
    reconcile >/dev/null 2>&1
    assert_eq "both phones published" "2" "${#LINK_PATH[@]}"
    assert_exists "first phone link"  "$MEDIA_DIR/A001"
    assert_exists "second phone link" "$MEDIA_DIR/A001-111111"
    STUB_VOLS=("$URI_B"); STUB_MOUNTS=("$URI_B")
    reconcile >/dev/null 2>&1
    assert_missing "unplugging one removes only its link" "$MEDIA_DIR/A001"
    assert_exists "the other phone stays"                "$MEDIA_DIR/A001-111111"
    assert_true "both phones' data intact" phone_data_intact

    # --- gvfs unreachable: never tear anything down on a query failure ----
    reset_state
    STUB_VOLS=("$URI_A")
    reconcile >/dev/null 2>&1
    assert_exists "published" "$MEDIA_DIR/A001"
    refresh_gvfs_state() { return 1; }          # simulate gio/D-Bus failure
    reconcile >/dev/null 2>&1
    assert_exists "a failed gvfs query changes nothing" "$MEDIA_DIR/A001"
}

# ─────────────────────────────────────────────────────────────────────────────

printf '\n\e[1mautomounter.sh test suite\e[0m\n'
setup
group_deletion_safety
group_target_validation
group_link_naming
group_uri_helpers
group_sweep
group_parser
group_monitor_lines
group_reconcile     # must be last: it stubs out the gvfs-facing functions

printf '\n'
if ((FAIL == 0)); then
    printf '\e[32m%d passed, 0 failed\e[0m\n\n' "$PASS"
    exit 0
fi
printf '\e[31m%d passed, %d FAILED\e[0m\n\n' "$PASS" "$FAIL"
exit 1
