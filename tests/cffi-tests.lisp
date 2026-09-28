;;;; cffi-tests.lisp — clXau tests that need the CFFI link(2) binding.
;;;; Copyright (C) 2026 Arthur Miller <arthur.miller@live.com>
;;;; SPDX-License-Identifier: MIT
;;;;
;;;; These live in the clxau/tests package so they share its deftest
;;;; and assertion macros.  They are compiled as part of the
;;;; clxau/cffi-tests system, which pulls in both clxau/cffi and
;;;; clxau/tests; loading it registers these tests with RT, and
;;;; clxau/tests:run-tests then runs the whole suite against the
;;;; CFFI backend.

(in-package #:clxau/tests)

(defun %reserve-temp-path (prefix)
  "Return a pathname that is not currently in use.

   UIOP:WITH-TEMPORARY-FILE reserves a unique name by creating the
   file atomically; we then delete the placeholder so the caller sees
   a path that does not exist.  This is the shape the LINK tests need:
   LINK fails with EEXIST if the destination exists and with ENOENT if
   the source does not."
  (uiop:with-temporary-file (:pathname path :prefix prefix :keep t)
    (delete-file path)
    path))

;; The whole point of loading clxau/cffi: *link-function* becomes the
;; CFFI binding.  If this fails, everything below tests the wrong
;; thing.

(deftest test-cffi-link-installed ()
  (is-true (fboundp 'clxau::%link-via-cffi))
  (is-true (eq clxau::*link-function* #'clxau::%link-via-cffi)))

;; The three outcomes XAU-LOCK-AUTH cares about, tested against the
;; CFFI binding directly.  :ERROR is not tested: it corresponds to an
;; errno that no ordinary filesystem operation in a temporary
;; directory can produce.
(deftest test-cffi-link-return-values ()
  (let ((source (%reserve-temp-path "clxau-cffi-src-"))
        (dest   (%reserve-temp-path "clxau-cffi-dst-"))
        (absent (%reserve-temp-path "clxau-cffi-abs-")))
    (unwind-protect
         (progn
           ;; :NOENT -- source does not exist.
           (is-equal (clxau::%link-via-cffi (namestring absent)
                                            (namestring dest))
                     :noent)
           ;; :OK -- source exists, destination does not.
           (with-open-file (s source :direction :output
                                     :if-exists :supersede
                                     :element-type '(unsigned-byte 8)))
           (is-equal (clxau::%link-via-cffi (namestring source)
                                            (namestring dest))
                     :ok)
           ;; Hard-link semantics: both names now refer to the same inode.
           (is-true (probe-file source))
           (is-true (probe-file dest))
           ;; :EXISTS -- destination is occupied.
           (is-equal (clxau::%link-via-cffi (namestring source)
                                            (namestring dest))
                     :exists))
      (dolist (p (list source dest absent))
        (ignore-errors (delete-file p))))))

(deftest test-cffi-link-errno-fallback ()
  ;; Same three cases with the errno resolver returning NIL, so
  ;; %LINK-VIA-CFFI cannot tell EEXIST from ENOENT by errno and has to
  ;; fall back to probing.
  (let ((clxau::*errno-symbol-lookup* (constantly nil))
        (source (%reserve-temp-path "clxau-cffi-src-"))
        (dest   (%reserve-temp-path "clxau-cffi-dst-"))
        (absent (%reserve-temp-path "clxau-cffi-abs-")))
    (unwind-protect
         (progn
           (is-equal (clxau::%link-via-cffi (namestring absent)
                                            (namestring dest))
                     :noent)
           (with-open-file (s source :direction :output
                                     :if-exists :supersede
                                     :element-type '(unsigned-byte 8)))
           (is-equal (clxau::%link-via-cffi (namestring source)
                                            (namestring dest))
                     :ok)
           (is-equal (clxau::%link-via-cffi (namestring source)
                                            (namestring dest))
                     :exists))
      (dolist (p (list source dest absent))
        (ignore-errors (delete-file p))))))
