;;;; src/conditions.lisp
;;;; Copyright (C) 2026 Arthur Miller
;;;; SPDX-License-Identifier: MIT

(in-package #:clxau)

(define-condition xau-error (error)
  ()
  (:documentation "Base class for all clXau-specific errors."))

(define-condition xau-parse-error (xau-error)
  ((message :initarg :message :reader xau-parse-error-message))
  (:report (lambda (c s)
             (format s "Xauthority parse error: ~A"
                     (xau-parse-error-message c)))))

(define-condition xau-file-error (xau-error)
  ((pathname :initarg :pathname :reader xau-file-error-pathname)
   (message  :initarg :message  :reader xau-file-error-message))
  (:report (lambda (c s)
             (format s "Xauthority file error (~A): ~A"
                     (xau-file-error-pathname c)
                     (xau-file-error-message  c)))))
