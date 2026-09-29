{
  autoconf,
  automake,
  curl,
  icu,
  lib,
  libtool,
  openssl,
  pkg-config,
  python3,
  stdenv,
  urweb,
}:
stdenv.mkDerivation {
  pname = "urweb-curl";
  version = "1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.intersection (lib.fileset.gitTracked ./.) (
      lib.fileset.unions [
        ./autogen.sh
        ./configure.ac
        ./Makefile.am
        ./config.urp.in
        ./urweb-curl.pc.in
        ./lib.urp
        ./curl.c
        ./curl.h
        ./curl.ur
        ./curl.urs
        ./curlFfi.urs
        ./m4
        ./tests
        ./README.md
      ]
    );
  };

  nativeBuildInputs = [
    autoconf
    automake
    libtool
    pkg-config
  ];
  # urweb.h includes ICU's headers, and urweb's package does not pass them
  # on, so icu is named here.
  buildInputs = [
    curl
    icu
    urweb
  ];

  preConfigure = ''
    ./autogen.sh
  '';
  configureFlags = [ "--with-urweb=${urweb}" ];
  # The .urp files link liburweb-curl.a, so that an application carries the
  # library instead of depending on this package at run time; nixpkgs would
  # otherwise configure with --disable-static and not build it.
  dontDisableStatic = true;

  # The tests compile and run an Ur/Web application against a fake HTTP server
  # (python) with a self-signed certificate (openssl).
  doCheck = true;
  nativeCheckInputs = [
    openssl
    python3
    urweb
  ];

  meta = {
    description = "HTTP requests from Ur/Web io code";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
