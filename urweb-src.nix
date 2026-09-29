# The Ur/Web the standalone build and shell use. A project that packages
# this library passes its own `urweb` to derivation.nix instead.
#
# The library needs the io monad (Basis.io, runTransaction), which is on the
# urmail-rewrite branch of buggymcbugfix/urweb; the test application also
# needs io_rpc, from the commit "io_rpc, io_tryRpc: an RPC whose function is
# an io computation" on.  Move this to main once it is there.
builtins.fetchGit {
  url = "https://github.com/buggymcbugfix/urweb";
  ref = "urmail-rewrite";
  rev = "82e75e7f70a04e6a2c3cfd8c22721c9b1f3a0a9b";
}
