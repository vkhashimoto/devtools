package main

import (
	"context"
	"encoding/json"
)

type schemaColumn struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type schemaTable struct {
	Schema  string         `json:"schema"`
	Name    string         `json:"name"`
	Type    string         `json:"type"`
	Columns []schemaColumn `json:"columns"`
}

// Every column visible to the user, outside the system schemas.
const postgresSchemaQuery = `select c.table_schema, c.table_name, t.table_type, c.column_name, c.data_type
from information_schema.columns c
join information_schema.tables t using (table_schema, table_name)
where c.table_schema not in ('pg_catalog', 'information_schema')
order by c.table_schema, c.table_name, c.ordinal_position`

// describeSchema lists the tables and views of a connection with their
// columns, for completion.
func (s *server) describeSchema(ctx context.Context, raw json.RawMessage) (any, error) {
	var params struct {
		Connection string `json:"connection"`
	}
	if err := decodeParams(raw, &params); err != nil {
		return nil, err
	}
	conn, err := s.connection(params.Connection)
	if err != nil {
		return nil, err
	}
	rows, err := conn.pool.Query(ctx, postgresSchemaQuery)
	if err != nil {
		return nil, databaseError(err)
	}
	defer rows.Close()

	tables := []*schemaTable{}
	for rows.Next() {
		var schema, name, tableType, column, dataType string
		if err := rows.Scan(&schema, &name, &tableType, &column, &dataType); err != nil {
			return nil, databaseError(err)
		}
		if n := len(tables); n == 0 || tables[n-1].Schema != schema || tables[n-1].Name != name {
			tables = append(tables, &schemaTable{Schema: schema, Name: name, Type: tableType})
		}
		last := tables[len(tables)-1]
		last.Columns = append(last.Columns, schemaColumn{Name: column, Type: dataType})
	}
	if err := rows.Err(); err != nil {
		return nil, databaseError(err)
	}
	return map[string]any{"tables": tables}, nil
}
