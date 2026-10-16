package main

import (
	"context"
	"fmt"
	"math"

	"go.mau.fi/mautrix-meta/pkg/messagix/socket"
)

// MARK: - Message requests

// Messenger's two request lists by the parent thread keys its web app asks for them with:
// "You may know" (-12; -28 also holds encrypted chats) and Spam (-2). Their chats arrive like
// any others (shortly after, over the socket), with the list's folder.
var requestListParents = map[string][]int64{
	requestListMayKnow: {-12, -28},
	requestListSpam:    {-2},
}

// loadRequests fetches a page of a request list: the newest, or (`more`) the next one after
// the oldest request stored. Regular and encrypted chats are paged separately (sync groups 1
// and 95).
func (c *Core) loadRequests(ctx context.Context, list string, more bool) error {
	parents, ok := requestListParents[list]
	if !ok {
		return fmt.Errorf("unknown request list %q", list)
	}
	cli, err := c.requireClient()
	if err != nil {
		return err
	}
	for _, group := range threadSyncGroups {
		// The first page starts from the newest (the web app passes the largest values).
		var refKey, refActivity int64 = math.MaxInt64, math.MaxInt64
		if more {
			if id, activity := c.store.OldestRequest(list, group == syncGroupEncrypted); id != "" {
				refKey, refActivity = c.fbThreadKey(id), activity
			}
		}
		for _, parent := range parents {
			task := &socket.FetchThreadsTask{
				ParentThreadKey: parent, ReferenceThreadKey: refKey, ReferenceActivityTimestamp: refActivity,
				SyncGroup: int(group),
			}
			if group == syncGroupMain {
				task.Cursor = cli.GetCursor(group)
			}
			resp, err := cli.ExecuteTasks(ctx, task)
			if err != nil {
				return err
			}
			c.handleTable(resp)
		}
	}
	return nil
}

// acceptRequest accepts a message request: the chat moves to the inbox, and they can call you
// and see when you've read their messages.
func (c *Core) acceptRequest(ctx context.Context, threadID string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	cli, err := c.requireClient()
	if err != nil {
		return err
	}
	key, syncGroup := c.fbTaskTarget(t)
	resp, err := cli.ExecuteTasks(ctx, &socket.AcceptMessageRequestTask{ThreadKey: key, SyncGroup: syncGroup})
	if err != nil {
		return err
	}
	c.handleTable(resp)
	// The sync confirms the move later; the chat moves at once.
	c.store.SetThreadFolder(threadID, folderInbox)
	c.emitThread(threadID)
	return nil
}
