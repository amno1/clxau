;;;; src/filename.lisp — Locating the user's Xauthority file.
;;;; Copyright (C) 2026 Arthur Miller
;;;; SPDX-License-Identifier: MIT

(in-package #:clxau)

(defun xau-file-name ()
  "Return the name of the user's Xauthority file, a string, or NIL if
   it cannot be determined.

   $XAUTHORITY, if set, wins outright, even when empty (and an empty
   name then finds no file).  Otherwise $HOME/.Xauthority, where a
   $HOME of \"/\" gives \"/.Xauthority\".  With neither set, NIL.

   Mirrors the C XauFileName()."
  (let ((from-env (uiop:getenv "XAUTHORITY")))
    (when from-env
      (return-from xau-file-name from-env)))
  (let ((home (uiop:getenv "HOME")))
    (when home
      (if (string= home "/")
          "/.Xauthority"
          (concatenate 'string home "/.Xauthority")))))
