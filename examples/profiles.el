;;; profiles.el --- Example devtools profiles  -*- lexical-binding: t; -*-

;; "local" points at the demo database (scripts/demo-db.sh).  Its
;; password goes in ~/.authinfo.gpg (or ~/.authinfo):
;;
;;   machine localhost port 54329 login dev password devpass

(setq devtools-profiles
      '((local
         :postgres ((:name "app" :host "localhost" :port 54329
                     :user "dev" :database "app")
                    (:name "admin" :host "localhost" :port 54329
                     :user "dev" :database "postgres")))
        (staging
         :postgres ((:name "app" :host "pg.staging.internal"
                     :user "app" :database "app")))
        (prod
         :production t
         :postgres ((:name "app" :host "pg.prod.internal"
                     :user "app_ro" :database "app")))))
