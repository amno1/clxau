;;;; src/cffi.lisp — A CFFI binding of link(2), for XAU-LOCK-AUTH.
;;;; Copyright (C) 2026 Arthur Miller
;;;; SPDX-License-Identifier: MIT
;;;
;;; This file is compiled as part of the CLXAU/CFFI system, not CLXAU.
;;; Loading it replaces the default *LINK-FUNCTION* (link(2) through
;;; SB-ALIEN on SBCL, a non-atomic rename elsewhere) with a CFFI
;;; binding of the same syscall, so that XAU-LOCK-AUTH is race-free on
;;; every implementation where CFFI can reach libc.  Nothing else in
;;; clXau is affected.

(in-package #:clxau)

#+unix
(progn
  ;; libc under the names the supported platforms give it.  The
  ;; absolute paths are a fallback for images whose dynamic-library
  ;; search path does not include the usual places.
  (cffi:define-foreign-library (clxau-libc :canary "link")
      (:darwin (:or "libc.dylib" "libSystem.dylib"
                    "/usr/lib/libSystem.B.dylib"))
    ;; use libc.so.6 first, from
    ;; https://www.mail-archive.com/cffi-devel@common-lisp.net/msg00709.html
    ;; also use :canary to use one from the core if available
    ;; https://cffi.common-lisp.dev/manual/html_node/define_002dforeign_002dlibrary.html
    (:unix   (:or "libc.so.6" "libc.so" "/lib/libc.so.6" "/usr/lib/libc.so.6"))
    (t       (:default "libc")))

  (cffi:use-foreign-library clxau-libc)

  (cffi:defcfun ("link" %c-link) :int
    (oldpath :string)
    (newpath :string))

  ;; errno.  glibc puts it behind __errno_location; the BSDs and macOS behind
  ;; __error.  Resolved at run time: a platform with neither leaves
  ;; *ERRNO-LOCATION* NIL, %ERRNO returns NIL, and %LINK-VIA-CFFI falls back
  ;; to probing for the distinction between EEXIST and ENOENT -- the same
  ;; behaviour the portable %LINK has, and only reached on systems clXau does
  ;; not otherwise claim to support.  
  (declaim (inline %errno))
  ;;; in src/cffi.lisp, replacing the current %errno
  (defvar *errno-symbol-lookup*
    (lambda ()
      (or (ignore-errors
           (cffi:foreign-symbol-pointer "__errno_location"
                                        :library 'clxau-libc))
          (ignore-errors
           (cffi:foreign-symbol-pointer "__error"
                                        :library 'clxau-libc))))
    "Function returning the address of errno, or NIL.  Resolved fresh on
   every call, so a saved-and-restored image re-finds the symbol after
   the dynamic linker has relocated it.  Rebinding this to
   (CONSTANTLY NIL) forces %LINK-VIA-CFFI down its probing fallback
   path, for testing.")

  (defun %errno ()
    "The value of errno, or NIL if it cannot be read."
    (let ((errno-ptr (funcall *errno-symbol-lookup*)))
      (when errno-ptr
        (cffi:mem-ref
         (cffi:foreign-funcall-pointer errno-ptr () :pointer) :int))))

  ;; Standard Unix errno values.  These are stable across Linux, the
  ;; BSDs, macOS, Solaris, AIX and HP-UX.
  (defconstant +eexist+ 17)
  (defconstant +enoent+  2)

  (defun %link-via-cffi (from to)
    "link(2) through CFFI.  Returns :OK, :EXISTS, :NOENT or :ERROR, the
     same protocol %LINK follows."
    (if (zerop (%c-link from to))
        :ok
        (let ((errno (%errno)))
          (cond ((eql errno +eexist+) :exists)
                ((eql errno +enoent+) :noent)
                ;; No errno on this platform: distinguish by probing,
                ;; as the portable fallback does.
                ((null errno)
                 (cond ((probe-file to)       :exists)
                       ((not (probe-file from)) :noent)
                       (t                        :error)))
                (t :error)))))

  ;; Loading this system is the opt-in.
  (setf *link-function* #'%link-via-cffi))
