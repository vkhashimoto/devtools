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
;;   g    run the query again    ?    menu with all of the above
;;
;; NULL cells show as [NULL]; an empty string shows as an empty cell.
;; Org tables cannot hold `|' or newlines, so those are shown (and
;; copied) as ¦ and ↵.

;;; Code:

(require 'org)
(require 'org-table)
(require 'seq)
(require 'transient)
(require 'devtools-profiles)

(defcustom devtools-sql-result-max-rows 1000
  "Maximum number of rows shown in a result buffer."
  :type 'natnum
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

(defvar-local devtools-sql-result-rerun nil
  "Function called with no arguments to run the query again.")
(put 'devtools-sql-result-rerun 'permanent-local t)

(defvar-local devtools-sql-result--info nil
  "Plist describing the result: :connection :profile :state :elapsed
:total-rows.")
(put 'devtools-sql-result--info 'permanent-local t)

(defvar-local devtools-sql-result--marks nil
  "Marked cells of the result table, as (ROW . COLUMN) pairs.
ROW counts table lines from 1, skipping rule lines; the header is row 1.")

(defvar-local devtools-sql-result--table-size nil
  "The result's size as (ROWS . COLUMNS), header row not counted.")

;;; Parsing psql output

(defun devtools-sql-result-parse-csv (text)
  "Parse TEXT, CSV as printed by psql --csv, into a list of rows.
Each row is a list of strings."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let (rows row)
      (while (not (eobp))
        (push (if (eq (char-after) ?\")
                  (let ((value "") done)
                    (forward-char 1)
                    (while (not done)
                      (let ((start (point)))
                        (unless (search-forward "\"" nil t)
                          (error "Unterminated quoted CSV field"))
                        (setq value (concat value (buffer-substring start (1- (point)))))
                        ;; A doubled quote is a literal quote.
                        (if (eq (char-after) ?\")
                            (progn (setq value (concat value "\"")) (forward-char 1))
                          (setq done t))))
                    value)
                (buffer-substring (point) (progn (skip-chars-forward "^,\n") (point))))
              row)
        (if (eq (char-after) ?,)
            (forward-char 1)
          (push (nreverse row) rows)
          (setq row nil)
          (unless (eobp) (forward-char 1))))
      (nreverse rows))))

(defun devtools-sql-result-status-p (output)
  "Return non-nil if OUTPUT is a command tag such as \"UPDATE 3\"."
  (string-match-p "\\`[A-Z][A-Z ]*[A-Z]\\( [0-9]+\\)*\n?\\'" output))

;;; Rendering

(defun devtools-sql-result-buffer-name (connection profile)
  "Return the result buffer name for CONNECTION in PROFILE."
  (format "*SQL Result: %s/%s*" profile (plist-get connection :name)))

(defun devtools-sql-result-start (connection profile rerun)
  "Prepare and show the result buffer for a query on CONNECTION in PROFILE.
RERUN is a function that runs the query again.  Return the buffer."
  (with-current-buffer (get-buffer-create (devtools-sql-result-buffer-name connection profile))
    (let ((inhibit-read-only t))
      (devtools-sql-result-mode -1)
      (devtools-sql-result--clear-overlays)
      (erase-buffer)
      (org-mode)
      (insert (propertize "Running..." 'face 'shadow)))
    (setq devtools-sql-result-rerun rerun
          devtools-sql-result--info (list :connection connection :profile profile
                                          :state 'running)
          header-line-format '(:eval (devtools-sql-result--header-line))
          truncate-lines t)
    (set-buffer-modified-p nil)
    (read-only-mode 1)
    (display-buffer (current-buffer))
    (current-buffer)))

(defun devtools-sql-result--cell-text (value)
  "Return VALUE made safe for an Org table cell."
  (string-replace "|" "¦" (string-replace "\n" "↵" value)))

(defun devtools-sql-result-finish (buffer exit-code output errors elapsed)
  "Show a finished query in BUFFER.
EXIT-CODE, OUTPUT and ERRORS come from psql; ELAPSED is in seconds."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (errors (string-trim errors))
            total)
        (erase-buffer)
        (cond
         ((not (zerop exit-code))
          (insert (propertize (if (string-empty-p errors) "Query failed" errors)
                              'face 'error)))
         ((devtools-sql-result-status-p output)
          (insert (string-trim output)))
         (t
          (let ((rows (mapcar (lambda (row) (mapcar #'devtools-sql-result--cell-text row))
                              (devtools-sql-result-parse-csv output))))
            (setq total (length (cdr rows)))
            (when rows
              (insert (orgtbl-to-orgtbl
                       (append (list (car rows) 'hline)
                               (seq-take (cdr rows) devtools-sql-result-max-rows))
                       nil)
                      "\n")
              (goto-char (point-min))
              (org-table-align)
              (while (re-search-forward "\\[NULL\\]" nil t)
                (let ((overlay (make-overlay (match-beginning 0) (match-end 0))))
                  (overlay-put overlay 'face 'devtools-sql-result-null)
                  (overlay-put overlay 'devtools-sql-result-null t)))))))
        ;; Notices and warnings of a successful query.
        (when (and (zerop exit-code) (not (string-empty-p errors)))
          (goto-char (point-max))
          (insert "\n" (propertize errors 'face 'warning)))
        (goto-char (point-min))
        (setq devtools-sql-result--info
              (plist-put (plist-put (plist-put devtools-sql-result--info
                                               :state (if (zerop exit-code) 'done 'failed))
                                    :elapsed elapsed)
                         :total-rows total))
        (set-buffer-modified-p nil)
        (devtools-sql-result-mode 1)))))

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
            (_ (let ((total (plist-get info :total-rows)))
                 (concat (when total
                           (if (> total devtools-sql-result-max-rows)
                               (format "first %d of %d rows" devtools-sql-result-max-rows total)
                             (format "%d rows" total)))
                         (format "  %.2fs" (or (plist-get info :elapsed) 0))))))))
    (concat
     (devtools-profile-label (plist-get info :profile))
     " " (plist-get connection :name) "  " summary
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

(defun devtools-sql-result--each-row (function)
  "Call FUNCTION with the row number, with point on each table row in turn."
  (save-excursion
    (goto-char (point-min))
    (let ((row 0))
      (while (org-at-table-p)
        (unless (org-at-table-hline-p)
          (setq row (1+ row))
          (save-excursion (funcall function row)))
        (forward-line 1)))))

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
    (let ((names (save-excursion (goto-char (point-min)) (devtools-sql-result--row-fields))))
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

(defun devtools-sql-result-rerun ()
  "Run the query of this result buffer again."
  (interactive)
  (unless devtools-sql-result-rerun
    (user-error "No query to run again"))
  (funcall devtools-sql-result-rerun))

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
    ("g" "Run again" devtools-sql-result-rerun)
    ("q" "Close window" quit-window)]])

;;; Mode

(defvar-keymap devtools-sql-result-mode-map
  "?" #'devtools-sql-result-dispatch
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
                        (goto-char (point-min))
                        (if (org-at-table-p) (length (devtools-sql-result--row-fields)) 0)))))
        ;; One margin column, for the flag on rows that have marked cells.
        (setq-local left-margin-width 1)
        (dolist (window (get-buffer-window-list nil nil t))
          (set-window-buffer window (current-buffer)))
        ;; Keeps the marked-cell count current after every command.
        (add-hook 'post-command-hook #'force-mode-line-update nil t))
    (remove-hook 'post-command-hook #'force-mode-line-update t)))

(provide 'devtools-sql-result)
;;; devtools-sql-result.el ends here
