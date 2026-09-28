# clXau

Common Lisp implementation of `libXau`: X11 authorization-file
parsing, writing, lookup, and locking.

The on-disk format, the matching rules, the file-name resolution, and the lock
protocol are re-implemented as in libXau (Xauth.h, AuRead.c, AuWrite.c,
AuGetAddr.c, AuGetBest.c, AuFileName.c, AuLock.c, AuUnlock.c) and libxcb's
`xcb_auth.c`.  No C code was copied; the format and the algorithms are
[documented in those
sources](https://gitlab.freedesktop.org/xorg/lib/libxau/-/blob/master/doc/protocol.txt)
and in the X Window System Protocol.  Their notices are reproduced in
[LICENSE](LICENSE).

## Dependencies

The Xauthority parsing, writing, and matching code is portable Common
Lisp.  

[UIOP](https://asdf.common-lisp.dev/uiop.html) is used for
portability between Lisp implementations: `getenv`, `hostname`,
temporary-directory handling, string splitting and a couple of other
small utilities.  UIOP ships with ASDF and is available in every modern
Common Lisp implementation; there is no other external Lisp dependency
for the base `clxau` system.

Where SBCL offers a faster built-in (`sb-ext:string-to-octets`,
`sb-ext:octets-to-string`) it is used, and a portable fallback is
provided for other implementations; both paths use the same ISO 8859-1
one-octet-per-character encoding the Xauthority format uses.

[CFFI](https://cffi.common-lisp.dev/manual/html_node/index.html) is an
**optional** dependency. It is pulled in only by the separate `clxau/cffi`
system if you load it explicitly.  Loading it replaces the default
lock-publishing step with a CFFI binding of the `link(2)` syscall, so that
locking is race-free on implementations whose default is the non-atomic rename
fallback.  The base `clxau` system does not depend on CFFI.  See
[Problems](#problems) below for what the default does on each implementation and
when it matters.

## Installation

This is currently not in Quicklisp.  Clone to your hard drive and symlink the
directory into Quicklisp's `local-projects`, or clone directly there.  If you
don't use Quicklisp, load the `.asd` by whichever mechanism your implementation
uses.

Most users do not need to load clXau directly: it exists so that binding
libraries such as CLX and CLXCB can share one Xauthority implementation instead
of each carrying their own (currently only CLXCB uses it).

## Usage

Load the `clxau` system.  To run the tests, `(asdf:test-system "clxau")`.

## Public API

libXau's two acquire/release pairs each have a `with-` macro and a `call-with-`
function, so they can be used either directly or from a higher-order function.

| Pair                                      | clXau                                                  |
|-------------------------------------------|--------------------------------------------------------|
| `XauGetBestAuthByAddr` + `XauDisposeAuth` | `(with-xauth (auth host display &key protocol) ...)`   |
| `XauLockAuth` + `XauUnlockAuth`           | `(with-xau-lock (file &key retries timeout dead) ...)` |

`with-xauth` looks the entry up the way libxcb's `xcb_auth.c` does (see
`xau-lookup-for-display`), binds it (or `NIL`), and zeroes the cookie on exit,
so copy the data if you need it afterwards.  `with-xau-lock` signals
`xau-file-error` if the lock cannot be taken and always unlocks on exit.

If that is not enough, there is also a "lispyfied" one-to-one API with
libXau:

| libXau                      | clXau                                                               |
|-----------------------------|---------------------------------------------------------------------|
| `XauFileName()`             | `(xau-file-name)`                                                   |
| `XauReadAuth(FILE*)`        | `(xau-read-auth stream)`                                            |
| `XauWriteAuth(FILE*,X)`     | `(xau-write-auth auth stream)`                                      |
| `XauDisposeAuth(X)`         | `(xau-dispose-auth auth)`                                           |
| `XauLockAuth(...)`          | `(xau-lock-auth path &key ...)`                                     |
| `XauUnlockAuth(path)`       | `(xau-unlock-auth path)`                                            |
| `XauGetAuthByAddr(...)`     | `(xau-get-auth-by-addr family address number &optional name)`       |
| `XauGetBestAuthByAddr(...)` | `(xau-get-best-auth-by-addr family address number &optional types)` |

The C API's `_length` parameters are omitted because Lisp vectors and strings
know their own length; `FILE*` becomes a CL stream with `element-type
'(unsigned-byte 8)`.  Enum-like return values (`LOCK_SUCCESS`, `LOCK_ERROR`,
`LOCK_TIMEOUT`) become keywords (`:lock-success`, `:lock-error`,
`:lock-timeout`).

The `Xauth` struct is exposed as `xauth` with slots `family`, `address`,
`number`, `name`, `data`.  `address` and `data` are octet vectors; `number` and
`name` are strings, with empty values acting as wildcards.  The family constants
are `+family-internet+`, `+family-internet6+`, `+family-local+`,
`+family-wild+`, and the other values from `Xauth.h`.

## Example

```lisp
(asdf:load-system "clxau")
(use-package :clxau)

;; Read every entry from a file:
(with-open-file (in "~/.Xauthority"
                    :direction :input
                    :element-type '(unsigned-byte 8))
  (loop for e = (xau-read-auth in)
        while e collect e))

;; Best-match lookup for a Unix-socket connection on DISPLAY :0:
(xau-get-best-auth-by-addr +family-local+
                           (string-to-octets (uiop:hostname))
                           "0")
;; => #<XAUTH family=256 name="MIT-MAGIC-COOKIE-1" number="0">

;; Connect-time convenience wrapper:
(xau-lookup-for-display "localhost" 0)

;; The cookie for DISPLAY :0, zeroed again when the body exits:
(with-xauth (auth nil 0)
  (when auth
    (values (xauth-name auth) (copy-seq (xauth-data auth)))))

;; Rewrite the file under libXau's lock:
(with-xau-lock ((xau-file-name))
  ...)
```

## Problems

### Locking is not race-free on non-SBCL implementations

libXau's lock protocol has two steps:

1. Create `FILE-c` with `O_CREAT | O_EXCL`.  If it already exists, the lock is
   held.

2. `link(2)` `FILE-c` to `FILE-l`.  This is the step that actually publishes the
   lock: the hard-link is what a second process cannot also complete, and its
   `EEXIST` failure is what makes the protocol exclusive.

Both steps have to be atomic.  Common Lisp's standard has `open` with
`:if-exists :error`, which is the first step.  It has no hard link, which is the
second. 

* **On SBCL**: `link(2)` is called through `sb-alien` and the whole
protocol matches libXau, which is race-free. 

* **On other implementations with CFFI**, loading the `clxau/cffi` system
  replaces the default `%link` with a CFFI binding of `link(2)`; the
  protocol then matches libXau as on SBCL, and locking is race-free.

* **On other implementations without CFFI**: the fallback checks for `FILE-l`
  and then renames `FILE-c` to it.  Between the check and the rename,
  another process can do the same thing; both then believe they hold the lock.
  The file itself is not corrupted, but a writer racing another writer can lose
  an entry.

Locking matters only for programs that *write* the file: `xauth add`, `xauth
merge`, `ssh -X` setting up a session, or a tool that manages its own
`.Xauthority`.  A client that reads its cookie at connection setup and then
never touches the file is unaffected, which is the overwhelmingly common case.

### Xauthority is not a secure credential store

This is a property of the auth method and of the security model the
specification assumes, not of clXau.

The file format itself is a container: a sequence of entries `(family, address,
number, name, data)`, where `data` is an opaque length-prefixed blob whose
meaning is determined by `name`.  The format says nothing about whether that
blob is encrypted.  Several auth methods have been defined over it, and they
differ in what they put in `data`:

* **`MIT-MAGIC-COOKIE-1`** is the method in universal use.  `data` is the cookie
  itself, sent verbatim in the connection setup block and compared byte-for-byte
  by the server against its own copy.  Nothing between the file and the wire
  transforms it, and the server has no hook for one.  The bytes in the file are
  the bytes the server sees.

* **`XDM-AUTHORIZATION-1`** is a DES-based method.  `data` is 24 bytes: an
  8-byte DES key followed by 16 bytes of ciphertext that encrypts the client's
  address, the display number, and a per-connection timestamp.  The server,
  which holds the same key, decrypts and checks that the address and time are
  right.  The idea was that a `MIT-MAGIC-COOKIE-1` cookie captured from the wire
  is useful forever, while an `XDM-AUTHORIZATION-1` entry captured the same way
  is tied to the connection it was used for.  DES has since been broken, XDMCP -
  the setup it was designed for - is gone, and no modern server accepts it.
  clXau parses the entries (the family and name are ordinary) but does not
  implement the crypto, and `XAU-GET-BEST-AUTH-BY-ADDR` does not select them:
  see `*XAU-DEFAULT-PREFERENCES*`.

* **`SUN-DES-1`** uses Secure RPC / Diffie-Hellman.  `data` is an encrypted
  conversation key, and the server obtains the session key by asking the
  `keyserv` daemon.  It was used with NIS and Secure RPC setups and is
  effectively extinct.

* Kerberos is not an auth method in the wire sense; it appears as a **family**
  rather than a name.  `+FAMILY-KRB5-PRINCIPAL+` (253) marks an entry whose
  address is a Kerberos principal name rather than a host.  No modern server
  accepts an auth exchange based on it.

[The spec](https://gitlab.freedesktop.org/xorg/lib/libxau/-/blob/master/doc/protocol.txt)
is explicit about the assumption `MIT-MAGIC-COOKIE-1` rests on: "This mechanism
assumes that the superuser and the transport layer between the client and the
server is secure", and the user's auth file "will be accessible only to the user
(no group access)".  Those two assumptions are what the design relies on; the
file's permissions are what enforce the second, and neither the format nor
libXau nor clXau checks them.  libXau's `XauGetAuthByAddr`, which clXau mirrors,
only calls `access(path, R_OK)`; a file with mode 0644 passes that check
happily.  Protecting the file is the responsibility of whatever creates it, and
the convention is mode 0600.

## History

There is `auth.lisp` in CLX which one can use more or less directly.  It works -
CLX uses it - but CLX is a large dependency, and libxcb did not want to depend
on it.  The first version of clXau was that file lifted into its own library.

On trying to test it, and on comparing it to what C clients do, the quirk count
turned out to be non-trivial: the FamilyLocal address handling in particular
diverges from libXau and libxcb in ways that matter for `ssh -X` and for servers
behind a loopback address.  Bit by bit, the CLX-derived code was replaced by a
re-derivation of libXau's and libxcb's behaviour, read from their C sources.

The result no longer contains any code from CLX's `auth.lisp`, and follows what
a C client would do.  Where it deviates from libXau or libxcb, it is a bug.

The (very) honorable mention is [Javier Olaechea's cl-xcb
library](https://git.sr.ht/~puercopop/cl-xcb), which also has an Xauthority
parser (in `auth.lisp`).  His is cleaner than CLX's, but still incomplete
compared to libXau.  It is not clear whether the gaps matter in practice, but
since the work was being done anyway, the goal here was to match the C libraries
exactly.

A bit of trivia (according to Google): the libXau source code originated at the
MIT X Consortium in the late 1980s.  The initial release was alongside X11
Release 4 (X11R4) in December 1989 to implement the X Authority protocol
(`XDM-AUTHORIZATION-1` and the standard `.Xauthority` database routines).  The
underlying authorization architecture and initial implementation were largely
written by Jim Fulton of the MIT X Consortium.  It remained part of the
monolithic MIT X Window System source tree and was maintained through successive
X Consortium and XFree86 iterations before being modularized into [its own
standalone Git repository](https://gitlab.freedesktop.org/xorg/lib/libxau) by
the X.Org Foundation in 2005.

## LICENSE

MIT.  clXau also reproduces the notices of libXau (The Open Group) and libxcb
(Bart Massey and Jamey Sharp), both MIT-style, for the behaviour re-derived from
them; the full texts are in [LICENSE](LICENSE).
