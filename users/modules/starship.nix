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
    # Preserve the original wide prompt, including its connected ribbon.
    format = ''
      [](color_yellow)$os$hostname[](fg:color_yellow bg:color_purple2)$username[](fg:color_purple2 bg:color_bg3)$directory[](fg:color_bg3 bg:color_bg1)$git_branch$git_status[](fg:color_bg1 bg:color_blue)$c$cpp$rust$golang$nodejs$php$java$kotlin$haskell$python[](fg:color_blue bg:color_bg1)$nix_shell$conda[](fg:color_bg1 bg:color_purple2)$time[ ](fg:color_purple2)$line_break$character
    '';
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
    };
    git_branch = {
      symbol = "";
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
  noTime = lib.recursiveUpdate wide {
    time.disabled = true;
  };
  noUsername = lib.recursiveUpdate noTime {
    # Retain the purple slot and its arrows, including root's red styling.
    username.format = "[ ]($style)";
  };
  pathBelow = noUsername // {
    # Move only the path; leave every other module and colored arrow in place.
    format =
      lib.replaceStrings
        [ "$directory" "$line_break$character" ]
        [ "[ ](bg:color_bg3 fg:color_purple)" "$line_break$directory$line_break$character" ]
        noUsername.format;
  };
  noTimeFile = toml.generate "starship-no-time.toml" noTime;
  noUsernameFile = toml.generate "starship-no-username.toml" noUsername;
  pathBelowFile = toml.generate "starship-path-below.toml" pathBelow;
in
{
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    settings = wide;
  };
  xdg.configFile = {
    "starship-no-time.toml".source = noTimeFile;
    "starship-no-username.toml".source = noUsernameFile;
    "starship-path-below.toml".source = pathBelowFile;
  };
  # Run after Home Manager's Starship init, preserving its status and Vim hooks.
  programs.zsh.initContent = lib.mkOrder 1100 ''
    if [[ $TERM != dumb ]]; then
      _inigo_starship_fits() {
        emulate -L zsh
        # Prompt expansion counts terminal cells and ignores Starship's ANSI
        # escapes. Disable substitution so prompt text cannot execute commands.
        unsetopt promptsubst
        local -i limit=$COLUMNS
        # The %l conditional counts from the latest automatic wrap. Measure in
        # a local virtual terminal wider than the text, against the real limit.
        local -i COLUMNS=$(( ''${#1} * 2 + limit + 1 ))
        local line check
        for line in "''${(@f)1}"; do
          check="$line%''${limit}(l.overflow.fits)"
          if [[ ''${(%)check} == *overflow ]]; then
            return 1
          fi
        done
        return 0
      }

      _inigo_starship_select() {
        typeset -g _inigo_starship_columns=$COLUMNS
        local -a layouts=(full no-time no-username path-below)
        local -a files=(
          ${lib.escapeShellArg (
            toString config.home.file.${config.programs.starship.configPath}.source
          )}
          ${lib.escapeShellArg (toString noTimeFile)}
          ${lib.escapeShellArg (toString noUsernameFile)}
          ${lib.escapeShellArg (toString pathBelowFile)}
        )
        typeset -g _inigo_starship_layout=full
        export STARSHIP_CONFIG="''${files[1]}"
        (( COLUMNS > 0 )) || return 0
        local -i index
        local rendered
        # Measure actual content, not guessed breakpoints. Reserve the last
        # column to avoid the terminal's automatic end-of-line wrap.
        for index in 1 2 3; do
          rendered=$(STARSHIP_CONFIG="''${files[index]}" ${lib.getExe config.programs.starship.package} prompt \
            --terminal-width="$COLUMNS" --keymap="''${KEYMAP:-viins}" \
            --status="''${STARSHIP_CMD_STATUS:-0}" --pipestatus="''${STARSHIP_PIPE_STATUS[*]:-}" \
            --cmd-duration="''${STARSHIP_DURATION:-}" --jobs="''${STARSHIP_JOBS_COUNT:-0}") || return 0
          if _inigo_starship_fits "$rendered"; then
            export STARSHIP_CONFIG="''${files[index]}"
            typeset -g _inigo_starship_layout="''${layouts[index]}"
            return 0
          fi
        done
        export STARSHIP_CONFIG="''${files[4]}"
        typeset -g _inigo_starship_layout=path-below
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
