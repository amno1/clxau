;;;; src/xauth.lisp — The Xauth structure and family identifiers.
;;;; Copyright (C) 2026 Arthur Miller
;;;; SPDX-License-Identifier: MIT

(in-package #:clxau)

;;; Family IDs (Xauth.h + xcb.h)

(defconstant +family-internet+             0)
(defconstant +family-decnet+               1)
(defconstant +family-chaos+                2)
(defconstant +family-server-interpreted+   5)
(defconstant +family-internet6+            6)
(defconstant +family-localhost+          252)
(defconstant +family-krb5-principal+     253)
(defconstant +family-netname+            254)
(defconstant +family-local+              256)
(defconstant +family-wild+             65535)

;;; Octet-vector helpers
;;; Octet-vector type and helpers
;;;
;;; On SBCL we use SB-EXT:STRING-TO-OCTETS and SB-EXT:OCTETS-TO-STRING
;;; with :EXTERNAL-FORMAT :LATIN-1.  That is exactly the one-octet-per-
;;; character ISO 8859-1 encoding the Xauthority format uses, and it is
;;; faster than a hand-written loop.  Everywhere else we supply our own.

(deftype octet-vector ()
  '(simple-array (unsigned-byte 8) (*)))

(declaim (inline make-octet-vector))
(defun make-octet-vector (&optional (size 0))
  "Return a fresh octet vector of SIZE octets."
  (make-array size :element-type '(unsigned-byte 8)))

#+sbcl
(progn
  (declaim (inline string-to-octets octets-to-string))

  (defun string-to-octets (string)
    "Encode STRING as ISO 8859-1 (latin-1).  One octet per character.
   On SBCL this is SB-EXT:STRING-TO-OCTETS."
    (declare (type string string))
    (sb-ext:string-to-octets string :external-format :latin-1))

  (defun octets-to-string (octets)
    "Decode OCTETS as ISO 8859-1 (latin-1).  On SBCL this is
   SB-EXT:OCTETS-TO-STRING."
    (declare (type octet-vector octets))
    (sb-ext:octets-to-string octets :external-format :latin-1)))

#-sbcl
(progn
  (defun string-to-octets (string)
    (declare (type string string))
    (let ((result (make-array (length string) :element-type '(unsigned-byte 8))))
      (loop for ch across string
            for i from 0
            for code = (char-code ch)
            do (unless (<= 0 code #xFF)
                 (error 'type-error :datum ch :expected-type '(unsigned-byte 8)))
               (setf (aref result i) code))
      result))

  (defun octets-to-string (octets)
    "Decode OCTETS as ISO 8859-1 (latin-1)."
    (declare (type octet-vector octets))
    (let ((result (make-string (length octets))))
      (loop for b across octets
            for i from 0
            do (setf (char result i) (code-char b)))
      result)))

;;; Xauth

(defstruct (xauth
            (:constructor make-xauth
                (&key family address number name data)))
  "A single X authorization entry.  Mirrors the C `Xauth` struct.

   FAMILY is one of the +FAMILY-*+ constants.
   ADDRESS is an octet vector.
   NUMBER and NAME are strings; empty values act as wildcards.
   DATA is an octet vector (the cookie)."
  (family  0                   :type (unsigned-byte 16))
  (address (make-octet-vector) :type octet-vector)
  (number  ""                  :type string)
  (name    ""                  :type string)
  (data    (make-octet-vector) :type octet-vector))

(defun xauth-number-as-integer (auth)
  "Return AUTH's display number as an integer, or NIL if it is empty
   or non-numeric.  The slot itself is a string (matching libXau); this
   is a convenience accessor."
  (let ((n (xauth-number auth)))
    (when (plusp (length n))
      (parse-integer n :junk-allowed t))))

(defmethod print-object ((auth xauth) stream)
  (print-unreadable-object (auth stream :type t)
    (format stream "family=~D name=~S number=~S"
            (xauth-family auth)
            (xauth-name   auth)
            (xauth-number auth))))
