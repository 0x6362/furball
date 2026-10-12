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

(defun furball--pup-result (process)
  "Decode completed PROCESS output into the UI result contract."
  (cond
   ((process-get process 'furball-timeout)
    '((:error . "Pup request timed out")))
   ((not (and (eq (process-status process) 'exit)
              (= (process-exit-status process) 0)))
    `((:error . ,(format "Pup exited %s: %s"
                         (process-exit-status process)
                         (with-current-buffer (process-get process 'furball-stderr)
                           (string-trim (buffer-substring-no-properties
                                         (point-min) (min (point-max) 2001))))))))
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

(defun furball--request (site method path body callback)
  "Run Pup for PATH on SITE using METHOD and BODY; deliver CALLBACK.
Pup owns credentials.  JSON bodies go to stdin and arguments bypass a shell.
Return the asynchronous process, or nil when startup fails."
  (furball--site site)
  (let ((stdout (generate-new-buffer " *furball-pup-output*"))
        (stderr (generate-new-buffer " *furball-pup-errors*"))
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

(defun furball--fetch (view scope cursor callback &optional limit)
  "Fetch VIEW using log SCOPE or monitor page CURSOR and deliver CALLBACK.
LIMIT defaults to 100; landing page previews use a smaller limit."
  (let ((site (or (map-elt view :site) furball-site)))
    (pcase (map-elt view :kind)
      ('logs (furball--request site "POST" "/api/v2/logs/events/search"
                               (furball--logs-body scope cursor limit) callback))
      ('monitors
       (furball--request
        site "GET"
        (format "/api/v1/monitor/search?query=%s&page=%s&per_page=%s&sort=status,asc"
                (url-hexify-string (or (map-elt view :query) ""))
                (or cursor 0) (or limit 100))
        nil callback))
      ('monitor
       (furball--request
        site "GET"
        (format "/api/v1/monitor/%s?group_states=all&with_downtimes=true&with_assets=true"
                (url-hexify-string (format "%s" (map-elt view :monitor-id))))
        nil callback))
      (_ (user-error "Unknown Furball view kind: %s" (map-elt view :kind))))))

(provide 'furball-api)
;;; furball-api.el ends here
