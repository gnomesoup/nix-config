{ pkgs, ... }:
{
  imports = [
    ./modules/mpfammatter-base.nix
    ./modules/vimBindingKeyboardLayout.nix
    ./modules/nixvim.nix
    ./modules/ssh.nix
    ./modules/zsh.nix
    ./modules/wezterm.nix
    ./modules/wezterm-colors.nix
  ];
}
