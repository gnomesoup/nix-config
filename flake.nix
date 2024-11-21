{
  description = "One flake to rule them all";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/0.1";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    nixvim = {
      url = "github:nix-community/nixvim";
      # If using a stable channel you can use `url = "github:nix-community/nixvim/nixos-<version>"`
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
      nixvim,
      determinate,
      # kmonad,
    }:
    {
      # Build nixos flake using:
      # $ nixos-rebuild build --flake .#<ComputerName>
      nixosConfigurations = {
        "hoth" = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./hosts/hoth
            sops-nix.nixosModules.sops
            nixvim.nixosModules.nixvim
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.mpfammatter = import ./users/mpfammatter.nix;
              home-manager.backupFileExtension = "backup";
            }
          ];
        };
        "nixvm" = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./hosts/nixvm
            sops-nix.nixosModules.sops
            nixvim.nixosModules.nixvim
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.mpfammatter = import ./users/mpfammatter.nix;
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
            nixvim.nixDarwinModules.nixvim
            home-manager.darwinModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
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
            determinate.darwinModules.default
            ./hosts/Coruscant
            nixvim.nixDarwinModules.nixvim
            home-manager.darwinModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
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
            determinate.darwinModules.default
            ./hosts/exegol
            nixvim.nixDarwinModules.nixvim
            home-manager.darwinModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
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
