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
;; rows in a result buffer, see `devtools-sql-result-mode'.

;;; Code:

(require 'cl-lib)
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
A connection's :read-only key overrides this.  To write on purpose,
wrap the statements in one run: BEGIN READ WRITE; ...; COMMIT;
In a session or the psql REPL, SET default_transaction_read_only = off;
lasts for that session."
  :type 'boolean
  :group 'devtools)

(defcustom devtools-sql-query-files-use-session t
  "When non-nil, queries of a query file run on its own session.
A session keeps SET, temp tables and transactions between runs, like a
psql session.  When nil, they run on the connection pool, each run
starting clean.  A prefix argument to `devtools-sql-run' runs a query
the other way."
  :type 'boolean
  :group 'devtools)

(defvar-local devtools-sql-connection nil
  "Connection plist of the current query or REPL buffer.")
(put 'devtools-sql-connection 'permanent-local t)

(defvar-local devtools-sql-profile nil
  "Profile name of the current query or REPL buffer.")
(put 'devtools-sql-profile 'permanent-local t)

(defvar-local devtools-sql-query-name nil
  "Name of this query file, or nil for its datasource's default file.")
(put 'devtools-sql-query-name 'permanent-local t)

(defvar-local devtools-sql--session nil
  "The server session of this query buffer, as (GENERATION . ID).
GENERATION is `devtools-server-generation' when it was opened.")
(put 'devtools-sql--session 'permanent-local t)

(defvar-local devtools-sql--tx-status nil
  "Transaction state of this buffer's session: \"idle\", \"transaction\"
or \"failed\", or nil before its first run.")
(put 'devtools-sql--tx-status 'permanent-local t)

(defvar-local devtools-sql--session-busy nil
  "Non-nil while this buffer's session runs a query.")
(put 'devtools-sql--session-busy 'permanent-local t)

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
            " " (plist-get devtools-sql-connection :name)
            (when devtools-sql-query-name (concat "/" devtools-sql-query-name))
            "  " (propertize (devtools-sql--describe devtools-sql-connection) 'face 'shadow)
            (when (devtools-sql--read-only-p devtools-sql-connection devtools-sql-profile)
              (propertize "  read-only" 'face 'warning))
            (pcase devtools-sql--tx-status
              ("transaction" (propertize "  in transaction" 'face 'warning))
              ("failed" (propertize "  transaction failed" 'face 'error))))))

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
(defun devtools-sql-query (conn &optional name description)
  "Open a query file of CONN in the current environment.
Without NAME, the datasource's default file; with NAME, its file NAME,
created if new, with DESCRIPTION as its first line.  Interactively, a
prefix argument asks for NAME, and for DESCRIPTION if the file is new.
\\<devtools-sql-query-mode-map>\\[devtools-sql-run] runs the query at point, or the region."
  (interactive
   (let* ((conn (devtools-sql--read-connection))
          (profile (devtools-current-profile))
          (name (and current-prefix-arg (devtools-sql--read-query-name conn profile))))
     (list conn name
           (and name (not (file-exists-p (devtools-sql--query-file conn profile name)))
                (read-string "Description (first line of the file): ")))))
  (let* ((profile (devtools-current-profile))
         (file (devtools-sql--query-file conn profile name))
         (created (and name description (not (string-blank-p description))
                       (not (file-exists-p file)))))
    (make-directory (file-name-directory file) t)
    (when created
      (write-region (format "-- %s\n\n" (string-trim description)) nil file nil 'silent))
    (prog1 (find-file file)
      (devtools-sql--link-query-buffer conn profile name)
      (when created
        (goto-char (point-max))))))

(defun devtools-sql--query-file (conn profile &optional name)
  "Return the query file of CONN in PROFILE.
That is PROFILE/CONN.sql, or PROFILE/CONN/NAME.sql given NAME."
  (expand-file-name (if name
                        (format "%s/%s/%s.sql" profile (plist-get conn :name) name)
                      (format "%s/%s.sql" profile (plist-get conn :name)))
                    devtools-sql-query-directory))

(defun devtools-sql--query-names (conn profile)
  "Return the names of the query files of CONN in PROFILE.
The default file is not among them."
  (let ((dir (file-name-sans-extension (devtools-sql--query-file conn profile))))
    (and (file-directory-p dir)
         (mapcar #'file-name-base (directory-files dir nil "\\.sql\\'")))))

(defun devtools-sql--read-query-name (conn profile)
  "Ask for the name of a query file of CONN in PROFILE, new or existing."
  (let ((name (string-trim
               (completing-read (format "Query file of %s/%s: " profile (plist-get conn :name))
                                (devtools-sql--query-names conn profile)))))
    (when (or (string-empty-p name) (string-search "/" name))
      (user-error "A query file name cannot be empty or contain a slash"))
    name))

(defun devtools-sql--link-query-buffer (conn profile &optional name)
  "Make the current buffer run its queries on CONN in PROFILE.
NAME is the query file's name, nil for the default file."
  (unless (derived-mode-p 'sql-mode)
    (sql-mode))
  (sql-set-product 'postgres)
  (devtools-sql--mark-buffer conn profile)
  (setq devtools-sql-query-name name)
  (add-hook 'kill-buffer-hook #'devtools-sql--close-session nil t)
  (devtools-sql-query-mode 1))

(defun devtools-sql-link-query-file ()
  "Link a file under `devtools-sql-query-directory' to its connection.
Files are PROFILE/CONNECTION.sql or PROFILE/CONNECTION/NAME.sql; for
`find-file-hook'."
  (when-let* ((file buffer-file-name)
              ((string-suffix-p ".sql" file))
              (dir (file-name-as-directory (expand-file-name devtools-sql-query-directory)))
              ((string-prefix-p dir (expand-file-name file)))
              (parts (split-string (file-relative-name file dir) "/"))
              ((memq (length parts) '(2 3)))
              (profile (intern (car parts)))
              ((assq profile devtools-profiles))
              (conn-name (if (length= parts 2) (file-name-base (cadr parts)) (cadr parts)))
              (conn (seq-find (lambda (c) (equal (plist-get c :name) conn-name))
                              (devtools-env :postgres profile))))
    (devtools-sql--link-query-buffer conn profile
                                     (and (length= parts 3) (file-name-base (nth 2 parts))))))

(defun devtools-sql--file-description (file)
  "Return the description of the query FILE: its first line, if a comment."
  (with-temp-buffer
    (insert-file-contents file nil 0 4096)
    (goto-char (point-min))
    (when (looking-at "[ \t]*--+[ \t]*\\(.*?\\)[ \t]*$")
      (let ((text (match-string 1)))
        (unless (string-empty-p text) text)))))

(defun devtools-sql--query-files (profiles)
  "Return the query files of the datasources of PROFILES.
Each is a list (FILE PROFILE CONN NAME), NAME being nil for a
datasource's default file, which is listed even before it exists."
  (let (files)
    (dolist (profile profiles)
      (dolist (conn (devtools-env :postgres profile))
        (push (list (devtools-sql--query-file conn profile) profile conn nil) files)
        (dolist (name (devtools-sql--query-names conn profile))
          (push (list (devtools-sql--query-file conn profile name) profile conn name)
                files))))
    (nreverse files)))

(defun devtools-sql--find-file-candidates (files with-profile)
  "Return completion candidates for FILES, as (CANDIDATE . FILE) pairs.
A candidate is the file's name followed by its description, so both
can be matched.  WITH-PROFILE puts the environment in front."
  (let* ((labels (mapcar (pcase-lambda (`(,_ ,profile ,conn ,name))
                           (concat (if with-profile (format "%s/" profile) "")
                                   (plist-get conn :name)
                                   (if name (concat "/" name) "")))
                         files))
         (width (apply #'max (mapcar #'length labels))))
    (cl-mapcar (lambda (label file)
                 (let ((description (or (and (file-exists-p (car file))
                                             (devtools-sql--file-description (car file)))
                                        (and (null (nth 3 file)) "(default file)"))))
                   (cons (if description
                             (concat label (make-string (- width (length label)) ?\s) "  "
                                     (propertize description 'face 'completions-annotations))
                           label)
                         file)))
               labels files)))

;;;###autoload
(defun devtools-sql-find-file (&optional all)
  "Open a query file of the current environment, found by name or description.
The description is a file's first line, when it is a comment.  With a
prefix argument ALL, look in every environment."
  (interactive "P")
  (let* ((profiles (if all (mapcar #'car devtools-profiles) (list (devtools-current-profile))))
         (files (or (devtools-sql--query-files profiles)
                    (user-error "No datasources in %s"
                                (if all "the profiles" (car profiles)))))
         (candidates (devtools-sql--find-file-candidates files all))
         (choice (completing-read (if all "Query file: "
                                    (format "Query file [%s]: " (car profiles)))
                                  candidates nil t)))
    (pcase-let ((`(,file ,profile ,conn ,name) (cdr (assoc choice candidates))))
      (make-directory (file-name-directory file) t)
      (prog1 (find-file file)
        (devtools-sql--link-query-buffer conn profile name)))))

;;;###autoload
(defun devtools-sql-query-named ()
  "Open a named query file of a datasource, new or existing.
Like `devtools-sql-query' with a prefix argument."
  (interactive)
  (let ((current-prefix-arg '(4)))
    (call-interactively #'devtools-sql-query)))

;;;###autoload
(defun devtools-sql-find-file-everywhere ()
  "Open a query file of any environment, found by name or description.
Like `devtools-sql-find-file' with a prefix argument."
  (interactive)
  (devtools-sql-find-file t))

;;; Running queries into a result buffer

(defvar devtools-sql-after-execute-functions nil
  "Functions called after a query run with `devtools-sql-execute' ends.
Each is called with the connection, the profile, and the command tags
of the statements (such as \"CREATE TABLE\"), or nil if the run failed.")

(defun devtools-sql--server-settings (conn profile)
  "Return the server's connection settings for CONN in PROFILE.
They are the connection/open parameters, the password aside."
  (list :driver "postgres"
        :host (or (plist-get conn :host) "")
        :port (or (plist-get conn :port) 0)
        :user (or (plist-get conn :user) "")
        :database (or (plist-get conn :database) "")
        :readOnly (if (devtools-sql--read-only-p conn profile) t :json-false)))

(defun devtools-sql--server-params (conn profile)
  "Return the server's connection/open parameters for CONN in PROFILE."
  (append (devtools-sql--server-settings conn profile)
          (list :password (or (devtools-sql--password conn) ""))))

(defun devtools-sql--server-id (conn profile)
  "Return the server's id for CONN in PROFILE."
  (format "%s/%s" profile (plist-get conn :name)))

(defun devtools-sql-server-request (conn profile method params callback)
  "Send METHOD with PARAMS about CONN in PROFILE to devtools-server.
The connection is opened first if needed, and PARAMS get its
:connection.  CALLBACK is called with the result and nil, or with nil
and the error plist."
  (let ((id (devtools-sql--server-id conn profile)))
    (devtools-server-ensure-open
     id (devtools-sql--server-params conn profile)
     (lambda (error)
       (if error
           (funcall callback nil error)
         (devtools-server-request method (append (list :connection id) params)
                                  callback))))))

;;; Sessions

(defun devtools-sql--use-session-p (other)
  "Return non-nil if a query file run should use its session.
OTHER (the prefix argument) asks for the other choice than
`devtools-sql-query-files-use-session'."
  (if other
      (not devtools-sql-query-files-use-session)
    devtools-sql-query-files-use-session))

(defun devtools-sql--with-session (buffer conn profile callback)
  "Call CALLBACK with the session id of BUFFER, opening one if needed.
On failure, call it with nil and the error."
  (let ((session (buffer-local-value 'devtools-sql--session buffer))
        (generation (devtools-server-generation)))
    (if (eql (car session) generation)
        (funcall callback (cdr session) nil)
      (when session
        (message "devtools: the server stopped, ending the session of %s; starting a new one"
                 (buffer-name buffer)))
      (devtools-server-request
       "session/open" (list :connection (devtools-sql--server-id conn profile))
       (lambda (result error)
         (if error
             (funcall callback nil error)
           (let ((id (plist-get result :session)))
             (if (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq devtools-sql--session (cons generation id)
                         devtools-sql--tx-status "idle"))
               ;; The buffer was killed meanwhile.
               (devtools-server-request "session/close" (list :session id) #'ignore))
             (funcall callback id nil))))))))

(defun devtools-sql--session-gone-p (error)
  "Return non-nil if ERROR says the session and its state are gone."
  (memq (plist-get error :code) '(-32003 -32005)))

(defun devtools-sql--note-session-run (buffer id result error)
  "Record in BUFFER how a run on its session ID ended.
RESULT or ERROR is the server's reply."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq devtools-sql--session-busy nil)
      (cond ((devtools-sql--session-gone-p error)
             (when (equal (cdr devtools-sql--session) id)
               (setq devtools-sql--session nil
                     devtools-sql--tx-status nil)))
            (result (setq devtools-sql--tx-status (plist-get result :txStatus)))
            (error (when-let* ((status (plist-get (plist-get error :data) :txStatus)))
                     (setq devtools-sql--tx-status status))))
      (force-mode-line-update))))

(defun devtools-sql--close-session ()
  "Close the session of the current buffer, if its server still runs."
  (when-let* ((session devtools-sql--session)
              ((devtools-server-running-p))
              ((eql (car session) (devtools-server-generation))))
    (devtools-server-request "session/close" (list :session (cdr session)) #'ignore))
  (setq devtools-sql--session nil
        devtools-sql--tx-status nil))
(put 'devtools-sql--close-session 'permanent-local-hook t)

;;; Keeping connections up to date with the profiles

(defun devtools-sql--current-connection (conn profile)
  "Return CONN as PROFILE currently defines it, found by name.
Query buffers keep the connection they were linked with; the profile
may have been edited since.  Return CONN if it is no longer there."
  (or (seq-find (lambda (c) (equal (plist-get c :name) (plist-get conn :name)))
                (devtools-env :postgres profile))
      conn))

(defconst devtools-sql--setting-labels
  '((:host . "host") (:port . "port") (:user . "user") (:database . "database")
    (:readOnly . "read-only"))
  "Connection settings that need a new connection when they change.")

(defun devtools-sql--setting-text (key value)
  "Return VALUE of the setting KEY as shown to the user."
  (cond ((eq key :readOnly) (if (eq value t) "on" "off"))
        ((member value '("" 0 nil)) "default")
        (t (format "%s" value))))

(defun devtools-sql--settings-changes (old new)
  "Describe how the settings changed from OLD to NEW server parameters.
Return nil when they are the same, the password aside."
  (let (changes)
    (pcase-dolist (`(,key . ,label) devtools-sql--setting-labels)
      (let ((before (plist-get old key))
            (after (plist-get new key)))
        (unless (equal before after)
          (push (format "%s: %s → %s" label
                        (devtools-sql--setting-text key before)
                        (devtools-sql--setting-text key after))
                changes))))
    (and changes (string-join (nreverse changes) ", "))))

(defun devtools-sql--session-buffers (id)
  "Return the query buffers with a session on the server connection ID."
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (and devtools-sql--session
                       (eql (car devtools-sql--session) (devtools-server-generation))
                       devtools-sql-connection
                       (equal (devtools-sql--server-id devtools-sql-connection
                                                       devtools-sql-profile)
                              id))))
              (buffer-list)))

(defun devtools-sql--count-text (names singular plural)
  "Return \"SINGULAR a\" or \"PLURAL a, b\" for NAMES, or nil if none."
  (when (length> names 0)
    (format "%s %s" (if (length= names 1) singular plural)
            (string-join (append names nil) ", "))))

(defun devtools-sql--session-state-text (buffer)
  "Describe what the session of BUFFER holds, or return nil if nothing."
  (let* ((reply (devtools-server-call "session/state"
                                      (list :session (cdr (buffer-local-value
                                                           'devtools-sql--session buffer)))))
         (state (plist-get reply :result))
         (error (plist-get reply :error)))
    (cond
     ;; Already gone: nothing to lose.
     ((eql (plist-get error :code) -32003) nil)
     ((eql (plist-get error :code) -32004) "a query running")
     (error (format "unknown state (%s)" (plist-get error :message)))
     (t
      (let ((parts
             (delq nil
                   (list (pcase (plist-get state :transaction)
                           ("transaction" "open transaction")
                           ("failed" "failed transaction"))
                         (devtools-sql--count-text (plist-get state :tempTables)
                                                   "temp table" "temp tables")
                         (devtools-sql--count-text (plist-get state :settings) "SET" "SET")
                         (devtools-sql--count-text (plist-get state :prepared)
                                                   "prepared statement" "prepared statements")
                         (devtools-sql--count-text (plist-get state :cursors) "cursor" "cursors")
                         (devtools-sql--count-text (plist-get state :listening) "LISTEN" "LISTEN")
                         (let ((locks (or (plist-get state :advisoryLocks) 0)))
                           (when (> locks 0)
                             (format "%d advisory lock%s" locks (if (= locks 1) "" "s"))))))))
        (and parts (string-join parts ", ")))))))

(defun devtools-sql--refresh-connection (conn profile)
  "Bring the server connection of CONN in PROFILE up to date, if open.
Called before interactive runs.  A new password is passed on without
closing anything.  Other changes need a new connection, which closes
its sessions: that happens at once if no session holds state, else
only if the user agrees; otherwise the current connection stays."
  (let* ((id (devtools-sql--server-id conn profile))
         (old (devtools-server-opened-params id))
         (new (devtools-sql--server-params conn profile)))
    (when (and old (not (equal old new)))
      (let ((changes (devtools-sql--settings-changes old new)))
        (if (null changes)
            (devtools-server-open id new)
          (let* ((buffers (devtools-sql--session-buffers id))
                 (held (delq nil (mapcar (lambda (buffer)
                                           (when-let* ((text (devtools-sql--session-state-text buffer)))
                                             (format "  %s: %s" (buffer-name buffer) text)))
                                         buffers))))
            (if (and held
                     (not (y-or-n-p
                           (format "Settings of %s changed (%s).  Reopening loses:\n%s\nReopen now? "
                                   id changes (string-join held "\n")))))
                (message "devtools: %s keeps its current connection and settings" id)
              (devtools-server-open id new)
              ;; The server closed their sessions; the next runs open new ones.
              (dolist (buffer buffers)
                (with-current-buffer buffer
                  (setq devtools-sql--session nil
                        devtools-sql--tx-status nil)
                  (force-mode-line-update)))
              (message "devtools: reopened %s (%s)" id changes))))))))

(defun devtools-sql--report-profile-changes ()
  "Report the open connections whose settings differ from the profiles.
Nothing is reopened here: the next interactive run does that."
  (let (reports)
    (pcase-dolist (`(,id . ,params) (devtools-server-opened-connections))
      (when (string-match "\\`\\([^/]+\\)/\\(.*\\)\\'" id)
        (let* ((profile (intern (match-string 1 id)))
               (name (match-string 2 id))
               (conn (and (assq profile devtools-profiles)
                          (seq-find (lambda (c) (equal (plist-get c :name) name))
                                    (devtools-env :postgres profile)))))
          (if (null conn)
              (push (format "%s is no longer in the profiles (its connection stays open until the server stops)"
                            id)
                    reports)
            (when-let* ((changes (devtools-sql--settings-changes
                                  params (devtools-sql--server-settings conn profile))))
              (push (format "%s settings changed (%s); the next run reopens it%s"
                            id changes
                            (if (devtools-sql--session-buffers id)
                                ", asking first if a session holds state"
                              ""))
                    reports))))))
    (when reports
      (message "devtools: %s" (string-join (nreverse reports) "; ")))))

(defun devtools-sql--profiles-watcher (_symbol _value operation _where)
  "Report profile changes to open connections once `devtools-profiles' is set.
OPERATION is the kind of change, see `add-variable-watcher'."
  (when (eq operation 'set)
    ;; Watchers run before the new value is in place.
    (run-at-time 0 nil #'devtools-sql--report-profile-changes)))

;;; Running queries

(defun devtools-sql-server-execute (conn profile sql callback &optional session-buffer)
  "Run SQL on CONN in PROFILE through devtools-server.
With SESSION-BUFFER, a query buffer, run on its session; else on the
pool.  CALLBACK is called with the server's result and nil, or with nil
and the error plist."
  (let ((id (devtools-sql--server-id conn profile)))
    (devtools-server-ensure-open
     id (devtools-sql--server-params conn profile)
     (lambda (error)
       (cond
        (error (funcall callback nil error))
        ((buffer-live-p session-buffer)
         (devtools-sql--with-session
          session-buffer conn profile
          (lambda (session error)
            (if error
                (progn (devtools-sql--note-session-run session-buffer nil nil error)
                       (funcall callback nil error))
              (devtools-server-request
               "query/execute"
               (list :connection id :session session :sql sql
                     :maxRows devtools-sql-result-max-rows)
               (lambda (result error)
                 (devtools-sql--note-session-run session-buffer session result error)
                 (funcall callback result error)))))))
        (t
         (devtools-sql-server-request
          conn profile "query/execute"
          (list :sql sql :maxRows devtools-sql-result-max-rows) callback)))))))

(defun devtools-sql-execute (conn profile query &optional source use-session)
  "Run QUERY on CONN in PROFILE and show the result in a result buffer.
SOURCE is the query buffer it comes from, if any: its result buffer
shows the result.  With USE-SESSION, run on SOURCE's session; else on
the pool.  Only the result of the last statement is shown."
  (let* ((source (and (buffer-live-p source) source))
         (session-buffer (and use-session source))
         (name (and source (buffer-local-value 'devtools-sql-query-name source))))
    (when (and session-buffer
               (buffer-local-value 'devtools-sql--session-busy session-buffer))
      (user-error "The session is still running a query; %s runs on the pool instead"
                  (substitute-command-keys "\\[universal-argument] \\[devtools-sql-run]")))
    ;; Fail before touching the result buffer if the server cannot start.
    (devtools-server)
    (setq conn (devtools-sql--current-connection conn profile))
    (when source
      (with-current-buffer source
        (setq devtools-sql-connection conn)))
    (devtools-sql--refresh-connection conn profile)
    (let ((result (devtools-sql-result-start
                   conn profile
                   (lambda () (devtools-sql-execute conn profile query source use-session))
                   query name))
          (target (if session-buffer 'session 'pool))
          (started (float-time))
          (run (list 'run)))
      (with-current-buffer result
        (setq devtools-sql-result--info
              (plist-put (plist-put devtools-sql-result--info :run run) :target target)))
      (when session-buffer
        (with-current-buffer session-buffer
          (setq devtools-sql--session-busy t)))
      (devtools-sql-server-execute
       conn profile query
       (lambda (response error)
         (when (buffer-live-p session-buffer)
           (with-current-buffer session-buffer
             (setq devtools-sql--session-busy nil)))
         ;; A query that was run again in the meantime is stale.
         (when (eq run (devtools-sql--result-run conn profile name))
           (when session-buffer
             (with-current-buffer result
               (setq devtools-sql-result--info
                     (plist-put devtools-sql-result--info :tx
                                (or (plist-get response :txStatus)
                                    (plist-get (plist-get error :data) :txStatus))))))
           (if error
               (devtools-sql-result-show-error
                result
                (if (devtools-sql--session-gone-p error)
                    (plist-put (copy-sequence error) :message
                               (concat (plist-get error :message)
                                       ".  Run again to start a new session."))
                  error)
                (- (float-time) started))
             (devtools-sql-result-show result response (- (float-time) started))))
         (run-hook-with-args 'devtools-sql-after-execute-functions conn profile
                             (and response
                                  (mapcar (lambda (set) (plist-get set :command))
                                          (plist-get response :results)))))
       session-buffer))))

(defun devtools-sql--result-run (conn profile &optional name)
  "Return the token of the latest run in a result buffer of CONN in PROFILE.
NAME is the query file's name, nil for the default file."
  (when-let* ((buffer (get-buffer (devtools-sql-result-buffer-name conn profile name))))
    (plist-get (buffer-local-value 'devtools-sql-result--info buffer) :run)))

(defun devtools-sql-run (start end &optional other)
  "Run the query between START and END and show its rows.
Interactively, the region if active, else the paragraph at point.  It
runs on the buffer's session, or on the pool with a prefix argument
OTHER; `devtools-sql-query-files-use-session' swaps the two."
  (interactive
   (append (if (use-region-p)
               (list (region-beginning) (region-end))
             (save-excursion
               (list (progn (backward-paragraph) (point))
                     (progn (forward-paragraph) (point)))))
           (list current-prefix-arg)))
  (unless devtools-sql-connection
    (user-error "Buffer is not linked to a connection; open it with `devtools-sql-query'"))
  (let ((query (string-trim (buffer-substring-no-properties start end))))
    (when (string-empty-p query)
      (user-error "No query at point"))
    (pulse-momentary-highlight-region start end)
    (devtools-sql-execute devtools-sql-connection devtools-sql-profile query
                          (current-buffer) (devtools-sql--use-session-p other))))

(defun devtools-sql-run-string (query &optional other)
  "Run QUERY and show its rows.
In a query file, like `devtools-sql-run' (OTHER is the prefix
argument); elsewhere, on the pool of a connection of the current
environment."
  (interactive (list (read-string "Query: ") current-prefix-arg))
  (if devtools-sql-connection
      (devtools-sql-execute devtools-sql-connection devtools-sql-profile query
                            (current-buffer) (devtools-sql--use-session-p other))
    (devtools-sql-execute (devtools-sql--read-connection) (devtools-current-profile) query)))

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
