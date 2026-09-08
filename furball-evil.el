;;; furball-evil.el --- Evil keymaps for Furball -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Loaded automatically when both Furball and Evil are available.
;; Result commands work in normal and motion states; queries start in insert.

;;; Code:

(require 'evil)

(defvar furball-mode-map)
(defvar furball-query-mode-map)
(defvar furball-log-mode-map)
(defvar furball--result-bindings)
(defvar furball--query-bindings)

(declare-function furball-menu "furball-transient")
(declare-function furball-log-functions-menu "furball-transient")
(declare-function furball-query-run "furball")
(declare-function furball-next-item "furball")
(declare-function furball-previous-item "furball")

(with-eval-after-load 'furball
  (evil-set-initial-state 'furball-mode 'normal)
  (evil-set-initial-state 'furball-query-mode 'insert)
  (evil-set-initial-state 'furball-log-mode 'motion)
  (evil-define-key* '(normal motion) furball-log-mode-map
    (kbd "q") #'quit-window
    (kbd "?") #'furball-menu
    (kbd "x") #'furball-log-functions-menu
    (kbd "g") #'beginning-of-buffer
    (kbd "G") #'end-of-buffer
    (kbd "Q") #'quit-window)
  (dolist (binding furball--result-bindings)
    (evil-define-key* '(normal motion) furball-mode-map
      (kbd (car binding)) (cdr binding)))
  (evil-define-key* '(normal motion) furball-mode-map
    (kbd "h") #'evil-backward-char
    (kbd "l") #'evil-forward-char
    (kbd "j") #'furball-next-item
    (kbd "k") #'furball-previous-item)
  (evil-define-key* '(normal motion) furball-query-mode-map
    (kbd "r") #'furball-query-run
    (kbd "c") #'completion-at-point
    (kbd "Q") #'quit-window
    (kbd "?") #'furball-menu)
  (dolist (binding furball--query-bindings)
    (evil-define-key* '(normal insert visual) furball-query-mode-map
      (kbd (car binding)) (cdr binding))))

(provide 'furball-evil)
;;; furball-evil.el ends here
