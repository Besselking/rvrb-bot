{
  description = "rvrb - a music bot";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        beamPackages = pkgs.beam.packages.erlang;
        # mix.exs requires elixir ~> 1.20; the plain `elixir` alias in
        # nixpkgs can lag behind and point at an older default (e.g. 1.18),
        # so pin the versioned attribute explicitly.
        elixir = beamPackages.elixir_1_20;

        version = "0.1.0";

        # Fixed-output derivation fetching every Hex dependency pinned in
        # mix.lock (the vendored `vendor/fresh` path dependency is part of
        # `src` and needs no separate fetch).
        mixFodDeps = beamPackages.fetchMixDeps {
          pname = "rvrb-deps";
          inherit version elixir;
          src = ./.;
          hash = "sha256-2Tm/bpbSbX59VUDPfLMXOjH/qgbWD4gsenWDHkomGOs=";
        };
      in
      {
        # Exposed mainly so CI can target `nix build .#mixFodDeps` directly
        # to recompute the hash below without also building the (much
        # slower) full release.
        packages.mixFodDeps = mixFodDeps;

        packages.default = beamPackages.mixRelease {
          pname = "rvrb";
          inherit version mixFodDeps elixir;
          src = ./.;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = self.packages.${system}.default;
          exePath = "/bin/rvrb";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            elixir
            beamPackages.erlang
            pkgs.postgresql
          ];
        };
      }
    )
    // {
      nixosModules.default = import ./nix/module.nix { inherit self; };
    };
}
