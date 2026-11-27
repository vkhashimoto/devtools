package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"sync"
)

type handlerFunc func(ctx context.Context, params json.RawMessage) (any, error)

type server struct {
	out     *messageWriter
	methods map[string]handlerFunc

	mu          sync.Mutex
	conns       map[string]*pgConnection
	sessions    map[string]*session
	nextSession int

	inflight sync.WaitGroup
}

func newServer(out io.Writer) *server {
	s := &server{
		out:      &messageWriter{w: out},
		conns:    map[string]*pgConnection{},
		sessions: map[string]*session{},
	}
	s.methods = map[string]handlerFunc{
		"initialize":       s.initialize,
		"connection/open":  s.openConnection,
		"connection/close": s.closeConnection,
		"query/execute":    s.execute,
		"session/open":     s.openSession,
		"session/close":    s.closeSession,
		"schema/describe":  s.describeSchema,
	}
	return s
}

// serve handles messages from in until it is closed.  Requests run
// concurrently; serve returns once the ones in flight have replied.
func (s *server) serve(ctx context.Context, in io.Reader) error {
	defer s.inflight.Wait()
	r := bufio.NewReader(in)
	for {
		body, err := readMessage(r)
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		var req request
		if err := json.Unmarshal(body, &req); err != nil {
			s.reply(json.RawMessage("null"), nil, &rpcError{Code: codeParseError, Message: err.Error()})
			continue
		}
		s.inflight.Add(1)
		go func() {
			defer s.inflight.Done()
			s.handle(ctx, req)
		}()
	}
}

func (s *server) handle(ctx context.Context, req request) {
	isNotification := len(req.ID) == 0
	method, ok := s.methods[req.Method]
	if !ok {
		if !isNotification {
			s.reply(req.ID, nil, &rpcError{Code: codeMethodNotFound, Message: "unknown method " + req.Method})
		}
		return
	}
	result, err := s.call(ctx, method, req.Params)
	if isNotification {
		return
	}
	if err != nil {
		var rpcErr *rpcError
		if !errors.As(err, &rpcErr) {
			rpcErr = &rpcError{Code: codeInternalError, Message: err.Error()}
		}
		s.reply(req.ID, nil, rpcErr)
		return
	}
	if result == nil {
		result = struct{}{}
	}
	s.reply(req.ID, result, nil)
}

// call runs a handler, turning a panic into an error reply.
func (s *server) call(ctx context.Context, method handlerFunc, params json.RawMessage) (result any, err error) {
	defer func() {
		if p := recover(); p != nil {
			err = fmt.Errorf("internal error: %v", p)
		}
	}()
	return method(ctx, params)
}

func (s *server) reply(id json.RawMessage, result any, rpcErr *rpcError) {
	if err := s.out.write(response{JSONRPC: "2.0", ID: id, Result: result, Error: rpcErr}); err != nil {
		log.Printf("writing reply: %v", err)
	}
}

// decodeParams unmarshals params into v, reporting invalid params.
func decodeParams(params json.RawMessage, v any) error {
	if len(params) == 0 {
		params = json.RawMessage("{}")
	}
	if err := json.Unmarshal(params, v); err != nil {
		return &rpcError{Code: codeInvalidParams, Message: err.Error()}
	}
	return nil
}

func (s *server) initialize(ctx context.Context, params json.RawMessage) (any, error) {
	return map[string]any{
		"name":    "devtools-server",
		"version": version,
		"drivers": []string{"postgres"},
	}, nil
}

// closeAll closes every session and connection.
func (s *server) closeAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for id, sess := range s.sessions {
		sess.close()
		delete(s.sessions, id)
	}
	for id, conn := range s.conns {
		conn.close()
		delete(s.conns, id)
	}
}
