;;; devtools-sql.el --- Postgres connections per environment  -*- lexical-binding: t; -*-

;;; Commentary:

;; Each profile lists its Postgres connections under :postgres:
;;
;;   (:name "app" :host "localhost" :port 5432 :user "dev" :database "app")
;;
;; Optional :read-only overrides `devtools-sql-read-only-in-production'.
;; Passwords come from auth-source (~/.authinfo.gpg), matched on host,
;; port and user.  Without one, psql asks for it in the minibuffer.
;;
;; `devtools-sql-connect' opens a psql REPL.  `devtools-sql-query' opens
;; a saved .sql file per environment/connection; in it, C-c C-c runs the
;; query at point (or the region) through devtools-server and shows the
;; rows in a result buffer, see `devtools-sql-result-mode'.  Table and
;; column names for completion are still loaded with psql.

;;; Code:

(require 'sql)
(require 'auth-source)
(require 'pulse)
(require 'devtools-profiles)
(require 'devtools-sql-result)
(require 'devtools-server)

(defcustom devtools-sql-psql-program "psql"
  "Name or path of the psql executable.
It is looked up from the buffer the command runs in, so a project's
envrc/nix shell is respected."
  :type 'string
  :group 'devtools)

(defcustom devtools-sql-query-directory (locate-user-emacs-file "devtools/sql/")
  "Directory for query files, one per environment and connection."
  :type 'directory
  :group 'devtools)

(defcustom devtools-sql-read-only-in-production t
  "When non-nil, production connections use read-only transactions.
A connection's :read-only key overrides this.  To write on purpose in
a read-only session, run: SET default_transaction_read_only = off;"
  :type 'boolean
  :group 'devtools)

(defvar-local devtools-sql-connection nil
  "Connection plist of the current query or REPL buffer.")
(put 'devtools-sql-connection 'permanent-local t)

(defvar-local devtools-sql-profile nil
  "Profile name of the current query or REPL buffer.")
(put 'devtools-sql-profile 'permanent-local t)

(defun devtools-sql--describe (conn)
  "Return a user@host:port/database summary of CONN."
  (format "%s@%s:%s/%s"
          (or (plist-get conn :user) "")
          (or (plist-get conn :host) "localhost")
          (or (plist-get conn :port) 5432)
          (or (plist-get conn :database) "")))

(defun devtools-sql--connections (&optional profile)
  "Return the Postgres connections of PROFILE."
  (or (devtools-env :postgres profile)
      (user-error "Environment `%s' has no :postgres connections"
                  (or profile (devtools-current-profile)))))

(defun devtools-sql--read-connection ()
  "Pick a Postgres connection of the current profile."
  (let ((conns (devtools-sql--connections)))
    (if (length= conns 1)
        (car conns)
      (let* ((find (lambda (name)
                     (seq-find (lambda (c) (equal (plist-get c :name) name)) conns)))
             (completion-extra-properties
              `(:annotation-function
                ,(lambda (name)
                   (propertize (concat "  " (devtools-sql--describe (funcall find name)))
                               'face 'completions-annotations)))))
        (funcall find (completing-read
                       (format "Postgres [%s]: " (devtools-current-profile))
                       (mapcar (lambda (c) (plist-get c :name)) conns)
                       nil t))))))

(defun devtools-sql--read-only-p (conn profile)
  "Return non-nil if CONN in PROFILE should be read-only."
  (if (plist-member conn :read-only)
      (plist-get conn :read-only)
    (and devtools-sql-read-only-in-production
         (devtools-production-p profile))))

(defun devtools-sql--password (conn)
  "Return the auth-source password for CONN, or nil."
  (apply #'auth-source-pick-first-password
         :host (or (plist-get conn :host) "localhost")
         :port (format "%s" (or (plist-get conn :port) 5432))
         (when-let* ((user (plist-get conn :user)))
           (list :user user))))

(defun devtools-sql--environment (conn profile)
  "Return the extra environment variables for psql on CONN in PROFILE."
  (delq nil
        (list (when-let* ((password (devtools-sql--password conn)))
                (concat "PGPASSWORD=" password))
              (when (devtools-sql--read-only-p conn profile)
                "PGOPTIONS=-c default_transaction_read_only=on"))))

(defun devtools-sql--buffer-name (conn profile)
  "Return the REPL buffer name for CONN in PROFILE."
  (format "*SQL: %s/%s*" profile (plist-get conn :name)))

(defun devtools-sql--header-line ()
  "Header line showing which environment and database a buffer targets."
  (when devtools-sql-connection
    (concat (devtools-profile-label devtools-sql-profile)
            " " (plist-get devtools-sql-connection :name) "  "
            (propertize (devtools-sql--describe devtools-sql-connection) 'face 'shadow)
            (when (devtools-sql--read-only-p devtools-sql-connection devtools-sql-profile)
              (propertize "  read-only" 'face 'warning)))))

(defun devtools-sql--mark-buffer (conn profile)
  "Tag the current buffer as targeting CONN in PROFILE."
  (setq devtools-sql-connection conn
        devtools-sql-profile profile
        header-line-format '(:eval (devtools-sql--header-line))))

(defun devtools-sql--start (conn profile)
  "Return a live psql buffer for CONN in PROFILE, starting it if needed."
  (let ((existing (get-buffer (devtools-sql--buffer-name conn profile))))
    (if (and existing (comint-check-proc existing))
        existing
      (let ((program (or (executable-find devtools-sql-psql-program)
                         (user-error "Cannot find `%s'; install the PostgreSQL client or set `devtools-sql-psql-program'"
                                     devtools-sql-psql-program)))
            (env (devtools-sql--environment conn profile))
            buf)
        ;; Start from a temp buffer: sql.el switches to the new buffer
        ;; before launching psql, so variables bound in a buffer with a
        ;; local environment (envrc) would not reach the process.
        (with-temp-buffer
          (let ((default-directory (expand-file-name "~/"))
                (process-environment (append env process-environment))
                (sql-postgres-program program)
                (sql-postgres-login-params nil)
                (sql-user (or (plist-get conn :user) ""))
                (sql-server (or (plist-get conn :host) ""))
                (sql-database (or (plist-get conn :database) ""))
                (sql-port (or (plist-get conn :port) 0))
                (sql-password ""))
            (setq buf (sql-product-interactive
                       'postgres (devtools-sql--buffer-name conn profile)))))
        (with-current-buffer buf
          (devtools-sql--mark-buffer conn profile))
        buf))))

;;;###autoload
(defun devtools-sql-connect (conn)
  "Open a psql REPL for CONN in the current environment."
  (interactive (list (devtools-sql--read-connection)))
  (pop-to-buffer (devtools-sql--start conn (devtools-current-profile))))

;;;###autoload
(defun devtools-sql-query (conn)
  "Open the query file for CONN in the current environment.
\\<devtools-sql-query-mode-map>\\[devtools-sql-run] runs the query at point, or the region."
  (interactive (list (devtools-sql--read-connection)))
  (let* ((profile (devtools-current-profile))
         (file (devtools-sql--query-file conn profile)))
    (make-directory (file-name-directory file) t)
    (prog1 (find-file file)
      (devtools-sql--link-query-buffer conn profile))))

(defun devtools-sql--query-file (conn profile)
  "Return the query file of CONN in PROFILE."
  (expand-file-name (format "%s/%s.sql" profile (plist-get conn :name))
                    devtools-sql-query-directory))

(defun devtools-sql--link-query-buffer (conn profile)
  "Make the current buffer run its queries on CONN in PROFILE."
  (unless (derived-mode-p 'sql-mode)
    (sql-mode))
  (sql-set-product 'postgres)
  (devtools-sql--mark-buffer conn profile)
  (devtools-sql-query-mode 1))

(defun devtools-sql-link-query-file ()
  "Link a file under `devtools-sql-query-directory' to its connection.
Files are named PROFILE/CONNECTION.sql; for `find-file-hook'."
  (when-let* ((file buffer-file-name)
              (dir (file-name-as-directory (expand-file-name devtools-sql-query-directory)))
              ((string-prefix-p dir (expand-file-name file)))
              (parts (split-string (file-relative-name file dir) "/"))
              ((length= parts 2))
              (profile (intern (car parts)))
              ((assq profile devtools-profiles))
              (conn (seq-find (lambda (c) (equal (plist-get c :name)
                                                 (file-name-base (cadr parts))))
                              (devtools-env :postgres profile))))
    (devtools-sql--link-query-buffer conn profile)))

;;; Running queries into a result buffer

(defun devtools-sql--psql-args (conn)
  "Return the psql connection arguments for CONN."
  (append (when-let* ((host (plist-get conn :host))) (list "-h" host))
          (when-let* ((port (plist-get conn :port))) (list "-p" (format "%s" port)))
          (when-let* ((user (plist-get conn :user))) (list "-U" user))
          (when-let* ((database (plist-get conn :database))) (list "-d" database))))

(defun devtools-sql--drain (buffer)
  "Read what is left of the process writing to BUFFER, then return its text."
  (when-let* ((process (get-buffer-process buffer)))
    (while (accept-process-output process 0.05)))
  (with-current-buffer buffer (buffer-string)))

(defvar devtools-sql-after-execute-functions nil
  "Functions called after a query run with `devtools-sql-execute' ends.
Each is called with the connection, the profile, and the command tags
of the statements (such as \"CREATE TABLE\"), or nil if the run failed.")

(defun devtools-sql-psql-async (conn profile query callback)
  "Run QUERY on CONN in PROFILE with psql in the background.
Output is CSV.  When psql exits, call CALLBACK with its exit code, its
output and its error output.  Return the process."
  (let* ((program (or (executable-find devtools-sql-psql-program)
                      (user-error "Cannot find `%s'; install the PostgreSQL client or set `devtools-sql-psql-program'"
                                  devtools-sql-psql-program)))
         (stdout (generate-new-buffer " *devtools-sql-output*"))
         (stderr (generate-new-buffer " *devtools-sql-errors*"))
         (default-directory (expand-file-name "~/"))
         (process-environment (append (devtools-sql--environment conn profile)
                                      process-environment)))
    (make-process
     :name "devtools-sql"
     :buffer stdout
     :stderr stderr
     :connection-type 'pipe
     :command `(,program ,@(devtools-sql--psql-args conn)
                         ;; No psqlrc, never prompt for a password, CSV
                         ;; output, and stop at the first error.
                         "-X" "-w" "--csv" "--pset=null=[NULL]"
                         "-v" "ON_ERROR_STOP=1" "-v" "SHOW_ALL_RESULTS=off"
                         "-c" ,query)
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (unwind-protect
             (funcall callback (process-exit-status process)
                      (devtools-sql--drain stdout)
                      (devtools-sql--drain stderr))
           (dolist (buffer (list stdout stderr))
             (when-let* ((reader (get-buffer-process buffer)))
               (delete-process reader))
             (kill-buffer buffer))))))))

(defun devtools-sql--server-params (conn profile)
  "Return the server's connection/open parameters for CONN in PROFILE."
  (list :driver "postgres"
        :host (or (plist-get conn :host) "")
        :port (or (plist-get conn :port) 0)
        :user (or (plist-get conn :user) "")
        :password (or (devtools-sql--password conn) "")
        :database (or (plist-get conn :database) "")
        :readOnly (if (devtools-sql--read-only-p conn profile) t :json-false)))

(defun devtools-sql-server-execute (conn profile sql callback)
  "Run SQL on CONN in PROFILE through devtools-server.
CALLBACK is called with the server's result and nil, or with nil and
the error plist."
  (let ((id (format "%s/%s" profile (plist-get conn :name))))
    (devtools-server-ensure-open
     id (devtools-sql--server-params conn profile)
     (lambda (error)
       (if error
           (funcall callback nil error)
         (devtools-server-request
          "query/execute"
          (list :connection id :sql sql :maxRows devtools-sql-result-max-rows)
          callback))))))

(defun devtools-sql-execute (conn profile query)
  "Run QUERY on CONN in PROFILE and show the result in a result buffer.
Only the result of the last statement is shown."
  ;; Fail before touching the result buffer if the server cannot start.
  (devtools-server)
  (let ((result (devtools-sql-result-start
                 conn profile (lambda () (devtools-sql-execute conn profile query)) query))
        (started (float-time))
        (run (list 'run)))
    (with-current-buffer result
      (setq devtools-sql-result--info (plist-put devtools-sql-result--info :run run)))
    (devtools-sql-server-execute
     conn profile query
     (lambda (response error)
       ;; A query that was run again in the meantime is stale.
       (when (eq run (devtools-sql--result-run conn profile))
         (if error
             (devtools-sql-result-show-error result error (- (float-time) started))
           (devtools-sql-result-show result response (- (float-time) started))))
       (run-hook-with-args 'devtools-sql-after-execute-functions conn profile
                           (and response
                                (mapcar (lambda (set) (plist-get set :command))
                                        (plist-get response :results))))))))

(defun devtools-sql--result-run (conn profile)
  "Return the token of the latest run in the result buffer of CONN in PROFILE."
  (when-let* ((buffer (get-buffer (devtools-sql-result-buffer-name conn profile))))
    (plist-get (buffer-local-value 'devtools-sql-result--info buffer) :run)))

(defun devtools-sql-run (start end)
  "Run the query between START and END and show its rows.
Interactively, the region if active, else the paragraph at point."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (save-excursion
       (list (progn (backward-paragraph) (point))
             (progn (forward-paragraph) (point))))))
  (unless devtools-sql-connection
    (user-error "Buffer is not linked to a connection; open it with `devtools-sql-query'"))
  (let ((query (string-trim (buffer-substring-no-properties start end))))
    (when (string-empty-p query)
      (user-error "No query at point"))
    (pulse-momentary-highlight-region start end)
    (devtools-sql-execute devtools-sql-connection devtools-sql-profile query)))

(defun devtools-sql-run-string (query)
  "Run QUERY on the connection of the current buffer and show its rows."
  (interactive "sQuery: ")
  (unless devtools-sql-connection
    (user-error "Buffer is not linked to a connection; open it with `devtools-sql-query'"))
  (devtools-sql-execute devtools-sql-connection devtools-sql-profile query))

(defun devtools-sql-repl-for-buffer ()
  "Open the psql REPL for the connection of the current buffer."
  (interactive)
  (unless devtools-sql-connection
    (user-error "Buffer is not linked to a connection"))
  (pop-to-buffer (devtools-sql--start devtools-sql-connection devtools-sql-profile)))

(defvar-keymap devtools-sql-query-mode-map
  "C-c C-c" #'devtools-sql-run
  "C-c C-z" #'devtools-sql-repl-for-buffer)

(define-minor-mode devtools-sql-query-mode
  "Run the queries of a devtools query file into a result buffer.
\\{devtools-sql-query-mode-map}"
  :lighter " DevSQL"
  :keymap devtools-sql-query-mode-map)

(provide 'devtools-sql)
;;; devtools-sql.el ends here
