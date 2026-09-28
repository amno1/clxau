;;;; tests/tests.lisp — clXau tests; RT-based, no X server, no fixtures
;;;; Copyright (C) 2026 Arthur Miller <arthur.miller@live.com>
;;;; SPDX-License-Identifier: MIT
;;;;
;;;; (asdf:test-system "clxau") runs these.  On SBCL the ASDF system
;;;; loads SBCL's bundled sb-rt; elsewhere it must find the RT system.
;;;; Every fixture is built inline, so no data files are needed.

(defpackage #:clxau/tests
  (:use #:cl #+sbcl #:sb-rt #-sbcl #:rt)
  (:shadow #:deftest)
  (:export #:run-tests))

(in-package #:clxau/tests)

;;; Some helpers

(defvar *failures* '()
  "The assertions that failed in the test being run.")

(defmacro is (form)
  "Assert that FORM is true."
  `(unless ,form
     (push '(:failed ,form) *failures*)))

(defmacro is-true (form)
  `(is ,form))

(defmacro is-false (form)
  `(is (not ,form)))

(defmacro is-equal (got want)
  "Assert that GOT is EQUAL to WANT."
  (let ((g (gensym "GOT")) (w (gensym "WANT")))
    `(let ((,g ,got) (,w ,want))
       (unless (equal ,g ,w)
         (push (list :form ',got :got ,g :want ,w) *failures*)))))

(defmacro is-equalp (got want)
  "Assert that GOT is EQUALP to WANT; useful for octet vectors."
  (let ((g (gensym "GOT")) (w (gensym "WANT")))
    `(let ((,g ,got) (,w ,want))
       (unless (equalp ,g ,w)
         (push (list :form ',got :got ,g :want ,w) *failures*)))))

(defmacro deftest (name lambda-list &body body)
  "Define an RT test NAME that runs BODY and passes if no IS or
   IS-EQUAL in it failed.  LAMBDA-LIST must be empty."
  (assert (null lambda-list) () "DEFTEST ~S takes no arguments." name)
  `(#+sbcl sb-rt:deftest #-sbcl rt:deftest ,name
     (let ((*failures* '()))
       ,@body
       (or (null *failures*) (reverse *failures*)))
     t))

(defmacro with-env ((name value) &body body)
  "Run BODY with environment variable NAME bound to VALUE.  NIL means
   unset.  The prior value is restored afterwards."
  (let ((old (gensym "OLD")))
    `(let ((,old (uiop:getenv ,name)))
       (unwind-protect
            (progn (setf (uiop:getenv ,name) ,value) ,@body)
         (setf (uiop:getenv ,name) ,old)))))

(defun call-with-temp-file (fn &key (prefix "clxau-test-") (type "xauth"))
  "Call FN with a fresh temporary pathname.  The file, and any FILE-c
   or FILE-l siblings, are removed on exit.

   The pathname comes from UIOP:WITH-TEMPORARY-FILE, which creates the
   underlying file atomically (O_CREAT|O_EXCL with a name UIOP has
   reserved), so the name is unique even if the test suite is run from
   several processes at once.  UIOP cleans up the base file; we clean
   up the two lock siblings, which it knows nothing about."
  (uiop:with-temporary-file (:pathname path
                             :prefix prefix
                             :type type)
    (unwind-protect (funcall fn path)
      (let ((s (namestring path)))
        (ignore-errors (delete-file (concatenate 'string s "-c")))
        (ignore-errors (delete-file (concatenate 'string s "-l")))))))

(defun write-auth-file (path entries)
  "Write ENTRIES, a list of (FAMILY ADDRESS NUMBER NAME DATA-STRING)
   tuples, to PATH as an Xauthority file.  ADDRESS is a string, stored
   as its ISO 8859-1 octets, or a list or vector of octets."
  (with-open-file (out path
                       :direction :output
                       :element-type '(unsigned-byte 8)
                       :if-exists :supersede)
    (dolist (e entries)
      (destructuring-bind (family address number name data) e
        (clxau:xau-write-auth
         (clxau:make-xauth
          :family  family
          :address (if (stringp address)
                       (clxau:string-to-octets address)
                       (coerce address '(simple-array (unsigned-byte 8) (*))))
          :number  number
          :name    name
          :data    (clxau:string-to-octets data))
         out)))))

(deftest test-family-constants ()
  (is-equal clxau:+family-internet+ 0)
  (is-equal clxau:+family-decnet+ 1)
  (is-equal clxau:+family-chaos+ 2)
  (is-equal clxau:+family-server-interpreted+ 5)
  (is-equal clxau:+family-internet6+ 6)
  (is-equal clxau:+family-localhost+ 252)
  (is-equal clxau:+family-krb5-principal+ 253)
  (is-equal clxau:+family-netname+ 254)
  (is-equal clxau:+family-local+ 256)
  (is-equal clxau:+family-wild+ 65535))

;;; Encoding

(deftest test-read-counted-bytes-rejects-overlong-prefix ()
  (call-with-temp-file
   (lambda (p)
     (with-open-file (out p :direction :output
                            :element-type '(unsigned-byte 8)
                            :if-exists :supersede)
       ;; CARD16 length 500, then only three bytes of payload.
       (write-byte (ldb (byte 8 8) 500) out)
       (write-byte (ldb (byte 8 0) 500) out)
       (write-byte 1 out) (write-byte 2 out) (write-byte 3 out))
     (with-open-file (in p :direction :input
                           :element-type '(unsigned-byte 8))
       (is-true (handler-case (progn (clxau::%read-counted-bytes in) nil)
                  (end-of-file () t)))))))

(deftest test-encoding-ascii-round-trip ()
  (let ((s "Hello, world!"))
    (is-equal (clxau:octets-to-string (clxau:string-to-octets s)) s)))

(deftest test-encoding-latin-1-range ()
  (let ((s (coerce (list #\a (code-char 233) (code-char 255)) 'string)))
    (is-equalp (clxau:string-to-octets s)
               (make-array 3 :element-type '(unsigned-byte 8)
                             :initial-contents '(97 233 255)))
    (is-equal (clxau:octets-to-string (clxau:string-to-octets s)) s)))

(deftest test-encoding-empty ()
  (is-equalp (clxau:string-to-octets "")
             (make-array 0 :element-type '(unsigned-byte 8)))
  (is-equal  "" (clxau:octets-to-string
                 (make-array 0 :element-type '(unsigned-byte 8)))))

;;; Binary primitives

(deftest test-binary-round-trip ()
  (call-with-temp-file
   (lambda (p)
     (with-open-file (out p :direction :output
                            :element-type '(unsigned-byte 8)
                            :if-exists :supersede)
       (clxau::%write-be16 #x1234 out)
       (clxau::%write-be16 #x00ff out)
       (clxau::%write-counted-bytes
        (make-array 3 :element-type '(unsigned-byte 8)
                      :initial-contents '(1 2 3))
        out)
       (clxau::%write-counted-string "abc" out))
     (with-open-file (in p :direction :input
                           :element-type '(unsigned-byte 8))
       (is-equal  (clxau::%read-be16 in) #x1234)
       (is-equal  (clxau::%read-be16 in) #x00ff)
       (is-equalp (clxau::%read-counted-bytes in)
                  (make-array 3 :element-type '(unsigned-byte 8)
                                :initial-contents '(1 2 3)))
       (is-equal  (clxau::%read-counted-string in) "abc")))))

(deftest test-binary-eof ()
  (call-with-temp-file
   (lambda (p)
     (with-open-file (out p :direction :output
                            :element-type '(unsigned-byte 8)
                            :if-exists :supersede))
     (with-open-file (in p :direction :input
                           :element-type '(unsigned-byte 8))
       (multiple-value-bind (v present-p) (clxau::%read-be16-or-eof in)
         (is-false present-p)
         (is-false v))))))

(deftest test-binary-truncated-be16 ()
  (call-with-temp-file
   (lambda (p)
     (with-open-file (out p :direction :output
                            :element-type '(unsigned-byte 8)
                            :if-exists :supersede)
       (write-byte #x12 out))
     (with-open-file (in p :direction :input
                           :element-type '(unsigned-byte 8))
       (is-true (handler-case (progn (clxau::%read-be16 in) nil)
                  (end-of-file () t)))))))

;;; The Xauth structure

(deftest test-xauth-construct-and-access ()
  (let ((e (clxau:make-xauth :family clxau:+family-local+
                              :address (clxau:string-to-octets "host")
                              :number  "0"
                              :name    "MIT-MAGIC-COOKIE-1"
                              :data    (make-array
                                        4
                                        :element-type '(unsigned-byte 8)
                                        :initial-contents '(1 2 3 4)))))
    (is-equal  (clxau:xauth-family e) clxau:+family-local+)
    (is-equal  (clxau:xauth-number e) "0")
    (is-equal  (clxau:xauth-name   e) "MIT-MAGIC-COOKIE-1")
    (is-equalp (clxau:xauth-address e) (clxau:string-to-octets "host"))
    (is-equalp (clxau:xauth-data e) (make-array
                                     4
                                     :element-type '(unsigned-byte 8)
                                     :initial-contents '(1 2 3 4)))))

(deftest test-xauth-defaults ()
  (let ((e (clxau:make-xauth)))
    (is-equal (clxau:xauth-family e) 0)
    (is-equal (clxau:xauth-number e) "")
    (is-equal (clxau:xauth-name   e) "")
    (is-equal (length (clxau:xauth-address e)) 0)
    (is-equal (length (clxau:xauth-data e)) 0)))

(deftest test-xauth-print ()
  (let ((e (clxau:make-xauth :name "MIT-MAGIC-COOKIE-1" :number "0")))
    (is-true (stringp (prin1-to-string e)))
    (is-true (search "MIT-MAGIC-COOKIE-1" (prin1-to-string e)))))

(deftest test-xauth-number-as-integer ()
  (is-equal (clxau:xauth-number-as-integer (clxau:make-xauth :number "0")) 0)
  (is-equal (clxau:xauth-number-as-integer (clxau:make-xauth :number "42")) 42)
  (is-false (clxau:xauth-number-as-integer (clxau:make-xauth :number ""))))

;;; Entry read/write round trips

(deftest test-write-read-xauth-entry ()
  (call-with-temp-file
   (lambda (p)
     (let* ((addr (clxau:string-to-octets "127.0.0.1"))
            (data (make-array 16 :element-type '(unsigned-byte 8)
                                 :initial-element #x42))
            (original (clxau:make-xauth :family clxau:+family-internet+
                                         :address addr
                                         :number "0"
                                         :name "MIT-MAGIC-COOKIE-1"
                                         :data data)))
       (with-open-file (out p :direction :output
                              :element-type '(unsigned-byte 8)
                              :if-exists :supersede)
         (clxau:xau-write-auth original out))
       (with-open-file (in p :direction :input
                             :element-type '(unsigned-byte 8))
         (let ((read-back (clxau:xau-read-auth in)))
           (is-true read-back)
           (is-equal  (clxau:xauth-family read-back) clxau:+family-internet+)
           (is-equalp (clxau:xauth-address read-back) addr)
           (is-equal  (clxau:xauth-number read-back) "0")
           (is-equal  (clxau:xauth-name read-back) "MIT-MAGIC-COOKIE-1")
           (is-equalp (clxau:xauth-data read-back) data)
           ;; Clean EOF: the second read returns NIL.
           (is-false  (clxau:xau-read-auth in))))))))

(deftest test-write-read-empty-fields ()
  (call-with-temp-file
   (lambda (p)
     (let ((original (clxau:make-xauth :family clxau:+family-local+
                                        :address (clxau:string-to-octets "host")
                                        :number ""
                                        :name   ""
                                        :data   (make-array 0 :element-type '(unsigned-byte 8)))))
       (with-open-file (out p :direction :output
                              :element-type '(unsigned-byte 8)
                              :if-exists :supersede)
         (clxau:xau-write-auth original out))
       (with-open-file (in p :direction :input
                             :element-type '(unsigned-byte 8))
         (let ((read-back (clxau:xau-read-auth in)))
           (is-equal (clxau:xauth-number read-back) "")
           (is-equal (clxau:xauth-name   read-back) "")
           (is-equal (length (clxau:xauth-data read-back)) 0)))))))

(deftest test-write-read-multiple-entries ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ "127.0.0.1" "0"
                   "MIT-MAGIC-COOKIE-1" "cookie1")
             (list clxau:+family-internet+ "127.0.0.1" "1"
                   "MIT-MAGIC-COOKIE-1" "cookie2")
             (list clxau:+family-local+ "myhost" "0"
                   "MIT-MAGIC-COOKIE-1" "cookie3")))
     (with-open-file (in p :direction :input
                           :element-type '(unsigned-byte 8))
       (let ((e1 (clxau:xau-read-auth in))
             (e2 (clxau:xau-read-auth in))
             (e3 (clxau:xau-read-auth in)))
         (is-equal (clxau:octets-to-string (clxau:xauth-data e1)) "cookie1")
         (is-equal (clxau:octets-to-string (clxau:xauth-data e2)) "cookie2")
         (is-equal (clxau:xauth-family e3) clxau:+family-local+)
         (is-false (clxau:xau-read-auth in)))))))

(deftest test-read-truncated-entry ()
  (call-with-temp-file
   (lambda (p)
     (with-open-file (out p :direction :output
                            :element-type '(unsigned-byte 8)
                            :if-exists :supersede)
       ;; family 0, address length 5, but only 3 bytes of address.
       (write-byte 0 out) (write-byte 0 out)
       (write-byte 0 out) (write-byte 5 out)
       (write-byte 65 out) (write-byte 66 out) (write-byte 67 out))
     (with-open-file (in p :direction :input
                           :element-type '(unsigned-byte 8))
       (is-true (handler-case (progn (clxau:xau-read-auth in) nil)
                  (clxau:xau-parse-error () t)))))))

;;; xau-file-name

(deftest test-xau-file-name-xauthority ()
  (with-env ("XAUTHORITY" "/tmp/test-xauth")
    (is-equal (clxau:xau-file-name) "/tmp/test-xauth")))

(deftest test-xau-file-name-empty-xauthority-wins ()
  ;; As in libXau: a set $XAUTHORITY is used even when empty.
  (with-env ("XAUTHORITY" "")
    (with-env ("HOME" "/home/user")
      (is-equal (clxau:xau-file-name) ""))))

(deftest test-xau-file-name-empty-home ()
  (with-env ("XAUTHORITY" nil)
    (with-env ("HOME" "")
      (is-equal (clxau:xau-file-name) "/.Xauthority"))))

(deftest test-lookup-empty-xauthority-finds-nothing ()
  (with-env ("XAUTHORITY" "")
    (is-false (clxau:xau-get-auth-by-addr clxau:+family-wild+ nil nil))))

(deftest test-xau-file-name-home ()
  (with-env ("XAUTHORITY" nil)
    (with-env ("HOME" "/home/user")
      (is-equal (clxau:xau-file-name) "/home/user/.Xauthority"))))

(deftest test-xau-file-name-home-slash ()
  (with-env ("XAUTHORITY" nil)
    (with-env ("HOME" "/")
      (is-equal (clxau:xau-file-name) "/.Xauthority"))))

(deftest test-xau-file-name-nothing ()
  (with-env ("XAUTHORITY" nil)
    (with-env ("HOME" nil)
      (is-false (clxau:xau-file-name)))))

;;; xau-get-auth-by-addr

(deftest test-get-auth-by-addr-exact ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ "127.0.0.1" "0"
                   "MIT-MAGIC-COOKIE-1" "cookie1")))
     (with-env ("XAUTHORITY" (namestring p))
       (let ((e (clxau:xau-get-auth-by-addr
                 clxau:+family-internet+
                 (clxau:string-to-octets "127.0.0.1")
                 "0")))
         (is-true e)
         (is-equal (clxau:xauth-name e) "MIT-MAGIC-COOKIE-1")
         (is-equal (clxau:octets-to-string (clxau:xauth-data e)) "cookie1"))))))

(deftest test-get-auth-by-addr-with-name ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ "127.0.0.1" "0"
                   "MIT-MAGIC-COOKIE-1" "cookie1")
             (list clxau:+family-internet+ "127.0.0.1" "0"
                   "XDM-AUTHORIZATION-1" "cookie2")))
     (with-env ("XAUTHORITY" (namestring p))
       (let ((e (clxau:xau-get-auth-by-addr
                 clxau:+family-internet+
                 (clxau:string-to-octets "127.0.0.1")
                 "0" "XDM-AUTHORIZATION-1")))
         (is-equal (clxau:xauth-name e) "XDM-AUTHORIZATION-1"))))))

(deftest test-get-auth-by-addr-wildcard-family ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-wild+ "" ""
                   "MIT-MAGIC-COOKIE-1" "cookie1")))
     (with-env ("XAUTHORITY" (namestring p))
       (let ((e (clxau:xau-get-auth-by-addr
                 clxau:+family-internet+
                 (clxau:string-to-octets "127.0.0.1")
                 "0")))
         (is-true e)
         (is-equal (clxau:octets-to-string (clxau:xauth-data e)) "cookie1"))))))

(deftest test-get-auth-by-addr-wildcard-number ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ "127.0.0.1" ""
                   "MIT-MAGIC-COOKIE-1" "cookie1")))
     (with-env ("XAUTHORITY" (namestring p))
       (let ((e (clxau:xau-get-auth-by-addr
                 clxau:+family-internet+
                 (clxau:string-to-octets "127.0.0.1")
                 "5")))
         (is-true e))))))

(deftest test-get-auth-by-addr-wildcard-name ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ "127.0.0.1" "0"
                   "" "cookie1")))
     (with-env ("XAUTHORITY" (namestring p))
       (let ((e (clxau:xau-get-auth-by-addr
                 clxau:+family-internet+
                 (clxau:string-to-octets "127.0.0.1")
                 "0" "MIT-MAGIC-COOKIE-1")))
         (is-true e))))))

(deftest test-get-auth-by-addr-no-match ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ "10.0.0.1" "0"
                   "MIT-MAGIC-COOKIE-1" "cookie1")))
     (with-env ("XAUTHORITY" (namestring p))
       (is-false (clxau:xau-get-auth-by-addr
                  clxau:+family-internet+
                  (clxau:string-to-octets "127.0.0.1")
                  "0"))))))

(deftest test-get-auth-by-addr-missing-file ()
  (with-env ("XAUTHORITY" "/nonexistent/clxau-test-missing")
    (is-false (clxau:xau-get-auth-by-addr
               clxau:+family-internet+
               (clxau:string-to-octets "127.0.0.1")
               "0"))))

(deftest test-get-auth-by-addr-accepts-string-address ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ "127.0.0.1" "0"
                   "MIT-MAGIC-COOKIE-1" "cookie1")))
     (with-env ("XAUTHORITY" (namestring p))
       (is-true (clxau:xau-get-auth-by-addr
                 clxau:+family-internet+ "127.0.0.1" 0))))))

;;; xau-get-best-auth-by-addr

(deftest test-get-best-auth-preferences-order ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ "127.0.0.1" "0"
                   "XDM-AUTHORIZATION-1" "cookie-xdm")
             (list clxau:+family-internet+ "127.0.0.1" "0"
                   "MIT-MAGIC-COOKIE-1" "cookie-mit")))
     (with-env ("XAUTHORITY" (namestring p))
       (let ((e (clxau:xau-get-best-auth-by-addr
                 clxau:+family-internet+
                 (clxau:string-to-octets "127.0.0.1")
                 "0"
                 '("MIT-MAGIC-COOKIE-1" "XDM-AUTHORIZATION-1"))))
         (is-equal (clxau:xauth-name e) "MIT-MAGIC-COOKIE-1"))))))

(deftest test-get-best-auth-ignores-unknown ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ "127.0.0.1" "0"
                   "SOMETHING-ELSE" "cookie-other")
             (list clxau:+family-internet+ "127.0.0.1" "0"
                   "MIT-MAGIC-COOKIE-1" "cookie-mit")))
     (with-env ("XAUTHORITY" (namestring p))
       (let ((e (clxau:xau-get-best-auth-by-addr
                 clxau:+family-internet+
                 (clxau:string-to-octets "127.0.0.1")
                 "0"
                 '("MIT-MAGIC-COOKIE-1"))))
         (is-equal (clxau:xauth-name e) "MIT-MAGIC-COOKIE-1"))))))

(deftest test-get-best-auth-empty-types-first-wins ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ "127.0.0.1" "0" "SOMETHING-ELSE" "a")
             (list clxau:+family-internet+ "127.0.0.1" "0" "MIT-MAGIC-COOKIE-1" "b")))
     (with-env ("XAUTHORITY" (namestring p))
       (is-equal (clxau:xauth-name
                  (clxau:xau-get-best-auth-by-addr
                   clxau:+family-internet+ "127.0.0.1" "0" '()))
                 "SOMETHING-ELSE")))))

(deftest test-get-best-auth-returned-entry-intact ()
  ;; Discarded entries are zeroed, as in libXau; the result is not.
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ "127.0.0.1" "0" "XDM-AUTHORIZATION-1" "x")
             (list clxau:+family-internet+ "127.0.0.1" "0" "MIT-MAGIC-COOKIE-1" "m")))
     (with-env ("XAUTHORITY" (namestring p))
       (is-equal (clxau:octets-to-string
                  (clxau:xauth-data
                   (clxau:xau-get-best-auth-by-addr
                    clxau:+family-internet+ "127.0.0.1" "0"
                    '("MIT-MAGIC-COOKIE-1" "XDM-AUTHORIZATION-1"))))
                 "m")))))

(deftest test-get-best-auth-none-matching ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ "127.0.0.1" "0"
                   "SOMETHING-ELSE" "cookie-other")))
     (with-env ("XAUTHORITY" (namestring p))
       (is-false (clxau:xau-get-best-auth-by-addr
                  clxau:+family-internet+
                  (clxau:string-to-octets "127.0.0.1")
                  "0"
                  '("MIT-MAGIC-COOKIE-1")))))))

;;; Locking

(deftest test-lock-basic ()
  (call-with-temp-file
   (lambda (p)
     (let ((path (namestring p)))
       ;; Fresh path: succeeds.
       (is-equal (clxau:xau-lock-auth path) :lock-success)
       ;; Already held: fails fast.  DEAD must be large so the cleanup
       ;; step does not remove the holder's lock.
       (is-equal (clxau:xau-lock-auth path :retries 1 :timeout 0 :dead 1000000)
                 :lock-timeout)
       ;; Unlock: always T.
       (is-true (clxau:xau-unlock-auth path))
       ;; Now the lock can be taken again.
       (is-equal (clxau:xau-lock-auth path) :lock-success)
       (clxau:xau-unlock-auth path)))))

(deftest test-lock-leaves-files-as-libxau ()
  ;; libXau hard-links FILE-l from FILE-c and keeps both while locked.
  ;; Both the SB-ALIEN and the CFFI bindings do link(2), so both leave
  ;; FILE-c in place while the lock is held.  The portable fallback
  ;; renames FILE-c to FILE-l, so FILE-c is gone by then.
  (call-with-temp-file
   (lambda (p)
     (let* ((path (namestring p))
            (creat (concatenate 'string path "-c"))
            (link  (concatenate 'string path "-l"))
            (race-free #+sbcl t
                       #-sbcl (eq clxau::*link-function*
                                  #'clxau::%link-via-cffi)))
       (is-equal (clxau:xau-lock-auth path) :lock-success)
       (is-true  (probe-file link))
       (when race-free
         (is-true (probe-file creat)))
       (clxau:xau-unlock-auth path)
       (is-false (probe-file link))
       (is-false (probe-file creat))))))

(deftest test-lock-dead-zero-breaks-lock ()
  ;; As in libXau, DEAD 0 removes an existing lock first.
  (call-with-temp-file
   (lambda (p)
     (let ((path (namestring p)))
       (is-equal (clxau:xau-lock-auth path) :lock-success)
       (is-equal (clxau:xau-lock-auth path :retries 1 :timeout 0) :lock-success)
       (clxau:xau-unlock-auth path)))))

(deftest test-lock-zero-retries-times-out ()
  (call-with-temp-file
   (lambda (p)
     (is-equal (clxau:xau-lock-auth (namestring p) :retries 0) :lock-timeout))))

(deftest test-lock-long-name-is-an-error ()
  (is-equal (clxau:xau-lock-auth (make-string 1023 :initial-element #\a))
            :lock-error))

;;; WITH- macros

(deftest test-with-xau-lock ()
  (call-with-temp-file
   (lambda (p)
     (let ((path (namestring p)))
       (is-equal (clxau:with-xau-lock (path)
                   (is-true (probe-file (concatenate 'string path "-l")))
                   (values 1 2))
                 1)
       (is-false (probe-file (concatenate 'string path "-l")))
       ;; Unlocked on a non-local exit too.
       (ignore-errors (clxau:with-xau-lock (path) (error "boom")))
       (is-false (probe-file (concatenate 'string path "-l")))))))

(deftest test-with-xau-lock-held-signals ()
  (call-with-temp-file
   (lambda (p)
     (let ((path (namestring p))
           (ran nil))
       (clxau:xau-lock-auth path)
       (is-true (handler-case
                    (clxau:with-xau-lock (path :retries 1 :timeout 0 :dead 1000000)
                      (setf ran t))
                  (clxau:xau-file-error () t)))
       (is-false ran)
       (clxau:xau-unlock-auth path)))))

(deftest test-with-xauth ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ '(10 0 0 5) "0"
                   "MIT-MAGIC-COOKIE-1" "cookie1")))
     (with-env ("XAUTHORITY" (namestring p))
       (let ((kept nil))
         (is-equal (clxau:with-xauth (auth "10.0.0.5" 0 :protocol :internet)
                     (setf kept auth)
                     (clxau:octets-to-string (clxau:xauth-data auth)))
                   "cookie1")
         ;; The cookie is zeroed on exit.
         (is-true (every #'zerop (clxau:xauth-data kept))))
       (is-false (clxau:with-xauth (auth "10.0.0.6" 0 :protocol :internet)
                   auth))))))

(deftest test-unlock-idempotent ()
  (call-with-temp-file
   (lambda (p)
     (is-true (clxau:xau-unlock-auth (namestring p)))
     (is-true (clxau:xau-unlock-auth (namestring p))))))

;;; xau-lookup-for-display

(deftest test-lookup-for-display-internet ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ '(10 0 0 5) "0"
                   "MIT-MAGIC-COOKIE-1" "cookie1")))
     (with-env ("XAUTHORITY" (namestring p))
       (multiple-value-bind (family address number name data)
           (clxau:xau-lookup-for-display "10.0.0.5" 0 :protocol :internet)
         (is-equal  family clxau:+family-internet+)
         (is-equalp address #(10 0 0 5))
         (is-equal  number "0")
         (is-equal  name "MIT-MAGIC-COOKIE-1")
         (is-equal (clxau:octets-to-string data) "cookie1"))))))

(deftest test-lookup-for-display-localhost-coerced ()
  ;; "localhost" + :internet is coerced to :local, so the query uses
  ;; the family-local family and the local hostname.
  (call-with-temp-file
   (lambda (p)
     (let ((hostname (uiop:hostname)))
       (write-auth-file p
         (list (list clxau:+family-local+ hostname "0"
                     "MIT-MAGIC-COOKIE-1" "cookie1")))
       (with-env ("XAUTHLOCALHOSTNAME" nil)
       (with-env ("XAUTHORITY" (namestring p))
         (multiple-value-bind (family address number name data)
             (clxau:xau-lookup-for-display "localhost" 0 :protocol :internet)
           (declare (ignore address number name data))
           (is-equal family clxau:+family-local+))
         (is-equal (clxau:xau-lookup-for-display "127.0.0.1" 0 :protocol :internet)
                   clxau:+family-local+)
         (is-equal (clxau:xau-lookup-for-display
                    (let ((v (make-array 16 :element-type '(unsigned-byte 8)
                                            :initial-element 0)))
                      (setf (aref v 15) 1) v)
                    0 :protocol :internet6)
                   clxau:+family-local+)))))))

(deftest test-lookup-for-display-xauthlocalhostname ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-local+ "other-name" "0"
                   "MIT-MAGIC-COOKIE-1" "cookie1")))
     (with-env ("XAUTHLOCALHOSTNAME" "other-name")
       (with-env ("XAUTHORITY" (namestring p))
         (is-equal (clxau:xau-lookup-for-display nil 0)
                   clxau:+family-local+))))))

(deftest test-dotted-quad ()
  (is-equalp (clxau::%dotted-quad "10.0.0.5") #(10 0 0 5))
  (is-false  (clxau::%dotted-quad "10.0.0.256"))
  (is-false  (clxau::%dotted-quad "10.0.0.+5"))
  (is-false  (clxau::%dotted-quad "10.0.0"))
  (is-false  (clxau::%dotted-quad "host.example.org.x")))

(deftest test-ipv6-literal ()
  ;; Same address, several spellings.
  (is-equalp (clxau::%ipv6-literal "::1")
             #(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1))
  (is-equalp (clxau::%ipv6-literal "0:0:0:0:0:0:0:1")
             #(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1))
  (is-equalp (clxau::%ipv6-literal "0000:0000:0000:0000:0000:0000:0000:0001")
             #(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1))
  ;; Bare :: is the all-zeros address.
  (is-equalp (clxau::%ipv6-literal "::")
             #(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0))
  ;; Full eight-group form.
  (is-equalp (clxau::%ipv6-literal "1:2:3:4:5:6:7:8")
             #(0 1 0 2 0 3 0 4 0 5 0 6 0 7 0 8))
  ;; :: in the middle.
  (is-equalp (clxau::%ipv6-literal "1:2::7:8")
             #(0 1 0 2 0 0 0 0 0 0 0 0 0 7 0 8))
  ;; IPv4-mapped form.
  (is-equalp (clxau::%ipv6-literal "::ffff:127.0.0.1")
             #(0 0 0 0 0 0 0 0 0 0 #xff #xff 127 0 0 1))
  ;; The v4 tail also replaces the last two groups in a full form.
  (is-equalp (clxau::%ipv6-literal "1:2:3:4:5:6:127.0.0.1")
             #(0 1 0 2 0 3 0 4 0 5 0 6 127 0 0 1))
  ;; Malformed: too few groups with no ::, which the old version
  ;; silently zero-extended.
  (is-false (clxau::%ipv6-literal "1:2:3"))
  ;; Malformed: too many groups.
  (is-false (clxau::%ipv6-literal "1:2:3:4:5:6:7:8:9"))
  ;; Malformed: two :: in one address.
  (is-false (clxau::%ipv6-literal "1:2::7::8"))
  ;; Malformed: bad hex.
  (is-false (clxau::%ipv6-literal "1:2:xyz:4:5:6:7:8"))
  ;; Malformed: dotted quad with too few parts.
  (is-false (clxau::%ipv6-literal "::ffff:127.0.0"))
  ;; Malformed: dotted quad octet out of range.
  (is-false (clxau::%ipv6-literal "::ffff:127.0.0.256"))
  ;; Malformed: dotted quad alone.
  (is-false (clxau::%ipv6-literal "127.0.0.1")))

(deftest test-lookup-for-display-v4-mapped ()
  ;; ::ffff:127.0.0.1 is a v4-mapped loopback.  The check in
  ;; %LOOKUP-ENTRY-FOR-DISPLAY rewrites it to the v4 127.0.0.1 and
  ;; protocol :INTERNET, then the loopback clause downgrades it to
  ;; :LOCAL.
  (call-with-temp-file
   (lambda (p)
     (let ((hostname (uiop:hostname)))
       (write-auth-file p
         (list (list clxau:+family-local+ hostname "0"
                     "MIT-MAGIC-COOKIE-1" "cookie1")))
       (with-env ("XAUTHLOCALHOSTNAME" nil)
         (with-env ("XAUTHORITY" (namestring p))
           (is-equal (clxau:xau-lookup-for-display
                      "::ffff:127.0.0.1" 0 :protocol :internet6)
                     clxau:+family-local+)))))))

;;; CALL-WITH-XAUTH and WITH-XAUTH, beyond the basic case

(deftest test-call-with-xauth-directly ()
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ '(10 0 0 5) "0"
                   "MIT-MAGIC-COOKIE-1" "cookie1")))
     (with-env ("XAUTHORITY" (namestring p))
       (let ((seen nil))
         (is-equal (clxau:call-with-xauth
                    (lambda (auth)
                      (setf seen auth)
                      (clxau:octets-to-string (clxau:xauth-data auth)))
                    "10.0.0.5" 0 :protocol :internet)
                   "cookie1")
         (is-true seen)
         ;; Disposal ran, so the cookie is zeroed.
         (is-true (every #'zerop (clxau:xauth-data seen))))))))

(deftest test-with-xauth-no-match-binds-nil ()
  ;; A missing file must bind the variable to NIL, not to a bogus entry
  ;; and not by failing to bind at all.
  (with-env ("XAUTHORITY" "/nonexistent/clxau-with-test")
    (is-equal (clxau:with-xauth
                  (auth "anywhere" 0 :protocol :internet)
                (if auth :bound :unbound))
              :unbound)))

(deftest test-with-xauth-multiple-values ()
  ;; The macro returns whatever the body returns, all of it.
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ '(10 0 0 5) "0"
                   "MIT-MAGIC-COOKIE-1" "cookie1")))
     (with-env ("XAUTHORITY" (namestring p))
       (multiple-value-bind (a b c)
           (clxau:with-xauth
               (auth "10.0.0.5" 0 :protocol :internet)
             (declare (ignore auth))
             (values 1 2 3))
         (is-equal (list a b c) '(1 2 3)))))))

(deftest test-with-xauth-disposes-on-error ()
  ;; The unwind-protect must run on the error path too: a caller that
  ;; keeps a reference to AUTH cannot use it after the macro exits.
  (call-with-temp-file
   (lambda (p)
     (write-auth-file p
       (list (list clxau:+family-internet+ '(10 0 0 5) "0"
                   "MIT-MAGIC-COOKIE-1" "cookie1")))
     (with-env ("XAUTHORITY" (namestring p))
       (let ((kept nil))
         (is-true (handler-case
                      (clxau:with-xauth
                          (auth "10.0.0.5" 0 :protocol :internet)
                        (setf kept auth)
                        (error "boom"))
                    (error () t)))
         (is-true kept)
         (is-true (every #'zerop (clxau:xauth-data kept))))))))

;;; CALL-WITH-XAU-LOCK and WITH-XAU-LOCK, beyond the basic case

(deftest test-call-with-xau-lock-directly ()
  (call-with-temp-file
   (lambda (p)
     (let ((path (namestring p)))
       (is-equal (clxau:call-with-xau-lock
                  (lambda ()
                    (is-true (probe-file (concatenate 'string path "-l")))
                    'body-value)
                  path)
                 'body-value)
       (is-false (probe-file (concatenate 'string path "-l")))))))

(deftest test-with-xau-lock-multiple-values ()
  (call-with-temp-file
   (lambda (p)
     (multiple-value-bind (a b)
         (clxau:with-xau-lock ((namestring p))
           (values :x :y))
       (is-equal (list a b) '(:x :y))))))

(deftest test-with-xau-lock-releases-on-non-local-exit ()
  ;; An ERROR is one way out of BODY; a THROW is another, and the
  ;; unwind-protect must cover both.
  (call-with-temp-file
   (lambda (p)
     (let ((path (namestring p)))
       (ignore-errors
        (clxau:with-xau-lock (path) (error "boom")))
       (is-false (probe-file (concatenate 'string path "-l")))
       (catch 'escape
         (clxau:with-xau-lock (path) (throw 'escape nil)))
       (is-false (probe-file (concatenate 'string path "-l")))))))

(deftest test-with-xau-lock-held-does-not-run-body ()
  ;; If the lock cannot be taken, BODY must not run at all: the
  ;; caller's job is to notice the signal, not to be half-done.
  (call-with-temp-file
   (lambda (p)
     (let ((path (namestring p))
           (ran nil))
       (clxau:xau-lock-auth path)
       (is-true (handler-case
                    (clxau:with-xau-lock (path :retries 1
                                               :timeout 0
                                               :dead 1000000)
                      (setf ran t))
                  (clxau:xau-file-error () t)))
       (is-false ran)
       (clxau:xau-unlock-auth path)))))

(deftest test-with-xau-lock-keywords-passed ()
  ;; :RETRIES reaches XAU-LOCK-AUTH through the macro's &REST KEYS.
  ;; With :RETRIES 0 and no fresh lock, the call must give up at once.
  (call-with-temp-file
   (lambda (p)
     (let ((path (namestring p)))
       (clxau:xau-lock-auth path)
       (is-true (handler-case
                    (clxau:with-xau-lock (path :retries 0
                                               :timeout 0
                                               :dead 1000000)
                      :never)
                  (clxau:xau-file-error () t)))
       (clxau:xau-unlock-auth path)))))

;;; Runner

(defun run-tests ()
  "Run the clXau tests.  Returns T if all passed."
  (do-tests))
