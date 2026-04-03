{ pkgs, ... }:
{
  imports = [
    ./modules/mpfammatter-base.nix
    ./modules/zsh.nix
    ./modules/wezterm.nix
  ];
}
