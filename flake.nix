{
  description = "Build Rust applications in Nix. Pure Nix, no generated files, crates are isolated, reusing existing rustc/cargo machinery.";

  outputs = { self, nixpkgs }:
  let
    forAllSystems = nixpkgs.lib.genAttrs [ "aarch64-linux" "aarch64-darwin" "i686-linux" "x86_64-darwin" "x86_64-linux" ];
  in {
    lib = forAllSystems (system: nixpkgs.legacyPackages.${system}.callPackage ./default.nix { });
  };
}
