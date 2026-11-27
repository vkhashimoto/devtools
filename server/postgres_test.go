package main

// These tests need the demo database (scripts/demo-db.sh); they run when
// DEVTOOLS_PG_PORT is set.

import (
	"encoding/json"
	"os"
	"reflect"
	"strconv"
	"testing"
)

func demoParams(t *testing.T) map[string]any {
	t.Helper()
	port, err := strconv.Atoi(os.Getenv("DEVTOOLS_PG_PORT"))
	if err != nil {
		t.Skip("DEVTOOLS_PG_PORT is not set")
	}
	return map[string]any{
		"id": "local/app", "driver": "postgres", "host": "localhost", "port": port,
		"user": "dev", "password": "devpass", "database": "app",
	}
}

func openDemo(t *testing.T, c *client, extra map[string]any) {
	t.Helper()
	params := demoParams(t)
	for k, v := range extra {
		params[k] = v
	}
	if r := c.call("connection/open", params); r.Error != nil {
		t.Fatalf("open: %+v", r.Error)
	}
}

func executeDemo(t *testing.T, c *client, sql string, maxRows int) (executeResult, *rpcError) {
	t.Helper()
	r := c.call("query/execute", map[string]any{"connection": "local/app", "sql": sql, "maxRows": maxRows})
	var result executeResult
	if r.Error == nil {
		if err := json.Unmarshal(r.Result, &result); err != nil {
			t.Fatal(err)
		}
	}
	return result, r.Error
}

func text(s string) *string { return &s }

func TestPostgresValuesAndTypes(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, nil)
	result, err := executeDemo(t, c, "select 1 as n, null::text as nothing, '' as empty, 12345678901234567890.5::numeric as big, 'a,\"b\"\nc' as tricky", 0)
	if err != nil {
		t.Fatal(err)
	}
	want := resultSet{
		Columns: []column{{"n", "int4"}, {"nothing", "text"}, {"empty", "text"}, {"big", "numeric"}, {"tricky", "text"}},
		Rows:    [][]*string{{text("1"), nil, text(""), text("12345678901234567890.5"), text("a,\"b\"\nc")}},
		// SELECT reports its row count in the command tag.
		TotalRows: 1,
		Command:   "SELECT 1",
	}
	if len(result.Results) != 1 || !reflect.DeepEqual(result.Results[0], want) {
		t.Fatalf("got %+v", result.Results)
	}
}

func TestPostgresMultipleStatements(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, nil)
	result, err := executeDemo(t, c, "select customer from orders order by id; update orders set status = status; select 1 where false", 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Results) != 3 {
		t.Fatalf("got %d results", len(result.Results))
	}
	first := result.Results[0]
	if first.TotalRows != 3 || len(first.Rows) != 2 || *first.Rows[1][0] != "globex" {
		t.Errorf("maxRows not applied: %+v", first)
	}
	if update := result.Results[1]; update.Command != "UPDATE 3" || update.Columns != nil {
		t.Errorf("update: %+v", update)
	}
	if empty := result.Results[2]; empty.Columns == nil || len(empty.Rows) != 0 || empty.TotalRows != 0 {
		t.Errorf("empty select: %+v", empty)
	}
}

func TestPostgresErrorDetails(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, nil)
	_, err := executeDemo(t, c, "select nope from orders", 0)
	if err == nil || err.Code != codeDatabaseError || err.Message != `column "nope" does not exist` {
		t.Fatalf("got %+v", err)
	}
	data := err.Data.(map[string]any)
	if data["sqlstate"] != "42703" || data["position"] != float64(8) {
		t.Errorf("data %v", data)
	}
	// The connection is still usable after an error.
	if _, err := executeDemo(t, c, "select 1", 0); err != nil {
		t.Fatal(err)
	}
}

func TestPostgresReadOnly(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, map[string]any{"readOnly": true})
	_, err := executeDemo(t, c, "delete from orders", 0)
	if err == nil || err.Data.(map[string]any)["sqlstate"] != "25006" {
		t.Fatalf("got %+v", err)
	}
}

func TestPostgresBadPassword(t *testing.T) {
	c := startServer(t)
	params := demoParams(t)
	params["password"] = "wrong"
	r := c.call("connection/open", params)
	if r.Error == nil || r.Error.Code != codeDatabaseError {
		t.Fatalf("got %+v", r.Error)
	}
	// A failed open leaves nothing behind.
	if _, err := executeDemo(t, c, "select 1", 0); err == nil || err.Code != codeConnectionNotFound {
		t.Fatalf("got %+v", err)
	}
}

func TestPostgresReopenReplacesPool(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, nil)
	openDemo(t, c, map[string]any{"readOnly": true})
	if _, err := executeDemo(t, c, "delete from orders", 0); err == nil {
		t.Fatal("reopened connection is not read-only")
	}
	if r := c.call("connection/close", map[string]any{"id": "local/app"}); r.Error != nil {
		t.Fatal(r.Error)
	}
	if _, err := executeDemo(t, c, "select 1", 0); err == nil || err.Code != codeConnectionNotFound {
		t.Fatalf("got %+v", err)
	}
}
