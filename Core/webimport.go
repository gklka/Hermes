package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"go.mau.fi/mautrix-meta/pkg/messagix/table"
)

// Encrypted chats aren't in the LightSpeed thread lists, but Messenger's web app shows them.
// The Swift side reads the web app's chat list (WebChatImporter.swift) and hands rows to these
// functions, which map them to users and merge them into the store.

type webThreadRow struct {
	WebID     string `json:"webID"`
	UserID    string `json:"userID"`
	Name      string `json:"name"`
	AvatarURL string `json:"avatarURL"`
	Snippet   string `json:"snippet"`
	Age       string `json:"age"`
}

var avatarKeyPattern = regexp.MustCompile(`(\d+_\d+_\d+)_n\.`)

// avatarKey extracts the image ID from a profile picture URL; it's the same in every size variant.
func avatarKey(url string) string {
	if m := avatarKeyPattern.FindStringSubmatch(url); m != nil {
		return m[1]
	}
	return ""
}

func (s *Store) ContactByAvatarKey(key string) string {
	if key == "" {
		return ""
	}
	var id string
	_ = s.db.QueryRow(`SELECT id FROM contacts WHERE avatar_url LIKE ? LIMIT 1`, "%"+key+"%").Scan(&id)
	return id
}

var agePattern = regexp.MustCompile(`(\d+)\s*([^\d\s.]+)`)

// parseAge turns the chat list's relative time ("6 órája", "5 napja", "2 hete", "6h", "3 days")
// into a duration. Returns false if it can't be parsed.
func parseAge(label string) (time.Duration, bool) {
	label = strings.ToLower(strings.TrimSpace(label))
	switch label {
	case "", "most", "now", "just now", "épp most":
		return 0, label != ""
	}
	m := agePattern.FindStringSubmatch(label)
	if m == nil {
		return 0, false
	}
	n, _ := strconv.Atoi(m[1])
	unit := m[2]
	day := 24 * time.Hour
	var d time.Duration
	// Order matters: Hungarian "hete" (weeks) and "hónapja" (months) also start with "h".
	switch {
	case strings.HasPrefix(unit, "hét"), strings.HasPrefix(unit, "het"), strings.HasPrefix(unit, "w"):
		d = 7 * day
	case strings.HasPrefix(unit, "hó"), strings.HasPrefix(unit, "mo"):
		d = 30 * day
	case strings.HasPrefix(unit, "perc"), strings.HasPrefix(unit, "m"):
		d = time.Minute
	case strings.HasPrefix(unit, "ó"), strings.HasPrefix(unit, "h"):
		d = time.Hour
	case strings.HasPrefix(unit, "nap"), strings.HasPrefix(unit, "n"), strings.HasPrefix(unit, "d"):
		d = day
	case strings.HasPrefix(unit, "év"), strings.HasPrefix(unit, "y"):
		d = 365 * day
	default:
		return 0, false
	}
	return time.Duration(n) * d, true
}

// importWebThreads merges encrypted chats from the web app's chat list (in list order, newest
// first). Rows whose user can't be determined are returned so the app can resolve them by
// opening the chat.
func (c *Core) importWebThreads(rows []webThreadRow) map[string]any {
	self := c.selfID()
	now := time.Now().UnixMilli()

	// Before restoring with a PIN, every encrypted chat shows the same placeholder instead of
	// the last message; don't use that as a snippet.
	snippetCounts := map[string]int{}
	for _, r := range rows {
		snippetCounts[r.Snippet]++
	}

	cs := newChangeSet()
	unresolved := []string{}
	imported := 0
	prevTs := now
	for _, r := range rows {
		userID := r.UserID
		if userID == "" {
			userID = c.store.Get("webmap:" + r.WebID)
		}
		if userID == "" {
			userID = c.store.ContactByAvatarKey(avatarKey(r.AvatarURL))
		}
		if userID == "" || userID == self {
			unresolved = append(unresolved, r.WebID)
			continue
		}
		c.store.Set("webmap:"+r.WebID, userID)
		c.store.Set("webid:"+userID, r.WebID)

		ts := prevTs - 1
		if age, ok := parseAge(r.Age); ok {
			ts = min(now-age.Milliseconds(), prevTs-1)
		}
		prevTs = ts

		snippet := r.Snippet
		if snippetCounts[snippet] > 2 {
			snippet = ""
		}
		c.store.UpsertContact(userID, "", r.AvatarURL)
		if c.store.ContactName(userID) == "" {
			c.store.UpsertContact(userID, r.Name, "")
		}
		c.store.EnsureThread(userID, table.ENCRYPTED_OVER_WA_ONE_TO_ONE, "inbox")
		c.store.SetThreadType(userID, table.ENCRYPTED_OVER_WA_ONE_TO_ONE)
		c.store.SetThreadFolder(userID, "inbox")
		c.store.AddParticipant(userID, self, "", 0)
		c.store.AddParticipant(userID, userID, "", 0)
		// Only moves the chat forward in time; real messages keep their exact timestamps.
		c.store.BumpThread(userID, ts, snippet, "")
		cs.thread(userID)
		imported++
	}
	c.flush(cs)
	c.log.Info().Int("rows", len(rows)).Int("imported", imported).Int("unresolved", len(unresolved)).Msg("Imported web chat list")
	return map[string]any{"imported": imported, "unresolved": unresolved}
}

// MARK: - Message history

type webImage struct {
	Data     string `json:"data"` // base64
	MimeType string `json:"mimeType"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
}

type webMessage struct {
	// The web app's data-message-id: "<chat user>@msgr.<message ID>".
	DOMID  string     `json:"domID"`
	FromMe bool       `json:"fromMe"`
	Text   string     `json:"text"`
	Images []webImage `json:"images"`
}

// webMessageID splits the web app's message element ID into the real end-to-end message ID and
// its timestamp. Messenger message IDs are offline threading IDs: milliseconds << 22 | random.
func webMessageID(domID string) (id string, timestampMs int64, ok bool) {
	dot := strings.LastIndex(domID, ".")
	if dot < 0 {
		return "", 0, false
	}
	id = domID[dot+1:]
	n, err := strconv.ParseUint(id, 10, 64)
	if err != nil {
		return "", 0, false
	}
	return id, int64(n >> 22), true
}

// importWebMessages stores decrypted history read from the web app for a 1:1 encrypted chat.
// Messages the live connection already delivered are left alone.
func (c *Core) importWebMessages(threadID string, messages []webMessage) map[string]any {
	self := c.selfID()
	cs := newChangeSet()
	imported := 0
	var newest *messageRow
	for _, wm := range messages {
		id, ts, ok := webMessageID(wm.DOMID)
		if !ok || c.store.GetMessage(id) != nil {
			continue
		}
		sender := threadID
		if wm.FromMe {
			sender = self
		}
		row := &messageRow{
			ID:        id,
			ThreadID:  threadID,
			SenderID:  sender,
			Timestamp: ts,
			Text:      wm.Text,
			WAChat:    threadID + "@msgr",
			WASender:  sender + "@msgr",
		}
		for i, img := range wm.Images {
			path, err := c.saveWebImage(id, i, img)
			if err != nil {
				c.log.Warn().Err(err).Str("message_id", id).Msg("Failed to save imported image")
				continue
			}
			kind := kindImage
			if img.MimeType == "image/gif" {
				kind = kindGIF
			}
			row.Attachments = append(row.Attachments, storedAttachment{apiAttachment: apiAttachment{
				ID: fmt.Sprintf("web%d", i), Kind: kind, LocalPath: path, Width: img.Width, Height: img.Height, MimeType: img.MimeType,
			}})
		}
		if row.Text == "" && len(row.Attachments) == 0 {
			continue
		}
		c.store.PutMessage(row)
		cs.message(id)
		imported++
		if newest == nil || ts > newest.Timestamp {
			newest = row
		}
	}
	if newest != nil {
		c.store.BumpThread(threadID, newest.Timestamp, snippetFor(newest.Text, len(newest.Attachments) > 0), newest.SenderID)
		cs.thread(threadID)
	}
	c.flush(cs)
	c.log.Info().Str("thread_id", threadID).Int("received", len(messages)).Int("imported", imported).Msg("Imported web message history")
	return map[string]any{"imported": imported}
}

func (c *Core) saveWebImage(messageID string, index int, img webImage) (string, error) {
	data, err := base64.StdEncoding.DecodeString(img.Data)
	if err != nil {
		return "", err
	}
	path := filepath.Join(c.dataDir, "media", fmt.Sprintf("%s-web%d%s", messageID, index, extensionFor(img.MimeType)))
	return path, os.WriteFile(path, data, 0o600)
}
