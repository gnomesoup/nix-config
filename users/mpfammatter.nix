{ pkgs, ... }:
{
  imports = [
    ./modules/mpfammatter-base.nix
    ./modules/vimBindingKeyboardLayout.nix
    ./modules/nixvim.nix
    ./modules/zsh.nix
    ./modules/wezterm.nix
  ];
}
