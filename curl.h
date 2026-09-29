#include <urweb.h>

// CurlFfi (curlFfi.urs) in C.

typedef struct request *uw_CurlFfi_request;
typedef struct completed *uw_CurlFfi_completed;

// CurlFfi.outcome, laid out as the compiler expects a datatype declared in
// an FFI signature: the struct's tag is an enum whose constants are
// uw_Module_Con, and a constructor's argument is the union member uw_Con.
enum uw_CurlFfi_outcome_tag {
  uw_CurlFfi_Answered,
  uw_CurlFfi_NotSent,
  uw_CurlFfi_MaybeSent,
  uw_CurlFfi_ResponseTooLarge
};
struct uw_CurlFfi_outcome {
  enum uw_CurlFfi_outcome_tag tag;
  union {
    uw_Basis_string uw_NotSent;
    uw_Basis_string uw_MaybeSent;
  } data;
};
typedef struct uw_CurlFfi_outcome *uw_CurlFfi_outcome;

uw_CurlFfi_request uw_CurlFfi_make(uw_context, uw_Basis_string method, uw_Basis_string url);
uw_CurlFfi_request uw_CurlFfi_header(uw_context, uw_Basis_string, uw_Basis_string, uw_CurlFfi_request);
uw_CurlFfi_request uw_CurlFfi_body(uw_context, uw_Basis_string, uw_Basis_blob, uw_CurlFfi_request);
uw_CurlFfi_request uw_CurlFfi_basicAuth(uw_context, uw_Basis_string, uw_Basis_string, uw_CurlFfi_request);
uw_CurlFfi_request uw_CurlFfi_timeout(uw_context, uw_Basis_int, uw_Basis_int, uw_CurlFfi_request);
uw_CurlFfi_request uw_CurlFfi_maxResponse(uw_context, uw_Basis_int, uw_CurlFfi_request);
uw_CurlFfi_request uw_CurlFfi_followRedirects(uw_context, uw_Basis_int, uw_CurlFfi_request);
uw_CurlFfi_request uw_CurlFfi_caFile(uw_context, uw_Basis_string, uw_CurlFfi_request);
uw_CurlFfi_request uw_CurlFfi_noVerify(uw_context, uw_CurlFfi_request);

uw_CurlFfi_completed uw_CurlFfi_perform(uw_context, uw_CurlFfi_request);
uw_CurlFfi_outcome uw_CurlFfi_outcomeOf(uw_context, uw_CurlFfi_completed);
uw_Basis_int uw_CurlFfi_statusOf(uw_context, uw_CurlFfi_completed);
uw_Basis_int uw_CurlFfi_headerCount(uw_context, uw_CurlFfi_completed);
uw_Basis_string uw_CurlFfi_headerName(uw_context, uw_CurlFfi_completed, uw_Basis_int);
uw_Basis_string uw_CurlFfi_headerValue(uw_context, uw_CurlFfi_completed, uw_Basis_int);
uw_Basis_blob uw_CurlFfi_bodyOf(uw_context, uw_CurlFfi_completed);

uw_Basis_string uw_CurlFfi_escape(uw_context, uw_Basis_string);
