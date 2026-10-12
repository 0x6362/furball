;;; install.el --- Install lint dependencies into the sandbox -*- lexical-binding: t; -*-

;;; Commentary:
;; Run in batch mode with `package-user-dir' pointing at the sandbox.

;;; Code:

(require 'package)

(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(package-refresh-contents)
(dolist (pkg '(elisp-lint transient evil))
  (unless (package-installed-p pkg)
    (package-install pkg)))

;;; install.el ends here
