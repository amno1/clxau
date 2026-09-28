;;;; src/with.lisp — RAII (WITH-) macros: scoped lookups and scoped locks.
;;;; Copyright (C) 2026 Arthur Miller
;;;; SPDX-License-Identifier: MIT
;;;
;;; libXau has two acquire/release pairs: XauGetBestAuthByAddr (and
;;; friends) with XauDisposeAuth, which zeroes the cookie, and
;;; XauLockAuth with XauUnlockAuth.  Each gets a CALL-WITH- function and
;;; a WITH- macro that releases on any exit, as CALL-WITH-XCB-CONNECTION
;;; and WITH-XCB-CONNECTION do in clxcb.

(in-package #:clxau)

(defun call-with-xauth (function hostname display-number &key (protocol :local))
  "Look up the entry for HOSTNAME and DISPLAY-NUMBER over PROTOCOL as
   XAU-LOOKUP-FOR-DISPLAY does, call FUNCTION with it (an XAUTH, or NIL
   if none matches) and return FUNCTION's values.  On any exit the
   entry's cookie is zeroed with XAU-DISPOSE-AUTH, so FUNCTION must copy
   anything it wants to keep."
  (let ((auth nil))
    (unwind-protect
         (progn
           (setf auth (%lookup-entry-for-display hostname display-number protocol))
           (funcall function auth))
      (xau-dispose-auth auth))))

(defmacro with-xauth ((var hostname display-number &key (protocol :local))
                      &body body)
  "Evaluate BODY with VAR bound to the Xauthority entry for HOSTNAME
   and DISPLAY-NUMBER (an XAUTH, or NIL if none matches), zeroing its
   cookie on exit.  See CALL-WITH-XAUTH.

     (with-xauth (auth \"localhost\" 0 :protocol :internet)
       (when auth
         (send-setup (xauth-name auth) (copy-seq (xauth-data auth)))))"
  `(call-with-xauth (lambda (,var) ,@body) ,hostname ,display-number
                    :protocol ,protocol))

(defun call-with-xau-lock (function file-name &key (retries 5) (timeout 1) (dead 0))
  "Lock the Xauthority file FILE-NAME with XAU-LOCK-AUTH (RETRIES,
   TIMEOUT and DEAD as there), call FUNCTION with no arguments, and
   unlock it on any exit.  Returns FUNCTION's values.  Signals
   XAU-FILE-ERROR, without calling FUNCTION, if the lock cannot be
   taken."
  (let ((result (xau-lock-auth file-name :retries retries :timeout timeout
                                         :dead dead)))
    (unless (eq result :lock-success)
      (error 'xau-file-error
             :pathname file-name
             :message (if (eq result :lock-timeout)
                          "timed out waiting for the lock"
                          "cannot create the lock files")))
    (unwind-protect (funcall function)
      (xau-unlock-auth file-name))))

(defmacro with-xau-lock ((file-name &rest keys &key retries timeout dead)
                         &body body)
  "Evaluate BODY with the Xauthority file FILE-NAME locked, unlocking it
   on any exit.  RETRIES, TIMEOUT and DEAD are as for XAU-LOCK-AUTH.
   See CALL-WITH-XAU-LOCK.

     (with-xau-lock ((xau-file-name))
       ;; rewrite the file
       ...)"
  (declare (ignore retries timeout dead))
  `(call-with-xau-lock (lambda () ,@body) ,file-name ,@keys))
