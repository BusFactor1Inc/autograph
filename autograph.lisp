(require :cl-ppcre)
(require :anaphora)
(use-package :anaphora)

;; Encode a js symbol, graciously stolen from from Parenscript
(let ((cache (make-hash-table :test 'equal)))
  (defun encode-js-identifier (identifier)
    "Given a string, produces to a valid JavaScript identifier by
following transformation heuristics case conversion. For example,
paren-script becomes parenScript, *some-global* becomes SOMEGLOBAL."
    (or (gethash identifier cache)
        (setf (gethash identifier cache)
              (cond ((some (lambda (c) (find c "-*+!?#@%/=:<>^")) identifier)
                     (let ((lowercase t)
                           (all-uppercase nil))
                       (when (and (not (string= identifier "[]")) ;; HACK
                                  (find-if (lambda (x) (find x '(#\. #\[ #\]))) identifier))
                         (warn "Symbol ~A contains one of '.[]' - this compound naming convention is no longer supported by Parenscript!"
                               identifier))
                       (acond ((nth-value 1 (cl-ppcre:scan-to-strings "[\\*|\\+](.+)[\\*|\\+](.*)" identifier :sharedp t))
                               (setf all-uppercase t
                                     identifier (concatenate 'string (aref it 0) (aref it 1))))
                              ((and (> (length identifier) 1)
                                    (or (eql (char identifier 0) #\+)
                                        (eql (char identifier 0) #\*)))
                               (setf lowercase nil
                                     identifier (subseq identifier 1))))
                       (with-output-to-string (acc)
                         (loop for c across identifier
                            do (acond ((eql c #\-)
                                       (setf lowercase (not lowercase)))
                                      ((position c "!?#@%+*/=:<>^")
                                       (write-sequence (aref #("bang" "what" "hash" "at" "percent"
                                                               "plus" "star" "slash" "equals" "colon"
                                                               "lessthan" "greaterthan" "caret")
                                                             it)
                                                       acc))
                                      (t (write-char (cond ((and lowercase (not all-uppercase)) (char-downcase c))
                                                           (t (char-upcase c)))
                                                     acc)
                                         (setf lowercase t)))))))
                    ((every #'upper-case-p (remove-if-not #'alpha-char-p identifier)) (string-downcase identifier))
                    ((every #'lower-case-p (remove-if-not #'alpha-char-p identifier)) (string-upcase identifier))
                    (t identifier))))))

(defun string-lowercase (s)
  (map 'string #'char-downcase s))

(defun lowercase-symbol (s)
  (string-lowercase (symbol-name s)))

(defparameter *include-paths* ())

(defun include (file)
  ;;(format *error-output* "~A~%" *include-paths*)
  (catch 'found
    (dolist (include-path *include-paths*)
      (let ((path (concatenate 'string (directory-namestring include-path) file)))
        ;;(format *error-output* "Searching: ~A~%" path)
        (when (probe-file path)
          (with-open-file (f path)
                          (autograph f)
                          (throw 'found t)))))
    (format *error-output* "autograph: Cannot find load file: ~A~%" file))
  )

(defmacro defselector-op (name sep)
  `(defmacro ,name (&rest things)
     (let ((s (with-output-to-string
                (s)
                (dolist (thing things)
                  (format s "~A ~A "
                          (if (symbolp thing)
                              (lowercase-symbol thing)
                            (eval thing))
                          ,sep)))))
       (subseq s 0 (- (length s) 2)))))

(defselector-op all ",")
(defselector-op inside " ")
(defselector-op child ">")
(defselector-op after "+")
(defselector-op before "~")

(defmacro cls (class &optional thing)
    (concatenate 'string
     "."
     (encode-js-identifier (symbol-name class))
     (when  thing
       (concatenate 'string ":"
                    (encode-js-identifier (symbol-name thing))))))

(defmacro id (class &optional thing)
    (concatenate 'string
     "#"
     (encode-js-identifier (symbol-name class))
     (when  thing
       (concatenate 'string ":"
                    (encode-js-identifier (symbol-name thing))))))

(defun expand-rules (rules)
  (flet ((format-rule-values (values)
           (with-output-to-string (s)
               (dolist (value values)
                 (if (or (stringp value) (numberp value))
                     (format s "~A " value)
                     (if (or (listp value) (boundp value))
                         (format s "~A " (let ((value (eval value)))
                                        (if (symbolp value)
                                            (lowercase-symbol value)
                                            value)))
                         (format s "~A " (lowercase-symbol value))))))))
    
    (with-output-to-string (s)
      (dolist (rule rules)
        (destructuring-bind (first &rest rest) rule
           (case first
                 (@viewport (format s "@viewport { ~A }"
                                    (expand-rules rest)))
                 (t
                  (format s "~A: ~A;~%"
                          (if (symbolp first)
                              (lowercase-symbol first)
                            first)
                          (format-rule-values rest)))))))))
     
(defmacro css (selector &body rules)
  (if (stringp selector)
      (format t "~A {~% ~A }~%" selector (expand-rules rules))
      (if (listp selector)
          (format t "~A {~% ~A }~%" (eval selector) (expand-rules rules))
        (case selector
              (include (apply #'include rules))
              (t (format t "~A {~% ~A }~%" (lowercase-symbol selector)
                         (expand-rules rules)))))
      ))

(defun quote-function-arguments (function-call)
  (cons (car function-call)
        (map 'list (lambda (e)
                     (if (not (listp e))
                         `',e
                       e))
             (cdr function-call))))

(defparameter *funs* (list))
(defun autograph (f)
  (do ((form (read f nil) (read f nil)))
      ((not form))
      (format t "/* ~S */~%" form)
      (case (car form)
            ((defun)
             (when (eq (car form) 'defun)
               (push (second form) *funs*))
             (eval form))
            ((defvar defparameter defconstant)
             (eval form))
            (t
             (if (and (find (car form) *funs*) (symbol-function (car form)))
                 (eval `(css ,@(eval (quote-function-arguments form))))
               (eval `(css ,@form)))))))

(defmacro while (test &body body)
  `(loop
      (when (not ,test)
        (return))
      ,@body))

(defun main (argv)
  (push (probe-file ".") *include-paths*)
  (if (cdr argv)
      (progn
        (pop argv)
        (while argv
          (let ((arg (pop argv)))
            (cond 
              ((string= arg "-I")
               (let ((dir (pop argv)))
                 (push (probe-file dir) *include-paths*)))
              ((string= arg "--eval")
               (let ((code (pop argv)))
                 (format t "/* --eval ~A~% */" (read-from-string code))
                 (in-package :ps)
                 (eval (read-from-string code))))
              (t
               (let ((probe-results (probe-file arg)))
                 (when probe-results
                   ;; Add current file directory to include paths so they can relative include properly
                   (push (directory-namestring probe-results) *include-paths*)
                   
                   (setf *include-paths* (reverse *include-paths*))
                   (with-open-file (f arg)
                     (handler-bind
                         ((error
                           (lambda (e) 
                             (format *error-output* "~A~%" e)
                             (sb-ext:exit :code 1))))
                       (autograph f))))))))))
      (format *error-output* "Usage: autograph style.autograph > style.css~%")))
