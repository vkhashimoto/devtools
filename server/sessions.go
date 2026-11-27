package main

// A session is a connection of its own, kept until it is closed, so
// SET, temp tables and transactions carry over between its runs.  It is
// opened with the settings of its connection's pool (read-only
// included) but is not part of the pool.

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

type session struct {
	connection string
	conn       *pgx.Conn
	// running is held while a query runs; a session runs one at a time.
	running sync.Mutex
}

func (s *server) openSession(ctx context.Context, raw json.RawMessage) (any, error) {
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
	connectCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	pgConn, err := pgx.ConnectConfig(connectCtx, conn.connConfig())
	if err != nil {
		return nil, databaseError(err)
	}

	s.mu.Lock()
	// The connection may have been closed or replaced meanwhile.
	if s.conns[params.Connection] != conn {
		s.mu.Unlock()
		pgConn.Close(context.Background())
		return nil, &rpcError{Code: codeConnectionNotFound, Message: "connection " + strconv.Quote(params.Connection) + " was closed"}
	}
	s.nextSession++
	id := fmt.Sprintf("s%d", s.nextSession)
	s.sessions[id] = &session{connection: params.Connection, conn: pgConn}
	s.mu.Unlock()
	return map[string]any{"session": id}, nil
}

func (s *server) closeSession(ctx context.Context, raw json.RawMessage) (any, error) {
	var params struct {
		Session string `json:"session"`
	}
	if err := decodeParams(raw, &params); err != nil {
		return nil, err
	}
	s.mu.Lock()
	sess := s.sessions[params.Session]
	delete(s.sessions, params.Session)
	s.mu.Unlock()
	if sess != nil {
		sess.close()
	}
	return nil, nil
}

func (sess *session) close() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	sess.conn.Close(ctx)
}

// dropSessions closes the sessions of the connection id.  The caller
// holds s.mu.
func (s *server) dropSessions(id string) {
	for sid, sess := range s.sessions {
		if sess.connection == id {
			delete(s.sessions, sid)
			go sess.close()
		}
	}
}

func (s *server) executeOnSession(ctx context.Context, id, sql string, maxRows int) (any, error) {
	s.mu.Lock()
	sess := s.sessions[id]
	s.mu.Unlock()
	if sess == nil {
		return nil, &rpcError{Code: codeSessionNotFound, Message: "session " + strconv.Quote(id) + " does not exist; its state is gone"}
	}
	if !sess.running.TryLock() {
		return nil, &rpcError{Code: codeSessionBusy, Message: "the session is busy with another query"}
	}
	defer sess.running.Unlock()

	result, err := runQuery(ctx, sess.conn, sql, maxRows)
	if err == nil {
		result.TxStatus = txStatus(sess.conn)
		return result, nil
	}
	if sess.conn.IsClosed() {
		s.mu.Lock()
		if s.sessions[id] == sess {
			delete(s.sessions, id)
		}
		s.mu.Unlock()
		return nil, &rpcError{Code: codeSessionLost, Message: "the session's connection was lost, and its state with it: " + err.Error()}
	}
	rpcErr := databaseError(err)
	data, _ := rpcErr.Data.(map[string]any)
	if data == nil {
		data = map[string]any{}
	}
	data["txStatus"] = txStatus(sess.conn)
	rpcErr.Data = data
	return nil, rpcErr
}

// txStatus describes the transaction state of conn.
func txStatus(conn *pgx.Conn) string {
	switch conn.PgConn().TxStatus() {
	case 'I':
		return "idle"
	case 'T':
		return "transaction"
	case 'E':
		return "failed"
	default:
		return "unknown"
	}
}

// What a session holds that a new one would not have.
const sessionStateQuery = `select
  (select coalesce(array_agg(name order by name), '{}') from pg_settings where source = 'session'),
  (select coalesce(array_agg(relname::text order by relname), '{}') from pg_class
     where relnamespace = pg_my_temp_schema() and relkind in ('r', 'p', 'v', 'm')),
  (select coalesce(array_agg(name order by name), '{}') from pg_prepared_statements where from_sql),
  (select coalesce(array_agg(name order by name), '{}') from pg_cursors),
  (select coalesce(array_agg(channel order by channel), '{}') from pg_listening_channels() channel),
  (select count(*) from pg_locks where locktype = 'advisory' and pid = pg_backend_pid())`

type sessionState struct {
	Transaction   string   `json:"transaction"`
	Settings      []string `json:"settings"`
	TempTables    []string `json:"tempTables"`
	Prepared      []string `json:"prepared"`
	Cursors       []string `json:"cursors"`
	Listening     []string `json:"listening"`
	AdvisoryLocks int64    `json:"advisoryLocks"`
}

// describeSession reports what a session holds: its transaction state,
// SET changes, temp tables, prepared statements, cursors, LISTEN
// channels and advisory locks.  In a failed transaction nothing else
// can be queried, so only the transaction is reported.
func (s *server) describeSession(ctx context.Context, raw json.RawMessage) (any, error) {
	var params struct {
		Session string `json:"session"`
	}
	if err := decodeParams(raw, &params); err != nil {
		return nil, err
	}
	s.mu.Lock()
	sess := s.sessions[params.Session]
	s.mu.Unlock()
	if sess == nil {
		return nil, &rpcError{Code: codeSessionNotFound, Message: "session " + strconv.Quote(params.Session) + " does not exist; its state is gone"}
	}
	if !sess.running.TryLock() {
		return nil, &rpcError{Code: codeSessionBusy, Message: "the session is busy with another query"}
	}
	defer sess.running.Unlock()

	state := sessionState{Transaction: txStatus(sess.conn)}
	if state.Transaction == "failed" {
		return state, nil
	}
	// The simple protocol leaves no prepared statement behind in the session.
	err := sess.conn.QueryRow(ctx, sessionStateQuery, pgx.QueryExecModeSimpleProtocol).Scan(
		&state.Settings, &state.TempTables, &state.Prepared, &state.Cursors, &state.Listening, &state.AdvisoryLocks)
	if err != nil {
		return nil, databaseError(err)
	}
	return state, nil
}
