{
  description = "WAI / Yesod on Cloudflare Workers (PoC)";

  inputs = {
    ghc-wasm-meta.url = "github:haskell-wasm/ghc-wasm-meta";
    # Reuse the toolchain's own pins so the dev shell needs no second nixpkgs.
    nixpkgs.follows = "ghc-wasm-meta/nixpkgs";
    flake-utils.follows = "ghc-wasm-meta/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ghc-wasm-meta,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          # all_9_12 bundles wasm32-wasi-ghc, wasm32-wasi-cabal, wasi-sdk,
          # nodejs, binaryen (wasm-opt) and wasmtime for the 9.12 flavour.
          # GHC 9.12 is the first release whose wasm backend supports
          # Template Haskell, which Yesod needs.
          packages = [ ghc-wasm-meta.packages.${system}.all_9_12 ];
        };
      }
    );
}
