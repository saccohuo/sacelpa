;;; lispy-inline.el --- inline arglist and documentation. -*- lexical-binding: t -*-

;; Copyright (C) 2014-2015 Oleh Krehel

;; This file is not part of GNU Emacs

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Display current function arguments or docstring in an in-place
;; overlay.

;;; Code:

(if (version< emacs-version "24.4")
    (progn
      (defsubst string-trim-left (string)
        "Remove leading whitespace from STRING."
        (if (string-match "\\`[ \t\n\r]+" string)
            (replace-match "" t t string)
          string))
      (defsubst string-trim-right (string)
        "Remove trailing whitespace from STRING."
        (if (string-match "[ \t\n\r]+\\'" string)
            (replace-match "" t t string)
          string))
      (defsubst string-trim (string)
        "Remove leading and trailing whitespace from STRING."
        (string-trim-left (string-trim-right string))))
  (require 'subr-x))

(defgroup lispy-faces nil
  "Font-lock faces for `lispy'."
  :group 'lispy
  :prefix "lispy-face-")

(defface lispy-face-hint
  '((((class color) (background light))
     :background "#fff3bc" :foreground "black")
    (((class color) (background dark))
     :background "black" :foreground "#fff3bc"))
  "Basic hint face."
  :group 'lispy-faces)

(defface lispy-face-req-nosel
  '((t (:inherit lispy-face-hint)))
  "Face for required unselected args."
  :group 'lispy-faces)

(defface lispy-face-req-sel
  '((t (:inherit lispy-face-req-nosel :bold t)))
  "Face for required selected args."
  :group 'lispy-faces)

(defface lispy-face-opt-nosel
  '((t (:inherit lispy-face-hint :slant italic)))
  "Face for optional unselected args."
  :group 'lispy-faces)

(defface lispy-face-key-nosel
  '((t (:inherit lispy-face-hint :slant italic)))
  "Face for keyword unselected args."
  :group 'lispy-faces)

(defface lispy-face-opt-sel
  '((t (:inherit lispy-face-opt-nosel :bold t)))
  "Face for optional selected args."
  :group 'lispy-faces)

(defface lispy-face-key-sel
  '((t (:inherit lispy-face-opt-nosel :bold t)))
  "Face for keyword selected args."
  :group 'lispy-faces)

(defface lispy-face-rst-nosel
  '((t (:inherit lispy-face-hint)))
  "Face for rest unselected args."
  :group 'lispy-faces)

(defface lispy-face-rst-sel
  '((t (:inherit lispy-face-rst-nosel :bold t)))
  "Face for rest selected args."
  :group 'lispy-faces)

(defcustom lispy-window-height-ratio 0.65
  "`lispy--show' will fail with string taller than window height times this.
The caller of `lispy--show' might use a substitute e.g. `describe-function'."
  :type 'float
  :group 'lispy)

(defvar lispy-elisp-modes
  '(emacs-lisp-mode lisp-interaction-mode eltex-mode minibuffer-inactive-mode)
  "Modes for which `lispy--eval-elisp' and related functions are appropriate.")

(defvar lispy-clojure-modes
  '(clojure-mode clojurescript-mode clojurex-mode clojurec-mode)
  "Modes for which clojure related functions are appropriate.")

(defvar lispy-overlay nil
  "Hint overlay instance.")

(defvar lispy-hint-pos nil
  "Point position where the hint should be (re-) displayed.")

(declare-function lispy--eval-clojure "le-clojure")
(declare-function lispy--clojure-args "le-clojure")
(declare-function lispy--clojure-resolve "le-clojure")
(declare-function lispy--describe-clojure-java "le-clojure")
(declare-function lispy--eval-scheme "le-scheme")
(declare-function lispy--eval-lisp "le-lisp")
(declare-function lispy--lisp-args "le-lisp")
(declare-function lispy--lisp-describe "le-lisp")
(declare-function lispy--back-to-paren "lispy")
(declare-function lispy--current-function "lispy")

;; ——— Commands ————————————————————————————————————————————————————————————————
(defun lispy--back-to-python-function ()
  "Move point from function call at point to the function name."
  (let ((pt (point))
        bnd)
    (if (lispy--in-comment-p)
        (error "Not possible in a comment")
      (condition-case nil
          (progn
            (when (setq bnd (lispy--bounds-string))
              (goto-char (car bnd)))
            (up-list -1))
        (error (goto-char pt)))
      (unless (looking-at "\\_<")
        (re-search-backward "\\_<" (line-beginning-position))))))

(defun lispy-arglist-inline ()
  "Display arglist for `lispy--current-function' inline."
  (interactive)
  (save-excursion
    (if (eq major-mode 'python-mode)
        (lispy--back-to-python-function)
      (lispy--back-to-paren))
    (unless (and (prog1 (lispy--cleanup-overlay)
                   (when (window-minibuffer-p)
                     (window-resize (selected-window) -1)))
                 (= lispy-hint-pos (point)))
      (cond ((memq major-mode lispy-elisp-modes)
             (let ((sym (intern-soft (lispy--current-function))))
               (cond ((fboundp sym)
                      (setq lispy-hint-pos (point))
                      (lispy--show (lispy--pretty-args sym))))))
            ((or (memq major-mode '(cider-repl-mode))
                 (memq major-mode lispy-clojure-modes))
             (require 'le-clojure)
             (setq lispy-hint-pos (point))
             (lispy--show (lispy--clojure-args (lispy--current-function))))

            ((eq major-mode 'lisp-mode)
             (require 'le-lisp)
             (setq lispy-hint-pos (point))
             (lispy--show (lispy--lisp-args (lispy--current-function))))

            ((eq major-mode 'python-mode)
             (require 'le-python)
             (setq lispy-hint-pos (point))
             (let ((arglist (lispy--python-arglist
                             (python-info-current-symbol)
                             (buffer-file-name)
                             (line-number-at-pos)
                             (current-column))))
               (while (eq (char-before) ?.)
                 (backward-sexp))
               (lispy--show arglist)))

            (t (error "%s isn't supported currently" major-mode))))))

(defun lispy--delete-help-windows ()
  "Delete help windows.
Return t if at least one was deleted."
  (let (deleted)
    (mapc (lambda (window)
            (when (eq (with-current-buffer (window-buffer window)
                        major-mode)
                      'help-mode)
              (delete-window window)
              (setq deleted t)))
          (window-list))
    deleted))

(defvar lispy--di-window-config nil
  "Store window configuration before `lispy-describe-inline'.")

(defun lispy--hint-pos ()
  "Point position for the first column of the hint."
  (save-excursion
    (cond ((region-active-p)
           (goto-char (region-beginning)))
          ((eq major-mode 'python-mode)
           (goto-char (beginning-of-thing 'sexp)))
          (t
           (lispy--back-to-paren)))
    (point)))

(defun lispy--cleanup-overlay ()
  "Delete `lispy-overlay' if it's valid and return t."
  (when (overlayp lispy-overlay)
    (delete-overlay lispy-overlay)
    (setq lispy-overlay nil)
    t))

(declare-function geiser-doc-symbol-at-point "geiser-doc")

(defun lispy--describe-inline ()
  "Toggle the overlay hint."
  (condition-case nil
      (let ((new-hint-pos (lispy--hint-pos))
            doc)
        (if (and (eq lispy-hint-pos new-hint-pos)
                 (overlayp lispy-overlay))
            (lispy--cleanup-overlay)
          (save-excursion
            (when (= 0 (count-lines (window-start) (point)))
              (recenter 1))
            (setq lispy-hint-pos new-hint-pos)
            (if (eq major-mode 'scheme-mode)
                (geiser-doc-symbol-at-point)
              (when (setq doc (lispy--docstring (lispy--current-function)))
                (goto-char lispy-hint-pos)
                (lispy--show (propertize doc 'face 'lispy-face-hint)))))))
    (error
     (lispy--cleanup-overlay))))

(defun lispy--docstring (sym)
  "Get the docstring for SYM."
  (cond
    ((memq major-mode lispy-elisp-modes)
     (let (dc)
       (setq sym (intern-soft sym))
       (cond ((fboundp sym)
              (if (lispy--show-fits-p
                   (setq dc (or (documentation sym)
                                "undocumented")))
                  dc
                (setq lispy--di-window-config (current-window-configuration))
                (save-selected-window
                  (describe-function sym))
                nil))
             ((boundp sym)
              (if (lispy--show-fits-p
                   (setq dc (or (documentation-property
                                 sym 'variable-documentation)
                                "undocumented")))
                  dc
                (setq lispy--di-window-config (current-window-configuration))
                (save-selected-window
                  (describe-variable sym))
                nil))
             (t "unbound"))))
    ((or (memq major-mode lispy-clojure-modes)
         (memq major-mode '(cider-repl-mode)))
     (require 'le-clojure)
     (let ((rsymbol (lispy--clojure-resolve sym)))
       (string-trim-left
        (replace-regexp-in-string
         "^\\(?:-+\n\\|\n*.*$.*@.*\n*\\)" ""
         (cond ((stringp rsymbol)
                (read
                 (lispy--eval-clojure
                  (format "(with-out-str (clojure.repl/doc %s))" rsymbol))))
               ((eq rsymbol 'special)
                (read
                 (lispy--eval-clojure
                  (format "(with-out-str (clojure.repl/doc %s))" sym))))
               ((eq rsymbol 'keyword)
                "No docs for keywords")
               ((and (listp rsymbol)
                     (eq (car rsymbol) 'variable))
                (cadr rsymbol))
               (t
                (or (lispy--describe-clojure-java sym)
                    (format "Could't resolve '%s" sym))))))))
    ((eq major-mode 'lisp-mode)
     (require 'le-lisp)
     (lispy--lisp-describe sym))
    ((eq major-mode 'python-mode)
     (semantic-mode 1)
     (let ((sym (semantic-ctxt-current-symbol)))
       (if sym
           (progn
             (setq sym (mapconcat #'identity sym "."))
             (require 'le-python)
             (or
              (lispy--python-docstring sym)
              (progn
                (message "no doc: %s" sym)
                nil)))
         (error "The point is not on a symbol"))))
    (t
     (format "%s isn't supported currently" major-mode))))

(declare-function semantic-ctxt-current-symbol "ctxt")

(defun lispy-describe-inline ()
  "Display documentation for `lispy--current-function' inline."
  (interactive)
  (if (cl-some (lambda (window)
                 (eq (with-current-buffer (window-buffer window)
                       major-mode)
                     'help-mode))
               (window-list))
      (if (window-configuration-p lispy--di-window-config)
          (set-window-configuration lispy--di-window-config)
        (lispy--delete-help-windows))
    (lispy--describe-inline)))

(declare-function lispy--python-docstring "le-python")
(declare-function lispy--python-arglist "le-python")
(declare-function python-info-current-symbol "python")

;; ——— Utilities ———————————————————————————————————————————————————————————————
(defun lispy--arglist (symbol)
  "Get arglist for SYMBOL."
  (let (doc)
    (if (setq doc (help-split-fundoc (documentation symbol t) symbol))
        (car doc)
      (prin1-to-string
       (cons symbol (help-function-arglist symbol t))))))

(defun lispy--join-pad (strs width)
  "Join STRS padding each line with WIDTH spaces."
  (let ((padding (make-string width ?\ )))
    (mapconcat (lambda (x) (concat padding x))
               strs
               "\n")))

(defun lispy--show-fits-p (str)
  "Return nil if window isn't large enough to display STR whole."
  (let ((strs (split-string str "\n")))
    (when (or (< (length strs) (* lispy-window-height-ratio (window-height)))
              (window-minibuffer-p))
      strs)))

(defun lispy--show (str)
  "Show STR hint when `lispy--show-fits-p' is t."
  (let ((last-point (point))
        (strs (lispy--show-fits-p str)))
    (if strs
        (progn
          (setq str (lispy--join-pad
                     strs
                     (+ (if (window-minibuffer-p)
                            (- (minibuffer-prompt-end) (point-min))
                          0)
                        (string-width (buffer-substring
                                       (line-beginning-position)
                                       (point))))))
          (save-excursion
            (goto-char lispy-hint-pos)
            (if (= -1 (forward-line -1))
                (setq str (concat str "\n"))
              (end-of-line)
              (setq str (concat "\n" str)))
            (setq str (concat str
                              (buffer-substring (point) (1+ (point)))))
            (if lispy-overlay
                (progn
                  (move-overlay lispy-overlay (point) (+ (point) 1))
                  (overlay-put lispy-overlay 'invisible nil))
              (setq lispy-overlay (make-overlay (point) (+ (point) 1)))
              (overlay-put lispy-overlay 'priority 9999))
            (overlay-put lispy-overlay 'display str)
            (overlay-put lispy-overlay 'after-string "")
            (put 'lispy-overlay 'last-point last-point)))
      (setq lispy--di-window-config (current-window-configuration))
      (save-selected-window
        (pop-to-buffer (get-buffer-create "*lispy-help*"))
        (let ((inhibit-read-only t))
          (delete-region (point-min) (point-max))
          (insert str)
          (goto-char (point-min))
          (help-mode))))))

(defun lispy--pretty-args (symbol)
  "Return a vector of fontified strings for function SYMBOL."
  (let* ((args (cdr (read (lispy--arglist symbol))))
         (p-opt (cl-position '&optional args :test 'equal))
         (p-rst (or (cl-position '&rest args :test 'equal)
                    (cl-position-if (lambda (x)
                                      (and (symbolp x)
                                           (string-match
                                            "\\.\\.\\.\\'"
                                            (symbol-name x))))
                                    args)))
         (a-req (cl-subseq args 0 (or p-opt p-rst (length args))))
         (a-opt (and p-opt
                     (cl-subseq args (1+ p-opt) (or p-rst (length args)))))
         (a-rst (and p-rst (last args))))
    (format
     "(%s)"
     (mapconcat
      #'identity
      (append
       (list (propertize (symbol-name symbol) 'face 'lispy-face-hint))
       (mapcar
        (lambda (x)
          (propertize (downcase (prin1-to-string x)) 'face 'lispy-face-req-nosel))
        a-req)
       (mapcar
        (lambda (x)
          (propertize (downcase (prin1-to-string x)) 'face 'lispy-face-opt-nosel))
        a-opt)
       (mapcar
        (lambda (x)
          (setq x (downcase (symbol-name x)))
          (unless (string-match "\\.\\.\\.$" x)
            (setq x (concat x "...")))
          (propertize x 'face 'lispy-face-rst-nosel))
        a-rst))
      " "))))

(provide 'lispy-inline)

;;; Local Variables:
;;; outline-regexp: ";; ———"
;;; End:

;;; lispy-inline.el ends here
