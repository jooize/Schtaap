# Third-party notices for a built engine payload.
#
# The app bundles owntone, librespot and their dylib closure, and most of
# that is GPL, LGPL or BSD code whose terms require the license text to
# travel with the binaries. This turns the list of store paths
# relocate.bash actually copied into one NOTICES.txt: every package a
# shipped file came from, with its version, homepage and license, followed
# by the full text of every license named.
#
# The shipped list is the only input build-engine passes. Everything else
# comes from the same locked nixpkgs the payload was built from, so the
# notices and the binaries cannot disagree. A shipped path whose package
# is not reachable from the roots below fails the build rather than going
# unlisted.
{
  lib,
  runCommand,
  spdx-license-list-data,
  darwin,
  owntone,
  librespot,
}:

{
  # Store paths (files or directories) that ended up in the payload.
  shipped,
  # Where the recipes, the patches and the corresponding source live.
  sourceUrl,
}:

let
  discard = builtins.unsafeDiscardStringContext;

  # libresolv is Apple's, reached through curl by way of the darwin stdenv
  # rather than any buildInputs list, so it is a root of its own.
  roots = [
    owntone
    librespot
    darwin.libresolv
  ];

  inputsOf =
    d:
    lib.filter lib.isDerivation (
      lib.concatMap (attr: d.${attr} or [ ]) [
        "buildInputs"
        "propagatedBuildInputs"
        "nativeBuildInputs"
        "propagatedNativeBuildInputs"
      ]
    );

  # Every derivation reachable from the roots, keyed by each of its
  # output paths.
  walk =
    seen: queue:
    if queue == [ ] then
      seen
    else
      let
        d = builtins.head queue;
        rest = builtins.tail queue;
        key = discard d.outPath;
        entries = map (o: {
          name = discard d.${o}.outPath;
          value = d;
        }) (d.outputs or [ "out" ]);
      in
      if seen ? ${key} then walk seen rest else walk (seen // lib.listToAttrs entries) (rest ++ inputsOf d);

  index = walk { } roots;

  storePathOf =
    file:
    let
      rel = lib.removePrefix (builtins.storeDir + "/") file;
    in
    builtins.storeDir + "/" + builtins.head (lib.splitString "/" rel);

  packageOf =
    path:
    index.${path}
      or (throw "engine-notices: no package known for ${path}; add its derivation to roots in nix/engine-notices.nix");

  packages = lib.sort (a: b: lib.toLower (nameOf a) < lib.toLower (nameOf b)) (
    lib.attrValues (
      lib.listToAttrs (
        map (
          p: {
            name = discard p.outPath;
            value = p;
          }
        ) (map packageOf (lib.unique (map storePathOf shipped)))
      )
    )
  );

  nameOf = p: p.pname or p.name;

  # Only libintl ships from gettext, and it is LGPL, not the GPL the
  # package as a whole carries (gettext-runtime/intl/COPYING.LIB).
  licenseOverrides = {
    gettext = [ lib.licenses.lgpl21Plus ];
  };

  licensesOf =
    p:
    let
      l = licenseOverrides.${nameOf p} or (p.meta.license or (throw "engine-notices: ${nameOf p} has no license"));
    in
    if builtins.isList l then l else [ l ];

  # SQLite's "public domain" has no SPDX id and no text to print.
  idOf =
    l:
    l.spdxId or (
      if (l.shortName or "") == "publicDomain" then
        "Public domain"
      else
        throw "engine-notices: license ${l.fullName or "?"} has no SPDX id"
    );

  patched = {
    owntone = "patches/owntone";
    librespot = "patches/librespot";
  };

  entry =
    p:
    ''
      ${nameOf p} ${p.version or ""}
        license: ${lib.concatStringsSep ", " (map idOf (licensesOf p))}
        source:  ${p.meta.homepage or "(no homepage recorded)"}
    ''
    + lib.optionalString (patched ? ${nameOf p}) "  patched: ${patched.${nameOf p}} in the repository named above\n";

  header = ''
    Third-party notices for the engine this app bundles
    ===================================================

    The app bundles the programs and libraries listed below, built from the
    sources named here by the Nix expressions in its repository, unmodified
    except where a patch is noted. Each is the work of its own authors and
    is distributed under its own license. The text of every license named
    follows the list. Where an entry names several, the package is offered
    under them as its own source says, by choice or by part.

    The build recipes, the patches, and the complete corresponding source
    of every GPL and LGPL component are available from

        ${sourceUrl}

    The app's own code is under the MIT License; see LICENSE there.


    Components
    ----------

  '';

  textIds = lib.sort (a: b: a < b) (
    lib.filter (id: id != "Public domain") (lib.unique (lib.concatMap (p: map idOf (licensesOf p)) packages))
  );
in
runCommand "engine-notices"
  {
    body = header + lib.concatStringsSep "\n" (map entry packages);
    passAsFile = [ "body" ];
    inherit textIds;
    texts = spdx-license-list-data.text;
  }
  ''
    {
      cat "$bodyPath"
      printf '\n\nLicense texts\n-------------\n'
      for id in $textIds; do
        printf '\n\n%s\n' "$id"
        printf '%s\n\n' "$(printf '%*s' "''${#id}" "" | tr ' ' '=')"
        cat "$texts/text/$id.txt"
      done
    } > "$out"
  ''
