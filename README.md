# phone-automounter

udiskie-style automounting for phones, built on `gio`/`gvfs`.

Plug a phone in, pick **File transfer** on the device, and it shows up as
`/media/<Phone>` — a plain folder path that works in every file manager,
terminal and script. Unplug it, lock it, or switch it back to charging-only and
the folder disappears again, exactly like a USB stick being pulled out.

```
  phone-automounter  v1.0.0 · udiskie-style phone mounting through gio/gvfs
  ────────────────────────────────────────────────────────────────────
  media dir   /media
  gvfs root   /run/user/1000/gvfs
  schemes     mtp, gphoto2, afc
  resync      30s watchdog, 3s while a device is pending
  notifies    notify-send
  ────────────────────────────────────────────────────────────────────

21:04:11 i info   device appeared: Nothing Phone (2a) (mtp://Nothing_A001_0019/)
21:04:11 i info   Nothing Phone (2a) is connected but not sharing storage yet — choose "File transfer" on the phone
21:04:19 ⇄ event  Volume changed: Nothing Phone (2a)
21:04:20 ✓ ok     Nothing Phone (2a) is available at /media/Nothing Phone (2a)
```

## Why

`gvfs` already knows how to talk to phones over MTP, PTP and AFC, and already
exposes them through its fuse daemon — but only under
`$XDG_RUNTIME_DIR/gvfs/mtp:host=…`, a path nothing outside a GTK file manager
wants to type. `udiskie` does the "plug it in and it appears in /media" part,
but only for block devices; a phone is not a block device.

This fills that gap: it watches gvfs for phone volumes, mounts them when they
become mountable, and publishes each one as a symlink in `/media`.

## What it actually does

1. You plug the phone in. Nothing appears yet — a phone on "charging only"
   exposes no storage, so there is nothing to show.
2. You pick **File transfer** (or **Photo transfer**) on the phone. It gets
   mounted through gvfs and appears as `/media/<Phone>`.
3. You use it like any other folder.
4. The cable comes loose, the phone locks, the mode changes, gvfs dies —
   `/media/<Phone>` disappears.
5. Plug it back in and it comes back.

If you eject the phone from a file manager while it is still plugged in, it
stays unmounted: that was a deliberate action, and fighting it would be
annoying. Reconnect the cable to get it back, or run with `--remount-always`.

Supported gvfs schemes: `mtp` (Android file transfer), `gphoto2` (PTP / photo
transfer, cameras) and `afc` (iPhone, iPad).

### Design

- **Event driven.** The only source of wake-ups is `gio mount --monitor`, which
  pushes volume and mount events over D-Bus with millisecond latency. No
  filesystem polling, no busy loop (measured idle cost: 0% CPU).
- **Reconciliation, not incremental state.** Every event re-reads the truth out
  of gvfs and makes `/media` match it. Missed, duplicated or out-of-order
  events therefore cannot desynchronise anything, which is what makes
  reconnect storms harmless.
- **A slow watchdog** (30s by default) exists only for state gvfs can change
  without emitting an event — the storage list appearing when you unlock the
  phone, for instance. While a device is pending it tightens to 3s, then backs
  off again.
- **Every call into gvfs is wrapped in a timeout.** A half-dead MTP backend is
  the classic way for a script like this to hang forever.
- **A busy phone is not a missing phone.** MTP serialises everything over one
  USB channel, so an unrelated listing can time out mid-copy. Only a listing
  that *succeeds and comes back empty* counts as evidence that the storage went
  away, so a large transfer never gets the folder yanked out from under it.

### It cannot delete anything on your phone

`/media` entries are **symlinks**, never directories. The only removal this
program ever performs is `unlink(1)` on a path that

- is a symlink (checked with `lstat`, never followed), **and**
- sits directly in `/media`, **and**
- whose *link text* names a gvfs mount **root** of a phone scheme — a link
  pointing anywhere *inside* a phone is rejected.

`unlink(1)` removes exactly one directory entry: it has no recursive mode and
does not dereference symlinks. There is no `rm` anywhere in `automounter.sh`,
and the test suite asserts that (along with no `rmdir`, no `find -delete` and
no `gio remove`/`gio trash`). Anything in `/media` that this program did not
create — including udiskie's real USB mount directories — is left alone.

## Install

Everything Nix lives in a single `flake.nix` at the repo root — the package, the
NixOS module and the dev shell are all defined there, there are no other `.nix`
files to copy or import. It exposes:

| Output | What it is |
| --- | --- |
| `nixosModules.default` | the `services.phone-automounter` user service |
| `packages.default` | the wrapped `phone-automounter` binary |
| `overlays.default` | adds `pkgs.phone-automounter` |
| `apps.default` | the `nix run` entry point |
| `devShells.default` | `nix develop` |
| `checks.<system>` | `tests.sh` and shellcheck, run by `nix flake check` |

### NixOS flake, as a service (recommended)

```nix
# flake.nix
{
  inputs.phone-automounter.url = "github:pillowbanana/phone-automounter";
  # optional, keeps the closure shared with your system nixpkgs:
  inputs.phone-automounter.inputs.nixpkgs.follows = "nixpkgs";
}
```

```nix
# configuration.nix
{
  imports = [ inputs.phone-automounter.nixosModules.default ];

  services.phone-automounter.enable = true;
}
```

That installs the `phone-automounter` command, enables `services.gvfs`, makes
`/media` group-writable (`root:users`, mode `0775`) and starts a **systemd user
service** for every logged-in user.

It is a user service on purpose: gvfs mounts live inside a user's session
(`$XDG_RUNTIME_DIR/gvfs`) and are not visible to root, so a system-wide daemon
would publish links nobody could follow.

```bash
systemctl --user status phone-automounter
journalctl --user -u phone-automounter -f
```

Options, all optional:

| Option | Default | Meaning |
| --- | --- | --- |
| `services.phone-automounter.enable` | `false` | Enable the user service. |
| `.package` | this flake's package | Package providing the binary. |
| `.mediaDir` | `"/media"` | Where the phone symlinks go. |
| `.manageMediaDir` | `true` | Create `mediaDir` as `root:users` `0775`. Turn off if you manage it yourself. |
| `.schemes` | `[ "mtp" "gphoto2" "afc" ]` | gvfs schemes treated as a phone. |
| `.resyncInterval` | `30` | Watchdog seconds; `0` = events only. |
| `.notify` | `true` | Desktop notifications on mount/unmount. |
| `.remountAlways` | `false` | Remount even after an explicit eject. |
| `.extraArgs` | `[ ]` | Extra CLI arguments, e.g. `[ "--debug" ]`. |
| `.environment` | `{ }` | Extra env vars, e.g. `{ PENDING_WINDOW = "300"; }`. |

### NixOS flake, just the package

```nix
environment.systemPackages = [
  inputs.phone-automounter.packages.${pkgs.system}.default
];
```

or through the overlay, which adds `pkgs.phone-automounter`:

```nix
nixpkgs.overlays = [ inputs.phone-automounter.overlays.default ];
```

Note that **`/media` is root-only on a stock NixOS**, and this runs as your
user. Either make it writable:

```nix
systemd.tmpfiles.rules = [ "d /media 0775 root users -" ];
```

or point it somewhere else with `--media-dir ~/phones`.

Running it yourself, without the module (`pkgs.phone-automounter` here comes
from the overlay above — use
`inputs.phone-automounter.packages.${pkgs.system}.default` if you skipped it):

```nix
systemd.user.services.phone-automounter = {
  wantedBy = [ "default.target" ];
  environment.DBUS_SESSION_BUS_ADDRESS = "unix:path=%t/bus";
  serviceConfig.ExecStart = "${pkgs.phone-automounter}/bin/phone-automounter";
  serviceConfig.Restart = "on-failure";
};
```

Home Manager works the same way: add the package to `home.packages` and define
the unit under `systemd.user.services`.

### Try it without installing

```bash
nix run github:pillowbanana/phone-automounter             # run the daemon
nix run github:pillowbanana/phone-automounter -- --once   # one pass, then exit
```

On a non-NixOS machine with Nix and flakes enabled, the same package can go
straight into your profile — gvfs and its fuse daemon then have to come from
the distro:

```bash
nix profile install github:pillowbanana/phone-automounter
```

### Without Nix

Nothing to build — it is one bash script.

```bash
git clone https://github.com/pillowbanana/phone-automounter
cd phone-automounter
./automounter.sh
```

Requirements: bash 4.2+, glib (`gio`, `gdbus`), gvfs **with its fuse daemon
running** (`gvfsd-fuse` is what gives a phone a real filesystem path), a D-Bus
session bus, coreutils, awk, and write permission on the media directory.
`notify-send` is used for notifications if present; otherwise `gdbus` does it,
and glib always ships that.

## Usage

```
Usage: phone-automounter [options]

  --media-dir DIR   where to publish the phone links    (default: /media)
  --schemes "a b"   gvfs schemes treated as phones      (default: mtp gphoto2 afc)
  --resync SECS     watchdog interval, 0 = events only  (default: 30)
  --no-resync       same as --resync 0
  --remount-always  mount a phone straight back even after it was ejected
  --no-notify       do not send desktop notifications
  --keep-links      leave the links in place on exit
  --once            reconcile once and exit (handy for testing)
  --debug           verbose logging
  --color WHEN      always | never | auto               (default: auto)
  -h, --help        this text
  -V, --version     print the version
```

Only one instance runs at a time (`flock` on
`$XDG_RUNTIME_DIR/phone-automounter.lock`); two of them fighting over the same
`/media` would be a mess.

### Environment variables

Every CLI option has an environment variable, plus a number of tunables that
have no flag:

| Variable | Default | Meaning |
| --- | --- | --- |
| `MEDIA_DIR` | `/media` | Where the links are published. |
| `GVFS_ROOT` | `$XDG_RUNTIME_DIR/gvfs` | The gvfs fuse root. |
| `PHONE_SCHEMES` | `mtp gphoto2 afc` | Schemes treated as a phone. |
| `RESYNC_INTERVAL` | `30` | Watchdog interval, seconds. `0` disables it. |
| `FAST_RESYNC_INTERVAL` | `3` | Watchdog while a device is pending. |
| `PENDING_WINDOW` | `150` | How long a device stays in the fast lane. |
| `DEBOUNCE` | `0.4` | Event coalescing window; gvfs emits bursts of 4–6. |
| `TICK_INTERVAL` | `1` | Max time blocked in `read`, so signals are prompt. |
| `MAX_PROBE_FAILURES` | `3` | Failed health probes before a link is torn down. |
| `MOUNT_RETRY_BASE` / `MOUNT_RETRY_MAX` | `4` / `120` | Mount retry backoff, seconds. |
| `PROBE_TIMEOUT` | `8` | Timeout for a liveness probe. |
| `MOUNT_TIMEOUT` | `25` | Timeout for `gio mount`. |
| `UNMOUNT_TIMEOUT` | `15` | Timeout for `gio mount -u`. |
| `LIST_TIMEOUT` | `10` | Timeout for `gio mount --list` / `gio list`. |
| `STAT_TIMEOUT` | `5` | Timeout for a `test -d` on the fuse path. |
| `REMOUNT_ALWAYS` | `0` | `1` = remount after an explicit eject. |
| `NOTIFY` / `NOTIFY_TIMEOUT` | `1` / `5000` | Desktop notifications, ms. |
| `LOG_DEBUG` | `0` | `1` = verbose. |
| `USE_COLOR` | `auto` | `auto` \| `1` \| `0`. `NO_COLOR` is honoured. |
| `KEEP_LINKS_ON_EXIT` | `0` | `1` = leave links behind on exit. |
| `LOCK_FILE` | `$XDG_RUNTIME_DIR/phone-automounter.lock` | Single-instance lock. |

### Naming

A link is named after the phone, sanitised for use as a directory entry:
`/media/Nothing Phone (2a)`. Two identical handsets get a stable discriminator
from their serial (`/media/A001-111111`), and a name that is taken by something
this program does not manage is never clobbered — it just moves on to the next
candidate.

## Development

```bash
nix develop          # bash, shellcheck, shfmt, glib, gvfs
./tests.sh           # 129 assertions, no hardware needed
nix build            # build the package — the test suite runs as its checkPhase
nix flake check      # the test suite + shellcheck, in a sandbox
nix fmt              # format flake.nix with nixfmt
```

`nix flake check` fails on shellcheck warnings and errors; style and info notes
are advisory. Two warnings are excluded as false positives, both documented in
`flake.nix`.

`tests.sh` builds a throwaway sandbox under `$TMPDIR` with a fake gvfs root
full of fake "phone files", stubs out everything that would talk to real
hardware, and then tries hard to make the program delete something it should
not. A regression in the removal guards shows up as a failing test instead of
as lost photos. It is also where the `gio mount --list -i` parser, the link
naming rules and the full reconcile loop are exercised.

The test suite sources `automounter.sh`, which is why the script guards its
entry point with `[[ ${BASH_SOURCE[0]} == "${0}" ]]`.

## Troubleshooting

**Nothing happens when I plug the phone in.** Check the phone first: it has to
be in File transfer / Photo transfer mode, unlocked, and the "Allow access"
prompt has to be accepted. Then check that gvfs sees it at all:

```bash
gio mount --list -i | grep -i mtp
```

If gvfs sees nothing, the problem is below this program — on NixOS make sure
`services.gvfs.enable = true;` and that `gvfsd-fuse` is running.

**It says the gvfs fuse root is missing.** `gvfsd-fuse` is not running. Without
it a phone has no filesystem path, so there is nothing to link to.

**It refuses to start: `/media` is not writable.** Expected on a stock NixOS —
see the `/media` note above, or use `--media-dir`.

**The folder is there but empty.** The phone stopped sharing its storage
(locked, or flipped back to charging). The watchdog notices within a few
seconds and removes the link.

**`another phone-automounter instance is already running`.** One is already
up — probably the user service. `systemctl --user stop phone-automounter`
first if you want to run one by hand.

Run with `--debug` for the full story, and `--once` to do a single
reconcile pass and exit.

## License

Public domain (Unlicense). See [LICENSE](LICENSE).
