;;;; src/lookup.lisp — Entry matching and lookup.
;;;; Copyright (C) 2026 Arthur Miller
;;;; SPDX-License-Identifier: MIT

(in-package #:clxau)

(declaim (inline %coerce-address %coerce-number %entry-matches-address-p
                 %entry-matches-number-p %entry-matches-name-p))

(defun %call-with-auth-file (function)
  "Call FUNCTION with the Xauthority file open as a binary input stream
   and return its value, or return NIL without calling it if there is
   no file name or the file cannot be opened (libXau's access() and
   fopen() checks)."
  (let* ((path (xau-file-name))
         (in (and path
                  (plusp (length path))
                  (ignore-errors
                   (open path :direction :input
                              :element-type '(unsigned-byte 8)
                              :if-does-not-exist nil)))))
    (when in
      (unwind-protect (funcall function in)
        (close in)))))

;; Coerce X to an octet vector suitable for matching.  A string is
;; encoded as ISO 8859-1; NIL becomes the empty vector.
(defun %coerce-address (x)
  (etypecase x
    (null (make-octet-vector))
    (string (string-to-octets x))
    (octet-vector x)
    ((vector (unsigned-byte 8))
     (coerce x 'octet-vector))))

;; Coerce X to the string used for display-number matching.  NIL
;; becomes the empty string (wildcard).
(defun %coerce-number (x)
  (etypecase x
    (null "")
    (string x)
    (integer (princ-to-string x))))

(defun %ipv6-literal (s)
  "Parse an IPv6 string literal into a 16-octet vector, or NIL if
   invalid.  Handles the compressed `::' form (RFC 4291 section 2.2),
   the full eight-group form, and the trailing-dotted-quad form used
   by IPv4-mapped addresses such as \"::ffff:127.0.0.1\".  Returns NIL
   for anything malformed; does not signal."
  (ignore-errors
    (let* (;; A trailing dotted quad replaces the last two 16-bit
           ;; groups.  Rewrite it that way first so the rest of the
           ;; parser only ever sees hex groups.
           (last-dot   (position #\. s :from-end t))
           (last-colon (position #\: s :from-end t))
           (v4-tail-p  (and last-dot
                            (or (null last-colon) (< last-colon last-dot))))
           (s (if v4-tail-p
                  (let* ((sep   (if last-colon (1+ last-colon) 0))
                         (quad  (subseq s sep))
                         (parts (uiop:split-string quad :separator ".")))
                    (unless (and (= 4 (length parts))
                                 (every (lambda (p)
                                          (and (plusp (length p))
                                               (every #'digit-char-p p)))
                                        parts))
                      (return-from %ipv6-literal nil))
                    (let ((octets (mapcar #'parse-integer parts)))
                      (unless (every (lambda (b) (<= 0 b 255)) octets)
                        (return-from %ipv6-literal nil))
                      (format nil "~A~X:~X"
                              (subseq s 0 sep)
                              (+ (ash (first  octets) 8) (second octets))
                              (+ (ash (third  octets) 8) (fourth octets)))))
                  s))
           ;; Standard `::' handling from here on.
           (gap       (search "::" s))
           (left-str  (if gap (subseq s 0 gap) s))
           (right-str (if gap (subseq s (+ gap 2)) ""))
           (left  (when (plusp (length left-str))
                    (uiop:split-string left-str :separator ":")))
           (right (when (plusp (length right-str))
                    (uiop:split-string right-str :separator ":")))
           (left-vals  (mapcar (lambda (x) (parse-integer x :radix 16)) left))
           (right-vals (mapcar (lambda (x) (parse-integer x :radix 16)) right))
           ;; Padding is legitimate only when `::' was present.
           ;; Without it, the field count must be exactly eight.
           (pad    (if gap
                       (- 8 (+ (length left-vals) (length right-vals)))
                       0))
           (blocks (append left-vals (make-list pad :initial-element 0) right-vals))
           (bytes  (make-octet-vector 16)))
      (when (and (>= pad 0) (= (length blocks) 8)
                 (every (lambda (b) (<= 0 b #xFFFF)) blocks))
        (loop for b in blocks
              for i from 0 by 2 do
              (setf (aref bytes i)      (ldb (byte 8 8) b)
                    (aref bytes (1+ i)) (ldb (byte 8 0) b)))
        bytes))))

;;; Entry matching primitives (mirror AuGetAddr.c / AuGetBest.c)

;; True if ENTRY's family and address match the query.  Either family
;; may be FamilyWild, in which case the query matches unconditionally.
(defun %entry-matches-address-p (entry family address-bytes)
  (let ((efam (xauth-family entry)))
    (or (= efam   +family-wild+)
        (= family +family-wild+)
        (and (= efam family)
             (equalp (xauth-address entry) address-bytes)))))

;; True if ENTRY's display number matches NUMBER-STRING, or either side
;; is empty (wildcard).
(defun %entry-matches-number-p (entry number-string)
  (let ((enum (xauth-number entry)))
    (or (zerop (length number-string))
        (zerop (length enum))
        (string= enum number-string))))

;; True if ENTRY's auth name matches NAME-STRING, or either side is
;; empty (wildcard).
(defun %entry-matches-name-p (entry name-string)
  (let ((ename (xauth-name entry)))
    (or (zerop (length name-string))
        (zerop (length ename))
        (string= ename name-string))))

;;; XauGetAuthByAddr

(defun xau-get-auth-by-addr (family address number &optional name)
  "Return the first entry in the Xauthority file whose family and
   address match (FAMILY, ADDRESS) and whose number and name match
   NUMBER and NAME, or NIL if none matches.

   FAMILY   is one of the +FAMILY-*+ constants.
   ADDRESS  is an octet vector, a string (ISO 8859-1 encoded), or NIL
            (empty).
   NUMBER   is a string, an integer, or NIL (wildcard).
   NAME     is a string, or NIL (wildcard).  Optional.

   Mirrors the C XauGetAuthByAddr().  The C API's _length parameters
   are omitted: Lisp vectors and strings know their length."
  (let ((address-bytes (%coerce-address address))
        (number-string (%coerce-number  number))
        (name-string   (or name "")))
    (%call-with-auth-file
     (lambda (in)
       (loop for entry = (%safe-read-auth in)
             until (eq entry :eof)
             when (and (%entry-matches-address-p entry family address-bytes)
                       (%entry-matches-number-p  entry number-string)
                       (%entry-matches-name-p    entry name-string))
               return entry
             do (xau-dispose-auth entry))))))

;;; XauGetBestAuthByAddr

(defparameter *xau-default-preferences* '("MIT-MAGIC-COOKIE-1")
  "Auth protocol names in descending preference order.  Entries whose
   NAME is not in this list are ignored by XAU-GET-BEST-AUTH-BY-ADDR.

   XDM-AUTHORIZATION-1 is deliberately absent: it requires
   per-connection XDMCP wrapping with DES and no modern X server uses
   it.")

(defun xau-get-best-auth-by-addr (family address number
                                  &optional (types *xau-default-preferences*))
  "Return the best-matching entry from the Xauthority file, or NIL.
   \"Best\" is decided by the position of the entry's auth NAME in
   TYPES, which is a list of protocol-name strings in descending
   preference order.  An entry whose name is not in TYPES is ignored.

   Mirrors the C XauGetBestAuthByAddr().  The C API's types_length and
   type_lengths parameters are omitted because Lisp strings know their
   length."
  (let ((address-bytes (%coerce-address address))
        (number-string (%coerce-number  number)))
    (%call-with-auth-file
     (lambda (in)
       (let ((best      nil)
             (best-rank (length types)))
         (loop for entry = (%safe-read-auth in)
               until (eq entry :eof)
               do (if (and (%entry-matches-address-p entry family address-bytes)
                           (%entry-matches-number-p  entry number-string))
                      (let ((rank (and (plusp best-rank)
                                       (position (xauth-name entry) types
                                                 :end best-rank
                                                 :test #'string=))))
                        (cond
                          ;; No TYPES: the first matching entry wins,
                          ;; as AuGetBest.c's `if (best_type == 0)'.
                          ((zerop best-rank)
                           (setf best entry)
                           (return))
                          (rank
                           (xau-dispose-auth best)
                           (setf best      entry
                                 best-rank rank)
                           (when (zerop rank)
                             (return)))
                          (t (xau-dispose-auth entry))))
                      (xau-dispose-auth entry)))
         best)))))

;;; Convenience: resolve a host and display number the way libxcb's
;;; xcb_auth.c does.  This is an extension, not part of libXau's API.

;; Return a list of candidate local hostnames, most-specific first.
;; $XAUTHLOCALHOSTNAME (set by some ssh -X setups) comes before
;; gethostname(3).
(defun %local-hostnames ()
  (let ((names '()))
    (let ((env (uiop:getenv "XAUTHLOCALHOSTNAME")))
      (when (and env (plusp (length env)))
        (push env names)))
    (let ((h (ignore-errors (uiop:hostname))))
      (when (and h (plusp (length h)) (not (member h names :test #'string=)))
        (push h names)))
    (nreverse names)))

;; Return a 4-octet vector if S is a dotted-quad IPv4 literal,
;; otherwise NIL.  Hostname resolution is deliberately not attempted;
;; the auth file stores numeric addresses.
(defun %dotted-quad (s)
  (when (and (stringp s) (plusp (length s)))
    (let ((parts (uiop:split-string s :separator ".")))
      (when (and (= 4 (length parts))
                 (every (lambda (p)
                          (and (<= 1 (length p) 3) (every #'digit-char-p p)))
                        parts))
        (let ((bytes (mapcar #'parse-integer parts)))
          (when (every (lambda (b) (<= b 255)) bytes)
            (make-array 4 :element-type '(unsigned-byte 8)
                          :initial-contents bytes)))))))

(declaim (inline %ipv6-loopback))
(defun %ipv6-loopback ()
  "A fresh 16-octet ::1 address."
  (let ((v (make-octet-vector 16)))
    (setf (aref v 15) 1)
    v))

(defun %lookup-entry-for-display (hostname display-number protocol)
  "The XAUTH entry XAU-LOOKUP-FOR-DISPLAY finds, or NIL."
  (flet ((best (family address)
           (xau-get-best-auth-by-addr family address display-number)))
    (let ((address (etypecase hostname
                     (null nil)
                     (string (ecase protocol
                             (:internet  (%dotted-quad hostname))
                             (:internet6 (%ipv6-literal hostname))
                             (:local     nil)))
                     ((vector (unsigned-byte 8)) (%coerce-address hostname)))))
      ;; xcb_auth.c: a loopback TCP address authenticates as FamilyLocal,
      ;; as does a v4-mapped IPv6 loopback.
      (when (and (eq protocol :internet6) address (= (length address) 16)
                 (every #'zerop (subseq address 0 10))
                 (= #xff (aref address 10) (aref address 11)))
        (setf protocol :internet
              address  (subseq address 12)))
      (when (or (and (eq protocol :internet)
                     (or (equal hostname "localhost")
                         (equalp address #(127 0 0 1))))
                (and (eq protocol :internet6)
                     (or (equal hostname "localhost")
                         (equalp address (%ipv6-loopback)))))
        (setf protocol :local))
      (ecase protocol
        (:local
         (loop for host in (%local-hostnames)
                 thereis (best +family-local+ (string-to-octets host))))
        (:internet
         (best +family-internet+ (or address (make-octet-vector))))
        (:internet6
         (best +family-internet6+ (or address (make-octet-vector))))))))

(defun xau-lookup-for-display (hostname display-number
                               &key (protocol :local))
  "Look up the best-matching entry for a connection to HOSTNAME on
   DISPLAY-NUMBER over PROTOCOL (:LOCAL, :INTERNET or :INTERNET6), as
   libxcb's xcb_auth.c does.  Returns (VALUES FAMILY ADDRESS NUMBER NAME
   DATA), or NIL if no entry matches.  This is a convenience wrapper
   around XAU-GET-BEST-AUTH-BY-ADDR and is not part of the libXau API.

   For :LOCAL, the entry is looked up under the local hostname
   ($XAUTHLOCALHOSTNAME first, then the host's name) and HOSTNAME is
   ignored.  For :INTERNET, HOSTNAME is a dotted-quad IPv4 literal or a
   4-octet vector; for :INTERNET6, a 16-octet vector.  Names are not
   resolved, so other HOSTNAMEs match only FamilyWild entries.  As in
   xcb_auth.c, \"localhost\" and the loopback addresses 127.0.0.1, ::1
   and ::ffff:127.0.0.1 look up a FamilyLocal entry, since that is how
   the X server stores the cookie for a local display."
  (let ((entry (%lookup-entry-for-display hostname display-number protocol)))
    (when entry
      (values (xauth-family  entry)
              (xauth-address entry)
              (xauth-number  entry)
              (xauth-name    entry)
              (xauth-data    entry)))))
