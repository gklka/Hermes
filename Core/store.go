package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

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
	wa_sender   TEXT NOT NULL DEFAULT ''
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
	return &Store{db: db}, nil
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
		folder = "inbox"
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
	case "inbox", "e2ee_cutover", "":
		return true
	}
	return false
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

func (s *Store) DeleteThread(id string) {
	_, _ = s.db.Exec(`DELETE FROM threads WHERE id=?`, id)
	_, _ = s.db.Exec(`DELETE FROM participants WHERE thread_id=?`, id)
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

// MARK: - Participants

type participantRow struct {
	UserID        string
	Name          string
	AvatarURL     string
	ReadWatermark int64
}

func (s *Store) AddParticipant(threadID, userID, nickname string, readWatermark int64) {
	_, _ = s.db.Exec(`
		INSERT INTO participants (thread_id, user_id, nickname, read_watermark) VALUES (?, ?, ?, ?)
		ON CONFLICT (thread_id, user_id) DO UPDATE SET
			nickname=excluded.nickname, read_watermark=MAX(participants.read_watermark, excluded.read_watermark)
	`, threadID, userID, nickname, readWatermark)
}

func (s *Store) RemoveParticipant(threadID, userID string) {
	_, _ = s.db.Exec(`DELETE FROM participants WHERE thread_id=? AND user_id=?`, threadID, userID)
}

func (s *Store) SetReadWatermark(threadID, userID string, ts int64) {
	s.AddParticipant(threadID, userID, "", ts)
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
}

const messageColumns = `id, thread_id, sender_id, timestamp, text, is_system, reply_to, attachments, status, is_unsent, is_edited, otid, wa_chat, wa_sender`

func scanMessage(row interface{ Scan(...any) error }) (*messageRow, error) {
	var m messageRow
	var replyJSON, attachmentsJSON string
	err := row.Scan(&m.ID, &m.ThreadID, &m.SenderID, &m.Timestamp, &m.Text, &m.IsSystem, &replyJSON, &attachmentsJSON,
		&m.Status, &m.IsUnsent, &m.IsEdited, &m.OTID, &m.WAChat, &m.WASender)
	if err != nil {
		return nil, err
	}
	if replyJSON != "" {
		_ = json.Unmarshal([]byte(replyJSON), &m.ReplyTo)
	}
	_ = json.Unmarshal([]byte(attachmentsJSON), &m.Attachments)
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
	if m.Status == "" {
		m.Status = statusSent
	}
	_, _ = s.db.Exec(`
		INSERT INTO messages (`+messageColumns+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (id) DO UPDATE SET
			thread_id=excluded.thread_id, sender_id=excluded.sender_id, timestamp=excluded.timestamp,
			text=excluded.text, is_system=excluded.is_system, reply_to=excluded.reply_to,
			attachments=excluded.attachments, status=excluded.status, is_unsent=excluded.is_unsent,
			is_edited=MAX(messages.is_edited, excluded.is_edited), otid=excluded.otid,
			wa_chat=excluded.wa_chat, wa_sender=excluded.wa_sender
	`, m.ID, m.ThreadID, m.SenderID, m.Timestamp, m.Text, m.IsSystem, string(replyJSON), string(attachmentsJSON),
		m.Status, m.IsUnsent, m.IsEdited, m.OTID, m.WAChat, m.WASender)
}

func (s *Store) GetMessage(id string) *messageRow {
	m, err := scanMessage(s.db.QueryRow(`SELECT `+messageColumns+` FROM messages WHERE id=?`, id))
	if err != nil {
		return nil
	}
	return m
}

// ListMessages returns up to `limit` messages older than `before` (ms; 0 = newest), oldest first.
func (s *Store) ListMessages(threadID string, before int64, limit int) []*messageRow {
	if before <= 0 {
		before = 1 << 62
	}
	rows, err := s.db.Query(`
		SELECT `+messageColumns+` FROM messages
		WHERE thread_id=? AND timestamp<?
		ORDER BY timestamp DESC LIMIT ?`, threadID, before, limit)
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
	// Reverse into chronological order.
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

// UnreadFromOthers returns messages from other people newer than the thread's read marker.
func (s *Store) UnreadFromOthers(threadID, selfID string, since int64) []*messageRow {
	rows, err := s.db.Query(`
		SELECT `+messageColumns+` FROM messages
		WHERE thread_id=? AND sender_id<>? AND timestamp>? AND is_system=0
		ORDER BY timestamp`, threadID, selfID, since)
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

func (s *Store) EditMessage(id, text string) {
	_, _ = s.db.Exec(`UPDATE messages SET text=?, is_edited=1 WHERE id=?`, text, id)
}

func (s *Store) UnsendMessage(id string) {
	_, _ = s.db.Exec(`UPDATE messages SET text='', attachments='[]', is_unsent=1 WHERE id=?`, id)
}

func (s *Store) DeleteMessage(id string) {
	_, _ = s.db.Exec(`DELETE FROM messages WHERE id=?`, id)
	_, _ = s.db.Exec(`DELETE FROM reactions WHERE message_id=?`, id)
}

func (s *Store) SetAttachmentLocalPath(messageID, attachmentID, path string) {
	m := s.GetMessage(messageID)
	if m == nil {
		return
	}
	for i := range m.Attachments {
		if m.Attachments[i].ID == attachmentID {
			m.Attachments[i].LocalPath = path
		}
	}
	data, _ := json.Marshal(m.Attachments)
	_, _ = s.db.Exec(`UPDATE messages SET attachments=? WHERE id=?`, string(data), messageID)
}

// MARK: - Reactions

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
			out[messageID] = append(out[messageID], r)
		}
	}
	return out
}

// MARK: - Conversion to API types

func (s *Store) Conversation(t *threadRow, selfID string) apiConversation {
	participants := s.Participants(t.ID)
	conv := apiConversation{
		ID:              t.ID,
		Name:            t.Name,
		AvatarURL:       t.AvatarURL,
		Snippet:         t.Snippet,
		SnippetSenderID: t.SnippetSenderID,
		LastActivity:    t.LastActivity,
		IsGroup:         !t.Type.IsOneToOne(),
		IsEncrypted:     t.Type.IsWhatsApp(),
		IsMuted:         t.MuteUntil == -1 || t.MuteUntil > time.Now().UnixMilli(),
		IsMarketplace:   t.Type == table.MARKETPLACE,
		Participants:    make([]apiParticipant, 0, len(participants)),
	}
	if colors := s.Get("colors:" + t.ID); colors != "" {
		conv.BubbleColors = strings.Split(colors, ",")
	}
	conv.QuickEmoji = s.Get("emoji:" + t.ID)
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
	if t.LastActivity > t.LastRead && t.SnippetSenderID != selfID {
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
	}
}

var errNotFound = errors.New("not found")
