;;; furball-evil-tests.el --- Evil integration tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Check effective bindings, including Evil's state-map precedence.

;;; Code:

(require 'ert)
(require 'furball)
(require 'evil)
(require 'furball-evil)

(ert-deftest furball-evil-results-resolve-application-commands ()
  (with-temp-buffer
    (furball-mode)
    (evil-local-mode 1)
    (dolist (state '(normal motion emacs))
      (evil-change-state state)
      (dolist (binding furball--result-bindings)
        (unless (and (memq state '(normal motion)) (equal (car binding) "l"))
          (should (eq (key-binding (kbd (car binding))) (cdr binding))))))))

(ert-deftest furball-evil-results-have-row-motions ()
  (with-temp-buffer
    (furball-mode)
    (evil-local-mode 1)
    (dolist (state '(normal motion))
      (evil-change-state state)
      (should (eq (key-binding (kbd "h")) #'evil-backward-char))
      (should (eq (key-binding (kbd "l")) #'evil-forward-char))
      (should (eq (key-binding (kbd "j")) #'furball-next-item))
      (should (eq (key-binding (kbd "k")) #'furball-previous-item)))))

(ert-deftest furball-evil-query-commands-work-in-editing-states ()
  (with-temp-buffer
    (furball-query-mode)
    (evil-local-mode 1)
    (should (eq evil-state 'insert))
    (dolist (state '(normal insert visual emacs))
      (evil-change-state state)
      (dolist (binding furball--query-bindings)
        (should (eq (key-binding (kbd (car binding))) (cdr binding)))))
    (evil-insert-state)
    (should-not buffer-read-only)
    (insert "service:web")
    (should (equal (buffer-string) "service:web"))))

(ert-deftest furball-evil-log-details-can-quit ()
  (with-temp-buffer
    (furball-log-mode)
    (evil-local-mode 1)
    (dolist (state '(normal motion emacs))
      (evil-change-state state)
      (should (eq (key-binding (kbd "q")) #'quit-window)))))

(ert-deftest furball-evil-dashboard-opens-without-capturing-motions ()
  (save-window-excursion
    (let (menu-opened)
      (cl-letf (((symbol-function 'furball-refresh) #'ignore)
                ((symbol-function 'furball-menu)
                 (lambda () (interactive) (setq menu-opened t))))
        (call-interactively #'furball))
      (should-not menu-opened)
      (evil-local-mode 1)
      (evil-normal-state)
      (should (eq (key-binding (kbd "l")) #'evil-forward-char))
      (should (eq (key-binding (kbd "j")) #'furball-next-item)))))

(ert-deftest furball-evil-log-details-preserve-hjkl ()
  (with-temp-buffer
    (furball-log-mode)
    (evil-local-mode 1)
    (dolist (state '(normal motion))
      (evil-change-state state)
      (dolist (binding '(("h" . evil-backward-char) ("j" . evil-next-line)
                         ("k" . evil-previous-line) ("l" . evil-forward-char)))
        (should (eq (key-binding (kbd (car binding))) (cdr binding)))))))

(ert-deftest furball-evil-view-actions-work-without-transient ()
  (dolist (entry '((furball-mode
                    ("x" . furball-log-functions-menu) ("c" . furball-open-traceback)
                    ("v" . furball-saved-views-menu) ("L" . furball-search-menu))
                   (furball-log-mode
                    ("x" . furball-log-functions-menu) ("c" . furball-open-traceback)
                    ("g" . beginning-of-buffer) ("G" . end-of-buffer) ("Q" . quit-window))
                   (furball-query-mode
                    ("r" . furball-query-run) ("c" . completion-at-point) ("Q" . quit-window))))
    (with-temp-buffer
      (funcall (car entry))
      (evil-local-mode 1)
      (dolist (state '(normal motion))
        (evil-change-state state)
        (dolist (binding (cdr entry))
          (should (eq (key-binding (kbd (car binding))) (cdr binding))))))))

(provide 'furball-evil-tests)
;;; furball-evil-tests.el ends here
