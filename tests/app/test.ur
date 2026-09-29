(* The test application: an io task that makes every request once, at
   startup, against the fake server (tests/httpd.py) named by the environment
   run.sh sets -- CURL_TEST_HTTP and CURL_TEST_HTTPS, the two servers;
   CURL_TEST_CLOSED, a port nothing listens on; CURL_TEST_CA, the server's
   self-signed certificate -- and logs what Curl made of it, one section per
   case ("--- NAME"), then "--- end".  tests/run.sh splits the log into the
   cases' transcripts. *)

open Curl

type opts = Curl.opts

(* Short timeouts, so that a server that does not answer fails the case
   quickly. *)
val base : opts = Opts.default -- #Timeout ++ {Timeout = {Connect = sec 5, Total = sec 5}}

fun escapeText (s : string) : string =
	let
		fun esc c =
			if c = #"\n" then
				"\\n"
			else if c = #"\t" then
				"\\t"
			else if c = #"\\" then
				"\\\\"
			else if ord c < 32 then
				"\\" ^ show (ord c)
			else
				String.str c

		fun go i acc =
			if i >= String.length s then
				acc
			else
				go (i + 1) (acc ^ esc (String.sub s i))
	in
		go 0 ""
	end

(* libcurl's messages carry what varies from run to run and machine to
   machine: ports, milliseconds, byte counts.  Every run of digits becomes N. *)
fun withoutNumbers (s : string) : string =
	let
		fun go i inDigits acc =
			if i >= String.length s then
				acc
			else
				let
					val c = String.sub s i
				in
					if Char.isDigit c then
						go (i + 1) True (if inDigits then acc else acc ^ "N")
					else
						go (i + 1) False (acc ^ String.str c)
				end
	in
		go 0 False ""
	end

fun describe (b : blob) : string =
	case textOfBlob b of
	| None => show (blobSize b) ^ " bytes, binary"
	| Some s =>
		if String.length s > 256 then
			show (blobSize b) ^ " bytes"
		else
			"\"" ^ escapeText s ^ "\""

(* The transcript of an outcome.  Of the headers, Date and Server (the
   python version) are left out. *)
fun details (o : outcome) : io unit =
	case o of
	| Answered r =>
		(
			io_debug ("outcome: answered " ^ show r.Status);
			List.app
				(
					fn (n, v) =>
						let
							val n' = String.mp Char.toLower n
						in
							if n' = "date" || n' = "server" then
								return ()
							else
								io_debug ("header: " ^ n ^ ": " ^ v)
						end
				)
				r.Headers;
			io_debug ("body: " ^ describe r.Body)
		)
	| NotSent m => io_debug ("outcome: not sent: " ^ withoutNumbers m)
	| MaybeSent m => io_debug ("outcome: maybe sent: " ^ withoutNumbers m)
	| o => io_debug ("outcome: " ^ show o)

fun showOption (o : option string) : string =
	case o of
	| None => "None"
	| Some s => "Some \"" ^ s ^ "\""

(* The section starts before the request, so that a failure shows in it. *)
fun request (name : string) (o : opts) (m : method) (u : url) : io unit =
	io_debug ("--- " ^ name);
	r <- perform o m u;
	details r

fun withBody (o : opts) (b : body) : opts = o -- #Body ++ {Body = Some b}
fun withHeaders (o : opts) (hs : list (string * string)) : opts = o -- #Headers ++ {Headers = hs}

fun env (name : string) : io string =
	v <- io_getenv (blessEnvVar name);
	return
		(
			case v of
			| None => ""
			| Some v => v
		)

fun all () : io unit =
	http <- env "CURL_TEST_HTTP";
	https <- env "CURL_TEST_HTTPS";
	closed <- env "CURL_TEST_CLOSED";
	ca <- env "CURL_TEST_CA";
	let
		fun at (base : string) (path : string) : url = bless (base ^ path)
		val echo = at http "/echo"
		val secure = at https "/echo"
	in
		(* Methods and bodies, as the server sees them *)
		request "get" base Get echo;
		request "post-form" (withBody base (form (("a b", "c&d") :: ("Größe", "€") :: []))) Post echo;
		request "post-json" (withBody base (json "{\"n\": 1}")) Post echo;
		request "post-empty" base Post echo;
		request "put" (withBody base {ContentType = "text/plain", Data = textBlob "put this"}) Put echo;
		request "patch" (withBody base (json "[]")) Patch echo;
		request "delete" base Delete echo;
		request "head" base Head echo;
		request "custom-method" base (Method "PROPFIND") echo;
		request "get-with-body" (withBody base (json "{}")) Get echo;

		(* Headers *)
		request "headers"
			(
				withHeaders base
					(
							("X-One", "1")
						::
							("X-Dup", "first")
						::
							("X-Dup", "second")
						::
							("User-Agent", "test/0")
						::
							("Expect", "100-continue")
						::
							[]
					)
			)
			Get
			echo;
		request "response-headers" base Get (at http "/headers");
		(
			io_debug "--- lookup-header";
			r <- perform base Get (at http "/headers");
			case r of
			| Answered r =>
				(
					io_debug ("x-two: " ^ showOption (lookupHeader "x-two" r));
					io_debug ("set-cookie: " ^ showOption (lookupHeader "Set-Cookie" r));
					io_debug ("x-none: " ^ showOption (lookupHeader "X-None" r))
				)
			| o => io_debug ("outcome: " ^ show o)
		);

		(* Statuses: all answers *)
		request "status-404" base Get (at http "/status/404");
		request "status-500" base Get (at http "/status/500");
		request "nocontent" base Get (at http "/nocontent");
		request "gzip" base Get (at http "/gzip");

		(* Authentication *)
		request "bearer" (base -- #Auth ++ {Auth = Bearer "tok-123"}) Get echo;
		request "basic-ok" (base -- #Auth ++ {Auth = Basic {User = "user", Password = "secret"}}) Get (at http "/auth");
		request "basic-wrong" (base -- #Auth ++ {Auth = Basic {User = "user", Password = "wrong"}}) Get (at http "/auth");

		(* Redirects *)
		request "redirect-not-followed" base Get (at http "/redirect/2");
		request "redirect-followed" (base -- #FollowRedirects ++ {FollowRedirects = 3}) Get (at http "/redirect/2");
		request "redirect-too-many" (base -- #FollowRedirects ++ {FollowRedirects = 1}) Get (at http "/redirect/2");

		(* Sizes *)
		request "big-under-limit" base Get (at http "/big/100000");
		request "too-large" (base -- #MaxResponse ++ {MaxResponse = kib 1}) Get (at http "/big/5000");

		(* Failures: told apart by whether the request went out *)
		request "timeout" (base -- #Timeout ++ {Timeout = {Connect = sec 5, Total = ms 500}}) Get (at http "/slow/3");
		request "drop" base Get (at http "/drop");
		request "refused" base Get (at closed "/echo");
		request "unresolvable" base Get (bless "http://nonexistent.invalid/echo");

		(* TLS *)
		request "tls-untrusted" base Get secure;
		request "tls-ca" (base -- #Tls ++ {Tls = Verify (Some ca)}) Get secure;
		request "tls-noverify" (base -- #Tls ++ {Tls = NoVerify}) Get secure;

		(* Options perform refuses *)
		request "bad-header-name" (withHeaders base (("X Y", "1") :: [])) Get echo;
		request "bad-header-value" (withHeaders base (("X-One", "a\r\nX-Two: b") :: [])) Get echo;
		request "content-type-header" (withHeaders (withBody base (json "{}")) (("Content-Type", "text/plain") :: [])) Post echo;
		request "head-with-body" (withBody base (json "{}")) Head echo;
		request "bad-method" base (Method "GE T") echo;
		request "bad-timeout" (base -- #Timeout ++ {Timeout = {Connect = ms 0, Total = sec 5}}) Get echo;
		request "bad-limit" (base -- #MaxResponse ++ {MaxResponse = bytes 0}) Get echo;
		request "bad-redirects" (base -- #FollowRedirects ++ {FollowRedirects = -1}) Get echo;
		request "bad-ca" (base -- #Tls ++ {Tls = Verify (Some "")}) Get echo;
		request "bad-bearer" (base -- #Auth ++ {Auth = Bearer "a\nb"}) Get echo;

		(* Encoding *)
		io_debug "--- escape";
		io_debug ("escaped: " ^ escape "a b/ü&~-_.");

		io_debug "--- end"
	end

task periodic 3600 =
	fn () =>
		all ()

fun main () = return <xml/>
