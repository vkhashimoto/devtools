;;; devtools-menu.el --- Transient menu for devtools  -*- lexical-binding: t; -*-

;;; Commentary:

;; One entry point for every devtools command.  Bind `devtools-menu' to
;; a key of your choice; add or rebind entries with `transient-append-suffix'
;; and friends.

;;; Code:

(require 'transient)
(require 'devtools-profiles)
(require 'devtools-sql)

(defun devtools-menu--title ()
  "Menu heading with the current environment."
  (concat "Devtools  environment:" (devtools-profile-label)))

;;;###autoload (autoload 'devtools-menu "devtools-menu" nil t)
(transient-define-prefix devtools-menu ()
  "Databases, clusters and APIs for the current environment."
  [:description devtools-menu--title
   ["Environment"
    ("e" "Switch" devtools-switch-profile :transient t)]
   ["Postgres"
    ("p" "REPL" devtools-sql-connect)
    ("q" "Query file" devtools-sql-query)]])

(provide 'devtools-menu)
;;; devtools-menu.el ends here
