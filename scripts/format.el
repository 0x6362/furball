;;; format.el --- Reindent Emacs Lisp files in batch mode -*- lexical-binding: t; -*-

;;; Commentary:
;; `furball-format-files' reindents each file named on the command line.

;;; Code:

(require 'transient)
(require 'evil)

(setq-default indent-tabs-mode nil)

(defun furball-format-files ()
  "Reindent every file in `command-line-args-left' and report changed files."
  (dolist (file command-line-args-left)
    (with-temp-buffer
      (insert-file-contents file)
      (let ((before (buffer-string)))
        (emacs-lisp-mode)
        (untabify (point-min) (point-max))
        (indent-region (point-min) (point-max))
        (delete-trailing-whitespace)
        (unless (equal before (buffer-string))
          (write-region (point-min) (point-max) file)
          (message "Reindented %s" file)))))
  (setq command-line-args-left nil))

;;; format.el ends here
