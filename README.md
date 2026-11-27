# devtools.el

Databases, clusters and APIs for the current environment, inside Emacs.
This first slice covers **environment profiles**, a **menu** and **Postgres**.

## Setup

Add to `config.org` *after* the magit section (it needs `transient`):

```elisp
(use-package devtools
  :ensure nil
  :load-path "~/code/poc/devtools"
  :demand t
  :bind ("C-c d" . devtools-menu)
  :config
  (load "~/code/poc/devtools/examples/profiles.el")  ; or your own profiles
  (devtools-mode 1))
```

Emacs must be able to find `psql`: add `postgresql` to your NixOS/home-manager
packages, or run commands from a buffer whose `.envrc` provides it
(this repo's `.envrc` loads the flake's dev shell, after `direnv allow`).

Passwords live in `~/.authinfo.gpg` (or `~/.authinfo`):

```
machine localhost port 54329 login dev password devpass
```

## Try it with the demo database

```sh
nix develop -c scripts/demo-db.sh start   # stop: nix develop -c scripts/demo-db.sh stop
```

Data lives in `~/.local/state/devtools-demo` (override with `DEVTOOLS_DEMO_DIR`).

Then in Emacs: `C-c d q`, pick `app`, write a query and press `C-c C-c`.
The rows show up as an aligned table in `*SQL Result: local/app*`.

## Keys

| Key       | Action                                            |
|-----------|---------------------------------------------------|
| `C-c d e` | Switch environment (menu stays open)              |
| `C-c d p` | psql REPL for a connection                        |
| `C-c d q` | Query file for a connection                       |

In a query file (`devtools-sql-query-mode`):

| Key         | Action                                                       |
|-------------|--------------------------------------------------------------|
| `C-c C-c`   | Run the query at point (blank-line separated), or the region |
| `C-c C-z`   | psql REPL for this file's connection                         |
| `M-x devtools-sql-run-string` | Type a query and run it                    |

Each query runs in its own psql process; with several statements, the result
of the last one is shown.  Session state (`SET`, temp tables, open
transactions) does not carry over between runs; use the REPL for that.

In a result buffer (`devtools-sql-result-mode`):

| Key       | Action                                                        |
|-----------|---------------------------------------------------------------|
| `n` / `p` | Down / up one row, same column                                |
| `f` / `b` | Right / left one column                                       |
| `m`       | Toggle the mark on the cell; with a region, mark the block    |
| `C`       | Mark the column (header excluded)                             |
| `U`       | Clear all marks                                               |
| `w`       | Copy the marked cells, or the cell at point                   |
| `W`       | Copy the row                                                  |
| `N`       | Copy NULL as nothing / as `NULL`                              |
| `H`       | Copy column names too                                         |
| `D`       | Choose the delimiter between copied cells                     |
| `g`       | Run the query again                                           |
| `q`       | Close the window                                              |
| `?`       | Menu with all of the above (like magit's `?`)               |

NULL shows as `[NULL]`, an empty string as an empty cell.  Org tables cannot
hold `|` or newlines, so those show (and copy) as `¦` and `↵`.

## Customizing

`M-x customize-group RET devtools`. Highlights:

- `devtools-profiles`: environments and their connections.
- `devtools-display-rules`: where devtools buffers open (`display-buffer-alist` format).
- `devtools-sql-read-only-in-production`: production sessions start read-only.
- `devtools-sql-query-directory`: where query files are saved.
- `devtools-sql-result-max-rows`: rows shown in a result buffer (default 1000).
- `devtools-sql-result-copy-delimiter`, `-copy-header`, `-copy-null-as`: copy defaults.
- Faces `devtools-profile` / `devtools-production` / `devtools-sql-result-*`.
- Menu entries: `transient-append-suffix`, `transient-suffix-put`, etc.

## Nix

| Command           | What it does                                              |
|-------------------|-----------------------------------------------------------|
| `nix develop`     | Shell with `psql` and the Postgres server for the demo DB |
| `nix flake check` | Byte-compiles and runs all tests against a throwaway DB   |
| `nix build`       | Builds the package with the flake's Emacs                 |

To install it through Nix with your own Emacs, add `overlays.default` to your
nixpkgs and use `emacsPackages.devtools` (or `epkgs.devtools` in
`emacsWithPackages`).  `packages.default` is compiled for the flake's Emacs,
which may differ from yours.

## Tests

```sh
nix flake check                                  # everything, hermetic
./run-tests.sh                                   # unit tests, using your elpaca packages
nix develop -c bash -c 'scripts/demo-db.sh start && DEVTOOLS_PG_PORT=54329 ./run-tests.sh'
```
