;;; furball-query.el --- Datadog query data -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Cate B.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Pure transformations for saved views, log expressions, and Datadog URLs.

;;; Code:

(require 'json)
(require 'map)
(require 'seq)
(require 'subr-x)
(require 'url-parse)
(require 'url-util)
(require 'rx)

(defun furball--with (record changes)
  "Return RECORD with CHANGES, without modifying either alist.
For example, updating ((:name . \"Old\")) with ((:name . \"New\")) replaces name."
  (append changes (seq-remove (lambda (entry) (assq (car entry) changes)) record)))

(defconst furball--sites
  '("datadoghq.com" "us3.datadoghq.com" "us5.datadoghq.com"
    "datadoghq.eu" "ap1.datadoghq.com" "ap2.datadoghq.com"
    "uk1.datadoghq.com" "ddog-gov.com" "us2.ddog-gov.com")
  "Datadog site suffixes supported by the API client.")

(defun furball--site (site)
  "Validate and return Datadog SITE, for example \"us5.datadoghq.com\"."
  (unless (member site furball--sites)
    (user-error "Unknown Datadog site: %s" site))
  site)

(defun furball--duration (text)
  "Return seconds for TEXT such as \"1h\"; reject unsupported durations."
  (unless (string-match "\\`\\([1-9][0-9]*\\)\\([smhd]\\)\\'" text)
    (user-error "Use a positive duration such as 15m, 1h, or 2d"))
  (* (string-to-number (match-string 1 text))
     (map-elt '(("s" . 1) ("m" . 60) ("h" . 3600) ("d" . 86400))
              (match-string 2 text))))

(defconst furball--quoted-string
  (rx "\"" (* (or (not (in "\"" "\\")) (seq "\\" anything))) "\"")
  "A JSON-compatible quoted string in a log monitor expression.")

(defun furball--parse-query (input)
  "Parse log INPUT into an alist.
Plain \"service:web\" returns a search.  Count monitor expressions also
retain indexes, grouping, duration, and threshold; they are not evaluated."
  (if (not (string-match-p "\\`[ \t\n]*logs[ \t]*(" input))
      `((:query . ,input) (:indexes . ["*"]))
    (let ((pattern
           (concat "\\`logs(\\(" furball--quoted-string "\\))"
                   "\\(?:\\.index(\\(" furball--quoted-string "\\))\\)?"
                   "\\.rollup(\"count\")"
                   "\\(?:\\.by(\\(" furball--quoted-string "\\))\\)?"
                   "\\.last(\\(" furball--quoted-string "\\))"
                   "[ \t]*\\(>=\\|<=\\|>\\|<\\|==\\|!=\\)[ \t]*"
                   "\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\'"))
          (text (string-trim input)))
      (unless (string-match pattern text)
        (user-error "Supported expression: logs(\"…\").index(\"*\").rollup(\"count\").by(\"…\").last(\"1h\") > 1"))
      (let ((query (json-parse-string (match-string 1 text)))
            (index (when (match-string 2 text)
                     (json-parse-string (match-string 2 text))))
            (group (when (match-string 3 text)
                     (json-parse-string (match-string 3 text))))
            (duration (json-parse-string (match-string 4 text)))
            (operator (match-string 5 text))
            (threshold (string-to-number (match-string 6 text))))
        (furball--duration duration)
        `((:query . ,query)
          (:indexes . ,(vconcat (split-string (or index "*") "," t " ")))
          (:group-by . ,(and group (split-string group "," t " ")))
          (:time-range . ,duration) (:operator . ,operator)
          (:threshold . ,threshold))))))

(defun furball--log-scope (view &optional now)
  "Resolve log VIEW into a fixed request scope at NOW, in seconds.
For a relative 1h view, paging reuses the resulting absolute timestamps."
  (let* ((parsed (furball--parse-query (or (map-elt view :query) "*")))
         (duration (or (map-elt parsed :time-range)
                       (map-elt view :time-range) "1h"))
         (end (or (map-elt view :to) (floor (* 1000 (or now (float-time))))))
         (start (or (map-elt view :from)
                    (- end (* 1000 (furball--duration duration))))))
    (unless (< start end)
      (user-error "Log window must end after it starts"))
    (furball--with
     (furball--with view parsed)
     `((:from . ,start) (:to . ,end)
       (:query . ,(if-let* ((group (map-elt view :group-filter)))
                      (format "(%s) AND %s" (map-elt parsed :query) group)
                    (map-elt parsed :query)))))))

(defun furball--url-view (address)
  "Convert a Datadog logs ADDRESS to a view with exact timestamps.
Monitor and event IDs remain strings to preserve their precision."
  (let* ((url (url-generic-parse-url address))
         (host (url-host url))
         (path (url-filename url)))
    (unless (and (equal (url-type url) "https")
                 (string-prefix-p "/logs?" path))
      (user-error "Expected an HTTPS Datadog /logs? URL"))
    (let* ((site (furball--site (string-remove-prefix "app." host)))
           (args (url-parse-query-string (substring path (1+ (string-match "?" path)))))
           (value (lambda (key) (cadr (assoc key args))))
           (start (funcall value "from_ts"))
           (end (funcall value "to_ts"))
           (storage (or (funcall value "storage") "hot")))
      (unless (and start end (string-match-p "\\`[0-9]+\\'" start)
                   (string-match-p "\\`[0-9]+\\'" end)
                   (< (string-to-number start) (string-to-number end)))
        (user-error "URL needs a valid from_ts/to_ts window"))
      (unless (member storage '("hot" "indexes" "flex" "online-archives"))
        (user-error "Unsupported URL storage tier: %s" storage))
      `((:name . "Imported logs") (:kind . logs) (:site . ,site)
        (:query . ,(or (funcall value "query") "*"))
        (:from . ,(string-to-number start)) (:to . ,(string-to-number end))
        (:sort . ,(if (equal (funcall value "stream_sort") "asc")
                      "timestamp" "-timestamp"))
        (:storage . ,(if (equal storage "hot") "indexes" storage))
        (:monitor-id . ,(funcall value "link_monitor_id"))
        (:event-id . ,(funcall value "link_event_id"))
        (:event-ts . ,(funcall value "link_event_ts"))))))

(defun furball--group-filter (group &optional dimensions)
  "Convert monitor GROUP tags into a log search conjunction.
DIMENSIONS preserves attribute prefixes from the monitor's grouping.
For example, env:prod becomes env:\"prod\"."
  (mapconcat
   (lambda (tag)
     (unless (string-match "\\`\\([^:]+\\):\\(.*\\)\\'" tag)
       (user-error "Cannot interpret monitor group %s" group))
     (let ((key (match-string 1 tag)) (value (match-string 2 tag)))
       (when (member (concat "@" key) dimensions)
         (setq key (concat "@" key)))
       (concat key ":" (json-serialize value))))
   (split-string group "," t " ") " AND "))

(provide 'furball-query)
;;; furball-query.el ends here
