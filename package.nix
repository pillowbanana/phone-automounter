{
  lib,
  stdenvNoCC,
  makeWrapper,
  bash,
  coreutils,
  gawk,
  glib,
  gnugrep,
  util-linux,
  libnotify,
  # notify-send is optional: without it the script falls back to gdbus, which
  # ships with glib.  Set to false for a slightly smaller closure.
  withLibnotify ? true,
}:

let
  # Everything automounter.sh shells out to.  gvfs itself is deliberately not
  # here: the fuse daemon is a system/session service, not something a CLI
  # wrapper should pull into its PATH.
  runtimeDeps = [
    coreutils # timeout, readlink, unlink, ln, sleep, test, id, install
    gawk # the gio mount --list parser
    glib # gio, gdbus
    gnugrep # gvfs_root_is_mounted
    util-linux # flock, for the single-instance lock
  ]
  ++ lib.optional withLibnotify libnotify;
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "phone-automounter";
  version = "1.0.0"; # keep in sync with APP_VERSION in automounter.sh

  src = ./.;

  strictDeps = true;
  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ bash ];

  dontConfigure = true;
  dontBuild = true;

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ${bash}/bin/bash tests.sh
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 automounter.sh "$out/bin/phone-automounter"
    patchShebangs "$out/bin/phone-automounter"
    wrapProgram "$out/bin/phone-automounter" \
      --prefix PATH : ${lib.makeBinPath runtimeDeps}

    install -Dm644 README.md -t "$out/share/doc/${finalAttrs.pname}"
    install -Dm644 LICENSE -t "$out/share/licenses/${finalAttrs.pname}"

    runHook postInstall
  '';

  meta = {
    description = "udiskie-style automounting for phones, built on gio/gvfs";
    longDescription = ''
      Watches gio/gvfs for phone volumes (MTP, PTP/gphoto2 and AFC), mounts them
      as soon as the device actually shares storage, and publishes each one as a
      symlink in /media.  The links disappear again when the phone is unplugged,
      locked, or switched back to charging-only mode.
    '';
    homepage = "https://github.com/pillowbanana/phone-automounter";
    license = lib.licenses.unlicense;
    mainProgram = "phone-automounter";
    platforms = lib.platforms.linux;
  };
})
