;;; devtools-sql-result.el --- Buffer for SQL query results  -*- lexical-binding: t; -*-

;;; Commentary:

;; Shows a query result as an aligned Org table in a read-only buffer,
;; one per environment/connection, with keys to move by cell and to
;; mark and copy cells:
;;
;;   n/p  down/up one row        f/b  right/left one column
;;   m    toggle mark on cell (with a region, mark the block)
;;   C    mark the column        U    clear all marks
;;   w    copy marked cells (or the cell at point)
;;   W    copy the row           N    copy NULL as nothing / NULL
;;   H    copy column names too  D    choose the delimiter
;;   TAB  show or hide the whole query  RET  on the query: go to its file
;;   g    run the query again (see `devtools-sql-result-allow-rerun')
;;   ?    menu with all of the above
;;
;; NULL cells show as [NULL]; an empty string shows as an empty cell.
;; Org tables cannot hold `|' or newlines, so those are shown (and
;; copied) as ¦ and ↵.

;;; Code:

(require 'org)
(require 'org-table)
(require 'pulse)
(require 'sql)
(require 'seq)
(require 'transient)
(require 'devtools-profiles)

(defcustom devtools-sql-result-max-rows 1000
  "Maximum number of rows shown in a result buffer."
  :type 'natnum
  :group 'devtools)

(defcustom devtools-sql-result-query-expanded nil
  "Non-nil means result buffers show their whole query at first.
Otherwise they show its first line; \\<devtools-sql-result-mode-map>\\[devtools-sql-result-toggle-query] shows or hides the rest."
  :type 'boolean
  :group 'devtools)

(defcustom devtools-sql-result-allow-rerun 'reads
  "Which queries \\<devtools-sql-result-mode-map>\\[devtools-sql-result-rerun] in a result buffer runs again.
`reads': only queries that read (SELECT, WITH, SHOW, EXPLAIN, VALUES,
TABLE, without a write inside); others are refused, to be run again
from their file.  `all': any query.  nil: none, the key is off.
A function called from a SELECT can still have side effects (nextval,
for instance); those are not detected."
  :type '(choice (const :tag "Only queries that read" reads)
                 (const :tag "Any query" all)
                 (const :tag "None" nil))
  :group 'devtools)

(defcustom devtools-sql-result-copy-null-as ""
  "What a NULL cell becomes when copied: an empty string or \"NULL\"."
  :type '(choice (const :tag "Nothing" "") (const "NULL"))
  :group 'devtools)

(defcustom devtools-sql-result-copy-header nil
  "Non-nil means copied text starts with a line of column names."
  :type 'boolean
  :group 'devtools)

(defcustom devtools-sql-result-copy-delimiter "\t"
  "The text put between the cells of one row when copying."
  :type 'string
  :group 'devtools)

(defcustom devtools-sql-result-delimiters
  '(("tab" . "\t") ("pipe" . "|") ("semicolon" . ";") ("comma" . ",")
    ("space" . " "))
  "Named delimiters offered by `devtools-sql-result-set-copy-delimiter'."
  :type '(alist :key-type string :value-type string)
  :group 'devtools)

(defface devtools-sql-result-null
  '((t :inherit font-lock-constant-face :slant italic))
  "Face for NULL cells."
  :group 'devtools)

(defface devtools-sql-result-null-marked
  '((t :inherit (font-lock-keyword-face highlight) :slant italic :weight bold))
  "Face for a NULL cell that is marked."
  :group 'devtools)

(defface devtools-sql-result-marked-header
  '((t :inherit highlight :weight bold))
  "Face for the header of a column that has marked cells."
  :group 'devtools)

(defface devtools-sql-result-marked-row
  '((t :inherit warning :weight bold))
  "Face for the margin flag of a row that has marked cells."
  :group 'devtools)

(defvar devtools-sql-result-mode)

(defvar-local devtools-sql-result--rerun-function nil
  "Function called with no arguments to run the query again.")
(put 'devtools-sql-result--rerun-function 'permanent-local t)

(defvar-local devtools-sql-result--info nil
  "Plist describing the result: :connection :profile :name :sql :location
:state :run
:target (`session' or `pool') :tx :elapsed :statements :shown-rows
:total-rows.")
(put 'devtools-sql-result--info 'permanent-local t)

(defvar-local devtools-sql-result--query-expanded nil
  "Non-nil when this result buffer shows its whole query.")
(put 'devtools-sql-result--query-expanded 'permanent-local t)

(defvar-local devtools-sql-result--marks nil
  "Marked cells of the result table, as (ROW . COLUMN) pairs.
ROW counts table lines from 1, skipping rule lines; the header is row 1.")

(defvar-local devtools-sql-result--table-size nil
  "The result's size as (ROWS . COLUMNS), header row not counted.")

;;; Rendering

(defun devtools-sql-result-buffer-name (connection profile &optional name)
  "Return the result buffer name for CONNECTION in PROFILE.
NAME is the query file's name, nil for the default file."
  (format "*SQL Result: %s/%s%s*" profile (plist-get connection :name)
          (if name (concat "/" name) "")))

(defun devtools-sql-result-start (connection profile rerun &optional sql name location)
  "Prepare and show the result buffer for a query on CONNECTION in PROFILE.
RERUN is a function that runs the query again; SQL is the query, shown
above the result and used to point at errors; NAME is the query file's
name, nil for the default file; LOCATION, a plist (:file :line
:marker), is where the query is in its file, if it came from one.
Return the buffer."
  (with-current-buffer (get-buffer-create (devtools-sql-result-buffer-name connection profile name))
    (unless (local-variable-p 'devtools-sql-result--query-expanded)
      (setq-local devtools-sql-result--query-expanded devtools-sql-result-query-expanded))
    (setq devtools-sql-result--rerun-function rerun
          devtools-sql-result--info (list :connection connection :profile profile
                                          :name name :sql sql :location location
                                          :state 'running))
    (let ((inhibit-read-only t))
      (devtools-sql-result-mode -1)
      (devtools-sql-result--clear-overlays)
      (erase-buffer)
      (org-mode)
      (devtools-sql-result--insert-query)
      (insert (propertize "Running..." 'face 'shadow)))
    (setq header-line-format '(:eval (devtools-sql-result--header-line))
          truncate-lines t)
    (set-buffer-modified-p nil)
    (read-only-mode 1)
    (display-buffer (current-buffer))
    (current-buffer)))

(defun devtools-sql-result--cell-text (value)
  "Return VALUE made safe for an Org table cell; nil (NULL) is [NULL]."
  (if value
      (string-replace "|" "¦" (string-replace "\n" "↵" value))
    "[NULL]"))

(defun devtools-sql-result--render (buffer state elapsed insert)
  "Erase BUFFER and call INSERT there to show a finished query.
STATE is `done' or `failed'; ELAPSED is in seconds.  INSERT returns
the result's (SHOWN-ROWS . TOTAL-ROWS), or nil when it is no table."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            rows)
        (erase-buffer)
        (devtools-sql-result--insert-query)
        (setq rows (funcall insert))
        (devtools-sql-result--goto-first-row)
        (dolist (window (get-buffer-window-list nil nil t))
          (set-window-point window (point)))
        (setq devtools-sql-result--info
              (thread-first devtools-sql-result--info
                            (plist-put :state state)
                            (plist-put :elapsed elapsed)
                            (plist-put :shown-rows (car rows))
                            (plist-put :total-rows (cdr rows))))
        (set-buffer-modified-p nil)
        (devtools-sql-result-mode 1)))))

(defun devtools-sql-result--insert-table (set)
  "Insert the result SET as an aligned Org table.
Return its (SHOWN-ROWS . TOTAL-ROWS)."
  (let ((header (mapcar (lambda (column)
                          (devtools-sql-result--cell-text (plist-get column :name)))
                        (plist-get set :columns)))
        (rows (mapcar (lambda (row) (mapcar #'devtools-sql-result--cell-text row))
                      (plist-get set :rows))))
    (let ((start (point)))
      (insert (orgtbl-to-orgtbl (append (list header 'hline) rows) nil) "\n")
      (goto-char start))
    (org-table-align)
    (while (re-search-forward "\\[NULL\\]" nil t)
      (let ((overlay (make-overlay (match-beginning 0) (match-end 0))))
        (overlay-put overlay 'face 'devtools-sql-result-null)
        (overlay-put overlay 'devtools-sql-result-null t)))
    (cons (length rows) (plist-get set :totalRows))))

(defun devtools-sql-result-show (buffer response elapsed)
  "Show RESPONSE, the server's reply to query/execute, in BUFFER.
The last statement's result is shown.  ELAPSED is in seconds."
  (let* ((results (plist-get response :results))
         (last (and (length> results 0) (aref results (1- (length results))))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq devtools-sql-result--info
              (plist-put devtools-sql-result--info :statements (length results)))))
    (devtools-sql-result--render
     buffer 'done elapsed
     (lambda ()
       (cond ((null last) (insert (propertize "No statements" 'face 'shadow)) nil)
             ((plist-get last :columns) (devtools-sql-result--insert-table last))
             (t (insert (plist-get last :command)) nil))))))

(defun devtools-sql-result--error-context (sql position)
  "Return the line of SQL holding the character at POSITION (from 1).
A caret under it points at the character, like psql does."
  (with-temp-buffer
    (insert sql)
    (goto-char (max (point-min) (min position (point-max))))
    (let ((prefix (format "LINE %d: " (line-number-at-pos)))
          (column (current-column)))
      (concat prefix (buffer-substring (line-beginning-position) (line-end-position)) "\n"
              (make-string (+ (length prefix) column) ?\s) "^"))))

(defun devtools-sql-result-show-error (buffer error elapsed)
  "Show ERROR, a server error plist (:code :message :data), in BUFFER.
ELAPSED is in seconds."
  (devtools-sql-result--render
   buffer 'failed elapsed
   (lambda ()
     (let ((data (plist-get error :data))
           (sql (plist-get devtools-sql-result--info :sql)))
       (insert (propertize (concat "ERROR:  " (plist-get error :message)) 'face 'error))
       (when-let* ((position (plist-get data :position))
                   ((stringp sql)))
         (insert "\n" (devtools-sql-result--error-context sql position)))
       (when-let* ((detail (plist-get data :detail)))
         (insert "\nDETAIL:  " detail))
       (when-let* ((hint (plist-get data :hint)))
         (insert "\nHINT:  " hint))
       nil))))

(defun devtools-sql-result--clear-overlays ()
  "Remove the overlays added by the result buffer."
  (dolist (property '(devtools-sql-result-marked devtools-sql-result-null
                                                 devtools-sql-result-indicator))
    (remove-overlays (point-min) (point-max) property t)))

(defun devtools-sql-result--header-line ()
  "Return the text of the result buffer's header line."
  (let* ((info devtools-sql-result--info)
         (connection (plist-get info :connection))
         (on (lambda (text) (propertize text 'face 'devtools-sql-result-null)))
         (off (lambda (text) (propertize text 'face 'shadow)))
         (summary
          (pcase (plist-get info :state)
            ('running (funcall off "running..."))
            ('failed (propertize "failed" 'face 'error))
            (_ (let ((shown (plist-get info :shown-rows))
                     (total (plist-get info :total-rows))
                     (statements (or (plist-get info :statements) 0)))
                 (concat (when total
                           (if (> total shown)
                               (format "first %d of %d rows" shown total)
                             (format "%d rows" total)))
                         (format "  %.2fs" (or (plist-get info :elapsed) 0))
                         (when (> statements 1)
                           (funcall off (format "  (last of %d results)" statements))))))))
         (target
          (pcase (plist-get info :target)
            ('pool (funcall off "  pool"))
            ('session
             (concat (funcall off "  session")
                     (pcase (plist-get info :tx)
                       ("transaction" (propertize " · in transaction" 'face 'warning))
                       ("failed" (propertize " · transaction failed" 'face 'error))))))))
    (concat
     (devtools-profile-label (plist-get info :profile))
     " " (plist-get connection :name)
     (when-let* ((name (plist-get info :name))) (concat "/" name))
     "  " summary target
     (when (and devtools-sql-result-mode
                (> (or (cdr devtools-sql-result--table-size) 0) 0))
       (let ((rows (length (delete-dups (delq 1 (mapcar #'car devtools-sql-result--marks)))))
             (columns (length (delete-dups (mapcar #'cdr devtools-sql-result--marks)))))
         (format "   Marked: %d/%d rows, %d/%d columns, %d cells   Copy NULL as: %s (N)   Header: %s (H)   Delimiter: %s (D)"
                 rows (or (car devtools-sql-result--table-size) 0)
                 columns (or (cdr devtools-sql-result--table-size) 0)
                 (length devtools-sql-result--marks)
                 (if (equal devtools-sql-result-copy-null-as "")
                     (funcall off "nothing")
                   (funcall on "NULL"))
                 (if devtools-sql-result-copy-header (funcall on "yes") (funcall off "no"))
                 (funcall on (devtools-sql-result--delimiter-name))))))))

;;; The query

(defvar-keymap devtools-sql-result-query-map
  :doc "Keys on the query at the top of a result buffer."
  "RET" #'devtools-sql-result-visit-query)

(defconst devtools-sql-result--query-width 72
  "Characters of a collapsed query's first line shown.")

(defun devtools-sql-result--fontify-sql (sql)
  "Return SQL highlighted as in `sql-mode'.
The faces are `font-lock-face' properties, which Org's font-lock in
the result buffer leaves alone."
  (with-temp-buffer
    (insert sql)
    (delay-mode-hooks (sql-mode))
    (sql-set-product 'postgres)
    (font-lock-ensure)
    (let ((position (point-min)))
      (while (< position (point-max))
        (let ((next (next-single-property-change position 'face nil (point-max))))
          (when-let* ((face (get-text-property position 'face)))
            (put-text-property position next 'font-lock-face face))
          (setq position next))))
    (remove-list-of-text-properties (point-min) (point-max) '(face))
    (buffer-string)))

(defun devtools-sql-result--location-label (location)
  "Return \"FILE:LINE\" for LOCATION, or nil."
  (when location
    (format "%s:%d" (file-name-nondirectory (plist-get location :file))
            (plist-get location :line))))

(defun devtools-sql-result--insert-query ()
  "Insert the query of this result at point, whole or as its first line.
RET on it goes to the query in its file."
  (when-let* ((sql (plist-get devtools-sql-result--info :sql)))
    (let ((sql (string-trim sql))
          (label (devtools-sql-result--location-label
                  (plist-get devtools-sql-result--info :location)))
          (start (point)))
      (if devtools-sql-result--query-expanded
          ;; Indented, so Org does not read its lines as headings or tables.
          (insert (propertize (concat "▾ " (or label "query")) 'font-lock-face 'shadow) "\n"
                  (replace-regexp-in-string "^" "  " (devtools-sql-result--fontify-sql sql))
                  "\n")
        (let* ((lines (split-string sql "\n"))
               (first (string-trim (car lines)))
               (long (> (length first) devtools-sql-result--query-width)))
          (insert (propertize "▸ " 'font-lock-face 'shadow)
                  (devtools-sql-result--fontify-sql
                   (if long (substring first 0 devtools-sql-result--query-width) first))
                  (if (or long (cdr lines)) (propertize "…" 'font-lock-face 'shadow) "")
                  (if label (concat "   " (propertize label 'font-lock-face 'shadow)) "")
                  "\n")))
      (add-text-properties start (point)
                           (list 'devtools-sql-result-query t
                                 'keymap devtools-sql-result-query-map
                                 'help-echo "RET: go to the query in its file"))
      (insert "\n"))))

(defun devtools-sql-result--goto-first-row ()
  "Move to the table's first row, or to the top if there is no table."
  (if (not (devtools-sql-result--goto-table))
      (goto-char (point-min))
    (forward-line 2)
    (if (and (org-at-table-p) (not (org-at-table-hline-p)))
        (org-table-goto-column 1)
      (devtools-sql-result--goto-table))))

(defun devtools-sql-result-toggle-query ()
  "Show the whole query of this result, or only its first line."
  (interactive)
  (unless (plist-get devtools-sql-result--info :sql)
    (user-error "No query to show"))
  (setq devtools-sql-result--query-expanded (not devtools-sql-result--query-expanded))
  (let ((inhibit-read-only t))
    (save-excursion
      (when (get-text-property (point-min) 'devtools-sql-result-query)
        ;; The query, then the blank line after it.
        (delete-region (point-min)
                       (min (point-max)
                            (1+ (next-single-property-change
                                 (point-min) 'devtools-sql-result-query nil (point-max))))))
      (goto-char (point-min))
      (devtools-sql-result--insert-query)))
  (set-buffer-modified-p nil))

(defun devtools-sql-result-visit-query ()
  "Go to the query of this result in its file."
  (interactive)
  (let* ((location (plist-get devtools-sql-result--info :location))
         (marker (plist-get location :marker)))
    (cond
     ;; The file is open: the marker follows the edits made since.
     ((and (markerp marker) (marker-buffer marker))
      (pop-to-buffer (marker-buffer marker))
      (goto-char marker))
     (location
      (pop-to-buffer (find-file-noselect (plist-get location :file)))
      (goto-char (point-min))
      (forward-line (1- (plist-get location :line))))
     (t (user-error "This query was not run from a file")))
    (pulse-momentary-highlight-one-line (point))))

;;; Cells

(defun devtools-sql-result--cell ()
  "Return the (ROW . COLUMN) of the cell at point."
  (unless (and (org-at-table-p) (not (org-at-table-hline-p)))
    (user-error "Point is not on a table row"))
  ;; Past the last `|' Org reports one column too many, so clamp it.
  (cons (org-table-current-dline)
        (min (length (devtools-sql-result--row-fields))
             (max 1 (org-table-current-column)))))

(defun devtools-sql-result--row-fields ()
  "Return the cell values of the table line at point."
  (mapcar #'string-trim
          (butlast (cdr (split-string
                         (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position))
                         "|")))))

(defun devtools-sql-result--copy-fields ()
  "Return the cell values of the line at point, as they should be copied."
  (mapcar (lambda (value)
            (if (equal value "[NULL]") devtools-sql-result-copy-null-as value))
          (devtools-sql-result--row-fields)))

(defun devtools-sql-result--goto-table ()
  "Move to the first line of the result table; return nil if there is none."
  (goto-char (point-min))
  (when (re-search-forward "^|" nil t)
    (forward-line 0)
    t))

(defun devtools-sql-result--each-row (function)
  "Call FUNCTION with the row number, with point on each table row in turn."
  (save-excursion
    (when (devtools-sql-result--goto-table)
      (let ((row 0))
        (while (org-at-table-p)
          (unless (org-at-table-hline-p)
            (setq row (1+ row))
            (save-excursion (funcall function row)))
          (forward-line 1))))))

;;; Marking

(defun devtools-sql-result--mark-column (row column)
  "Mark the cell at ROW and COLUMN.  Point must be on that row's line."
  (let ((cell (cons row column)))
    (unless (member cell devtools-sql-result--marks)
      (push cell devtools-sql-result--marks)
      (org-table-goto-column column)
      (let ((overlay (make-overlay (1- (point))
                                   (progn (skip-chars-forward "^|\n") (point)))))
        (overlay-put overlay 'face
                     (if (equal (string-trim (buffer-substring-no-properties
                                              (overlay-start overlay)
                                              (overlay-end overlay)))
                                "[NULL]")
                         'devtools-sql-result-null-marked
                       'highlight))
        ;; Above the overlay that colours unmarked NULL cells.
        (overlay-put overlay 'priority 1)
        (overlay-put overlay 'devtools-sql-result-marked t)
        (overlay-put overlay 'devtools-sql-result-mark cell)))))

(defun devtools-sql-result--unmark (cell)
  "Remove the mark on CELL."
  (let ((stored (car (member cell devtools-sql-result--marks))))
    (remove-overlays (point-min) (point-max) 'devtools-sql-result-mark stored)
    (setq devtools-sql-result--marks (delq stored devtools-sql-result--marks))))

(defun devtools-sql-result--refresh-indicators ()
  "Highlight the headers and flag the rows that have marked cells."
  (remove-overlays (point-min) (point-max) 'devtools-sql-result-indicator t)
  (let ((rows (delete-dups (mapcar #'car devtools-sql-result--marks)))
        (columns (delete-dups (mapcar #'cdr devtools-sql-result--marks))))
    (devtools-sql-result--each-row
     (lambda (row)
       (when (= row 1)
         (save-excursion
           (dolist (column columns)
             (org-table-goto-column column)
             (let ((overlay (make-overlay
                             (1- (point))
                             (progn (skip-chars-forward "^|\n") (point)))))
               (overlay-put overlay 'face 'devtools-sql-result-marked-header)
               (overlay-put overlay 'devtools-sql-result-indicator t)))))
       (when (memq row rows)
         (let ((overlay (make-overlay (point) (1+ (point)))))
           (overlay-put overlay 'before-string
                        (propertize
                         " " 'display
                         `((margin left-margin)
                           ,(propertize "▌" 'face 'devtools-sql-result-marked-row))))
           (overlay-put overlay 'devtools-sql-result-indicator t)))))))

(defun devtools-sql-result-mark ()
  "Toggle the mark on the cell at point, or mark the cells in the region.
With an active region, mark the block of cells between its two ends."
  (interactive)
  (if (use-region-p)
      (let* ((start (save-excursion (goto-char (region-beginning)) (devtools-sql-result--cell)))
             (end (save-excursion (goto-char (region-end)) (devtools-sql-result--cell)))
             (first-column (min (cdr start) (cdr end)))
             (last-column (max (cdr start) (cdr end))))
        (devtools-sql-result--each-row
         (lambda (row)
           (when (<= (car start) row (car end))
             (dolist (column (number-sequence first-column last-column))
               (devtools-sql-result--mark-column row column)))))
        (deactivate-mark))
    (let ((cell (devtools-sql-result--cell)))
      (if (member cell devtools-sql-result--marks)
          (devtools-sql-result--unmark cell)
        (save-excursion (devtools-sql-result--mark-column (car cell) (cdr cell))))))
  (devtools-sql-result--refresh-indicators))

(defun devtools-sql-result-mark-whole-column ()
  "Mark every cell below the header in the column at point."
  (interactive)
  (let ((column (cdr (devtools-sql-result--cell))))
    (devtools-sql-result--each-row
     (lambda (row)
       (when (> row 1)
         (devtools-sql-result--mark-column row column)))))
  (devtools-sql-result--refresh-indicators))

(defun devtools-sql-result-unmark-all ()
  "Clear all marks."
  (interactive)
  (remove-overlays (point-min) (point-max) 'devtools-sql-result-marked t)
  (setq devtools-sql-result--marks nil)
  (devtools-sql-result--refresh-indicators))

;;; Copying

(defun devtools-sql-result-toggle-copy-null ()
  "Switch between copying NULL cells as nothing and as the text NULL."
  (interactive)
  (setq devtools-sql-result-copy-null-as
        (if (equal devtools-sql-result-copy-null-as "") "NULL" ""))
  (force-mode-line-update t)
  (message "NULL cells are copied as %s"
           (if (equal devtools-sql-result-copy-null-as "") "nothing" "NULL")))

(defun devtools-sql-result-toggle-copy-header ()
  "Switch between copying with and without the column names."
  (interactive)
  (setq devtools-sql-result-copy-header (not devtools-sql-result-copy-header))
  (force-mode-line-update t)
  (message "Column names are %s"
           (if devtools-sql-result-copy-header "copied too" "not copied")))

(defun devtools-sql-result--delimiter-name ()
  "Return the name of the current delimiter, or the delimiter itself."
  (or (car (rassoc devtools-sql-result-copy-delimiter devtools-sql-result-delimiters))
      devtools-sql-result-copy-delimiter))

(defun devtools-sql-result-set-copy-delimiter (delimiter)
  "Choose the DELIMITER put between copied cells.
Pick one of the named delimiters or type any other text to use as is."
  (interactive
   (list (completing-read
          (format "Delimiter (now %s): " (devtools-sql-result--delimiter-name))
          devtools-sql-result-delimiters)))
  (when (equal delimiter "")
    (user-error "The delimiter cannot be empty"))
  (setq devtools-sql-result-copy-delimiter
        (or (cdr (assoc delimiter devtools-sql-result-delimiters)) delimiter))
  (force-mode-line-update t)
  (message "Cells are separated by %s" (devtools-sql-result--delimiter-name)))

(defun devtools-sql-result--quote (value)
  "Return VALUE, quoted like a CSV field when it would break the row.
That is when it contains the delimiter or a newline, or starts with a
double quote.  Double quotes inside a quoted value are doubled."
  (if (or (string-search devtools-sql-result-copy-delimiter value)
          (string-search "\n" value)
          (string-prefix-p "\"" value))
      (concat "\"" (string-replace "\"" "\"\"" value) "\"")
    value))

(defun devtools-sql-result--kill-rows (columns rows)
  "Copy ROWS, a list of lists of cell values, as delimited lines.
With `devtools-sql-result-copy-header' set, start with the names of COLUMNS."
  (when devtools-sql-result-copy-header
    (let ((names (save-excursion (devtools-sql-result--goto-table)
                                 (devtools-sql-result--row-fields))))
      (push (mapcar (lambda (column) (nth (1- column) names)) columns) rows)))
  ;; A row of one cell has no delimiter to clash with, so it stays as is.
  (kill-new (mapconcat (lambda (row)
                         (if (cdr row)
                             (mapconcat #'devtools-sql-result--quote row
                                        devtools-sql-result-copy-delimiter)
                           (car row)))
                       rows "\n")))

(defun devtools-sql-result-copy ()
  "Copy the marked cells, or the cell at point when nothing is marked."
  (interactive)
  (if (null devtools-sql-result--marks)
      (let* ((cell (devtools-sql-result--cell))
             (value (nth (1- (cdr cell)) (devtools-sql-result--copy-fields))))
        (devtools-sql-result--kill-rows (list (cdr cell)) (list (list value)))
        (message "Copied: %s" value))
    (let ((all-columns (sort (delete-dups (mapcar #'cdr devtools-sql-result--marks)) #'<))
          (lines nil))
      (devtools-sql-result--each-row
       (lambda (row)
         (let ((columns (sort (mapcar #'cdr (seq-filter
                                             (lambda (cell) (= (car cell) row))
                                             devtools-sql-result--marks))
                              #'<))
               (fields (devtools-sql-result--copy-fields)))
           ;; With the header copied anyway, a marked header row is skipped.
           (when (and columns (not (and devtools-sql-result-copy-header (= row 1))))
             (push (mapcar (lambda (column) (nth (1- column) fields)) columns)
                   lines)))))
      (devtools-sql-result--kill-rows all-columns (nreverse lines))
      (message "Copied %d cells" (length devtools-sql-result--marks)))))

(defun devtools-sql-result-copy-row ()
  "Copy the row at point."
  (interactive)
  (devtools-sql-result--cell)
  (let ((fields (devtools-sql-result--copy-fields)))
    (devtools-sql-result--kill-rows (number-sequence 1 (length fields)) (list fields)))
  (message "Copied row"))

;;; Moving

(defun devtools-sql-result-next-row (&optional count)
  "Move down COUNT rows, staying in the same column."
  (interactive "p")
  (let ((column (max 1 (org-table-current-column)))
        (step (if (< (or count 1) 0) -1 1))
        (start (point)))
    (dotimes (_ (abs (or count 1)))
      (forward-line step)
      (while (and (org-at-table-p) (org-at-table-hline-p) (not (bobp)))
        (forward-line step)))
    (unless (and (org-at-table-p) (not (org-at-table-hline-p)))
      (goto-char start)
      (user-error "No more rows"))
    (org-table-goto-column column)))

(defun devtools-sql-result-previous-row (&optional count)
  "Move up COUNT rows, staying in the same column."
  (interactive "p")
  (devtools-sql-result-next-row (- (or count 1))))

(defun devtools-sql-result-next-column (&optional count)
  "Move right COUNT columns."
  (interactive "p")
  (let ((column (+ (cdr (devtools-sql-result--cell)) (or count 1))))
    (unless (<= 1 column (length (devtools-sql-result--row-fields)))
      (user-error "No more columns"))
    (org-table-goto-column column)))

(defun devtools-sql-result-previous-column (&optional count)
  "Move left COUNT columns."
  (interactive "p")
  (devtools-sql-result-next-column (- (or count 1))))

(defun devtools-sql-result--strip-sql (sql)
  "Return SQL without its comments, string literals and quoted names.
What remains is keywords and plain names, safe to look for words in."
  (with-temp-buffer
    (insert sql)
    (goto-char (point-min))
    (let (parts)
      (while (not (eobp))
        (let ((start (point)))
          (skip-chars-forward "^-/$'\"")
          (push (buffer-substring start (point)) parts))
        (cond
         ((eobp))
         ((looking-at "--")
          (forward-line 1)
          (push "\n" parts))
         ((looking-at "/\\*")
          (goto-char (or (search-forward "*/" nil t) (point-max)))
          (push " " parts))
         ((looking-at "\\$[A-Za-z_0-9]*\\$")
          (let ((tag (match-string 0)))
            (goto-char (match-end 0))
            (goto-char (or (search-forward tag nil t) (point-max))))
          (push " x " parts))
         ((looking-at "['\"]")
          ;; A doubled quote inside is part of the literal or name.
          (let ((quote (char-after)) done)
            (forward-char 1)
            (while (and (not done) (not (eobp)))
              (cond ((not (eq (char-after) quote)) (forward-char 1))
                    ((eq (char-after (1+ (point))) quote) (forward-char 2))
                    (t (forward-char 1) (setq done t)))))
          (push " x " parts))
         (t
          (push (char-to-string (char-after)) parts)
          (forward-char 1))))
      (apply #'concat (nreverse parts)))))

(defun devtools-sql-read-only-query-p (sql)
  "Return non-nil if every statement of SQL only reads.
Each must start with SELECT, WITH, SHOW, EXPLAIN, VALUES or TABLE and
hold no write: a data-changing WITH, SELECT INTO, EXPLAIN ANALYZE or
SELECT FOR UPDATE make it a write.  When unsure, it is not a read."
  (let ((statements (seq-remove #'string-blank-p
                                (split-string (devtools-sql-result--strip-sql (or sql "")) ";"))))
    (and statements
         (seq-every-p
          (lambda (statement)
            (let ((words (split-string (downcase statement) "[^a-z_0-9]+" t)))
              (and (member (car words) '("select" "with" "show" "explain" "values" "table"))
                   (not (seq-intersection (cdr words)
                                          '("insert" "update" "delete" "merge" "into"
                                            "truncate" "analyze" "analyse"))))))
          statements))))

(defun devtools-sql-result-rerun ()
  "Run the query of this result buffer again.
`devtools-sql-result-allow-rerun' says which queries it runs."
  (interactive)
  (cond
   ((null devtools-sql-result-allow-rerun)
    (user-error "Running again from the result buffer is off; see `devtools-sql-result-allow-rerun'"))
   ((null devtools-sql-result--rerun-function)
    (user-error "No query to run again"))
   ((and (eq devtools-sql-result-allow-rerun 'reads)
         (not (devtools-sql-read-only-query-p (plist-get devtools-sql-result--info :sql))))
    (user-error "Not running again: the query may change data; run it from its file instead"))
   (t (funcall devtools-sql-result--rerun-function))))

;;; Menu

(defun devtools-sql-result--copy-null-description ()
  "Menu label showing how NULL cells are copied."
  (concat "Copy NULL as "
          (propertize (if (equal devtools-sql-result-copy-null-as "") "nothing" "NULL")
                      'face 'transient-value)))

(defun devtools-sql-result--copy-header-description ()
  "Menu label showing whether column names are copied."
  (concat "Copy column names "
          (propertize (if devtools-sql-result-copy-header "yes" "no")
                      'face 'transient-value)))

(defun devtools-sql-result--delimiter-description ()
  "Menu label showing the copy delimiter."
  (concat "Delimiter "
          (propertize (devtools-sql-result--delimiter-name) 'face 'transient-value)))

;;;###autoload (autoload 'devtools-sql-result-dispatch "devtools-sql-result" nil t)
(transient-define-prefix devtools-sql-result-dispatch ()
  "Show the commands of a SQL result buffer."
  [["Move"
    ("n" "Next row" devtools-sql-result-next-row)
    ("p" "Previous row" devtools-sql-result-previous-row)
    ("f" "Next column" devtools-sql-result-next-column)
    ("b" "Previous column" devtools-sql-result-previous-column)]
   ["Mark"
    ("m" "Cell (or region block)" devtools-sql-result-mark)
    ("C" "Column" devtools-sql-result-mark-whole-column)
    ("U" "Clear all" devtools-sql-result-unmark-all)]
   ["Copy"
    ("w" "Marked cells (or cell)" devtools-sql-result-copy)
    ("W" "Row" devtools-sql-result-copy-row)]]
  [["Copy options"
    ("N" devtools-sql-result-toggle-copy-null
     :description devtools-sql-result--copy-null-description :transient t)
    ("H" devtools-sql-result-toggle-copy-header
     :description devtools-sql-result--copy-header-description :transient t)
    ("D" devtools-sql-result-set-copy-delimiter
     :description devtools-sql-result--delimiter-description)]
   ["Query"
    ("TAB" "Show or hide the query" devtools-sql-result-toggle-query)
    ("RET" "Go to the query in its file" devtools-sql-result-visit-query)
    ("g" "Run again" devtools-sql-result-rerun
     :if (lambda () devtools-sql-result-allow-rerun))
    ("q" "Close window" quit-window)]])

;;; Mode

(defvar-keymap devtools-sql-result-mode-map
  "?" #'devtools-sql-result-dispatch
  "TAB" #'devtools-sql-result-toggle-query
  ;; Org binds <tab> too, which would win over TAB.
  "<tab>" #'devtools-sql-result-toggle-query
  "n" #'devtools-sql-result-next-row
  "p" #'devtools-sql-result-previous-row
  "f" #'devtools-sql-result-next-column
  "b" #'devtools-sql-result-previous-column
  "m" #'devtools-sql-result-mark
  "C" #'devtools-sql-result-mark-whole-column
  "U" #'devtools-sql-result-unmark-all
  "w" #'devtools-sql-result-copy
  "W" #'devtools-sql-result-copy-row
  "N" #'devtools-sql-result-toggle-copy-null
  "H" #'devtools-sql-result-toggle-copy-header
  "D" #'devtools-sql-result-set-copy-delimiter
  "g" #'devtools-sql-result-rerun
  "q" #'quit-window)

(define-minor-mode devtools-sql-result-mode
  "Move through, mark and copy cells of a SQL result table."
  :lighter " SQLResult"
  :keymap devtools-sql-result-mode-map
  (if devtools-sql-result-mode
      (progn
        (setq devtools-sql-result--marks nil
              devtools-sql-result--table-size
              (let ((lines 0))
                (devtools-sql-result--each-row (lambda (_row) (setq lines (1+ lines))))
                (cons (max 0 (1- lines))
                      (save-excursion
                        (if (devtools-sql-result--goto-table)
                            (length (devtools-sql-result--row-fields))
                          0)))))
        ;; One margin column, for the flag on rows that have marked cells.
        (setq-local left-margin-width 1)
        (dolist (window (get-buffer-window-list nil nil t))
          (set-window-buffer window (current-buffer)))
        ;; Keeps the marked-cell count current after every command.
        (add-hook 'post-command-hook #'force-mode-line-update nil t))
    (remove-hook 'post-command-hook #'force-mode-line-update t)))

(provide 'devtools-sql-result)
;;; devtools-sql-result.el ends here
