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
        elixir = beamPackages.elixir;

        version = "0.1.0";

        # Fixed-output derivation fetching every Hex dependency pinned in
        # mix.lock (the vendored `vendor/fresh` path dependency is part of
        # `src` and needs no separate fetch). The hash below is a
        # placeholder: run `nix build`, it will fail with the real hash
        # of the resolved deps, paste that in here.
        mixFodDeps = beamPackages.fetchMixDeps {
          pname = "rvrb-deps";
          inherit version;
          src = ./.;
          hash = pkgs.lib.fakeHash;
        };
      in
      {
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
