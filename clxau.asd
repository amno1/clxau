;;;; clxau.asd
;;;; Copyright (C) 2026 Arthur Miller
;;;; SPDX-License-Identifier: MIT

(require :asdf)
(cl:in-package #:asdf-user)

(defsystem "clxau"
  :description "Common Lisp implementation of libXau (X11 authorization file management)"
  :author "Arthur Miller <arthur.miller@live.com>"
  :license "MIT; also carries the libXau and libxcb notices (see LICENSE)"
  :version "0.9.0"
  :depends-on ("uiop")
  :in-order-to ((test-op (test-op "clxau/tests")))
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "conditions")
                             (:file "xauth")
                             (:file "binary")
                             (:file "io")
                             (:file "filename")
                             (:file "lookup")
                             (:file "lock")
                             (:file "with")))))

(defsystem "clxau/cffi"
  :description "clXau with a CFFI binding of link(2), for race-free
 Xauthority file locking on implementations without SB-ALIEN."
  :author "Arthur Miller <arthur.miller@live.com>"
  :license "MIT"
  :depends-on ("clxau" "cffi")
  :pathname "src/"
  :components ((:file "cffi")))

;;; clxau/tests — RT-based tests.  SBCL bundles RT as the sb-rt contrib;
;;; pull it in now so the package exists before the test file is read.
;;; Everywhere else, the :depends-on entry makes ASDF find an "rt" system.

#+sbcl (eval-when (:load-toplevel :execute) (require :sb-rt))

(defsystem "clxau/tests"
  :description "RT-based tests for clXau; no X server needed."
  :author "Arthur Miller <arthur.miller@live.com>"
  :license "MIT"
  :depends-on ("clxau" #-sbcl "rt")
  :pathname "tests/"
  :components ((:file "tests"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call '#:clxau/tests '#:run-tests)
               (error "clXau RT tests failed."))))

(defsystem "clxau/cffi-tests"
  :description "clXau tests run against the CFFI link(2) binding."
  :author "Arthur Miller <arthur.miller@live.com>"
  :license "MIT"
  :depends-on ("clxau/cffi" "clxau/tests")
  :pathname "tests/"
  :components ((:file "cffi-tests"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call '#:clxau/tests '#:run-tests)
               (error "clXau CFFI tests failed."))))
