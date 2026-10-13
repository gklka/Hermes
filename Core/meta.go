package main

import (
	"reflect"
	"strconv"
	"sync"

	"go.mau.fi/mautrix-meta/pkg/messagix/table"
)

// changeSet collects what a table touched, so each thread/message is emitted once.
type changeSet struct {
	threads  map[string]bool
	messages map[string]string // messageID → pendingID (may be empty)
}

func newChangeSet() *changeSet {
	return &changeSet{threads: map[string]bool{}, messages: map[string]string{}}
}

func (cs *changeSet) thread(id string)  { cs.threads[id] = true }
func (cs *changeSet) message(id string) { cs.messages[id] = cs.messages[id] }

func (c *Core) flush(cs *changeSet) {
	self := c.selfID()
	for id := range cs.threads {
		if t := c.store.GetThread(id); t != nil {
			if t.Visible() {
				emitEvent("thread", c.store.Conversation(t, self))
			} else {
				// Also drops it from the list if it was just moved to requests/spam.
				emitEvent("threadRemoved", map[string]string{"threadID": id})
			}
		}
	}
	for id, pendingID := range cs.messages {
		m := c.store.GetMessage(id)
		if m == nil {
			continue
		}
		api := c.store.APIMessages([]*messageRow{m}, self)[0]
		api.PendingID = pendingID
		emitEvent("message", api)
	}
}

// MARK: - Hybrid (E2EE) thread mapping

// Some threads exist under a Facebook thread key and a WhatsApp-style JID. Everything is
// stored under the JID once a mapping is known.
var threadMapLock sync.Mutex
var threadMap = map[int64]string{}

func (c *Core) setThreadMapping(fbKey int64, jidUser int64) {
	threadMapLock.Lock()
	threadMap[fbKey] = strconv.FormatInt(jidUser, 10)
	threadMapLock.Unlock()
	c.store.Set("map:"+strconv.FormatInt(fbKey, 10), strconv.FormatInt(jidUser, 10))
}

func (c *Core) threadID(fbKey int64) string {
	threadMapLock.Lock()
	defer threadMapLock.Unlock()
	if id, ok := threadMap[fbKey]; ok {
		return id
	}
	key := strconv.FormatInt(fbKey, 10)
	if id := c.store.Get("map:" + key); id != "" {
		threadMap[fbKey] = id
		return id
	}
	return key
}

// fbThreadKey returns the Facebook thread key to use for socket tasks.
func (c *Core) fbThreadKey(threadID string) int64 {
	if t := c.store.GetThread(threadID); t != nil && t.FBKey != "" {
		if key, err := strconv.ParseInt(t.FBKey, 10, 64); err == nil {
			return key
		}
	}
	key, _ := strconv.ParseInt(threadID, 10, 64)
	return key
}

// MARK: - Table handling

func id64(v int64) string { return strconv.FormatInt(v, 10) }

// logTableSummary logs which LightSpeed tables arrived and the thread rows in them (debugging aid).
func (c *Core) logTableSummary(tbl *table.LSTable) {
	counts := map[string]int{}
	v := reflect.ValueOf(tbl).Elem()
	for i := 0; i < v.NumField(); i++ {
		if f := v.Field(i); f.Kind() == reflect.Slice && f.Len() > 0 {
			counts[v.Type().Field(i).Name] = f.Len()
		}
	}
	c.log.Debug().Any("tables", counts).Msg("LS table")
	for _, t := range tbl.LSDeleteThenInsertThread {
		c.log.Debug().Int64("key", t.ThreadKey).Int64("type", int64(t.ThreadType)).Str("folder", t.FolderName).
			Int64("activity", t.LastActivityTimestampMs).Bool("has_snippet", t.Snippet != "").Msg("LS thread (full)")
	}
	for _, t := range tbl.LSUpdateOrInsertThread {
		c.log.Debug().Int64("key", t.ThreadKey).Int64("type", int64(t.ThreadType)).Str("folder", t.FolderName).
			Int64("activity", t.LastActivityTimestampMs).Bool("has_snippet", t.Snippet != "").Msg("LS thread (partial)")
	}
	for _, t := range tbl.LSVerifyThreadExists {
		c.log.Debug().Int64("key", t.ThreadKey).Int64("type", int64(t.ThreadType)).Str("folder", t.FolderName).Msg("LS thread (verify)")
	}
	for _, h := range tbl.LSVerifyHybridThreadExists {
		c.log.Debug().Int64("key", h.ThreadKey).Int64("jid", h.ThreadJID).Int64("type", int64(h.ThreadType)).
			Int64("activity", h.LastActivityTimestampMS).Msg("LS hybrid thread")
	}
}

func (c *Core) handleTable(tbl *table.LSTable) {
	c.logTableSummary(tbl)
	cs := newChangeSet()
	self := c.selfID()

	for _, m := range tbl.LSUpdateThreadAuthorityAndMappingWithOTIDFromJID {
		c.mapThread(m.ThreadKey, m.ThreadJID, 0, cs)
	}
	for _, m := range tbl.LSVerifyHybridThreadExists {
		c.mapThread(m.ThreadKey, m.ThreadJID, m.ThreadType, cs)
	}

	// Contacts first so thread names resolve.
	for _, ct := range tbl.LSDeleteThenInsertContact {
		c.store.UpsertContact(id64(ct.Id), ct.Name, ct.ProfilePictureUrl)
	}
	for _, ct := range tbl.LSVerifyContactRowExists {
		c.store.UpsertContact(id64(ct.ContactId), ct.Name, ct.ProfilePictureUrl)
	}

	// Threads
	for _, t := range tbl.LSDeleteThenInsertThread {
		c.putThread(t.ThreadKey, t.ThreadType, t.ThreadName, t.ThreadPictureUrl, t.Snippet, t.SnippetSenderContactId,
			t.LastActivityTimestampMs, t.LastReadWatermarkTimestampMs, t.FolderName, t.MuteExpireTimeMs, cs)
		// The unencrypted chat an encrypted one replaced keeps its old theme.
		if t.FolderName != "e2ee_cutover" {
			c.noteTheme(c.threadID(t.ThreadKey), t.ThemeFbid, t.CustomEmoji)
		}
	}
	for _, t := range tbl.LSUpdateOrInsertThread {
		c.putThread(t.ThreadKey, t.ThreadType, t.ThreadName, t.ThreadPictureUrl, t.Snippet, t.SnippetSenderContactId,
			t.LastActivityTimestampMs, t.LastReadWatermarkTimestampMs, t.FolderName, t.MuteExpireTimeMs, cs)
		// Partial rows may leave the theme out.
		if t.ThemeFbid != 0 && t.FolderName != "e2ee_cutover" {
			c.noteTheme(c.threadID(t.ThreadKey), t.ThemeFbid, t.CustomEmoji)
		}
	}
	for _, t := range tbl.LSVerifyThreadExists {
		id := c.threadID(t.ThreadKey)
		c.store.EnsureThread(id, t.ThreadType, t.FolderName)
	}
	// Someone changed the chat's theme (Unknown1 is the new theme's ID). Encrypted chats are
	// named by their web ID here.
	for _, t := range tbl.LSUpdateThreadTheme {
		id := c.threadID(t.ThreadKey)
		if userID := c.store.Get("webmap:" + id); userID != "" {
			id = userID
		}
		c.log.Debug().Str("thread_id", id).Any("update", t).Msg("Theme changed")
		if t.Unknown1 != 0 {
			c.noteTheme(id, t.Unknown1, c.store.Get("emoji:"+id))
		}
	}
	for _, t := range tbl.LSDeleteThread {
		id := c.threadID(t.ThreadKey)
		c.store.DeleteThread(id)
		delete(cs.threads, id)
		emitEvent("threadRemoved", map[string]string{"threadID": id})
	}
	for _, t := range tbl.LSMoveThreadToE2EECutoverFolder {
		id := c.threadID(t.ThreadKey)
		c.store.SetThreadType(id, table.ENCRYPTED_OVER_WA_ONE_TO_ONE)
		cs.thread(id)
	}
	for _, t := range tbl.LSSyncUpdateThreadName {
		id := c.threadID(t.ThreadKey)
		c.store.SetThreadName(id, t.ThreadName)
		cs.thread(id)
	}
	for _, t := range tbl.LSSetThreadImageURL {
		id := c.threadID(t.ThreadKey)
		c.store.SetThreadAvatar(id, t.ImageURL)
		cs.thread(id)
	}
	for _, t := range tbl.LSUpdateThreadSnippet {
		id := c.threadID(t.ThreadKey)
		c.store.SetThreadSnippet(id, t.Snippet, id64(t.SnippetSenderContactId))
		cs.thread(id)
	}
	for _, t := range tbl.LSUpdateThreadMuteSetting {
		id := c.threadID(t.ThreadKey)
		c.store.SetThreadMute(id, t.MuteExpireTimeMS)
		cs.thread(id)
	}

	// Participants
	for _, p := range tbl.LSAddParticipantIdToGroupThread {
		id := c.threadID(p.ThreadKey)
		c.store.AddParticipant(id, id64(p.ContactId), p.Nickname, p.ReadWatermarkTimestampMs)
		cs.thread(id)
	}
	for _, p := range tbl.LSRemoveParticipantFromThread {
		id := c.threadID(p.ThreadKey)
		c.store.RemoveParticipant(id, id64(p.ParticipantId))
		cs.thread(id)
	}

	// Messages
	upserts, inserts := tbl.WrapMessages()
	for _, um := range upserts {
		for _, m := range um.Messages {
			c.storeFBMessage(m, cs)
		}
		if um.Range != nil {
			id := c.threadID(um.Range.ThreadKey)
			c.store.SetThreadHasMoreBefore(id, um.Range.HasMoreBefore)
		}
	}
	for _, m := range inserts {
		c.storeFBMessage(m, cs)
		id := c.threadID(m.ThreadKey)
		c.store.BumpThread(id, m.TimestampMs, snippetFor(m.Text, len(m.BlobAttachments)+len(m.Attachments)+len(m.Stickers) > 0), id64(m.SenderId))
		cs.thread(id)
	}
	for _, m := range tbl.LSDeleteThenInsertMessage {
		if m.IsUnsent {
			c.store.UnsendMessage(m.MessageId)
			cs.message(m.MessageId)
		}
	}
	for _, e := range tbl.LSEditMessage {
		if threadID := c.store.EditMessage(e.MessageID, e.Text); threadID != "" {
			cs.thread(threadID)
		}
		cs.message(e.MessageID)
	}
	for _, d := range tbl.LSDeleteMessage {
		c.store.DeleteMessage(d.MessageId)
		delete(cs.messages, d.MessageId)
		emitEvent("messageRemoved", map[string]string{"threadID": c.threadID(d.ThreadKey), "messageID": d.MessageId})
	}

	// Reactions
	for _, r := range tbl.LSUpsertReaction {
		c.store.SetReaction(r.MessageId, id64(r.ActorId), r.Reaction)
		cs.message(r.MessageId)
	}
	for _, r := range tbl.LSDeleteReaction {
		c.store.SetReaction(r.MessageId, id64(r.ActorId), "")
		cs.message(r.MessageId)
	}

	// Read receipts
	for _, r := range tbl.LSUpdateReadReceipt {
		id := c.threadID(r.ThreadKey)
		reader := id64(r.ContactId)
		c.store.SetReadWatermark(id, reader, r.ReadWatermarkTimestampMs)
		if reader != self {
			emitEvent("readReceipt", map[string]any{"threadID": id, "readerID": reader, "timestamp": r.ReadWatermarkTimestampMs})
		}
	}
	for _, r := range tbl.LSMarkThreadRead {
		id := c.threadID(r.ThreadKey)
		c.store.SetThreadLastRead(id, r.LastReadWatermarkTimestampMs)
		cs.thread(id)
	}
	for _, r := range tbl.LSMarkThreadReadV2 {
		id := c.threadID(r.ThreadKey)
		c.store.SetThreadLastRead(id, r.LastReadWatermarkTimestampMs)
		cs.thread(id)
	}

	// Typing
	for _, t := range tbl.LSUpdateTypingIndicator {
		emitEvent("typing", map[string]any{"threadID": c.threadID(t.ThreadKey), "senderID": id64(t.SenderId), "isTyping": t.IsTyping})
	}

	// Results of our own sends
	for _, r := range tbl.LSReplaceOptimsiticMessage {
		c.resolvePending(r.OfflineThreadingId, r.MessageId, "")
	}
	for _, f := range tbl.LSMarkOptimisticMessageFailed {
		c.resolvePending(f.OTID, "", f.Message)
	}
	for _, f := range tbl.LSHandleFailedTask {
		if f.OTID != "" {
			c.resolvePending(f.OTID, "", f.Message)
		}
	}

	c.flushWithPending(cs)
}

func (c *Core) mapThread(fbKey, jid int64, threadType table.ThreadType, cs *changeSet) {
	jidID := id64(jid)
	c.setThreadMapping(fbKey, jid)
	if threadType == 0 {
		c.store.EnsureThread(jidID, table.ENCRYPTED_OVER_WA_ONE_TO_ONE, "inbox")
	} else {
		c.store.EnsureThread(jidID, threadType, "inbox")
		c.store.SetThreadType(jidID, threadType)
	}
	c.store.SetThreadFBKey(jidID, id64(fbKey))
	if fbID := id64(fbKey); fbID != jidID {
		if c.store.GetThread(fbID) != nil {
			c.store.DeleteThread(fbID)
			emitEvent("threadRemoved", map[string]string{"threadID": fbID})
		}
	}
	cs.thread(jidID)
}

func (c *Core) putThread(key int64, threadType table.ThreadType, name, picture, snippet string, snippetSender,
	lastActivity, lastRead int64, folder string, muteUntil int64, cs *changeSet) {
	id := c.threadID(key)
	existing := c.store.GetThread(id)
	// Never downgrade a thread we know is end-to-end encrypted.
	if existing != nil && existing.Type.IsWhatsApp() && !threadType.IsWhatsApp() {
		threadType = existing.Type
	}
	if folder == "e2ee_cutover" && threadType == table.ONE_TO_ONE {
		threadType = table.ENCRYPTED_OVER_WA_ONE_TO_ONE
	}
	if folder == "" {
		folder = "inbox"
	}
	fbKey := ""
	if existing != nil {
		fbKey = existing.FBKey
	}
	if id != id64(key) {
		fbKey = id64(key)
	}
	senderID := ""
	if snippetSender != 0 {
		senderID = id64(snippetSender)
	}
	c.store.PutThread(&threadRow{
		ID: id, FBKey: fbKey, Type: threadType, Name: name, AvatarURL: picture, Snippet: snippet,
		SnippetSenderID: senderID, LastActivity: lastActivity, LastRead: lastRead, Folder: folder, MuteUntil: muteUntil,
	})
	cs.thread(id)
}

var thumbsUpStickers = map[int64]bool{369239263222822: true, 369239343222814: true, 369239383222810: true}

func (c *Core) storeFBMessage(m *table.WrappedMessage, cs *changeSet) {
	if m == nil || m.LSInsertMessage == nil || m.MessageId == "" {
		return
	}
	text := m.Text
	if thumbsUpStickers[m.StickerId] {
		text = "👍"
	}
	row := &messageRow{
		ID:        m.MessageId,
		ThreadID:  c.threadID(m.ThreadKey),
		SenderID:  id64(m.SenderId),
		Timestamp: m.TimestampMs,
		Text:      text,
		IsSystem:  m.IsAdminMessage,
		IsUnsent:  m.IsUnsent,
		OTID:      m.OfflineThreadingId,
	}
	if m.ReplySourceId != "" {
		replyText := m.ReplyMessageText
		if replyText == "" {
			replyText = m.ReplySnippet
		}
		row.ReplyTo = &apiReply{MessageID: m.ReplySourceId, Text: replyText}
		if m.ReplyToUserId != 0 {
			row.ReplyTo.SenderID = id64(m.ReplyToUserId)
		}
	}

	seen := map[string]bool{}
	add := func(a storedAttachment) {
		if a.ID == "" || seen[a.ID] {
			return
		}
		seen[a.ID] = true
		row.Attachments = append(row.Attachments, a)
	}
	for _, b := range m.BlobAttachments {
		add(storedAttachment{apiAttachment: mediaAttachment(b.AttachmentFbid, b.AttachmentType, b.PlayableUrl, b.PreviewUrl,
			int(b.PreviewWidth), int(b.PreviewHeight), b.Filename, firstNonEmpty(b.PlayableUrlMimeType, b.AttachmentMimeType, b.PreviewUrlMimeType))})
	}
	for _, b := range m.Attachments {
		add(storedAttachment{apiAttachment: mediaAttachment(b.AttachmentFbid, b.AttachmentType, b.PlayableUrl, b.PreviewUrl,
			int(b.PreviewWidth), int(b.PreviewHeight), b.Filename, firstNonEmpty(b.PlayableUrlMimeType, b.AttachmentMimeType, b.PreviewUrlMimeType))})
	}
	for _, s := range m.Stickers {
		if thumbsUpStickers[m.StickerId] {
			continue
		}
		add(storedAttachment{apiAttachment: apiAttachment{
			ID: s.AttachmentFbid, Kind: kindSticker, URL: firstNonEmpty(s.PreviewUrl, s.ImageUrl),
			Width: int(s.PreviewWidth), Height: int(s.PreviewHeight), MimeType: s.PreviewUrlMimeType,
		}})
	}
	for _, x := range m.XMAAttachments {
		add(storedAttachment{apiAttachment: apiAttachment{
			ID: x.AttachmentFbid, Kind: kindLink, URL: x.ActionUrl, PreviewURL: x.PreviewUrl,
			Width: int(x.PreviewWidth), Height: int(x.PreviewHeight), Title: firstNonEmpty(x.TitleText, x.SubtitleText),
		}})
	}

	if existing := c.store.GetMessage(row.ID); existing != nil {
		// Keep downloaded files and the edited flag.
		row.IsEdited = existing.IsEdited
		for i := range row.Attachments {
			for _, old := range existing.Attachments {
				if old.ID == row.Attachments[i].ID {
					row.Attachments[i].LocalPath = old.LocalPath
				}
			}
		}
	}
	c.store.PutMessage(row)
	cs.message(row.ID)
	for _, r := range m.Reactions {
		c.store.SetReaction(r.MessageId, id64(r.ActorId), r.Reaction)
	}
}

func mediaAttachment(id string, attachmentType table.AttachmentType, playable, preview string, w, h int, filename, mime string) apiAttachment {
	a := apiAttachment{ID: id, URL: firstNonEmpty(playable, preview), PreviewURL: preview, Width: w, Height: h, Filename: filename, MimeType: mime}
	switch attachmentType {
	case table.AttachmentTypeImage, table.AttachmentTypeEphemeralImage:
		a.Kind = kindImage
	case table.AttachmentTypeAnimatedImage:
		a.Kind = kindGIF
	case table.AttachmentTypeVideo, table.AttachmentTypeEphemeralVideo:
		a.Kind = kindVideo
	case table.AttachmentTypeAudio, table.AttachmentTypeSoundBite:
		a.Kind = kindAudio
	case table.AttachmentTypeSticker, table.AttachmentTypeSelfieSticker, table.AttachmentTypeThirdPartySticker:
		a.Kind = kindSticker
	default:
		a.Kind = kindFile
	}
	return a
}

func snippetFor(text string, hasAttachment bool) string {
	if text == "" && hasAttachment {
		return "Attachment"
	}
	return text
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// MARK: - Pending (optimistic) sends

func (c *Core) addPending(otid, threadID, pendingID string) {
	c.pendingLock.Lock()
	c.pending[otid] = pendingSend{threadID: threadID, pendingID: pendingID}
	c.pendingLock.Unlock()
}

func (c *Core) resolvePending(otid, messageID, errMsg string) {
	c.pendingLock.Lock()
	p, ok := c.pending[otid]
	if ok && errMsg != "" {
		delete(c.pending, otid)
	}
	c.pendingLock.Unlock()
	if !ok {
		return
	}
	evt := map[string]any{"threadID": p.threadID, "pendingID": p.pendingID}
	if messageID != "" {
		evt["messageID"] = messageID
	}
	if errMsg != "" {
		evt["error"] = errMsg
	}
	emitEvent("pendingResolved", evt)
}

// flushWithPending emits changes, tagging confirmed outgoing messages with their local echo ID.
func (c *Core) flushWithPending(cs *changeSet) {
	c.pendingLock.Lock()
	for id := range cs.messages {
		if m := c.store.GetMessage(id); m != nil && m.OTID != "" {
			if p, ok := c.pending[m.OTID]; ok {
				cs.messages[id] = p.pendingID
				delete(c.pending, m.OTID)
			}
		}
	}
	c.pendingLock.Unlock()
	c.flush(cs)
}
