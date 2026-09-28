;;;; src/lock.lisp — Xauthority file locking (XauLockAuth / XauUnlockAuth).
;;;; Copyright (C) 2026 Arthur Miller SPDX-License-Identifier: MIT
;;;; A Lisp re-implementation of libXau's AuLock.c and AuUnlock.c, Copyright
;;;; 1988, 1993, 1994, 1998 The Open Group; see section 2 of LICENSE.

;;;; libXau's lock is a pair of files, FILE-c (a "creation" marker,
;;;; created with O_EXCL) and FILE-l (the actual lock, hard-linked from
;;;; FILE-c).  It is used only by clients that write the Xauthority
;;;; file; read-only clients never take the lock.
;;;;
;;;; The publish step -- hard-linking FILE-c to FILE-l -- is the only
;;;; thing here that is not portable Common Lisp, and it is what
;;;; XAU-LOCK-AUTH calls *LINK-FUNCTION* for.  The default is link(2)
;;;; through SB-ALIEN on SBCL and a non-atomic rename elsewhere;
;;;; loading the CLXAU/CFFI system replaces the default with a CFFI
;;;; binding of the same syscall, so that the lock is race-free on
;;;; implementations without SB-ALIEN.
;;;;
;;;; The non-atomic fallback checks for FILE-l and then renames FILE-c
;;;; over it; between the check and the rename another process can do
;;;; the same, so two processes can then both believe they hold the
;;;; lock.

(in-package #:clxau)

(declaim (inline %create-name %link-name))
(defun %create-name (path) (concatenate 'string path "-c"))
(defun %link-name  (path) (concatenate 'string path "-l"))

(defun %create-exclusive (path)
  "Create PATH if it does not exist, like open(O_CREAT|O_EXCL).
   Returns :OK or :EXISTS.  An error creating it (EACCES, say) counts
   as :EXISTS, so the caller retries, as libXau does for EACCES."
  (handler-case
      (with-open-file (s path :direction :output
                              :if-exists nil
                              :if-does-not-exist :create
                              :element-type '(unsigned-byte 8))
        (if s :ok :exists))
    (file-error () :exists)))

#+sbcl
(defun %link (from to)
  "link(2).  Returns :OK, :EXISTS (EEXIST), :NOENT (ENOENT) or :ERROR."
  (if (zerop (sb-alien:alien-funcall
              (sb-alien:extern-alien "link" (function sb-alien:int
                                                      sb-alien:c-string
                                                      sb-alien:c-string))
              from to))
      :ok
      (let ((errno (sb-alien:get-errno)))
        (cond ((= errno sb-unix:eexist) :exists)
              ((= errno sb-unix:enoent) :noent)
              (t :error)))))

#-sbcl
(defun %link (from to)
  "Publish FROM as TO; see the file comment for why this is not atomic."
  (cond ((probe-file to) :exists)
        ((not (probe-file from)) :noent)
        ((ignore-errors (rename-file from to) t) :ok)
        (t :error)))

(defvar *link-function* #'%link
  "The function XAU-LOCK-AUTH calls to publish FILE-c as FILE-l.  It
   is called as (FUNCALL *LINK-FUNCTION* FROM TO) and returns one of
   :OK, :EXISTS, :NOENT or :ERROR, the same protocol %LINK follows.

   The default is %LINK: link(2) through SB-ALIEN on SBCL, and a
   non-atomic rename elsewhere.  The CLXAU/CFFI system sets this to a
   CFFI binding of link(2) at load time.")

(defun xau-lock-auth (file-name &key (retries 5) (timeout 1) (dead 0))
  "Attempt to lock the Xauthority file at FILE-NAME, a string.

   RETRIES is the number of attempts; TIMEOUT is the number of seconds
   to sleep after each failed one; a lock older than DEAD seconds is
   removed before the first attempt, and with DEAD 0 (the default) any
   existing lock is removed, as in libXau.

   Returns one of the keywords :LOCK-SUCCESS, :LOCK-ERROR or
   :LOCK-TIMEOUT, corresponding to LOCK_SUCCESS, LOCK_ERROR and
   LOCK_TIMEOUT in libXau.  Mirrors the C XauLockAuth()."
  (declare (type string file-name))
  (when (> (length file-name) 1022)
    (return-from xau-lock-auth :lock-error))
  (let ((create (%create-name file-name))
        (link   (%link-name   file-name))
        (created nil))
    ;; Stale-lock cleanup.
    (when (probe-file create)
      (let ((ctime (or (ignore-errors (file-write-date create)) 0)))
        (when (or (zerop dead) (> (- (get-universal-time) ctime) dead))
          (ignore-errors (delete-file create))
          (ignore-errors (delete-file link)))))
    (loop
      (when (<= retries 0)
        (return :lock-timeout))
      (unless created
        (setf created (eq (%create-exclusive create) :ok)))
      (if (not created)
          (progn (sleep timeout) (decf retries))
          (ecase (funcall *link-function* create link)
            (:ok (return :lock-success))
            ;; FILE-c vanished (another process removed a stale lock):
            ;; create it again, without using up a retry.
            (:noent (setf created nil))
            (:exists (sleep timeout) (decf retries))
            (:error (return :lock-error)))))))

(defun xau-unlock-auth (file-name)
  "Release the lock on FILE-NAME.  Always returns T.  Mirrors the C
   XauUnlockAuth()."
  (ignore-errors (delete-file (%create-name file-name)))
  (ignore-errors (delete-file (%link-name   file-name)))
  t)
