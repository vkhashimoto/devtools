package main

// These tests need the demo database (scripts/demo-db.sh); they run when
// DEVTOOLS_PG_PORT is set.

import (
	"encoding/json"
	"testing"
	"time"
)

func openSession(t *testing.T, c *client) string {
	t.Helper()
	r := c.call("session/open", map[string]any{"connection": "local/app"})
	if r.Error != nil {
		t.Fatalf("session/open: %+v", r.Error)
	}
	var result struct {
		Session string `json:"session"`
	}
	json.Unmarshal(r.Result, &result)
	if result.Session == "" {
		t.Fatalf("no session id in %s", r.Result)
	}
	return result.Session
}

func executeSession(t *testing.T, c *client, session, sql string) (executeResult, *rpcError) {
	t.Helper()
	r := c.call("query/execute", map[string]any{"connection": "local/app", "session": session, "sql": sql})
	var result executeResult
	if r.Error == nil {
		if err := json.Unmarshal(r.Result, &result); err != nil {
			t.Fatal(err)
		}
	}
	return result, r.Error
}

// lastValue returns the first value of the last result.
func lastValue(t *testing.T, result executeResult, err *rpcError) string {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
	last := result.Results[len(result.Results)-1]
	return *last.Rows[0][0]
}

func sessionValue(t *testing.T, c *client, session, sql string) string {
	t.Helper()
	result, err := executeSession(t, c, session, sql)
	return lastValue(t, result, err)
}

func poolValue(t *testing.T, c *client, sql string) string {
	t.Helper()
	result, err := executeDemo(t, c, sql, 0)
	return lastValue(t, result, err)
}

func TestSessionKeepsState(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, nil)
	s := openSession(t, c)

	result, err := executeSession(t, c, s, "set search_path = nowhere, public; create temp table notes (x int)")
	if err != nil || result.TxStatus != "idle" {
		t.Fatalf("got %+v, %+v", result, err)
	}
	if got := sessionValue(t, c, s, "show search_path"); got != "nowhere, public" {
		t.Errorf("search_path %q", got)
	}
	if _, err := executeSession(t, c, s, "select * from notes"); err != nil {
		t.Errorf("temp table gone: %+v", err)
	}
	// Pooled runs do not see the session's state.
	if _, err := executeDemo(t, c, "select * from notes", 0); err == nil {
		t.Error("pooled run sees the session's temp table")
	}
}

func TestSessionTransactionAcrossRuns(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, nil)
	s := openSession(t, c)

	result, err := executeSession(t, c, s, "begin")
	if err != nil || result.TxStatus != "transaction" {
		t.Fatalf("begin: %+v, %+v", result, err)
	}
	if _, err := executeSession(t, c, s, "update orders set status = 'session' where id = 1"); err != nil {
		t.Fatal(err)
	}
	// Uncommitted: the session sees it, a pooled run does not.
	if got := sessionValue(t, c, s, "select status from orders where id = 1"); got != "session" {
		t.Errorf("session sees %q", got)
	}
	if got := poolValue(t, c, "select status from orders where id = 1"); got != "open" {
		t.Errorf("pool sees %q before the commit", got)
	}

	// An error fails the transaction, and the reply says so.
	_, err = executeSession(t, c, s, "select nope")
	if err == nil || err.Data.(map[string]any)["txStatus"] != "failed" {
		t.Fatalf("got %+v", err)
	}
	result, err = executeSession(t, c, s, "rollback")
	if err != nil || result.TxStatus != "idle" {
		t.Fatalf("rollback: %+v, %+v", result, err)
	}
	if got := poolValue(t, c, "select status from orders where id = 1"); got != "open" {
		t.Errorf("rolled back update visible: %q", got)
	}
}

func TestSessionIsReadOnlyLikeItsPool(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, map[string]any{"readOnly": true})
	s := openSession(t, c)
	_, err := executeSession(t, c, s, "delete from orders where false")
	if err == nil || err.Data.(map[string]any)["sqlstate"] != "25006" {
		t.Fatalf("got %+v", err)
	}
	// Turning it off is deliberate and lasts for the session.
	if _, err := executeSession(t, c, s, "set default_transaction_read_only = off"); err != nil {
		t.Fatal(err)
	}
	if _, err := executeSession(t, c, s, "delete from orders where false"); err != nil {
		t.Fatal(err)
	}
}

func TestSessionRunsOneQueryAtATime(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, nil)
	s := openSession(t, c)

	// Send a slow query, then another before the first one ends.
	slow, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 100, "method": "query/execute",
		"params": map[string]any{"session": s, "sql": "select pg_sleep(0.5)"}})
	fast, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 101, "method": "query/execute",
		"params": map[string]any{"session": s, "sql": "select 1"}})
	c.send(string(slow))
	time.Sleep(100 * time.Millisecond)
	c.send(string(fast))

	replies := map[int]reply{}
	for range 2 {
		r := c.receive()
		replies[r.ID] = r
	}
	if r := replies[101]; r.Error == nil || r.Error.Code != codeSessionBusy {
		t.Errorf("second query: %+v", r.Error)
	}
	if r := replies[100]; r.Error != nil {
		t.Errorf("slow query: %+v", r.Error)
	}
	// Free again afterwards.
	if _, err := executeSession(t, c, s, "select 1"); err != nil {
		t.Fatal(err)
	}
}

func TestSessionClose(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, nil)
	s := openSession(t, c)
	if r := c.call("session/close", map[string]any{"session": s}); r.Error != nil {
		t.Fatal(r.Error)
	}
	if _, err := executeSession(t, c, s, "select 1"); err == nil || err.Code != codeSessionNotFound {
		t.Fatalf("got %+v", err)
	}
	// Closing again, or an unknown session, is fine.
	if r := c.call("session/close", map[string]any{"session": s}); r.Error != nil {
		t.Fatal(r.Error)
	}
}

func TestSessionsCloseWithTheirConnection(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, nil)
	reopened := openSession(t, c)
	openDemo(t, c, map[string]any{"readOnly": true}) // replaces the pool
	if _, err := executeSession(t, c, reopened, "select 1"); err == nil || err.Code != codeSessionNotFound {
		t.Fatalf("session survived reopening its connection: %+v", err)
	}
	closed := openSession(t, c)
	c.call("connection/close", map[string]any{"id": "local/app"})
	if _, err := executeSession(t, c, closed, "select 1"); err == nil || err.Code != codeSessionNotFound {
		t.Fatalf("session survived closing its connection: %+v", err)
	}
	if r := c.call("session/open", map[string]any{"connection": "local/app"}); r.Error == nil || r.Error.Code != codeConnectionNotFound {
		t.Fatalf("session opened on a closed connection: %+v", r.Error)
	}
}

func TestSessionLost(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, nil)
	s := openSession(t, c)
	pid := sessionValue(t, c, s, "select pg_backend_pid()")
	if _, err := executeDemo(t, c, "select pg_terminate_backend("+pid+")", 0); err != nil {
		t.Fatal(err)
	}
	_, err := executeSession(t, c, s, "select 1")
	if err == nil || err.Code != codeSessionLost {
		t.Fatalf("got %+v", err)
	}
	if _, err := executeSession(t, c, s, "select 1"); err == nil || err.Code != codeSessionNotFound {
		t.Fatalf("lost session still listed: %+v", err)
	}
}

// Sessions on different connections, or pooled runs next to a busy
// session, do not wait for each other.
func TestSessionDoesNotBlockThePool(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, nil)
	s := openSession(t, c)
	slow, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 200, "method": "query/execute",
		"params": map[string]any{"session": s, "sql": "select pg_sleep(0.5)"}})
	c.send(string(slow))
	time.Sleep(100 * time.Millisecond)
	pooled, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 201, "method": "query/execute",
		"params": map[string]any{"connection": "local/app", "sql": "select 1"}})
	started := time.Now()
	c.send(string(pooled))
	first := c.receive()
	if first.ID != 201 || first.Error != nil || time.Since(started) > 300*time.Millisecond {
		t.Fatalf("pooled run waited for the session: %+v after %v", first, time.Since(started))
	}
	c.receive()
}

// When only the password changes, the pool and its sessions stay; the
// new password is checked, then used for new connections.
func TestPasswordChangeKeepsPoolAndSessions(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, nil)
	s := openSession(t, c)
	if _, err := executeSession(t, c, s, "create temp table kept (x int)"); err != nil {
		t.Fatal(err)
	}
	if _, err := executeDemo(t, c, "alter role dev password 'rotated'", 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		params := demoParams(t)
		if r := c.call("connection/open", params); r.Error != nil {
			// The pool may hold the rotated password; reopen with it.
			params["password"] = "rotated"
			c.call("connection/open", params)
		}
		executeDemo(t, c, "alter role dev password 'devpass'", 0)
	})

	// A wrong password is refused and changes nothing.
	r := c.call("connection/open", map[string]any{"id": "local/app", "driver": "postgres", "host": "localhost",
		"port": demoParams(t)["port"], "user": "dev", "password": "wrong", "database": "app"})
	if r.Error == nil || r.Error.Code != codeDatabaseError {
		t.Fatalf("wrong password accepted: %+v", r.Error)
	}

	r = c.call("connection/open", map[string]any{"id": "local/app", "driver": "postgres", "host": "localhost",
		"port": demoParams(t)["port"], "user": "dev", "password": "rotated", "database": "app"})
	if r.Error != nil || string(r.Result) != `{"kept":true}` {
		t.Fatalf("password update: %s %+v", r.Result, r.Error)
	}
	if _, err := executeSession(t, c, s, "select * from kept"); err != nil {
		t.Fatalf("session lost its state: %+v", err)
	}
	// New connections use the new password: a new session and a pooled run.
	openSession(t, c)
	if _, err := executeDemo(t, c, "select 1", 0); err != nil {
		t.Fatal(err)
	}
}
