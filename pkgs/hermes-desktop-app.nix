{
  lib,
  stdenv,
  runCommand,
  writeText,
  writeShellScript,
  hermes-desktop,
}:
assert stdenv.hostPlatform.isDarwin;
let
  inherit (hermes-desktop) version;

  appName = "Hermes";
  bundleId = "com.nousresearch.hermes";

  infoPlist = writeText "Info.plist" (
    lib.concatStringsSep "\n" [
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
      "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
      "<plist version=\"1.0\">"
      "<dict>"
      "  <key>CFBundleDevelopmentRegion</key><string>en</string>"
      "  <key>CFBundleExecutable</key><string>${appName}</string>"
      "  <key>CFBundleIdentifier</key><string>${bundleId}</string>"
      "  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>"
      "  <key>CFBundleName</key><string>${appName}</string>"
      "  <key>CFBundleDisplayName</key><string>Hermes Desktop</string>"
      "  <key>CFBundlePackageType</key><string>APPL</string>"
      "  <key>CFBundleIconFile</key><string>icon.png</string>"
      "  <key>CFBundleShortVersionString</key><string>${version}</string>"
      "  <key>CFBundleVersion</key><string>${version}</string>"
      "  <key>NSHighResolutionCapable</key><true/>"
      "</dict>"
      "</plist>"
    ]
  );

  # The launcher delegates to the upstream wrapper, which already points
  # Electron at the renderer directory and exports HERMES_DESKTOP_HERMES.
  launcher = writeShellScript "Hermes" ''
    exec ${lib.getExe hermes-desktop} "$@"
  '';

  # Upstream installs the app icon on the Linux hicolor theme path. The build
  # fails loudly here if that path ever moves.
  icon = "${hermes-desktop}/share/icons/hicolor/1024x1024/apps/hermes.png";

  # `targets.darwin.linkApps` builds a buildEnv with
  # `pathsToLink = [ "/Applications" ]`, so the bundle must sit in an
  # `/Applications` subdirectory of `$out`, not at the top level.
  bundle = "$out/Applications/${appName}.app";
in
runCommand "hermes-desktop-app" { } ''
  mkdir -p "${bundle}/Contents/MacOS" "${bundle}/Contents/Resources"

  cp ${infoPlist} "${bundle}/Contents/Info.plist"
  cp ${launcher} "${bundle}/Contents/MacOS/${appName}"
  chmod +x "${bundle}/Contents/MacOS/${appName}"
  cp ${icon} "${bundle}/Contents/Resources/icon.png"

  # home-manager links `$out/Applications/*.app`; fail loudly if that
  # assumption breaks.
  test -d "${bundle}"
''
