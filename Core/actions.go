package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waConsumerApplication"
	"go.mau.fi/whatsmeow/proto/waMediaTransport"
	"go.mau.fi/whatsmeow/proto/waMsgApplication"
	waTypes "go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"

	"go.mau.fi/mautrix-meta/pkg/messagix"
	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"go.mau.fi/mautrix-meta/pkg/messagix/methods"
	"go.mau.fi/mautrix-meta/pkg/messagix/socket"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
	"go.mau.fi/mautrix-meta/pkg/messagix/useragent"
)

var errNotConnected = errors.New("not connected")

type rpcRequest struct {
	ID     int64           `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

// HandleRequest routes one request. Anything that sends to a chat runs on a single
// sequential queue so messages go out in the order they were typed.
func (c *Core) HandleRequest(data []byte) {
	var req rpcRequest
	if err := json.Unmarshal(data, &req); err != nil {
		c.log.Err(err).Msg("Invalid request")
		return
	}
	run := func() {
		defer func() {
			if r := recover(); r != nil {
				c.log.Error().Any("panic", r).Str("method", req.Method).Msg("Request panicked")
				emitResponse(req.ID, nil, fmt.Errorf("internal error: %v", r))
			}
		}()
		result, err := c.dispatch(req)
		if err != nil {
			c.log.Warn().Err(err).Str("method", req.Method).Msg("Request failed")
		}
		emitResponse(req.ID, result, err)
	}
	switch req.Method {
	case "messages.send", "messages.sendMedia", "messages.react", "messages.unsend", "messages.edit":
		c.sendQueue <- run
	default:
		go run()
	}
}

type threadParams struct {
	ThreadID     string            `json:"threadID"`
	UserID       string            `json:"userID"`
	MessageID    string            `json:"messageID"`
	AttachmentID string            `json:"attachmentID"`
	Text         string            `json:"text"`
	ReplyTo      string            `json:"replyTo"`
	Emoji        string            `json:"emoji"`
	Path         string            `json:"path"`
	IsTyping     bool              `json:"isTyping"`
	Enabled      bool              `json:"enabled"`
	Before       int64             `json:"before"`
	Limit        int               `json:"limit"`
	Cookies      map[string]string `json:"cookies"`
}

func (c *Core) dispatch(req rpcRequest) (any, error) {
	if c.store == nil {
		return nil, errors.New("core failed to start")
	}
	var p threadParams
	if len(req.Params) > 0 {
		if err := json.Unmarshal(req.Params, &p); err != nil {
			return nil, fmt.Errorf("invalid params: %w", err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	switch req.Method {
	case "log":
		c.log.Info().Str("source", "app").Msg(p.Text)
		return nil, nil
	case "userAgent":
		return map[string]string{"userAgent": useragent.UserAgent}, nil
	case "login":
		return nil, c.Login(ctx, p.Cookies)
	case "logout":
		c.Logout(ctx)
		return nil, nil
	case "threads.list":
		self := c.selfID()
		rows := c.store.ListThreads()
		out := make([]apiConversation, 0, len(rows))
		for _, t := range rows {
			conv := c.store.Conversation(t, self)
			out = append(out, conv)
			c.lookUpNames(t, conv)
		}
		return out, nil
	case "session.cookies":
		// Lets the app's hidden web view share this session (for encrypted chat restore/import).
		c.mu.Lock()
		ck := c.cookies
		c.mu.Unlock()
		if ck == nil {
			return nil, errors.New("not logged in")
		}
		out := map[string]string{}
		for name, value := range ck.GetAll() {
			out[string(name)] = value
		}
		return out, nil
	case "web.importThreads":
		var rows struct {
			Rows []webThreadRow `json:"rows"`
		}
		if err := json.Unmarshal(req.Params, &rows); err != nil {
			return nil, err
		}
		return c.importWebThreads(rows.Rows), nil
	case "web.threadWebID":
		return map[string]string{"webID": c.store.Get("webid:" + p.ThreadID)}, nil
	case "web.threadPath":
		return map[string]string{"path": c.webThreadPath(p.ThreadID)}, nil
	case "web.setThreadTheme":
		var params struct {
			ThreadID string   `json:"threadID"`
			Colors   []string `json:"colors"`
			Emoji    string   `json:"emoji"`
		}
		if err := json.Unmarshal(req.Params, &params); err != nil {
			return nil, err
		}
		c.setThreadTheme(params.ThreadID, params.Colors, params.Emoji)
		return nil, nil
	case "web.importMessages":
		var params struct {
			ThreadID string       `json:"threadID"`
			Messages []webMessage `json:"messages"`
		}
		if err := json.Unmarshal(req.Params, &params); err != nil {
			return nil, err
		}
		return c.importWebMessages(params.ThreadID, params.Messages), nil
	case "contacts.search":
		return c.store.SearchContacts(p.Text, c.selfID(), 50), nil
	case "threads.open":
		return c.openDirectThread(p.UserID)
	case "threads.loadMore":
		return nil, c.loadMoreThreads(ctx)
	case "threads.markRead":
		return nil, c.markRead(ctx, p.ThreadID)
	case "threads.typing":
		return nil, c.sendTyping(ctx, p.ThreadID, p.IsTyping)
	case "threads.setUnread":
		return nil, c.setUnread(ctx, p.ThreadID, p.Enabled)
	case "threads.mute":
		return nil, c.muteThread(ctx, p.ThreadID, p.Enabled)
	case "threads.delete":
		return nil, c.deleteThread(ctx, p.ThreadID)
	case "threads.leave":
		return nil, c.leaveThread(ctx, p.ThreadID)
	case "users.block":
		return nil, c.blockUser(ctx, p.UserID)
	case "threads.refreshTheme":
		return nil, c.refreshTheme(ctx, p.ThreadID)
	case "threads.subscribePresence":
		return nil, c.subscribePresence(ctx, p.ThreadID)
	case "messages.list":
		return c.listMessages(p.ThreadID, p.Before, p.Limit), nil
	case "messages.stored":
		// The newest stored messages, without fetching history (for the Spotlight index).
		return map[string]any{
			"messages": c.store.APIMessages(c.store.ListMessages(p.ThreadID, p.Before, p.Limit), c.selfID()),
			"hasMore":  false,
		}, nil
	case "messages.send":
		return nil, c.sendText(ctx, p.ThreadID, p.Text, p.ReplyTo)
	case "messages.sendMedia":
		return nil, c.sendMedia(ctx, p.ThreadID, p.Path)
	case "messages.react":
		return nil, c.react(ctx, p.ThreadID, p.MessageID, p.Emoji)
	case "messages.unsend":
		return nil, c.unsend(ctx, p.ThreadID, p.MessageID)
	case "messages.edit":
		return nil, c.editMessage(ctx, p.ThreadID, p.MessageID, p.Text)
	case "media.download":
		path, err := c.downloadMedia(ctx, p.MessageID, p.AttachmentID)
		if err != nil {
			return nil, err
		}
		return map[string]string{"path": path}, nil
	default:
		return nil, fmt.Errorf("unknown method %q", req.Method)
	}
}

// MARK: - Threads

func (c *Core) loadMoreThreads(ctx context.Context) error {
	cli := c.client()
	if cli == nil {
		return errNotConnected
	}
	for _, group := range threadSyncGroups {
		if _, _, err := c.fetchThreadPage(ctx, cli, group); err != nil {
			return err
		}
	}
	return nil
}

// Sync group 1 holds regular threads; 95 holds end-to-end encrypted (and request) threads.
var threadSyncGroups = []int64{1, 95}

// fetchThreadPage requests the next page of a thread list. The threads themselves mostly arrive
// shortly afterwards as a socket event. Returns the cursor used and whether more pages exist.
func (c *Core) fetchThreadPage(ctx context.Context, cli *messagix.Client, group int64) (int64, bool, error) {
	keyStore, tbl, err := cli.FetchMoreThreads(ctx, group)
	if err != nil {
		return 0, false, err
	}
	if tbl != nil {
		c.handleTable(tbl)
	}
	if keyStore == nil {
		return 0, false, nil
	}
	return keyStore.MinThreadKey, keyStore.HasMoreBefore, nil
}

// backfillThreads pages through every thread list once per connection, so the sidebar shows
// all chats rather than just the first page of each list.
func (c *Core) backfillThreads(ctx context.Context) {
	cli := c.client()
	if cli == nil {
		return
	}
	for _, group := range threadSyncGroups {
		var prevCursor int64
		for page := 1; page <= 100; page++ {
			cursor, more, err := c.fetchThreadPage(ctx, cli, group)
			if err != nil {
				c.log.Warn().Err(err).Int64("sync_group", group).Msg("Thread backfill failed")
				break
			}
			// Stop when there's nothing more, or the cursor didn't move since the last page.
			if !more || (page > 1 && cursor == prevCursor) {
				c.log.Info().Int64("sync_group", group).Int("pages", page).Msg("Thread backfill complete")
				break
			}
			prevCursor = cursor
			// Give the page's socket event time to arrive and advance the cursor.
			select {
			case <-ctx.Done():
				return
			case <-time.After(2 * time.Second):
			}
		}
	}
}

// openDirectThread returns the 1:1 chat with a user, creating it if needed. 1:1 threads are keyed
// by the other person's ID, and new 1:1 chats on Messenger are end-to-end encrypted, so a missing
// chat is created as an encrypted one. Its history isn't available (it lives in Messenger's PIN
// backup), but messages from now on are.
func (c *Core) openDirectThread(userID string) (apiConversation, error) {
	if userID == "" {
		return apiConversation{}, errors.New("missing user ID")
	}
	self := c.selfID()
	if t := c.store.GetThread(userID); t == nil || t.LastActivity == 0 {
		c.store.EnsureThread(userID, table.ENCRYPTED_OVER_WA_ONE_TO_ONE, "inbox")
		c.store.AddParticipant(userID, self, "", 0)
		c.store.AddParticipant(userID, userID, "", 0)
		c.store.BumpThread(userID, time.Now().UnixMilli(), "", "")
	}
	conv := c.store.Conversation(c.store.GetThread(userID), self)
	emitEvent("thread", conv)
	return conv, nil
}

func (c *Core) chatJID(t *threadRow) waTypes.JID {
	server := waTypes.MessengerServer
	if t.Type == table.ENCRYPTED_OVER_WA_GROUP {
		server = waTypes.GroupServer
	}
	return waTypes.JID{User: t.ID, Server: server}
}

func (c *Core) thread(id string) (*threadRow, error) {
	t := c.store.GetThread(id)
	if t == nil {
		return nil, fmt.Errorf("unknown thread %s", id)
	}
	return t, nil
}

func (c *Core) markRead(ctx context.Context, threadID string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	now := time.Now().UnixMilli()
	if t.Type.IsWhatsApp() {
		e2ee := c.e2eeClient()
		if e2ee == nil {
			return errNotConnected
		}
		chat := c.chatJID(t)
		bySender := map[string][]waTypes.MessageID{}
		for _, m := range c.store.UnreadFromOthers(threadID, c.selfID(), t.LastRead) {
			if m.WASender != "" {
				bySender[m.WASender] = append(bySender[m.WASender], m.ID)
			}
		}
		for senderStr, ids := range bySender {
			sender := waTypes.EmptyJID
			if t.Type == table.ENCRYPTED_OVER_WA_GROUP {
				sender, _ = waTypes.ParseJID(senderStr)
			}
			if err := e2ee.MarkRead(ctx, ids, time.Now(), chat, sender); err != nil {
				c.log.Warn().Err(err).Msg("Failed to send E2EE read receipt")
			}
		}
	} else {
		cli := c.client()
		if cli == nil {
			return errNotConnected
		}
		_, err := cli.ExecuteTasks(ctx, &socket.ThreadMarkReadTask{
			ThreadId: c.fbThreadKey(threadID), LastReadWatermarkTs: now, SyncGroup: 1,
		})
		if err != nil {
			return err
		}
	}
	c.markThreadReadLocally(threadID, now)
	return nil
}

func (c *Core) sendTyping(ctx context.Context, threadID string, typing bool) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	if t.Type.IsWhatsApp() {
		e2ee := c.e2eeClient()
		if e2ee == nil {
			return errNotConnected
		}
		state := waTypes.ChatPresencePaused
		if typing {
			state = waTypes.ChatPresenceComposing
		}
		return e2ee.SendChatPresence(ctx, c.chatJID(t), state, waTypes.ChatPresenceMediaText)
	}
	cli := c.client()
	if cli == nil {
		return errNotConnected
	}
	task := &socket.UpdatePresenceTask{ThreadKey: c.fbThreadKey(threadID), SyncGroup: 1, ThreadType: int64(t.Type)}
	if !t.Type.IsOneToOne() {
		task.IsGroupThread = 1
	}
	if typing {
		task.IsTyping = 1
	}
	return cli.ExecuteStatelessTask(ctx, task)
}

// setUnread marks a thread unread (or clears that) on this Mac only; reading it clears it too.
func (c *Core) setUnread(ctx context.Context, threadID string, unread bool) error {
	if !unread {
		return c.markRead(ctx, threadID)
	}
	// When it was marked: a read on another device after this clears it (applyRead).
	c.store.Set("unread:"+threadID, strconv.FormatInt(time.Now().UnixMilli(), 10))
	cs := newChangeSet()
	cs.thread(threadID)
	c.flush(cs)
	return nil
}

// fbTaskTarget is the Facebook thread key and sync group for thread tasks (encrypted chats
// use their original Facebook thread key in sync group 95).
func (c *Core) fbTaskTarget(t *threadRow) (int64, int64) {
	if t.Type.IsWhatsApp() {
		return c.fbThreadKey(t.ID), 95
	}
	return c.fbThreadKey(t.ID), 1
}

func (c *Core) muteThread(ctx context.Context, threadID string, muted bool) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	cli := c.client()
	if cli == nil {
		return errNotConnected
	}
	until := int64(0)
	if muted {
		until = -1
	}
	key, syncGroup := c.fbTaskTarget(t)
	if _, err := cli.ExecuteTasks(ctx, &socket.MuteThreadTask{ThreadKey: key, MuteExpireTimeMS: until, SyncGroup: syncGroup}); err != nil {
		return err
	}
	c.store.SetThreadMute(threadID, until)
	cs := newChangeSet()
	cs.thread(threadID)
	c.flush(cs)
	return nil
}

func (c *Core) deleteThread(ctx context.Context, threadID string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	cli := c.client()
	if cli == nil {
		return errNotConnected
	}
	key, syncGroup := c.fbTaskTarget(t)
	if _, err := cli.ExecuteTasks(ctx, &socket.DeleteThreadTask{ThreadKey: key, SyncGroup: syncGroup}); err != nil {
		return err
	}
	c.store.DeleteThread(threadID)
	emitEvent("threadRemoved", map[string]string{"threadID": threadID})
	return nil
}

func (c *Core) leaveThread(ctx context.Context, threadID string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	cli := c.client()
	if cli == nil {
		return errNotConnected
	}
	self, err := strconv.ParseInt(c.selfID(), 10, 64)
	if err != nil {
		return err
	}
	key, _ := c.fbTaskTarget(t)
	_, err = cli.ExecuteTasks(ctx, &socket.RemoveParticipantTask{ThreadID: key, ContactID: self})
	return err
}

func (c *Core) blockUser(ctx context.Context, userID string) error {
	cli := c.client()
	if cli == nil {
		return errNotConnected
	}
	id, err := strconv.ParseInt(userID, 10, 64)
	if err != nil {
		return err
	}
	resp, err := cli.ExecuteTasks(ctx, &socket.SetUserBlockStatusTask{
		BlockeeID:       id,
		RequestID:       strconv.FormatInt(time.Now().UnixNano(), 10),
		UserBlockAction: 1,
	})
	if err != nil {
		return err
	}
	for _, reset := range resp.LSResetUserBlockStatus {
		if reset.ContactID == id && !reset.Success {
			return errors.New("the server rejected the block")
		}
	}
	return nil
}

// subscribePresence asks for a 1:1 contact's online status and last-seen time, which arrive
// as "presence" events. 1:1 thread IDs are the other person's user ID.
func (c *Core) subscribePresence(ctx context.Context, threadID string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	if !t.Type.IsOneToOne() {
		return nil
	}
	e2ee := c.e2eeClient()
	if e2ee == nil {
		return errNotConnected
	}
	err = e2ee.SubscribePresence(ctx, waTypes.JID{User: threadID, Server: waTypes.MessengerServer})
	c.log.Debug().Err(err).Str("thread", threadID).Msg("Subscribed to presence")
	return err
}

// MARK: - Messages

var (
	backfillLock    sync.Mutex
	backfillRunning = map[string]bool{}
)

func (c *Core) listMessages(threadID string, before int64, limit int) map[string]any {
	if limit <= 0 {
		limit = 50
	}
	rows := c.store.ListMessages(threadID, before, limit)
	t := c.store.GetThread(threadID)
	// End-to-end encrypted chats have no server-side history.
	canBackfill := t != nil && t.HasMoreBefore && (!t.Type.IsWhatsApp() || t.FBKey != "")
	if len(rows) < limit && canBackfill {
		refTs, refID := before, ""
		if len(rows) > 0 {
			refTs, refID = rows[0].Timestamp, rows[0].ID
		}
		if refTs <= 0 {
			refTs = time.Now().UnixMilli()
		}
		go c.backfill(threadID, refTs, refID)
	}
	return map[string]any{
		"messages": c.store.APIMessages(rows, c.selfID()),
		"hasMore":  len(rows) == limit || canBackfill,
	}
}

// backfill asks the server for messages older than the reference. Results arrive as tables
// (in the direct response and/or as a later socket event) and are emitted as message events.
func (c *Core) backfill(threadID string, refTs int64, refID string) {
	backfillLock.Lock()
	if backfillRunning[threadID] {
		backfillLock.Unlock()
		return
	}
	backfillRunning[threadID] = true
	backfillLock.Unlock()
	defer func() {
		backfillLock.Lock()
		delete(backfillRunning, threadID)
		backfillLock.Unlock()
	}()

	cli := c.client()
	if cli == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if !strings.HasPrefix(refID, "mid.") {
		refID = ""
	}
	resp, err := cli.ExecuteTasks(ctx, &socket.FetchMessagesTask{
		ThreadKey:            c.fbThreadKey(threadID),
		Direction:            0,
		ReferenceTimestampMs: refTs,
		ReferenceMessageId:   refID,
		SyncGroup:            1,
		Cursor:               cli.GetCursor(1),
	})
	if err != nil {
		c.log.Warn().Err(err).Str("thread_id", threadID).Msg("Backfill request failed")
		return
	}
	if resp != nil {
		c.handleTable(resp)
	}
}

func newOTID() (int64, string) {
	otid := methods.GenerateEpochID()
	return otid, strconv.FormatInt(otid, 10)
}

func (c *Core) emitEcho(threadID, pendingID, text string, replyTo *apiReply, attachments []apiAttachment) {
	if attachments == nil {
		attachments = []apiAttachment{}
	}
	emitEvent("message", apiMessage{
		ID:          pendingID,
		ThreadID:    threadID,
		SenderID:    c.selfID(),
		IsFromMe:    true,
		Text:        text,
		Timestamp:   time.Now().UnixMilli(),
		Attachments: attachments,
		ReplyTo:     replyTo,
		Reactions:   []apiReaction{},
		Status:      statusPending,
		PendingID:   pendingID,
	})
}

func (c *Core) failPending(threadID, pendingID string, err error) error {
	emitEvent("pendingResolved", map[string]any{"threadID": threadID, "pendingID": pendingID, "error": err.Error()})
	return err
}

func (c *Core) replyPreview(replyTo string) *apiReply {
	if replyTo == "" {
		return nil
	}
	reply := &apiReply{MessageID: replyTo}
	if target := c.store.GetMessage(replyTo); target != nil {
		reply.Text = target.Text
		reply.SenderID = target.SenderID
	}
	return reply
}

func (c *Core) sendText(ctx context.Context, threadID, text, replyTo string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	otid, otidStr := newOTID()
	pendingID := "pending:" + otidStr
	reply := c.replyPreview(replyTo)
	c.emitEcho(threadID, pendingID, text, reply, nil)

	if t.Type.IsWhatsApp() {
		content := &waConsumerApplication.ConsumerApplication_Content{
			Content: &waConsumerApplication.ConsumerApplication_Content_MessageText{
				MessageText: &waCommon.MessageText{Text: proto.String(text)},
			},
		}
		row := &messageRow{Text: text, ReplyTo: reply}
		return c.sendE2EE(ctx, t, otidStr, pendingID, content, c.quotedMetadata(replyTo), row)
	}

	task := &socket.SendMessageTask{
		ThreadId:         c.fbThreadKey(threadID),
		Otid:             otid,
		Source:           table.MESSENGER_INBOX_IN_THREAD,
		InitiatingSource: table.FACEBOOK_INBOX,
		SendType:         table.TEXT,
		SyncGroup:        1,
		Text:             text,
	}
	if t.Folder == "pending" {
		task.Source = table.MESSENGER_INBOX_PENDING_REQUESTS
	}
	if reply != nil {
		replySender, _ := strconv.ParseInt(reply.SenderID, 10, 64)
		task.ReplyMetaData = &socket.ReplyMetaData{ReplyMessageId: replyTo, ReplySourceType: 1, ReplyType: 0, ReplySender: replySender}
	}
	return c.sendFBTask(ctx, threadID, otidStr, pendingID, task)
}

func (c *Core) sendFBTask(ctx context.Context, threadID, otidStr, pendingID string, task *socket.SendMessageTask) error {
	cli := c.client()
	if cli == nil {
		return c.failPending(threadID, pendingID, errNotConnected)
	}
	c.addPending(otidStr, threadID, pendingID)
	if err := cli.WaitUntilCanSendMessages(ctx, 30*time.Second); err != nil {
		c.resolvePending(otidStr, "", err.Error())
		return err
	}
	readTask := &socket.ThreadMarkReadTask{ThreadId: task.ThreadId, LastReadWatermarkTs: time.Now().UnixMilli(), SyncGroup: 1}
	resp, err := cli.ExecuteTasks(ctx, task, readTask)
	if err != nil {
		c.resolvePending(otidStr, "", err.Error())
		return err
	}
	c.handleTable(resp)
	return nil
}

func (c *Core) quotedMetadata(replyTo string) *waMsgApplication.MessageApplication_Metadata {
	if replyTo == "" {
		return nil
	}
	target := c.store.GetMessage(replyTo)
	if target == nil || target.WASender == "" {
		return nil
	}
	return &waMsgApplication.MessageApplication_Metadata{
		QuotedMessage: &waMsgApplication.MessageApplication_Metadata_QuotedMessage{
			StanzaID:    proto.String(target.ID),
			Participant: proto.String(target.WASender),
		},
	}
}

// sendE2EE sends a consumer message over the encrypted connection and stores our copy
// (whatsmeow doesn't echo our own messages back).
func (c *Core) sendE2EE(
	ctx context.Context, t *threadRow, otidStr, pendingID string,
	content *waConsumerApplication.ConsumerApplication_Content,
	meta *waMsgApplication.MessageApplication_Metadata,
	row *messageRow,
) error {
	e2ee := c.e2eeClient()
	if e2ee == nil || e2ee.Store == nil || e2ee.Store.ID == nil {
		return c.failPending(t.ID, pendingID, errNotConnected)
	}
	msg := &waConsumerApplication.ConsumerApplication{
		Payload: &waConsumerApplication.ConsumerApplication_Payload{
			Payload: &waConsumerApplication.ConsumerApplication_Payload_Content{Content: content},
		},
	}
	chat := c.chatJID(t)
	resp, err := e2ee.SendFBMessage(ctx, chat, msg, meta, whatsmeow.SendRequestExtra{ID: otidStr})
	if err != nil {
		return c.failPending(t.ID, pendingID, err)
	}
	row.ID = resp.ID
	row.ThreadID = t.ID
	row.SenderID = c.selfID()
	row.Timestamp = resp.Timestamp.UnixMilli()
	row.WAChat = chat.String()
	row.WASender = e2ee.Store.ID.ToNonAD().String()
	c.store.PutMessage(row)
	c.store.BumpThread(t.ID, row.Timestamp, snippetFor(row.Text, len(row.Attachments) > 0), row.SenderID)
	cs := newChangeSet()
	cs.messages[row.ID] = pendingID
	cs.thread(t.ID)
	c.flush(cs)
	return nil
}

func waKey(m *messageRow, selfID string) *waCommon.MessageKey {
	key := &waCommon.MessageKey{RemoteJID: proto.String(m.WAChat), ID: proto.String(m.ID)}
	if m.SenderID == selfID {
		key.FromMe = proto.Bool(true)
	}
	if chat, err := waTypes.ParseJID(m.WAChat); err == nil &&
		chat.Server != waTypes.MessengerServer && chat.Server != waTypes.DefaultUserServer {
		key.Participant = proto.String(m.WASender)
	}
	return key
}

func (c *Core) react(ctx context.Context, threadID, messageID, emoji string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	target := c.store.GetMessage(messageID)
	if target == nil {
		return fmt.Errorf("unknown message %s", messageID)
	}
	self := c.selfID()
	if t.Type.IsWhatsApp() && target.WAChat != "" {
		e2ee := c.e2eeClient()
		if e2ee == nil {
			return errNotConnected
		}
		msg := &waConsumerApplication.ConsumerApplication{
			Payload: &waConsumerApplication.ConsumerApplication_Payload{
				Payload: &waConsumerApplication.ConsumerApplication_Payload_Content{
					Content: &waConsumerApplication.ConsumerApplication_Content{
						Content: &waConsumerApplication.ConsumerApplication_Content_ReactionMessage{
							ReactionMessage: &waConsumerApplication.ConsumerApplication_ReactionMessage{
								Key:               waKey(target, self),
								Text:              proto.String(emoji),
								SenderTimestampMS: proto.Int64(time.Now().UnixMilli()),
							},
						},
					},
				},
			},
		}
		if _, err = e2ee.SendFBMessage(ctx, c.chatJID(t), msg, nil); err != nil {
			return err
		}
		c.store.SetReaction(messageID, self, emoji)
		cs := newChangeSet()
		cs.message(messageID)
		c.flush(cs)
		return nil
	}

	cli := c.client()
	if cli == nil {
		return errNotConnected
	}
	actor, _ := strconv.ParseInt(self, 10, 64)
	resp, err := cli.ExecuteTasks(ctx, &socket.SendReactionTask{
		ThreadKey:       c.fbThreadKey(threadID),
		MessageID:       messageID,
		ActorID:         actor,
		Reaction:        emoji,
		SyncGroup:       1,
		SendAttribution: table.MESSENGER_INBOX_IN_THREAD,
	})
	if err != nil {
		return err
	}
	c.handleTable(resp)
	return nil
}

func (c *Core) unsend(ctx context.Context, threadID, messageID string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	target := c.store.GetMessage(messageID)
	if target == nil {
		return fmt.Errorf("unknown message %s", messageID)
	}
	if t.Type.IsWhatsApp() && target.WAChat != "" {
		e2ee := c.e2eeClient()
		if e2ee == nil {
			return errNotConnected
		}
		msg := &waConsumerApplication.ConsumerApplication{
			Payload: &waConsumerApplication.ConsumerApplication_Payload{
				Payload: &waConsumerApplication.ConsumerApplication_Payload_ApplicationData{
					ApplicationData: &waConsumerApplication.ConsumerApplication_ApplicationData{
						ApplicationContent: &waConsumerApplication.ConsumerApplication_ApplicationData_Revoke{
							Revoke: &waConsumerApplication.ConsumerApplication_RevokeMessage{Key: waKey(target, c.selfID())},
						},
					},
				},
			},
		}
		if _, err = e2ee.SendFBMessage(ctx, c.chatJID(t), msg, nil); err != nil {
			return err
		}
	} else {
		cli := c.client()
		if cli == nil {
			return errNotConnected
		}
		resp, err := cli.ExecuteTasks(ctx, &socket.DeleteMessageTask{MessageId: messageID})
		if err != nil {
			return err
		}
		c.handleTable(resp)
	}
	c.store.UnsendMessage(messageID)
	cs := newChangeSet()
	cs.message(messageID)
	c.flush(cs)
	return nil
}

// editMessage changes the text of one of our sent messages (Messenger allows this for 15 minutes).
func (c *Core) editMessage(ctx context.Context, threadID, messageID, text string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	target := c.store.GetMessage(messageID)
	if target == nil {
		return fmt.Errorf("unknown message %s", messageID)
	}
	if t.Type.IsWhatsApp() && target.WAChat != "" {
		e2ee := c.e2eeClient()
		if e2ee == nil {
			return errNotConnected
		}
		msg := &waConsumerApplication.ConsumerApplication{
			Payload: &waConsumerApplication.ConsumerApplication_Payload{
				Payload: &waConsumerApplication.ConsumerApplication_Payload_Content{
					Content: &waConsumerApplication.ConsumerApplication_Content{
						Content: &waConsumerApplication.ConsumerApplication_Content_EditMessage{
							EditMessage: &waConsumerApplication.ConsumerApplication_EditMessage{
								Key:         waKey(target, c.selfID()),
								Message:     &waCommon.MessageText{Text: proto.String(text)},
								TimestampMS: proto.Int64(time.Now().UnixMilli()),
							},
						},
					},
				},
			},
		}
		if _, err = e2ee.SendFBMessage(ctx, c.chatJID(t), msg, nil); err != nil {
			return err
		}
	} else {
		cli := c.client()
		if cli == nil {
			return errNotConnected
		}
		resp, err := cli.ExecuteTasks(ctx, &socket.EditMessageTask{MessageID: messageID, Text: text})
		if err != nil {
			return err
		}
		// The server answers with the message's current text; a different one means it refused
		// (e.g. too late to edit).
		for _, edit := range resp.LSEditMessage {
			if edit.MessageID == messageID && edit.Text != text {
				return errors.New("Messenger didn't accept the edit")
			}
		}
	}
	cs := newChangeSet()
	if threadID := c.store.EditMessage(messageID, text); threadID != "" {
		cs.thread(threadID)
	}
	cs.message(messageID)
	c.flush(cs)
	return nil
}

// MARK: - Media

func kindForMime(mimeType string) string {
	switch {
	case mimeType == "image/gif":
		return kindGIF
	case strings.HasPrefix(mimeType, "image/"):
		return kindImage
	case strings.HasPrefix(mimeType, "video/"):
		return kindVideo
	case strings.HasPrefix(mimeType, "audio/"):
		return kindAudio
	default:
		return kindFile
	}
}

func (c *Core) sendMedia(ctx context.Context, threadID, path string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	filename := filepath.Base(path)
	mimeType := mime.TypeByExtension(strings.ToLower(filepath.Ext(path)))
	if mimeType == "" {
		mimeType = http.DetectContentType(data)
	}
	mimeType, _, _ = strings.Cut(mimeType, ";")
	kind := kindForMime(mimeType)
	width, height := 0, 0
	if cfg, _, err := image.DecodeConfig(bytes.NewReader(data)); err == nil {
		width, height = cfg.Width, cfg.Height
	}

	otid, otidStr := newOTID()
	pendingID := "pending:" + otidStr
	attachment := apiAttachment{
		ID: pendingID + "-0", Kind: kind, LocalPath: path, Width: width, Height: height, Filename: filename, MimeType: mimeType,
	}
	c.emitEcho(threadID, pendingID, "", nil, []apiAttachment{attachment})

	if !t.Type.IsWhatsApp() {
		cli := c.client()
		if cli == nil {
			return c.failPending(threadID, pendingID, errNotConnected)
		}
		resp, err := cli.GetHTTP().SendMercuryUploadRequest(ctx, c.fbThreadKey(threadID), &httpclient.MercuryUploadMedia{
			Filename: filename, MimeType: mimeType, MediaData: data,
		})
		if err != nil {
			return c.failPending(threadID, pendingID, fmt.Errorf("upload failed: %w", err))
		}
		if resp.Payload.RealMetadata == nil || resp.Payload.RealMetadata.GetFbId() == 0 {
			return c.failPending(threadID, pendingID, errors.New("upload failed: no attachment ID"))
		}
		task := &socket.SendMessageTask{
			ThreadId:         c.fbThreadKey(threadID),
			Otid:             otid,
			Source:           table.MESSENGER_INBOX_IN_THREAD,
			InitiatingSource: table.FACEBOOK_INBOX,
			SendType:         table.MEDIA,
			SyncGroup:        1,
			AttachmentFBIds:  []int64{resp.Payload.RealMetadata.GetFbId()},
		}
		return c.sendFBTask(ctx, threadID, otidStr, pendingID, task)
	}

	e2ee := c.e2eeClient()
	if e2ee == nil {
		return c.failPending(threadID, pendingID, errNotConnected)
	}
	mediaType := whatsmeow.MediaDocument
	switch kind {
	case kindImage:
		mediaType = whatsmeow.MediaImage
	case kindVideo, kindGIF:
		// Messenger wants GIFs sent as (looping) videos.
		mediaType = whatsmeow.MediaVideo
	}
	uploaded, err := e2ee.Upload(ctx, data, mediaType)
	if err != nil {
		return c.failPending(threadID, pendingID, fmt.Errorf("upload failed: %w", err))
	}
	thumbW, thumbH := clampTo400(width, height)
	transport := &waMediaTransport.WAMediaTransport{
		Integral: &waMediaTransport.WAMediaTransport_Integral{
			FileSHA256:        uploaded.FileSHA256,
			MediaKey:          uploaded.MediaKey,
			FileEncSHA256:     uploaded.FileEncSHA256,
			DirectPath:        &uploaded.DirectPath,
			MediaKeyTimestamp: proto.Int64(time.Now().Unix()),
		},
		Ancillary: &waMediaTransport.WAMediaTransport_Ancillary{
			FileLength: proto.Uint64(uint64(len(data))),
			Mimetype:   &mimeType,
			// Messenger's mobile apps won't show media without thumbnail dimensions.
			Thumbnail: &waMediaTransport.WAMediaTransport_Ancillary_Thumbnail{
				ThumbnailWidth:  proto.Uint32(uint32(thumbW)),
				ThumbnailHeight: proto.Uint32(uint32(thumbH)),
			},
			ObjectID: &uploaded.ObjectID,
		},
	}

	content := &waConsumerApplication.ConsumerApplication_Content{}
	switch mediaType {
	case whatsmeow.MediaImage:
		msg := &waConsumerApplication.ConsumerApplication_ImageMessage{}
		err = msg.Set(&waMediaTransport.ImageTransport{
			Integral:  &waMediaTransport.ImageTransport_Integral{Transport: transport},
			Ancillary: &waMediaTransport.ImageTransport_Ancillary{Width: proto.Uint32(uint32(width)), Height: proto.Uint32(uint32(height))},
		})
		content.Content = &waConsumerApplication.ConsumerApplication_Content_ImageMessage{ImageMessage: msg}
	case whatsmeow.MediaVideo:
		msg := &waConsumerApplication.ConsumerApplication_VideoMessage{}
		err = msg.Set(&waMediaTransport.VideoTransport{
			Integral: &waMediaTransport.VideoTransport_Integral{Transport: transport},
			Ancillary: &waMediaTransport.VideoTransport_Ancillary{
				Width: proto.Uint32(uint32(width)), Height: proto.Uint32(uint32(height)), GifPlayback: proto.Bool(kind == kindGIF),
			},
		})
		content.Content = &waConsumerApplication.ConsumerApplication_Content_VideoMessage{VideoMessage: msg}
	default:
		msg := &waConsumerApplication.ConsumerApplication_DocumentMessage{FileName: proto.String(filename)}
		err = msg.Set(&waMediaTransport.DocumentTransport{
			Integral:  &waMediaTransport.DocumentTransport_Integral{Transport: transport},
			Ancillary: &waMediaTransport.DocumentTransport_Ancillary{},
		})
		content.Content = &waConsumerApplication.ConsumerApplication_Content_DocumentMessage{DocumentMessage: msg}
	}
	if err != nil {
		return c.failPending(threadID, pendingID, err)
	}

	stored := storedAttachment{
		apiAttachment: apiAttachment{ID: "0", Kind: kind, LocalPath: path, Width: width, Height: height, Filename: filename, MimeType: mimeType},
		WA: &waMediaInfo{
			MediaType: string(mediaType), Key: uploaded.MediaKey, SHA256: uploaded.FileSHA256,
			EncSHA256: uploaded.FileEncSHA256, DirectPath: uploaded.DirectPath,
		},
	}
	row := &messageRow{Attachments: []storedAttachment{stored}}
	return c.sendE2EE(ctx, t, otidStr, pendingID, content, nil, row)
}

func clampTo400(w, h int) (int, int) {
	if w <= 0 || h <= 0 {
		return 400, 400
	}
	if w > h && w > 400 {
		return 400, h * 400 / w
	} else if h > 400 {
		return w * 400 / h, 400
	}
	return w, h
}

// GetDirectPath etc. let waMediaInfo be passed to whatsmeow's Download.
func (m *waMediaInfo) GetDirectPath() string             { return m.DirectPath }
func (m *waMediaInfo) GetMediaKey() []byte               { return m.Key }
func (m *waMediaInfo) GetFileSHA256() []byte             { return m.SHA256 }
func (m *waMediaInfo) GetFileEncSHA256() []byte          { return m.EncSHA256 }
func (m *waMediaInfo) GetMediaType() whatsmeow.MediaType { return whatsmeow.MediaType(m.MediaType) }

func (c *Core) downloadMedia(ctx context.Context, messageID, attachmentID string) (string, error) {
	m := c.store.GetMessage(messageID)
	if m == nil {
		return "", fmt.Errorf("unknown message %s", messageID)
	}
	var att *storedAttachment
	for i := range m.Attachments {
		if m.Attachments[i].ID == attachmentID {
			att = &m.Attachments[i]
		}
	}
	if att == nil {
		return "", fmt.Errorf("unknown attachment %s", attachmentID)
	}
	if att.LocalPath != "" {
		if _, err := os.Stat(att.LocalPath); err == nil {
			return att.LocalPath, nil
		}
	}

	var data []byte
	var err error
	switch {
	case att.WA != nil:
		e2ee := c.e2eeClient()
		if e2ee == nil {
			return "", errNotConnected
		}
		data, err = e2ee.Download(ctx, att.WA)
	case att.URL != "" && att.Kind != kindLink:
		data, err = httpGet(ctx, att.URL)
	default:
		return "", errors.New("attachment has no downloadable media")
	}
	if err != nil {
		return "", fmt.Errorf("download failed: %w", err)
	}

	ext := filepath.Ext(att.Filename)
	if ext == "" {
		ext = extensionFor(firstNonEmpty(att.MimeType, http.DetectContentType(data)))
	}
	name := strings.NewReplacer("/", "_", ":", "_", "$", "_", ".", "_").Replace(messageID + "-" + attachmentID)
	path := filepath.Join(c.dataDir, "media", name+ext)
	if err = os.WriteFile(path, data, 0o600); err != nil {
		return "", err
	}
	c.store.SetAttachmentLocalPath(messageID, attachmentID, path)
	return path, nil
}

func httpGet(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", useragent.UserAgent)
	req.Header.Set("sec-ch-ua", useragent.SecCHUserAgent)
	req.Header.Set("sec-ch-ua-platform", useragent.SecCHPlatform)
	req.Header.Set("Sec-Fetch-Dest", "image")
	req.Header.Set("Sec-Fetch-Mode", "no-cors")
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

var preferredExtensions = map[string]string{
	"image/jpeg": ".jpg", "image/png": ".png", "image/gif": ".gif", "image/webp": ".webp",
	"video/mp4": ".mp4", "video/quicktime": ".mov", "audio/mpeg": ".mp3", "audio/mp4": ".m4a",
	"audio/aac": ".aac", "audio/ogg": ".ogg", "application/pdf": ".pdf",
}

func extensionFor(mimeType string) string {
	mimeType, _, _ = strings.Cut(mimeType, ";")
	if ext, ok := preferredExtensions[mimeType]; ok {
		return ext
	}
	if exts, _ := mime.ExtensionsByType(mimeType); len(exts) > 0 {
		return exts[0]
	}
	return ""
}
