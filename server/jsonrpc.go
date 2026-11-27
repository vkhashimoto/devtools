package main

// JSON-RPC 2.0 messages framed like the Language Server Protocol: each
// message is preceded by a "Content-Length: N" header and a blank line.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net/textproto"
	"strconv"
	"strings"
	"sync"
)

// Error codes defined by JSON-RPC, plus the server's own.
const (
	codeParseError     = -32700
	codeInvalidRequest = -32600
	codeMethodNotFound = -32601
	codeInvalidParams  = -32602
	codeInternalError  = -32603

	codeDatabaseError      = -32001
	codeConnectionNotFound = -32002
	codeSessionNotFound    = -32003
	codeSessionBusy        = -32004
	codeSessionLost        = -32005
)

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

func (e *rpcError) Error() string { return e.Message }

// readMessage reads one framed message and returns its body.
func readMessage(r *bufio.Reader) ([]byte, error) {
	headers, err := textproto.NewReader(r).ReadMIMEHeader()
	if err != nil {
		if err == io.EOF {
			return nil, io.EOF
		}
		return nil, fmt.Errorf("reading headers: %w", err)
	}
	length, err := strconv.Atoi(strings.TrimSpace(headers.Get("Content-Length")))
	if err != nil || length < 0 {
		return nil, fmt.Errorf("invalid Content-Length %q", headers.Get("Content-Length"))
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, fmt.Errorf("reading body: %w", err)
	}
	return body, nil
}

// messageWriter writes framed messages; safe for concurrent use.
type messageWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (m *messageWriter) write(v any) error {
	body, err := json.Marshal(v)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, err := fmt.Fprintf(m.w, "Content-Length: %d\r\n\r\n", len(body)); err != nil {
		return err
	}
	_, err = m.w.Write(body)
	return err
}
