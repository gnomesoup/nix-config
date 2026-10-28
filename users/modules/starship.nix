{
  config,
  lib,
  pkgs,
  ...
}:
let
  toml = pkgs.formats.toml { };
  wide = {

    "$schema" = "https://starship.rs/config-schema.json";
    # Each optional section owns its caps, so absent modules leave no arrows.
    format = lib.concatStrings [
      "[](color_yellow)$os$hostname[](fg:color_yellow bg:color_purple2)"
      "$username[](fg:color_purple2 bg:color_bg3)$directory[](color_bg3)"
      "( [](color_bg1)$git_branch$git_status[](color_bg1))"
      "( [](color_blue)$c$cpp$rust$golang$nodejs$php$java$kotlin$haskell$python[](color_blue))"
      "( [](color_bg1)$nix_shell$conda[](color_bg1))"
      "( [](color_purple2)$time[](color_purple2))"
      "$line_break$character"
    ];
    palette = "spacemacs";
    palettes.spacemacs = {
      color_fg0 = "#b2b2b2";
      color_fg1 = "#ffffff";
      color_fg2 = "#000000";
      color_bg1 = "#212026";
      color_bg2 = "#292b2E";
      color_bg3 = "#34323E";
      color_blue = "#4f97d7";
      color_aqua = "#2aa1ae";
      color_green = "#52AD70";
      color_orange = "#d1951d";
      color_purple = "#B888E2";
      color_purple2 = "#5D4D7A";
      color_red = "#e0211d";
      color_yellow = "#d1951d";
    };
    palettes.gruvbox_dark = {
      color_fg0 = "#fbf1c7";
      color_bg1 = "#3c3836";
      color_bg3 = "#665c54";
      color_blue = "#458588";
      color_aqua = "#689d6a";
      color_green = "#98971a";
      color_orange = "#d65d0e";
      color_purple = "#b16286";
      color_red = "#cc241d";
      color_yellow = "#d79921";
    };
    palettes.goldfish = {
      color_fg0 = "#E0E4CC";
      color_fg1 = "#000000";
      color_bg1 = "#3c3836";
      color_bg3 = "#665c54";
      color_blue = "#a7dbd8";
      color_aqua = "#69d2e7";
      color_green = "#f38630";
      color_orange = "#fa6900";
      color_purple = "#b16286";
      color_red = "#cc241d";
      color_yellow = "#f38630";
    };
    os.disabled = false;
    os.style = "bg:color_yellow fg:color_fg2";
    os.symbols = {
      Windows = "";
      Macos = "";
      Linux = "";
      NixOS = "";
      Arch = "󰣇";
    };
    hostname = {
      ssh_only = false;
      style = "bg:color_yellow fg:color_fg2";
      format = "[ $hostname ]($style)";
    };
    username = {
      show_always = true;
      style_user = "bg:color_purple2 fg:color_fg0";
      style_root = "bg:color_red fg:color_fg1";
      format = "[ $user ]($style)";
    };
    directory = {
      style = "bg:color_bg3 fg:color_purple";
      format = "[ $path ]($style)";
      truncation_length = 3;
      truncation_symbol = "…/";
      truncate_to_repo = false;
    };
    git_branch = {
      symbol = "";
      truncation_length = 24;
      truncation_symbol = "…";
      style = "bg:color_bg1";
      format = "[[ $symbol $branch ](fg:color_green bg:color_bg1)]($style)";
    };
    git_status = {
      style = "bg:color_bg1";
      format = "[[($all_status$ahead_behind )](fg:color_green bg:color_bg1)]($style)";
    };

    nodejs = {
      symbol = "";
      style = "bg:color_blue";
      format = "[[ $symbol( $version) ](fg:color_bg1 bg:color_blue)]($style)";
    };
    c = {
      symbol = " ";
      style = "bg:color_blue";
      format = "[[ $symbol( $version) ](fg:color_bg1 bg:color_blue)]($style)";
    };
    cpp = {
      symbol = "";
      style = "bg:color_blue";
      format = "[[ $symbol( $version) ](fg:color_bg1 bg:color_blue)]($style)";
      disabled = false;
    };
    rust = {
      symbol = "";
      style = "bg:color_blue";
      format = "[[ $symbol( $version) ](fg:color_bg1 bg:color_blue)]($style)";
    };
    golang = {
      symbol = "";
      style = "bg:color_blue";
      format = "[[ $symbol( $version) ](fg:color_bg1 bg:color_blue)]($style)";
    };
    php = {
      symbol = "";
      style = "bg:color_blue";
      format = "[[ $symbol( $version) ](fg:color_bg1 bg:color_blue)]($style)";
    };
    java = {
      symbol = " ";
      style = "bg:color_blue";
      format = "[[ $symbol( $version) ](fg:color_bg1 bg:color_blue)]($style)";
    };
    kotlin = {
      symbol = "";
      style = "bg:color_blue";
      format = "[[ $symbol( $version) ](fg:color_bg1 bg:color_blue)]($style)";
    };
    haskell = {
      symbol = "";
      style = "bg:color_blue";
      format = "[[ $symbol( $version) ](fg:color_bg1 bg:color_blue)]($style)";
    };
    python = {
      symbol = "";
      style = "bg:color_blue";
      format = "[[ $symbol( $version)( $virtualenv) ](fg:color_bg1 bg:color_blue)]($style)";
    };

    nix_shell = {
      symbol = "";
      style = "bg:color_bg1";
      format = "[[ $symbol( $name) ](fg:color_blue bg:color_bg1)]($style)";
    };
    conda = {
      style = "bg:color_bg1";
      format = "[[ $symbol( $environment) ](fg:color_blue bg:color_bg1)]($style)";
    };

    time = {
      disabled = false;
      time_format = "%R";
      style = "bg:color_purple2";
      format = "[[  $time ](fg:color_fg0 bg:color_purple2)]($style)";
    };

    line_break.disabled = false;

    character = {
      disabled = false;
      success_symbol = "[](bold fg:color_green)";
      error_symbol = "[](bold fg:color_red)";
      vimcmd_symbol = "[](bold fg:color_green)";
      vimcmd_replace_one_symbol = "[](bold fg:color_purple)";
      vimcmd_replace_symbol = "[](bold fg:color_purple)";
      vimcmd_visual_symbol = "[](bold fg:color_yellow)";
    };
  };
  compact = lib.recursiveUpdate wide {
    format = "($username$hostname\n)$directory$git_branch$git_status$nix_shell$conda$python$line_break$character";
    username = {
      show_always = false;
      style_user = "bold color_yellow";
      style_root = "bold color_red";
      format = "[$user]($style) ";
    };
    hostname = {
      ssh_only = true;
      style = "bold color_yellow";
      format = "[@$hostname]($style)";
    };
    directory = {
      style = "fg:color_purple bg:color_bg3";
      truncation_length = 2;
    };
    git_branch = {
      truncation_length = 16;
      format = "[ $symbol $branch](color_green)";
    };
    git_status.format = "[ $all_status$ahead_behind](color_green)";
    nix_shell.format = "[ $symbol( $name)](color_blue)";
    conda.format = "[ $symbol $environment](color_blue)";
    python.format = "[( $symbol $virtualenv)](color_blue)";
  };
  minimal = lib.recursiveUpdate compact {
    format = "($username$hostname\n)$directory$git_branch$git_status$line_break$character";
    directory = {
      style = "color_purple";
      format = "[$path]($style)";
      truncation_length = 1;
      truncation_symbol = "";
    };
    git_branch = {
      truncation_length = 10;
      format = "[ $branch](color_green)";
    };
  };
  compactFile = toml.generate "starship-compact.toml" compact;
  minimalFile = toml.generate "starship-minimal.toml" minimal;
in
{
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    settings = wide;
  };
  xdg.configFile = {
    "starship-compact.toml".source = compactFile;
    "starship-minimal.toml".source = minimalFile;
  };
  # Run after Home Manager's Starship init, preserving its status and Vim hooks.
  programs.zsh.initContent = lib.mkOrder 1100 ''
    if [[ $TERM != dumb ]]; then
      _inigo_starship_select() {
        typeset -g _inigo_starship_columns=$COLUMNS
        if (( COLUMNS < 70 )); then
          export STARSHIP_CONFIG=${lib.escapeShellArg (toString minimalFile)}
        elif (( COLUMNS < 110 )); then
          export STARSHIP_CONFIG=${lib.escapeShellArg (toString compactFile)}
        else
          export STARSHIP_CONFIG=${
            lib.escapeShellArg (toString config.home.file.${config.programs.starship.configPath}.source)
          }
        fi
      }

      _inigo_starship_resize() {
        if [[ $_inigo_starship_columns != $COLUMNS ]]; then
          _inigo_starship_select
          zle reset-prompt
        fi
      }

      autoload -Uz add-zsh-hook add-zle-hook-widget
      add-zsh-hook precmd _inigo_starship_select
      add-zle-hook-widget line-pre-redraw _inigo_starship_resize
      _inigo_starship_select
    fi
  '';
}
