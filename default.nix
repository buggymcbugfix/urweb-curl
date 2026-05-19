{
  stdenv,
  curl,
  gcc,
  urweb,
  icu,
}: let
  libExt =
    if stdenv.isDarwin
    then "dylib"
    else "so";
in
  stdenv.mkDerivation rec {
    version = "0.0.1";
    name = "urweb-curl-${version}";

    src = ./.;

    buildInputs = [gcc];
    # TODO: Improve like urweb.nix c, cflags etc
    configurePhase = ''
      cp lib.urp.in lib.urp
      substituteInPlace lib.urp \
        --replace-fail '@LIBCURL@' '${lib.getLib curl}/lib/libcurl${stdenv.hostPlatform.extensions.sharedLibrary}' \
        --replace-fail '@LIBCURLDEV@' '${lib.getDev curl}/include'
    '';
    buildPhase = ''
      ${gcc}/bin/gcc -c -I${urweb}/include/urweb -I${curl.dev}/include -I${icu.dev}/include -Isrc/c -o src/c/curl.o -Wimplicit -Wall -Werror -Wno-deprecated-declarations src/c/curl.c
    '';
    installPhase = "
    mkdir $out
    cp -r . $out
  ";
  }
