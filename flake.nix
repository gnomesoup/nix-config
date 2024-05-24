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
  };

  outputs = inputs@{ self, nix-darwin, nixpkgs, home-manager, sops-nix }: {
    # Build nixos flake using:
    # $ nixos-rebuild build --flake .#<ComputerName>
    nixosConfigurations."hoth" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/hoth
        home-manager.nixosModules.home-manager {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.test = import ./users/mpfammatter.nix;
        }
      ];
    };

    # Build darwin flake using:
    # $ darwin-rebuild build --flake .#Tests-Virtual-Machine
    darwinConfigurations = {
      "Tests-Virtual-Machine" = nix-darwin.lib.darwinSystem {
        specialArgs = { inherit self;};
        modules = [
          ./hosts/Tests-Virtual-Machine
          home-manager.darwinModules.home-manager {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.test = import ./users/test.nix;
          }
        ];
      };

      "Coruscant" = nix-darwin.lib.darwinSystem {
        specialArgs = { inherit self;};
        modules = [
          ./hosts/Coruscant
          home-manager.darwinModules.home-manager {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.mpfammatter = import ./users/mpfammatter.nix;
            home-manager.backupFileExtension = "backup";
          }
        ];
      };
    };

    # Expose the package set, including overlays, for convenience.
    darwinPackages = self.darwinConfigurations."Tests-Virtual-Machine".pkgs;
    
  };
}
