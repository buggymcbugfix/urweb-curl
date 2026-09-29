ACLOCAL_AMFLAGS = -I m4

lib_LTLIBRARIES = liburweb-curl.la

liburweb_curl_la_SOURCES = curl.c curl.h
liburweb_curl_la_LDFLAGS = -version-info $(URWEB_CURL_LT_VERSION)
liburweb_curl_la_LIBADD = $(LIBCURL_LIBS)

AM_CPPFLAGS = -I$(top_srcdir) -I$(URWEB_INC) -I$(URWEB_INC)/urweb $(LIBCURL_CFLAGS)
AM_CFLAGS = -Wall -Wextra -Werror -Wimplicit

# The Ur/Web side: the signatures and the .urp files an application imports
# with `library $(LIB_UR)`.
LIB_URdir = $(LIB_UR)
LIB_UR_DATA = \
  curl.ur \
  curl.urs \
  curlFfi.urs \
  lib.urp \
  config.urp

INCLUDEdir = $(INCLUDE)
INCLUDE_HEADERS = curl.h

PKGCONFIGdir = $(PKGCONFIG)
PKGCONFIG_DATA = urweb-curl.pc

EXTRA_DIST = \
  curl.ur \
  curl.urs \
  curlFfi.urs \
  lib.urp \
  config.urp.in \
  urweb-curl.pc.in \
  README.md \
  tests

CLEANFILES = config.urp urweb-curl.pc tests/config.urp

# The tests run against the library as built in this tree (tests/config.urp),
# with the urweb named by URWEB, else the one on the PATH.
check-local:
	$(SHELL) $(top_srcdir)/tests/run.sh

.PHONY: check-local
