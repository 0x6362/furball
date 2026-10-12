;;; furball.el --- A dashboard for Datadog monitors and logs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; URL: https://github.com/0x6362/furball
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.7.0"))
;; Keywords: tools

;;; Commentary:
;; M-x furball opens saved views from `furball-landing-page'.  Results are
;; read-only; e opens a query editor, and C-c C-c runs the edited query.
;; The landing page draws inspiration from agent-shell-dashboard.

;;; Code:

(require 'browse-url)
(require 'compile)
(require 'org-faces)
(require 'furball-api)

(defcustom furball-landing-page
  '(((:name . "Needs attention") (:kind . monitors)
     (:query . "status:(Alert OR Warn)")))
  "Ordered saved views displayed by `furball'.
Each alist has :name, :kind (monitors or logs), and :query.
Optional keys are :site and :time-range (for example, \"1h\").
:log-view-functions is a list of function symbols accepting one Furball buffer.
:directory-abbrev-alist maps traceback path regexps to local directories.
:project-directory-id-fn accepts a Furball buffer and returns its
base directory.
Example: (((:name . \"Sidekick\") (:kind . monitors)
           (:query . \"tag:\\\"component:sidekick\\\"\")))."
  :type '(repeat (alist :key-type (choice (const :name) (const :kind)
                                          (const :query) (const :site)
                                          (const :time-range) (const :log-view-functions)
                                          (const :directory-abbrev-alist)
                                          (const :project-directory-id-fn))
                        :value-type (choice string (const monitors) (const logs)
                                            (repeat function) function
                                            (alist :key-type regexp :value-type directory))))
  :group 'furball)

(defface furball-heading
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for dashboard sections."
  :group 'furball)
(defface furball-alert '((t :inherit error :weight bold))
  "Face for alert states."
  :group 'furball)
(defface furball-warn '((t :inherit warning :weight bold))
  "Face for warning states."
  :group 'furball)
(defface furball-ok '((t :inherit success))
  "Face for healthy states."
  :group 'furball)

(defface furball-log-error
  '((t :inherit error))
  "Face for error-level log summaries."
  :group 'furball)
(defface furball-log-warning
  '((t :inherit warning))
  "Face for warning-level log summaries."
  :group 'furball)
(defface furball-log-header '((t :inherit furball-heading))
  "Face for log timestamps, service names, and hosts."
  :group 'furball)
(defface furball-log-highlight
  '((t :inherit hl-line))
  "Face for the selected Furball row."
  :group 'furball)

(defvar-local furball--state nil
  "Current view and fetched snapshots as an alist.")
(defvar-local furball--query-target nil
  "Results buffer targeted by a query editor.")
(defvar-local furball--completion-values nil
  "Completion candidates observed in this view's results.")

(defconst furball--result-bindings
  '(("g" . furball-refresh) ("e" . furball-edit-query)
    ("RET" . furball-open-at-point) ("o" . furball-open-at-point)
    ("n" . furball-next-item) ("p" . furball-previous-item)
    ("TAB" . furball-toggle-log-preview) ("<tab>" . furball-toggle-log-preview) ("<backtab>" . furball-previous-item)
    ("m" . furball-more) ("l" . furball-search-menu)
    ("L" . furball-search-menu) ("v" . furball-saved-views-menu)
    ("x" . furball-log-functions-menu) ("c" . furball-open-traceback)
    ("Q" . quit-window)
    ("u" . furball-url-menu) ("b" . furball-browse)
    ("t" . furball-time-menu) ("s" . furball-status-menu)
    ("^" . furball) ("q" . quit-window) ("?" . furball-menu))
  "Result-view commands shared by Emacs and Evil keymaps.")

(defvar furball-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (binding furball--result-bindings)
      (define-key map (kbd (car binding)) (cdr binding)))
    map)
  "Keymap for read-only Furball views.")

(define-derived-mode furball-mode special-mode "Furball"
  "Read-only Datadog results with keyboard navigation."
  (setq-local truncate-lines t)
  (setq-local cursor-type 'hbar)
  (setq-local hl-line-face 'furball-log-highlight)
  (hl-line-mode 1))

(defvar furball-log-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "?") #'furball-menu)
    map)
  "Keymap for full log records.")

(define-derived-mode furball-log-mode special-mode "Furball Log"
  "Read a complete log message, traceback, and structured record."
  (setq-local truncate-lines nil)
  (setq-local header-line-format " ? Actions · q Return to results"))

(defconst furball--query-bindings
  '(("C-c C-c" . furball-query-run) ("C-c C-k" . quit-window)
    ("C-c ?" . furball-menu))
  "Query-editor commands shared by Emacs and Evil keymaps.")

(defvar furball-query-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding furball--query-bindings)
      (define-key map (kbd (car binding)) (cdr binding)))
    map)
  "Keymap for editable Datadog queries.")

(define-derived-mode furball-query-mode text-mode "Furball Query"
  "Edit a Datadog query; use \\<furball-query-mode-map>\\[furball-query-run] to run it.
Completion at point uses syntax and values observed in the source view."
  (setq-local header-line-format " Edit query   C-c ? Actions   C-c C-c run   C-c C-k return")
  (add-hook 'completion-at-point-functions #'furball-completion-at-point nil t))

(defun furball--set-state (changes)
  "Replace fields in buffer state with CHANGES."
  (setq furball--state (furball--with furball--state changes)))

(defun furball--view (view)
  "Validate and snapshot saved VIEW, resolving its Datadog site."
  (unless (memq (map-elt view :kind) '(logs monitors monitor dashboard))
    (user-error "View needs :kind logs or monitors"))
  (when (memq (map-elt view :kind) '(logs monitors))
    (unless (stringp (map-elt view :query))
      (user-error "View needs a string :query")))
  (furball--with view `((:site . ,(furball--site
                                   (or (map-elt view :site) furball-site))))))

(defun furball--open-view (view &optional beside)
  "Open VIEW and fetch its first page; display BESIDE when non-nil."
  (let ((buffer (generate-new-buffer
                 (format "*furball: %s*" (or (map-elt view :name) "Results")))))
    (with-current-buffer buffer
      (furball-mode)
      (setq furball--state `((:view . ,(furball--view view))))
      (furball-refresh))
    (if beside
        (pop-to-buffer buffer '((display-buffer-in-direction)
                                (direction . right) (window-width . 0.55)))
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun furball ()
  "Open the landing page configured by `furball-landing-page'."
  (interactive)
  (pop-to-buffer (get-buffer-create "*furball*"))
  (unless (derived-mode-p 'furball-mode)
    (furball-mode))
  (furball--set-state '((:view . ((:kind . dashboard) (:name . "Furball")))))
  (furball-refresh))

;;;###autoload
(defun furball-logs (&optional query)
  "Browse logs for QUERY, or prompt for a search or count expression."
  (interactive)
  (furball--open-view `((:name . "Logs") (:kind . logs)
                        (:query . ,(or query (read-string "Log query: ")))
                        (:time-range . "1h"))))

;;;###autoload
(defun furball-open-url (address)
  "Browse a Datadog logs ADDRESS, preserving its historical window."
  (interactive "sDatadog logs URL: ")
  (let ((view (furball--url-view address)))
    (when (map-elt view :monitor-id)
      (furball--open-monitor (map-elt view :monitor-id) (map-elt view :site)))
    (furball--open-view view (map-elt view :monitor-id))))

(defun furball--open-monitor (id site &optional functions context)
  "Open current monitor ID on SITE, carrying log view FUNCTIONS and path CONTEXT."
  (furball--open-view `((:kind . monitor) (:monitor-id . ,id)
                        (:name . ,(format "Monitor %s" id)) (:site . ,site)
                        (:log-view-functions . ,functions)
                        (:directory-abbrev-alist . ,(map-elt context :directory-abbrev-alist))
                        (:project-directory-id-fn . ,(map-elt context :project-directory-id-fn)))))

(defun furball-refresh ()
  "Refresh the current view, retaining old results until a request succeeds."
  (interactive)
  (if (eq (map-nested-elt furball--state '(:view :kind)) 'dashboard)
      (furball--refresh-dashboard)
    (furball--load-page nil)))

(defun furball--load-page (more)
  "Fetch the next page when MORE is non-nil, otherwise start a new snapshot."
  (let* ((view (map-elt furball--state :view))
         (scope (if more (map-elt furball--state :scope)
                  (and (eq (map-elt view :kind) 'logs) (furball--log-scope view))))
         (cursor (and more (map-elt furball--state :next)))
         (token (gensym "furball-request"))
         (buffer (current-buffer)))
    (furball--set-state `((:token . ,token) (:loading . t) (:error . nil)))
    (furball--render)
    (furball--fetch
     view scope cursor
     (lambda (result)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (eq token (map-elt furball--state :token))
             (furball--accept result view scope more)
             (furball--render))))))))

(defun furball--accept (result view scope more)
  "Accept RESULT for VIEW and SCOPE, appending rows when MORE is non-nil."
  (furball--set-state `((:loading . nil) (:error . ,(map-elt result :error))))
  (unless (map-elt result :error)
    (let* ((data (map-elt result :data))
           (kind (map-elt view :kind))
           (rows (pcase kind ('logs (map-elt data 'data))
                        ('monitors (map-elt data 'monitors))
                        (_ data)))
           (next (pcase kind
                   ('logs (map-nested-elt data '(meta page after)))
                   ('monitors
                    (let ((page (map-nested-elt data '(metadata page)))
                          (count (map-nested-elt data '(metadata page_count))))
                      (when (and page count (< (1+ page) count)) (1+ page)))))))
      (furball--set-state
       `((:rows . ,(if more (append (map-elt furball--state :rows) rows) rows))
         (:scope . ,scope) (:next . ,next) (:fetched-view . ,view)
         (:updated . ,(map-elt result :fetched-at))
         (:partial . ,(or (map-nested-elt data '(meta warnings))
                          (equal (map-nested-elt data '(meta status)) "timeout")))
         (:total . ,(map-nested-elt data '(metadata total_count)))))
      (furball--learn-completions kind data))))

(defun furball--refresh-dashboard ()
  "Refresh compact previews of all configured landing views."
  (let ((views (mapcar #'furball--view furball-landing-page))
        (buffer (current-buffer))
        (token (gensym "furball-dashboard")))
    (furball--set-state `((:token . ,token) (:sections . nil)))
    (furball--set-state
     `((:sections . ,(mapcar (lambda (view) `((:view . ,view) (:loading . t))) views))))
    (furball--render)
    (seq-do-indexed
     (lambda (view index)
       (let ((scope (and (eq (map-elt view :kind) 'logs) (furball--log-scope view))))
         (furball--fetch
          view scope nil
          (lambda (result)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (when (eq token (map-elt furball--state :token))
                  (furball--set-state
                   `((:sections . ,(seq-map-indexed
                                    (lambda (section position)
                                      (if (= position index)
                                          (append `((:view . ,view) (:scope . ,scope)) result)
                                        section))
                                    (map-elt furball--state :sections)))))
                  (furball--render)))))
          5)))
     views)))

(defun furball-more ()
  "Fetch the next results page without changing the original time window."
  (interactive)
  (when (map-elt furball--state :loading)
    (user-error "A request is already in progress"))
  (unless (equal (map-elt furball--state :view)
                 (map-elt furball--state :fetched-view))
    (user-error "Refresh this query successfully before loading more"))
  (unless (map-elt furball--state :next)
    (user-error "No more pages"))
  (furball--load-page t))

(defun furball--status (status)
  "Return a display badge for STATUS."
  (let ((text (upcase (or status "Unknown"))))
    (propertize (format "%-8s" text) 'face
                (cond ((equal text "ALERT") 'furball-alert)
                      ((member text '("WARN" "WARNING" "NO DATA")) 'furball-warn)
                      ((equal text "OK") 'furball-ok)
                      (t 'shadow)))))

(defun furball--heading (text)
  "Insert section heading TEXT."
  (insert (propertize (concat "\n" text "\n") 'face 'furball-heading)))

(defun furball--row (text key action value)
  "Insert TEXT as a row identified by KEY, with ACTION and VALUE."
  (let ((start (point)))
    (insert text "\n")
    (add-text-properties start (point)
                         (list 'furball-key key 'furball-action action
                               'furball-value value 'mouse-face 'highlight))))

(defun furball--time (milliseconds)
  "Format MILLISECONDS as a UTC timestamp."
  (format-time-string "%Y-%m-%d %H:%M:%S UTC" (/ milliseconds 1000.0) t))

(defun furball--render ()
  "Render the current snapshot, preserving selection by stable row identity."
  (let ((inhibit-read-only t)
        (key (get-text-property (point) 'furball-key))
        (position (point))
        (view (map-elt furball--state :view)))
    (erase-buffer)
    (if (eq (map-elt view :kind) 'dashboard)
        (furball--render-dashboard)
      (insert (format "\n%s  ·  %s\n" (map-elt view :name) (map-elt view :site)))
      (when (map-elt view :query)
        (insert (format "Query: %s\n" (map-elt view :query))))
      (when (map-elt furball--state :loading)
        (insert (propertize "Refreshing… previous results retained below\n" 'face 'shadow)))
      (when (map-elt furball--state :error)
        (insert (propertize (format "Fetch failed: %s\n" (map-elt furball--state :error))
                            'face 'error)))
      (when-let* ((updated (map-elt furball--state :updated)))
        (insert (format "Fetched: %s\n" (furball--time (* updated 1000)))))
      (when (and (map-elt furball--state :fetched-view)
                 (not (equal view (map-elt furball--state :fetched-view))))
        (insert (propertize "Results below belong to the previous query.\n" 'face 'warning)))
      (when (map-elt furball--state :partial)
        (insert (propertize "Partial results: Datadog reported warnings or a timeout.\n" 'face 'warning)))
      (pcase (map-elt view :kind)
        ('monitors
         (furball--heading
          (format "Monitors · %s loaded%s"
                  (length (map-elt furball--state :rows))
                  (if-let* ((total (map-elt furball--state :total)))
                      (format " of %s" total) "")))
         (furball--render-monitors (map-elt furball--state :rows) view))
        ('logs (furball--render-logs))
        ('monitor (furball--render-monitor)))
      (when (map-elt furball--state :next)
        (insert "\nMore results available — m loads the next page\n")))
    (insert (propertize "\n? Actions · RET Open · TAB Preview · n/p Navigate · q Quit\n" 'face 'shadow))
    (goto-char (min position (point-max)))
    (when key
      (let ((at (point-min)) (found nil))
        (while (and (< at (point-max)) (not found))
          (if (equal key (get-text-property at 'furball-key))
              (setq found at)
            (setq at (next-single-property-change at 'furball-key nil (point-max)))))
        (when found (goto-char found))))
    (set-buffer-modified-p nil)))

(defun furball--render-dashboard ()
  "Insert saved view previews, each linked to its full results."
  (if (null furball-landing-page)
      (insert "\nCustomize furball-landing-page to add saved views.\n")
    (dolist (section (map-elt furball--state :sections))
      (let ((view (map-elt section :view)) (data (map-elt section :data)))
        (furball--heading (map-elt view :name))
        (furball--row (format "  Open %s  [%s]" (map-elt view :name) (map-elt view :kind))
                      (list 'view view) 'view view)
        (insert (propertize (format "  %s\n" (map-elt view :query)) 'face 'shadow))
        (cond
         ((map-elt section :loading) (insert "  Fetching preview…\n"))
         ((map-elt section :error)
          (insert (propertize (format "  %s\n" (map-elt section :error)) 'face 'error)))
         ((eq (map-elt view :kind) 'monitors)
          (furball--render-monitors (map-elt data 'monitors) view))
         (t (dolist (log (map-elt data 'data)) (furball--log-row log view))
            (unless (map-elt data 'data) (insert "  No matching logs in this window.\n"))))
        (when (map-elt section :fetched-at)
          (insert (propertize
                   (format "  Preview fetched %s\n"
                           (furball--time (* 1000 (map-elt section :fetched-at))))
                   'face 'shadow)))))))

(defun furball--render-monitors (rows view)
  "Insert monitor ROWS belonging to VIEW."
  (unless rows (insert "\n  No monitor rows loaded.\n"))
  (dolist (monitor rows)
    (furball--row
     (format "  %s  %s  #%s" (furball--status (map-elt monitor 'status))
             (map-elt monitor 'name) (map-elt monitor 'id))
     (list 'monitor (map-elt view :site) (map-elt monitor 'id)) 'monitor
     `((:monitor-id . ,(map-elt monitor 'id)) (:site . ,(map-elt view :site))
       (:log-view-functions . ,(map-elt view :log-view-functions))
       (:directory-abbrev-alist . ,(map-elt view :directory-abbrev-alist))
       (:project-directory-id-fn . ,(map-elt view :project-directory-id-fn))))))

(defun furball-toggle-log-preview ()
  "Expand or collapse the log at point without leaving the results buffer."
  (interactive)
  (if (not (eq (get-text-property (point) 'furball-action) 'log))
      (furball-next-item)
    (let* ((key (get-text-property (point) 'furball-key))
           (expanded (map-elt furball--state :expanded-logs)))
      (furball--set-state
       (list (cons :expanded-logs
                   (if (member key expanded)
                       (seq-remove (lambda (item) (equal item key)) expanded)
                     (cons key expanded)))))
      (furball--render))))

(defun furball--configure-traceback-parser ()
  "Add Python exception-group frames to this buffer's compilation formats."
  (let ((rule '("^[ \t]*[|+][ \t|+]*File \"\\([^\"\n]+\\)\", line \\([0-9]+\\)" 1 2)))
    (setq-local compilation-error-regexp-alist
                (cons rule (remove rule compilation-error-regexp-alist)))))

(defun furball--highlight-traceback (text)
  "Return TEXT with compilation faces, without compilation navigation properties."
  (with-temp-buffer
    (insert text)
    (delay-mode-hooks (compilation-mode))
    (furball--configure-traceback-parser)
    (font-lock-ensure)
    (compilation--ensure-parse (point-max))
    (let ((result (buffer-substring-no-properties (point-min) (point-max)))
          (at (point-min)))
      (while (< at (point-max))
        (let ((end (next-property-change at nil (point-max)))
              (face (or (get-text-property at 'face)
                        (get-text-property at 'font-lock-face))))
          (when face (put-text-property (1- at) (1- end) 'face face result))
          (setq at end)))
      result)))

(defun furball--log-level-face (status)
  "Return the summary face for log STATUS."
  (pcase (downcase (or status ""))
    ((or "error" "critical" "alert" "emergency" "fatal") 'furball-log-error)
    ((or "warn" "warning") 'furball-log-warning)
    (_ 'default)))

(defun furball--log-row (log &optional view)
  "Insert LOG with a foldable preview and optional saved VIEW context."
  (let* ((start (point))
         (attrs (map-elt log 'attributes))
         (key (list 'log (or view (map-elt furball--state :view)) (map-elt log 'id)))
         (expanded (member key (map-elt furball--state :expanded-logs))))
    (furball--row
     (format "%s %s  %-7s  %s  %s\n    %s"
             (if expanded "▾" "▸")
             (propertize (or (map-elt attrs 'timestamp) "") 'face 'furball-log-header)
             (propertize (or (map-elt attrs 'status) "") 'face
                         (furball--log-level-face (map-elt attrs 'status)))
             (propertize (or (map-elt attrs 'service) "") 'face 'furball-log-header)
             (propertize (or (map-elt attrs 'host) "") 'face 'furball-log-header)
             (propertize (car (split-string (or (map-elt attrs 'message) "") "\n"))
                         'face (furball--log-level-face (map-elt attrs 'status))))
     key 'log log)
    (when expanded
      (insert (propertize "    Message\n" 'face 'furball-heading))
      (insert (furball--highlight-traceback (or (map-elt attrs 'message) "")) "\n")
      (dolist (trace (furball--log-tracebacks log))
        (insert (propertize (format "    Traceback · %s\n" (car trace))
                            'face 'furball-heading))
        (insert (furball--highlight-traceback (cdr trace)) "\n")))
    (add-text-properties start (point)
                         (list 'furball-key key 'furball-action 'log 'furball-value log))
    (when view (put-text-property start (point) 'furball-view view))))

(defun furball--render-logs ()
  "Insert the log snapshot with its exact scope and provenance."
  (when-let* ((scope (map-elt furball--state :scope)))
    (insert (format "Window: %s → %s\n" (furball--time (map-elt scope :from))
                    (furball--time (map-elt scope :to))))
    (insert (format "Search: %s\n" (map-elt scope :query)))
    (when (map-elt scope :operator)
      (insert (format "Condition: count by %s %s %s (not evaluated here)\n"
                      (or (map-elt scope :group-by) "all logs")
                      (map-elt scope :operator) (map-elt scope :threshold))))
    (when (map-elt scope :monitor-id)
      (insert (format "Monitor: %s  Event: %s\n" (map-elt scope :monitor-id)
                      (or (map-elt scope :event-id) "not supplied"))))
    (when (map-elt scope :provenance)
      (insert (format "%s\n" (map-elt scope :provenance)))))
  (furball--heading (format "Logs · %s loaded · RET for details and traceback"
                            (length (map-elt furball--state :rows))))
  (dolist (log (map-elt furball--state :rows)) (furball--log-row log))
  (unless (map-elt furball--state :rows)
    (insert "  No log rows loaded.\n")))

(defun furball--insert-notification (template)
  "Insert notification TEMPLATE in a read-only Markdown source-style block.
Preserve Datadog variables and conditional markup verbatim."
  (furball--heading "Notification template")
  (insert (propertize "#+begin_src markdown\n" 'face 'org-block-begin-line))
  (let ((start (point)))
    (insert (or template ""))
    (unless (bolp) (insert "\n"))
    (add-text-properties start (point)
                         '(face org-block font-lock-face org-block
                                read-only t rear-nonsticky t)))
  (insert (propertize "#+end_src\n" 'face 'org-block-end-line)))

(defun furball--render-monitor ()
  "Insert the current monitor configuration and per-group states."
  (when-let* ((monitor (map-elt furball--state :rows)))
    (furball--heading (or (map-elt monitor 'name) "Monitor"))
    (insert (format "Current: %s  Priority: %s\nType: %s\n\n%s\n"
                    (furball--status (map-elt monitor 'overall_state))
                    (or (map-elt monitor 'priority) "unset")
                    (map-elt monitor 'type) (map-elt monitor 'query)))
    (furball--insert-notification (map-elt monitor 'message))
    (insert (format "\nThresholds: %S\nDowntimes: %S\n"
                    (map-nested-elt monitor '(options thresholds))
                    (or (map-elt monitor 'matching_downtimes) "none")))
    (dolist (asset (map-elt monitor 'assets))
      (insert (format "Runbook: %s\n" (map-elt asset 'url))))
    (furball--heading "Groups · RET opens matching logs alongside this monitor")
    (if-let* ((groups (map-nested-elt monitor '(state groups))))
        (dolist (entry groups)
          (let ((group (format "%s" (car entry))) (state (cdr entry)))
            (furball--row
             (format "  %s  %s\n    Last trigger: %s   Recovery: %s"
                     (furball--status (map-elt state 'status)) group
                     (if-let* ((time (map-elt state 'last_triggered_ts)))
                         (furball--time (* time 1000)) "unknown")
                     (if-let* ((time (map-elt state 'last_resolved_ts)))
                         (furball--time (* time 1000)) "unknown"))
             (list 'group group) 'group `((:group . ,group) (:state . ,state)))))
      (furball--row "  Open matching logs" 'all-logs 'group nil))))

(defun furball-next-item ()
  "Move to the next selectable row."
  (interactive)
  (let ((key (get-text-property (point) 'furball-key))
        (at (point)))
    (while (and (< at (point-max))
                (or (null (get-text-property at 'furball-key))
                    (equal key (get-text-property at 'furball-key))))
      (setq at (next-single-property-change at 'furball-key nil (point-max))))
    (when (< at (point-max)) (goto-char at))))

(defun furball-previous-item ()
  "Move to the previous selectable row."
  (interactive)
  (let ((key (get-text-property (point) 'furball-key))
        (at (point))
        target)
    (when (and key (> at (point-min))
               (equal key (get-text-property (1- at) 'furball-key)))
      (setq at (previous-single-property-change at 'furball-key nil (point-min))))
    (while (and (> at (point-min)) (not target))
      (let ((previous-key (get-text-property (1- at) 'furball-key)))
        (setq at (previous-single-property-change at 'furball-key nil (point-min)))
        (when previous-key (setq target at))))
    (when target (goto-char target))))

(defun furball--log-tracebacks (log)
  "Return distinct traceback strings from LOG, paired with field names."
  (let ((attributes (map-nested-elt log '(attributes attributes)))
        traces)
    (dolist (entry `(("error.stack" . ,(map-nested-elt attributes '(error stack)))
                     ("error.stack" . ,(map-elt attributes 'error.stack))
                     ("exc_info" . ,(map-elt attributes 'exc_info))))
      (when (and (stringp (cdr entry))
                 (not (string-empty-p (string-trim (cdr entry))))
                 (not (seq-some (lambda (trace) (equal (cdr trace) (cdr entry))) traces)))
        (push entry traces)))
    (nreverse traces)))

(defun furball--insert-log-details (log)
  "Insert LOG with complete multiline tracebacks followed by its raw record."
  (let ((attributes (map-elt log 'attributes))
        (traces (furball--log-tracebacks log)))
    (insert (format "Log %s\n%s  %s  %s\n"
                    (map-elt log 'id) (or (map-elt attributes 'timestamp) "")
                    (or (map-elt attributes 'service) "")
                    (or (map-elt attributes 'host) "")))
    (furball--heading "Message")
    (insert (or (map-elt attributes 'message) "") "\n")
    (dolist (trace traces)
      (furball--heading (format "Traceback · %s" (car trace)))
      (insert (cdr trace) "\n"))
    (unless traces
      (insert "\nNo separate traceback field was returned; the full message is shown above.\n"))
    (furball--heading "Raw log record")
    (let ((json-encoding-pretty-print t)
          (json-null nil)
          (json-false :false))
      (insert (json-encode log)))
    (insert "\n")))

(defun furball-open-traceback ()
  "Open the current log traceback with compilation navigation in this window."
  (interactive)
  (let* ((source (current-buffer))
         (view (or (get-text-property (point) 'furball-view)
                   (map-elt furball--state :view)))
         (log (if (derived-mode-p 'furball-log-mode)
                  (map-elt furball--state :log)
                (and (eq (get-text-property (point) 'furball-action) 'log)
                     (get-text-property (point) 'furball-value))))
         (traces (and log (furball--log-tracebacks log)))
         (resolver (map-elt view :project-directory-id-fn))
         (directory (if resolver (funcall resolver source) default-directory))
         (abbreviations (map-elt view :directory-abbrev-alist)))
    (unless log (user-error "Select a log row or reopen its full-log buffer"))
    (unless (and (stringp directory) (file-name-absolute-p directory)
                 (file-directory-p directory))
      (user-error "Project directory must be an existing absolute directory"))
    (let ((buffer (generate-new-buffer "*furball: Traceback*")))
      (with-current-buffer buffer
        (insert (if traces (mapconcat #'cdr traces "\n\n")
                  (or (map-nested-elt log '(attributes message)) "")) "\n")
        (compilation-mode)
        (furball--configure-traceback-parser)
        (setq-local default-directory (file-name-as-directory directory))
        (setq-local directory-abbrev-alist (copy-tree abbreviations))
        (setq-local compilation-transform-file-match-alist
                    (mapcar (lambda (entry) (list (car entry) (cdr entry))) abbreviations))
        (goto-char (point-min)))
      (switch-to-buffer buffer))))

(defun furball-open-at-point ()
  "Open the saved view, monitor, group logs, or log at point."
  (interactive)
  (let ((value (get-text-property (point) 'furball-value)))
    (pcase (get-text-property (point) 'furball-action)
      ('view (furball--open-view value))
      ('monitor (furball--open-monitor (map-elt value :monitor-id) (map-elt value :site)
                                       (map-elt value :log-view-functions) value))
      ('group (furball--monitor-logs value))
      ('log
       (let ((buffer (generate-new-buffer "*furball: Log details*"))
             (view (or (get-text-property (point) 'furball-view)
                       (map-elt furball--state :view))))
         (with-current-buffer buffer
           (furball--insert-log-details value)
           (goto-char (point-min))
           (furball-log-mode)
           (setq furball--state `((:view . ,view) (:log . ,value))))
         (switch-to-buffer buffer)))
      (_ (user-error "Select a row with TAB first")))))

(defun furball--monitor-logs (selection)
  "Open logs for monitor group SELECTION alongside the current buffer."
  (let* ((monitor (map-elt furball--state :rows))
         (query (map-elt monitor 'query))
         (parsed (and (equal (map-elt monitor 'type) "log alert")
                      (furball--parse-query query)))
         (group (map-elt selection :group))
         (state (map-elt selection :state))
         (trigger (and (not (equal (map-elt state 'status) "Warn"))
                       (map-elt state 'last_triggered_ts)))
         (end (- (if (and trigger (> trigger 0)) (* trigger 1000)
                   (floor (* 1000 (float-time))))
                 (* 1000 (or (map-nested-elt monitor '(options evaluation_delay)) 0)))))
    (unless parsed
      (user-error "Automatic log drill-down supports count log monitors; use l for a related search"))
    (furball--open-view
     `((:kind . logs) (:name . ,(format "Logs: %s" (map-elt monitor 'name)))
       (:site . ,(map-nested-elt furball--state '(:view :site)))
       (:log-view-functions . ,(map-nested-elt furball--state '(:view :log-view-functions)))
       (:directory-abbrev-alist . ,(map-nested-elt furball--state '(:view :directory-abbrev-alist)))
       (:project-directory-id-fn . ,(map-nested-elt furball--state '(:view :project-directory-id-fn)))
       (:monitor-id . ,(map-elt monitor 'id)) (:query . ,query)
       (:group-filter . ,(and group (not (member group '("*" "")))
                              (furball--group-filter group (map-elt parsed :group-by))))
       (:from . ,(- end (* 1000 (furball--duration (map-elt parsed :time-range)))))
       (:to . ,end)
       (:provenance . ,(if (and trigger (> trigger 0))
                           "Window uses last recorded trigger and evaluation delay; search uses current monitor configuration."
                         "Latest window; exact transition time unavailable. Search uses current configuration.")))
     t)))

(defun furball-edit-query ()
  "Open an editable query buffer for the current results or selected view."
  (interactive)
  (let ((view (map-elt furball--state :view)))
    (if (eq (map-elt view :kind) 'dashboard)
        (let ((selected (get-text-property (point) 'furball-value)))
          (unless (eq (get-text-property (point) 'furball-action) 'view)
            (user-error "Select an Open saved-view row first"))
          (furball--open-view selected)
          (furball-edit-query))
      (unless (memq (map-elt view :kind) '(logs monitors))
        (user-error "Open a log results view to edit its search"))
      (let ((target (current-buffer))
            (candidates furball--completion-values)
            (buffer (get-buffer-create (format "*furball query: %s*" (buffer-name)))))
        (pop-to-buffer buffer)
        (unless (derived-mode-p 'furball-query-mode)
          (furball-query-mode))
        (unless (buffer-modified-p)
          (erase-buffer)
          (insert (map-elt view :query))
          (set-buffer-modified-p nil))
        (setq furball--query-target target
              furball--completion-values candidates)
        (goto-char (point-max))))))

(defun furball-query-run ()
  "Run this query in its results buffer, leaving results read-only."
  (interactive)
  (unless (buffer-live-p furball--query-target)
    (user-error "The results buffer was closed"))
  (let ((query (string-trim (buffer-substring-no-properties (point-min) (point-max))))
        (target furball--query-target))
    (with-current-buffer target
      (let* ((view (map-elt furball--state :view))
             (logs (eq (map-elt view :kind) 'logs))
             (parsed (and logs (furball--parse-query query)))
             (previous (and logs (furball--parse-query (map-elt view :query)))))
        (furball--set-state
         `((:view . ,(furball--with
                      view
                      (append `((:query . ,query) (:base-query . nil) (:status-filter . nil))
                              (when (and (map-elt parsed :time-range)
                                         (not (equal (map-elt previous :time-range)
                                                     (map-elt parsed :time-range))))
                                '((:from . nil)))))))))
      (furball-refresh))
    (set-buffer-modified-p nil)
    (pop-to-buffer target)))

(defun furball-time-range (duration)
  "Use a relative DURATION for this log view, clearing a historical window."
  (interactive "sWindow (e.g. 15m, 1h): ")
  (unless (eq (map-nested-elt furball--state '(:view :kind)) 'logs)
    (user-error "Time range applies to a log results view"))
  (furball--duration duration)
  (let* ((view (map-elt furball--state :view))
         (query (map-elt view :query)))
    (when (map-elt (furball--parse-query query) :operator)
      (setq query (replace-regexp-in-string "\\.last(\"[^\"]*\")"
                                            (format ".last(\"%s\")" duration) query t t)))
    (furball--set-state
     `((:view . ,(furball--with view `((:time-range . ,duration) (:query . ,query)
                                       (:from . nil) (:to . nil) (:event-id . nil)
                                       (:event-ts . nil)
                                       (:provenance . "Latest window selected explicitly.")))))))
  (furball-refresh))

(defun furball-status-filter (status)
  "Filter monitor results to STATUS without changing the saved view."
  (interactive (list (completing-read "Status: " '("Alert" "Warn" "No Data" "OK" "All") nil t)))
  (unless (eq (map-nested-elt furball--state '(:view :kind)) 'monitors)
    (user-error "Open a monitor list first"))
  (let* ((view (map-elt furball--state :view))
         (base (or (map-elt view :base-query) (map-elt view :query))))
    (furball--set-state
     `((:view . ,(furball--with view
                                `((:base-query . ,base) (:status-filter . ,status)
                                  (:query . ,(if (equal status "All") base
                                               (format "(%s) status:\"%s\"" base status)))))))))
  (furball-refresh))

(defun furball--value-completions (key value)
  "Return log query completions for field KEY with scalar VALUE."
  (let ((text (format "%s" value)))
    (append (list (concat key ":" (json-serialize text)))
            (when (string-match-p "\\`[[:alnum:]_.:/-]+\\'" text)
              (list (concat key ":" text))))))

(defun furball--attribute-completions (attributes &optional prefix)
  "Return completions for structured ATTRIBUTES under PREFIX."
  (seq-mapcat
   (lambda (entry)
     (let ((key (concat (or prefix "@") (format "%s" (car entry))))
           (value (cdr entry)))
       (if (and (consp value) (consp (car value)))
           (furball--attribute-completions value (concat key "."))
         (append (list (concat key ":"))
                 (when (or (stringp value) (numberp value))
                   (furball--value-completions key value))))))
   attributes))

(defun furball--learn-completions (kind data)
  "Learn completion values from fetched DATA of KIND."
  (setq furball--completion-values
        (delete-dups
         (append
          (pcase kind
            ('monitors
             (mapcar (lambda (facet) (concat "tag:" (json-serialize (map-elt facet 'name))))
                     (map-nested-elt data '(counts tag))))
            ('logs
             (seq-mapcat
              (lambda (log)
                (let ((attrs (map-elt log 'attributes)))
                  (append (map-elt attrs 'tags)
                          (furball--attribute-completions (map-elt attrs 'attributes))
                          (seq-mapcat
                           (lambda (key)
                             (when-let* ((value (map-elt attrs key)))
                               (furball--value-completions (symbol-name key) value)))
                           '(service host status)))))
              (map-elt data 'data))))
          furball--completion-values))))

(defun furball-completion-at-point ()
  "Complete Datadog fields and observed values at point."
  (let ((end (point))
        (start (save-excursion (skip-chars-backward "[:alnum:]_@.:/-") (point))))
    (when (and (> start (point-min)) (eq (char-before start) ?\"))
      (save-excursion
        (goto-char (1- start))
        (let ((quote-position (point)))
          (skip-chars-backward "[:alnum:]_@.:")
          (when (string-match-p "\\`[[:alnum:]_@.]+:\\'"
                                (buffer-substring-no-properties (point) quote-position))
            (setq start (point))
            (when (eq (char-after end) ?\") (setq end (1+ end)))))))
    (list start end
          (append '("service:" "env:" "host:" "status:" "@error.kind:"
                    "tag:" "type:" "name:" "AND" "OR" "NOT"
                    "logs(\"\")" ".index(\"*\")" ".rollup(\"count\")"
                    ".by(\"env,@error.kind\")" ".last(\"1h\")")
                  furball--completion-values)
          :exclusive 'no)))

(defun furball-browse ()
  "Open the current result scope in Datadog's web interface."
  (interactive)
  (let* ((view (map-elt furball--state :view))
         (site (map-elt view :site))
         (base (concat "https://" (if (member site '("datadoghq.com" "datadoghq.eu" "ddog-gov.com"))
                                      "app." "") site)))
    (pcase (map-elt view :kind)
      ('logs
       (let ((scope (or (map-elt furball--state :scope) (furball--log-scope view))))
         (browse-url
          (concat base "/logs?"
                  (mapconcat
                   (lambda (entry) (concat (car entry) "=" (url-hexify-string (format "%s" (cdr entry)))))
                   `(("query" . ,(map-elt scope :query)) ("from_ts" . ,(map-elt scope :from))
                     ("to_ts" . ,(map-elt scope :to)) ("live" . "false")
                     ("stream_sort" . ,(if (equal (map-elt scope :sort) "timestamp") "asc" "desc"))
                     ("link_monitor_id" . ,(or (map-elt scope :monitor-id) ""))
                     ("link_event_id" . ,(or (map-elt scope :event-id) ""))) "&")))))
      ('monitors (browse-url (concat base "/monitors/manage?q="
                                     (url-hexify-string (map-elt view :query)))))
      ('monitor (browse-url (format "%s/monitors/%s" base (map-elt view :monitor-id))))
      (_ (user-error "Open a saved view first")))))

(require 'furball-transient)

(with-eval-after-load 'evil
  (require 'furball-evil))

(provide 'furball)
;;; furball.el ends here
