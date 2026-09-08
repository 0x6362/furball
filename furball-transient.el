;;; furball-transient.el --- Contextual Furball menus -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Transient owns action menus and query arguments.  Result buffers retain
;; fetched data and the editable query buffer retains unsent query drafts.

;;; Code:

(require 'transient)
(require 'furball-query)

(defvar furball--state)
(defvar furball--completion-values)
(defvar furball-landing-page)
(defvar furball-site)
(declare-function furball "furball")
(declare-function furball--open-view "furball" (view &optional beside))
(declare-function furball-open-url "furball" (address))
(declare-function furball-time-range "furball" (duration))
(declare-function furball-status-filter "furball" (status))
(declare-function furball-completion-at-point "furball" ())

(defun furball--selected-row-p ()
  "Return non-nil when point is on an actionable result row."
  (get-text-property (point) 'furball-action))

(defun furball--more-results-p ()
  "Return non-nil when another results page can be fetched."
  (and (map-elt furball--state :next)
       (not (map-elt furball--state :loading))
       (equal (map-elt furball--state :view)
              (map-elt furball--state :fetched-view))))

(defun furball--read-search (prompt initial history)
  "Read a search using PROMPT, INITIAL value, and HISTORY with completion."
  (let ((candidates furball--completion-values))
    (minibuffer-with-setup-hook
        (lambda ()
          (setq-local furball--completion-values candidates)
          (add-hook 'completion-at-point-functions #'furball-completion-at-point nil t))
      (read-string prompt initial history))))

(defun furball--read-window (prompt initial history)
  "Read a duration using PROMPT, INITIAL value, and HISTORY."
  (let ((value (completing-read prompt '("15m" "1h" "6h" "24h" "2d")
                                nil nil initial history)))
    (furball--duration value)
    value))

(defun furball--read-site (prompt initial history)
  "Read a Datadog site using PROMPT, INITIAL value, and HISTORY."
  (completing-read prompt furball--sites nil t initial history))

(defun furball--saved-view-choices ()
  "Return uniquely labelled saved views, preserving configuration order."
  (seq-map-indexed
   (lambda (view index) (cons (format "%d: %s" (1+ index) (map-elt view :name)) view))
   furball-landing-page))

(defun furball--read-saved-view (prompt initial history)
  "Select a saved view using PROMPT, INITIAL value, and HISTORY."
  (completing-read prompt (furball--saved-view-choices) nil t initial history))

(defun furball--required-argument (key prefix)
  "Read required argument KEY from transient PREFIX."
  (or (transient-arg-value key (transient-args prefix))
      (user-error "Set %s before applying" key)))

(defun furball-transient-search ()
  "Open a log view using the search menu's arguments."
  (interactive)
  (let ((query (furball--required-argument "--query=" 'furball-search-menu))
        (window (furball--required-argument "--window=" 'furball-search-menu))
        (site (furball--required-argument "--site=" 'furball-search-menu)))
    (when (map-elt (furball--parse-query query) :operator)
      (setq query (replace-regexp-in-string "\\.last(\"[^\"]*\")"
                                            (format ".last(\"%s\")" window) query t t)))
    (furball--duration window)
    (furball--open-view `((:kind . logs) (:name . "Logs") (:query . ,query)
                         (:time-range . ,window) (:site . ,(furball--site site))))))

(defun furball-transient-open-saved ()
  "Open the saved view selected in the saved-views menu."
  (interactive)
  (let ((view (cdr (assoc (furball--required-argument "--view=" 'furball-saved-views-menu)
                          (furball--saved-view-choices)))))
    (unless view (user-error "The selected saved view no longer exists"))
    (furball--open-view view)))

(defun furball-transient-open-url ()
  "Open the URL entered in the import menu."
  (interactive)
  (furball-open-url (furball--required-argument "--url=" 'furball-url-menu)))

(defun furball-transient-set-window ()
  "Apply the time menu's duration to the current log view."
  (interactive)
  (furball-time-range (furball--required-argument "--window=" 'furball-time-menu)))

(defun furball-transient-set-status ()
  "Apply the status menu's filter to the current monitor view."
  (interactive)
  (furball-status-filter (furball--required-argument "--status=" 'furball-status-menu)))

(transient-define-prefix furball-search-menu ()
  "Compose a log search before fetching results."
  ["Search arguments"
   ("s" "Search or count expression" "--query=" :reader furball--read-search :always-read t)
   ("t" "Relative window" "--window=" :reader furball--read-window :always-read t)
   ("d" "Datadog site" "--site=" :reader furball--read-site :always-read t)]
  ["Actions"
   ("RET" "Search logs" furball-transient-search)
   ("q" "Cancel" transient-quit-one)]
  (interactive)
  (let ((view (map-elt furball--state :view)))
    (transient-setup
     'furball-search-menu nil nil
     :value (list (concat "--query=" (if (eq (map-elt view :kind) 'logs)
                                           (map-elt view :query) "*"))
                  (concat "--window=" (or (and (eq (map-elt view :kind) 'logs)
                                              (map-elt (furball--parse-query
                                                        (map-elt view :query)) :time-range))
                                         (map-elt view :time-range) "1h"))
                  (concat "--site=" (or (map-elt view :site) furball-site))))))

(transient-define-prefix furball-saved-views-menu ()
  "Choose a configured monitor or log view."
  ["Saved views"
   ("v" "View" "--view=" :reader furball--read-saved-view :always-read t)]
  ["Actions"
   ("RET" "Open view" furball-transient-open-saved)
   ("q" "Cancel" transient-quit-one)]
  (interactive)
  (unless furball-landing-page (user-error "Configure furball-landing-page first"))
  (transient-setup 'furball-saved-views-menu nil nil
                   :value (list (concat "--view=" (caar (furball--saved-view-choices))))))

(transient-define-prefix furball-url-menu ()
  "Import a Datadog logs URL with its original time window."
  ["Import"
   ("u" "Datadog logs URL" "--url=" :always-read t)]
  ["Actions"
   ("RET" "Open URL" furball-transient-open-url)
   ("q" "Cancel" transient-quit-one)])

(transient-define-prefix furball-time-menu ()
  "Choose a relative window for the current logs."
  ["Window (applying switches historical views to the latest window)"
   ("t" "Duration" "--window=" :reader furball--read-window :always-read t)]
  ["Actions"
   ("RET" "Apply window" furball-transient-set-window)
   ("q" "Cancel" transient-quit-one)]
  (interactive)
  (unless (eq (map-nested-elt furball--state '(:view :kind)) 'logs)
    (user-error "Open a log results view first"))
  (let* ((view (map-elt furball--state :view))
         (parsed (furball--parse-query (map-elt view :query))))
    (transient-setup 'furball-time-menu nil nil
                     :value (list (concat "--window=" (or (map-elt parsed :time-range)
                                                          (map-elt view :time-range) "1h"))))))

(transient-define-prefix furball-status-menu ()
  "Choose a status within the monitor view's saved scope."
  ["Monitor status"
   ("s" "Status (All restores saved scope)" "--status="
    :choices ("All" "Alert" "Warn" "No Data" "OK") :always-read t)]
  ["Actions"
   ("RET" "Apply status" furball-transient-set-status)
   ("q" "Cancel" transient-quit-one)]
  (interactive)
  (unless (eq (map-nested-elt furball--state '(:view :kind)) 'monitors)
    (user-error "Open a monitor list first"))
  (transient-setup 'furball-status-menu nil nil
                   :value (list (concat "--status="
                                        (or (map-nested-elt furball--state '(:view :status-filter)) "All")))))

(defun furball--log-view-functions ()
  "Return functions configured for the selected row or current view."
  (map-elt (or (get-text-property (point) 'furball-view)
               (and (eq (get-text-property (point) 'furball-action) 'monitor)
                    (get-text-property (point) 'furball-value))
               (map-elt furball--state :view)) :log-view-functions))

(defun furball--log-function-suffixes ()
  "Build ordered action specifications capturing the current Furball buffer."
  (let ((functions (furball--log-view-functions))
        (buffer (current-buffer))
        (keys "123456789abcdefghijklmnopqrstuvwxyz"))
    (when (> (length functions) (length keys))
      (user-error "A log view supports at most 35 functions"))
    (seq-map-indexed
     (lambda (function index)
       (unless (and (symbolp function) (fboundp function))
         (user-error "Log view function is not defined: %S" function))
       (list (char-to-string (aref keys index)) (symbol-name function)
             (lambda ()
               (interactive)
               (unless (buffer-live-p buffer)
                 (user-error "The Furball buffer has been closed"))
               (funcall function buffer))))
     functions)))

(defun furball--log-function-children (_children)
  "Build Transient children from the current view instead of _CHILDREN."
  (transient-parse-suffixes 'furball-log-functions-menu
                          (furball--log-function-suffixes)))

(transient-define-prefix furball-log-functions-menu ()
  "Invoke a configured function with the current Furball buffer."
  ["Log view functions"
   :class transient-column
   :setup-children furball--log-function-children]
  ["Menu"
   ("C-g" "Cancel" transient-quit-one)])

(transient-define-prefix furball-dashboard-menu ()
  "Browse Furball's configured views."
  [["Browse"
    ("c" "Traceback in compilation mode" furball-open-traceback)
    ("RET" "Open selected row" furball-open-at-point :inapt-if-not furball--selected-row-p)
    ("v" "Saved views" furball-saved-views-menu)
    ("x" "Log view functions" furball-log-functions-menu :if furball--log-view-functions)
    ("L" "Log search" furball-search-menu)
    ("u" "Import logs URL" furball-url-menu)]
   ["Dashboard"
    ("g" "Refresh previews" furball-refresh)
    ("q" "Close menu" transient-quit-one)
    ("Q" "Quit view" quit-window)]])

(transient-define-prefix furball-monitors-menu ()
  "Browse and filter monitor results."
  [["Monitors"
    ("x" "Log view functions" furball-log-functions-menu :if furball--log-view-functions)
    ("RET" "Open monitor" furball-open-at-point :inapt-if-not furball--selected-row-p)
    ("e" "Edit query" furball-edit-query)
    ("s" "Status filter" furball-status-menu)
    ("b" "Open in Datadog" furball-browse)]
   ["Results"
    ("g" "Refresh" furball-refresh)
    ("m" "Next page" furball-more :inapt-if-not furball--more-results-p)
    ("v" "Saved views" furball-saved-views-menu)
    ("^" "Dashboard" furball)
    ("q" "Close menu" transient-quit-one)]])

(transient-define-prefix furball-logs-menu ()
  "Browse logs and adjust the search window."
  [["Logs"
    ("c" "Traceback in compilation mode" furball-open-traceback)
    ("TAB" "Toggle inline preview" furball-toggle-log-preview)
    ("x" "Log view functions" furball-log-functions-menu :if furball--log-view-functions)
    ("RET" "Full log and traceback" furball-open-at-point :inapt-if-not furball--selected-row-p)
    ("e" "Edit query" furball-edit-query)
    ("t" "Time window" furball-time-menu)
    ("b" "Open in Datadog" furball-browse)]
   ["Results"
    ("g" "Refresh" furball-refresh)
    ("m" "Next page" furball-more :inapt-if-not furball--more-results-p)
    ("L" "New search" furball-search-menu)
    ("u" "Import URL" furball-url-menu)
    ("^" "Dashboard" furball)
    ("q" "Close menu" transient-quit-one)]])

(transient-define-prefix furball-monitor-menu ()
  "Inspect a monitor and its triggering groups."
  ["Monitor"
   ("RET" "Logs for selected group" furball-open-at-point :inapt-if-not furball--selected-row-p)
   ("g" "Refresh current status" furball-refresh)
   ("b" "Open in Datadog" furball-browse)
   ("L" "New log search" furball-search-menu)
   ("^" "Dashboard" furball)
   ("q" "Close menu" transient-quit-one)])

(transient-define-prefix furball-query-menu ()
  "Run or leave the editable query buffer."
  ["Query editor"
   ("r" "Run query" furball-query-run)
   ("c" "Complete at point" completion-at-point)
   ("Q" "Return to results" quit-window)
   ("q" "Close menu" transient-quit-one)])

(transient-define-prefix furball-log-menu ()
  "Navigate the full log and traceback."
  ["Log details"
   ("c" "Traceback in compilation mode" furball-open-traceback)
   ("x" "Log view functions" furball-log-functions-menu :if furball--log-view-functions)
   ("g" "Beginning" beginning-of-buffer)
   ("G" "End" end-of-buffer)
   ("Q" "Return to results" quit-window)
   ("q" "Close menu" transient-quit-one)])

;;;###autoload
(defun furball-menu ()
  "Open the Transient menu for the current Furball view."
  (interactive)
  (cond
   ((derived-mode-p 'furball-query-mode) (call-interactively #'furball-query-menu))
   ((derived-mode-p 'furball-log-mode) (call-interactively #'furball-log-menu))
   ((derived-mode-p 'furball-mode)
    (pcase (map-nested-elt furball--state '(:view :kind))
      ('dashboard (call-interactively #'furball-dashboard-menu))
      ('monitors (call-interactively #'furball-monitors-menu))
      ('monitor (call-interactively #'furball-monitor-menu))
      ('logs (call-interactively #'furball-logs-menu))))
   (t (furball) (call-interactively #'furball-dashboard-menu))))

(provide 'furball-transient)
;;; furball-transient.el ends here
