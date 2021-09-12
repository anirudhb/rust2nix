# rust2nix

Build Rust applications in Nix. Pure Nix, no generated files, crates are isolated, reusing existing rustc/cargo machinery.

There are already many amazing tools out there that try to achieve this same goal, such as naersk, cargo2nix, crate2nix and carnix.
However, rust2nix does it better because unlike naersk, each crate is isolated (allowing them to be reused cross-project),
and it's written in pure Nix without any generated files (unlike the other options.)

Now here’s the one handicap (which I don’t really see as a big issue):
It adds like 10 seconds to Nix evaluation time to find crates that are already built.

## Usage

### Example (flake)

```nix
{
  description = "A very basic flake using rust2nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils"; # Not required, but nice to have
    rust2nix = {
      url = "github:anirudhb/rust2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Fenix provides a nightly version of Rust, which rust2nix currently requires
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, fenix, rust2nix }: flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      fenixPkgs = fenix.packages.${system};
      rust = fenixPkgs.combine [
        fenixPkgs.latest.rustc
        fenixPkgs.latest.cargo
      ];
      rust2nixLib = rust2nix.lib.${system};
    in rec {
      # mkRustApp is the primary entry-point to rust2nix
      packages.myApp = rust2nixLib.mkRustApp {
        # Recommended to be your Cargo crate name
        # rust2nix will eventually support automatically reading it from Cargo.toml
        pname = "my-app";
        src = ./.;
        cargo = rust;
        rustc = rust;
      };
      defaultPackage = packages.myApp;

      # Not rust2nix-specific
      apps.myApp = flake-utils.lib.mkApp {
        drv = packages.myApp;
      };
      defaultApp = apps.myApp;
    });
}
```

### Example (non-flake)

TODO, I don't currently use this without flakes.
It should be about the same as using with flakes, just use `fetchFromGitHub`.

### API

To be documented once it's more stable.

For now, there is only `mkRustApp`, which accepts the parameters shown in the examples, and anything else is forwarded to `mkDerivation`.

