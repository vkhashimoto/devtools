package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"
)

// client talks to a server running in the background over pipes.
type client struct {
	t      *testing.T
	in     *io.PipeWriter
	out    *bufio.Reader
	nextID int
	done   chan error
}

func startServer(t *testing.T) *client {
	t.Helper()
	inReader, inWriter := io.Pipe()
	outReader, outWriter := io.Pipe()
	s := newServer(outWriter)
	c := &client{t: t, in: inWriter, out: bufio.NewReader(outReader), done: make(chan error, 1)}
	go func() {
		err := s.serve(context.Background(), inReader)
		s.closeAll()
		outWriter.Close()
		c.done <- err
	}()
	t.Cleanup(func() {
		inWriter.Close()
		select {
		case <-c.done:
		case <-time.After(5 * time.Second):
			t.Error("server did not stop after stdin closed")
		}
	})
	return c
}

func (c *client) send(raw string) {
	c.t.Helper()
	if _, err := fmt.Fprintf(c.in, "Content-Length: %d\r\n\r\n%s", len(raw), raw); err != nil {
		c.t.Fatal(err)
	}
}

type reply struct {
	ID     int             `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
}

func (c *client) receive() reply {
	c.t.Helper()
	body, err := readMessage(c.out)
	if err != nil {
		c.t.Fatal(err)
	}
	var r reply
	if err := json.Unmarshal(body, &r); err != nil {
		c.t.Fatalf("%v in %s", err, body)
	}
	return r
}

// call sends a request and waits for its reply.
func (c *client) call(method string, params any) reply {
	c.t.Helper()
	c.nextID++
	body, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": c.nextID, "method": method, "params": params})
	if err != nil {
		c.t.Fatal(err)
	}
	c.send(string(body))
	r := c.receive()
	if r.ID != c.nextID {
		c.t.Fatalf("reply id %d, want %d", r.ID, c.nextID)
	}
	return r
}

func TestReadMessage(t *testing.T) {
	r := bufio.NewReader(strings.NewReader("Content-Length: 2\r\n\r\n{}Content-Length: 4\r\nContent-Type: x\r\n\r\nnull"))
	for _, want := range []string{"{}", "null"} {
		body, err := readMessage(r)
		if err != nil || string(body) != want {
			t.Fatalf("got %q, %v; want %q", body, err, want)
		}
	}
	if _, err := readMessage(r); err != io.EOF {
		t.Fatalf("got %v at the end, want EOF", err)
	}
	if _, err := readMessage(bufio.NewReader(strings.NewReader("Content-Length: x\r\n\r\n"))); err == nil {
		t.Fatal("bad Content-Length accepted")
	}
}

func TestInitialize(t *testing.T) {
	c := startServer(t)
	r := c.call("initialize", nil)
	if r.Error != nil {
		t.Fatal(r.Error)
	}
	var info struct {
		Name    string   `json:"name"`
		Drivers []string `json:"drivers"`
	}
	json.Unmarshal(r.Result, &info)
	if info.Name != "devtools-server" || len(info.Drivers) != 1 || info.Drivers[0] != "postgres" {
		t.Fatalf("unexpected initialize result %s", r.Result)
	}
}

func TestErrors(t *testing.T) {
	c := startServer(t)
	cases := []struct {
		method string
		params any
		code   int
	}{
		{"nope", nil, codeMethodNotFound},
		{"connection/open", map[string]any{"id": 3}, codeInvalidParams},
		{"connection/open", map[string]any{"id": "x", "driver": "mysql"}, codeInvalidParams},
		{"connection/open", map[string]any{"driver": "postgres"}, codeInvalidParams},
		{"query/execute", map[string]any{"connection": "missing", "sql": "select 1"}, codeConnectionNotFound},
	}
	for _, tc := range cases {
		r := c.call(tc.method, tc.params)
		if r.Error == nil || r.Error.Code != tc.code {
			t.Errorf("%s %v: got %+v, want code %d", tc.method, tc.params, r.Error, tc.code)
		}
	}
}

func TestNotificationsGetNoReply(t *testing.T) {
	c := startServer(t)
	c.send(`{"jsonrpc":"2.0","method":"nope"}`)
	// The next reply must be for the request, not the notification.
	if r := c.call("initialize", nil); r.Error != nil {
		t.Fatal(r.Error)
	}
}

func TestCloseUnknownConnection(t *testing.T) {
	c := startServer(t)
	if r := c.call("connection/close", map[string]any{"id": "missing"}); r.Error != nil {
		t.Fatal(r.Error)
	}
}
