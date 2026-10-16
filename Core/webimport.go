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
	"unicode/utf8"

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

var spelledOnePattern = regexp.MustCompile(`\b(an?|one|egy)\b`)

// parseAge turns the chat list's relative time ("6 órája", "5 napja", "2 hete", "6h", "3 days")
// into a duration, and its unit: the label is rounded down, so the real age is less than one
// unit more. Returns false if it can't be parsed.
func parseAge(label string) (age, unit time.Duration, ok bool) {
	label = strings.ToLower(strings.TrimSpace(label))
	switch label {
	case "", "most", "now", "just now", "épp most":
		return 0, time.Minute, label != ""
	}
	// "about an hour ago", "kb. egy órája", "a week ago": a spelled-out one.
	label = spelledOnePattern.ReplaceAllString(label, "1")
	m := agePattern.FindStringSubmatch(label)
	if m == nil {
		return 0, 0, false
	}
	n, _ := strconv.Atoi(m[1])
	name := m[2]
	day := 24 * time.Hour
	// Order matters: Hungarian "hete" (weeks) and "hónapja" (months) also start with "h".
	switch {
	case strings.HasPrefix(name, "hét"), strings.HasPrefix(name, "het"), strings.HasPrefix(name, "w"):
		unit = 7 * day
	case strings.HasPrefix(name, "hó"), strings.HasPrefix(name, "mo"):
		unit = 30 * day
	case strings.HasPrefix(name, "p"), strings.HasPrefix(name, "m"):
		unit = time.Minute
	case strings.HasPrefix(name, "ó"), strings.HasPrefix(name, "h"):
		unit = time.Hour
	case strings.HasPrefix(name, "nap"), strings.HasPrefix(name, "n"), strings.HasPrefix(name, "d"):
		unit = day
	case strings.HasPrefix(name, "év"), strings.HasPrefix(name, "y"):
		unit = 365 * day
	default:
		return 0, 0, false
	}
	return time.Duration(n) * unit, unit, true
}

// importWebThreads merges encrypted chats from the web app's chat list (in list order, newest
// first). Rows whose user can't be determined are returned so the app can resolve them by
// opening the chat.
func (c *Core) importWebThreads(rows []webThreadRow) apiThreadImportResult {
	self := c.selfID()
	now := time.Now().UnixMilli()

	// Before restoring with a PIN, every encrypted chat shows the same placeholder instead of
	// the last message; don't use that as a snippet.
	snippetCounts := map[string]int{}
	for _, r := range rows {
		snippetCounts[r.Snippet]++
	}

	// The earliest each row's message can be from. The list rounds its times down ("6 órája" is
	// 6–7 hours ago); a time that can't be read (parseAge knows English and Hungarian) is newer
	// than the row below it.
	earliest := make([]int64, len(rows))
	var below int64
	for i := len(rows) - 1; i >= 0; i-- {
		earliest[i] = below
		if age, unit, ok := parseAge(rows[i].Age); ok {
			earliest[i] = now - (age + unit).Milliseconds()
			below = earliest[i]
		}
	}

	cs := newChangeSet()
	unresolved := []string{}
	imported := 0
	prevTs := now
	for i, r := range rows {
		userID := r.UserID
		if userID == "" {
			userID = c.store.Get(kvWebMap + r.WebID)
		}
		if userID == "" {
			userID = c.store.ContactByAvatarKey(avatarKey(r.AvatarURL))
		}
		if userID == "" || userID == self {
			unresolved = append(unresolved, r.WebID)
			continue
		}
		c.store.Set(kvWebMap+r.WebID, userID)
		c.store.Set(kvWebID+userID, r.WebID)

		ts := prevTs - 1
		var unit time.Duration
		if age, ageUnit, ok := parseAge(r.Age); ok {
			ts = min(now-age.Milliseconds(), prevTs-1)
			unit = ageUnit
		}
		prevTs = ts
		c.log.Debug().Str("thread_id", userID).Str("age", r.Age).Time("guess", time.UnixMilli(ts)).Msg("Web chat list row")

		snippet := r.Snippet
		if snippetCounts[snippet] > 2 {
			snippet = ""
		}
		c.store.UpsertContact(userID, "", r.AvatarURL)
		if c.store.ContactName(userID) == "" {
			c.store.UpsertContact(userID, r.Name, "")
		}
		c.store.EnsureEncryptedDirectThread(userID, self)
		// An existing row may be the old unencrypted chat, or in another folder.
		c.store.SetThreadType(userID, table.ENCRYPTED_OVER_WA_ONE_TO_ONE)
		c.store.SetThreadFolder(userID, folderInbox)
		if latest := c.store.ListMessages(userID, 0, 1); len(latest) == 1 && latest[0].Timestamp >= earliest[i] {
			// Our newest message is the one shown: use its exact time and text (this also undoes
			// an earlier guess that put the chat later than it is).
			m := latest[0]
			c.store.SetThreadLatest(userID, m.Timestamp, snippetFor(m.Text, len(m.Attachments) > 0), m.SenderID)
		} else {
			// The web app knows a newer message: moves the chat forward in time, unless the
			// list's time is only later by its rounding ("15 hete" is 15–16 weeks ago).
			if t := c.store.GetThread(userID); t == nil || ts-unit.Milliseconds() > t.LastActivity {
				c.store.BumpThread(userID, ts, snippet, "")
			}
			// A chat without a snippet (no stored messages) gets the list's, and one read before
			// emoji were collected gets them.
			if snippet != "" {
				c.store.SetThreadSnippetIfEmpty(userID, snippet)
				if t := c.store.GetThread(userID); t != nil && t.Snippet != snippet && withoutEmoji(t.Snippet) == withoutEmoji(snippet) {
					c.store.SetThreadSnippet(userID, snippet, t.SnippetSenderID)
				}
			}
		}
		cs.thread(userID)
		imported++
	}
	c.flush(cs)
	c.log.Info().Int("rows", len(rows)).Int("imported", imported).Int("unresolved", len(unresolved)).Msg("Imported web chat list")
	return apiThreadImportResult{Imported: imported, Unresolved: unresolved}
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
	DOMID     string        `json:"domID"`
	FromMe    bool          `json:"fromMe"`
	Text      string        `json:"text"`
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

// repeatedTexts finds the placeholder in languages unrestoredTexts doesn't know: a long text
// shown for several messages without pictures.
func repeatedTexts(messages []webMessage) map[string]bool {
	counts := map[string]int{}
	for _, wm := range messages {
		if len(wm.Images) == 0 && utf8.RuneCountInString(wm.Text) >= 20 {
			counts[wm.Text]++
		}
	}
	out := map[string]bool{}
	for text, n := range counts {
		if n >= 3 {
			out[text] = true
		}
	}
	return out
}

// importWebMessages stores decrypted history read from the web app for a 1:1 encrypted chat.
// Messages the live connection already delivered are left alone, except placeholders stored
// before the history was restored, which are replaced with the real message.
func (c *Core) importWebMessages(threadID string, messages []webMessage) apiMessageImportResult {
	self := c.selfID()
	cs := newChangeSet()
	imported := 0
	unrestored := 0
	var newest *messageRow
	repeated := repeatedTexts(messages)
	isPlaceholder := func(text string) bool { return isUnrestoredPlaceholder(text) || repeated[text] }
	for _, wm := range messages {
		id, ts, ok := webMessageID(wm.DOMID)
		if !ok {
			continue
		}
		if isPlaceholder(wm.Text) && len(wm.Images) == 0 {
			unrestored++
			continue
		}
		if c.importWebReactions(id, threadID, wm.FromMe, wm.Reactions) {
			cs.message(id)
		}
		sender := threadID
		if wm.FromMe {
			sender = self
		}
		if existing := c.store.GetMessage(id); existing != nil && !isPlaceholder(existing.Text) &&
			!(len(wm.Links) > 0 && importedBeforeLinks(existing)) {
			changed := false
			// Text read before emoji were collected gets its emoji.
			if wm.Text != "" && existing.Text != wm.Text && withoutEmoji(existing.Text) == withoutEmoji(wm.Text) {
				existing.Text = wm.Text
				changed = true
			}
			// Albums were once read as the other side's (their photos are staggered).
			if len(wm.Images) > 0 && importedBeforeLinks(existing) && existing.SenderID != sender {
				existing.SenderID = sender
				existing.WASender = sender + "@msgr"
				changed = true
			}
			if changed {
				c.store.PutMessage(existing)
				cs.message(id)
			}
			continue
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
	// The chat's read position isn't known (it came from the web app's chat list, e.g. after
	// a new login): its history counts as read, or every imported chat would look unread.
	// Messages arriving from now on count as usual.
	if t := c.store.GetThread(threadID); t != nil && t.LastRead == 0 {
		if latest := c.store.ListMessages(threadID, 0, 1); len(latest) == 1 {
			c.store.SetThreadLastRead(threadID, latest[0].Timestamp)
			cs.thread(threadID)
		}
	}
	c.flush(cs)
	c.log.Info().Str("thread_id", threadID).Int("received", len(messages)).Int("imported", imported).Int("unrestored", unrestored).Msg("Imported web message history")
	return apiMessageImportResult{Imported: imported, Unrestored: unrestored}
}

// webReacted is the reactions the web app shows on a message imported before.
type webReacted struct {
	DOMID     string        `json:"domID"`
	FromMe    bool          `json:"fromMe"`
	Reactions []webReaction `json:"reactions"`
}

// importWebReactionUpdates stores the reactions shown on stored messages of a 1:1 encrypted
// chat: ones made while the app was offline aren't delivered by the live connection later.
func (c *Core) importWebReactionUpdates(threadID string, reacted []webReacted) {
	cs := newChangeSet()
	for _, r := range reacted {
		id, _, ok := webMessageID(r.DOMID)
		if !ok || c.store.GetMessage(id) == nil {
			continue
		}
		before := fmt.Sprint(c.store.Reactions([]string{id})[id])
		c.importWebReactions(id, threadID, r.FromMe, r.Reactions)
		if fmt.Sprint(c.store.Reactions([]string{id})[id]) != before {
			cs.message(id)
		}
	}
	c.flush(cs)
}

func (c *Core) saveWebImage(messageID string, index int, img webImage) (string, error) {
	data, err := base64.StdEncoding.DecodeString(img.Data)
	if err != nil {
		return "", err
	}
	path := filepath.Join(c.mediaDir(), fmt.Sprintf("%s-web%d%s", messageID, index, extensionFor(img.MimeType)))
	return path, os.WriteFile(path, data, 0o600)
}

// webThreadID is the web app's ID of an encrypted chat: its Facebook thread key, which Messenger
// tells us for every encrypted chat (mapThread), or else the one read from the web app's chat
// list (which only shows the chats it has loaded). "" if neither is known.
func (c *Core) webThreadID(threadID string) string {
	if t := c.store.GetThread(threadID); t != nil && t.Type.IsWhatsApp() && t.FBKey != "" && t.FBKey != threadID {
		return t.FBKey
	}
	return c.store.Get(kvWebID + threadID)
}

// webThreadPath is where the web app shows a chat, or "" if the encrypted chat's web ID isn't known yet.
// Message requests live under /requests/ (the plain path redirects elsewhere).
func (c *Core) webThreadPath(threadID string) string {
	t := c.store.GetThread(threadID)
	requests := ""
	if t != nil && t.IsRequest() {
		requests = "requests/"
	}
	if t != nil && t.Type.IsWhatsApp() {
		if webID := c.webThreadID(threadID); webID != "" {
			return "/messages/e2ee/" + requests + "t/" + webID + "/"
		}
		return ""
	}
	return fmt.Sprintf("/messages/%st/%d/", requests, c.fbThreadKey(threadID))
}
