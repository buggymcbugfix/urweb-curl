#include "config.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include <curl/curl.h>

#include <urweb/urweb.h>
#include "curl.h"

#define USER_AGENT "urweb-curl/" PACKAGE_VERSION

/* ---- Requests: an immutable list of settings, newest first ---- */

typedef enum { HEADER, BODY, BASIC_AUTH, TIMEOUT, MAX_RESPONSE, REDIRECTS, CA_FILE, NO_VERIFY } setting_kind;

struct setting {
  setting_kind kind;
  const char *a, *b;      // HEADER: a: b; BODY: a the media type; BASIC_AUTH: a, b; CA_FILE: a
  uw_Basis_blob blob;     // BODY
  long long n, m;         // TIMEOUT: n to connect, m in all (ms); MAX_RESPONSE, REDIRECTS: n
  const struct setting *next;
};

struct request {
  const char *method, *url;
  const struct setting *settings;
};

static uw_CurlFfi_request with(uw_context ctx, uw_CurlFfi_request r, struct setting s) {
  struct setting *n = uw_malloc(ctx, sizeof *n);
  struct request *r2 = uw_malloc(ctx, sizeof *r2);

  *n = s;
  n->next = r->settings;
  *r2 = *r;
  r2->settings = n;
  return r2;
}

uw_CurlFfi_request uw_CurlFfi_make(uw_context ctx, uw_Basis_string method, uw_Basis_string url) {
  struct request *r = uw_malloc(ctx, sizeof *r);

  r->method = method;
  r->url = url;
  r->settings = NULL;
  return r;
}

uw_CurlFfi_request uw_CurlFfi_header(uw_context ctx, uw_Basis_string name, uw_Basis_string value,
                                     uw_CurlFfi_request r) {
  struct setting s = {.kind = HEADER, .a = name, .b = value};
  return with(ctx, r, s);
}

uw_CurlFfi_request uw_CurlFfi_body(uw_context ctx, uw_Basis_string type, uw_Basis_blob data,
                                   uw_CurlFfi_request r) {
  struct setting s = {.kind = BODY, .a = type, .blob = data};
  return with(ctx, r, s);
}

uw_CurlFfi_request uw_CurlFfi_basicAuth(uw_context ctx, uw_Basis_string user, uw_Basis_string password,
                                        uw_CurlFfi_request r) {
  struct setting s = {.kind = BASIC_AUTH, .a = user, .b = password};
  return with(ctx, r, s);
}

uw_CurlFfi_request uw_CurlFfi_timeout(uw_context ctx, uw_Basis_int connect, uw_Basis_int total,
                                      uw_CurlFfi_request r) {
  struct setting s = {.kind = TIMEOUT, .n = connect, .m = total};
  return with(ctx, r, s);
}

uw_CurlFfi_request uw_CurlFfi_maxResponse(uw_context ctx, uw_Basis_int max, uw_CurlFfi_request r) {
  struct setting s = {.kind = MAX_RESPONSE, .n = max};
  return with(ctx, r, s);
}

uw_CurlFfi_request uw_CurlFfi_followRedirects(uw_context ctx, uw_Basis_int n, uw_CurlFfi_request r) {
  struct setting s = {.kind = REDIRECTS, .n = n};
  return with(ctx, r, s);
}

uw_CurlFfi_request uw_CurlFfi_caFile(uw_context ctx, uw_Basis_string file, uw_CurlFfi_request r) {
  struct setting s = {.kind = CA_FILE, .a = file};
  return with(ctx, r, s);
}

uw_CurlFfi_request uw_CurlFfi_noVerify(uw_context ctx, uw_CurlFfi_request r) {
  struct setting s = {.kind = NO_VERIFY};
  return with(ctx, r, s);
}

/* ---- The libcurl handle: one per context, kept for its connections ---- */

static pthread_once_t curl_once = PTHREAD_ONCE_INIT;

static void curl_init(void) {
  curl_global_init(CURL_GLOBAL_DEFAULT);
}

// One easy handle per context, kept across requests, so that a connection to
// a server that keeps it open is used again by the next request from the
// same task; it is reset before each request, which keeps the connections.
static CURL *handle(uw_context ctx) {
  CURL *c;

  pthread_once(&curl_once, curl_init);
  c = uw_get_global(ctx, "urweb-curl");
  if (!c) {
    c = curl_easy_init();
    if (!c)
      uw_error(ctx, FATAL, "urweb-curl: cannot create a libcurl handle");
    uw_set_global(ctx, "urweb-curl", c, (void (*)(void *))curl_easy_cleanup);
  }
  return c;
}

// Debug tracing, on stderr, when URWEB_CURL_DEBUG is set to anything but ""
// or "0".
static int debugging(void) {
  static int state = -1;

  if (state < 0) {
    const char *v = getenv("URWEB_CURL_DEBUG");
    state = v && v[0] && strcmp(v, "0") != 0;
  }
  return state;
}

/* ---- One request under way ---- */

typedef struct {
  char *data;
  size_t len, cap;
} buffer;

struct header {
  char *name, *value;
};

typedef struct {
  buffer body;
  struct header *headers;
  size_t nheaders, capheaders;
  size_t limit, total;     // bytes of headers and body allowed, and seen
  int too_large;           // the limit was passed: the transfer was given up
  int out_of_memory;       // malloc failed in a callback: the transfer was given up
  struct curl_slist *slist;
} transfer;

static void free_headers(transfer *t) {
  size_t i;

  for (i = 0; i < t->nheaders; ++i) {
    free(t->headers[i].name);
    free(t->headers[i].value);
  }
  t->nheaders = 0;
}

// Everything the transfer holds outside the Ur/Web heap; on the context's
// cleanup stack while it runs, for a uw_error on the way.
static void release(void *p) {
  transfer *t = p;

  free(t->body.data);
  free_headers(t);
  free(t->headers);
  curl_slist_free_all(t->slist);
  free(t);
}

static int append(buffer *b, const char *data, size_t n) {
  if (b->cap - b->len < n) {
    size_t cap = b->cap ? b->cap : 4096;
    char *d;

    while (cap - b->len < n)
      cap *= 2;
    d = realloc(b->data, cap);
    if (!d)
      return 0;
    b->data = d;
    b->cap = cap;
  }
  memcpy(b->data + b->len, data, n);
  b->len += n;
  return 1;
}

// Over the limit: give the transfer up; libcurl then fails with
// CURLE_WRITE_ERROR, which perform reads as the response being too large.
static int over(transfer *t, size_t n) {
  if (n > t->limit - t->total) {
    t->too_large = 1;
    return 1;
  }
  t->total += n;
  return 0;
}

static size_t write_body(void *data, size_t size, size_t nmemb, void *p) {
  transfer *t = p;
  size_t n = size * nmemb;

  if (over(t, n))
    return 0;
  if (!append(&t->body, data, n)) {
    t->out_of_memory = 1;
    return 0;
  }
  return n;
}

// libcurl hands over one header line at a time, CRLF included, with the
// status line first and an empty line last; with redirects followed, or a
// 100 Continue, that happens once per response, and only the last response's
// headers are kept.
static size_t read_header(char *line, size_t size, size_t nmemb, void *p) {
  transfer *t = p;
  size_t n = size * nmemb, len = n, namelen;
  const char *colon, *value;
  struct header h;

  if (over(t, n))
    return 0;
  while (len > 0 && (line[len - 1] == '\r' || line[len - 1] == '\n'))
    --len;
  if (len == 0)
    return n;
  if (len >= 5 && !strncmp(line, "HTTP/", 5)) {
    free_headers(t);
    return n;
  }
  colon = memchr(line, ':', len);
  if (!colon)
    return n;   // not a header; ignored
  namelen = colon - line;
  value = colon + 1;
  while (value < line + len && (*value == ' ' || *value == '\t'))
    ++value;
  if (t->nheaders == t->capheaders) {
    size_t cap = t->capheaders ? 2 * t->capheaders : 16;
    struct header *hs = realloc(t->headers, cap * sizeof *hs);

    if (!hs) {
      t->out_of_memory = 1;
      return 0;
    }
    t->headers = hs;
    t->capheaders = cap;
  }
  h.name = strndup(line, namelen);
  h.value = strndup(value, line + len - value);
  if (!h.name || !h.value) {
    free(h.name);
    free(h.value);
    t->out_of_memory = 1;
    return 0;
  }
  t->headers[t->nheaders++] = h;
  return n;
}

// libcurl's own trace, as CURLOPT_VERBOSE would print it, less the value of
// the Authorization header (a password or a token), and less the bodies.
static int trace(CURL *c, curl_infotype type, char *data, size_t size, void *p) {
  const char *prefix;
  (void)c; (void)p;

  switch (type) {
  case CURLINFO_TEXT: prefix = "* "; break;
  case CURLINFO_HEADER_OUT: prefix = "> "; break;
  case CURLINFO_HEADER_IN: prefix = "< "; break;
  default: return 0;
  }
  if (type == CURLINFO_HEADER_OUT) {
    // A block of lines, the whole request header.
    size_t i = 0;

    while (i < size) {
      size_t j = i;

      while (j < size && data[j] != '\n')
        ++j;
      if (j - i >= 14 && !strncasecmp(data + i, "Authorization:", 14))
        fprintf(stderr, "%sAuthorization: [redacted]\n", prefix);
      else
        fprintf(stderr, "%s%.*s\n", prefix, (int)(j - i - (j > i && data[j - 1] == '\r')), data + i);
      i = j + 1;
    }
    return 0;
  }
  while (size > 0 && (data[size - 1] == '\n' || data[size - 1] == '\r'))
    --size;
  fprintf(stderr, "%s%.*s\n", prefix, (int)size, data);
  return 0;
}

static struct curl_slist *add_header(transfer *t, const char *line) {
  struct curl_slist *l = curl_slist_append(t->slist, line);

  if (l)
    t->slist = l;
  return l;
}

// The request's headers, as an slist for libcurl: the ones given, in order;
// the body's Content-Type, or none; a User-Agent and an empty Expect unless
// given (the Expect: 100-continue libcurl would send with a large body costs
// a round trip, or a second's wait with servers that ignore it).
static int set_headers(transfer *t, const struct setting *settings, const char *body_type) {
  const struct setting *s, **rev;
  size_t n = 0, i;
  int have_ua = 0, have_expect = 0;

  // Newest first in the list; sent in the order given.
  for (s = settings; s; s = s->next)
    if (s->kind == HEADER)
      ++n;
  rev = malloc((n ? n : 1) * sizeof *rev);
  if (!rev)
    return 0;
  n = 0;
  for (s = settings; s; s = s->next)
    if (s->kind == HEADER)
      rev[n++] = s;
  for (i = n; i > 0; --i) {
    size_t len;
    char *line;

    s = rev[i - 1];
    len = strlen(s->a) + 2 + strlen(s->b) + 1;
    line = malloc(len);
    if (!line) {
      free(rev);
      return 0;
    }
    snprintf(line, len, "%s: %s", s->a, s->b);
    if (!add_header(t, line)) {
      free(line);
      free(rev);
      return 0;
    }
    free(line);
    if (!strcasecmp(s->a, "User-Agent"))
      have_ua = 1;
    if (!strcasecmp(s->a, "Expect"))
      have_expect = 1;
  }
  free(rev);
  if (body_type) {
    size_t len = strlen("Content-Type: ") + strlen(body_type) + 1;
    char *line = malloc(len);

    if (!line)
      return 0;
    snprintf(line, len, "Content-Type: %s", body_type);
    if (!add_header(t, line)) {
      free(line);
      return 0;
    }
    free(line);
  } else if (!add_header(t, "Content-Type:")) {
    // No body, no Content-Type: not even the application/x-www-form-urlencoded
    // libcurl assumes for a POST.
    return 0;
  }
  if (!have_ua && !add_header(t, "User-Agent: " USER_AGENT))
    return 0;
  if (!have_expect && !add_header(t, "Expect:"))
    return 0;
  return 1;
}

/* ---- Results ---- */

struct completed {
  uw_CurlFfi_outcome outcome;
  uw_Basis_int status;
  uw_Basis_int nheaders;
  struct header *headers;   // names and values on the Ur/Web heap
  uw_Basis_blob body;
};

static uw_CurlFfi_outcome outcome(uw_context ctx, enum uw_CurlFfi_outcome_tag tag, const char *msg) {
  uw_CurlFfi_outcome o = uw_malloc(ctx, sizeof *o);

  o->tag = tag;
  if (tag == uw_CurlFfi_NotSent)
    o->data.uw_NotSent = uw_strdup(ctx, msg);
  else if (tag == uw_CurlFfi_MaybeSent)
    o->data.uw_MaybeSent = uw_strdup(ctx, msg);
  return o;
}

// The libcurl error as a message: what it wrote to the error buffer, the
// more specific text, else the code's description.
static const char *failure(CURLcode code, const char *errbuf) {
  return errbuf[0] ? errbuf : curl_easy_strerror(code);
}

// CurlFfi.perform, in io: make the request now, and say what became of it.
uw_CurlFfi_completed uw_CurlFfi_perform(uw_context ctx, uw_CurlFfi_request r) {
  CURL *c = handle(ctx);
  transfer *t = calloc(1, sizeof *t);
  struct completed *result;
  const struct setting *s;
  const char *body_type = NULL, *ca_file = NULL, *user = NULL, *password = NULL;
  uw_Basis_blob body = {0, NULL};
  long long connect_ms = 10000, total_ms = 60000, redirects = 0;
  int no_verify = 0, has_body = 0, has_timeout = 0, has_limit = 0, has_redirects = 0;
  char errbuf[CURL_ERROR_SIZE] = "";
  CURLcode code;
  long status = 0, request_size = 0;
  curl_off_t uploaded = 0;
  size_t i;

  if (!t)
    uw_error(ctx, FATAL, "urweb-curl: out of memory");
  t->limit = (size_t)16 << 20;
  // Within this call nothing else touches the cleanup stack, so this runs
  // exactly once: by uw_pop_cleanup below, or by a uw_error on the way.
  uw_push_cleanup(ctx, release, t);

  // The settings: the list is newest first, so the first of a kind seen is
  // the last given, which counts.
  for (s = r->settings; s; s = s->next)
    switch (s->kind) {
    case HEADER: break;
    case BODY: if (!has_body) { has_body = 1; body_type = s->a; body = s->blob; } break;
    case BASIC_AUTH: if (!user) { user = s->a; password = s->b; } break;
    case TIMEOUT: if (!has_timeout) { has_timeout = 1; connect_ms = s->n; total_ms = s->m; } break;
    case MAX_RESPONSE: if (!has_limit) { has_limit = 1; t->limit = s->n < 0 ? 0 : (size_t)s->n; } break;
    case REDIRECTS: if (!has_redirects) { has_redirects = 1; redirects = s->n; } break;
    case CA_FILE: if (!ca_file) ca_file = s->a; break;
    case NO_VERIFY: no_verify = 1; break;
    }

  curl_easy_reset(c);
  curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);  // threads: no SIGALRM for timeouts
  curl_easy_setopt(c, CURLOPT_URL, r->url);
  curl_easy_setopt(c, CURLOPT_ERRORBUFFER, errbuf);
  curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, write_body);
  curl_easy_setopt(c, CURLOPT_WRITEDATA, t);
  curl_easy_setopt(c, CURLOPT_HEADERFUNCTION, read_header);
  curl_easy_setopt(c, CURLOPT_HEADERDATA, t);
  curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT_MS, (long)(connect_ms > 0x7fffffffL ? 0x7fffffffL : connect_ms));
  curl_easy_setopt(c, CURLOPT_TIMEOUT_MS, (long)(total_ms > 0x7fffffffL ? 0x7fffffffL : total_ms));
  curl_easy_setopt(c, CURLOPT_ACCEPT_ENCODING, "");  // whatever libcurl can decode, decoded
#if LIBCURL_VERSION_NUM >= 0x075500
  curl_easy_setopt(c, CURLOPT_PROTOCOLS_STR, "http,https");
  curl_easy_setopt(c, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
#else
  curl_easy_setopt(c, CURLOPT_PROTOCOLS, (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
  curl_easy_setopt(c, CURLOPT_REDIR_PROTOCOLS, (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
#endif
  if (redirects > 0) {
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(c, CURLOPT_MAXREDIRS, (long)redirects);
  }
  if (ca_file)
    curl_easy_setopt(c, CURLOPT_CAINFO, ca_file);
  if (no_verify) {
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYHOST, 0L);
  }
  if (user) {
    curl_easy_setopt(c, CURLOPT_HTTPAUTH, (long)CURLAUTH_BASIC);
    curl_easy_setopt(c, CURLOPT_USERNAME, user);
    curl_easy_setopt(c, CURLOPT_PASSWORD, password);
  }
  if (debugging()) {
    curl_easy_setopt(c, CURLOPT_VERBOSE, 1L);
    curl_easy_setopt(c, CURLOPT_DEBUGFUNCTION, trace);
  }

  // The method, and the body with it.  POSTFIELDS makes a POST unless the
  // method is set explicitly, and is copied since the handle outlives the
  // request; the size goes first, so that the copy is not measured with
  // strlen.
  if (!strcmp(r->method, "GET") && !has_body)
    curl_easy_setopt(c, CURLOPT_HTTPGET, 1L);
  else if (!strcmp(r->method, "HEAD") && !has_body)
    curl_easy_setopt(c, CURLOPT_NOBODY, 1L);
  else if (!strcmp(r->method, "POST"))
    curl_easy_setopt(c, CURLOPT_POST, 1L);
  else
    curl_easy_setopt(c, CURLOPT_CUSTOMREQUEST, r->method);
  if (has_body || !strcmp(r->method, "POST")) {
    curl_easy_setopt(c, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body.size);
    curl_easy_setopt(c, CURLOPT_COPYPOSTFIELDS, body.size ? body.data : "");
  }

  if (!set_headers(t, r->settings, body_type))
    uw_error(ctx, FATAL, "urweb-curl: out of memory");
  curl_easy_setopt(c, CURLOPT_HTTPHEADER, t->slist);

  code = curl_easy_perform(c);
  if (t->out_of_memory)
    uw_error(ctx, FATAL, "urweb-curl: out of memory");

  // The verdict: an answer, which the last of too many redirects is as well
  // (a 3xx, as with no redirects followed); too much of one; or a failure,
  // told apart by whether any of the request went out.
  result = uw_malloc(ctx, sizeof *result);
  result->status = 0;
  result->nheaders = 0;
  result->headers = NULL;
  result->body.size = 0;
  result->body.data = NULL;
  if (code == CURLE_OK || code == CURLE_TOO_MANY_REDIRECTS) {
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status);
    result->outcome = outcome(ctx, uw_CurlFfi_Answered, NULL);
    result->status = status;
    result->nheaders = t->nheaders;
    result->headers = uw_malloc(ctx, (t->nheaders ? t->nheaders : 1) * sizeof *result->headers);
    for (i = 0; i < t->nheaders; ++i) {
      result->headers[i].name = uw_strdup(ctx, t->headers[i].name);
      result->headers[i].value = uw_strdup(ctx, t->headers[i].value);
    }
    result->body.size = t->body.len;
    result->body.data = uw_malloc(ctx, t->body.len ? t->body.len : 1);
    if (t->body.len)
      memcpy(result->body.data, t->body.data, t->body.len);
  } else if (code == CURLE_WRITE_ERROR && t->too_large) {
    result->outcome = outcome(ctx, uw_CurlFfi_ResponseTooLarge, NULL);
  } else {
    curl_easy_getinfo(c, CURLINFO_REQUEST_SIZE, &request_size);
#if LIBCURL_VERSION_NUM >= 0x073700
    curl_easy_getinfo(c, CURLINFO_SIZE_UPLOAD_T, &uploaded);
#else
    { double d = 0; curl_easy_getinfo(c, CURLINFO_SIZE_UPLOAD, &d); uploaded = (curl_off_t)d; }
#endif
    result->outcome = outcome(ctx, request_size > 0 || uploaded > 0 ? uw_CurlFfi_MaybeSent : uw_CurlFfi_NotSent,
                              failure(code, errbuf));
  }

  uw_pop_cleanup(ctx);
  return result;
}

uw_CurlFfi_outcome uw_CurlFfi_outcomeOf(uw_context ctx, uw_CurlFfi_completed r) {
  (void)ctx;
  return r->outcome;
}

uw_Basis_int uw_CurlFfi_statusOf(uw_context ctx, uw_CurlFfi_completed r) {
  (void)ctx;
  return r->status;
}

uw_Basis_int uw_CurlFfi_headerCount(uw_context ctx, uw_CurlFfi_completed r) {
  (void)ctx;
  return r->nheaders;
}

uw_Basis_string uw_CurlFfi_headerName(uw_context ctx, uw_CurlFfi_completed r, uw_Basis_int i) {
  if (i < 0 || i >= r->nheaders)
    uw_error(ctx, FATAL, "urweb-curl: header %lld of %lld", (long long)i, (long long)r->nheaders);
  return r->headers[i].name;
}

uw_Basis_string uw_CurlFfi_headerValue(uw_context ctx, uw_CurlFfi_completed r, uw_Basis_int i) {
  if (i < 0 || i >= r->nheaders)
    uw_error(ctx, FATAL, "urweb-curl: header %lld of %lld", (long long)i, (long long)r->nheaders);
  return r->headers[i].value;
}

uw_Basis_blob uw_CurlFfi_bodyOf(uw_context ctx, uw_CurlFfi_completed r) {
  (void)ctx;
  return r->body;
}

// Percent-encoding, by libcurl: every byte but the unreserved ones (letters,
// digits, - . _ ~) as %XX, which is right for the bytes of UTF-8.
uw_Basis_string uw_CurlFfi_escape(uw_context ctx, uw_Basis_string s) {
  char *e = curl_easy_escape(handle(ctx), s, 0);
  uw_Basis_string r;

  if (!e)
    uw_error(ctx, FATAL, "urweb-curl: out of memory");
  r = uw_strdup(ctx, e);
  curl_free(e);
  return r;
}
