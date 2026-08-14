{
  description = "Hæ? native macOS development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          cmake
          coreutils
          git
          jq
          just
          ninja
          pkg-config
          shellcheck
          yq-go
        ];
      };
    };
}
