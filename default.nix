# This default.nix builds a tarball containing a statically linked
# Futhark binary and some manpages.  Likely to only work on linux.
#
# Just run 'nix-build' and fish the tarball out of 'result/'.
#
# For the Haskell dependencies that diverge from our pinned Nixpkgs,
# we use cabal2nix like thus:
#
#  $ cabal2nix cabal://sexp-grammar-2.2.1 > nix/sexp-grammar.nix
#
# And then import them into the configuration.
#
# Also remember this guide: https://github.com/Gabriel439/haskell-nix/blob/master/project1/README.md

{ compiler ? "ghc883", # ignored ATM
  suffix ? "nightly",
  commit ? "" }:
let
  config = {
    packageOverrides = pkgs: rec {
      haskellPackages = pkgs.haskellPackages.override {
        overrides = haskellPackagesNew: haskellPackagesOld: rec {
          versions =
            haskellPackagesNew.callPackage ./nix/versions.nix { };

          sexp-grammar =
            haskellPackagesNew.callPackage ./nix/sexp-grammar.nix { };

          futhark =
            pkgs.haskell.lib.overrideCabal
              (pkgs.haskell.lib.addBuildTools
                (haskellPackagesNew.callPackage ./futhark.nix { })
                [ pkgs.python37Packages.sphinx ])
              ( _drv: {
                isLibrary = false;
                isExecutable = true;
                enableSharedExecutables = false;
                enableSharedLibraries = false;
                enableLibraryProfiling = false;
                configureFlags = [
                  "--ghc-option=-optl=-static"
                  "--ghc-option=-split-sections"
                  "--extra-lib-dirs=${pkgs.ncurses.override { enableStatic = true; }}/lib"
                  "--extra-lib-dirs=${pkgs.glibc.static}/lib"
                  "--extra-lib-dirs=${pkgs.gmp6.override { withStatic = true; }}/lib"
                  "--extra-lib-dirs=${pkgs.zlib.static}/lib"
                  "--extra-lib-dirs=${pkgs.libffi.overrideAttrs (old: { dontDisableStatic = true; })}/lib"
                ];

                postBuild = (_drv.postBuild or "") + ''
        make -C docs man
        '';

                postInstall = (_drv.postInstall or "") + ''
        mkdir -p $out/share/man/man1
        cp docs/_build/man/*.1 $out/share/man/man1/
        mkdir -p $out/share/futhark/
        cp LICENSE $out/share/futhark/
        '';
              }
              );
        };
      };
    };
  };

  sources = import ./nix/sources.nix;
  pkgs = import sources.nixpkgs { inherit config; };

  futhark = pkgs.haskellPackages.futhark;

in pkgs.stdenv.mkDerivation rec {
  name = "futhark-" + suffix;
  version = futhark.version;
  src = tools/release;

  buildInputs = [ futhark ];

  buildPhase = ''
    cp -r skeleton futhark-${suffix}
    cp -r ${futhark}/bin futhark-${suffix}/bin
    mkdir -p futhark-${suffix}/share
    cp -r ${futhark}/share/man futhark-${suffix}/share/
    chmod +w -R futhark-${suffix}
    cp ${futhark}/share/futhark/LICENSE futhark-${suffix}/
    [ "${commit}" ] && echo "${commit}" > futhark-${suffix}/commit-id
    tar -Jcf futhark-${suffix}.tar.xz futhark-${suffix}
  '';

  installPhase = ''
    mkdir -p $out
    cp futhark-${suffix}.tar.xz $out/futhark-${suffix}.tar.xz
  '';
}
