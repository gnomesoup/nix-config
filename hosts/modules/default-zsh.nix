{
  config,
  lib,
  pkgs,
  ...
}:

let
  primaryUser = config.system.primaryUser;
  hasPrimaryUser = primaryUser != null && primaryUser != "";
  userRecord = lib.optionalString hasPrimaryUser "/Users/${primaryUser}";
  zshPath = "/run/current-system/sw${pkgs.zsh.shellPath}";
in
{
  programs.zsh.enable = true;
  environment.shells = [ pkgs.zsh ];

  users.users = lib.mkIf hasPrimaryUser {
    ${primaryUser}.shell = pkgs.zsh;
  };

  # nix-darwin only updates existing account shells for users listed in
  # users.knownUsers. Keep the admin account unmanaged, but still converge its
  # login shell to the Nix-managed zsh during activation.
  system.activationScripts.postActivation.text = lib.mkIf hasPrimaryUser (
    lib.mkAfter ''
      if /usr/bin/id -u ${lib.escapeShellArg primaryUser} >/dev/null 2>&1; then
        currentShell=$(/usr/bin/dscl . -read ${lib.escapeShellArg userRecord} UserShell 2>/dev/null | /usr/bin/awk '{print $2}')
        if [ "$currentShell" != ${lib.escapeShellArg zshPath} ]; then
          echo "setting ${primaryUser}'s login shell to ${zshPath}..." >&2
          /usr/bin/dscl . -create ${lib.escapeShellArg userRecord} UserShell ${lib.escapeShellArg zshPath}
        fi
      fi
    ''
  );
}
