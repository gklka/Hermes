package main

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	waTypes "go.mau.fi/whatsmeow/types"

	"go.mau.fi/mautrix-meta/pkg/messagix"
	"go.mau.fi/mautrix-meta/pkg/messagix/methods"
	"go.mau.fi/mautrix-meta/pkg/messagix/socket"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
)

// MARK: - The chat list

// listThreads is the chat list, newest first.
func (c *Core) listThreads() []apiConversation {
	self := c.selfID()
	rows := c.store.ListThreads()
	out := make([]apiConversation, 0, len(rows))
	for _, t := range rows {
		conv := c.store.Conversation(t, self)
		out = append(out, conv)
		c.lookUpNames(t, conv)
	}
	return out
}

var threadSyncGroups = []int64{syncGroupMain, syncGroupEncrypted}

func (c *Core) loadMoreThreads(ctx context.Context) error {
	cli, err := c.requireClient()
	if err != nil {
		return err
	}
	for _, group := range threadSyncGroups {
		if _, _, err := c.fetchThreadPage(ctx, cli, group); err != nil {
			return err
		}
	}
	return nil
}

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
	c.fillEmptyPreviews(ctx)
	for _, list := range []string{requestListMayKnow, requestListSpam} {
		if err := c.loadRequests(ctx, list, false); err != nil {
			c.log.Warn().Err(err).Str("list", list).Msg("Couldn't load the message requests")
		}
	}
}

// fillEmptyPreviews loads the latest messages of encrypted 1:1 chats that have neither a snippet
// nor stored messages (Messenger itself only shows the "end-to-end encrypted" notice for them)
// from their plain chat on the server, so the chat list shows the latest one.
func (c *Core) fillEmptyPreviews(ctx context.Context) {
	ids := c.store.ThreadsWithoutPreview(table.ENCRYPTED_OVER_WA_ONE_TO_ONE)
	c.log.Info().Int("chats", len(ids)).Msg("Loading the latest messages of chats without a preview")
	for _, id := range ids {
		if !c.canFetchOlder(id) {
			continue
		}
		c.backfill(id, time.Now().UnixMilli(), "")
		// The page can also arrive as a socket event a moment later.
		select {
		case <-ctx.Done():
			return
		case <-time.After(1500 * time.Millisecond):
		}
		c.emitThread(id)
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
	t := c.store.GetThread(userID)
	if t == nil || t.LastActivity == 0 {
		c.store.EnsureEncryptedDirectThread(userID, self)
		c.store.BumpThread(userID, time.Now().UnixMilli(), "", "")
	}
	if t == nil {
		// Someone you haven't chatted with: Messenger creates the chat too.
		go c.createDirectChat(userID)
	}
	conv := c.store.Conversation(c.store.GetThread(userID), self)
	emitEvent("thread", conv)
	return conv, nil
}

// resyncThread forgets the chat's stored messages, so the next page asked for loads them from
// Messenger again (an encrypted chat's history comes back from the web app).
func (c *Core) resyncThread(threadID string) error {
	if _, err := c.thread(threadID); err != nil {
		return err
	}
	c.store.DeleteThreadMessages(threadID)
	c.store.SetThreadHasMoreBefore(threadID, true)
	c.log.Info().Str("thread_id", threadID).Msg("Forgot the chat's messages to load them again")
	return nil
}

// fetchThreadExtras asks Messenger for a thread's extra data beyond its messages, which brings
// back its active polls (their options and votes). Polls aren't included in history pages, so
// this is the only way to restore a poll the app didn't see created. Regular chats only; the
// response's poll tables arrive asynchronously and are handled like any other event.
func (c *Core) fetchThreadExtras(threadID string) {
	t := c.store.GetThread(threadID)
	if t == nil || t.Type.IsWhatsApp() {
		return
	}
	key, err := strconv.ParseInt(threadID, 10, 64)
	if err != nil {
		return
	}
	cli := c.client()
	if cli == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	resp, err := cli.ExecuteTasks(ctx, &socket.FetchAdditionalThreadData{ThreadKey: key})
	if err != nil {
		c.log.Warn().Err(err).Str("thread_id", threadID).Msg("Fetch additional thread data failed")
		return
	}
	if resp != nil {
		c.handleTable(resp)
	}
}

// createDirectChat creates the 1:1 chat with someone on Messenger (its Facebook thread and the
// encrypted chat), as Messenger's own apps do when you message someone new.
func (c *Core) createDirectChat(userID string) {
	cli := c.client()
	id, err := strconv.ParseInt(userID, 10, 64)
	if cli == nil || err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	log := c.log.With().Str("user_id", userID).Logger()
	if _, err := cli.ExecuteTasks(ctx, &socket.CreateThreadTask{ThreadFBID: id, SyncGroup: 1}); err != nil {
		log.Warn().Err(err).Msg("Failed to create the chat")
	}
	resp, err := cli.ExecuteTasks(ctx, &socket.CreateWhatsAppThreadTask{
		WAJID:            id,
		OfflineThreadKey: methods.GenerateEpochID(),
		ThreadType:       table.ENCRYPTED_OVER_WA_ONE_TO_ONE,
		FolderType:       table.INBOX,
		BumpTimestampMS:  time.Now().UnixMilli(),
	})
	if err != nil {
		log.Warn().Err(err).Msg("Failed to create the encrypted chat")
		return
	}
	// Messenger answers with follow-up tasks that finish creating it.
	if len(resp.LSIssueNewTask) > 0 {
		tasks := make([]socket.Task, len(resp.LSIssueNewTask))
		for i, task := range resp.LSIssueNewTask {
			tasks[i] = task
		}
		if _, err := cli.ExecuteTasks(ctx, tasks...); err != nil {
			log.Warn().Err(err).Msg("Failed to finish creating the encrypted chat")
			return
		}
	}
	log.Info().Msg("Created chat")
}

// createGroupChat creates a group chat with the given people and returns it. Messenger assigns
// the real thread ID, which comes back as the replacement for the optimistic one we send up. New
// group chats aren't end-to-end encrypted (unlike new 1:1 chats).
func (c *Core) createGroupChat(ctx context.Context, userIDs []string) (apiConversation, error) {
	cli := c.client()
	if cli == nil {
		return apiConversation{}, errors.New("not connected")
	}
	participants := make([]int64, 0, len(userIDs))
	for _, u := range userIDs {
		if id, err := strconv.ParseInt(u, 10, 64); err == nil && id != 0 {
			participants = append(participants, id)
		}
	}
	if len(participants) < 2 {
		return apiConversation{}, errors.New("a group needs at least two people")
	}
	optimisticID := methods.GenerateEpochID()
	resp, err := cli.ExecuteTasks(ctx, &socket.CreateGroupTask{
		Participants: participants,
		SendPayload: socket.CreateGroupPayload{
			ThreadID: optimisticID,
			OTID:     strconv.FormatInt(methods.GenerateEpochID(), 10),
			Source:   0,
			SendType: 8,
		},
	})
	if err != nil {
		return apiConversation{}, err
	}
	if len(resp.LSIssueNewError) > 0 {
		e := resp.LSIssueNewError[0]
		return apiConversation{}, errors.New(firstNonEmpty(e.ErrorMessage, e.ErrorTitle, "couldn't create the group"))
	}
	if len(resp.LSReplaceOptimisticThread) == 0 {
		return apiConversation{}, errors.New("unexpected response creating the group")
	}
	threadID := strconv.FormatInt(resp.LSReplaceOptimisticThread[0].ThreadKey2, 10)
	// Store whatever the response already carries (the new thread and its members)...
	c.handleTable(resp)
	// ...then make sure it exists with its members, even if the response was sparse.
	self := c.selfID()
	c.store.EnsureThread(threadID, table.GROUP_THREAD, "")
	c.store.EnsureParticipant(threadID, self)
	for _, u := range userIDs {
		c.store.EnsureParticipant(threadID, u)
	}
	c.store.BumpThread(threadID, time.Now().UnixMilli(), "", "")
	conv := c.store.Conversation(c.store.GetThread(threadID), self)
	emitEvent("thread", conv)
	return conv, nil
}

// searchPeople finds people on Messenger by name (not only the ones you've chatted with), who
// can be messaged.
func (c *Core) searchPeople(ctx context.Context, query string) ([]apiParticipant, error) {
	cli := c.client()
	if cli == nil {
		return nil, errors.New("not connected")
	}
	resp, err := cli.ExecuteTasks(ctx, &socket.SearchUserTask{
		Query: query,
		SupportedTypes: []table.SearchType{
			table.SearchTypeContact, table.SearchTypeGroup, table.SearchTypePage, table.SearchTypeNonContact,
		},
		SurfaceType: 5,
	})
	if err != nil {
		return nil, err
	}
	self := c.selfID()
	out := []apiParticipant{}
	for _, r := range resp.LSInsertSearchResult {
		id := r.GetFBID()
		if !r.ThreadType.IsOneToOne() || !r.CanViewerMessage || id == 0 || id64(id) == self {
			continue
		}
		c.store.UpsertContact(id64(id), r.GetName(), r.GetAvatarURL())
		out = append(out, apiParticipant{ID: id64(id), Name: r.GetName(), AvatarURL: r.GetAvatarURL(), Detail: r.ContextLine})
	}
	return out, nil
}

// MARK: - Chat actions

func (c *Core) thread(id string) (*threadRow, error) {
	t := c.store.GetThread(id)
	if t == nil {
		return nil, fmt.Errorf("unknown thread %s", id)
	}
	return t, nil
}

// fbTaskTarget is the Facebook thread key and sync group for thread tasks (encrypted chats
// use their original Facebook thread key in the encrypted sync group).
func (c *Core) fbTaskTarget(t *threadRow) (key, syncGroup int64) {
	if t.Type.IsWhatsApp() {
		return c.fbThreadKey(t.ID), syncGroupEncrypted
	}
	return c.fbThreadKey(t.ID), syncGroupMain
}

// markRead sends read receipts for the chat (here: up to now) and clears its unread state.
func (c *Core) markRead(ctx context.Context, threadID string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	now := time.Now().UnixMilli()
	// The sender of a request doesn't learn that you opened it: read here only.
	if t.IsRequest() {
		c.markThreadReadLocally(threadID, now)
		return nil
	}
	if t.Type.IsWhatsApp() {
		err = c.sendE2EEReadReceipts(ctx, t)
	} else {
		err = c.sendFBReadReceipt(ctx, threadID, now)
	}
	if err != nil {
		return err
	}
	c.markThreadReadLocally(threadID, now)
	return nil
}

func (c *Core) sendFBReadReceipt(ctx context.Context, threadID string, ts int64) error {
	cli, err := c.requireClient()
	if err != nil {
		return err
	}
	_, err = cli.ExecuteTasks(ctx, &socket.ThreadMarkReadTask{
		ThreadId: c.fbThreadKey(threadID), LastReadWatermarkTs: ts, SyncGroup: syncGroupMain,
	})
	return err
}

// sendE2EEReadReceipts marks the unread messages from others read, per sender (as receipts
// on the encrypted connection name the messages). A receipt that fails isn't an error.
func (c *Core) sendE2EEReadReceipts(ctx context.Context, t *threadRow) error {
	e2ee, err := c.requireE2EE()
	if err != nil {
		return err
	}
	bySender := map[string][]waTypes.MessageID{}
	for _, m := range c.store.UnreadFromOthers(t.ID, c.selfID(), t.LastRead) {
		if m.WASender != "" {
			bySender[m.WASender] = append(bySender[m.WASender], m.ID)
		}
	}
	for senderStr, ids := range bySender {
		sender := waTypes.EmptyJID
		if t.Type == table.ENCRYPTED_OVER_WA_GROUP {
			sender, _ = waTypes.ParseJID(senderStr)
		}
		if err := e2ee.MarkRead(ctx, ids, time.Now(), t.chatJID(), sender); err != nil {
			c.log.Warn().Err(err).Msg("Failed to send E2EE read receipt")
		}
	}
	return nil
}

// setUnread marks a thread unread (or clears that) on this Mac only; reading it clears it too.
func (c *Core) setUnread(ctx context.Context, threadID string, unread bool) error {
	if !unread {
		return c.markRead(ctx, threadID)
	}
	// When it was marked: a read on another device after this clears it (applyRead).
	c.store.Set(kvUnread+threadID, strconv.FormatInt(time.Now().UnixMilli(), 10))
	c.emitThread(threadID)
	return nil
}

func (c *Core) muteThread(ctx context.Context, threadID string, muted bool) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	cli, err := c.requireClient()
	if err != nil {
		return err
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
	c.emitThread(threadID)
	return nil
}

func (c *Core) deleteThread(ctx context.Context, threadID string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	cli, err := c.requireClient()
	if err != nil {
		return err
	}
	key, syncGroup := c.fbTaskTarget(t)
	if _, err := cli.ExecuteTasks(ctx, &socket.DeleteThreadTask{ThreadKey: key, SyncGroup: syncGroup}); err != nil {
		return err
	}
	c.store.ForgetThreadSettings(threadID)
	c.removeThread(threadID)
	return nil
}

func (c *Core) leaveThread(ctx context.Context, threadID string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	cli, err := c.requireClient()
	if err != nil {
		return err
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
	cli, err := c.requireClient()
	if err != nil {
		return err
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

// MARK: - Typing and presence

func (c *Core) sendTyping(ctx context.Context, threadID string, typing bool) error {
	t, err := c.thread(threadID)
	if err != nil || t.IsRequest() {
		// A request's sender doesn't see you typing (you can't reply before accepting).
		return err
	}
	if t.Type.IsWhatsApp() {
		e2ee, err := c.requireE2EE()
		if err != nil {
			return err
		}
		state := waTypes.ChatPresencePaused
		if typing {
			state = waTypes.ChatPresenceComposing
		}
		return e2ee.SendChatPresence(ctx, t.chatJID(), state, waTypes.ChatPresenceMediaText)
	}
	cli, err := c.requireClient()
	if err != nil {
		return err
	}
	task := &socket.UpdatePresenceTask{ThreadKey: c.fbThreadKey(threadID), SyncGroup: syncGroupMain, ThreadType: int64(t.Type)}
	if !t.Type.IsOneToOne() {
		task.IsGroupThread = 1
	}
	if typing {
		task.IsTyping = 1
	}
	return cli.ExecuteStatelessTask(ctx, task)
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
	e2ee, err := c.requireE2EE()
	if err != nil {
		return err
	}
	return e2ee.SubscribePresence(ctx, waTypes.JID{User: threadID, Server: waTypes.MessengerServer})
}
