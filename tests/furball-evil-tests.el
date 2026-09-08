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
        (should (eq (key-binding (kbd (car binding))) (cdr binding)))))))

(ert-deftest furball-evil-results-have-row-motions ()
  (with-temp-buffer
    (furball-mode)
    (evil-local-mode 1)
    (dolist (state '(normal motion))
      (evil-change-state state)
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

(provide 'furball-evil-tests)
;;; furball-evil-tests.el ends here
