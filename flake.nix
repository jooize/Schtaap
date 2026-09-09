{
  description = "Spotify Connect to synced HomePods: OwnTone + librespot, native on macOS";

  inputs.nixpkgs.url = "flake:nixpkgs";

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      # Named in the bundle's third-party notices as where the recipes,
      # the patches and the corresponding source can be had.
      sourceUrl = "https://github.com/jooize/Schtaap";
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

      # NOTICES.txt for one built payload, from the store paths relocate.bash
      # copied. `macos/build-engine` calls this; see nix/engine-notices.nix.
      lib.engineNotices =
        shipped:
        pkgs.callPackage ./nix/engine-notices.nix {
          inherit (self.packages.${system}) owntone librespot;
        } { inherit shipped sourceUrl; };
    };
}
