;;; furball-transient-tests.el --- Menu behavior tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise contextual menus and their explicit apply boundary.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'furball)

(ert-deftest furball-transient-dispatches-every-view ()
  (dolist (entry '((furball-mode dashboard furball-dashboard-menu)
                   (furball-mode monitors furball-monitors-menu)
                   (furball-mode monitor furball-monitor-menu)
                   (furball-mode logs furball-logs-menu)
                   (furball-query-mode nil furball-query-menu)
                   (furball-log-mode nil furball-log-menu)))
    (with-temp-buffer
      (funcall (car entry))
      (setq furball--state `((:view . ((:kind . ,(cadr entry))))))
      (let (opened)
        (cl-letf (((symbol-function 'transient-setup)
                   (lambda (prefix &rest _) (setq opened prefix))))
          (furball-menu))
        (should (eq opened (nth 2 entry)))))))

(ert-deftest furball-transient-search-applies-expression-window ()
  (let (opened)
    (cl-letf (((symbol-function 'transient-args)
               (lambda (_)
                 '("--query=logs(\"env:prod\").index(\"*\").rollup(\"count\").last(\"1h\") > 1"
                   "--window=2h" "--site=us5.datadoghq.com")))
              ((symbol-function 'furball--open-view)
               (lambda (view &optional _) (setq opened view))))
      (furball-transient-search))
    (should (equal (map-elt opened :time-range) "2h"))
    (should (equal (map-elt (furball--parse-query (map-elt opened :query)) :time-range) "2h"))
    (should (equal (map-elt opened :site) "us5.datadoghq.com"))))

(ert-deftest furball-transient-saved-views-disambiguate-names ()
  (let* ((furball-landing-page '(((:name . "Same") (:kind . logs) (:query . "env:prod"))
                                 ((:name . "Same") (:kind . monitors) (:query . "tag:prod"))))
         (original (copy-tree furball-landing-page))
         opened)
    (cl-letf (((symbol-function 'transient-args) (lambda (_) '("--view=2: Same")))
              ((symbol-function 'furball--open-view)
               (lambda (view &optional _) (setq opened view))))
      (furball-transient-open-saved))
    (should (equal opened (cadr original)))
    (should (equal furball-landing-page original))))

(ert-deftest furball-transient-time-menu-preserves-history-until-applied ()
  (with-temp-buffer
    (furball-mode)
    (setq furball--state '((:view . ((:kind . logs) (:query . "env:prod")
                                     (:from . 1000) (:to . 2000)))))
    (let ((original (copy-tree furball--state)))
      (cl-letf (((symbol-function 'transient-setup) #'ignore))
        (furball-time-menu))
      (should (equal furball--state original))
      (cl-letf (((symbol-function 'transient-args) (lambda (_) '("--window=6h")))
                ((symbol-function 'furball-refresh) #'ignore))
        (furball-transient-set-window))
      (should-not (map-nested-elt furball--state '(:view :from)))
      (should-not (map-nested-elt furball--state '(:view :to)))
      (should (equal (map-nested-elt furball--state '(:view :time-range)) "6h")))))

(ert-deftest furball-transient-next-page-requires-current-idle-results ()
  (with-temp-buffer
    (setq furball--state '((:next . "cursor") (:view . logs) (:fetched-view . logs)))
    (should (furball--more-results-p))
    (setq furball--state (furball--with furball--state '((:loading . t))))
    (should-not (furball--more-results-p))
    (setq furball--state (furball--with furball--state '((:loading . nil) (:view . edited))))
    (should-not (furball--more-results-p))))


(ert-deftest furball-log-functions-bind-in-order-and-pass-source-buffer ()
  (with-temp-buffer
    (furball-mode)
    (let* ((source (current-buffer))
           received
           (functions (make-list 35 'furball-test-callback)))
      (setq furball--state `((:view . ((:log-view-functions . ,functions)))))
      (cl-letf (((symbol-function 'furball-test-callback)
                 (lambda (buffer) (setq received buffer))))
        (let ((suffixes (furball--log-function-suffixes)))
          (should (equal (mapcar #'car suffixes)
                         (mapcar #'char-to-string (string-to-list "123456789abcdefghijklmnopqrstuvwxyz"))))
          (with-temp-buffer (funcall (nth 2 (car suffixes))))
          (should (eq received source)))))))

(ert-deftest furball-log-functions-reject-overflow-and-undefined-functions ()
  (with-temp-buffer
    (setq furball--state `((:view . ((:log-view-functions . ,(make-list 36 'ignore))))))
    (should-error (furball--log-function-suffixes) :type 'user-error)
    (setq furball--state '((:view . ((:log-view-functions . (furball-undefined-callback))))))
    (should-error (furball--log-function-suffixes) :type 'user-error)))

(ert-deftest furball-log-functions-follow-preview-into-full-log ()
  (save-window-excursion
    (with-temp-buffer
      (furball-mode)
      (let ((inhibit-read-only t)
            (view '((:kind . logs) (:log-view-functions . (ignore))))
            detail)
        (furball--log-row '((id . "fixture") (attributes . ((message . "Traceback")))) view)
        (goto-char (point-min))
        (should (equal (furball--log-view-functions) '(ignore)))
        (unwind-protect
            (progn
              (furball-open-at-point)
              (setq detail (current-buffer))
              (should (derived-mode-p 'furball-log-mode))
              (should buffer-read-only)
              (should (equal (furball--log-view-functions) '(ignore))))
          (when (buffer-live-p detail) (kill-buffer detail)))))))

(ert-deftest furball-monitor-overview-offers-selected-view-functions ()
  (with-temp-buffer
    (furball-mode)
    (let ((inhibit-read-only t))
      (furball--render-monitors
       '(((id . 1) (name . "Monitor")))
       '((:log-view-functions . (ignore)))))
    (goto-char (point-min))
    (should (equal (furball--log-view-functions) '(ignore)))
    (should (equal (cadar (furball--log-function-suffixes)) "ignore"))))

(provide 'furball-transient-tests)
;;; furball-transient-tests.el ends here
