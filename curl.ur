(* n * k, or the largest int of its sign where that does not fit: the
   product would otherwise overflow in the generated C. *)
val maxInt = 9223372036854775807
fun times (n : int) (k : int) : int =
	if n > maxInt / k then
		maxInt
	else if n < 0 - maxInt / k then
		0 - maxInt
	else
		n * k

type duration = int (* milliseconds *)
fun ms n = n
fun sec n = times n 1000
fun showDuration (d : int) =
	if d <> 0 && d % 1000 = 0 then
		show (d / 1000) ^ " s"
	else
		show d ^ " ms"

type blobSize = int (* bytes *)
fun bytes n = n
fun kb n = times n 1000
fun mb n = times n 1000000
fun kib n = times n 1024
fun mib n = times n 1048576
fun showBlobSize (b : int) =
	if b <> 0 && b % 1048576 = 0 then
		show (b / 1048576) ^ " MiB"
	else if b <> 0 && b % 1024 = 0 then
		show (b / 1024) ^ " KiB"
	else
		show b ^ " bytes"

datatype method = Get | Head | Post | Put | Patch | Delete | Method of string

fun methodName m =
	case m of
	| Get => "GET"
	| Head => "HEAD"
	| Post => "POST"
	| Put => "PUT"
	| Patch => "PATCH"
	| Delete => "DELETE"
	| Method s => s

val show_method = mkShow methodName

datatype auth =
	| NoAuth
	| Basic of {User : string, Password : string}
	| Bearer of string

datatype tls =
	| Verify of option string
	| NoVerify

type body = {ContentType : string, Data : blob}

fun join (sep : string) (ls : list string) : string =
	case ls of
	| [] => ""
	| s :: [] => s
	| s :: ls => s ^ sep ^ join sep ls

fun form (fields : list (string * string)) : body =
	{
		ContentType = "application/x-www-form-urlencoded",
		Data = textBlob (join "&" (List.mp (fn (k, v) => CurlFfi.escape k ^ "=" ^ CurlFfi.escape v) fields))
	}

fun json (text : string) : body =
	{ContentType = "application/json", Data = textBlob text}

type opts =
	{
		Headers : list (string * string),
		Body : option body,
		Auth : auth,
		Tls : tls,
		Timeout : {Connect : duration, Total : duration},
		MaxResponse : blobSize,
		FollowRedirects : int
	}

structure Opts =
	struct
		val default =
			{
				Headers = [],
				Body = None,
				Auth = NoAuth,
				Tls = Verify None,
				Timeout = {Connect = sec 10, Total = sec 60},
				MaxResponse = mib 16,
				FollowRedirects = 0
			}
	end

type response = {Status : int, Headers : list (string * string), Body : blob}

fun lower (s : string) : string = String.mp Char.toLower s

fun lookupHeader (name : string) (r : response) : option string =
	let
		val name = lower name
	in
		Option.mp (fn (_, v) => v) (List.find (fn (n, _) => lower n = name) r.Headers)
	end

datatype outcome =
	| Answered of response
	| BadOpts of string
	| NotSent of string
	| MaybeSent of string
	| ResponseTooLarge of blobSize

val show_outcome =
	mkShow
		(
			fn o =>
				case o of
				| Answered r => "answered " ^ show r.Status ^ ", " ^ showBlobSize (blobSize r.Body)
				| BadOpts m => "bad options: " ^ m
				| NotSent m => "not sent: " ^ m
				| MaybeSent m => "maybe sent: " ^ m
				| ResponseTooLarge b => "response over " ^ showBlobSize b
		)

(* Only now: duration and blobSize are int in here, and an instance declared
   earlier would have been picked for every int shown above. *)
val show_duration = mkShow showDuration
val show_blobSize = mkShow showBlobSize

(* A token character of HTTP (RFC 9110): what a header name or a method may
   hold. *)
fun isTchar (c : char) : bool =
	(Char.isAlnum c && ord c < 128)
		|| c = #"!"
		|| c = #"#"
		|| c = #"$"
		|| c = #"%"
		|| c = #"&"
		|| c = #"'"
		|| c = #"*"
		|| c = #"+"
		|| c = #"-"
		|| c = #"."
		|| c = #"^"
		|| c = #"_"
		|| c = #"`"
		|| c = #"|"
		|| c = #"~"

fun isToken (s : string) : bool = s <> "" && String.all isTchar s

fun hasLineBreak (s : string) : bool =
	Option.isSome (String.index s #"\r") || Option.isSome (String.index s #"\n")

(* What makes the options unusable for a request of this method, if anything. *)
fun problem (o : opts) (m : method) : option string =
	case List.find (fn (n, _) => not (isToken n)) o.Headers of
	| Some (n, _) => Some ("invalid header name \"" ^ n ^ "\"")
	| None =>
		case List.find (fn (_, v) => hasLineBreak v) o.Headers of
		| Some (n, _) => Some ("line break in the value of header " ^ n)
		| None =>
			if Option.isSome o.Body && List.exists (fn (n, _) => lower n = "content-type") o.Headers then
				Some "Content-Type is given by the body, not as a header"
			else if Option.isSome o.Body && (case m of Head => True | _ => False) then
				Some "a HEAD request has no body"
			else if (case o.Body of Some b => hasLineBreak b.ContentType | None => False) then
				Some "line break in the body's Content-Type"
			else if not (isToken (methodName m)) then
				Some ("invalid method \"" ^ methodName m ^ "\"")
			else if o.Timeout.Connect <= 0 || o.Timeout.Total <= 0 then
				Some "the timeouts must be positive"
			else if o.MaxResponse <= 0 then
				Some "the response limit must be positive"
			else if o.FollowRedirects < 0 then
				Some "the redirect count must not be negative"
			else if (case o.Tls of Verify (Some "") => True | _ => False) then
				Some "empty CA file name"
			else if (case o.Auth of Bearer t => hasLineBreak t | _ => False) then
				Some "line break in the bearer token"
			else
				None

fun headersOf (c : CurlFfi.completed) : list (string * string) =
	let
		fun go i acc =
			if i < 0 then
				acc
			else
				go (i - 1) ((CurlFfi.headerName c i, CurlFfi.headerValue c i) :: acc)
	in
		go (CurlFfi.headerCount c - 1) []
	end

fun perform (o : opts) (m : method) (u : url) : io outcome =
	case problem o m of
	| Some p => return (BadOpts p)
	| None =>
		let
			fun header (n, v) r = CurlFfi.header n v r
			val r = CurlFfi.make (methodName m) u
			val r = List.foldl header r o.Headers
			val r = case o.Body of None => r | Some b => CurlFfi.body b.ContentType b.Data r
			val r =
				case o.Auth of
				| NoAuth => r
				| Basic b => CurlFfi.basicAuth b.User b.Password r
				| Bearer t => CurlFfi.header "Authorization" ("Bearer " ^ t) r
			val r =
				case o.Tls of
				| Verify None => r
				| Verify (Some ca) => CurlFfi.caFile ca r
				| NoVerify => CurlFfi.noVerify r
			val r = CurlFfi.timeout o.Timeout.Connect o.Timeout.Total r
			val r = CurlFfi.maxResponse o.MaxResponse r
			val r = CurlFfi.followRedirects o.FollowRedirects r
		in
			c <- CurlFfi.perform r;
			return
				(
					case CurlFfi.outcomeOf c of
					| CurlFfi.Answered =>
						Answered
							{
								Status = CurlFfi.statusOf c,
								Headers = headersOf c,
								Body = CurlFfi.bodyOf c
							}
					| CurlFfi.NotSent m => NotSent m
					| CurlFfi.MaybeSent m => MaybeSent m
					| CurlFfi.ResponseTooLarge => ResponseTooLarge o.MaxResponse
				)
		end

val escape = CurlFfi.escape
