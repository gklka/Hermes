package main

import (
	"encoding/base64"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"

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
	Images    []webImage    `json:"images"`
	Links     []webLink     `json:"links"`
	Reactions []webReaction `json:"reactions"`
}

// webReaction is a reaction pill: its emoji and how many reacted (the page doesn't say who).
type webReaction struct {
	Emojis []string `json:"emojis"`
	Count  int      `json:"count"`
}

// importWebReactions stores the reactions shown on a message in a 1:1 chat. The page doesn't
// say who reacted, so a single reaction is taken to be the other person's on your messages and
// yours on theirs; a second emoji (or a count of two) is the other one of you.
func (c *Core) importWebReactions(messageID, threadID string, fromMe bool, reactions []webReaction) bool {
	self := c.selfID()
	first, second := self, threadID
	if fromMe {
		first, second = threadID, self
	}
	changed := false
	set := func(actor, emoji string) {
		c.store.SetReaction(messageID, actor, emoji)
		changed = true
	}
	for _, r := range reactions {
		switch {
		case len(r.Emojis) >= 2:
			set(first, r.Emojis[0])
			set(second, r.Emojis[1])
		case len(r.Emojis) == 1:
			set(first, r.Emojis[0])
			if r.Count >= 2 {
				set(second, r.Emojis[0])
			}
		}
	}
	return changed
}

// withoutEmoji drops emoji (and joiners/variation selectors) and spacing, to compare a message's
// text read before emoji were collected with the same text read with them.
func withoutEmoji(s string) string {
	var b strings.Builder
	for _, r := range s {
		if unicode.Is(unicode.So, r) || unicode.Is(unicode.Sk, r) || unicode.IsSpace(r) ||
			r == 0x200D || (r >= 0xFE00 && r <= 0xFE0F) || (r >= 0x1F3FB && r <= 0x1F3FF) {
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// webLink is a shared link's card as the web app shows it (link, title, picture).
type webLink struct {
	URL         string    `json:"url"`
	Title       string    `json:"title"`
	Description string    `json:"description"`
	Image       *webImage `json:"image"`
}

// importedBeforeLinks reports whether a stored message came from an earlier web import that
// didn't collect links (only web attachments, no link among them), so a newer import with the
// link may replace it.
func importedBeforeLinks(m *messageRow) bool {
	if len(m.Attachments) == 0 {
		return false
	}
	for _, a := range m.Attachments {
		if !strings.HasPrefix(a.ID, "web") || a.Kind == kindLink {
			return false
		}
	}
	return true
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

// unrestoredTexts are what the web app shows (lowercased, per language) in place of a message
// it couldn't decrypt because the chat history hasn't been restored with the PIN yet.
var unrestoredTexts = []string{
	"nem sikerült visszaállítani",
	"restore this message",
}

func isUnrestoredPlaceholder(text string) bool {
	lower := strings.ToLower(text)
	for _, t := range unrestoredTexts {
		if strings.Contains(lower, t) {
			return true
		}
	}
	return false
}

// importWebMessages stores decrypted history read from the web app for a 1:1 encrypted chat.
// Messages the live connection already delivered are left alone, except placeholders stored
// before the history was restored, which are replaced with the real message.
func (c *Core) importWebMessages(threadID string, messages []webMessage) map[string]any {
	self := c.selfID()
	cs := newChangeSet()
	imported := 0
	unrestored := 0
	var newest *messageRow
	for _, wm := range messages {
		id, ts, ok := webMessageID(wm.DOMID)
		if !ok {
			continue
		}
		if isUnrestoredPlaceholder(wm.Text) && len(wm.Images) == 0 {
			unrestored++
			continue
		}
		if c.importWebReactions(id, threadID, wm.FromMe, wm.Reactions) {
			cs.message(id)
		}
		if existing := c.store.GetMessage(id); existing != nil && !isUnrestoredPlaceholder(existing.Text) &&
			!(len(wm.Links) > 0 && importedBeforeLinks(existing)) {
			// Text read before emoji were collected gets its emoji.
			if wm.Text != "" && existing.Text != wm.Text && withoutEmoji(existing.Text) == withoutEmoji(wm.Text) {
				existing.Text = wm.Text
				c.store.PutMessage(existing)
				cs.message(id)
			}
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
		for i, link := range wm.Links {
			if link.URL == "" {
				continue
			}
			att := apiAttachment{ID: fmt.Sprintf("weblink%d", i), Kind: kindLink, URL: link.URL, Title: firstNonEmpty(link.Title, link.Description)}
			if link.Image != nil {
				// Numbered after the photos so the files don't collide.
				if path, err := c.saveWebImage(id, 100+i, *link.Image); err == nil {
					att.PreviewURL = (&url.URL{Scheme: "file", Path: path}).String()
					att.Width, att.Height = link.Image.Width, link.Image.Height
				} else {
					c.log.Warn().Err(err).Str("message_id", id).Msg("Failed to save a link's picture")
				}
			}
			row.Attachments = append(row.Attachments, storedAttachment{apiAttachment: att})
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
	c.log.Info().Str("thread_id", threadID).Int("received", len(messages)).Int("imported", imported).Int("unrestored", unrestored).Msg("Imported web message history")
	return map[string]any{"imported": imported, "unrestored": unrestored}
}

func (c *Core) saveWebImage(messageID string, index int, img webImage) (string, error) {
	data, err := base64.StdEncoding.DecodeString(img.Data)
	if err != nil {
		return "", err
	}
	path := filepath.Join(c.dataDir, "media", fmt.Sprintf("%s-web%d%s", messageID, index, extensionFor(img.MimeType)))
	return path, os.WriteFile(path, data, 0o600)
}

// webThreadPath is where the web app shows a chat, or "" if the encrypted chat's web ID isn't known yet.
func (c *Core) webThreadPath(threadID string) string {
	if t := c.store.GetThread(threadID); t != nil && t.Type.IsWhatsApp() {
		if webID := c.store.Get("webid:" + threadID); webID != "" {
			return "/messages/e2ee/t/" + webID + "/"
		}
		return ""
	}
	return fmt.Sprintf("/messages/t/%d/", c.fbThreadKey(threadID))
}

var hexColorPattern = regexp.MustCompile(`^#[0-9a-f]{6}$`)

// setThreadTheme stores the chat's custom bubble colors and quick reaction emoji read from the
// web app (empty: Messenger's default theme / like).
func (c *Core) setThreadTheme(threadID string, colors []string, emoji string) {
	for _, color := range colors {
		if !hexColorPattern.MatchString(color) {
			c.log.Warn().Str("thread_id", threadID).Strs("colors", colors).Msg("Ignoring invalid bubble colors")
			return
		}
	}
	if len(emoji) > 64 {
		c.log.Warn().Str("thread_id", threadID).Int("length", len(emoji)).Msg("Ignoring invalid quick reaction emoji")
		emoji = ""
	}
	changed := c.setOrDelete("colors:"+threadID, strings.Join(colors, ","))
	changed = c.setOrDelete("emoji:"+threadID, emoji) || changed
	if changed {
		cs := newChangeSet()
		cs.thread(threadID)
		c.flush(cs)
	}
}

// setOrDelete stores a kv value (deleting it when empty) and reports whether it changed.
func (c *Core) setOrDelete(key, value string) bool {
	if c.store.Get(key) == value {
		return false
	}
	if value == "" {
		c.store.Delete(key)
	} else {
		c.store.Set(key, value)
	}
	return true
}
