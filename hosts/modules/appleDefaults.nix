{ config, lib, ... }:

let
  homeManagerApps = "/Users/${config.system.primaryUser}/Applications/Home Manager Apps";
in
{
  system = {
    defaults.NSGlobalDomain = {
      KeyRepeat = 2;
      InitialKeyRepeat = 12;
      ApplePressAndHoldEnabled = false;
      AppleICUForce24HourTime = true;
    };
    defaults.dock.persistent-apps = [
      "/Applications/Firefox.app"
      "/Applications/Chromium.app"
      "/System/Applications/Messages.app"
      "/System/Applications/Maps.app"
      "/System/Applications/Photos.app"
      "/System/Applications/Reminders.app"
      "/System/Applications/Calendar.app"
      "/System/Applications/Contacts.app"
      "/System/Applications/System Settings.app"
      "/System/Applications/iPhone Mirroring.app"
      "/Applications/1Password.app"
      "/Applications/Windows App.app"
      "/Applications/Microsoft Teams.app"
      "/Applications/Microsoft Outlook.app"
      "${homeManagerApps}/WezTerm.app"
    ]
    ++ lib.optionals (config.system.primaryUser == "mpfammatter") [
      "${homeManagerApps}/Logseq.app"
    ];
  };
}
