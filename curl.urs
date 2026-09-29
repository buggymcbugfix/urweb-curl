(** HTTP requests from io code *)

type duration
val ms : int -> duration
val sec : int -> duration
val show_duration : show duration

(* kb, mb, kib and mib of a number too large give the largest size. *)
type blobSize
val bytes : int -> blobSize
val kb : int -> blobSize (* 1000 bytes *)
val mb : int -> blobSize
val kib : int -> blobSize (* 1024 bytes *)
val mib : int -> blobSize
val show_blobSize : show blobSize

datatype method =
	| Get
	| Head
	| Post
	| Put
	| Patch
	| Delete
	| Method of string (* any other, as it goes on the wire *)
val show_method : show method

datatype auth =
	| NoAuth
	| Basic of {User : string, Password : string}
	| Bearer of string (* an Authorization: Bearer header *)

(* How the server's certificate is checked for an https URL. *)
datatype tls =
	| Verify of option string (* against the CA file given, or the system's CAs *)
	| NoVerify (* not at all: for a development server with a
									self-signed certificate; never for production,
									since anyone on the path can then read the
									request *)

(* The body of a request: its media type and its bytes. *)
type body = {ContentType : string, Data : blob}

(* application/x-www-form-urlencoded: the fields percent-encoded (the bytes
   of UTF-8, as libcurl does it) and joined with & and =. *)
val form : list (string * string) -> body
(* application/json, the text as given. *)
val json : string -> body

type opts =
	{
		Headers : list (string * string), (* sent in this order, after
															the body's Content-Type *)
		Body : option body,
		Auth : auth,
		Tls : tls,
		Timeout :
			{
				Connect : duration, (* to connect *)
				Total : duration
			}, (* for the whole request *)
		MaxResponse : blobSize, (* headers and body; over
												 it, ResponseTooLarge *)
		FollowRedirects : int
	} (* how many; 0: the 3xx is
											 the answer *)

structure Opts :
	sig
		(* No headers, no body, no authentication, certificates verified against
		   the system's CAs, 10 s to connect and 60 s in all, a response of up to
		   16 MiB, no redirects followed. *)
		val default : opts
	end

(* An answer: the status code, the headers of the final response (name and
   value, in the order received, as the server sent them; a header sent twice
   is there twice), and the body, decoded if the server compressed it.  With
   redirects followed, the final response is the last one; when more than
   FollowRedirects were needed, it is the last 3xx, as with none followed. *)
type response = {Status : int, Headers : list (string * string), Body : blob}

(* The first header of that name, case-insensitively. *)
val lookupHeader : string -> response -> option string

datatype outcome =
	| Answered of
		response (* the server answered, with any status: the
										caller judges *)
	| BadOpts of
		string (* the options are not usable; nothing was
											sent *)
	| NotSent of
		string (* nothing of the request reached the server:
											the name did not resolve, the connection
											or the TLS handshake failed, or it timed
											out before sending; sending again is
											safe *)
	| MaybeSent of
		string (* the request went out and no complete
											answer came back: the connection was lost
											or the transfer timed out; the server may
											have acted on it, so sending again may
											act twice *)
	| ResponseTooLarge of
		blobSize (* the server answered with more than the
											limit; it has acted, and the answer was
											given up *)

val show_outcome : show outcome

(* Make a request now and say what became of it.  In io, since a request
   cannot be undone: an io task or an io RPC claims what is to be sent in one
   transaction, sends, and records the outcome in another.  The URL is one the
   application's `allow url` rules admit, http or https; only those two
   schemes are spoken, redirects included.  What run refuses with BadOpts: a
   header whose name is empty or holds anything but token characters, a
   header value with a line break, a Content-Type header beside a body, a
   body on a HEAD request, an empty method or one with a space or a line
   break, a timeout that is not positive, a limit that is not positive, a
   negative redirect count, an empty CA file name.

   The connection to a server that keeps it open is kept by the task for its
   next request.  URWEB_CURL_DEBUG=1 traces every request on stderr, with the
   Authorization header's value left out. *)
val perform : opts -> method -> url -> io outcome

(* Percent-encoding of the bytes of a string, as a form field or a query
   parameter needs it: everything but letters, digits, - . _ ~ as %XX. *)
val escape : string -> string
