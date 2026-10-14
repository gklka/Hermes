package main

import (
	"strings"
	"unicode"

	"golang.org/x/text/runes"
	"golang.org/x/text/transform"
	"golang.org/x/text/unicode/norm"
)

// MARK: - Searching a chat

// searchFold lowercases and drops accents, so "uromorseg" finds "Ürömőrségi".
func searchFold(s string) string {
	folded, _, err := transform.String(transform.Chain(norm.NFD, runes.Remove(runes.In(unicode.Mn)), norm.NFC), s)
	if err != nil {
		folded = s
	}
	return strings.ToLower(folded)
}

// searchMessages finds the chat's stored messages containing the text (ignoring case and
// accents), oldest first, at most the newest limit.
func (c *Core) searchMessages(threadID, text string, limit int) map[string]any {
	query := searchFold(strings.TrimSpace(text))
	var found []*messageRow
	if query != "" {
		for _, m := range c.store.AllMessages(threadID) {
			if !m.IsSystem && !m.IsUnsent && strings.Contains(searchFold(m.Text), query) {
				found = append(found, m)
			}
		}
	}
	if limit > 0 && len(found) > limit {
		found = found[len(found)-limit:]
	}
	return map[string]any{
		"messages": c.store.APIMessages(found, c.selfID()),
		"hasMore":  c.canFetchOlder(threadID),
	}
}

// canFetchOlder tells whether Messenger has history before the oldest stored message
// (encrypted chats only have their unencrypted past there).
func (c *Core) canFetchOlder(threadID string) bool {
	t := c.store.GetThread(threadID)
	return t != nil && t.HasMoreBefore && (!t.Type.IsWhatsApp() || t.FBKey != "")
}

// fetchOlder loads one page of history before the oldest stored message from Messenger
// (synchronously, for search), and returns how many messages it added.
func (c *Core) fetchOlder(threadID string) apiFetchOlderResult {
	if !c.canFetchOlder(threadID) {
		return apiFetchOlderResult{}
	}
	before := c.store.MessageCount(threadID)
	refTs, refID := c.store.OldestMessage(threadID)
	c.backfill(threadID, refTs, refID)
	fetched := c.store.MessageCount(threadID) - before
	return apiFetchOlderResult{Fetched: fetched, HasMore: c.canFetchOlder(threadID)}
}
