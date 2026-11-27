;;; devtools-sql-schema.el --- Table and column completion  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loads the tables and columns of a connection from information_schema,
;; caches them per environment/connection, and offers them through
;; `completion-at-point' in query files (corfu, company, C-M-i...):
;;
;;   orders.|      columns of orders
;;   o.|           columns of the table aliased o in the statement
;;   sales.|       tables of the schema sales
;;   elsewhere     tables, and columns of the statement's tables
;;
;; The schema loads in the background when a query file opens, reloads
;; after a successful CREATE/ALTER/DROP, and on
;; `devtools-sql-refresh-schema'.

;;; Code:

(require 'devtools-sql)

(defcustom devtools-sql-schema-wait 3
  "Seconds completion waits for a schema that is still loading."
  :type 'number
  :group 'devtools)

(defconst devtools-sql-schema--query
  "select c.table_schema, c.table_name, t.table_type, c.column_name, c.data_type
from information_schema.columns c
join information_schema.tables t using (table_schema, table_name)
where c.table_schema not in ('pg_catalog', 'information_schema')
order by c.table_schema, c.table_name, c.ordinal_position"
  "Query listing every visible column with its table.")

(defvar devtools-sql-schema--cache (make-hash-table :test #'equal)
  "Tables per (PROFILE . CONNECTION-NAME).
Each table is a plist (:schema :name :type :columns), :columns being a
list of (NAME . TYPE).")

(defvar devtools-sql-schema--loading (make-hash-table :test #'equal)
  "Process loading the schema, per (PROFILE . CONNECTION-NAME).")

(defun devtools-sql-schema--key (conn profile)
  "Return the cache key of CONN in PROFILE."
  (cons profile (plist-get conn :name)))

(defun devtools-sql-schema--parse (output)
  "Turn the CSV OUTPUT of `devtools-sql-schema--query' into tables."
  (let (tables)
    (dolist (row (cdr (devtools-sql-result-parse-csv output)))
      (pcase-let ((`(,schema ,name ,type ,column ,data-type) row))
        (unless (and tables
                     (equal (plist-get (car tables) :schema) schema)
                     (equal (plist-get (car tables) :name) name))
          (push (list :schema schema :name name :type type :columns nil) tables))
        (plist-put (car tables) :columns
                   (cons (cons column data-type) (plist-get (car tables) :columns)))))
    (dolist (table tables)
      (plist-put table :columns (nreverse (plist-get table :columns))))
    (nreverse tables)))

(defun devtools-sql-schema-load (conn profile &optional force callback)
  "Load the tables and columns of CONN in PROFILE in the background.
Does nothing if a load is already running, unless FORCE restarts it.
Call CALLBACK with no arguments once the schema is stored."
  (let* ((key (devtools-sql-schema--key conn profile))
         (running (gethash key devtools-sql-schema--loading))
         process)
    (when (and force (process-live-p running))
      (remhash key devtools-sql-schema--loading)
      (delete-process running))
    (unless (and (not force) (process-live-p running))
      (setq process
            (devtools-sql-psql-async
             conn profile devtools-sql-schema--query
             (lambda (exit-code output errors)
               ;; A load replaced by a forced one is stale.
               (when (eq process (gethash key devtools-sql-schema--loading))
                 (remhash key devtools-sql-schema--loading)
                 (if (not (zerop exit-code))
                     (message "devtools: could not load the schema of %s/%s: %s"
                              profile (plist-get conn :name)
                              (car (split-string (string-trim errors) "\n")))
                   (puthash key (devtools-sql-schema--parse output)
                            devtools-sql-schema--cache)
                   (when callback (funcall callback)))))))
      (puthash key process devtools-sql-schema--loading))))

(defun devtools-sql-schema (conn profile)
  "Return the tables of CONN in PROFILE, loading them if needed.
Waits up to `devtools-sql-schema-wait' seconds for a load to finish."
  (let ((key (devtools-sql-schema--key conn profile)))
    (when (eq (gethash key devtools-sql-schema--cache 'missing) 'missing)
      (devtools-sql-schema-load conn profile)
      (let ((deadline (+ (float-time) devtools-sql-schema-wait)))
        (while (and (gethash key devtools-sql-schema--loading)
                    (< (float-time) deadline))
          (accept-process-output nil 0.05))))
    (gethash key devtools-sql-schema--cache)))

;;; Reading the statement

(defconst devtools-sql-schema--not-alias
  '("where" "join" "inner" "left" "right" "full" "cross" "outer" "natural"
    "lateral" "on" "using" "group" "order" "limit" "offset" "having" "union"
    "except" "intersect" "set" "values" "returning" "window" "fetch" "for")
  "Words that can follow a table name without being its alias.")

(defun devtools-sql-schema--statement-tables (start end)
  "Return the tables named between START and END as (NAME . ALIAS) pairs."
  (let ((case-fold-search t)
        tables)
    (save-excursion
      (goto-char start)
      (while (re-search-forward
              (concat "\\_<\\(?:from\\|join\\|update\\|into\\)[ \t\n]+"
                      "\\([[:alnum:]_.\"]+\\)"
                      "\\(?:[ \t\n]+\\(?:as[ \t\n]+\\)?\\([[:alnum:]_]+\\)\\)?")
              end t)
        (let ((alias (match-string-no-properties 2)))
          (push (cons (string-replace "\"" "" (match-string-no-properties 1))
                      (unless (and alias (member (downcase alias) devtools-sql-schema--not-alias))
                        alias))
                tables))))
    (nreverse tables)))

(defun devtools-sql-schema--label (table)
  "Return how TABLE is written: bare in public, qualified elsewhere."
  (if (equal (plist-get table :schema) "public")
      (plist-get table :name)
    (concat (plist-get table :schema) "." (plist-get table :name))))

(defun devtools-sql-schema--find-table (tables name)
  "Return the table of TABLES called NAME, qualified or not."
  (let ((name (downcase name)))
    (seq-find (lambda (table)
                (or (equal name (downcase (plist-get table :name)))
                    (equal name (downcase (concat (plist-get table :schema) "."
                                                  (plist-get table :name))))))
              tables)))

;;; Candidates

(defun devtools-sql-schema--table-candidate (table &optional label)
  "Completion candidate for TABLE, written as LABEL if given."
  (propertize (or label (devtools-sql-schema--label table))
              'devtools-sql-annotation
              (if (equal (plist-get table :type) "VIEW") " view" " table")
              'devtools-sql-kind 'struct))

(defun devtools-sql-schema--column-candidates (table &optional show-table)
  "Completion candidates for the columns of TABLE.
With SHOW-TABLE, the annotation also names the table."
  (mapcar (lambda (column)
            (propertize (car column)
                        'devtools-sql-annotation
                        (concat " " (cdr column)
                                (when show-table
                                  (concat "  " (devtools-sql-schema--label table))))
                        'devtools-sql-kind 'field))
          (plist-get table :columns)))

(defun devtools-sql-schema--candidates (tables qualifier statement-tables)
  "Candidates from TABLES for an identifier after QUALIFIER (or nil).
STATEMENT-TABLES are the (NAME . ALIAS) pairs of the statement."
  (if qualifier
      (let* ((aliased (car (seq-find (lambda (entry)
                                       (and (cdr entry)
                                            (string-equal-ignore-case (cdr entry) qualifier)))
                                     statement-tables)))
             (table (devtools-sql-schema--find-table tables (or aliased qualifier))))
        (if table
            (devtools-sql-schema--column-candidates table)
          ;; A schema: its tables, without the schema prefix.
          (mapcar (lambda (table)
                    (devtools-sql-schema--table-candidate table (plist-get table :name)))
                  (seq-filter (lambda (table)
                                (string-equal-ignore-case (plist-get table :schema) qualifier))
                              tables))))
    (let ((used (delete-dups
                 (delq nil (mapcar (lambda (entry)
                                     (devtools-sql-schema--find-table tables (car entry)))
                                   statement-tables)))))
      (append (mapcan (lambda (table)
                        (devtools-sql-schema--column-candidates table (cdr used)))
                      used)
              (mapcar #'devtools-sql-schema--table-candidate tables)))))

(defun devtools-sql-schema-completion-at-point ()
  "Complete table and column names of the buffer's connection."
  (when (and devtools-sql-connection
             (not (nth 8 (syntax-ppss))))      ; not in a string or comment
    (let* ((end (point))
           (start (save-excursion (skip-chars-backward "[:alnum:]_") (point)))
           (qualifier
            (when (eq (char-before start) ?.)
              (save-excursion
                (goto-char (1- start))
                (string-replace "\"" ""
                                (buffer-substring-no-properties
                                 (progn (skip-chars-backward "[:alnum:]_\"") (point))
                                 (1- start))))))
           (statement (save-excursion
                        (cons (progn (backward-paragraph) (point))
                              (progn (forward-paragraph) (point)))))
           (tables (with-demoted-errors "devtools: %S"
                     (devtools-sql-schema devtools-sql-connection devtools-sql-profile))))
      (when tables
        (list start end
              (devtools-sql-schema--candidates
               tables qualifier
               (devtools-sql-schema--statement-tables (car statement) (cdr statement)))
              :exclusive 'no
              :annotation-function
              (lambda (candidate) (get-text-property 0 'devtools-sql-annotation candidate))
              :company-kind
              (lambda (candidate) (get-text-property 0 'devtools-sql-kind candidate)))))))

;;; Keeping it current

(defun devtools-sql-refresh-schema ()
  "Reload the tables and columns offered for completion in this buffer."
  (interactive)
  (unless devtools-sql-connection
    (user-error "Buffer is not linked to a connection"))
  (let ((conn devtools-sql-connection)
        (profile devtools-sql-profile))
    (devtools-sql-schema-load
     conn profile t
     (lambda () (message "Schema of %s/%s reloaded" profile (plist-get conn :name))))))

(defun devtools-sql-schema--after-execute (conn profile exit-code output)
  "Reload the schema of CONN in PROFILE after a successful DDL statement.
EXIT-CODE and OUTPUT come from psql."
  (when (and (zerop exit-code)
             (string-match-p "\\`\\(CREATE\\|ALTER\\|DROP\\|COMMENT\\)\\_>" output))
    (devtools-sql-schema-load conn profile t)))

(defun devtools-sql-schema--setup ()
  "Turn completion on or off with `devtools-sql-query-mode'."
  (if (not devtools-sql-query-mode)
      (remove-hook 'completion-at-point-functions
                   #'devtools-sql-schema-completion-at-point t)
    (add-hook 'completion-at-point-functions
              #'devtools-sql-schema-completion-at-point nil t)
    ;; Load it now so the first completion does not wait.
    (when (and devtools-sql-connection
               (eq (gethash (devtools-sql-schema--key devtools-sql-connection
                                                      devtools-sql-profile)
                            devtools-sql-schema--cache 'missing)
                   'missing))
      (with-demoted-errors "devtools: %S"
        (devtools-sql-schema-load devtools-sql-connection devtools-sql-profile)))))

(add-hook 'devtools-sql-query-mode-hook #'devtools-sql-schema--setup)
(add-hook 'devtools-sql-after-execute-functions #'devtools-sql-schema--after-execute)

;; Query files opened before this file was loaded.
(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when devtools-sql-query-mode
      (devtools-sql-schema--setup))))

(provide 'devtools-sql-schema)
;;; devtools-sql-schema.el ends here
