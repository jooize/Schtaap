{
  description = "Spotify Connect to synced HomePods: OwnTone + librespot, native on macOS";

  inputs.nixpkgs.url = "flake:nixpkgs";

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system} = {
        # The two daemons the macOS app bundles and supervises.
        # `macos/build-engine` builds these, relocates their dylib closure
        # into a self-contained tree, and stages it for Xcode to copy.
        ffmpeg-audio = pkgs.callPackage ./nix/ffmpeg-audio.nix { };

        owntone = pkgs.callPackage ./nix/owntone.nix {
          ffmpeg = self.packages.${system}.ffmpeg-audio;
        };
        librespot = pkgs.callPackage ./nix/librespot.nix { };
      };
    };
}
