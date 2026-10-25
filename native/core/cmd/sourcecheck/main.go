package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"juku/internal/sourcecheck"
	"juku/mobile"
	"os"
	"os/signal"
	"strings"
	"sync"
	"time"
)

func main() {
	sources := flag.String("sources", "", "comma-separated source IDs; default: all declared sources")
	query := flag.String("query", "长生", "search sample; excluded from the report")
	includeMedia := flag.Bool("media", false, "also resolve one episode and probe manifests, keys and its first media bytes")
	output := flag.String("output", "", "write the report to this file instead of stdout")
	flag.Parse()
	report, err := run(*sources, *query, *includeMedia)
	if err != nil {
		fmt.Fprintln(os.Stderr, "source check initialization failed")
		os.Exit(1)
	}
	encoded, err := json.MarshalIndent(report, "", "  ")
	if err == nil && *output != "" {
		err = os.WriteFile(*output, append(encoded, '\n'), 0600)
	} else if err == nil {
		_, err = fmt.Println(string(encoded))
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "source check report could not be written")
		os.Exit(1)
	}
}

type report struct {
	Format      string               `json:"format"`
	Version     int                  `json:"version"`
	At          time.Time            `json:"at"`
	CoreVersion string               `json:"coreVersion"`
	Environment string               `json:"environment"`
	Sources     []sourcecheck.Result `json:"sources"`
}

func newClient() (*mobile.Client, func(), error) {
	dir, err := os.MkdirTemp("", "guoguo-sourcecheck-")
	if err != nil {
		return nil, nil, err
	}
	client, err := mobile.NewClient(dir)
	if err != nil {
		os.RemoveAll(dir)
		return nil, nil, err
	}
	return client, func() { client.Close(); os.RemoveAll(dir) }, nil
}

func run(selection, query string, includeMedia bool) (report, error) {
	result := report{Format: "guoguo.source-check", Version: 1, At: time.Now().UTC(), Environment: "host"}
	if os.Getenv("GITHUB_ACTIONS") == "true" {
		result.Environment = "github-actions"
	}
	client, cleanup, err := newClient()
	if err != nil {
		return result, err
	}
	defer cleanup()
	raw, err := client.Call(`{"method":"sourceCapabilities"}`)
	if err != nil {
		return result, err
	}
	var capabilities struct {
		Items []sourcecheck.Capability `json:"items"`
	}
	if err := json.Unmarshal([]byte(raw), &capabilities); err != nil {
		return result, err
	}
	if raw, err := client.Call(`{"method":"coreInfo"}`); err == nil {
		var core struct {
			Version string `json:"version"`
		}
		json.Unmarshal([]byte(raw), &core)
		result.CoreVersion = core.Version
	}
	wanted := map[string]bool{}
	if selection != "" {
		for _, source := range strings.Split(selection, ",") {
			wanted[strings.TrimSpace(source)] = true
		}
	}
	var selected []sourcecheck.Capability
	for _, capability := range capabilities.Items {
		if selection == "" || wanted[capability.Source] {
			selected = append(selected, capability)
			delete(wanted, capability.Source)
		}
	}
	if len(wanted) > 0 || len(selected) == 0 {
		return result, fmt.Errorf("invalid source selection")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	result.Sources = make([]sourcecheck.Result, len(selected))
	slots := make(chan struct{}, 2)
	var group sync.WaitGroup
	for index, capability := range selected {
		group.Go(func() {
			slots <- struct{}{}
			defer func() { <-slots }()
			client, cleanup, err := newClient()
			if err != nil {
				result.Sources[index] = sourcecheck.Result{Source: capability.Source, SearchScope: capability.SearchScope, Steps: []sourcecheck.Step{{Operation: "initialize", Status: "failed", Reason: "other"}}}
				return
			}
			defer cleanup()
			result.Sources[index] = sourcecheck.Check(ctx, client, capability, query, includeMedia)
		})
	}
	group.Wait()
	return result, nil
}
