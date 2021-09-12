{ pkgs }:
{
  openssl-sys = {
    nativeBuildInputs = with pkgs; [
      pkg-config
    ];
    buildInputs = with pkgs; [
      openssl.dev
    ];
    propagatedBuildInputs = with pkgs; [
      openssl.out
    ];
  };
  #openssl = {
  #  nativeBuildInputs = with pkgs; [
  #    pkg-config
  #  ];
  #  buildInputs = with pkgs; [
  #    openssl.dev
  #  ];
  #};
} // (if pkgs.stdenv.isDarwin then let
  mkFrameworkOverride = f: let
    f_ = pkgs.darwin.apple_sdk.frameworks.${f};
  in {
    propagatedBuildInputs = [ f_ ];
    NIX_LDFLAGS = "-F ${f_}/Library/Frameworks";
  };
  mkLibOverride = l: {
    propagatedBuildInputs = [ l ];
    NIX_LDFLAGS = "-L ${l}/lib";
  };
in {
  security-framework-sys = mkFrameworkOverride "Security";
  core-foundation-sys = mkFrameworkOverride "CoreFoundation";
  pq-sys = mkLibOverride ((pkgs.postgresql.override {
    enableSystemd = false;
  }).lib);
} else {})
