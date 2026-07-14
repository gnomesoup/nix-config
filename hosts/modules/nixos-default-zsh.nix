{ lib, pkgs, ... }:

{
  programs.zsh.enable = lib.mkDefault true;
  environment.shells = lib.mkDefault [ pkgs.zsh ];
  users.defaultUserShell = lib.mkForce pkgs.zsh;
}
