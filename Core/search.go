package main

import (
	"strings"
	"unicode"

	"golang.org/x/text/runes"
	"golang.org/x/text/transform"
	"golang.org/x/text/unicode/norm"
)

// MARK: - Searching a chat

// searchFold lowercases and drops accents, so "tukorfuro" finds "Tükörfúrógép".
func searchFold(s string) string {
	folded, _, err := transform.String(transform.Chain(norm.NFD, runes.Remove(runes.In(unicode.Mn)), norm.NFC), s)
	if err != nil {
		folded = s
	}
	return strings.ToLower(folded)
}

// searchMessages finds the chat's stored messages containing the text (ignoring case and
// accents), oldest first, at most the newest limit. HasMore: Messenger has older history the
// app can fetch (fetchOlder) to search further back.
func (c *Core) searchMessages(threadID, text string, limit int) apiMessagesPage {
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
	return c.messagesPage(found, c.canFetchOlder(threadID))
}
