package main

import (
	"context"
	"strings"
	"sync"
	"time"

	"go.mau.fi/mautrix-meta/pkg/messagix/socket"
)

// MARK: - A chat's message history

// listMessages returns a page of stored messages older than `before` (0: the newest). When the
// store runs out, older history is fetched from Messenger in the background; it arrives as
// message events.
func (c *Core) listMessages(threadID string, before int64, limit int) apiMessagesPage {
	if limit <= 0 {
		limit = 50
	}
	rows := c.store.ListMessages(threadID, before, limit)
	canBackfill := c.canFetchOlder(threadID)
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
	return c.messagesPage(rows, len(rows) == limit || canBackfill)
}

func (c *Core) messagesPage(rows []*messageRow, hasMore bool) apiMessagesPage {
	return apiMessagesPage{Messages: c.store.APIMessages(rows, c.selfID()), HasMore: hasMore}
}

// canFetchOlder tells whether Messenger has history before the oldest stored message
// (end-to-end encrypted chats have none on the server, except an encrypted chat's
// unencrypted past, under its Facebook thread key).
func (c *Core) canFetchOlder(threadID string) bool {
	t := c.store.GetThread(threadID)
	return t != nil && t.HasMoreBefore && (!t.Type.IsWhatsApp() || t.FBKey != "")
}

// fetchOlder loads one page of history before the oldest stored message from Messenger
// (synchronously, for search), and returns how many messages it added. A fetch already
// running for the chat (from scrolling back) is waited for, then this one goes on from there.
func (c *Core) fetchOlder(threadID string) apiFetchOlderResult {
	before := c.store.MessageCount(threadID)
	for wait := 0; c.canFetchOlder(threadID) && wait < 150; wait++ {
		refTs, refID := c.store.OldestMessage(threadID)
		if c.backfill(threadID, refTs, refID) {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	fetched := c.store.MessageCount(threadID) - before
	return apiFetchOlderResult{Fetched: fetched, HasMore: c.canFetchOlder(threadID)}
}

var (
	backfillLock    sync.Mutex
	backfillRunning = map[string]bool{}
)

// backfill asks the server for messages older than the reference. Results arrive as tables
// (in the direct response and/or as a later socket event) and are emitted as message events.
// Returns false without asking if a backfill of the chat is already running.
func (c *Core) backfill(threadID string, refTs int64, refID string) bool {
	backfillLock.Lock()
	if backfillRunning[threadID] {
		backfillLock.Unlock()
		return false
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
		return true
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	// Only Facebook message IDs can be the reference (not encrypted ones).
	if !strings.HasPrefix(refID, "mid.") {
		refID = ""
	}
	resp, err := cli.ExecuteTasks(ctx, &socket.FetchMessagesTask{
		ThreadKey:            c.fbThreadKey(threadID),
		Direction:            0,
		ReferenceTimestampMs: refTs,
		ReferenceMessageId:   refID,
		SyncGroup:            syncGroupMain,
		Cursor:               cli.GetCursor(syncGroupMain),
	})
	if err != nil {
		c.log.Warn().Err(err).Str("thread_id", threadID).Msg("Backfill request failed")
		return true
	}
	if resp != nil {
		c.handleTable(resp)
	}
	return true
}
