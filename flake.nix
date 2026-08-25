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

        # mix.exs requires elixir ~> 1.20, and this set's plain `elixir`
        # alias lags behind that (1.18 at the time of writing), so the
        # version has to be picked explicitly. It gets picked by scoping
        # the whole package set rather than by passing `elixir` to each
        # builder: nixpkgs stopped accepting that argument, and now takes
        # the version from whichever set the builder was called from.
        #
        # Scoping is what the old argument should have been anyway. `hex`
        # is built inside this set too, so it now follows elixir here -
        # passing the argument left it built against the default elixir
        # while the deps were fetched with 1.20.
        beamPackages = pkgs.beam.packages.erlang.overrideScope (
          _final: prev: { elixir = prev.elixir_1_20; }
        );
        elixir = beamPackages.elixir;

        version = "0.1.0";

        # Fixed-output derivation fetching every Hex dependency pinned in
        # mix.lock (the vendored `vendor/fresh` path dependency is part of
        # `src` and needs no separate fetch).
        mixFodDeps = beamPackages.fetchMixDeps {
          pname = "rvrb-deps";
          inherit version;
          src = ./.;
          hash = "sha256-2hH62w1NeqRM3dBQvi+sNwvh/+mWJIE23hr9oAJOSkU=";
        };
      in
      {
        # Exposed mainly so CI can target `nix build .#mixFodDeps` directly
        # to recompute the hash below without also building the (much
        # slower) full release.
        packages.mixFodDeps = mixFodDeps;

        packages.default = beamPackages.mixRelease {
          pname = "rvrb";
          inherit version mixFodDeps;
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
