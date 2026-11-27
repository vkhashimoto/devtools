;;; devtools-server.el --- Client for devtools-server  -*- lexical-binding: t; -*-

;;; Commentary:

;; devtools-server (server/ in this repository) holds the database
;; connections.  Emacs starts it on first use and talks JSON-RPC over its
;; stdin/stdout; every request is asynchronous.  `devtools-server-events'
;; shows the messages exchanged, `devtools-server-stop' stops it (the next
;; request starts it again).

;;; Code:

(require 'cl-lib)
(require 'jsonrpc)

(defcustom devtools-server-program "devtools-server"
  "Name or path of the devtools-server executable."
  :type 'string
  :group 'devtools)

(defvar devtools-server--connection nil
  "The `jsonrpc-process-connection' to the running server.")

(defvar devtools-server--opened (make-hash-table :test #'equal)
  "Parameters of the connections opened on the running server, by id.")

(defvar devtools-server--process nil
  "The running server's process.")

(defvar devtools-server--generation 0
  "Number of servers started so far; sessions belong to one of them.")

(defun devtools-server--start ()
  "Start the server and return its connection."
  (let ((program (or (executable-find devtools-server-program)
                     (user-error "Cannot find `%s'; build it with `go build' in server/ or set `devtools-server-program'"
                                 devtools-server-program))))
    (clrhash devtools-server--opened)
    (cl-incf devtools-server--generation)
    (setq devtools-server--connection
          (make-instance
           'jsonrpc-process-connection
           :name "devtools-server"
           :process (setq devtools-server--process
                          (make-process
                           :name "devtools-server"
                           :command (list program)
                           :connection-type 'pipe
                           :coding 'utf-8-emacs-unix
                           :noquery t
                           ;; jsonrpc expects exactly this name.
                           :stderr (get-buffer-create "*devtools-server stderr*")))
           :on-shutdown (lambda (_connection) (clrhash devtools-server--opened))))
    (jsonrpc-request devtools-server--connection "initialize" nil)
    devtools-server--connection))

(defun devtools-server-running-p ()
  "Return non-nil if the server is running."
  (and devtools-server--connection
       (jsonrpc-running-p devtools-server--connection)))

(defun devtools-server ()
  "Return the connection to the server, starting it if needed."
  (if (devtools-server-running-p)
      devtools-server--connection
    (devtools-server--start)))

(defun devtools-server-generation ()
  "Return the number of the running server, which changes on each start.
A session opened under another number is gone."
  devtools-server--generation)

(defun devtools-server-request (method params callback)
  "Send METHOD with PARAMS to the server without waiting.
CALLBACK is called with the result and nil, or with nil and the error,
a plist (:code :message :data)."
  (jsonrpc-async-request (devtools-server) method params
                         :success-fn (lambda (result) (funcall callback result nil))
                         :error-fn (lambda (error) (funcall callback nil error))
                         ;; Queries can take as long as they need.
                         :timeout nil))

(defun devtools-server-ensure-open (id params callback)
  "Open the connection ID with PARAMS unless it is open.
CALLBACK is called with nil once it is open, or with the error.  An
open connection is used as it is, even if PARAMS differ: reopening it
can close sessions, so it is left to `devtools-server-open'."
  ;; Starting the server first forgets the connections of a dead one.
  (devtools-server)
  (if (gethash id devtools-server--opened)
      (funcall callback nil)
    (devtools-server-request
     "connection/open" (append (list :id id) params)
     (lambda (_result error)
       (unless error
         (puthash id params devtools-server--opened))
       (funcall callback error)))))

(defun devtools-server-opened-params (id)
  "Return the parameters the connection ID is open with, or nil."
  (and (devtools-server-running-p)
       (gethash id devtools-server--opened)))

(defun devtools-server-opened-connections ()
  "Return the open connections as (ID . PARAMS) pairs."
  (when (devtools-server-running-p)
    (let (connections)
      (maphash (lambda (id params) (push (cons id params) connections))
               devtools-server--opened)
      connections)))

(defun devtools-server-call (method params)
  "Send METHOD with PARAMS to the server and wait for its result.
Return (:result RESULT) or (:error ERROR), ERROR being a plist (:code
:message :data)."
  (condition-case err
      (list :result (jsonrpc-request (devtools-server) method params :timeout 20))
    (jsonrpc-error
     (list :error (list :code (alist-get 'jsonrpc-error-code (cdr err))
                        :message (alist-get 'jsonrpc-error-message (cdr err))
                        :data (alist-get 'jsonrpc-error-data (cdr err)))))))

(defun devtools-server-open (id params)
  "Open, or reopen, the connection ID with PARAMS and wait.
Reopening with other settings than the password closes its sessions.
Signal a `user-error' if it fails."
  (let ((reply (devtools-server-call "connection/open" (append (list :id id) params))))
    (when-let* ((error (plist-get reply :error)))
      (user-error "Could not open %s: %s" id (plist-get error :message)))
    (puthash id params devtools-server--opened)))

(defun devtools-server-events ()
  "Show the JSON-RPC messages exchanged with the server."
  (interactive)
  (unless devtools-server--connection
    (user-error "The server has not been started"))
  (pop-to-buffer (jsonrpc-events-buffer devtools-server--connection)))

(defun devtools-server-stop ()
  "Stop the server, closing its connections; the next request starts a new one."
  (interactive)
  (when (devtools-server-running-p)
    ;; Closing its input lets the server close its connections and exit.
    (process-send-eof devtools-server--process)
    (let ((deadline (+ (float-time) 2)))
      (while (and (process-live-p devtools-server--process)
                  (< (float-time) deadline))
        (accept-process-output devtools-server--process 0.05)))
    (when (process-live-p devtools-server--process)
      (jsonrpc-shutdown devtools-server--connection)))
  (setq devtools-server--connection nil)
  (clrhash devtools-server--opened))

(provide 'devtools-server)
;;; devtools-server.el ends here
