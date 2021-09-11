{ pkgs }:
let
  mkRustApp = import ./rust2nix.nix { inherit pkgs; };
in {
  inherit mkRustApp;
}
