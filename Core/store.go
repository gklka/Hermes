package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"time"

	waTypes "go.mau.fi/whatsmeow/types"

	"go.mau.fi/mautrix-meta/pkg/messagix/table"
	_ "modernc.org/sqlite"
)

// Store is the app's own message database (separate from whatsmeow's crypto store).
// It uses a single connection, so never run a query while iterating another one's rows.
type Store struct {
	db *sql.DB
}

const schema = `
CREATE TABLE IF NOT EXISTS kv (
	key   TEXT PRIMARY KEY,
	value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS contacts (
	id         TEXT PRIMARY KEY,
	name       TEXT NOT NULL DEFAULT '',
	avatar_url TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS threads (
	id                TEXT PRIMARY KEY,
	fb_key            TEXT NOT NULL DEFAULT '',
	thread_type       INTEGER NOT NULL DEFAULT 1,
	name              TEXT NOT NULL DEFAULT '',
	avatar_url        TEXT NOT NULL DEFAULT '',
	snippet           TEXT NOT NULL DEFAULT '',
	snippet_sender_id TEXT NOT NULL DEFAULT '',
	last_activity     INTEGER NOT NULL DEFAULT 0,
	last_read         INTEGER NOT NULL DEFAULT 0,
	folder            TEXT NOT NULL DEFAULT 'inbox',
	mute_until        INTEGER NOT NULL DEFAULT 0,
	has_more_before   INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS participants (
	thread_id      TEXT NOT NULL,
	user_id        TEXT NOT NULL,
	nickname       TEXT NOT NULL DEFAULT '',
	read_watermark INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (thread_id, user_id)
);
CREATE TABLE IF NOT EXISTS messages (
	id          TEXT PRIMARY KEY,
	thread_id   TEXT NOT NULL,
	sender_id   TEXT NOT NULL,
	timestamp   INTEGER NOT NULL,
	text        TEXT NOT NULL DEFAULT '',
	is_system   INTEGER NOT NULL DEFAULT 0,
	reply_to    TEXT NOT NULL DEFAULT '',
	attachments TEXT NOT NULL DEFAULT '[]',
	status      TEXT NOT NULL DEFAULT 'sent',
	is_unsent   INTEGER NOT NULL DEFAULT 0,
	is_edited   INTEGER NOT NULL DEFAULT 0,
	otid        TEXT NOT NULL DEFAULT '',
	wa_chat     TEXT NOT NULL DEFAULT '',
	wa_sender   TEXT NOT NULL DEFAULT '',
	mentions    TEXT NOT NULL DEFAULT '[]'
);
CREATE INDEX IF NOT EXISTS messages_thread_ts ON messages (thread_id, timestamp);
CREATE TABLE IF NOT EXISTS reactions (
	message_id TEXT NOT NULL,
	sender_id  TEXT NOT NULL,
	emoji      TEXT NOT NULL,
	PRIMARY KEY (message_id, sender_id)
);
`

func OpenStore(path string) (*Store, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err = db.Exec(schema); err != nil {
		return nil, fmt.Errorf("failed to create schema: %w", err)
	}
	// Columns added since: these fail harmlessly once they exist.
	_, _ = db.Exec(`ALTER TABLE messages ADD COLUMN mentions TEXT NOT NULL DEFAULT '[]'`)
	s := &Store{db: db}
	s.convertCallLogLinks()
	return s, nil
}

// convertCallLogLinks turns call log cards stored as links (before calls had their own kind)
// into calls, once. Only their localized title is known: "video" in it means a video call
// ("Video call", "Videohívás"), "missed" or "Nem fogadott" a missed one. Fetched again, they get
// the exact details (callFromXMA).
func (s *Store) convertCallLogLinks() {
	const done = "migration.callLogLinks"
	if s.Get(done) != "" {
		return
	}
	rows, err := s.db.Query(`SELECT id, attachments FROM messages WHERE attachments LIKE '%"id":"cl.%'`)
	if err != nil {
		return
	}
	updates := map[string]string{}
	for rows.Next() {
		var id, raw string
		var attachments []storedAttachment
		if rows.Scan(&id, &raw) != nil || json.Unmarshal([]byte(raw), &attachments) != nil {
			continue
		}
		for i, a := range attachments {
			if a.Kind != kindLink || !strings.HasPrefix(a.ID, "cl.") {
				continue
			}
			title := strings.ToLower(a.Title)
			call := &apiCall{IsVideo: strings.Contains(title, "video"), Outcome: callEnded}
			if strings.Contains(title, "missed") || strings.Contains(title, "nem fogadott") {
				call.Outcome = callMissed
			}
			attachments[i].Kind = kindCall
			attachments[i].Call = call
		}
		if data, err := json.Marshal(attachments); err == nil {
			updates[id] = string(data)
		}
	}
	rows.Close()
	for id, data := range updates {
		_, _ = s.db.Exec(`UPDATE messages SET attachments=? WHERE id=?`, data, id)
	}
	s.Set(done, "1")
}

// Wipe deletes all account data (used on logout).
func (s *Store) Wipe() error {
	for _, tbl := range []string{"kv", "contacts", "threads", "participants", "messages", "reactions"} {
		if _, err := s.db.Exec(`DELETE FROM ` + tbl); err != nil {
			return err
		}
	}
	return nil
}

// MARK: - Key/value

// Keys in the kv table.
const (
	kvCookies    = "cookies"
	kvAccount    = "account"
	kvWADeviceID = "wa_device_id"
)

// Key prefixes in the kv table, each followed by an ID.
const (
	kvThreadMap   = "map:"         // Facebook thread key → the encrypted chat's ID
	kvWebMap      = "webmap:"      // web app chat ID → user ID (encrypted 1:1 chats)
	kvWebID       = "webid:"       // user ID → web app chat ID
	kvColors      = "colors:"      // chat → custom bubble colors, comma separated
	kvEmoji       = "emoji:"       // chat → custom quick reaction
	kvUnread      = "unread:"      // chat → when it was marked unread here (ms)
	kvEdits       = "edits:"       // message → its texts before edits (JSON, oldest first)
	kvThemeColors = "themecolors:" // theme ID → its colors, or "default"
)

func (s *Store) Get(key string) string {
	var value string
	_ = s.db.QueryRow(`SELECT value FROM kv WHERE key=?`, key).Scan(&value)
	return value
}

func (s *Store) Set(key, value string) {
	_, _ = s.db.Exec(`INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value=excluded.value`, key, value)
}

func (s *Store) Delete(key string) {
	_, _ = s.db.Exec(`DELETE FROM kv WHERE key=?`, key)
}

// MARK: - Contacts

func (s *Store) UpsertContact(id, name, avatarURL string) {
	_, _ = s.db.Exec(`
		INSERT INTO contacts (id, name, avatar_url) VALUES (?, ?, ?)
		ON CONFLICT (id) DO UPDATE SET
			name=CASE WHEN excluded.name<>'' THEN excluded.name ELSE contacts.name END,
			avatar_url=CASE WHEN excluded.avatar_url<>'' THEN excluded.avatar_url ELSE contacts.avatar_url END
	`, id, name, avatarURL)
}

// SearchContacts finds contacts by name (case-insensitive), excluding yourself.
func (s *Store) SearchContacts(query, selfID string, limit int) []apiParticipant {
	rows, err := s.db.Query(`
		SELECT id, name, avatar_url FROM contacts
		WHERE name<>'' AND id<>? AND name LIKE ? ESCAPE '\'
		ORDER BY name COLLATE NOCASE LIMIT ?`,
		selfID, "%"+strings.NewReplacer(`\`, `\\`, "%", `\%`, "_", `\_`).Replace(query)+"%", limit)
	if err != nil {
		return nil
	}
	defer rows.Close()
	out := []apiParticipant{}
	for rows.Next() {
		var p apiParticipant
		if rows.Scan(&p.ID, &p.Name, &p.AvatarURL) == nil {
			out = append(out, p)
		}
	}
	return out
}

func (s *Store) ContactName(id string) string {
	var name string
	_ = s.db.QueryRow(`SELECT name FROM contacts WHERE id=?`, id).Scan(&name)
	return name
}

// MARK: - Threads

// Thread folders, as Messenger names them.
const (
	folderInbox       = "inbox"
	folderE2EECutover = "e2ee_cutover" // the unencrypted chat an encrypted one replaced
	folderRequests    = "pending"      // message requests
)

type threadRow struct {
	ID              string
	FBKey           string
	Type            table.ThreadType
	Name            string
	AvatarURL       string
	Snippet         string
	SnippetSenderID string
	LastActivity    int64
	LastRead        int64
	Folder          string
	MuteUntil       int64
	HasMoreBefore   bool
}

const threadColumns = `id, fb_key, thread_type, name, avatar_url, snippet, snippet_sender_id, last_activity, last_read, folder, mute_until, has_more_before`

func scanThread(row interface{ Scan(...any) error }) (*threadRow, error) {
	var t threadRow
	err := row.Scan(&t.ID, &t.FBKey, &t.Type, &t.Name, &t.AvatarURL, &t.Snippet, &t.SnippetSenderID,
		&t.LastActivity, &t.LastRead, &t.Folder, &t.MuteUntil, &t.HasMoreBefore)
	return &t, err
}

// PutThread inserts or fully replaces the server-provided thread metadata.
func (s *Store) PutThread(t *threadRow) {
	_, _ = s.db.Exec(`
		INSERT INTO threads (`+threadColumns+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
		ON CONFLICT (id) DO UPDATE SET
			fb_key=excluded.fb_key, thread_type=excluded.thread_type, name=excluded.name,
			avatar_url=excluded.avatar_url, snippet=excluded.snippet, snippet_sender_id=excluded.snippet_sender_id,
			last_activity=MAX(threads.last_activity, excluded.last_activity),
			last_read=MAX(threads.last_read, excluded.last_read),
			folder=excluded.folder, mute_until=excluded.mute_until
	`, t.ID, t.FBKey, t.Type, t.Name, t.AvatarURL, t.Snippet, t.SnippetSenderID, t.LastActivity, t.LastRead, t.Folder, t.MuteUntil)
}

// EnsureThread creates a placeholder thread if it doesn't exist yet.
func (s *Store) EnsureThread(id string, threadType table.ThreadType, folder string) {
	if folder == "" {
		folder = folderInbox
	}
	_, _ = s.db.Exec(`INSERT INTO threads (id, thread_type, folder) VALUES (?, ?, ?) ON CONFLICT (id) DO NOTHING`, id, threadType, folder)
}

func (s *Store) GetThread(id string) *threadRow {
	t, err := scanThread(s.db.QueryRow(`SELECT `+threadColumns+` FROM threads WHERE id=?`, id))
	if err != nil {
		return nil
	}
	return t
}

// Visible reports whether the thread belongs in the chat list: inbox chats only, not message
// requests, filtered ("other") or spam threads, nor the folder pseudo-threads Messenger sends.
func (t *threadRow) Visible() bool {
	switch t.Type {
	case table.FOLDER, table.COMMUNITY_FOLDER:
		return false
	}
	switch t.Folder {
	case folderInbox, folderE2EECutover, "":
		return true
	}
	return false
}

// chatJID is the chat's address on the encrypted connection.
func (t *threadRow) chatJID() waTypes.JID {
	server := waTypes.MessengerServer
	if t.Type == table.ENCRYPTED_OVER_WA_GROUP {
		server = waTypes.GroupServer
	}
	return waTypes.JID{User: t.ID, Server: server}
}

func (s *Store) ListThreads() []*threadRow {
	rows, err := s.db.Query(`
		SELECT ` + threadColumns + ` FROM threads
		WHERE last_activity > 0
		ORDER BY last_activity DESC`)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []*threadRow
	for rows.Next() {
		if t, err := scanThread(rows); err == nil && t.Visible() {
			out = append(out, t)
		}
	}
	return out
}

// DeleteThread forgets the chat (its messages and settings stay: the server also deletes and
// re-sends chats, e.g. when one moves).
func (s *Store) DeleteThread(id string) {
	_, _ = s.db.Exec(`DELETE FROM threads WHERE id=?`, id)
	_, _ = s.db.Exec(`DELETE FROM participants WHERE thread_id=?`, id)
}

// ForgetThreadSettings drops the chat's theme, quick reaction and "marked unread" (when you
// delete the chat).
func (s *Store) ForgetThreadSettings(id string) {
	for _, prefix := range []string{kvColors, kvEmoji, kvUnread} {
		s.Delete(prefix + id)
	}
}

func (s *Store) SetThreadType(id string, threadType table.ThreadType) {
	_, _ = s.db.Exec(`UPDATE threads SET thread_type=? WHERE id=?`, threadType, id)
}

func (s *Store) SetThreadFolder(id, folder string) {
	_, _ = s.db.Exec(`UPDATE threads SET folder=? WHERE id=?`, folder, id)
}

func (s *Store) SetThreadFBKey(id, fbKey string) {
	_, _ = s.db.Exec(`UPDATE threads SET fb_key=? WHERE id=?`, fbKey, id)
}

func (s *Store) SetThreadName(id, name string) {
	_, _ = s.db.Exec(`UPDATE threads SET name=? WHERE id=?`, name, id)
}

func (s *Store) SetThreadAvatar(id, url string) {
	_, _ = s.db.Exec(`UPDATE threads SET avatar_url=? WHERE id=?`, url, id)
}

func (s *Store) SetThreadMute(id string, until int64) {
	_, _ = s.db.Exec(`UPDATE threads SET mute_until=? WHERE id=?`, until, id)
}

func (s *Store) SetThreadSnippet(id, snippet, senderID string) {
	_, _ = s.db.Exec(`UPDATE threads SET snippet=?, snippet_sender_id=? WHERE id=?`, snippet, senderID, id)
}

func (s *Store) SetThreadLastRead(id string, ts int64) {
	_, _ = s.db.Exec(`UPDATE threads SET last_read=MAX(last_read, ?) WHERE id=?`, ts, id)
}

func (s *Store) SetThreadHasMoreBefore(id string, hasMore bool) {
	_, _ = s.db.Exec(`UPDATE threads SET has_more_before=? WHERE id=?`, hasMore, id)
}

// BumpThread records a new message as the thread's latest activity, if it is newer.
func (s *Store) BumpThread(id string, ts int64, snippet, senderID string) {
	_, _ = s.db.Exec(`
		UPDATE threads SET last_activity=?, snippet=?, snippet_sender_id=?
		WHERE id=? AND last_activity<=?`, ts, snippet, senderID, id, ts)
}

// ThreadsWithoutPreview lists the chats of the type with no snippet and no stored messages,
// the most recent first.
func (s *Store) ThreadsWithoutPreview(threadType table.ThreadType) []string {
	rows, err := s.db.Query(`
		SELECT id FROM threads t WHERE thread_type=? AND snippet=''
		AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.thread_id=t.id)
		ORDER BY last_activity DESC`, int64(threadType))
	if err != nil {
		return nil
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	return ids
}

// SetThreadSnippetIfEmpty sets the snippet of a thread that has none (its time stays).
func (s *Store) SetThreadSnippetIfEmpty(id, snippet string) {
	_, _ = s.db.Exec(`UPDATE threads SET snippet=?, snippet_sender_id='' WHERE id=? AND snippet=''`, snippet, id)
}

// SetThreadLatest sets the thread's latest activity even if it's older (to undo a guess).
func (s *Store) SetThreadLatest(id string, ts int64, snippet, senderID string) {
	_, _ = s.db.Exec(`UPDATE threads SET last_activity=?, snippet=?, snippet_sender_id=? WHERE id=?`,
		ts, snippet, senderID, id)
}

// MARK: - Participants

type participantRow struct {
	UserID        string
	Name          string
	AvatarURL     string
	ReadWatermark int64
}

// AddParticipant adds the person to the chat, or updates them, as the sync describes them (its
// nickname is authoritative, also when cleared); the read watermark only moves on.
func (s *Store) AddParticipant(threadID, userID, nickname string, readWatermark int64) {
	_, _ = s.db.Exec(`
		INSERT INTO participants (thread_id, user_id, nickname, read_watermark) VALUES (?, ?, ?, ?)
		ON CONFLICT (thread_id, user_id) DO UPDATE SET
			nickname=excluded.nickname, read_watermark=MAX(participants.read_watermark, excluded.read_watermark)
	`, threadID, userID, nickname, readWatermark)
}

// EnsureParticipant adds the person to the chat if they aren't in it, leaving a known
// participant (and their nickname) as is.
func (s *Store) EnsureParticipant(threadID, userID string) {
	_, _ = s.db.Exec(`INSERT OR IGNORE INTO participants (thread_id, user_id) VALUES (?, ?)`, threadID, userID)
}

// EnsureEncryptedDirectThread makes sure the encrypted 1:1 chat with the user exists (keyed by
// their ID, like every 1:1 chat), with both of you in it.
func (s *Store) EnsureEncryptedDirectThread(userID, selfID string) {
	s.EnsureThread(userID, table.ENCRYPTED_OVER_WA_ONE_TO_ONE, folderInbox)
	s.EnsureParticipant(userID, selfID)
	s.EnsureParticipant(userID, userID)
}

// ThreadsWithParticipant lists the chats the person is in.
func (s *Store) ThreadsWithParticipant(userID string) []string {
	rows, err := s.db.Query(`SELECT thread_id FROM participants WHERE user_id=?`, userID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			out = append(out, id)
		}
	}
	return out
}

func (s *Store) RemoveParticipant(threadID, userID string) {
	_, _ = s.db.Exec(`DELETE FROM participants WHERE thread_id=? AND user_id=?`, threadID, userID)
}

// SetReadWatermark moves the person's read position on (a read receipt), adding them to the
// chat if needed; their nickname is kept.
func (s *Store) SetReadWatermark(threadID, userID string, ts int64) {
	_, _ = s.db.Exec(`
		INSERT INTO participants (thread_id, user_id, read_watermark) VALUES (?, ?, ?)
		ON CONFLICT (thread_id, user_id) DO UPDATE SET
			read_watermark=MAX(participants.read_watermark, excluded.read_watermark)
	`, threadID, userID, ts)
}

func (s *Store) Participants(threadID string) []participantRow {
	rows, err := s.db.Query(`
		SELECT p.user_id, COALESCE(NULLIF(p.nickname, ''), c.name, ''), COALESCE(c.avatar_url, ''), p.read_watermark
		FROM participants p LEFT JOIN contacts c ON c.id = p.user_id
		WHERE p.thread_id=?`, threadID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []participantRow
	for rows.Next() {
		var p participantRow
		if rows.Scan(&p.UserID, &p.Name, &p.AvatarURL, &p.ReadWatermark) == nil {
			out = append(out, p)
		}
	}
	return out
}

// MARK: - Messages

type waMediaInfo struct {
	MediaType  string `json:"type"`
	Key        []byte `json:"key"`
	SHA256     []byte `json:"sha256"`
	EncSHA256  []byte `json:"encSHA256"`
	DirectPath string `json:"directPath"`
}

type storedAttachment struct {
	apiAttachment
	WA *waMediaInfo `json:"wa,omitempty"`
}

type messageRow struct {
	ID          string
	ThreadID    string
	SenderID    string
	Timestamp   int64
	Text        string
	IsSystem    bool
	ReplyTo     *apiReply
	Attachments []storedAttachment
	Status      string
	IsUnsent    bool
	IsEdited    bool
	OTID        string
	WAChat      string
	WASender    string
	Mentions    []apiMention
}

const messageColumns = `id, thread_id, sender_id, timestamp, text, is_system, reply_to, attachments, status, is_unsent, is_edited, otid, wa_chat, wa_sender, mentions`

func scanMessage(row interface{ Scan(...any) error }) (*messageRow, error) {
	var m messageRow
	var replyJSON, attachmentsJSON, mentionsJSON string
	err := row.Scan(&m.ID, &m.ThreadID, &m.SenderID, &m.Timestamp, &m.Text, &m.IsSystem, &replyJSON, &attachmentsJSON,
		&m.Status, &m.IsUnsent, &m.IsEdited, &m.OTID, &m.WAChat, &m.WASender, &mentionsJSON)
	if err != nil {
		return nil, err
	}
	if replyJSON != "" {
		_ = json.Unmarshal([]byte(replyJSON), &m.ReplyTo)
	}
	_ = json.Unmarshal([]byte(attachmentsJSON), &m.Attachments)
	_ = json.Unmarshal([]byte(mentionsJSON), &m.Mentions)
	return &m, nil
}

func (s *Store) PutMessage(m *messageRow) {
	var replyJSON []byte
	if m.ReplyTo != nil {
		replyJSON, _ = json.Marshal(m.ReplyTo)
	}
	if m.Attachments == nil {
		m.Attachments = []storedAttachment{}
	}
	attachmentsJSON, _ := json.Marshal(m.Attachments)
	if m.Mentions == nil {
		m.Mentions = []apiMention{}
	}
	mentionsJSON, _ := json.Marshal(m.Mentions)
	if m.Status == "" {
		m.Status = statusSent
	}
	_, _ = s.db.Exec(`
		INSERT INTO messages (`+messageColumns+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (id) DO UPDATE SET
			thread_id=excluded.thread_id, sender_id=excluded.sender_id, timestamp=excluded.timestamp,
			text=excluded.text, is_system=excluded.is_system, reply_to=excluded.reply_to,
			attachments=excluded.attachments, status=excluded.status, is_unsent=excluded.is_unsent,
			is_edited=MAX(messages.is_edited, excluded.is_edited), otid=excluded.otid,
			wa_chat=excluded.wa_chat, wa_sender=excluded.wa_sender, mentions=excluded.mentions
	`, m.ID, m.ThreadID, m.SenderID, m.Timestamp, m.Text, m.IsSystem, string(replyJSON), string(attachmentsJSON),
		m.Status, m.IsUnsent, m.IsEdited, m.OTID, m.WAChat, m.WASender, string(mentionsJSON))
}

func (s *Store) GetMessage(id string) *messageRow {
	m, err := scanMessage(s.db.QueryRow(`SELECT `+messageColumns+` FROM messages WHERE id=?`, id))
	if err != nil {
		return nil
	}
	return m
}

// queryMessages runs a query selecting messageColumns.
func (s *Store) queryMessages(query string, args ...any) []*messageRow {
	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []*messageRow
	for rows.Next() {
		if m, err := scanMessage(rows); err == nil {
			out = append(out, m)
		}
	}
	return out
}

// AllMessages is every stored message of the chat, oldest first (for search).
func (s *Store) AllMessages(threadID string) []*messageRow {
	return s.queryMessages(`SELECT `+messageColumns+` FROM messages WHERE thread_id=? ORDER BY timestamp`, threadID)
}

func (s *Store) MessageCount(threadID string) int {
	var count int
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE thread_id=?`, threadID).Scan(&count)
	return count
}

// OldestMessage is the time and ID of the chat's oldest stored message (0 and "" if none).
func (s *Store) OldestMessage(threadID string) (int64, string) {
	var ts int64
	var id string
	_ = s.db.QueryRow(`SELECT timestamp, id FROM messages WHERE thread_id=? ORDER BY timestamp LIMIT 1`, threadID).Scan(&ts, &id)
	return ts, id
}

// OldestEncryptedMessage is the time (ms) of the chat's oldest end-to-end encrypted message (not
// a Facebook "mid." one), 0 if there's none. The web app shows every one of those.
func (s *Store) OldestEncryptedMessage(threadID string) int64 {
	var ts int64
	_ = s.db.QueryRow(`SELECT COALESCE(MIN(timestamp), 0) FROM messages WHERE thread_id=? AND id NOT LIKE 'mid.%' AND timestamp > 0`, threadID).Scan(&ts)
	return ts
}

// ListMessages returns up to `limit` messages older than `before` (ms; 0 = newest), oldest first.
func (s *Store) ListMessages(threadID string, before int64, limit int) []*messageRow {
	if before <= 0 {
		before = 1 << 62
	}
	out := s.queryMessages(`
		SELECT `+messageColumns+` FROM messages
		WHERE thread_id=? AND timestamp<?
		ORDER BY timestamp DESC LIMIT ?`, threadID, before, limit)
	slices.Reverse(out)
	return out
}

// UnreadFromOthers returns messages from other people newer than the thread's read marker.
func (s *Store) UnreadFromOthers(threadID, selfID string, since int64) []*messageRow {
	return s.queryMessages(`
		SELECT `+messageColumns+` FROM messages
		WHERE thread_id=? AND sender_id<>? AND timestamp>? AND is_system=0
		ORDER BY timestamp`, threadID, selfID, since)
}

// PreviousTexts are a message's texts before its edits seen by this app, oldest first.
func (s *Store) PreviousTexts(id string) []string {
	var versions []string
	if data := s.Get(kvEdits + id); data != "" {
		_ = json.Unmarshal([]byte(data), &versions)
	}
	return versions
}

// EditMessage changes a message's text. If it's its chat's latest message, the chat's snippet
// follows, and the chat's ID is returned (to emit the change).
func (s *Store) EditMessage(id, text string) string {
	// Keep the earlier versions (oldest first) to show them under "Edited".
	var old string
	if s.db.QueryRow(`SELECT text FROM messages WHERE id=?`, id).Scan(&old) == nil && old != text && old != "" {
		versions := s.PreviousTexts(id)
		versions = append(versions, old)
		data, _ := json.Marshal(versions)
		s.Set(kvEdits+id, string(data))
	}
	// The mentions' places were in the old text.
	_, _ = s.db.Exec(`UPDATE messages SET text=?, is_edited=1, mentions='[]' WHERE id=?`, text, id)
	var threadID string
	err := s.db.QueryRow(`
		SELECT m.thread_id FROM messages m
		WHERE m.id=? AND m.timestamp=(SELECT MAX(timestamp) FROM messages WHERE thread_id=m.thread_id)`, id).Scan(&threadID)
	if err != nil || text == "" {
		return ""
	}
	_, _ = s.db.Exec(`UPDATE threads SET snippet=? WHERE id=?`, text, threadID)
	return threadID
}

func (s *Store) UnsendMessage(id string) {
	_, _ = s.db.Exec(`UPDATE messages SET text='', attachments='[]', is_unsent=1 WHERE id=?`, id)
}

// DeleteThreadMessages forgets every stored message of the chat (and their reactions).
func (s *Store) DeleteThreadMessages(threadID string) {
	_, _ = s.db.Exec(`DELETE FROM reactions WHERE message_id IN (SELECT id FROM messages WHERE thread_id=?)`, threadID)
	_, _ = s.db.Exec(`DELETE FROM messages WHERE thread_id=?`, threadID)
}

func (s *Store) DeleteMessage(id string) {
	_, _ = s.db.Exec(`DELETE FROM messages WHERE id=?`, id)
	_, _ = s.db.Exec(`DELETE FROM reactions WHERE message_id=?`, id)
	s.Delete(kvEdits + id)
}

// attachment is the message's attachment with the ID, or nil.
func (m *messageRow) attachment(id string) *storedAttachment {
	for i := range m.Attachments {
		if m.Attachments[i].ID == id {
			return &m.Attachments[i]
		}
	}
	return nil
}

func (s *Store) SetAttachmentLocalPath(messageID, attachmentID, path string) {
	m := s.GetMessage(messageID)
	if m == nil {
		return
	}
	if a := m.attachment(attachmentID); a != nil {
		a.LocalPath = path
	}
	data, _ := json.Marshal(m.Attachments)
	_, _ = s.db.Exec(`UPDATE messages SET attachments=? WHERE id=?`, string(data), messageID)
}

// MARK: - Reactions

// Reaction is the person's current reaction to the message, or "".
func (s *Store) Reaction(messageID, senderID string) string {
	var emoji string
	_ = s.db.QueryRow(`SELECT emoji FROM reactions WHERE message_id=? AND sender_id=?`, messageID, senderID).Scan(&emoji)
	return emoji
}

func (s *Store) SetReaction(messageID, senderID, emoji string) {
	if emoji == "" {
		_, _ = s.db.Exec(`DELETE FROM reactions WHERE message_id=? AND sender_id=?`, messageID, senderID)
		return
	}
	_, _ = s.db.Exec(`
		INSERT INTO reactions (message_id, sender_id, emoji) VALUES (?, ?, ?)
		ON CONFLICT (message_id, sender_id) DO UPDATE SET emoji=excluded.emoji`, messageID, senderID, emoji)
}

func (s *Store) Reactions(messageIDs []string) map[string][]apiReaction {
	out := make(map[string][]apiReaction)
	if len(messageIDs) == 0 {
		return out
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(messageIDs)), ",")
	args := make([]any, len(messageIDs))
	for i, id := range messageIDs {
		args[i] = id
	}
	rows, err := s.db.Query(`SELECT message_id, sender_id, emoji FROM reactions WHERE message_id IN (`+placeholders+`)`, args...)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var messageID string
		var r apiReaction
		if rows.Scan(&messageID, &r.SenderID, &r.Emoji) == nil {
			r.Emoji = emojiPresentation(r.Emoji)
			out[messageID] = append(out[messageID], r)
		}
	}
	return out
}

// emojiPresentation adds the emoji variation selector to lone symbols that otherwise render
// as black text glyphs (Messenger sends its heart reaction as a bare U+2764 "❤").
func emojiPresentation(emoji string) string {
	runes := []rune(emoji)
	if len(runes) == 1 && runes[0] >= 0x2000 && runes[0] < 0x3300 {
		return emoji + "️"
	}
	return emoji
}

// likeSticker is the private-use character Messenger uses in snippets for the big like.
const likeSticker = "\U000F0000"

// stickerSnippet is the snippet Messenger sends for a sticker message (a middle dot).
const stickerSnippet = "·"

// MARK: - Conversion to API types

func (s *Store) Conversation(t *threadRow, selfID string) apiConversation {
	participants := s.Participants(t.ID)
	conv := apiConversation{
		ID:              t.ID,
		Name:            t.Name,
		AvatarURL:       t.AvatarURL,
		Snippet:         strings.ReplaceAll(t.Snippet, likeSticker, "👍"),
		SnippetSenderID: t.SnippetSenderID,
		LastActivity:    t.LastActivity,
		IsGroup:         !t.Type.IsOneToOne(),
		IsEncrypted:     t.Type.IsWhatsApp(),
		IsMuted:         t.MuteUntil == -1 || t.MuteUntil > time.Now().UnixMilli(),
		IsMarketplace:   t.Type == table.MARKETPLACE,
		Participants:    make([]apiParticipant, 0, len(participants)),
	}
	if t.Snippet == stickerSnippet {
		// Messenger's snippet for stickers (including the big like); use the latest message instead.
		var text, sender string
		if s.db.QueryRow(`SELECT text, sender_id FROM messages WHERE thread_id=? ORDER BY timestamp DESC LIMIT 1`, t.ID).
			Scan(&text, &sender) == nil && text != "" {
			conv.Snippet, conv.SnippetSenderID = text, sender
		} else {
			conv.Snippet = "Sticker"
		}
	}
	if conv.Snippet == "" {
		// No snippet from Messenger (an encrypted chat's, or the latest message was unsent):
		// the latest stored message.
		var text, sender, attachments string
		var unsent bool
		if s.db.QueryRow(`SELECT text, sender_id, attachments, is_unsent FROM messages WHERE thread_id=? AND is_system=0 ORDER BY timestamp DESC LIMIT 1`, t.ID).
			Scan(&text, &sender, &attachments, &unsent) == nil {
			conv.SnippetSenderID = sender
			conv.SnippetUnsent = unsent
			if !unsent {
				conv.Snippet = snippetFor(text, attachments != "[]")
			}
		}
	}
	if colors := s.Get(kvColors + t.ID); colors != "" {
		conv.BubbleColors = strings.Split(colors, ",")
	}
	conv.QuickEmoji = s.Get(kvEmoji + t.ID)
	var others []participantRow
	for _, p := range participants {
		conv.Participants = append(conv.Participants, apiParticipant{
			ID: p.UserID, Name: p.Name, AvatarURL: p.AvatarURL, ReadWatermark: p.ReadWatermark,
		})
		if p.UserID != selfID {
			others = append(others, p)
		}
	}
	if !conv.IsGroup && len(others) == 0 {
		// 1:1 threads are keyed by the other person's ID, even if the participant list hasn't arrived.
		var name, avatar string
		_ = s.db.QueryRow(`SELECT name, avatar_url FROM contacts WHERE id=?`, t.ID).Scan(&name, &avatar)
		others = append(others, participantRow{UserID: t.ID, Name: name, AvatarURL: avatar})
		conv.Participants = append(conv.Participants, apiParticipant{ID: t.ID, Name: name, AvatarURL: avatar})
	}
	if conv.Name == "" {
		names := make([]string, 0, len(others))
		for _, p := range others {
			if p.Name != "" {
				names = append(names, p.Name)
			}
		}
		conv.Name = strings.Join(names, ", ")
		if conv.Name == "" {
			conv.Name = "Unknown"
		}
	}
	if conv.AvatarURL == "" && !conv.IsGroup && len(others) > 0 {
		conv.AvatarURL = others[0].AvatarURL
	}
	// No read watermark (LastRead 0) happens for encrypted chats Messenger only lists (e.g. after
	// the E2EE cutover); count those as unread only once a message from someone else arrives.
	known := t.LastRead > 0 || t.SnippetSenderID != ""
	if known && t.LastActivity > t.LastRead && t.SnippetSenderID != selfID {
		// Messenger also bumps the activity time without a message (e.g. for encrypted chats),
		// so when the messages are known, only one from someone else after the last read counts.
		var newest sql.NullInt64
		_ = s.db.QueryRow(`SELECT MAX(timestamp) FROM messages WHERE thread_id=? AND sender_id!=? AND is_system=0`,
			t.ID, selfID).Scan(&newest)
		// Encrypted chats' messages all arrive here (live), so without one from someone else
		// after the last read the bump was something else; read state from other devices
		// doesn't always reach them either.
		if newest.Valid && newest.Int64 > t.LastRead || !newest.Valid && !t.Type.IsWhatsApp() {
			conv.UnreadCount = 1
		}
	}
	// Marked unread from the context menu (the value is when).
	if s.Get(kvUnread+t.ID) != "" {
		conv.UnreadCount = 1
	}
	return conv
}

func (s *Store) APIMessages(rows []*messageRow, selfID string) []apiMessage {
	ids := make([]string, len(rows))
	for i, m := range rows {
		ids[i] = m.ID
	}
	reactions := s.Reactions(ids)
	out := make([]apiMessage, len(rows))
	for i, m := range rows {
		out[i] = m.toAPI(selfID, reactions[m.ID])
		if m.IsEdited {
			out[i].PreviousTexts = s.PreviousTexts(m.ID)
		}
	}
	return out
}

func (m *messageRow) toAPI(selfID string, reactions []apiReaction) apiMessage {
	attachments := make([]apiAttachment, len(m.Attachments))
	for i, a := range m.Attachments {
		attachments[i] = a.apiAttachment
	}
	if reactions == nil {
		reactions = []apiReaction{}
	}
	return apiMessage{
		ID:          m.ID,
		ThreadID:    m.ThreadID,
		SenderID:    m.SenderID,
		IsFromMe:    m.SenderID == selfID,
		IsSystem:    m.IsSystem,
		Text:        m.Text,
		Timestamp:   m.Timestamp,
		Attachments: attachments,
		ReplyTo:     m.ReplyTo,
		Reactions:   reactions,
		Status:      m.Status,
		IsUnsent:    m.IsUnsent,
		IsEdited:    m.IsEdited,
		Mentions:    m.Mentions,
	}
}
