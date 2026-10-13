package main

import (
	"context"
	"io"
	"testing"
	"time"
)

func TestCancelOnEOFCancelsWhenWriterCloses(t *testing.T) {
	r, w := io.Pipe()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go cancelOnEOF(r, cancel)

	select {
	case <-ctx.Done():
		t.Fatal("cancelled before the writer closed")
	case <-time.After(50 * time.Millisecond):
	}

	_ = w.Close()
	select {
	case <-ctx.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("not cancelled after the writer closed")
	}
}
