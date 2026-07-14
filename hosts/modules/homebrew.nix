{ config, ... }:

{
  environment.systemPath = [
    "${config.homebrew.prefix}/bin"
    "${config.homebrew.prefix}/sbin"
  ];

  homebrew = {
    enable = true;
    casks = [
      "1password"
      "microsoft-outlook"
      "microsoft-teams"
      "chromium"
      "espanso"
      "gimp"
      "nextcloud"
      "rustdesk"
      "vorta"
      "raspberry-pi-imager"
      "calibre"
    ];
  };
}
