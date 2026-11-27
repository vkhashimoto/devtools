;;; devtools-test.el --- Tests for devtools  -*- lexical-binding: t; -*-

;; Run: emacs -Q --batch -L . -l test/devtools-test.el -f ert-run-tests-batch-and-exit
;; With DEVTOOLS_PG_PORT set (demo database running), the integration
;; test connects to Postgres too.

;;; Code:

(require 'ert)
(require 'devtools)

(defmacro devtools-test--with-profiles (&rest body)
  "Run BODY with sample profiles and a temporary authinfo file."
  (declare (indent 0))
  `(let* ((authinfo (make-temp-file "devtools-authinfo"))
          (auth-sources (list authinfo))
          (devtools--current-profile nil)
          (devtools-default-profile nil)
          (devtools-profiles
           '((local :postgres ((:name "app" :host "localhost"
                                :port ,(string-to-number (or (getenv "DEVTOOLS_PG_PORT") "54329"))
                                :user "dev" :database "app")))
             (empty)
             (prod :production t
                   :postgres ((:name "app" :host "pg.prod" :user "ro" :database "app")
                              (:name "writer" :host "pg.prod" :user "rw"
                               :database "app" :read-only nil))))))
     (unwind-protect
         (progn
           (with-temp-file authinfo
             (insert (format "machine localhost port %s login dev password devpass\n"
                             (or (getenv "DEVTOOLS_PG_PORT") "54329"))))
           (auth-source-forget-all-cached)
           ,@body)
       (delete-file authinfo)
       (auth-source-forget-all-cached))))

(defun devtools-test--conn (profile name)
  (seq-find (lambda (c) (equal (plist-get c :name) name))
            (devtools-env :postgres profile)))

(ert-deftest devtools-test-default-profile-is-first ()
  (devtools-test--with-profiles
    (should (eq (devtools-current-profile) 'local))
    (let ((devtools-default-profile 'prod))
      (should (eq (devtools-current-profile) 'prod)))))

(ert-deftest devtools-test-switch-profile ()
  (devtools-test--with-profiles
    (devtools-switch-profile 'prod)
    (should (eq (devtools-current-profile) 'prod))
    (should (devtools-production-p))
    (should (eq (get-text-property 1 'face (devtools-profile-label)) 'devtools-production))
    (should-error (devtools-switch-profile 'nope) :type 'user-error)))

(ert-deftest devtools-test-renamed-profile-falls-back ()
  (devtools-test--with-profiles
    (let ((devtools-profiles (copy-tree devtools-profiles)))
      (devtools-switch-profile 'prod)
      (setf (car (assq 'prod devtools-profiles)) 'production)
      (should (eq (devtools-current-profile) 'local)))))

(ert-deftest devtools-test-profile-with-empty-plist ()
  (devtools-test--with-profiles
    (should-not (devtools-env :postgres 'empty))
    (should-error (devtools-sql--connections 'empty) :type 'user-error)))

(ert-deftest devtools-test-no-profiles ()
  (let ((devtools-profiles nil) (devtools--current-profile nil) (devtools-default-profile nil))
    (should-error (devtools-current-profile) :type 'user-error)))

(ert-deftest devtools-test-read-only-rules ()
  (devtools-test--with-profiles
    (should-not (devtools-sql--read-only-p (devtools-test--conn 'local "app") 'local))
    (should (devtools-sql--read-only-p (devtools-test--conn 'prod "app") 'prod))
    ;; An explicit :read-only nil wins over the production default.
    (should-not (devtools-sql--read-only-p (devtools-test--conn 'prod "writer") 'prod))
    (let ((devtools-sql-read-only-in-production nil))
      (should-not (devtools-sql--read-only-p (devtools-test--conn 'prod "app") 'prod)))))

(ert-deftest devtools-test-environment ()
  (devtools-test--with-profiles
    (should (equal (devtools-sql--environment (devtools-test--conn 'local "app") 'local)
                   '("PGPASSWORD=devpass")))
    (should (equal (devtools-sql--environment (devtools-test--conn 'prod "app") 'prod)
                   '("PGOPTIONS=-c default_transaction_read_only=on")))))

(ert-deftest devtools-test-buffer-name ()
  (devtools-test--with-profiles
    (should (equal (devtools-sql--buffer-name (devtools-test--conn 'prod "app") 'prod)
                   "*SQL: prod/app*"))))

(ert-deftest devtools-test-mode-installs-and-removes-rules ()
  (let ((display-buffer-alist '(("other" display-buffer-same-window)))
        (mode-line-misc-info nil)
        (devtools--installed-display-rules nil))
    (devtools-mode 1)
    (should (assoc "\\`\\*SQL\\( Result\\)?: " display-buffer-alist))
    (should (member devtools--mode-line-entry mode-line-misc-info))
    (should (memq #'devtools-sql--profiles-watcher (get-variable-watchers 'devtools-profiles)))
    (devtools-mode 1)                   ; re-enabling must not duplicate
    (should (= (length display-buffer-alist) 2))
    (devtools-mode -1)
    (should (equal display-buffer-alist '(("other" display-buffer-same-window))))
    (should-not mode-line-misc-info)
    (should-not (memq #'devtools-sql--profiles-watcher (get-variable-watchers 'devtools-profiles)))))

;;; Result buffer

(defun devtools-test--response (&rest sets)
  "A query/execute reply holding SETS, as the server sends it."
  (list :elapsedMs 1 :results (vconcat sets)))

(defun devtools-test--table (columns rows &optional total)
  "A result set with COLUMNS (names) and ROWS (lists, nil for NULL)."
  (list :columns (vconcat (mapcar (lambda (name) (list :name name :type "text")) columns))
        :rows (vconcat (mapcar #'vconcat rows))
        :totalRows (or total (length rows))
        :command (format "SELECT %d" (or total (length rows)))))

(defmacro devtools-test--with-result (response &rest body)
  "Show the server RESPONSE in a result buffer and run BODY there."
  (declare (indent 1))
  `(let ((buffer (save-window-excursion
                   (devtools-sql-result-start '(:name "app") 'local #'ignore "select 1"))))
     (unwind-protect
         (let ((devtools-profiles '((local))))
           (devtools-sql-result-show buffer ,response 0.1)
           (with-current-buffer buffer ,@body))
       (kill-buffer buffer))))

(ert-deftest devtools-test-result-table-is-aligned ()
  (devtools-test--with-result
      (devtools-test--response
       (devtools-test--table '("id" "customer" "note")
                             '(("1" "acme" nil) ("22" "globex" "a|b") ("3" "initech" ""))))
    (should (equal (buffer-string)
                   (concat "| id | customer | note   |\n"
                           "|----+----------+--------|\n"
                           "|  1 | acme     | [NULL] |\n"
                           "| 22 | globex   | a¦b    |\n"
                           "|  3 | initech  |        |\n")))
    (should devtools-sql-result-mode)
    (should (equal devtools-sql-result--table-size '(3 . 3)))
    (should truncate-lines)
    (should buffer-read-only)
    (goto-char (point-min))
    (search-forward "[NULL]")
    (should (seq-some (lambda (o) (overlay-get o 'devtools-sql-result-null))
                      (overlays-at (1- (point)))))))

(ert-deftest devtools-test-result-command-and-statements ()
  (devtools-test--with-result
      (devtools-test--response (devtools-test--table '("n") '(("1")))
                               (list :totalRows 0 :command "UPDATE 3"))
    (should (equal (buffer-string) "UPDATE 3"))
    (should (string-match-p "(last of 2 results)" (devtools-sql-result--header-line))))
  (devtools-test--with-result (devtools-test--response)
    (should (equal (buffer-string) "No statements"))))

(ert-deftest devtools-test-result-error ()
  (let ((buffer (save-window-excursion
                  (devtools-sql-result-start '(:name "app") 'local #'ignore
                                             "select 1;\nselect nope from orders"))))
    (unwind-protect
        (with-current-buffer buffer
          (devtools-sql-result-show-error
           buffer '(:code -32001 :message "column \"nope\" does not exist"
                    :data (:sqlstate "42703" :position 18 :hint "Check the name."))
           0.1)
          (should (equal (buffer-string)
                         (concat "ERROR:  column \"nope\" does not exist\n"
                                 "LINE 2: select nope from orders\n"
                                 "               ^\n"
                                 "HINT:  Check the name.")))
          (should (eq (plist-get devtools-sql-result--info :state) 'failed))
          ;; `g' and the `?' menu still work after a failure.
          (should (eq (key-binding "g") #'devtools-sql-result-rerun))
          (should (eq (key-binding "?") #'devtools-sql-result-dispatch)))
      (kill-buffer buffer))))

(ert-deftest devtools-test-result-truncated ()
  (devtools-test--with-result
      (devtools-test--response (devtools-test--table '("n") '(("1") ("2")) 3))
    (should (equal devtools-sql-result--table-size '(2 . 1)))
    (should (eq (plist-get devtools-sql-result--info :total-rows) 3))
    (should (string-match-p "first 2 of 3 rows" (devtools-sql-result--header-line)))))

(ert-deftest devtools-test-result-copy ()
  (devtools-test--with-result
      (devtools-test--response
       (devtools-test--table '("id" "customer" "note") '(("1" "acme" nil) ("2" "globex" "x"))))
    (let ((kill-ring nil)
          (devtools-sql-result-copy-null-as "")
          (devtools-sql-result-copy-header nil)
          (devtools-sql-result-copy-delimiter "\t"))
      (goto-char (point-min))
      (forward-line 2)
      (org-table-goto-column 2)
      (devtools-sql-result-copy)
      (should (equal (car kill-ring) "acme"))
      (devtools-sql-result-copy-row)
      (should (equal (car kill-ring) "1\tacme\t"))
      (devtools-sql-result-mark-whole-column)
      (let ((devtools-sql-result-copy-header t))
        (devtools-sql-result-copy))
      (should (equal (car kill-ring) "customer\nacme\nglobex"))
      (devtools-sql-result-unmark-all)
      (should-not devtools-sql-result--marks))))

;;; Query files

(ert-deftest devtools-test-query-file-links-on-open ()
  (devtools-test--with-profiles
    (let* ((devtools-sql-query-directory (make-temp-file "devtools-sql" t))
           (file (devtools-sql--query-file (devtools-test--conn 'prod "writer") 'prod))
           (find-file-hook '(devtools-sql-link-query-file)))
      (unwind-protect
          (progn
            (make-directory (file-name-directory file) t)
            (write-region "" nil file)
            (with-current-buffer (find-file-noselect file)
              (unwind-protect
                  (progn
                    (should devtools-sql-query-mode)
                    (should (eq devtools-sql-profile 'prod))
                    (should (equal (plist-get devtools-sql-connection :name) "writer"))
                    (should (eq (key-binding (kbd "C-c C-c")) #'devtools-sql-run)))
                (kill-buffer))))
        (delete-directory devtools-sql-query-directory t)))))

;;; Against a running Postgres (DEVTOOLS_PG_PORT)

(defun devtools-test--server-p ()
  "Non-nil when the demo database and devtools-server are available."
  (and (getenv "DEVTOOLS_PG_PORT") (executable-find devtools-server-program)))

(defun devtools-test--wait-for-result (buffer)
  "Wait up to 10s for the query in result BUFFER to finish."
  (let ((deadline (+ (float-time) 10)))
    (while (and (< (float-time) deadline)
                (eq (plist-get (buffer-local-value 'devtools-sql-result--info buffer) :state)
                    'running))
      (accept-process-output nil 0.05))
    (plist-get (buffer-local-value 'devtools-sql-result--info buffer) :state)))

(defmacro devtools-test--with-query-file (&rest body)
  "Open the local/app query file and run BODY in it."
  (declare (indent 0))
  `(devtools-test--with-profiles
     (let* ((devtools-sql-query-directory (make-temp-file "devtools-sql" t))
            (conn (devtools-test--conn 'local "app"))
            (query-buf (save-window-excursion (devtools-sql-query conn))))
       (unwind-protect
           (with-current-buffer query-buf ,@body)
         (let ((result (get-buffer "*SQL Result: local/app*")))
           (when result (kill-buffer result)))
         (with-current-buffer query-buf (set-buffer-modified-p nil))
         (kill-buffer query-buf)
         (delete-directory devtools-sql-query-directory t)))))

(ert-deftest devtools-test-postgres-run-into-result ()
  (skip-unless (devtools-test--server-p))
  (devtools-test--with-query-file
    (insert "select id, customer,\n       total\nfrom orders\norder by id;\n\nselect 1;\n")
    (goto-char (point-min))
    (save-window-excursion (call-interactively #'devtools-sql-run))
    (let ((result (get-buffer "*SQL Result: local/app*")))
      (should (eq (devtools-test--wait-for-result result) 'done))
      (with-current-buffer result
        (should (equal (buffer-string)
                       (concat "| id | customer |  total |\n"
                               "|----+----------+--------|\n"
                               "|  1 | acme     | 120.50 |\n"
                               "|  2 | globex   |  89.90 |\n"
                               "|  3 | initech  |  42.00 |\n")))
        (should (eq (plist-get devtools-sql-result--info :total-rows) 3))
        ;; `g' runs the same query again.
        (save-window-excursion (devtools-sql-result-rerun))
        (should (eq (devtools-test--wait-for-result result) 'done))
        (should (string-match-p "initech" (buffer-string)))))))

(defun devtools-test--server-call (method params)
  "Send METHOD with PARAMS to the server and wait; return (RESULT . ERROR)."
  (let (reply)
    (devtools-server-request method params (lambda (result error) (setq reply (cons result error))))
    (let ((deadline (+ (float-time) 10)))
      (while (and (not reply) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    reply))

(defun devtools-test--run (query &optional other)
  "Run QUERY in the current query buffer, wait, and return the result buffer."
  (save-window-excursion (devtools-sql-run-string query other))
  (let ((result (get-buffer "*SQL Result: local/app*")))
    (devtools-test--wait-for-result result)
    result))

(defun devtools-test--result-text (buffer)
  (with-current-buffer buffer (buffer-string)))

(defun devtools-test--result-header (buffer)
  (with-current-buffer buffer (devtools-sql-result--header-line)))

(defun devtools-test--change-local-app (key value)
  "Set KEY to VALUE in the local/app connection of the profiles."
  (setq devtools-profiles (copy-tree devtools-profiles))
  (let ((conns (plist-get (cdr (assq 'local devtools-profiles)) :postgres)))
    (setcar conns (plist-put (copy-sequence (car conns)) key value))))

(ert-deftest devtools-test-postgres-errors-and-read-only ()
  (skip-unless (devtools-test--server-p))
  (devtools-test--with-query-file
    (let ((result (devtools-test--run "select nope from orders")))
      (should (eq (plist-get (buffer-local-value 'devtools-sql-result--info result) :state) 'failed))
      (should (string-match-p "column \"nope\" does not exist" (devtools-test--result-text result)))
      ;; Made read-only in the profile: the next run reopens (no session
      ;; state to lose, so without asking) and writes are refused.
      (devtools-test--change-local-app :read-only t)
      (should (string-match-p "read-only transaction"
                              (devtools-test--result-text (devtools-test--run "delete from orders"))))
      (should (string-match-p "read-only" (devtools-sql--header-line)))
      (devtools-test--change-local-app :read-only nil)
      (should (equal (devtools-test--result-text (devtools-test--run "update orders set status = status"))
                     "UPDATE 3")))))

(ert-deftest devtools-test-postgres-rerun-discards-stale-result ()
  (skip-unless (devtools-test--server-p))
  (devtools-test--with-query-file
    ;; On the pool; a session would refuse the second query as busy.
    (save-window-excursion
      (devtools-sql-run-string "select pg_sleep(2), 'slow' as which" t)
      (devtools-sql-run-string "select 'fast' as which" t))
    (let ((result (get-buffer "*SQL Result: local/app*")))
      (should (eq (devtools-test--wait-for-result result) 'done))
      (accept-process-output nil 0.3)
      (should (string-match-p "fast" (with-current-buffer result (buffer-string))))
      (should-not (string-match-p "slow" (with-current-buffer result (buffer-string)))))))

(ert-deftest devtools-test-postgres-server-features ()
  (skip-unless (devtools-test--server-p))
  (devtools-test--with-query-file
    (let ((result (lambda () (get-buffer "*SQL Result: local/app*"))))
      ;; NULL and the empty string differ.
      (save-window-excursion (devtools-sql-run-string "select null::text as a, '' as b"))
      (should (eq (devtools-test--wait-for-result (funcall result)) 'done))
      (should (equal (with-current-buffer (funcall result) (buffer-string))
                     "| a      | b |\n|--------+---|\n| [NULL] |   |\n"))
      ;; Errors point at the failing spot.
      (save-window-excursion (devtools-sql-run-string "select 1;\nselect nope from orders"))
      (should (eq (devtools-test--wait-for-result (funcall result)) 'failed))
      (should (string-match-p "^LINE 2: select nope from orders\n +\\^$"
                              (with-current-buffer (funcall result) (buffer-string))))
      ;; After the server is stopped, the next query starts it and reopens
      ;; the connection.
      (devtools-server-stop)
      (save-window-excursion (devtools-sql-run-string "select 'back' as state"))
      (should (eq (devtools-test--wait-for-result (funcall result)) 'done))
      (should (string-match-p "back" (with-current-buffer (funcall result) (buffer-string)))))))

(ert-deftest devtools-test-postgres-repl ()
  (skip-unless (getenv "DEVTOOLS_PG_PORT"))
  (devtools-test--with-profiles
    (let* ((conn (devtools-test--conn 'local "app"))
           (repl (save-window-excursion (devtools-sql--start conn 'local))))
      (unwind-protect
          (progn
            (should (comint-check-proc repl))
            (should (eq (devtools-sql--start conn 'local) repl)))
        (let ((kill-buffer-query-functions nil)) (kill-buffer repl))))))

;;; Completion

(defconst devtools-test--describe-reply
  '(:tables [(:schema "public" :name "orders" :type "BASE TABLE"
             :columns [(:name "id" :type "integer") (:name "customer" :type "text")])
            (:schema "public" :name "customers" :type "BASE TABLE"
             :columns [(:name "id" :type "integer") (:name "email" :type "text")])
            (:schema "sales" :name "leads" :type "VIEW"
             :columns [(:name "score" :type "numeric")])])
  "A schema/describe reply, as the server sends it.")

(ert-deftest devtools-test-schema-tables ()
  (should (equal (devtools-sql-schema--tables devtools-test--describe-reply)
                 '((:schema "public" :name "orders" :type "BASE TABLE"
                    :columns (("id" . "integer") ("customer" . "text")))
                   (:schema "public" :name "customers" :type "BASE TABLE"
                    :columns (("id" . "integer") ("email" . "text")))
                   (:schema "sales" :name "leads" :type "VIEW"
                    :columns (("score" . "numeric")))))))

(ert-deftest devtools-test-schema-statement-tables ()
  (with-temp-buffer
    (insert "select o.id\nfrom orders o\njoin public.customers as c on c.id = o.id\n"
            "left join items where x = 1")
    (should (equal (devtools-sql-schema--statement-tables (point-min) (point-max))
                   '(("orders" . "o") ("public.customers" . "c") ("items"))))))

(defun devtools-test--complete (text)
  "Return the completions at `|' in TEXT, with fake schema data."
  (let ((devtools-sql-schema--cache (make-hash-table :test #'equal)))
    (puthash '(local . "app") (devtools-sql-schema--tables devtools-test--describe-reply)
             devtools-sql-schema--cache)
    (with-temp-buffer
      (sql-mode)
      (setq devtools-sql-connection '(:name "app") devtools-sql-profile 'local)
      (insert text)
      (goto-char (point-min))
      (search-forward "|")
      (delete-char -1)
      (when-let* ((capf (devtools-sql-schema-completion-at-point)))
        (pcase-let ((`(,start ,end ,candidates . ,props) capf))
          (list (buffer-substring start end)
                (mapcar (lambda (c) (concat c (funcall (plist-get props :annotation-function) c)))
                        candidates)))))))

(ert-deftest devtools-test-complete-columns-after-alias ()
  (should (equal (devtools-test--complete "select o.cu| from orders o")
                 '("cu" ("id integer" "customer text")))))

(ert-deftest devtools-test-complete-columns-after-table ()
  (should (equal (cadr (devtools-test--complete "select customers.| from customers"))
                 '("id integer" "email text"))))

(ert-deftest devtools-test-complete-tables-of-schema ()
  (should (equal (devtools-test--complete "select * from sales.|")
                 '("" ("leads view")))))

(ert-deftest devtools-test-complete-tables-and-statement-columns ()
  ;; Columns of the statement's tables first, then every table.
  (should (equal (cadr (devtools-test--complete "select | from orders"))
                 '("id integer" "customer text"
                   "orders table" "customers table" "sales.leads view")))
  ;; With several tables, columns name their table.
  (should (member "email text  customers"
                  (cadr (devtools-test--complete
                         "select | from orders o join customers c on c.id = o.id")))))

(ert-deftest devtools-test-complete-not-in-strings ()
  (should-not (devtools-test--complete "select 'o.|' from orders o")))

(defun devtools-test--wait-for-schema (conn profile)
  "Wait up to 10s for the schema of CONN in PROFILE to load."
  (let ((key (devtools-sql-schema--key conn profile))
        (deadline (+ (float-time) 10)))
    (while (and (gethash key devtools-sql-schema--loading) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (gethash key devtools-sql-schema--cache)))

(ert-deftest devtools-test-postgres-schema-completion ()
  (skip-unless (devtools-test--server-p))
  (let ((devtools-sql-schema--cache (make-hash-table :test #'equal))
        (devtools-sql-schema--loading (make-hash-table :test #'equal)))
    (devtools-test--with-query-file
      ;; Opening the file starts loading the schema.
      (should (gethash '(local . "app") devtools-sql-schema--loading))
      (should (equal (plist-get (devtools-sql-schema--find-table
                                 (devtools-test--wait-for-schema conn 'local) "orders")
                                :columns)
                     '(("id" . "integer") ("customer" . "text") ("total" . "numeric")
                       ("status" . "text") ("created_at" . "timestamp with time zone"))))
      (insert "select o.sta from orders o")
      (goto-char (point-min))
      (search-forward "o.sta")
      (should (member "status" (nth 2 (devtools-sql-schema-completion-at-point)))))))

(ert-deftest devtools-test-postgres-schema-reloads-after-ddl ()
  (skip-unless (devtools-test--server-p))
  (let ((devtools-sql-schema--cache (make-hash-table :test #'equal))
        (devtools-sql-schema--loading (make-hash-table :test #'equal)))
    (devtools-test--with-query-file
      (let ((result (lambda () (get-buffer "*SQL Result: local/app*"))))
        (unwind-protect
            (progn
              (devtools-test--wait-for-schema conn 'local)
              (save-window-excursion
                (devtools-sql-run-string "create table devtools_tmp (note text)"))
              (should (eq (devtools-test--wait-for-result (funcall result)) 'done))
              (should (devtools-sql-schema--find-table
                       (devtools-test--wait-for-schema conn 'local) "devtools_tmp")))
          (save-window-excursion
            (devtools-sql-run-string "drop table if exists devtools_tmp"))
          (devtools-test--wait-for-result (funcall result))
          (should-not (devtools-sql-schema--find-table
                       (devtools-test--wait-for-schema conn 'local) "devtools_tmp")))))))

;;; Sessions

(ert-deftest devtools-test-use-session-p ()
  (let ((devtools-sql-query-files-use-session t))
    (should (devtools-sql--use-session-p nil))
    (should-not (devtools-sql--use-session-p '(4))))
  (let ((devtools-sql-query-files-use-session nil))
    (should-not (devtools-sql--use-session-p nil))
    (should (devtools-sql--use-session-p '(4)))))

(ert-deftest devtools-test-session-header-lines ()
  (devtools-test--with-profiles
    (with-temp-buffer
      (devtools-sql--mark-buffer (devtools-test--conn 'local "app") 'local)
      (should-not (string-match-p "transaction" (devtools-sql--header-line)))
      (setq devtools-sql--tx-status "transaction")
      (should (string-match-p "in transaction" (devtools-sql--header-line)))
      (setq devtools-sql--tx-status "failed")
      (should (string-match-p "transaction failed" (devtools-sql--header-line)))))
  (devtools-test--with-result (devtools-test--response (devtools-test--table '("n") '(("1"))))
    (setq devtools-sql-result--info (plist-put devtools-sql-result--info :target 'pool))
    (should (string-match-p "  pool" (devtools-sql-result--header-line)))
    (setq devtools-sql-result--info (plist-put (plist-put devtools-sql-result--info :target 'session)
                                               :tx "transaction"))
    (should (string-match-p "session · in transaction" (devtools-sql-result--header-line)))))

(ert-deftest devtools-test-postgres-session-keeps-state ()
  (skip-unless (devtools-test--server-p))
  (devtools-test--with-query-file
    (let ((result (devtools-test--run "begin")))
      (should (string-match-p "session · in transaction" (devtools-test--result-header result)))
      (should (equal devtools-sql--tx-status "transaction"))
      (should (string-match-p "in transaction" (devtools-sql--header-line)))
      (devtools-test--run "create temp table notes (x int); insert into notes values (7)")
      ;; The session sees its uncommitted temp table; a pooled run does not.
      (should (string-match-p "| 7 |" (devtools-test--result-text (devtools-test--run "select x from notes"))))
      (setq result (devtools-test--run "select x from notes" t))
      (should (eq (plist-get (buffer-local-value 'devtools-sql-result--info result) :state) 'failed))
      (should (string-match-p "  pool" (devtools-test--result-header result)))
      ;; An error fails the transaction, and both header lines say so.
      (setq result (devtools-test--run "select nope"))
      (should (string-match-p "transaction failed" (devtools-test--result-header result)))
      (should (equal devtools-sql--tx-status "failed"))
      (devtools-test--run "rollback")
      (should (equal devtools-sql--tx-status "idle"))
      (should-not (string-match-p "transaction" (devtools-sql--header-line))))))

(ert-deftest devtools-test-postgres-session-busy ()
  (skip-unless (devtools-test--server-p))
  (devtools-test--with-query-file
    (save-window-excursion (devtools-sql-run-string "select pg_sleep(1)"))
    ;; The session is busy: refused at once, the running query is kept.
    (should-error (devtools-sql-run-string "select 1") :type 'user-error)
    (should (eq (plist-get (buffer-local-value 'devtools-sql-result--info
                                               (get-buffer "*SQL Result: local/app*"))
                           :state)
                'running))
    (let ((result (get-buffer "*SQL Result: local/app*")))
      (should (eq (devtools-test--wait-for-result result) 'done))
      (should (string-match-p "pg_sleep" (devtools-test--result-text result))))
    ;; Free again.
    (should (eq (plist-get (buffer-local-value 'devtools-sql-result--info
                                               (devtools-test--run "select 1"))
                           :state)
                'done))))

(ert-deftest devtools-test-postgres-session-closes-with-buffer ()
  (skip-unless (devtools-test--server-p))
  (let (session)
    (devtools-test--with-query-file
      (devtools-test--run "select 1")
      (setq session (cdr devtools-sql--session))
      (should session))
    ;; The macro killed the query buffer, which closed its session.
    (let ((reply (devtools-test--server-call "query/execute" (list :session session :sql "select 1"))))
      (should (eq (plist-get (cdr reply) :code) -32003)))))

(ert-deftest devtools-test-postgres-session-after-server-stop ()
  (skip-unless (devtools-test--server-p))
  (devtools-test--with-query-file
    (devtools-test--run "create temp table notes (x int)")
    (devtools-server-stop)
    ;; A new session: the temp table is gone.
    (let ((result (devtools-test--run "select * from notes")))
      (should (string-match-p "relation \"notes\" does not exist" (devtools-test--result-text result))))
    (should (eql (car devtools-sql--session) (devtools-server-generation)))))

(ert-deftest devtools-test-postgres-session-lost ()
  (skip-unless (devtools-test--server-p))
  (devtools-test--with-query-file
    (let* ((result (devtools-test--run "select pg_backend_pid()"))
           (pid (with-current-buffer result
                  (goto-char (point-min)) (forward-line 2)
                  (string-trim (cadr (split-string (thing-at-point 'line t) "|"))))))
      (devtools-test--run (format "select pg_terminate_backend(%s)" pid) t)
      (setq result (devtools-test--run "select 1"))
      (should (string-match-p "Run again to start a new session" (devtools-test--result-text result)))
      (should-not devtools-sql--session)
      (setq result (devtools-test--run "select 'again' as state"))
      (should (string-match-p "again" (devtools-test--result-text result))))))

(ert-deftest devtools-test-postgres-pool-by-default-when-sessions-off ()
  (skip-unless (devtools-test--server-p))
  (devtools-test--with-query-file
    (let ((devtools-sql-query-files-use-session nil))
      (should (string-match-p "  pool" (devtools-test--result-header (devtools-test--run "select 1"))))
      (should-not devtools-sql--session)
      (should (string-match-p "  session" (devtools-test--result-header (devtools-test--run "select 1" t)))))))

;;; Profile changes and open connections

(ert-deftest devtools-test-settings-changes ()
  (let ((old '(:driver "postgres" :host "localhost" :port 54329 :user "dev"
               :password "a" :database "app" :readOnly :json-false)))
    (should-not (devtools-sql--settings-changes old old))
    (should-not (devtools-sql--settings-changes old (plist-put (copy-sequence old) :password "b")))
    (should (equal (devtools-sql--settings-changes old (plist-put (copy-sequence old) :readOnly t))
                   "read-only: off → on"))
    (should (equal (devtools-sql--settings-changes
                    old (thread-first (copy-sequence old)
                                      (plist-put :host "pg.staging") (plist-put :port 0)))
                   "host: localhost → pg.staging, port: 54329 → default"))))

(ert-deftest devtools-test-current-connection ()
  (devtools-test--with-profiles
    (let ((linked (devtools-test--conn 'local "app")))
      (devtools-test--change-local-app :read-only t)
      (should (eq (plist-get (devtools-sql--current-connection linked 'local) :read-only) t))
      ;; A connection no longer in the profile stays as it was.
      (let ((gone (list :name "gone")))
        (should (eq (devtools-sql--current-connection gone 'local) gone))))))

(defmacro devtools-test--answering (answer &rest body)
  "Run BODY with `y-or-n-p' answering ANSWER; return the prompts asked."
  (declare (indent 1))
  `(let (prompts)
     (cl-letf (((symbol-function 'y-or-n-p)
                (lambda (prompt) (push prompt prompts) ,answer)))
       ,@body)
     (nreverse prompts)))

(ert-deftest devtools-test-postgres-reopen-without-state-is-silent ()
  (skip-unless (devtools-test--server-p))
  (devtools-test--with-query-file
    (devtools-test--run "select 1")
    (let ((session (cdr devtools-sql--session)))
      (devtools-test--change-local-app :read-only t)
      (should-not (devtools-test--answering nil
                    ;; A new session, without any "session gone" error.
                    (should (string-match-p "read-only"
                                            (devtools-test--result-text
                                             (devtools-test--run "delete from orders where false"))))))
      (should-not (equal (cdr devtools-sql--session) session)))))

(ert-deftest devtools-test-postgres-reopen-with-state-asks ()
  (skip-unless (devtools-test--server-p))
  (devtools-test--with-query-file
    (devtools-test--run "create temp table notes (x int); begin")
    (let ((session (cdr devtools-sql--session)))
      (devtools-test--change-local-app :read-only t)
      ;; Declined: same session, old settings, transaction still open.
      (let ((prompts (devtools-test--answering nil
                       (devtools-test--run "insert into notes values (1)"))))
        (should (length= prompts 1))
        (should (string-match-p "Settings of local/app changed (read-only: off → on)" (car prompts)))
        (should (string-match-p "app.sql: open transaction, temp table notes" (car prompts))))
      (should (equal (cdr devtools-sql--session) session))
      (should (equal devtools-sql--tx-status "transaction"))
      ;; Asked again on the next run; accepted: a new session, read-only.
      (should (length= (devtools-test--answering t (devtools-test--run "select 1")) 1))
      (should-not (equal (cdr devtools-sql--session) session))
      (should (equal devtools-sql--tx-status "idle"))
      (should (string-match-p "read-only"
                              (devtools-test--result-text
                               (devtools-test--run "delete from orders where false")))))))

(ert-deftest devtools-test-postgres-password-change-keeps-session ()
  (skip-unless (devtools-test--server-p))
  (devtools-test--with-query-file
    (let ((authinfo (car auth-sources))
          (port (getenv "DEVTOOLS_PG_PORT")))
      (unwind-protect
          (progn
            (devtools-test--run "create temp table notes (x int)")
            (let ((session (cdr devtools-sql--session)))
              (devtools-test--run "alter role dev password 'rotated'")
              (with-temp-file authinfo
                (insert (format "machine localhost port %s login dev password rotated\n" port)))
              (auth-source-forget-all-cached)
              (should-not (devtools-test--answering nil
                            (should (string-match-p "| x |" (devtools-test--result-text
                                                             (devtools-test--run "select * from notes"))))))
              (should (equal (cdr devtools-sql--session) session))
              ;; New connections use the new password.
              (should (equal (devtools-test--result-text (devtools-test--run "select 'pool' as via" t))
                             "| via  |\n|------|\n| pool |\n"))))
        (devtools-server-call "query/execute" (list :connection "local/app"
                                                    :sql "alter role dev password 'devpass'"))
        (with-temp-file authinfo
          (insert (format "machine localhost port %s login dev password devpass\n" port)))
        (auth-source-forget-all-cached)))))

(ert-deftest devtools-test-postgres-background-never-reopens ()
  (skip-unless (devtools-test--server-p))
  (let ((devtools-sql-schema--cache (make-hash-table :test #'equal))
        (devtools-sql-schema--loading (make-hash-table :test #'equal)))
    (devtools-test--with-query-file
      (devtools-test--run "begin")
      (devtools-test--change-local-app :read-only t)
      (should-not (devtools-test--answering nil
                    (devtools-sql-schema-load (devtools-sql--current-connection conn 'local) 'local t)
                    (devtools-test--wait-for-schema conn 'local)))
      (should (eq (plist-get (devtools-server-opened-params "local/app") :readOnly) :json-false))
      (should (equal devtools-sql--tx-status "transaction")))))

(defun devtools-test--messages-after (thunk)
  "Call THUNK, let timers run, and return the messages shown meanwhile."
  (let (messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest args)
                 (when format (push (apply #'format-message format args) messages)))))
      (funcall thunk)
      (accept-process-output nil 0.1))
    (nreverse messages)))

(ert-deftest devtools-test-postgres-profile-watcher ()
  (skip-unless (devtools-test--server-p))
  (devtools-test--with-query-file
    (devtools-test--run "select 1")
    (let ((devtools-mode-was devtools-mode))
      (unwind-protect
          (progn
            (devtools-mode 1)
            ;; Nothing relevant changed: quiet.
            (should-not (seq-find (lambda (m) (string-prefix-p "devtools:" m))
                                  (devtools-test--messages-after
                                   (lambda () (setq devtools-profiles (copy-tree devtools-profiles))))))
            (let ((messages (devtools-test--messages-after
                             (lambda () (devtools-test--change-local-app :read-only t)))))
              (should (member "devtools: local/app settings changed (read-only: off → on); the next run reopens it, asking first if a session holds state"
                              messages)))
            ;; The connection itself was not touched.
            (should (eq (plist-get (devtools-server-opened-params "local/app") :readOnly) :json-false))
            (let ((messages (devtools-test--messages-after
                             (lambda () (setq devtools-profiles
                                              (assq-delete-all 'local (copy-tree devtools-profiles)))))))
              (should (seq-find (lambda (m) (string-match-p "local/app is no longer in the profiles" m))
                                messages))))
        (unless devtools-mode-was (devtools-mode -1))))))

;;; Several query files per datasource

(ert-deftest devtools-test-query-file-paths ()
  (let ((devtools-sql-query-directory "/q/"))
    (should (equal (devtools-sql--query-file '(:name "app") 'prod) "/q/prod/app.sql"))
    (should (equal (devtools-sql--query-file '(:name "app") 'prod "cleanup") "/q/prod/app/cleanup.sql")))
  (should (equal (devtools-sql-result-buffer-name '(:name "app") 'prod) "*SQL Result: prod/app*"))
  (should (equal (devtools-sql-result-buffer-name '(:name "app") 'prod "cleanup")
                 "*SQL Result: prod/app/cleanup*")))

(ert-deftest devtools-test-named-query-file-links-on-open ()
  (devtools-test--with-profiles
    (let* ((devtools-sql-query-directory (make-temp-file "devtools-sql" t))
           (file (devtools-sql--query-file (devtools-test--conn 'prod "writer") 'prod "cleanup"))
           (find-file-hook '(devtools-sql-link-query-file)))
      (unwind-protect
          (progn
            (make-directory (file-name-directory file) t)
            (write-region "" nil file)
            (write-region "" nil (expand-file-name "other.sql" (file-name-directory file)))
            (should (equal (sort (devtools-sql--query-names (devtools-test--conn 'prod "writer") 'prod)
                                 #'string<)
                           '("cleanup" "other")))
            (with-current-buffer (find-file-noselect file)
              (unwind-protect
                  (progn
                    (should devtools-sql-query-mode)
                    (should (equal (plist-get devtools-sql-connection :name) "writer"))
                    (should (equal devtools-sql-query-name "cleanup"))
                    (should (string-match-p "writer/cleanup" (devtools-sql--header-line))))
                (kill-buffer))))
        (delete-directory devtools-sql-query-directory t)))))

(ert-deftest devtools-test-read-query-name ()
  (devtools-test--with-profiles
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) " cleanup ")))
      (should (equal (devtools-sql--read-query-name (devtools-test--conn 'local "app") 'local) "cleanup")))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "a/b")))
      (should-error (devtools-sql--read-query-name (devtools-test--conn 'local "app") 'local)
                    :type 'user-error))))

(ert-deftest devtools-test-postgres-query-files-are-independent ()
  (skip-unless (devtools-test--server-p))
  (devtools-test--with-profiles
    (let* ((devtools-sql-query-directory (make-temp-file "devtools-sql" t))
           (conn (devtools-test--conn 'local "app"))
           (default (save-window-excursion (devtools-sql-query conn)))
           (named (save-window-excursion (devtools-sql-query conn "report"))))
      (unwind-protect
          (progn
            (should (string-suffix-p "/local/app/report.sql" (buffer-file-name named)))
            (with-current-buffer default
              (save-window-excursion (devtools-sql-run-string "begin")))
            (with-current-buffer named
              (save-window-excursion (devtools-sql-run-string "select 'report' as source")))
            (let ((default-result (get-buffer "*SQL Result: local/app*"))
                  (named-result (get-buffer "*SQL Result: local/app/report*")))
              (should (eq (devtools-test--wait-for-result default-result) 'done))
              (should (eq (devtools-test--wait-for-result named-result) 'done))
              (should (string-match-p "report" (devtools-test--result-text named-result)))
              (should (string-match-p "local  app/report  1 rows" (devtools-test--result-header named-result))))
            ;; Separate sessions: the transaction is only in the default file.
            (should (equal (buffer-local-value 'devtools-sql--tx-status default) "transaction"))
            (should (equal (buffer-local-value 'devtools-sql--tx-status named) "idle"))
            (should-not (equal (buffer-local-value 'devtools-sql--session default)
                               (buffer-local-value 'devtools-sql--session named))))
        (dolist (buffer (list default named
                              (get-buffer "*SQL Result: local/app*")
                              (get-buffer "*SQL Result: local/app/report*")))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))
        (delete-directory devtools-sql-query-directory t)))))

;;; Descriptions and finding query files

(defun devtools-test--write (file text)
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent))

(ert-deftest devtools-test-file-description ()
  (let ((file (make-temp-file "devtools-desc" nil ".sql")))
    (unwind-protect
        (progn
          (devtools-test--write file "--  Monthly revenue  \nselect 1;\n")
          (should (equal (devtools-sql--file-description file) "Monthly revenue"))
          (devtools-test--write file "---Cleanup\n")
          (should (equal (devtools-sql--file-description file) "Cleanup"))
          (devtools-test--write file "select 1; -- not a description\n")
          (should-not (devtools-sql--file-description file))
          (devtools-test--write file "--\nselect 1;\n")
          (should-not (devtools-sql--file-description file))
          (devtools-test--write file "")
          (should-not (devtools-sql--file-description file)))
      (delete-file file))))

(ert-deftest devtools-test-new-query-file-gets-description ()
  (devtools-test--with-profiles
    (let ((devtools-sql-query-directory (make-temp-file "devtools-sql" t))
          (conn (devtools-test--conn 'local "app")))
      (unwind-protect
          (let ((buffer (save-window-excursion (devtools-sql-query conn "report" "Monthly revenue"))))
            (with-current-buffer buffer
              (should (equal (buffer-string) "-- Monthly revenue\n\n"))
              (should (eobp))
              (kill-buffer))
            ;; An existing file keeps its first line.
            (setq buffer (save-window-excursion (devtools-sql-query conn "report" "Something else")))
            (with-current-buffer buffer
              (should (equal (buffer-string) "-- Monthly revenue\n\n"))
              (kill-buffer)))
        (delete-directory devtools-sql-query-directory t)))))

(ert-deftest devtools-test-find-query-file ()
  (devtools-test--with-profiles
    (let* ((devtools-sql-query-directory (make-temp-file "devtools-sql" t))
           (app (devtools-test--conn 'local "app"))
           (writer (devtools-test--conn 'prod "writer"))
           collection)
      (unwind-protect
          (progn
            (devtools-test--write (devtools-sql--query-file app 'local) "select 1;\n")
            (devtools-test--write (devtools-sql--query-file app 'local "cleanup")
                                  "-- Delete orphaned sessions older than 30 days\n")
            (devtools-test--write (devtools-sql--query-file app 'local "report") "select 2;\n")
            (devtools-test--write (devtools-sql--query-file writer 'prod "fix") "-- Fix totals\n")
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt candidates &rest _)
                         (setq collection (mapcar (lambda (c) (substring-no-properties (car c)))
                                                  candidates))
                         ;; Pick the file whose description mentions "orphaned".
                         (seq-find (lambda (c) (string-match-p "orphaned" c)) collection))))
              (let ((buffer (save-window-excursion (devtools-sql-find-file))))
                (should (equal collection
                               '("app          (default file)"
                                 "app/cleanup  Delete orphaned sessions older than 30 days"
                                 "app/report")))
                (with-current-buffer buffer
                  (should (string-suffix-p "/local/app/cleanup.sql" buffer-file-name))
                  (should devtools-sql-query-mode)
                  (should (equal devtools-sql-query-name "cleanup"))
                  (kill-buffer))))
            ;; Every environment, prefixed with its name.
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt candidates &rest _)
                         (setq collection (mapcar (lambda (c) (substring-no-properties (car c)))
                                                  candidates))
                         (car collection))))
              (kill-buffer (save-window-excursion (devtools-sql-find-file t)))
              (should (member "prod/writer/fix    Fix totals" collection))
              (should (member "local/app/report" collection))))
        (delete-directory devtools-sql-query-directory t)))))

(ert-deftest devtools-test-find-query-file-without-datasources ()
  (devtools-test--with-profiles
    (let ((devtools--current-profile 'empty))
      (should-error (devtools-sql-find-file) :type 'user-error))))

(ert-deftest devtools-test-find-lists-default-files-not-created-yet ()
  (devtools-test--with-profiles
    (let ((devtools-sql-query-directory (make-temp-file "devtools-sql" t))
          collection)
      (unwind-protect
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt candidates &rest _)
                       (setq collection (mapcar (lambda (c) (substring-no-properties (car c)))
                                                candidates))
                       (seq-find (lambda (c) (string-prefix-p "prod/writer " c)) collection))))
            (let ((buffer (save-window-excursion (devtools-sql-find-file t))))
              (should (equal collection
                             '("local/app    (default file)"
                               "prod/app     (default file)"
                               "prod/writer  (default file)")))
              (with-current-buffer buffer
                (should (string-suffix-p "/prod/writer.sql" buffer-file-name))
                (should (equal (plist-get devtools-sql-connection :name) "writer"))
                (should (eq devtools-sql-profile 'prod))
                (kill-buffer))))
        (delete-directory devtools-sql-query-directory t)))))

(ert-deftest devtools-test-menu-commands-without-prefix ()
  (devtools-test--with-profiles
    (let ((devtools-sql-query-directory (make-temp-file "devtools-sql" t)))
      (unwind-protect
          (progn
            ;; The named file entry asks for a name, as C-u C-c d q would.
            (cl-letf (((symbol-function 'devtools-sql--read-connection)
                       (lambda () (devtools-test--conn 'local "app")))
                      ((symbol-function 'completing-read) (lambda (&rest _) "report"))
                      ((symbol-function 'read-string) (lambda (&rest _) "Monthly revenue")))
              (with-current-buffer (save-window-excursion (devtools-sql-query-named))
                (should (string-suffix-p "/local/app/report.sql" buffer-file-name))
                (should (equal (buffer-string) "-- Monthly revenue\n\n"))
                (kill-buffer)))
            ;; Finding everywhere lists other environments too.
            (let (collection)
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt candidates &rest _)
                           (setq collection (mapcar (lambda (c) (substring-no-properties (car c)))
                                                    candidates))
                           (car collection))))
                (kill-buffer (save-window-excursion (devtools-sql-find-file-everywhere))))
              (should (seq-find (lambda (c) (string-prefix-p "prod/writer" c)) collection))))
        (delete-directory devtools-sql-query-directory t)))))

(ert-deftest devtools-test-menu-entries ()
  (dolist (command '(devtools-sql-query devtools-sql-query-named
                     devtools-sql-find-file devtools-sql-find-file-everywhere))
    (should (transient-get-suffix 'devtools-menu command))))

;;; devtools-test.el ends here
