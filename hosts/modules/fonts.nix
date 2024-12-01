{ pkgs, ... }:
{
  fonts = {
    packages = with pkgs; [
      source-code-pro
      font-awesome
      nerd-fonts.fira-code
      nerd-fonts.droid-sans-mono
    ];
  };
}
