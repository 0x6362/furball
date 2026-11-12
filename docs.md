# Noridoc: Furball

Path: @/

### Overview

- Provides an Emacs dashboard for saved Datadog monitor and log searches.
- Keeps query editing separate from read-only fetched evidence.

### How it fits into the larger codebase

- Built-in Emacs process, JSON, and buffer facilities provide the runtime. Datadog Pup handles authentication and API access for monitor search, monitor details, and log search.
- Transient 0.7 or later provides contextual menus for every view. Result buffers retain long content and the query editor retains unsent drafts.
- User-facing configuration consists of ordered saved-view alists, a default site, a Pup executable path, and a request timeout.
- Pure query transformations resolve URLs and count monitor expressions into request scopes; the asynchronous transport delivers data or errors to the UI.

### Core Implementation

- Each request starts Pup with `--no-agent --output json api PATH --method METHOD` through `make-process`, without a shell. JSON request bodies go to stdin via `--input -`; each child receives its selected `DD_SITE`.
- `furball--request` queues requests per (site, rule) from `furball-rate-limits`, starting at most `:limit` per `:period`. Pup's HTTP 429 output becomes `:rate-limited` and `:retry-after` in the result; the queue pauses until the reset and retries the request first. Callers pass `:live-p` so superseded requests are dropped unsent, and `:on-wait` to display why a request is delayed. `furball--start-pup` is the raw transport.
- The transport parses stdout as JSON, reports process failures with stderr context, and terminates timed-out processes. Completion delivers one result and releases process buffers and timers.
- Search, URL, time, status, and saved-view menus collect arguments before explicit application; cancelling preserves the active scope. Contextual actions coexist with direct buffer shortcuts.
- The landing page fetches compact previews independently; selecting a view opens a full results buffer. Views sharing a `:group` are gathered under a level-1 heading at the group's first position.
- Result buffers render through an ewoc whose node data identify parts of the snapshot (dashboard section, group heading, header, row, placeholder, next-page hint). Arriving previews, pagination, failed refreshes, and preview toggles redraw only the affected nodes.
- Group and view headings carry an `outline-level` text property found by `outline-search-level`. Folded heading keys are recorded before each redraw and re-folded afterwards, so folds survive partial and full redraws.
- Buffer-local alist snapshots track the view, fixed log scope, fetched rows, pagination, and freshness. Updates replace records rather than modifying saved customization.
- Request tokens reject superseded asynchronous responses. Pagination reuses the resolved time window.
- Optional Evil integration loads when Evil is available. It maps shared commands into result normal/motion states and query normal/insert/visual states; results start in normal and queries in insert, with row navigation on `j`/`k`.
- Log detail buffers use a dedicated read-only mode with wrapped full messages, distinct literal multiline `error.stack` and `exc_info` traces, and raw JSON. Missing trace fields produce a note; rendering cannot recover server-side truncation. Quit works in ordinary Emacs and Evil normal/motion states.
- Query buffers target a results buffer and rerun its search. Results and individual log records remain read-only.
- Monitor group drill-down combines the current count log expression with group tags, preserving custom attribute prefixes, and displays logs alongside monitor details.

### Things to Know

- Imported URLs retain fixed historical timestamps. Editing an expression duration recalculates the start while retaining a fixed end; the time-range command switches to a latest window. Relative windows advance on refresh, but not pagination.
- Monitor drill-down is best effort: historical trigger timestamps are combined with current configuration; WARN groups use the current time. The current evaluation delay is subtracted before deriving the window.
- Notification templates remain literal text inside an Org-style Markdown source block, preserving Datadog placeholders without rich Markdown rendering.
- Count expressions are parsed for browsing, not evaluated. Completion includes observed nested custom fields and quoted monitor tags; grouped aggregates and complete Datadog facet autocomplete are outside this implementation.
- Access requires `monitors_read` and `logs_read_data` permissions. Pup owns OAuth or environment-based credentials; Furball does not read auth-source or implement credential storage.
- Failed refreshes retain previous data and expose errors; changed-query snapshots and partial responses are labeled. Tests use mocked responses and local subprocess fixtures; they do not verify live service access.

Created and maintained by Nori.
