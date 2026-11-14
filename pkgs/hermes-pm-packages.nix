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
    else if stdenv.hostPlatform.isLinux then
      package.overrideAttrs (old: {
        # Upstream's 0.19.2-specific patch does not apply to nixpkgs' 0.15.2.
        # Use the unpatched tool on older versions for every pinned runtime.
        nativeBuildInputs = map (
          input:
          if (input.pname or "") == "patchelf" && lib.versionOlder patchelf.version "0.19" then
            patchelf
          else
            input
        ) (old.nativeBuildInputs or [ ]);
        # Preserve Node's header order while fixing its interpreter/libraries.
        patchelfFlags = (old.patchelfFlags or [ ]) ++ lib.optional (name == "pm-node") "--no-sort";
      })
    else
      package
  )
) (lib.filterAttrs (name: _: lib.hasPrefix "pm-" name) hermesPackages)
