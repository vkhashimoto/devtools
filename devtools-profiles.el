;;; devtools-profiles.el --- Environment profiles for devtools  -*- lexical-binding: t; -*-

;;; Commentary:

;; A profile is one environment (local, staging, prod...) holding the
;; connection details for every tool.  Switching profiles points every
;; devtools command at that environment.

;;; Code:

(defgroup devtools nil
  "Databases, clusters and APIs in one place."
  :group 'tools
  :prefix "devtools-")

(defcustom devtools-profiles nil
  "Environment profiles.
An alist of (NAME . PLIST) where NAME is a symbol.  Recognized keys:

  :production  non-nil marks the environment as production.
  :postgres    list of connection plists, see `devtools-sql-connect'."
  :type '(alist :key-type symbol :value-type plist))

(defcustom devtools-default-profile nil
  "Profile used until one is chosen with `devtools-switch-profile'.
When nil, the first entry of `devtools-profiles' is used."
  :type '(choice (const :tag "First profile" nil) symbol))

(defcustom devtools-profile-changed-hook nil
  "Hook run after switching profiles."
  :type 'hook)

(defface devtools-profile '((t :inherit success :weight bold))
  "Face for the profile name.")

(defface devtools-production '((t :inherit error :weight bold :inverse-video t))
  "Face for the profile name when it is a production environment.")

(defvar devtools--current-profile nil
  "Name of the selected profile, or nil to use the default.")

(defun devtools-current-profile ()
  "Return the name of the selected profile.
A selection that is no longer in `devtools-profiles' (renamed or
removed) is ignored."
  (or (and (assq devtools--current-profile devtools-profiles)
           devtools--current-profile)
      devtools-default-profile
      (caar devtools-profiles)
      (user-error "No profiles defined; set `devtools-profiles'")))

(defun devtools--profile-plist (&optional profile)
  "Return the plist of PROFILE, defaulting to the selected profile."
  (let ((name (or profile (devtools-current-profile))))
    (cdr (or (assq name devtools-profiles)
             (user-error "Unknown profile `%s'" name)))))

(defun devtools-env (key &optional profile)
  "Return KEY from PROFILE, defaulting to the selected profile."
  (plist-get (devtools--profile-plist profile) key))

(defun devtools-production-p (&optional profile)
  "Return non-nil if PROFILE is a production environment."
  (and (devtools-env :production profile) t))

(defun devtools-profile-label (&optional profile)
  "Return the name of PROFILE propertized with its face."
  (let ((name (or profile (devtools-current-profile))))
    (propertize (format " %s " name)
                'face (if (devtools-production-p name)
                          'devtools-production
                        'devtools-profile))))

(defun devtools--annotate-profile (name)
  "Completion annotation for profile NAME."
  (when (devtools-production-p (intern name))
    (propertize "  production" 'face 'error)))

(defun devtools-switch-profile (profile)
  "Point all devtools commands at PROFILE."
  (interactive
   (let ((completion-extra-properties
          '(:annotation-function devtools--annotate-profile)))
     (list (intern (completing-read
                    (format "Environment (current %s): " (devtools-current-profile))
                    (mapcar (lambda (p) (symbol-name (car p))) devtools-profiles)
                    nil t)))))
  (unless (assq profile devtools-profiles)
    (user-error "Unknown profile `%s'" profile))
  (setq devtools--current-profile profile)
  (force-mode-line-update t)
  (run-hooks 'devtools-profile-changed-hook)
  (message "Devtools environment:%s" (devtools-profile-label profile)))

(provide 'devtools-profiles)
;;; devtools-profiles.el ends here
