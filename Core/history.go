package main

import (
	"context"
	"strconv"
	"strings"
	"sync"
	"time"

	"go.mau.fi/mautrix-meta/pkg/messagix/socket"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
)

// MARK: - A chat's message history

// listMessages returns a page of stored messages older than `before` (0: the newest). When the
// store runs out, older history is fetched from Messenger in the background; it arrives as
// message events. `noServer`: not now (an encrypted chat whose newer history the web app is
// still reading; its server history is only its unencrypted past, older than all that).
func (c *Core) listMessages(threadID string, before int64, limit int, noServer bool) apiMessagesPage {
	if limit <= 0 {
		limit = 50
	}
	rows := c.store.ListMessages(threadID, before, limit)
	canBackfill := c.canFetchOlder(threadID)
	if len(rows) < limit && canBackfill && !noServer {
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
// unencrypted past: see historyThreadKey).
func (c *Core) canFetchOlder(threadID string) bool {
	t := c.store.GetThread(threadID)
	return t != nil && t.HasMoreBefore &&
		(!t.Type.IsWhatsApp() || t.Type == table.ENCRYPTED_OVER_WA_ONE_TO_ONE || t.FBKey != "")
}

// historyThreadKey is the Facebook thread holding the chat's history on the server. For an
// encrypted 1:1 chat that's the plain 1:1 chat with them (its key is their user ID): its
// unencrypted past, and messages sent without encryption. Its own Facebook key has none.
func (c *Core) historyThreadKey(threadID string) int64 {
	if t := c.store.GetThread(threadID); t != nil && t.Type == table.ENCRYPTED_OVER_WA_ONE_TO_ONE {
		if key, err := strconv.ParseInt(threadID, 10, 64); err == nil {
			return key
		}
	}
	return c.fbThreadKey(threadID)
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
		ThreadKey:            c.historyThreadKey(threadID),
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
		// An encrypted chat's Facebook thread may have no history at all: the server answers
		// with nothing (not even a range), so it would be asked again forever.
		if t := c.store.GetThread(threadID); t != nil && t.Type.IsWhatsApp() {
			if upserts, inserts := resp.WrapMessages(); len(upserts) == 0 && len(inserts) == 0 {
				c.store.SetThreadHasMoreBefore(threadID, false)
			}
		}
	}
	return true
}
