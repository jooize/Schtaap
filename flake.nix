{
  description = "Spotify Connect to synced HomePods: OwnTone + librespot, native on macOS";

  inputs.nixpkgs.url = "flake:nixpkgs";

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;
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

        # Not in nixpkgs. Runs as root via sudo (vmnet requires it), so it
        # must live at a root-only-writable path -- the Nix store qualifies.
        socket_vmnet = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "socket_vmnet";
          version = "1.2.2";

          src = pkgs.fetchFromGitHub {
            owner = "lima-vm";
            repo = "socket_vmnet";
            tag = "v${finalAttrs.version}";
            hash = "sha256-D5Z4aml82h397ho48HFeXwR6y2XkopFIKjO09jUgFdo=";
          };

          postPatch = ''
            substituteInPlace Makefile --replace-quiet "logger " ": "
          '';

          makeFlags = [
            "PREFIX=$(out)"
            "VERSION=v${finalAttrs.version}"
          ];
          installTargets = [ "install.bin" ];

          meta = {
            description = "vmnet.framework support for unmodified VMs";
            homepage = "https://github.com/lima-vm/socket_vmnet";
            license = lib.licenses.asl20;
            platforms = lib.platforms.darwin;
          };
        });

        lima = pkgs.lima;

        # Bridged socket_vmnet networking works only with Lima's QEMU
        # driver, not vz.
        qemu = pkgs.qemu;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [ pkgs.lima ];
      };
    };
}
