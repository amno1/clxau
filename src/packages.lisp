;;;; src/packages.lisp
;;;; Copyright (C) 2026 Arthur Miller
;;;; SPDX-License-Identifier: MIT

(defpackage #:clxau
  (:use #:cl)
  (:export
   ;; Family IDs
   #:+family-internet+
   #:+family-decnet+
   #:+family-chaos+
   #:+family-server-interpreted+
   #:+family-internet6+
   #:+family-localhost+
   #:+family-krb5-principal+
   #:+family-netname+
   #:+family-local+
   #:+family-wild+
   ;; Xauth structure
   #:xauth
   #:make-xauth
   #:copy-xauth
   #:xauth-p
   #:xauth-family
   #:xauth-address
   #:xauth-number
   #:xauth-name
   #:xauth-data
   #:xauth-number-as-integer
   #:octet-vector
   #:string-to-octets
   #:octets-to-string
   ;; libXau API
   #:xau-file-name
   #:xau-dispose-auth
   #:xau-read-auth
   #:xau-write-auth
   #:xau-lock-auth
   #:xau-unlock-auth
   #:xau-get-auth-by-addr
   #:xau-get-best-auth-by-addr
   ;; Convenience (extension, not part of libXau)
   #:*xau-default-preferences*
   #:xau-lookup-for-display
   #:call-with-xauth
   #:with-xauth
   #:call-with-xau-lock
   #:with-xau-lock
   ;; Conditions
   #:xau-error
   #:xau-parse-error
   #:xau-file-error))
