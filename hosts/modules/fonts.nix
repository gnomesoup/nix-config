{ pkgs, ... }:
{
  fonts = {
    fontDir.enable = true;
    fonts = with pkgs; [ source-code-pro font-awesome ];
  };
}