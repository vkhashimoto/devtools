#!/usr/bin/env bash
# Byte-compile and run the tests against the packages in your Emacs config.
# For the Postgres tests, start the demo DB first and set DEVTOOLS_PG_PORT=54329.
set -euo pipefail
cd "$(dirname "$0")"
builds="${ELPACA_BUILDS:-$HOME/.config/emacs/elpaca/builds}"
load_path=(-L .)
for pkg in transient compat cond-let llama seq; do
  [ -d "$builds/$pkg" ] && load_path+=(-L "$builds/$pkg")
done
emacs -Q --batch "${load_path[@]}" --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile devtools-profiles.el devtools-sql-result.el devtools-sql.el devtools-menu.el devtools.el
rm -f ./*.elc
emacs -Q --batch "${load_path[@]}" -l test/devtools-test.el -f ert-run-tests-batch-and-exit
