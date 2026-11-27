package main

// These tests need the demo database (scripts/demo-db.sh); they run when
// DEVTOOLS_PG_PORT is set.

import (
	"encoding/json"
	"reflect"
	"testing"
)

func describeDemo(t *testing.T, c *client) []schemaTable {
	t.Helper()
	r := c.call("schema/describe", map[string]any{"connection": "local/app"})
	if r.Error != nil {
		t.Fatalf("schema/describe: %+v", r.Error)
	}
	var result struct {
		Tables []schemaTable `json:"tables"`
	}
	if err := json.Unmarshal(r.Result, &result); err != nil {
		t.Fatal(err)
	}
	return result.Tables
}

func findTable(tables []schemaTable, schema, name string) *schemaTable {
	for i := range tables {
		if tables[i].Schema == schema && tables[i].Name == name {
			return &tables[i]
		}
	}
	return nil
}

func TestDescribeSchema(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, nil)
	if _, err := executeDemo(t, c, "create schema if not exists describe_test; create or replace view describe_test.open_orders as select id, customer from orders where status = 'open'", 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { executeDemo(t, c, "drop schema describe_test cascade", 0) })

	tables := describeDemo(t, c)
	orders := findTable(tables, "public", "orders")
	if orders == nil {
		t.Fatalf("orders missing from %+v", tables)
	}
	want := []schemaColumn{{"id", "integer"}, {"customer", "text"}, {"total", "numeric"},
		{"status", "text"}, {"created_at", "timestamp with time zone"}}
	if orders.Type != "BASE TABLE" || !reflect.DeepEqual(orders.Columns, want) {
		t.Errorf("orders: %+v", orders)
	}
	view := findTable(tables, "describe_test", "open_orders")
	if view == nil || view.Type != "VIEW" || len(view.Columns) != 2 {
		t.Errorf("view: %+v", view)
	}
	for _, table := range tables {
		if table.Schema == "pg_catalog" || table.Schema == "information_schema" {
			t.Fatalf("system table listed: %+v", table)
		}
	}
}

func TestDescribeSchemaUnknownConnection(t *testing.T) {
	c := startServer(t)
	r := c.call("schema/describe", map[string]any{"connection": "missing"})
	if r.Error == nil || r.Error.Code != codeConnectionNotFound {
		t.Fatalf("got %+v", r.Error)
	}
}

// describe prepares its query; the pool reset must also forget it, or
// the next use of the connection would refer to a statement the server
// dropped.
func TestDescribeSchemaTwiceOnOneConnection(t *testing.T) {
	c := startServer(t)
	openDemo(t, c, map[string]any{"poolSize": 1})
	describeDemo(t, c)
	describeDemo(t, c)
}
