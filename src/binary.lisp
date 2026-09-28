;;;; src/binary.lisp — Big-endian and counted-field primitives.
;;;; Copyright (C) 2026 Arthur Miller
;;;; SPDX-License-Identifier: MIT
;;;
;;; Every multi-byte integer in an Xauthority file is big-endian,
;;; independent of host order; every variable-length field is prefixed
;;; with a CARD16 length.

(in-package #:clxau)

(declaim (inline %read-be16 %write-be16))

(defun %read-be16 (stream)
  "Read a big-endian CARD16 from STREAM.  Signals END-OF-FILE on
   truncation."
  (let ((hi (read-byte stream nil nil)))
    (when (null hi) (error 'end-of-file :stream stream))
    (let ((lo (read-byte stream nil nil)))
      (when (null lo) (error 'end-of-file :stream stream))
      (logior (ash hi 8) lo))))

(defun %read-be16-or-eof (stream)
  "Read a big-endian CARD16 from STREAM.  Returns (VALUES NIL NIL) at a
   clean end-of-file and (VALUES VALUE T) otherwise.  Signals
   END-OF-FILE if a partial CARD16 is present."
  (let ((hi (read-byte stream nil nil)))
    (if (null hi)
        (values nil nil)
        (let ((lo (read-byte stream nil nil)))
          (if (null lo)
              (error 'end-of-file :stream stream)
              (values (logior (ash hi 8) lo) t))))))

(defun %write-be16 (n stream)
  "Write N as a big-endian CARD16 to STREAM."
  (check-type n (unsigned-byte 16))
  (write-byte (ldb (byte 8 8) n) stream)
  (write-byte (ldb (byte 8 0) n) stream))

(defun %read-counted-bytes (stream)
  "Read a CARD16-length-prefixed octet vector from STREAM."
  (let ((n (%read-be16 stream)))
    ;; Prevent large allocations if the file is smaller than the requested length.
    (let ((pos (ignore-errors (file-position stream)))
          (len (ignore-errors (file-length stream))))
      (when (and pos len (> n (- len pos)))
        (error 'end-of-file :stream stream)))
    (let ((v (make-array n :element-type '(unsigned-byte 8))))
      (unless (= (read-sequence v stream) n)
        (error 'end-of-file :stream stream))
      v)))

(defun %write-counted-bytes (bytes stream)
  "Write BYTES as a CARD16 length followed by the octets."
  (%write-be16 (length bytes) stream)
  (write-sequence bytes stream))

(defun %read-counted-string (stream)
  "Read a CARD16-length-prefixed ISO 8859-1 string from STREAM."
  (octets-to-string (%read-counted-bytes stream)))

(defun %write-counted-string (string stream)
  "Write STRING as a CARD16 length followed by ISO 8859-1 octets."
  (%write-counted-bytes (string-to-octets string) stream))
