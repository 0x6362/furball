;;; furball-api.el --- Asynchronous Pup transport -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Cate B.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run Datadog Pup asynchronously; authentication belongs to the CLI.

;;; Code:

(require 'json)
(require 'furball-query)

(defgroup furball nil
  "Browse Datadog monitors and logs."
  :group 'tools
  :prefix "furball-")

(defcustom furball-site (or (getenv "DD_SITE") "datadoghq.com")
  "Datadog site suffix, such as \"us5.datadoghq.com\".
A saved view or imported URL can override this site."
  :type 'string)

(defcustom furball-pup-command "pup"
  "Datadog Pup executable, found using variable `exec-path' or an absolute path."
  :type 'file)

(defcustom furball-pup-timeout 60
  "Maximum seconds allowed for a Pup request."
  :type 'natnum)

(defcustom furball-rate-limits
  '((logs-search . ((:path . "/api/v2/logs/events/search") (:limit . 3) (:period . 10))))
  "Request budgets Furball stays within for each Datadog site.
Each entry maps a rule name to an alist with the API :path prefix it
covers and the most requests, :limit, started in any :period seconds.
Requests to other paths start immediately."
  :type '(alist :key-type symbol
                :value-type (alist :key-type (choice (const :path) (const :limit)
                                                     (const :period))
                                   :value-type (choice string number))))

(defcustom furball-rate-limit-retries 2
  "Times a request is retried after Datadog reports a rate limit."
  :type 'natnum)

(defvar furball--queues nil
  "Alist from (SITE . RULE) to rate-limit queue state.
State holds :sent start times, :pending requests oldest first,
:paused-until after a rate-limit response, and the :timer that next
drains the queue.")

(defun furball--pup-result (process)
  "Decode completed PROCESS output into the UI result contract."
  (cond
   ((process-get process 'furball-timeout)
    '((:error . "Pup request timed out")))
   ((not (and (eq (process-status process) 'exit)
              (= (process-exit-status process) 0)))
    (let ((stderr (with-current-buffer (process-get process 'furball-stderr)
                    (buffer-substring-no-properties (point-min) (point-max)))))
      `((:error . ,(format "Pup exited %s: %s" (process-exit-status process)
                           (string-trim (substring stderr 0 (min (length stderr) 2000)))))
        ,@(when (string-search "HTTP 429" stderr)
            `((:rate-limited . t)
              (:retry-after . ,(and (string-match "reset: *\\([0-9]+\\)" stderr)
                                    (string-to-number (match-string 1 stderr)))))))))
   (t
    (condition-case err
        (with-current-buffer (process-buffer process)
          (goto-char (point-min))
          (let ((data (json-parse-buffer :object-type 'alist :array-type 'list
                                         :null-object nil :false-object :false)))
            (skip-chars-forward " \t\r\n")
            (unless (eobp) (error "Unexpected text after Pup JSON output"))
            `((:data . ,data) (:fetched-at . ,(float-time)))))
      (error `((:error . ,(format "Invalid Pup JSON: %s" (error-message-string err)))))))))

(defun furball--pup-finish (process _event)
  "Deliver the completed PROCESS result once, then release its resources."
  (when (and (memq (process-status process) '(exit signal failed))
             (not (process-get process 'furball-delivered)))
    (process-put process 'furball-delivered t)
    (let ((result (furball--pup-result process))
          (callback (process-get process 'furball-callback)))
      (when-let* ((timer (process-get process 'furball-timer)))
        (cancel-timer timer))
      (kill-buffer (process-buffer process))
      (kill-buffer (process-get process 'furball-stderr))
      (funcall callback result))))

(defun furball--start-pup (site method path body callback)
  "Run Pup for PATH on SITE using METHOD and BODY; deliver CALLBACK.
Pup owns credentials.  JSON bodies go to stdin and arguments bypass a shell.
Pup runs locally from the home directory, regardless of the caller's
`default-directory'.  Return the asynchronous process, or nil when
startup fails."
  (furball--site site)
  (let ((stdout (generate-new-buffer " *furball-pup-output*"))
        (stderr (generate-new-buffer " *furball-pup-errors*"))
        (default-directory (expand-file-name "~/"))
        (process-environment (copy-sequence process-environment))
        process failure)
    (setenv "DD_SITE" site)
    (condition-case err
        (progn
          (setq process
                (make-process
                 :name "furball-pup" :buffer stdout :stderr stderr
                 :command (append (list furball-pup-command "--no-agent" "--output" "json"
                                        "api" path "--method" method)
                                  (when body '("--input" "-")))
                 :connection-type 'pipe :coding 'utf-8-unix :noquery t
                 :sentinel #'furball--pup-finish))
          (process-put process 'furball-stderr stderr)
          (process-put process 'furball-callback callback)
          (process-put process 'furball-timer
                       (run-at-time furball-pup-timeout nil
                                    (lambda ()
                                      (when (process-live-p process)
                                        (process-put process 'furball-timeout t)
                                        (delete-process process)))))
          (when body (process-send-string process (json-serialize body)))
          (process-send-eof process))
      (error (setq failure (error-message-string err))))
    (when failure
      (when process
        (process-put process 'furball-delivered t)
        (when-let* ((timer (process-get process 'furball-timer))) (cancel-timer timer))
        (when (process-live-p process) (delete-process process)))
      (when (buffer-live-p stdout) (kill-buffer stdout))
      (when (buffer-live-p stderr) (kill-buffer stderr))
      (funcall callback `((:error . ,(format "Could not run Pup: %s" failure)))))
    (unless failure process)))

(defun furball--request (site method path body callback &optional options)
  "Run Pup for PATH on SITE using METHOD and BODY; deliver CALLBACK once.
Requests covered by `furball-rate-limits' wait for budget, and requests
that Datadog rate limits are retried up to `furball-rate-limit-retries'
times.  OPTIONS is an alist: :live-p returns nil once the result is no
longer wanted, so a waiting request is dropped unsent; :on-wait receives
a message whenever the request is delayed."
  (furball--site site)
  (furball--enqueue `((:site . ,site) (:method . ,method) (:path . ,path)
                      (:body . ,body) (:callback . ,callback) (:attempts . 0)
                      (:rule . ,(car (seq-find (lambda (rule)
                                                 (string-prefix-p (map-elt (cdr rule) :path) path))
                                               furball-rate-limits)))
                      ,@options)))

(defun furball--set-queue (key changes)
  "Apply CHANGES to the state of rate-limit queue KEY."
  (setq furball--queues
        (cons (cons key (furball--with (map-elt furball--queues key) changes))
              (assoc-delete-all key furball--queues))))

(defun furball--wanted-p (request)
  "Return non-nil while REQUEST's result is still wanted."
  (let ((live (map-elt request :live-p)))
    (or (null live) (funcall live))))

(defun furball--enqueue (request &optional first)
  "Queue REQUEST behind its rate-limit rule, or start it when unlimited.
When FIRST is non-nil, REQUEST goes ahead of other waiting requests."
  (if-let* ((rule (map-elt request :rule)))
      (let* ((key (cons (map-elt request :site) rule))
             (pending (map-nested-elt furball--queues (list key :pending))))
        (furball--set-queue key `((:pending . ,(if first (cons request pending)
                                                 (append pending (list request))))))
        (furball--drain key))
    (furball--send request)))

(defun furball--drain (key)
  "Start the waiting requests that rate-limit queue KEY has budget for."
  (let* ((rule (map-elt furball-rate-limits (cdr key)))
         (limit (map-elt rule :limit))
         (period (map-elt rule :period))
         (now (float-time))
         (state (map-elt furball--queues key))
         (paused (when-let* ((until (map-elt state :paused-until)))
                   (and (> until now) until)))
         (sent (seq-filter (lambda (time) (> time (- now period))) (map-elt state :sent)))
         (pending (seq-filter #'furball--wanted-p (map-elt state :pending)))
         ready)
    (while (and pending (not paused) (< (length sent) limit))
      (push (pop pending) ready)
      (push now sent))
    (when-let* ((timer (map-elt state :timer)))
      (cancel-timer timer))
    (let ((wake (and pending (or paused (+ (if sent (apply #'min sent) now) period)))))
      (furball--set-queue
       key `((:sent . ,sent) (:pending . ,pending) (:paused-until . ,paused)
             (:timer . ,(and wake (run-at-time (max 0 (- wake now)) nil #'furball--drain key)))))
      (dolist (request pending)
        (when-let* ((on-wait (map-elt request :on-wait)))
          (funcall on-wait
                   (if paused
                       (format "rate limited by Datadog; retrying in %ds" (ceiling (- paused now)))
                     (format "waiting: %s allows %s per %ss" (cdr key) limit period))))))
    (mapc #'furball--send (nreverse ready))))

(defun furball--send (request)
  "Start REQUEST, retrying it while Datadog reports a rate limit."
  (furball--start-pup
   (map-elt request :site) (map-elt request :method) (map-elt request :path)
   (map-elt request :body)
   (lambda (result)
     (if (and (map-elt result :rate-limited)
              (< (map-elt request :attempts) furball-rate-limit-retries)
              (furball--wanted-p request))
         (furball--retry request (or (map-elt result :retry-after)
                                     (map-nested-elt furball-rate-limits
                                                     (list (map-elt request :rule) :period))
                                     10))
       (funcall (map-elt request :callback) result)))))

(defun furball--retry (request delay)
  "Retry REQUEST after DELAY seconds, ahead of requests waiting behind it."
  (let ((request (furball--with request `((:attempts . ,(1+ (map-elt request :attempts)))))))
    (if-let* ((rule (map-elt request :rule)))
        (progn
          (furball--set-queue (cons (map-elt request :site) rule)
                              `((:paused-until . ,(+ (float-time) delay))))
          (furball--enqueue request t))
      (when-let* ((on-wait (map-elt request :on-wait)))
        (funcall on-wait (format "rate limited by Datadog; retrying in %ds" delay)))
      (run-at-time delay nil (lambda ()
                               (when (furball--wanted-p request)
                                 (furball--send request)))))))

(defun furball--logs-body (scope cursor &optional limit)
  "Build a logs request from fixed SCOPE, CURSOR, and optional LIMIT."
  `((filter . ((query . ,(map-elt scope :query))
               (indexes . ,(map-elt scope :indexes))
               (from . ,(number-to-string (map-elt scope :from)))
               (to . ,(number-to-string (map-elt scope :to)))
               (storage_tier . ,(or (map-elt scope :storage) "indexes"))))
    (sort . ,(or (map-elt scope :sort) "-timestamp"))
    (page . ,(append `((limit . ,(or limit 100)))
                     (when cursor `((cursor . ,cursor)))))))

(defun furball--fetch (view scope cursor callback &optional limit options)
  "Fetch VIEW using log SCOPE or monitor page CURSOR and deliver CALLBACK.
LIMIT defaults to 100; landing page previews use a smaller limit.
OPTIONS are passed to `furball--request'."
  (let ((site (or (map-elt view :site) furball-site)))
    (pcase (map-elt view :kind)
      ('logs (furball--request site "POST" "/api/v2/logs/events/search"
                               (furball--logs-body scope cursor limit) callback options))
      ('monitors
       (furball--request
        site "GET"
        (format "/api/v1/monitor/search?query=%s&page=%s&per_page=%s&sort=status,asc"
                (url-hexify-string (or (map-elt view :query) ""))
                (or cursor 0) (or limit 100))
        nil callback options))
      ('monitor
       (furball--request
        site "GET"
        (format "/api/v1/monitor/%s?group_states=all&with_downtimes=true&with_assets=true"
                (url-hexify-string (format "%s" (map-elt view :monitor-id))))
        nil callback options))
      (_ (user-error "Unknown Furball view kind: %s" (map-elt view :kind))))))

(provide 'furball-api)
;;; furball-api.el ends here
