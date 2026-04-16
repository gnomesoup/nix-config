{ pkgs, ... }:
{
  fonts = {
    packages = with pkgs; [
      font-awesome
      nerd-fonts.sauce-code-pro
      nerd-fonts.fira-code
      nerd-fonts.droid-sans-mono
    ];
  };
}
