package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

const defaultMaxRows = 1000

type openParams struct {
	ID       string `json:"id"`
	Driver   string `json:"driver"`
	Host     string `json:"host"`
	Port     int    `json:"port"`
	User     string `json:"user"`
	Password string `json:"password"`
	Database string `json:"database"`
	ReadOnly bool   `json:"readOnly"`
	PoolSize int    `json:"poolSize"`
}

type pgConnection struct {
	pool *pgxpool.Pool
}

func (c *pgConnection) close() { c.pool.Close() }

// openConnection creates a pool for params.ID, replacing any open one.
// It connects once so bad credentials are reported here.
func (s *server) openConnection(ctx context.Context, raw json.RawMessage) (any, error) {
	var params openParams
	if err := decodeParams(raw, &params); err != nil {
		return nil, err
	}
	if params.ID == "" {
		return nil, &rpcError{Code: codeInvalidParams, Message: "id is required"}
	}
	if params.Driver != "postgres" {
		return nil, &rpcError{Code: codeInvalidParams, Message: "unsupported driver " + strconv.Quote(params.Driver)}
	}

	config, err := pgxpool.ParseConfig("")
	if err != nil {
		return nil, err
	}
	cc := config.ConnConfig
	if params.Host != "" {
		cc.Host = params.Host
	}
	if params.Port != 0 {
		cc.Port = uint16(params.Port)
	}
	if params.User != "" {
		cc.User = params.User
	}
	if params.Database != "" {
		cc.Database = params.Database
	}
	cc.Password = params.Password
	cc.RuntimeParams["application_name"] = "devtools"
	if params.ReadOnly {
		cc.RuntimeParams["default_transaction_read_only"] = "on"
	}
	if params.PoolSize > 0 {
		config.MaxConns = int32(params.PoolSize)
	}
	config.AfterRelease = resetConnection

	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, databaseError(err)
	}
	pingCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, databaseError(err)
	}

	s.mu.Lock()
	old := s.conns[params.ID]
	s.conns[params.ID] = &pgConnection{pool: pool}
	// Sessions keep the settings they were opened with; close them.
	s.dropSessions(params.ID)
	s.mu.Unlock()
	if old != nil {
		old.close()
	}
	return nil, nil
}

// resetConnection clears what a run left on a connection (SET, temp tables,
// prepared statements...) before it goes back to the pool, restoring its
// startup settings, read-only included.  A connection that cannot be
// reset is closed instead.
func resetConnection(conn *pgx.Conn) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := conn.PgConn().Exec(ctx, "DISCARD ALL").ReadAll(); err != nil {
		log.Printf("resetting a connection: %v", err)
		return false
	}
	// The server dropped its prepared statements; drop pgx's cached ones.
	if err := conn.DeallocateAll(ctx); err != nil {
		log.Printf("resetting a connection: %v", err)
		return false
	}
	return true
}

func (s *server) closeConnection(ctx context.Context, raw json.RawMessage) (any, error) {
	var params struct {
		ID string `json:"id"`
	}
	if err := decodeParams(raw, &params); err != nil {
		return nil, err
	}
	s.mu.Lock()
	conn := s.conns[params.ID]
	delete(s.conns, params.ID)
	s.dropSessions(params.ID)
	s.mu.Unlock()
	if conn != nil {
		conn.close()
	}
	return nil, nil
}

func (s *server) connection(id string) (*pgConnection, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	conn := s.conns[id]
	if conn == nil {
		return nil, &rpcError{Code: codeConnectionNotFound, Message: "connection " + strconv.Quote(id) + " is not open"}
	}
	return conn, nil
}

type column struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

// resultSet is one statement's result: rows (columns set) or a command tag.
// Values are Postgres' text format; NULL is nil.
type resultSet struct {
	Columns   []column    `json:"columns,omitempty"`
	Rows      [][]*string `json:"rows,omitempty"`
	TotalRows int         `json:"totalRows"`
	Command   string      `json:"command"`
}

type executeResult struct {
	ElapsedMs int64       `json:"elapsedMs"`
	Results   []resultSet `json:"results"`
	// TxStatus is set for runs on a session: idle, transaction or failed.
	TxStatus string `json:"txStatus,omitempty"`
}

// execute runs every statement of params.SQL and returns all results,
// each limited to maxRows rows (TotalRows counts all of them).  It runs
// on params.Session when given, else on a connection from the pool.
func (s *server) execute(ctx context.Context, raw json.RawMessage) (any, error) {
	var params struct {
		Connection string `json:"connection"`
		Session    string `json:"session"`
		SQL        string `json:"sql"`
		MaxRows    int    `json:"maxRows"`
	}
	if err := decodeParams(raw, &params); err != nil {
		return nil, err
	}
	if params.MaxRows <= 0 {
		params.MaxRows = defaultMaxRows
	}
	if params.Session != "" {
		return s.executeOnSession(ctx, params.Session, params.SQL, params.MaxRows)
	}
	conn, err := s.connection(params.Connection)
	if err != nil {
		return nil, err
	}
	pooled, err := conn.pool.Acquire(ctx)
	if err != nil {
		return nil, databaseError(err)
	}
	defer pooled.Release()
	result, err := runQuery(ctx, pooled.Conn(), params.SQL, params.MaxRows)
	if err != nil {
		return nil, databaseError(err)
	}
	return result, nil
}

// runQuery runs sql on conn with the simple protocol, so it may hold
// several statements, and collects every statement's result.
func runQuery(ctx context.Context, conn *pgx.Conn, sql string, maxRows int) (executeResult, error) {
	types := conn.TypeMap()
	started := time.Now()
	results := []resultSet{}
	reader := conn.PgConn().Exec(ctx, sql)
	for reader.NextResult() {
		rows := reader.ResultReader()
		var set resultSet
		for _, field := range rows.FieldDescriptions() {
			typeName := strconv.FormatUint(uint64(field.DataTypeOID), 10)
			if t, ok := types.TypeForOID(field.DataTypeOID); ok {
				typeName = t.Name
			}
			set.Columns = append(set.Columns, column{Name: field.Name, Type: typeName})
		}
		for rows.NextRow() {
			set.TotalRows++
			if len(set.Rows) >= maxRows {
				continue
			}
			values := rows.Values()
			row := make([]*string, len(values))
			for i, value := range values {
				if value != nil {
					text := string(value)
					row[i] = &text
				}
			}
			set.Rows = append(set.Rows, row)
		}
		tag, err := rows.Close()
		if err != nil {
			reader.Close()
			return executeResult{}, err
		}
		set.Command = tag.String()
		if set.Columns != nil && set.Rows == nil {
			set.Rows = [][]*string{}
		}
		results = append(results, set)
	}
	if err := reader.Close(); err != nil {
		return executeResult{}, err
	}
	return executeResult{ElapsedMs: time.Since(started).Milliseconds(), Results: results}, nil
}

// databaseError turns a driver error into a reply carrying Postgres'
// details when there are some.
func databaseError(err error) *rpcError {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		data := map[string]any{
			"sqlstate": pgErr.Code,
			"severity": pgErr.Severity,
		}
		if pgErr.Detail != "" {
			data["detail"] = pgErr.Detail
		}
		if pgErr.Hint != "" {
			data["hint"] = pgErr.Hint
		}
		if pgErr.Position != 0 {
			data["position"] = pgErr.Position
		}
		return &rpcError{Code: codeDatabaseError, Message: pgErr.Message, Data: data}
	}
	return &rpcError{Code: codeDatabaseError, Message: err.Error()}
}
