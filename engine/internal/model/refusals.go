package model

import (
	"fmt"
	"net/http"
	"strings"
	"sync"
)

// Models differ in which optional request fields they accept: reasoning
// models refuse sampling settings or the legacy max_tokens cap, and the set
// changes with every release. Instead of tracking model IDs, a request that
// the service rejects for naming one of these fields is sent again without
// it, and the refusal is remembered for that endpoint, model and reasoning
// setting so later requests leave the field out from the start.

// optionalFields can be left out, letting the service use its own default.
var optionalFields = []string{"temperature", "top_p", "top_k", "logprobs", "top_logprobs", "presence_penalty", "frequency_penalty"}

// legacyTokenCap is the Chat Completions output cap that reasoning models
// refuse in favour of max_completion_tokens.
const legacyTokenCap = "max_tokens"

var refusals = struct {
	sync.Mutex
	fields map[string]map[string]bool
}{fields: map[string]map[string]bool{}}

func (c *Client) refusalKey() string {
	key := fmt.Sprintf("%s %s %s %s", c.Provider, strings.TrimRight(c.BaseURL, "/"), c.Model, c.ReasoningEffort)
	if c.Reasoning != nil {
		key += fmt.Sprintf(" %+v", *c.Reasoning)
	}
	return key
}

// refused is a copy of the fields this connection is known to refuse.
func (c *Client) refused() map[string]bool {
	refusals.Lock()
	defer refusals.Unlock()
	known := map[string]bool{}
	for field := range refusals.fields[c.refusalKey()] {
		known[field] = true
	}
	return known
}

func (c *Client) remember(fields []string) {
	refusals.Lock()
	defer refusals.Unlock()
	key := c.refusalKey()
	if refusals.fields[key] == nil {
		refusals.fields[key] = map[string]bool{}
	}
	for _, field := range fields {
		refusals.fields[key][field] = true
	}
}

// presentFields are the optional fields a request body carries.
func presentFields(body map[string]any) map[string]bool {
	present := map[string]bool{}
	for _, field := range optionalFields {
		if _, exists := body[field]; exists {
			present[field] = true
		}
	}
	return present
}

// refusedFields are the fields of a rejected request that the service's
// error names. Only an invalid-request status counts, and the legacy cap only
// when the service asks for max_completion_tokens instead; any other error
// is the user's to see.
func refusedFields(e *APIError, sent map[string]bool) []string {
	if e == nil || e.Status != http.StatusBadRequest && e.Status != http.StatusUnprocessableEntity {
		return nil
	}
	text := strings.ToLower(e.Param + " " + e.Message)
	var named []string
	for _, field := range optionalFields {
		if sent[field] && mentions(text, field) {
			named = append(named, field)
		}
	}
	if sent[legacyTokenCap] && mentions(text, legacyTokenCap) && mentions(text, "max_completion_tokens") {
		named = append(named, legacyTokenCap)
	}
	return named
}

// mentions reports whether text contains word on its own, so top_p is not
// found inside top_p_extra and logprobs is not found inside top_logprobs.
func mentions(text, word string) bool {
	for from := 0; ; {
		at := strings.Index(text[from:], word)
		if at < 0 {
			return false
		}
		start, end := from+at, from+at+len(word)
		if (start == 0 || !wordByte(text[start-1])) && (end == len(text) || !wordByte(text[end])) {
			return true
		}
		from = start + 1
	}
}

func wordByte(b byte) bool {
	return b == '_' || b >= 'a' && b <= 'z' || b >= '0' && b <= '9'
}
