;;;; src/io.lisp — Reading, writing and disposing Xauth entries.
;;;; Copyright (C) 2026 Arthur Miller
;;;; SPDX-License-Identifier: MIT

(in-package #:clxau)

(defun xau-read-auth (stream)
  "Read one entry from STREAM in Xauthority binary format.  Returns a
   fresh XAUTH, or NIL at a clean end-of-file.  Signals XAU-PARSE-ERROR
   if the stream ends in the middle of an entry.

   STREAM must be a binary stream with element type (UNSIGNED-BYTE 8).
   Mirrors the C XauReadAuth(), except that libXau signals end-of-file
   and truncation the same way (both return NULL); here the two are
   distinguished."
  (handler-case
      (multiple-value-bind (family present-p) (%read-be16-or-eof stream)
        (unless present-p
          (return-from xau-read-auth nil))
        (make-xauth
         :family  family
         :address (%read-counted-bytes  stream)
         :number  (%read-counted-string stream)
         :name    (%read-counted-string stream)
         :data    (%read-counted-bytes  stream)))
    (end-of-file ()
      (error 'xau-parse-error
             :message "truncated Xauthority entry"))))

(defun %safe-read-auth (stream)
  "Read one entry from STREAM.  Returns :EOF on a clean end-of-file, on
   a truncated entry, or on a read error, as libXau's XauReadAuth()
   returns NULL for all three."
  (handler-case
      (or (xau-read-auth stream) :eof)
    ((or xau-parse-error stream-error) () :eof)))

(defun xau-write-auth (auth stream)
  "Write AUTH to STREAM in the Xauthority binary format.  Returns T.
   Signals a stream error if the write fails.

   STREAM must be a binary stream with element type (UNSIGNED-BYTE 8).
   Mirrors the C XauWriteAuth()."
  (%write-be16 (xauth-family auth) stream)
  (%write-counted-bytes  (xauth-address auth) stream)
  (%write-counted-string (xauth-number  auth) stream)
  (%write-counted-string (xauth-name    auth) stream)
  (%write-counted-bytes  (xauth-data    auth) stream)
  t)

(defun xau-dispose-auth (auth)
  "Release resources associated with AUTH.  In Common Lisp, memory is
   reclaimed by the garbage collector, so the only thing this function
   does is zero the sensitive DATA field, mirroring libXau's
   explicit_bzero behaviour.  Passing NIL does nothing.  Returns NIL.

   Mirrors the C XauDisposeAuth(), which has a void return."
  (when auth
    (let ((data (xauth-data auth)))
      (when (typep data 'octet-vector)
        (fill data 0))))
  nil)
