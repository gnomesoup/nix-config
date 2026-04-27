{
  description = "One flake to rule them all";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    kickstart-nixvim = {
      url = "github:JMartJonesy/kickstart.nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # kmonad = {
    #   url = "git+https://github.com/kmonad/kmonad?submodules=1&dir=nix";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
  };
  outputs =
    inputs@{
      self,
      nix-darwin,
      nixpkgs,
      home-manager,
      sops-nix,
      kickstart-nixvim,
      nixos-wsl, # kmonad,
    }:
    let
      # Keep local package additions in an overlay so every consumer of pkgs
      # (standalone Home Manager, NixOS, and nix-darwin) resolves the same
      # package set. We use this for pi-coding-agent because it is packaged in
      # this repo and needs to be available consistently across hosts without
      # duplicating package wiring in each configuration.
      overlays.default = final: prev: {
        pi-coding-agent = final.callPackage ./pkgs/pi-coding-agent.nix { };
      };

      supportedSystems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      mkPkgs = system: import nixpkgs {
        inherit system;
        overlays = [ overlays.default ];
      };
    in
    {
      inherit overlays;

      formatter = forAllSystems (system: (mkPkgs system).nixfmt);

      packages.x86_64-linux.pi-coding-agent = (mkPkgs "x86_64-linux").pi-coding-agent;

      homeConfigurations = {
        "mpfammatter-linux" = home-manager.lib.homeManagerConfiguration {
          pkgs = mkPkgs "x86_64-linux";
          modules = [
            sops-nix.homeManagerModules.sops
            kickstart-nixvim.homeManagerModules.default
            ./users/mpfammatter.nix
          ];
        };
      };

      # Build nixos flake using:
      # $ nixos-rebuild build --flake .#<ComputerName>
      nixosConfigurations = {
        "hoth" = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./hosts/hoth
            sops-nix.nixosModules.sops
            home-manager.nixosModules.home-manager
            {
              nixpkgs.overlays = [ overlays.default ];
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.sharedModules = [
                sops-nix.homeManagerModules.sops
                kickstart-nixvim.homeManagerModules.default
              ];
              home-manager.users.mpfammatter = import ./users/mpfammatter.nix;
              home-manager.backupFileExtension = "backup";
            }
          ];
        };
        "ferrix" = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./hosts/ferrix
            sops-nix.nixosModules.sops
            home-manager.nixosModules.home-manager
            {
              nixpkgs.overlays = [ overlays.default ];
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.sharedModules = [
                sops-nix.homeManagerModules.sops
                kickstart-nixvim.homeManagerModules.default
              ];
              home-manager.users.mpfammatter =
                { pkgs, ... }:
                {
                  imports = [ ./users/mpfammatter-ui.nix ];
                  home.packages = [
                    pkgs.openclaw
                    pkgs.rustdesk
                  ];
                };
              home-manager.backupFileExtension = "backup";
            }
          ];
        };
        "nixvm" = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./hosts/nixvm
            sops-nix.nixosModules.sops
            home-manager.nixosModules.home-manager
            {
              nixpkgs.overlays = [ overlays.default ];
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.sharedModules = [
                sops-nix.homeManagerModules.sops
                kickstart-nixvim.homeManagerModules.default
              ];
              home-manager.users.mpfammatter = import ./users/mpfammatter.nix;
              home-manager.backupFileExtension = "backup";
            }
          ];
        };
      };

      nixosConfigurations = {
        "jedha" = nixpkgs.lib.nixosSystem {
          specialArgs = { inherit nixos-wsl; };
          system = "x86_64-linux";
          modules = [
            ./hosts/jedha
            home-manager.nixosModules.home-manager
            {
              nixpkgs.overlays = [ overlays.default ];
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.sharedModules = [
                kickstart-nixvim.homeManagerModules.default
              ];
              home-manager.users.mpfammatter = import ./users/jedha.nix;
              home-manager.backupFileExtension = "backup";
            }
          ];
        };
      };

      # Build darwin flake using:
      # $ darwin-rebuild build --flake .#Tests-Virtual-Machine
      darwinConfigurations = {
        "Tests-Virtual-Machine" = nix-darwin.lib.darwinSystem {
          specialArgs = {
            inherit self;
          };
          modules = [
            ./hosts/Tests-Virtual-Machine
            home-manager.darwinModules.home-manager
            {
              nixpkgs.overlays = [ overlays.default ];
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.sharedModules = [
                sops-nix.homeManagerModules.sops
                kickstart-nixvim.homeManagerModules.default
              ];
              home-manager.users.test = import ./users/test.nix;
              home-manager.backupFileExtension = "backup";
            }
          ];
        };

        "Coruscant" = nix-darwin.lib.darwinSystem {
          specialArgs = {
            inherit self;
          };
          modules = [
            ./hosts/Coruscant
            home-manager.darwinModules.home-manager
            {
              nixpkgs.overlays = [ overlays.default ];
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.sharedModules = [
                sops-nix.homeManagerModules.sops
                kickstart-nixvim.homeManagerModules.default
              ];
              home-manager.users.mpfammatter = import ./users/mpfammatter-ui.nix;
              home-manager.backupFileExtension = "backup";
            }
          ];
        };

        "exegol" = nix-darwin.lib.darwinSystem {
          specialArgs = {
            inherit self;
          };
          modules = [
            ./hosts/exegol
            home-manager.darwinModules.home-manager
            {
              nixpkgs.overlays = [ overlays.default ];
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.sharedModules = [
                sops-nix.homeManagerModules.sops
                kickstart-nixvim.homeManagerModules.default
              ];
              home-manager.users.mpfammatter = import ./users/mpfammatter-ui.nix;
              home-manager.backupFileExtension = "backup";
            }
          ];
        };
      };

      # Expose the package set, including overlays, for convenience.
      darwinPackages = self.darwinConfigurations."Tests-Virtual-Machine".pkgs;
    };
}
