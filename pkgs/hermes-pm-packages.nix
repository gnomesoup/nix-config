{
  autoPatchelfHook,
  hermesPackages,
  lib,
  patchelf,
  stdenv,
}:

lib.mapAttrs' (
  name: package:
  lib.nameValuePair (lib.removePrefix "pm-" name) (
    if stdenv.hostPlatform.isDarwin then
      # Upstream's Linux ELF fixups must not run on the pinned Mach-O artifacts.
      package.overrideAttrs (old: {
        nativeBuildInputs = builtins.filter (input: input != autoPatchelfHook && input != patchelf) (
          old.nativeBuildInputs or [ ]
        );
        postFixup = "";
      })
    else if stdenv.hostPlatform.isLinux && name == "pm-node" then
      # patchelf 0.19.2 header sorting makes pinned Node 26 segfault at startup.
      # Preserve header order while still fixing its interpreter and libraries.
      package.overrideAttrs (old: {
        patchelfFlags = (old.patchelfFlags or [ ]) ++ [ "--no-sort" ];
      })
    else
      package
  )
) (lib.filterAttrs (name: _: lib.hasPrefix "pm-" name) hermesPackages)
