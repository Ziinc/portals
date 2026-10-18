package main

import (
	"fmt"
	"log"
	"runtime"
	"strings"

	portals "github.com/Ziinc/portals/sdk/go"
)

func main() {
	w := portals.NewWorker(portals.Options{})

	w.Handle("greeter", "hello", func(c *portals.Call, args portals.Args) (any, error) {
		name, err := args.String(0)
		if err != nil {
			return nil, err
		}
		version := strings.TrimPrefix(runtime.Version(), "go")
		return fmt.Sprintf("Hello, %s! I'm Go %s.", name, version), nil
	})

	if err := w.Run(); err != nil {
		log.Fatal(err)
	}
}
