(* The C side of urweb-curl, for Curl (curl.ur) to wrap.  Applications use
   Curl.

   Low level and unchecked where the wrapper checks: Curl.perform validates
   the options first (header names and values, timeouts, limits), and what
   is given here is passed to libcurl as it is. *)

(* A request to make.  Immutable: a builder returns a new request and leaves
   its argument as it was.  Settings given twice: the last one counts, but
   for headers, which are all sent, in the order given. *)
type request

(* A request of the method, as it goes on the wire (GET, POST, ...), to the URL. *)
val make : string -> url -> request
val header : string -> string -> request -> request
(* The body, with its media type (the Content-Type header). *)
val body : string -> blob -> request -> request
val basicAuth : string -> string -> request -> request
(* Milliseconds: to connect, and for the whole transfer. *)
val timeout : int -> int -> request -> request
(* Bytes of response (headers and body) beyond which the transfer is given up. *)
val maxResponse : int -> request -> request
(* How many redirects to follow; 0: none, the 3xx is the answer. *)
val followRedirects : int -> request -> request
(* The CA file to verify the server's certificate against, instead of the
   system's; or no verification at all. *)
val caFile : string -> request -> request
val noVerify : request -> request

(* What became of a request; the sizes and the bad-options case are the
   wrapper's. *)
datatype outcome =
	| Answered (* the server answered, with any status *)
	| NotSent of string (* nothing of the request reached the server *)
	| MaybeSent of string (* the request went out, no complete answer came back *)
	| ResponseTooLarge (* answered, with more than the limit *)

(* A finished request. *)
type completed

val perform : request -> io completed
val outcomeOf : completed -> outcome
(* The answer, when there is one: the status code, the headers of the final
   response (name and value, by position), and the body. *)
val statusOf : completed -> int
val headerCount : completed -> int
val headerName : completed -> int -> string
val headerValue : completed -> int -> string
val bodyOf : completed -> blob

(* Percent-encoding of the bytes of a string, as a form field or a URL
   component needs it: everything but the unreserved characters. *)
val escape : string -> string
