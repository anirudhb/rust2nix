{ pkgs }:
{ cargo, rustc, pname, src, ... }@args_:
let
  args = builtins.removeAttrs args_ [ "cargo" "rustc" "pname" "src" ];
  lib = pkgs.lib;
  overrides = pkgs.callPackage ./overrides.nix {};
  mkHostTriple = import ./lib/host-triple.nix {};
  #fenix = import (fetchTarball "https://github.com/nix-community/fenix/archive/main.tar.gz") {};

  #pname = "cargo_nixify";
  #toolchain = fenix.stable.defaultToolchain;
  #cargo = toolchain;
  #rustc = toolchain;
  rawDeps = (builtins.fromTOML (builtins.readFile (src + "/Cargo.lock"))).package; rawDeps' = builtins.filter (p: builtins.hasAttr "source" p) rawDeps;
  # FIXME: non crates.io sources
  fetchPackage = name: version: sha256: builtins.fetchurl {
    name = "download-${name}-${version}";
    url = "https://crates.io/api/v1/crates/${name}/${version}/download"; inherit sha256; };
  unpackPackage = name: version: sha256:
    let
      crate = fetchPackage name version sha256;
    in
      pkgs.runCommand "unpack-${name}-${version}" { preferLocalBuild = true; allowSubstitutes = false; } ''
        mkdir -p $out
        tar -xzf ${crate} --strip-components=1 -C $out
      '';
  vendorPackage = name: version: sha256:
    let
      crate = fetchPackage name version sha256; in pkgs.runCommand "vendor-${name}-${version}" { preferLocalBuild = true; allowSubstitutes = false; } ''
        mkdir -p $out
        tar -xzf ${crate} -C $out
        echo '{"package":"${sha256}","files":{}}' > $out/${name}-${version}/.cargo-checksum.json
      '';
  mkCratesIo = deps: symlinkJoinPassViaFile {
    name = "crates-io";
    paths = deps;
  };
  mkCargoConfig = deps:
    let
      crates-io = mkCratesIo deps;
    in
      pkgs.writeText "cargo-config" ''
        [source.crates-io]
        replace-with = "nix-vendored"

        [source.nix-vendored]
        directory = "${crates-io}"
      '';
  addCargoConfig = config: pkg: pkgs.stdenv.mkDerivation {
    name = "${lib.getName pkg}-with-cargo-config";
    src = pkg;
    installPhase = ''
      mkdir -p $out
      cp -RP $src/. $out
      mkdir -p $out/.cargo
      cp ${config} $out/.cargo/config
    '';
    preferLocalBuild = true;
    allowSubstitutes = false;
  } // (if pkg ? version then { inherit (pkg) version; } else {});
  skeletonCargoPkg = cargoToml: cargoLock: pkg: pkgs.stdenv.mkDerivation {
    name = "${lib.getName pkg}-cargo-skeleton";
    src = pkg;
    installPhase = ''
      mkdir -p $out
      cp -RP $src/. $out
      cp --remove-destination ${cargoToml} $out/Cargo.toml
      cp --remove-destination ${cargoLock} $out/Cargo.lock
    '';
    preferLocalBuild = true;
    allowSubstitutes = false;
  };
  nixPackageNameToCrateName = name: builtins.replaceStrings ["-"] ["_"] name;
  # https://stackoverflow.com/a/54505212
  recursiveMerge = with lib; attrList:
    let f = attrPath:
      zipAttrsWith (n: values:
        if tail values == []
          then head values
        else if all isList values
          then unique (concatLists values)
        else if all isAttrs values
          then f (attrPath ++ [n]) values
        else last values
      );
    in f [] attrList;
  buildPackage' = { name, version, src, vendoredDeps, builtDeps, features, isTopLevel, NIX_LDFLAGS ? null, ... }@args_:
    let
      args = builtins.removeAttrs args_ [ "name" "version" "src" "vendoredDeps" "builtDeps" "features" "isTopLevel" "NIX_LDFLAGS" ];
      override = overrides.${name} or {};
      hostTriple = mkHostTriple pkgs.stdenv.hostPlatform;
      cargoConfig = mkCargoConfig vendoredDeps;
      cargoConfig' =
          # FIXME: translate nix target to triple
          pkgs.writeText "cargo-config" ''
            [target.${hostTriple}]
            linker = "${pkgs.stdenv.cc}/bin/ld"
          '';
      depsBlacklist = [
        #"cfg-if" # already included in sysroot
      ];
      walkDeps = dep: [dep.pkg] ++ (lib.flatten (map walkDeps dep.deps));
      builtDeps' = map (p: p.value) builtDeps;
      walkedDeps = lib.flatten (map walkDeps builtDeps');
      ldFlags =
        let
          ldFlags0 = lib.flatten (map (d: d.ldFlags) builtDeps');
          ldFlags1 = if NIX_LDFLAGS != null then lib.splitString " " NIX_LDFLAGS else [];
          ldFlags2 = if override ? NIX_LDFLAGS then lib.splitString " " override.NIX_LDFLAGS else [];
        in
          ldFlags0 ++ ldFlags1 ++ ldFlags2;
      #builtDeps' = (builtins.map (p: p.pkg) builtDeps);
      envVars = recursiveMerge (map
        (p:
          let
            pkg = p.pkg;
            buildOutput = lib.splitString "\n" (builtins.readFile "${pkg.buildOutput}");
            buildOutput' = map (lib.removePrefix "cargo:") (builtins.filter (lib.hasPrefix "cargo:") buildOutput);
            knownCargoKeys = [ "rerun-if-changed" "rerun-if-env-changed" "rustc-link-lib" "rustc-link-search" "rustc-flags" "rustc-cfg" "rustc-env" "rustc-cdylib-link-arg" "warning" ];
            buildOutput'' = recursiveMerge (map
              (l: let
                splitText = lib.splitString "=" l;
                key = builtins.head splitText;
                value = builtins.concatStringsSep "=" (builtins.tail splitText);
              in
                { ${key} = value; })
              buildOutput');
            buildOutput''' = lib.filterAttrs (k: v: !(builtins.elem k knownCargoKeys)) buildOutput'';
            makeEnvVarName = name: let
              name' = "DEP_${p.links}_${name}";
              normalize = name: lib.toUpper (builtins.replaceStrings ["-"] ["_"] name);
            in
              normalize name';
            envVars = lib.mapAttrs'
              (name: value: lib.nameValuePair (makeEnvVarName name) value)
              buildOutput''';
          in
            envVars
          )
        (builtins.filter (p: p.links != null) builtDeps'));
      src'' = skeletonCargoPkg skeletonCargoToml skeletonCargoLock src;
      src''' = if isTopLevel then addCargoConfig cargoConfig' src'' else src'';
      depsLink = symlinkJoinPassViaFile {
        name = "${name}-${version}-deps-link";
        paths = builtins.map (p: "${p}/out") walkedDeps;
      };
      depFlags = [
        # Remove runtime dependency on crate sources
        "--remap-path-prefix"
        "${src'''}=/source"
      ] ++ [
        "-L"
        "dependency=${depsLink}"
      ] ++ (lib.optionals (!isTopLevel) [
        "--cap-lints"
        "warn"
      ]) ++
        (lib.flatten (map
        (p:
          let
            pkg = p.value.pkg;
            outputs = builtins.attrNames (builtins.readDir "${pkg}/out");
            libPath = builtins.head outputs;
          in
            [ "--extern" "${p.name}=${pkg}/out/${libPath}" ])
          builtDeps)) ++ (lib.optionals isTopLevel (lib.flatten (map
        (f: [ "-C" "link-arg=${f}" ])
        ldFlags)));
        #(builtins.filter (d: !(builtins.elem (lib.getName d.value.pkg) depsBlacklist)) builtDeps)));
      depFlags' = builtins.concatStringsSep " " depFlags;
      rustcWrapper = pkgs.writeScriptBin "rustc" ''
          #!${pkgs.stdenv.shell}
          exec ${rustc}/bin/rustc ${depFlags'} $@
        '';
      origCargoTOML = builtins.fromTOML (builtins.readFile "${src}/Cargo.toml");
      package = origCargoTOML.package;
      edition = if package ? edition then "edition = \"${package.edition}\"" else "";
      features'' =
        let
          origFeatures = origCargoTOML.features or {};
          newFeatures = f: builtins.foldl' (a: p: a // { ${p} = []; }) {} (builtins.filter
            (p: !(builtins.hasAttr p f) && !(lib.hasInfix "/" p))
            (lib.flatten (builtins.attrValues f)));
          optionalPkgFeatures = builtins.foldl' (a: p: a // { ${p} = []; }) {} (builtins.attrNames (lib.filterAttrs
            (k: v: (v.optional or false) && (lib.any (p: (lib.getName p.pkg) == k) builtDeps'))
            origCargoTOML.dependencies or {}));
        in
          origFeatures // (newFeatures origFeatures) // optionalPkgFeatures;
      features' =
        let
          makePair = f: key: value: "\"${key}\" = [${builtins.concatStringsSep "," (builtins.map (s: "\"${s}\"") (builtins.filter (p: !(lib.hasInfix "/" p)) value))}]";
          repackFeatures = f: "[features]\n${builtins.concatStringsSep "\n" (lib.mapAttrsToList (makePair f) f)}";
        in
          repackFeatures features'';
      lib' =
        let
          serializeLib = l:
            let
              components = ["[lib]"] ++
                (lib.optional (l ? name) "name = \"${l.name}\"") ++
                (lib.optional (l ? path) "path = \"${l.path}\"") ++
                (lib.optional (l ? proc-macro) "proc-macro = ${if l.proc-macro then "true" else "false"}");
            in
              builtins.concatStringsSep "\n" components;
        in
          if origCargoTOML ? lib then serializeLib origCargoTOML.lib else "";
      package' =
        let
          serializePackage = p:
            let
              components = [
                "[package]"
                "name = \"${p.name}\""
                "version = \"${p.version}\""
              ] ++
                (lib.optional (p ? build) "build = \"${p.build}\"") ++
                (lib.optional (p ? edition) "edition = \"${p.edition}\"") ++
                (lib.optional (p ? links) "links = \"${p.links}\"");
            in
              builtins.concatStringsSep "\n" components;
        in
          serializePackage package;
      links = package.links or null;
      skeletonCargoToml = pkgs.writeText "cargo-toml" ''
          ${package'}
          ${features'}
          ${lib'}
        '';
      skeletonCargoLock = pkgs.writeText "cargo-lock" ''
          version = 3

          [[package]]
          name = "${name}"
          version = "${version}"
        '';
      #featureFlags = if builtins.length features > 0 then "--features ${builtins.concatStringsSep "," (builtins.filter (p: builtins.hasAttr p origCargoTOML.features) features)}" else "";
      flags = builtins.concatLists [
        [
          "-p"
          name
          "--release"
          "--offline"
          "-Z"
          "unstable-options"
          "-Z"
          "avoid-dev-deps"
          "--no-default-features"
          "--target-dir"
          "$out/target"
          "--out-dir"
          "$out/out"
        ]
        (lib.optionals (!isTopLevel) [
          "--lib"
        ])
        (lib.optionals (features != []) [
          "--features"
          (builtins.concatStringsSep "," (builtins.filter (p: builtins.hasAttr p features'') features))
        ])
      ];
      flags' = builtins.concatStringsSep " " flags;
    in {
      pkg = pkgs.stdenv.mkDerivation (recursiveMerge [
        {
          inherit name version;
          src = src''';
          nativeBuildInputs = [ cargo rustcWrapper pkgs.libiconv ];
          #buildInputs = [ pkgs.libiconv ];
          buildInputs = map (p: p.pkg) builtDeps';
          outputs = if package ? links then [ "out" "buildOutput" ] else [ "out" ];
          installPhase = ''
            mkdir -p $out/target
            mkdir -p $out/out
            cd $src
            export RUSTC="${rustcWrapper}/bin/rustc"
            ${cargo}/bin/cargo build ${flags'}
            LIB="$(find $out/out -type f)"
            LIBEXT="''${LIB##*.}"
            LIB2="''${LIB%%.*}"
            if [ "$LIB" != "$LIB2" ]; then
              mv $LIB $LIB2-"$(echo $(basename $out) | cut -d'-' -f1)".$LIBEXT
            fi
            ${if package ? links then ''
              find $out -path '*/target/release/build/*/output' -exec cat {} \; > $buildOutput
            '' else ""}
            rm -rf $out/target
          '';
        }
        envVars
        override
        args
      ]);
      inherit links ldFlags;
    };
  deps = map
    (p: vendorPackage p.name p.version p.checksum)
    rawDeps';
  /** From naersk */
  symlinkJoinPassViaFile =
    args_@{ name
         , paths
         , preferLocalBuild ? true
         , allowSubstitutes ? false
         , postBuild ? ""
         , ...
       }:
    let
      args = removeAttrs args_ [ "name" "postBuild" ]
      // { inherit preferLocalBuild allowSubstitutes;
           passAsFile = [ "paths" ];
           nativeBuildInputs = [ pkgs.pkgsBuildHost.xorg.lndir ];
         };
    in
      pkgs.runCommand name args ''
          mkdir -p $out

          for i in $(cat $pathsPath); do
            lndir -silent $i $out
          done
          ${postBuild}
        '';
  crates-io = symlinkJoinPassViaFile {
    name = "crates-io";
    paths = deps;
  };
  cargoConfig = pkgs.writeText "cargo-config" ''
    [source.crates-io]
    replace-with = "nix-vendored"

    [source.nix-vendored]
    directory = "${crates-io}"
  '';
  metadataFile = pkgs.runCommand "cargo-metadata" {
    nativeBuildInputs = with pkgs; [ cargo rustc ];
  } ''
    ${cargo}/bin/cargo init --name ${pname}
    cp ${src}/Cargo.toml ./Cargo.toml
    cp ${src}/Cargo.lock ./Cargo.lock
    mkdir -p .cargo
    cp ${cargoConfig} .cargo/config
    ${cargo}/bin/cargo metadata --offline --format-version 1 > $out
  '';
  metadata = builtins.fromJSON (builtins.readFile metadataFile);
  getPackageMetadata = id: lib.findSingle (p: p.id == id) null null metadata.packages;
  getResolveMetadata = id: lib.findSingle (p: p.id == id) null null metadata.resolve.nodes;
  getChecksumFromCargoLock = name: version:
    let
      pkg = lib.findSingle (p: p.name == name && p.version == version) null null rawDeps;
    in
      if builtins.hasAttr "checksum" pkg then pkg.checksum else null;
  checkCargoCfg = cfg:
    let
      sourceFile = pkgs.writeText "cargo-cfg-test-source" ''
        #[cfg(${cfg})]
        compile_error!("HAS_DEP_TARGET");
        #[cfg(not(${cfg}))]
        compile_error!("NO_DEP_TARGET");

        fn main() {}
      '';
      output = pkgs.runCommand "cargo-cfg-test" {
        nativeBuildInputs = [ cargo rustc ];
      } ''
        ${cargo}/bin/cargo init --name cargo-cfg-test
        cp ${sourceFile} src/main.rs
        ! ${cargo}/bin/cargo run >$out 2>&1
        true
      '';
    in
      lib.hasInfix "HAS_DEP_TARGET" (builtins.readFile output);
  buildPackage'' = { id, isTopLevel ? false, NIX_LDFLAGS ? null, ... }@args_:
    let
      args = builtins.removeAttrs args_ [ "id" "isTopLevel" "NIX_LDFLAGS" ];
      resolved = getResolveMetadata id;
      metadata = getPackageMetadata id;
      name = metadata.name;
      version = metadata.version;
      sha256 = getChecksumFromCargoLock name version;
      isLocal = sha256 == null;
      src' = if isLocal then pkgs.runCommand "${name}-${version}-local-src" { preferLocalBuild = true; allowSubstitutes = false; } ''
          mkdir -p $out
          cp -RP ${src}/. $out
        '' else unpackPackage name version sha256;
      vendoredDeps = crates-io;
      builtDeps = map
        (p: {
          inherit (p) name;
          value = buildPackage'' { id = p.pkg; };
        })
        (builtins.filter
          (p:
            let
              depKind = builtins.head p.dep_kinds;
            in if (depKind.target == null) then true else let
              cfgOption = builtins.match "cfg\\((.*)\\)" depKind.target;
            in if (cfgOption == null) then false else # FIXME: target matching
              checkCargoCfg (builtins.head cfgOption))
          resolved.deps);
      builtPkg = buildPackage' {
        inherit name version vendoredDeps builtDeps isTopLevel NIX_LDFLAGS;
        src = src';
        features = resolved.features;
      } // args;
    in
      {
        inherit (builtPkg) pkg links ldFlags;
        deps = map (p: p.value) builtDeps;
      };
  remapBinaryPackage = pkg:
    let
      pkg' = pkg.pkg;
    in
      pkgs.runCommand "${lib.getName pkg'}-bin" { preferLocalBuild = true; allowSubstitutes = false; } ''
        mkdir -p $out/bin
        cp -RP ${pkg'}/out/. $out/bin
      '';
  app = remapBinaryPackage (buildPackage'' { id = metadata.resolve.root; isTopLevel = true; } // args);
  #app = (buildPackage'' { id = "openssl 0.10.35 (registry+https://github.com/rust-lang/crates.io-index)"; }).pkg;
in
  app
