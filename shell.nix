# nix-shell: the library's build inputs and its Ur/Web.
# `URWEB=/path/to/bin/urweb make check` tests against another compiler,
# e.g. an in-tree build of a modified Ur/Web.
{ pkgs ? import ./nixpkgs.nix }:
let
  urweb-curl = pkgs.callPackage ./derivation.nix { };
in
pkgs.mkShell {
  inputsFrom = [ urweb-curl ];
}
