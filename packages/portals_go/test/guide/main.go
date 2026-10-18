package main

import (
	"log"
	"strconv"
	"strings"

	portals "github.com/Ziinc/portals/sdk/go"
)

func main() {
	// Portals starts this binary and appends the socket path as the last argument.
	w := portals.NewWorker(portals.Options{MaxConcurrency: 8, MaxStreams: 4})

	w.Handle("text_tools", "word_count", func(c *portals.Call, args portals.Args) (any, error) {
		text, err := args.String(0)
		if err != nil {
			return nil, err
		}
		return len(strings.Fields(text)), nil
	})

	w.Handle("text_tools", "parse_int", func(c *portals.Call, args portals.Args) (any, error) {
		text, err := args.String(0)
		if err != nil {
			return nil, err
		}
		return strconv.Atoi(text) // an error becomes %Portals.Error{kind: :remote}
	})

	w.Handle("text_tools", "progress", func(c *portals.Call, args portals.Args) (any, error) {
		steps, err := args.Int(0)
		if err != nil {
			return nil, err
		}
		for step := int64(1); step <= steps; step++ {
			// Blocks this goroutine until MyApp.Progress.report/1 returns.
			if _, err := c.Callback("Elixir.MyApp.Progress", "report", step); err != nil {
				return nil, err
			}
		}
		return steps, nil
	})

	w.Handle("text_tools", "notify", func(c *portals.Call, args portals.Args) (any, error) {
		pid, err := args.Pid(0)
		if err != nil {
			return nil, err
		}
		text, err := args.String(1)
		if err != nil {
			return nil, err
		}
		return "sent", c.SendMessage(pid, strings.ToUpper(text)) // fire-and-forget
	})

	w.HandleStream("text_tools", "upcase_stream", func(c *portals.Call, s *portals.Stream, args portals.Args) (any, error) {
		count := 0
		for {
			chunk, err := s.Recv() // io.EOF once the BEAM half-closes its side
			if err != nil {
				return count, nil // the stream's final result
			}
			text, _ := chunk.(string)
			if err := s.Send(strings.ToUpper(text)); err != nil { // blocks while the BEAM's credit is used up
				return nil, err
			}
			count++
		}
	})

	if err := w.Run(); err != nil {
		log.Fatal(err)
	}
}
