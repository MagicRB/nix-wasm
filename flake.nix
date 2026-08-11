{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-compat.url = "github:nix-community/flake-compat";
    ghc-wasm-meta = {
      url = "github:haskell-wasm/ghc-wasm-meta";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    with builtins;
    let
      inherit (inputs."nixpkgs") lib;
      foreach = xs: f: with lib; foldr recursiveUpdate { } (
        if isList xs then map f xs
        else if isAttrs xs then mapAttrsToList f xs
        else throw "foreach: expected list or attrset but got ${typeOf xs}"
      );
      importNixpkgs = pkgs:
        let
          patchedPkgs = pkgs.stdenvNoCC.mkDerivation {
            name = "patched-nixpkgs";
            src = pkgs.path;
            patches = [
              ./nixpkgs-patches/generic-builder.patch
              ./nixpkgs-patches/with-packages-wrapper.patch
            ];
            dontBuild = true;
            installPhase = ''
              cp -r . "$out"
            '';
          };
        in
          import patchedPkgs;
      targetPrefix = "wasm32-wasi-";
      wasmPkgs = { pkgs, ghcVersion, patchNixpkgs }:
        let
          ghc-wasm-meta-all = inputs.ghc-wasm-meta.packages.${pkgs.stdenv.hostPlatform.system}."all_${ghcVersion.major}_${ghcVersion.minor}";
          ghc-wasm-meta-cabal = inputs.ghc-wasm-meta.packages.${pkgs.stdenv.hostPlatform.system}."wasm32-wasi-cabal-${ghcVersion.major}_${ghcVersion.minor}";
          ghc-wasm-meta-ghc = inputs.ghc-wasm-meta.packages.${pkgs.stdenv.hostPlatform.system}."wasm32-wasi-ghc-${ghcVersion.major}_${ghcVersion.minor}";

          importer = if patchNixpkgs then importNixpkgs else pkgs: import pkgs.path;
        in
          importer pkgs rec {
            inherit (pkgs.stdenv.hostPlatform) system;
            crossSystem = lib.systems.elaborate lib.systems.examples.wasi32 // {
              isStatic = false;
            };
            config.replaceCrossStdenv = { buildPackages, baseStdenv }: buildPackages.stdenvNoCC.override {
              inherit (baseStdenv)
                buildPlatform
                hostPlatform
                targetPlatform;
              cc = ghc-wasm-meta-all // {
                isGNU = false;
                isClang = true;
                libc = inputs.ghc-wasm-meta.packages.${system}.wasi-sdk.overrideAttrs (attrs: { pname = attrs.name; version = "unstable1"; });
                inherit targetPrefix;
                bintools = ghc-wasm-meta-all // {
                  inherit targetPrefix;
                  bintools = ghc-wasm-meta-all // {
                    inherit targetPrefix;
                  };
                };
              };
            };
            overlays = [
              (final: prev: {
                cabal-install = ghc-wasm-meta-cabal;
              })
            ];
            crossOverlays = [
              (final: prev: {
                cabal-install = ghc-wasm-meta-cabal;
                haskell = (prev.haskell.override (old: {
                  buildPackages = lib.recursiveUpdate old.buildPackages {
                    haskell.compiler."ghc${ghcVersion.major}${ghcVersion.minor}" = ghc-wasm-meta-ghc // {
                      inherit targetPrefix;
                    };
                  };
                })) // {
                  packageOverrides = lib.composeManyExtensions [
                    prev.haskell.packageOverrides
                    (hfinal: hprev: {
                      ghcWithPackages = hprev.ghcWithPackages.override { installDocumentation = false; };
                      ghc = ghc-wasm-meta-ghc // {
                        inherit (pkgs.haskell.packages."ghc${ghcVersion.major}${ghcVersion.minor}".ghc) version haskellCompilerName;
                        inherit targetPrefix;
                      };
                      mkDerivation = args: (hprev.mkDerivation (args // {
                        enableLibraryProfiling = false;
                        enableSharedLibraries = true;
                        enableStaticLibraries = false;
                        enableExternalInterpreter = false;
                        doBenchmark = false;
                        doHaddock = false;
                        doCheck = false;
                        jailbreak = true;
                        configureFlags = [
                          "--with-ld=${prev.stdenv.cc.bintools}/bin/lld"
                          "--with-ar=${prev.stdenv.cc.bintools}/bin/ar"
                          "--with-strip=${prev.stdenv.cc.bintools}/bin/strip"
                        ];
                        #buildFlags = (args.buildFlags or []) ++ ["-v3"];
                        setupHaskellDepends = (args.setupHaskellDepends or [ ]) ++ [
                          # This executes the wasi-sdk setup-hook that sets toolchain env vars such as AR, CC, ...
                          inputs.ghc-wasm-meta.packages.${system}.wasi-sdk
                        ];
                        preBuild = ''
                          ${args.preBuild or ""}
                          export NIX_CC=$CC
                        '';
                      })).overrideAttrs (attrs: {
                        name = "${attrs.pname}-${targetPrefix}${attrs.version}";
                        preSetupCompilerEnvironment = ''
                          export CC_FOR_BUILD=$CC
                        '';
                      });
                      zlib = prev.haskell.lib.compose.addBuildDepend hprev.zlib-clib hprev.zlib;
                    })
                  ];
                };
              })
            ];
          };
    in
      {
        inherit wasmPkgs;
      } // foreach inputs.nixpkgs.legacyPackages (system: pkgs:
        let
          ghcVersion = { major = "9"; minor = "14"; };
          wasmPackages = wasmPkgs { inherit pkgs ghcVersion; patchNixpkgs = true; };
          haskellPackages = wasmPackages.haskell.packages."ghc${ghcVersion.major}${ghcVersion.minor}";
          example = hp: hp.callCabal2nix "example" ./example { };
        in
        {
          legacyPackages.${system} = lib.recursiveUpdate wasmPackages {
            inherit haskellPackages;
            haskell.packages.${ghc} = example haskellPackages;
          };
          packages.${system}.default = example haskellPackages;
          devShells.${system}.default = pkgs.mkShell {
            inputsFrom = [
              (haskellPackages.shellFor {
                packages = hp: [ (example hp) ];
                nativeBuildInputs = with wasmPackages; [
                  cabal-install
                ];
              })
              (pkgs.haskell.packages.${ghc}.shellFor {
                packages = hp: [ (example hp) ];
                nativeBuildInputs = with pkgs; [
                  cabal-install
                  haskell.packages.${ghc}.haskell-language-server
                ];
              })
            ];
          };
        }
      );
}
