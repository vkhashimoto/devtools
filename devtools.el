;;; devtools.el --- Databases, clusters and APIs in one place  -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.7"))
;; Keywords: tools, sql

;;; Commentary:

;; Entry point.  Load this, set `devtools-profiles', enable
;; `devtools-mode' and bind `devtools-menu'.

;;; Code:

(require 'devtools-profiles)
(require 'devtools-sql)
(require 'devtools-menu)

(defcustom devtools-display-rules
  '(("\\`\\*SQL\\( Result\\)?: "
     (display-buffer-reuse-window display-buffer-at-bottom)
     (window-height . 0.35)))
  "Window placement rules added to `display-buffer-alist' by `devtools-mode'.
Same format as `display-buffer-alist'.  Toggle `devtools-mode' after
changing this to apply it."
  :type 'sexp
  :group 'devtools)

(defvar devtools--installed-display-rules nil
  "Rules `devtools-mode' added to `display-buffer-alist'.")

(defvar devtools--mode-line-entry
  '(devtools-mode (:eval (when devtools-profiles
                           (concat " " (devtools-profile-label)))))
  "Mode line construct showing the current environment.")

;;;###autoload
(define-minor-mode devtools-mode
  "Show the current environment, apply window rules and link query files."
  :global t
  :group 'devtools
  (remove-hook 'find-file-hook #'devtools-sql-link-query-file)
  (setq display-buffer-alist
        (seq-remove (lambda (rule) (memq rule devtools--installed-display-rules))
                    display-buffer-alist)
        devtools--installed-display-rules nil
        mode-line-misc-info (delete devtools--mode-line-entry mode-line-misc-info))
  (when devtools-mode
    (setq devtools--installed-display-rules (copy-tree devtools-display-rules)
          display-buffer-alist (append devtools--installed-display-rules
                                       display-buffer-alist))
    (add-hook 'find-file-hook #'devtools-sql-link-query-file)
    (push devtools--mode-line-entry mode-line-misc-info)))

(provide 'devtools)
;;; devtools.el ends here
