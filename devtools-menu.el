;;; devtools-menu.el --- Transient menu for devtools  -*- lexical-binding: t; -*-

;;; Commentary:

;; One entry point for every devtools command.  Bind `devtools-menu' to
;; a key of your choice; add or rebind entries with `transient-append-suffix'
;; and friends.  A prefix argument typed before the menu key does not reach
;; the commands; type it in the menu (C-u before the entry's key) instead.
;;
;; The -e option picks an environment for the next command only, leaving
;; the current environment as it is.

;;; Code:

(require 'transient)
(require 'devtools-profiles)
(require 'devtools-sql)

(defun devtools-menu--title ()
  "Menu heading with the current environment."
  (concat "Devtools  environment:" (devtools-profile-label)))

(defun devtools-menu--default-environment ()
  "Return the environment commands use when -e is not set."
  (let ((devtools-sql-command-profile-function nil))
    (devtools-sql-command-profile)))

(defun devtools-menu--environment-description (&optional option)
  "Label of the -e OPTION: the environment set, or the one used if unset."
  (let ((value (and option (slot-boundp option 'value) (oref option value))))
    (concat "For this command"
            (if value
                (concat ": " (propertize value 'face 'transient-value))
              (propertize (format " (default %s)" (devtools-menu--default-environment))
                          'face 'shadow)))))

(defun devtools-menu--read-environment (prompt initial-input history)
  "Read an environment for the -e option; see `transient-infix-read'.
PROMPT, INITIAL-INPUT and HISTORY are passed to `completing-read'."
  (completing-read prompt (mapcar (lambda (profile) (symbol-name (car profile)))
                                  devtools-profiles)
                   nil t initial-input history))

(transient-define-argument devtools-menu--environment ()
  "Environment for the next command only."
  :description #'devtools-menu--environment-description
  :class 'transient-option
  ;; The label shows the value.
  :format " %k %d"
  :argument "--environment="
  :reader #'devtools-menu--read-environment)

(defun devtools-menu--chosen-environment ()
  "Return the environment set with -e for the running menu command, or nil."
  (when (eq transient-current-command 'devtools-menu)
    (when-let* ((value (transient-arg-value "--environment="
                                            (transient-args 'devtools-menu)))
                (profile (intern value))
                ((assq profile devtools-profiles)))
      profile)))

(setq devtools-sql-command-profile-function #'devtools-menu--chosen-environment)

;;;###autoload (autoload 'devtools-menu "devtools-menu" nil t)
(transient-define-prefix devtools-menu ()
  "Databases, clusters and APIs for the current environment."
  [:description devtools-menu--title
   ["Environment"
    ("e" "Switch" devtools-switch-profile :transient t)
    ("-e" devtools-menu--environment)]
   ["Postgres"
    ("p" "REPL" devtools-sql-connect)
    ("q" "Query file" devtools-sql-query)
    ("n" "Named query file" devtools-sql-query-named)
    ("f" "Find query file" devtools-sql-find-file)
    ("F" "Find in all environments" devtools-sql-find-file-everywhere)]])

(provide 'devtools-menu)
;;; devtools-menu.el ends here
