package main

import (
	"fmt"
	"os"
	"time"
)

func main() {
	fmt.Println("=== Phase 1 smoke test PASSED ===")
	fmt.Printf("Time     : %s\n", time.Now().UTC().Format(time.RFC3339))
	fmt.Printf("Hostname : %s\n", hostname())
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil {
		return "unknown"
	}
	return h
}
