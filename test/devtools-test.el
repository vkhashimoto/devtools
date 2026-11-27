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
    (devtools-mode 1)                   ; re-enabling must not duplicate
    (should (= (length display-buffer-alist) 2))
    (devtools-mode -1)
    (should (equal display-buffer-alist '(("other" display-buffer-same-window))))
    (should-not mode-line-misc-info)))

;;; Result buffer

(ert-deftest devtools-test-parse-csv ()
  (should (equal (devtools-sql-result-parse-csv
                  "a,b,c\n1,,\"x,\"\"y\"\"\"\n\"l1\nl2\",[NULL],z\n")
                 '(("a" "b" "c")
                   ("1" "" "x,\"y\"")
                   ("l1\nl2" "[NULL]" "z"))))
  (should (equal (devtools-sql-result-parse-csv "") nil))
  (should (equal (devtools-sql-result-parse-csv "id\n") '(("id")))))

(ert-deftest devtools-test-status-output ()
  (should (devtools-sql-result-status-p "UPDATE 3\n"))
  (should (devtools-sql-result-status-p "INSERT 0 1\n"))
  (should (devtools-sql-result-status-p "CREATE TABLE\n"))
  (should-not (devtools-sql-result-status-p "id,name\n1,acme\n"))
  (should-not (devtools-sql-result-status-p "count\n3\n")))

(defmacro devtools-test--with-result (output &rest body)
  "Render psql OUTPUT in a result buffer and run BODY there."
  (declare (indent 1))
  `(let ((buffer (save-window-excursion
                   (devtools-sql-result-start '(:name "app") 'local #'ignore))))
     (unwind-protect
         (let ((devtools-profiles '((local))))
           (devtools-sql-result-finish buffer 0 ,output "" 0.1)
           (with-current-buffer buffer ,@body))
       (kill-buffer buffer))))

(ert-deftest devtools-test-result-table-is-aligned ()
  (devtools-test--with-result "id,customer,note\n1,acme,[NULL]\n22,globex,a|b\n"
    (should (equal (buffer-string)
                   (concat "| id | customer | note   |\n"
                           "|----+----------+--------|\n"
                           "|  1 | acme     | [NULL] |\n"
                           "| 22 | globex   | a¦b    |\n")))
    (should devtools-sql-result-mode)
    (should (equal devtools-sql-result--table-size '(2 . 3)))
    (should truncate-lines)
    (should buffer-read-only)
    (goto-char (point-min))
    (search-forward "[NULL]")
    (should (seq-some (lambda (o) (overlay-get o 'devtools-sql-result-null))
                      (overlays-at (1- (point)))))))

(ert-deftest devtools-test-result-status-and-error ()
  (devtools-test--with-result "UPDATE 3\n"
    (should (equal (buffer-string) "UPDATE 3")))
  (let ((buffer (save-window-excursion
                  (devtools-sql-result-start '(:name "app") 'local #'ignore))))
    (unwind-protect
        (with-current-buffer buffer
          (devtools-sql-result-finish buffer 1 "" "ERROR:  boom\n" 0.1)
          (should (equal (buffer-string) "ERROR:  boom"))
          (should (eq (plist-get devtools-sql-result--info :state) 'failed))
          ;; `g' and the `?' menu still work after a failure.
          (should (eq (key-binding "g") #'devtools-sql-result-rerun))
          (should (eq (key-binding "?") #'devtools-sql-result-dispatch)))
      (kill-buffer buffer))))

(ert-deftest devtools-test-result-max-rows ()
  (let ((devtools-sql-result-max-rows 2))
    (devtools-test--with-result "n\n1\n2\n3\n"
      (should (equal devtools-sql-result--table-size '(2 . 1)))
      (should (eq (plist-get devtools-sql-result--info :total-rows) 3))
      (should (string-match-p "first 2 of 3 rows"
                              (devtools-sql-result--header-line))))))

(ert-deftest devtools-test-result-copy ()
  (devtools-test--with-result "id,customer,note\n1,acme,[NULL]\n2,globex,x\n"
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

(ert-deftest devtools-test-psql-args ()
  (should (equal (devtools-sql--psql-args '(:name "a" :host "h" :port 5433 :user "u" :database "d"))
                 '("-h" "h" "-p" "5433" "-U" "u" "-d" "d")))
  (should (equal (devtools-sql--psql-args '(:name "a" :database "d")) '("-d" "d"))))

;;; Against a running Postgres (DEVTOOLS_PG_PORT)

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
  (skip-unless (getenv "DEVTOOLS_PG_PORT"))
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

(ert-deftest devtools-test-postgres-errors-and-read-only ()
  (skip-unless (getenv "DEVTOOLS_PG_PORT"))
  (devtools-test--with-query-file
    (let ((result-buffer (lambda () (get-buffer "*SQL Result: local/app*"))))
      (save-window-excursion (devtools-sql-run-string "select nope from orders"))
      (should (eq (devtools-test--wait-for-result (funcall result-buffer)) 'failed))
      (should (string-match-p "column \"nope\" does not exist"
                              (with-current-buffer (funcall result-buffer) (buffer-string))))
      (save-window-excursion
        (devtools-sql-execute (append '(:read-only t) conn) 'local "delete from orders"))
      (should (eq (devtools-test--wait-for-result (funcall result-buffer)) 'failed))
      (should (string-match-p "read-only transaction"
                              (with-current-buffer (funcall result-buffer) (buffer-string))))
      (save-window-excursion (devtools-sql-run-string "update orders set status = status"))
      (should (eq (devtools-test--wait-for-result (funcall result-buffer)) 'done))
      (should (equal (with-current-buffer (funcall result-buffer) (buffer-string))
                     "UPDATE 3")))))

(ert-deftest devtools-test-postgres-rerun-discards-stale-result ()
  (skip-unless (getenv "DEVTOOLS_PG_PORT"))
  (devtools-test--with-query-file
    (save-window-excursion
      (devtools-sql-run-string "select pg_sleep(2), 'slow' as which")
      (devtools-sql-run-string "select 'fast' as which"))
    (let ((result (get-buffer "*SQL Result: local/app*")))
      (should (eq (devtools-test--wait-for-result result) 'done))
      (accept-process-output nil 0.3)
      (should (string-match-p "fast" (with-current-buffer result (buffer-string))))
      (should-not (string-match-p "slow" (with-current-buffer result (buffer-string)))))))

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

;;; devtools-test.el ends here
