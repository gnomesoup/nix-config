{ pkgs, ... }:
{
  imports = [
    ./modules/mpfammatter-base.nix
    ./modules/nixvim.nix
    ./modules/zsh.nix
    ./modules/wezterm.nix
  ];
}
