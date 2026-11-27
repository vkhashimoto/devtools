// devtools-server connects devtools.el to databases.  Emacs starts it
// and talks JSON-RPC over stdin/stdout; logs go to stderr.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
)

var version = "0.1.0"

func main() {
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}

	log.SetFlags(0)
	log.SetPrefix("devtools-server: ")
	s := newServer(os.Stdout)
	err := s.serve(context.Background(), os.Stdin)
	s.closeAll()
	if err != nil {
		log.Fatal(err)
	}
}
