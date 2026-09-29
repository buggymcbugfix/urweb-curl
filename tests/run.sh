#!/usr/bin/env bash
#
# The library's tests: an Ur/Web application (tests/app) whose io task makes
# every request once at startup, against a fake HTTP server (tests/httpd.py),
# and logs what Curl made of it; the log is split into one transcript per case
# and compared with the case's golden file.
#
#   tests/run.sh [-u] [CASE...]      all cases unless given; -u rewrites what
#                                    the cases expect
#
# A case is a section "--- NAME" of the application's log (tests/app/test.ur
# says what each one requests) and a directory tests/cases/NAME holding
# `expected`.
#
# The compiler is the one URWEB names, run with the flags in URWEB_FLAGS if
# set, or else `urweb` on the PATH.  The library must have been built
# (tests/config.urp names it).  Needs python3 (the server) and openssl (a
# self-signed certificate for the TLS cases).  Exit status: 0 every case
# passed, 1 some failed, 2 could not run.

set -u

here=$(cd "$(dirname "$0")" && pwd)
out=$here/out
urweb=${URWEB:-urweb}
urweb_flags=${URWEB_FLAGS:-}

update=0
if [ "${1:-}" = "-u" ]; then update=1; shift; fi

die() { echo "run.sh: $*" >&2; exit 2; }

for tool in python3 openssl; do
  command -v "$tool" >/dev/null || die "$tool is needed"
done
command -v "$urweb" >/dev/null || die "no urweb: set URWEB or put it on the PATH"
[ -f "$here/config.urp" ] || die "tests/config.urp is missing: run configure and make first"

rm -rf "$out"
mkdir -p "$out"

# The application.
( cd "$here/app" && rm -f test.exe && "$urweb" $urweb_flags -protocol http test ) \
  > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; die "the test application failed to build"; }

# The server's certificate: self-signed, for 127.0.0.1.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$out/key.pem" -out "$out/cert.pem" \
  -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 -days 2 > "$out/openssl.log" 2>&1 \
  || { cat "$out/openssl.log" >&2; die "openssl could not make a certificate"; }

# The server, until this script ends.
python3 "$here/httpd.py" "$out/cert.pem" "$out/key.pem" > "$out/httpd.out" 2> "$out/httpd.err" &
httpd_pid=$!
trap 'kill $httpd_pid 2>/dev/null' EXIT
for _ in $(seq 100); do
  grep -q '^closed=' "$out/httpd.out" 2>/dev/null && break
  sleep 0.1
done
grep -q '^closed=' "$out/httpd.out" || { cat "$out/httpd.err" >&2; die "the fake server did not start"; }
http=$(sed -n 's/^http=//p' "$out/httpd.out")
https=$(sed -n 's/^https=//p' "$out/httpd.out")
closed=$(sed -n 's/^closed=//p' "$out/httpd.out")

# Run the application until its task has logged every case (io_debug writes
# to stdout), or failed; then split the log into one transcript per section,
# of the lines the task writes and a failure of it (the server's other
# threads log meanwhile).  -d3 prints pid=, port= and status= on fd 3 once it
# listens.  LD_LIBRARY_PATH goes through for a compiler whose runtime is not
# installed where the application looks (an in-tree build: out/lib).
eval "$( env -i ${LD_LIBRARY_PATH:+LD_LIBRARY_PATH="$LD_LIBRARY_PATH"} PATH="$PATH" \
           CURL_TEST_HTTP="http://127.0.0.1:$http" CURL_TEST_HTTPS="https://127.0.0.1:$https" \
           CURL_TEST_CLOSED="http://127.0.0.1:$closed" CURL_TEST_CA="$out/cert.pem" \
           "$here/app/test.exe" -a 127.0.0.1 -p 8000 -P 9000 -d3 3>&1 1> "$out/app.log" 2>&1 )"
[ "${status:-}" = OK ] || { cat "$out/app.log" >&2; die "the test application did not start"; }
for _ in $(seq 900); do
  grep -q -e '^--- end$' -e '^Fatal error in io task' "$out/app.log" && break
  sleep 0.1
done
kill "$pid" 2>/dev/null
grep -q -e '^--- end$' -e '^Fatal error in io task' "$out/app.log" || { cat "$out/app.log" >&2; die "the task did not finish in 90 s"; }
awk -v out="$out" '
  /^--- end$/ { exit }
  /^--- / { name = substr($0, 5); file = out "/" name ".actual"; printf "" > file; next }
  name != "" && /^(outcome|header|body|x-two|set-cookie|x-none|escaped): |^Fatal error in io task/ { print >> file }
' "$out/app.log"

if [ $# -gt 0 ]; then
  cases=("$@")
else
  cases=()
  for f in "$out"/*.actual; do cases+=("$(basename "$f" .actual)"); done
  for d in "$here"/cases/*/; do
    [ -d "$d" ] || continue
    c=$(basename "$d")
    [ -f "$out/$c.actual" ] || cases+=("$c")
  done
fi

failed=0
for case in "${cases[@]}"; do
  dir=$here/cases/$case
  actual=$out/$case.actual
  if [ ! -f "$actual" ]; then
    echo "$case: not in the application's log" >&2; failed=1
  elif [ $update = 1 ]; then
    mkdir -p "$dir"
    cp "$actual" "$dir/expected"
    echo "$case: updated"
  elif [ ! -f "$dir/expected" ]; then
    echo "$case: no expected file (run with -u to create it)" >&2; failed=1
  elif diff -u "$dir/expected" "$actual" > "$out/$case.diff"; then
    echo "$case: ok"
  else
    echo "$case: FAILED" >&2; cat "$out/$case.diff" >&2; failed=1
  fi
done

exit $failed
