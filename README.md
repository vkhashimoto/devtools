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

Queries run through **devtools-server** (`server/`, Go).  Build it with Go 1.25
or later, with or without Nix (`nix develop` provides Go); Go downloads the
dependencies listed in `server/go.mod`:

```sh
cd server && go build -o ~/.local/bin/devtools-server .
```

Emacs needs to find it on `exec-path`, or set `devtools-server-program` to its
full path.  Emacs starts it on first use.

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
| `C-c C-c`   | Run the query at point (blank-line separated), or the region, on the file's session |
| `C-u C-c C-c` | The same, on the connection pool                           |
| `C-c C-z`   | psql REPL for this file's connection                         |
| `M-x devtools-sql-run-string` | Type a query and run it (outside a query file: pick a connection; runs on the pool) |
| `C-M-i`     | Complete table and column names (corfu, company, etc.)       |
| `M-x devtools-sql-refresh-schema` | Reload the names offered for completion |

Queries run through devtools-server; with several statements, the result of
the last one is shown.

- **Session** (default): each query file has a connection of its own, opened on
  its first run and closed when the buffer is killed.  `SET`, temp tables and
  transactions carry over between runs, like a psql session; the header lines
  show "in transaction" or "transaction failed", so an open transaction on
  prod is hard to miss.  A session runs one query at a time: while it is busy,
  `C-c C-c` refuses and `C-u C-c C-c` runs on the pool instead.  If the server
  stops, or the connection is reopened with other settings (profile changed),
  the session and its state are gone; the next run says so and starts a new
  one.
- **Pool**: each run borrows a connection, which is reset (`DISCARD ALL`)
  before going back, so `SET`, temp tables and read-only changes last for that
  run only, and a transaction left open is rolled back.

Set `devtools-sql-query-files-use-session` to nil to run on the pool by
default; `C-u` then picks the session.  The result buffer's header line says
which one ran the query.  On a read-only connection, write with
`BEGIN READ WRITE; ...; COMMIT;` in one run (or, in a session, `SET
default_transaction_read_only = off`, which lasts for that session).

NULL shows as `[NULL]`, distinct from an empty string, and errors show the
failing line with a caret, plus Postgres' detail and hint.

### Completion

Tables and columns load in the background when a query file opens (cached per
environment and connection), and reload after a successful `CREATE`, `ALTER`
or `DROP`.  What is offered depends on what comes before point:

| Before point      | Candidates                                            |
|-------------------|-------------------------------------------------------|
| `orders.`         | Columns of `orders`                                   |
| `o.`              | Columns of the table aliased `o` in the statement     |
| `sales.`          | Tables of the schema `sales`                          |
| anything else     | Columns of the statement's tables, then all tables    |

Tables outside `public` are offered qualified (`sales.leads`).  Annotations show
the column type, or whether a name is a table or a view.  Only tables your user
can see in `information_schema` are listed.

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

## devtools-server

Emacs and the server talk JSON-RPC 2.0 over the server's stdin/stdout, framed
like LSP (`Content-Length` headers).  Methods so far:

| Method             | Purpose                                                    |
|--------------------|------------------------------------------------------------|
| `initialize`       | Server name, version and drivers                           |
| `connection/open`  | Open (or replace) a pool: driver, host, port, user, password, database, readOnly, poolSize; closes its sessions |
| `connection/close` | Close a pool and its sessions                              |
| `session/open`     | Open a session on a connection: a connection of its own, with the pool's settings |
| `session/close`    | Close a session                                            |
| `query/execute`    | Run SQL on the pool, or on a session; every statement's columns, rows (text, NULL as null) or command tag, plus `txStatus` (idle, transaction, failed) for sessions |

Errors carry Postgres' SQLSTATE, detail, hint and position in `data` (and
`txStatus` for sessions).  A session runs one query at a time (a second one
gets a "busy" error); one whose connection dies is reported lost, never
silently replaced.

| Command                        | What it does                                   |
|--------------------------------|------------------------------------------------|
| `M-x devtools-server-events`   | Show the JSON-RPC messages exchanged           |
| `M-x devtools-server-stop`     | Stop the server, closing every connection; the next query starts it again |

The server's own log is in `*devtools-server stderr*`.

## Customizing

`M-x customize-group RET devtools`. Highlights:

- `devtools-profiles`: environments and their connections.
- `devtools-display-rules`: where devtools buffers open (`display-buffer-alist` format).
- `devtools-sql-read-only-in-production`: production sessions start read-only.
- `devtools-sql-query-files-use-session`: query files run on a session (default) or the pool.
- `devtools-sql-query-directory`: where query files are saved.
- `devtools-sql-result-max-rows`: rows shown in a result buffer (default 1000).
- `devtools-sql-result-copy-delimiter`, `-copy-header`, `-copy-null-as`: copy defaults.
- Faces `devtools-profile` / `devtools-production` / `devtools-sql-result-*`.
- Menu entries: `transient-append-suffix`, `transient-suffix-put`, etc.

## Nix

| Command           | What it does                                              |
|-------------------|-----------------------------------------------------------|
| `nix develop`     | Shell with `psql`, the Postgres server for the demo DB, and Go |
| `nix flake check` | Byte-compiles and runs the Emacs tests against a throwaway DB (tests needing devtools-server are skipped) |
| `nix build`       | Builds the package with the flake's Emacs                 |

To install it through Nix with your own Emacs, add `overlays.default` to your
nixpkgs and use `emacsPackages.devtools` (or `epkgs.devtools` in
`emacsWithPackages`).  `packages.default` is compiled for the flake's Emacs,
which may differ from yours.

## Tests

```sh
nix flake check                                  # Emacs tests, hermetic, without the server
./run-tests.sh                                   # unit tests, using your elpaca packages
nix develop -c bash -c 'scripts/demo-db.sh start && DEVTOOLS_PG_PORT=54329 ./run-tests.sh'
(cd server && DEVTOOLS_PG_PORT=54329 go test ./...)   # server tests
```

`run-tests.sh` builds devtools-server when Go is available, so the Emacs
tests can run queries end to end.  `nix flake check` cannot download Go
modules in its sandbox, so those tests are skipped there.
