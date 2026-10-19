package main

import (
	"reflect"
	"slices"
	"strconv"
	"strings"
	"sync"

	"go.mau.fi/mautrix-meta/pkg/messagix/socket"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
)

// Messenger's sync groups: 1 holds regular chats, 95 end-to-end encrypted (and request) chats.
const (
	syncGroupMain      = 1
	syncGroupEncrypted = 95
)

func id64(v int64) string { return strconv.FormatInt(v, 10) }

// MARK: - Hybrid (E2EE) thread mapping

// Some threads exist under a Facebook thread key and a WhatsApp-style JID. Everything is
// stored under the JID once a mapping is known.
var (
	threadMapLock sync.Mutex
	threadMap     = map[int64]string{}
)

func (c *Core) setThreadMapping(fbKey int64, jidUser int64) {
	threadMapLock.Lock()
	threadMap[fbKey] = id64(jidUser)
	threadMapLock.Unlock()
	c.store.Set(kvThreadMap+id64(fbKey), id64(jidUser))
}

// forgetThreadMappings drops the cached mappings (at logout: they belong to the account).
func forgetThreadMappings() {
	threadMapLock.Lock()
	threadMap = map[int64]string{}
	threadMapLock.Unlock()
}

// threadID is the ID a Facebook thread key is stored under.
func (c *Core) threadID(fbKey int64) string {
	threadMapLock.Lock()
	defer threadMapLock.Unlock()
	if id, ok := threadMap[fbKey]; ok {
		return id
	}
	key := id64(fbKey)
	if id := c.store.Get(kvThreadMap + key); id != "" {
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

// logTableSummary logs which LightSpeed tables arrived and how many rows each has.
func (c *Core) logTableSummary(tbl *table.LSTable) {
	counts := map[string]int{}
	v := reflect.ValueOf(tbl).Elem()
	for i := 0; i < v.NumField(); i++ {
		if f := v.Field(i); f.Kind() == reflect.Slice && f.Len() > 0 {
			counts[v.Type().Field(i).Name] = f.Len()
		}
	}
	c.log.Debug().Any("tables", counts).Msg("LS table")
}

// handleTable stores a LightSpeed table (a sync update or a task's response) and sends what
// changed to the app.
func (c *Core) handleTable(tbl *table.LSTable) {
	c.logTableSummary(tbl)
	cs := newChangeSet()
	c.handleThreadTables(tbl, cs)
	c.handleMessageTables(tbl, cs)
	c.handlePollTables(tbl, cs)
	c.handleOrphanPollCards(tbl, cs)
	c.handlePollReferences(tbl, cs)
	c.handleReadTables(tbl, cs)

	for _, t := range tbl.LSUpdateTypingIndicator {
		emitEvent("typing", apiTypingEvent{ThreadID: c.threadID(t.ThreadKey), SenderID: id64(t.SenderId), IsTyping: t.IsTyping})
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

// handleThreadTables stores contacts, chats and their participants.
func (c *Core) handleThreadTables(tbl *table.LSTable, cs *changeSet) {
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

	for _, t := range tbl.LSDeleteThenInsertThread {
		c.putThread(t.ThreadKey, t.ThreadType, t.ThreadName, t.ThreadPictureUrl, t.Snippet, t.SnippetSenderContactId,
			t.LastActivityTimestampMs, t.LastReadWatermarkTimestampMs, t.FolderName, t.MuteExpireTimeMs, cs)
		// The unencrypted chat an encrypted one replaced keeps its old theme.
		if t.FolderName != folderE2EECutover {
			c.noteTheme(c.threadID(t.ThreadKey), t.ThemeFbid, t.CustomEmoji)
		}
	}
	for _, t := range tbl.LSUpdateOrInsertThread {
		c.putThread(t.ThreadKey, t.ThreadType, t.ThreadName, t.ThreadPictureUrl, t.Snippet, t.SnippetSenderContactId,
			t.LastActivityTimestampMs, t.LastReadWatermarkTimestampMs, t.FolderName, t.MuteExpireTimeMs, cs)
		// Partial rows may leave the theme out.
		if t.ThemeFbid != 0 && t.FolderName != folderE2EECutover {
			c.noteTheme(c.threadID(t.ThreadKey), t.ThemeFbid, t.CustomEmoji)
		}
	}
	for _, t := range tbl.LSVerifyThreadExists {
		c.store.EnsureThread(c.threadID(t.ThreadKey), t.ThreadType, t.FolderName)
	}
	// Someone changed the chat's theme (Unknown1 is the new theme's ID). Encrypted chats are
	// named by their web ID here.
	for _, t := range tbl.LSUpdateThreadTheme {
		id := c.threadID(t.ThreadKey)
		if userID := c.store.Get(kvWebMap + id); userID != "" {
			id = userID
		}
		c.log.Debug().Str("thread_id", id).Int64("theme", t.Unknown1).Msg("Theme changed")
		if t.Unknown1 != 0 {
			c.noteTheme(id, t.Unknown1, c.store.Get(kvEmoji+id))
		}
	}
	for _, t := range tbl.LSDeleteThread {
		id := c.threadID(t.ThreadKey)
		delete(cs.threads, id)
		c.removeThread(id)
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
}

// handleMessageTables stores messages, their edits, deletions and reactions.
func (c *Core) handleMessageTables(tbl *table.LSTable, cs *changeSet) {
	upserts, inserts := tbl.WrapMessages()
	for _, um := range upserts {
		for _, m := range um.Messages {
			c.storeFBMessage(m, cs)
		}
		if um.Range != nil {
			c.store.SetThreadHasMoreBefore(c.threadID(um.Range.ThreadKey), um.Range.HasMoreBefore)
		}
	}
	for _, m := range inserts {
		c.storeFBMessage(m, cs)
		id := c.threadID(m.ThreadKey)
		hasAttachment := len(m.BlobAttachments)+len(m.Attachments)+len(m.Stickers) > 0
		c.store.BumpThread(id, m.TimestampMs, snippetFor(m.Text, hasAttachment), id64(m.SenderId))
		cs.thread(id)
	}
	for _, m := range tbl.LSDeleteThenInsertMessage {
		if m.IsUnsent {
			c.applyUnsend(cs, m.MessageId)
		}
	}
	for _, e := range tbl.LSEditMessage {
		c.applyEdit(cs, e.MessageID, e.Text)
	}
	for _, d := range tbl.LSDeleteMessage {
		c.store.DeleteMessage(d.MessageId)
		delete(cs.messages, d.MessageId)
		emitEvent("messageRemoved", apiMessageRemovedEvent{ThreadID: c.threadID(d.ThreadKey), MessageID: d.MessageId})
	}

	for _, r := range tbl.LSUpsertReaction {
		c.setReaction(r.MessageId, id64(r.ActorId), r.Reaction, r.TimestampMs)
		cs.message(r.MessageId)
	}
	for _, r := range tbl.LSDeleteReaction {
		c.store.SetReaction(r.MessageId, id64(r.ActorId), "")
		cs.message(r.MessageId)
	}
}

// handleReadTables stores read receipts: others', and ours from this or another device.
func (c *Core) handleReadTables(tbl *table.LSTable, cs *changeSet) {
	self := c.selfID()
	for _, r := range tbl.LSUpdateReadReceipt {
		id := c.threadID(r.ThreadKey)
		reader := id64(r.ContactId)
		c.store.SetReadWatermark(id, reader, r.ReadWatermarkTimestampMs)
		if reader != self {
			emitEvent("readReceipt", apiReadReceiptEvent{ThreadID: id, ReaderID: reader, Timestamp: r.ReadWatermarkTimestampMs})
		} else {
			// Our own receipt: the chat was read on another device (Messenger sends this, not
			// LSMarkThreadRead, for reads elsewhere).
			c.log.Debug().Str("thread", id).Int64("ts", r.ReadWatermarkTimestampMs).Msg("Read on another device (LSUpdateReadReceipt)")
			c.applyRead(cs, id, r.ReadWatermarkTimestampMs)
		}
	}
	for _, r := range tbl.LSMarkThreadRead {
		c.applyRead(cs, c.threadID(r.ThreadKey), r.LastReadWatermarkTimestampMs)
	}
	for _, r := range tbl.LSMarkThreadReadV2 {
		c.applyRead(cs, c.threadID(r.ThreadKey), r.LastReadWatermarkTimestampMs)
	}
}

// mapThread records that a Facebook thread is the encrypted chat jid, moving the chat under
// the JID.
func (c *Core) mapThread(fbKey, jid int64, threadType table.ThreadType, cs *changeSet) {
	jidID := id64(jid)
	c.setThreadMapping(fbKey, jid)
	if threadType == 0 {
		c.store.EnsureThread(jidID, table.ENCRYPTED_OVER_WA_ONE_TO_ONE, folderInbox)
	} else {
		c.store.EnsureThread(jidID, threadType, folderInbox)
		c.store.SetThreadType(jidID, threadType)
	}
	c.store.SetThreadFBKey(jidID, id64(fbKey))
	if fbID := id64(fbKey); fbID != jidID && c.store.GetThread(fbID) != nil {
		c.removeThread(fbID)
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
	if folder == folderE2EECutover && threadType == table.ONE_TO_ONE {
		threadType = table.ENCRYPTED_OVER_WA_ONE_TO_ONE
	}
	if folder == "" {
		folder = folderInbox
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

// The big like, sent as one of these stickers; stored as a 👍 text instead.
var thumbsUpStickers = map[int64]bool{369239263222822: true, 369239343222814: true, 369239383222810: true}

// parseMentions reads a message's tags (people, or the whole chat for @everyone) from its
// comma-separated mention columns.
func parseMentions(ids, offsets, lengths, types string) []apiMention {
	mentions, err := (&socket.MentionData{
		MentionIDs: ids, MentionOffsets: offsets, MentionLengths: lengths, MentionTypes: types,
	}).Parse()
	if err != nil {
		return nil
	}
	var out []apiMention
	for _, m := range mentions {
		if m.Length <= 0 {
			continue
		}
		mention := apiMention{Offset: m.Offset, Length: m.Length}
		if m.Type == socket.MentionTypePerson || m.Type == socket.MentionTypeSilent {
			mention.UserID = id64(m.ID)
		}
		out = append(out, mention)
	}
	return out
}

func (c *Core) storeFBMessage(m *table.WrappedMessage, cs *changeSet) {
	if m == nil || m.LSInsertMessage == nil || m.MessageId == "" {
		return
	}
	isThumbsUp := thumbsUpStickers[m.StickerId]
	text := m.Text
	if isThumbsUp {
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
	if !isThumbsUp {
		row.Mentions = parseMentions(m.MentionIds, m.MentionOffsets, m.MentionLengths, m.MentionTypes)
	}
	if m.ReplySourceId != "" {
		row.ReplyTo = &apiReply{MessageID: m.ReplySourceId, Text: firstNonEmpty(m.ReplyMessageText, m.ReplySnippet)}
		if m.ReplyToUserId != 0 {
			row.ReplyTo.SenderID = id64(m.ReplyToUserId)
		}
	}

	seen := map[string]bool{}
	add := func(a apiAttachment) {
		if a.ID == "" || seen[a.ID] {
			return
		}
		seen[a.ID] = true
		row.Attachments = append(row.Attachments, storedAttachment{apiAttachment: a})
	}
	for _, b := range m.BlobAttachments {
		add(mediaAttachment(b.AttachmentFbid, b.AttachmentType, b.PlayableUrl, b.PreviewUrl,
			int(b.PreviewWidth), int(b.PreviewHeight), b.Filename, firstNonEmpty(b.PlayableUrlMimeType, b.AttachmentMimeType, b.PreviewUrlMimeType)))
	}
	for _, b := range m.Attachments {
		add(mediaAttachment(b.AttachmentFbid, b.AttachmentType, b.PlayableUrl, b.PreviewUrl,
			int(b.PreviewWidth), int(b.PreviewHeight), b.Filename, firstNonEmpty(b.PlayableUrlMimeType, b.AttachmentMimeType, b.PreviewUrlMimeType)))
	}
	if !isThumbsUp {
		for _, s := range m.Stickers {
			add(apiAttachment{
				ID: s.AttachmentFbid, Kind: kindSticker, URL: firstNonEmpty(s.PreviewUrl, s.ImageUrl),
				Width: int(s.PreviewWidth), Height: int(s.PreviewHeight), MimeType: s.PreviewUrlMimeType,
			})
		}
	}
	for _, x := range m.XMAAttachments {
		if call := callFromXMA(x); call != nil {
			add(apiAttachment{ID: x.AttachmentFbid, Kind: kindCall, Title: x.TitleText, Call: call})
			continue
		}
		if poll := pollFromXMA(x); poll != nil {
			c.log.Debug().Any("xma", x).Msg("Poll card")
			c.setPollCard(poll.ID, row.ID, row.Timestamp, cs)
			if poll.Question != "" {
				c.store.Set(kvPollQ+poll.ID, poll.Question)
			}
			c.setCardVoters(poll.ID, x, cs)
			add(apiAttachment{ID: firstNonEmpty(x.AttachmentFbid, "poll-"+poll.ID), Kind: kindPoll, Title: poll.Question, Poll: poll})
			continue
		}
		// A shared post, reel, story, song or link: a card with the preview Messenger ships in the
		// XMA (title, a description line, where it's from), since these aren't fetchable web pages.
		title := firstNonEmpty(x.TitleText, x.SubtitleText)
		subtitle := x.DescriptionText
		if subtitle == "" && x.TitleText != "" {
			subtitle = x.SubtitleText // not already used as the title
		}
		add(apiAttachment{
			ID: x.AttachmentFbid, Kind: kindLink, URL: x.ActionUrl,
			PreviewURL: firstNonEmpty(x.PreviewUrl, x.ImageUrl),
			Width:      int(x.PreviewWidth), Height: int(x.PreviewHeight),
			Title:    title,
			Subtitle: subtitle,
			Source:   firstNonEmpty(x.SourceText, x.AttributionAppName),
		})
	}

	if existing := c.store.GetMessage(row.ID); existing != nil {
		// Keep downloaded files and the edited flag.
		row.IsEdited = existing.IsEdited
		// Messenger sends some messages again without their poll card (in history pages): keep it.
		if !hasPollCard(row.Attachments) && hasPollCard(existing.Attachments) {
			row.Attachments = slices.DeleteFunc(row.Attachments, func(a storedAttachment) bool { return a.Kind == kindPoll })
			for _, a := range existing.Attachments {
				if a.Kind == kindPoll {
					row.Attachments = append(row.Attachments, a)
				}
			}
		}
		for i := range row.Attachments {
			if old := existing.attachment(row.Attachments[i].ID); old != nil {
				row.Attachments[i].LocalPath = old.LocalPath
			}
		}
	}
	c.store.PutMessage(row)
	cs.message(row.ID)
	for _, r := range m.Reactions {
		c.store.SetReaction(r.MessageId, id64(r.ActorId), r.Reaction)
	}
}

// callFromXMA reads a call log card ("Audio call · 9 min", with Call Back): its button's type
// is "xma_rtc_<outcome>_<audio|video>" (e.g. xma_rtc_ended_audio, xma_rtc_missed_video).
func callFromXMA(x *table.WrappedXMA) *apiCall {
	if x.CTA == nil || !strings.HasPrefix(x.CTA.Type_, "xma_rtc_") {
		return nil
	}
	kind := x.CTA.Type_
	call := &apiCall{IsVideo: strings.HasSuffix(kind, "_video"), Outcome: callEnded}
	if strings.Contains(kind, "missed") {
		call.Outcome = callMissed
	} else {
		call.DurationText = x.SubtitleText
	}
	return call
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

// snippetFor is the chat list's preview of a message.
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
