;;; furball-tests.el --- Behavioral tests for Furball -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with (ert-run-tests-batch "furball-") through emacsclient.
;; View tests replace requests; transport tests use real fixture subprocesses.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'furball)

(defconst furball-test--expression
  "logs(\"service:prosite-celery-titan-messaging \\\"Sidekick task failed\\\" env:prod\").index(\"*\").rollup(\"count\").by(\"env,@error.kind\").last(\"1h\") > 1")

(defconst furball-test--log
  '((id . "log-1")
    (attributes . ((timestamp . "2026-07-18T19:00:00Z") (status . "error")
                   (service . "worker") (host . "host-1")
                   (message . "Sidekick task failed\nTraceback")
                   (tags . ("env:prod"))
                   (attributes . ((error . ((kind . "ValueError")))))))))

(ert-deftest furball-expression-preserves-search-and-condition ()
  (let ((parsed (furball--parse-query furball-test--expression)))
    (should (equal (map-elt parsed :query)
                   "service:prosite-celery-titan-messaging \"Sidekick task failed\" env:prod"))
    (should (equal (map-elt parsed :indexes) ["*"]))
    (should (equal (map-elt parsed :group-by) '("env" "@error.kind")))
    (should (equal (map-elt parsed :time-range) "1h"))
    (should (= (map-elt parsed :threshold) 1))))

(ert-deftest furball-unsupported-expression-is-not-a-log-search ()
  (should-error (furball--parse-query "logs(\"*\").rollup(\"avg\").last(\"1h\") > 1")
                :type 'user-error)
  (should-error (furball--parse-query "logs(\"unterminated") :type 'user-error))

(ert-deftest furball-expression-without-index-or-groups ()
  (let ((parsed (furball--parse-query "logs(\"*\").rollup(\"count\").last(\"15m\") >= 2")))
    (should (equal (map-elt parsed :indexes) ["*"]))
    (should-not (map-elt parsed :group-by))
    (should (equal (map-elt parsed :operator) ">="))))

(ert-deftest furball-import-keeps-large-ids-and-exact-window ()
  (let ((view (furball--url-view
               (concat "https://us5.datadoghq.com/logs?query=service%3Aworker%20%22Sidekick%20task%20failed%22%20env%3Aprod"
                       "&from_ts=1784408010000&to_ts=1784411610000"
                       "&link_event_id=8726648848452761513&link_monitor_id=19770390"
                       "&stream_sort=desc&refresh_mode=sliding&live=false&storage=hot"))))
    (should (equal (map-elt view :query) "service:worker \"Sidekick task failed\" env:prod"))
    (should (equal (map-elt view :event-id) "8726648848452761513"))
    (should (= (map-elt view :from) 1784408010000))
    (should (= (map-elt view :to) 1784411610000))
    (should (equal (map-elt view :site) "us5.datadoghq.com"))
    (should (equal (map-elt view :storage) "indexes"))
    (should (= (map-elt (furball--log-scope view 9999999999) :to) 1784411610000))))

(ert-deftest furball-import-rejects-foreign-sites-and-invalid-windows ()
  (dolist (url '("https://us5.datadoghq.com.evil.test/logs?from_ts=1&to_ts=2"
                 "https://us5.datadoghq.com/logs?from_ts=2&to_ts=1"
                 "https://us5.datadoghq.com/logs?query=*"))
    (should-error (furball--url-view url) :type 'user-error)))

(ert-deftest furball-scopes-are-immutable-and-resolve-relative-time ()
  (let* ((view '((:kind . logs) (:query . "service:web") (:time-range . "1h")))
         (before (copy-tree view))
         (scope (furball--log-scope view 7200)))
    (should (= (map-elt scope :from) 3600000))
    (should (= (map-elt scope :to) 7200000))
    (should (equal view before))))

(ert-deftest furball-group-filter-quotes-values ()
  (should (equal (furball--group-filter "env:prod,@error.kind:Some Error")
                 "env:\"prod\" AND @error.kind:\"Some Error\"")))

(ert-deftest furball-pagination-reuses-window-and-cursor ()
  (let (requests callbacks)
    (cl-letf (((symbol-function 'furball--request)
               (lambda (_site _method _path body callback)
                 (push body requests) (push callback callbacks))))
      (with-temp-buffer
        (furball-mode)
        (setq furball--state '((:view . ((:kind . logs) (:name . "Test")
                                         (:query . "env:prod") (:site . "us5.datadoghq.com")))))
        (furball-refresh)
        (funcall (car callbacks)
                 `((:data . ((data . (,furball-test--log)) (meta . ((page . ((after . "cursor-1")))))))
                   (:fetched-at . 100)))
        (furball-more)
        (should (equal (map-nested-elt (car requests) '(page cursor)) "cursor-1"))
        (should (equal (map-elt (car requests) 'filter) (map-elt (cadr requests) 'filter)))
        (funcall (car callbacks) '((:data . ((data . nil) (meta . ((page . nil))))) (:fetched-at . 101)))
        (should (= (length (map-elt furball--state :rows)) 1))
        (should-not (map-elt furball--state :next))
        (should buffer-read-only)
        (should-error (insert "edit") :type 'buffer-read-only)))))

(ert-deftest furball-out-of-order-responses-do-not-replace-new-results ()
  (let (callbacks)
    (cl-letf (((symbol-function 'furball--request)
               (lambda (_site _method _path _body callback) (push callback callbacks))))
      (with-temp-buffer
        (furball-mode)
        (setq furball--state '((:view . ((:kind . logs) (:query . "old")))))
        (furball-refresh)
        (furball--set-state '((:view . ((:kind . logs) (:query . "new")))))
        (furball-refresh)
        (funcall (car callbacks) '((:data . ((data . nil))) (:fetched-at . 200)))
        (funcall (cadr callbacks) '((:error . "old failure")))
        (should-not (map-elt furball--state :error))
        (should (= (map-elt furball--state :updated) 200))
        (should (equal (map-nested-elt furball--state '(:scope :query)) "new"))))))

(ert-deftest furball-failed-refresh-retains-and-labels-old-results ()
  (let (callback)
    (cl-letf (((symbol-function 'furball--request)
               (lambda (_site _method _path _body cb) (setq callback cb))))
      (with-temp-buffer
        (furball-mode)
        (setq furball--state '((:view . ((:kind . logs) (:query . "old")))))
        (furball-refresh)
        (funcall callback `((:data . ((data . (,furball-test--log)))) (:fetched-at . 200)))
        (furball--set-state '((:view . ((:kind . logs) (:query . "new")))))
        (furball-refresh)
        (funcall callback '((:error . "HTTP 403")))
        (should (string-match-p "previous query" (buffer-string)))
        (should (string-match-p "HTTP 403" (buffer-string)))
        (should (string-match-p "Sidekick task failed" (buffer-string)))
        (should-error (furball-more) :type 'user-error)))))

(ert-deftest furball-query-editor-reruns-without-changing-saved-view ()
  (let* ((saved '((:kind . logs) (:query . "old") (:from . 1000) (:to . 2000)))
         (target (generate-new-buffer " *furball-test-results*"))
         (editor (generate-new-buffer " *furball-test-query*"))
         request)
    (unwind-protect
        (cl-letf (((symbol-function 'furball--request)
                   (lambda (_site _method _path body _callback) (setq request body)))
                  ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) buffer)))
          (with-current-buffer target
            (furball-mode)
            (setq furball--state `((:view . ,saved))))
          (with-current-buffer editor
            (furball-query-mode)
            (setq furball--query-target target)
            (insert "service:new")
            (should-not buffer-read-only)
            (furball-query-run))
          (should (equal (map-nested-elt request '(filter query)) "service:new"))
          (should (equal (map-nested-elt request '(filter from)) "1000"))
          (should (equal (map-elt saved :query) "old"))
          (should (buffer-local-value 'buffer-read-only target)))
      (kill-buffer target) (kill-buffer editor))))

(ert-deftest furball-monitor-drilldown-preserves-group-and-trigger ()
  (let (opened beside)
    (cl-letf (((symbol-function 'furball--open-view)
               (lambda (view &optional side) (setq opened view beside side))))
      (with-temp-buffer
        (furball-mode)
        (setq furball--state
              `((:view . ((:kind . monitor) (:site . "us5.datadoghq.com")))
                (:rows . ((id . 19770390) (name . "Failures") (type . "log alert")
                          (query . ,furball-test--expression)))))
        (furball--monitor-logs '((:group . "env:prod,@error.kind:ValueError")
                                 (:state . ((status . "Alert") (last_triggered_ts . 1784411610)))))
        (should beside)
        (should (= (map-elt opened :to) 1784411610000))
        (should (= (map-elt opened :from) 1784408010000))
        (should (string-match-p "@error.kind:\"ValueError\""
                                (map-elt (furball--log-scope opened) :query)))
        (should (string-match-p "current monitor configuration" (map-elt opened :provenance)))))))

(ert-deftest furball-landing-page-is-ordered-and-read-only ()
  (let ((furball-landing-page '(((:name . "Sidekick") (:kind . monitors) (:query . "tag:\"component:sidekick\""))
                               ((:name . "Failures") (:kind . logs) (:query . "env:prod"))))
        paths)
    (cl-letf (((symbol-function 'furball--request)
               (lambda (_site _method path _body callback)
                 (push path paths)
                 (funcall callback '((:data . ((data . nil) (monitors . nil))) (:fetched-at . 100))))))
      (with-temp-buffer
        (furball-mode)
        (setq furball--state '((:view . ((:kind . dashboard)))))
        (furball-refresh)
        (should buffer-read-only)
        (should (= (length paths) 2))
        (should (< (string-match "Sidekick" (buffer-string))
                   (string-match "Failures" (buffer-string))))
        (goto-char (point-min))
        (furball-next-item)
        (should (equal (map-elt (get-text-property (point) 'furball-value) :name) "Sidekick"))
        (furball-next-item)
        (should (equal (map-elt (get-text-property (point) 'furball-value) :name) "Failures"))
        (furball-previous-item)
        (should (equal (map-elt (get-text-property (point) 'furball-value) :name) "Sidekick"))))))

(ert-deftest furball-completion-offers-fields-and-observed-values ()
  (with-temp-buffer
    (furball-query-mode)
    (furball--learn-completions 'logs `((data . (,furball-test--log))))
    (insert "ser")
    (let ((completion (furball-completion-at-point)))
      (should (member "service:" (nth 2 completion)))
      (should (member "service:\"worker\"" (nth 2 completion)))
      (should (member "env:prod" (nth 2 completion))))))

(ert-deftest furball-completion-matches-unquoted-values-and-nested-fields ()
  (with-temp-buffer
    (furball-query-mode)
    (furball--learn-completions 'logs `((data . (,furball-test--log))))
    (insert "@error.kind:Va")
    (let* ((completion (furball-completion-at-point))
           (prefix (buffer-substring-no-properties (nth 0 completion) (nth 1 completion))))
      (should (member "@error.kind:ValueError" (all-completions prefix (nth 2 completion)))))))

(ert-deftest furball-completion-matches-quoted-monitor-tags ()
  (with-temp-buffer
    (furball-query-mode)
    (furball--learn-completions 'monitors '((counts . ((tag . (((name . "component:sidekick"))))))))
    (insert "tag:\"component:si")
    (let* ((completion (furball-completion-at-point))
           (prefix (buffer-substring-no-properties (nth 0 completion) (nth 1 completion))))
      (should (member "tag:\"component:sidekick\"" (all-completions prefix (nth 2 completion)))))))

(ert-deftest furball-monitor-attributes-retain-at-prefix ()
  (should (equal (furball--group-filter "env:prod,error.kind:ValueError" '("env" "@error.kind"))
                 "env:\"prod\" AND @error.kind:\"ValueError\"")))

(ert-deftest furball-query-editor-preserves-drafts-and-refreshes-clean-text ()
  (let ((target (generate-new-buffer " *furball-editor-test*")) editor)
    (unwind-protect
        (save-current-buffer
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _) (set-buffer buffer))))
            (with-current-buffer target
              (furball-mode)
              (setq furball--state '((:view . ((:kind . logs) (:query . "first")))))
              (furball-edit-query)
              (setq editor (current-buffer))
              (should (equal (buffer-string) "first"))
              (erase-buffer)
              (insert "draft"))
            (with-current-buffer target
              (furball--set-state '((:view . ((:kind . logs) (:query . "second")))))
              (furball-edit-query)
              (should (equal (buffer-string) "draft"))
              (set-buffer-modified-p nil))
            (with-current-buffer target
              (furball-edit-query)
              (should (equal (buffer-string) "second")))))
      (kill-buffer target)
      (when (buffer-live-p editor)
        (with-current-buffer editor (set-buffer-modified-p nil))
        (kill-buffer editor)))))

(defun furball-test--pup (script &optional body timeout cancel)
  "Run a fixture SCRIPT with BODY, optional TIMEOUT and CANCEL."
  (let ((file (make-temp-file "furball-pup-"))
        result process before command (calls 0))
    (unwind-protect
        (progn
          (with-temp-file file (insert "#!/bin/sh\n" script "\n"))
          (set-file-modes file #o700)
          (let ((furball-pup-command file)
                (furball-pup-timeout (or timeout 3)))
            (setq process (furball--request
                           "us5.datadoghq.com" "POST" "/api/v2/logs/events/search" body
                           (lambda (value) (setq result value calls (1+ calls)))))
            (setq before (null result) command (process-command process))
            (when cancel (delete-process process))
            (let ((deadline (+ (float-time) 4)))
              (while (and (not result) (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            (should result)
            (should (= calls 1))
            (should-not (buffer-live-p (process-buffer process)))
            (should-not (buffer-live-p (process-get process 'furball-stderr)))
            (list result command before)))
      (when (and process (process-live-p process)) (delete-process process))
      (delete-file file))))

(ert-deftest furball-pup-is-asynchronous-and-preserves-stdin-json ()
  (let* ((query "service:web \"$(touch /tmp/never-execute)\" ; &")
         (body (furball--logs-body (furball--log-scope `((:query . ,query)) 7200) "next"))
         (outcome (furball-test--pup "cat" body)))
    (should (nth 2 outcome))
    (should (equal (map-nested-elt (car outcome) '(:data filter query)) query))
    (should (equal (map-nested-elt (car outcome) '(:data page cursor)) "next"))
    (should (equal (cdr (nth 1 outcome))
                   '("--no-agent" "--output" "json" "api" "/api/v2/logs/events/search"
                     "--method" "POST" "--input" "-")))))

(ert-deftest furball-pup-site-is-local-to-the-child ()
  (let ((before (getenv "DD_SITE"))
        (outcome (furball-test--pup "printf '{\"site\":\"%s\"}' \"$DD_SITE\"")))
    (should (equal (map-nested-elt (car outcome) '(:data site)) "us5.datadoghq.com"))
    (should (equal (getenv "DD_SITE") before))))

(ert-deftest furball-pup-stderr-does-not-corrupt-json ()
  (let ((result (car (furball-test--pup "printf 'notice' >&2; printf '{\"data\":[]}'"))))
    (should (assq :data result))
    (should-not (map-elt result :error))))

(ert-deftest furball-pup-nonzero-exit-is-visible ()
  (should (string-match-p "Pup exited 7"
                          (map-elt (car (furball-test--pup "printf 'authentication required' >&2; exit 7")) :error))))

(ert-deftest furball-pup-rejects-invalid-and-trailing-json ()
  (dolist (script '("printf 'bad json'" "printf '{} trailing'"))
    (should (string-match-p "Invalid Pup JSON" (map-elt (car (furball-test--pup script)) :error)))))

(ert-deftest furball-pup-timeout-cleans-up ()
  (should (equal (map-elt (car (furball-test--pup "exec sleep 5" nil 0.05)) :error)
                 "Pup request timed out")))

(ert-deftest furball-pup-cancellation-delivers-one-error ()
  (should (map-elt (car (furball-test--pup "exec sleep 5" nil nil t)) :error)))

(ert-deftest furball-pup-missing-executable-is-visible ()
  (let ((furball-pup-command "/nonexistent/furball-pup") result)
    (furball--request "us5.datadoghq.com" "GET" "/api/v1/monitor/search" nil
                      (lambda (value) (setq result value)))
    (should (string-match-p "Could not run Pup" (map-elt result :error)))))

(ert-deftest furball-log-details-display-complete-traceback-read-only ()
  (let* ((stack (concat "Traceback (most recent call last):\n"
                        (make-string 5000 ?x) "\nValueError: complete tail"))
         (log `((id . "trace-log")
                (attributes . ((message . "Task failed")
                               (tags . ("env:prod" "service:worker"))
                               (attributes . ((error . ((stack . ,stack)))
                                              (exc_info . ,stack)))))))
         details)
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _) (setq details buffer))))
          (with-temp-buffer
            (furball-mode)
            (let ((inhibit-read-only t)) (furball--log-row log))
            (goto-char (point-min))
            (furball-open-at-point))
          (with-current-buffer details
            (should (derived-mode-p 'furball-log-mode))
            (should buffer-read-only)
            (should-not truncate-lines)
            (should (string-search (concat "Traceback · error.stack\n" stack) (buffer-string)))
            (should-not (string-search "Traceback · exc_info" (buffer-string)))
            (should (string-search "Raw log record" (buffer-string)))
            (goto-char (point-min))
            (search-forward "Raw log record\n")
            (should (equal (map-nested-elt
                            (json-parse-buffer :object-type 'alist :array-type 'list)
                            '(attributes tags))
                           '("env:prod" "service:worker")))))
      (when (buffer-live-p details) (kill-buffer details)))))

(ert-deftest furball-log-tracebacks-support-exc-info-and-flat-fields ()
  (dolist (fields '(((exc_info . "Traceback\nValueError"))
                    ((error.stack . "Traceback\nValueError"))))
    (should (equal (cdar (furball--log-tracebacks
                         `((attributes . ((attributes . ,fields))))))
                   "Traceback\nValueError"))))

(ert-deftest furball-log-without-stack-keeps-full-message ()
  (with-temp-buffer
    (furball--insert-log-details '((attributes . ((message . "Message\nwith embedded traceback")))))
    (should (string-search "Message\nwith embedded traceback" (buffer-string)))
    (should (string-search "No separate traceback field" (buffer-string)))))

(provide 'furball-tests)
;;; furball-tests.el ends here
