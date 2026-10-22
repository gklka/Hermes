package main

import (
	"context"
	"strconv"
	"sync"
	"time"

	"go.mau.fi/mautrix-meta/pkg/messagix/socket"
)

// MARK: - Names of people the sync didn't name

// A new chat (e.g. someone messaging for the first time, or an encrypted chat) can arrive
// before its people's contact rows, so it would be "Unknown" until opened. Such people are
// looked up with GetContactsFullTask as soon as their chat is sent to the app.

var (
	nameLookupLock sync.Mutex
	// When each person was last looked up, so a name Messenger doesn't give isn't asked for
	// over and over.
	nameLookups = map[string]time.Time{}
)

const nameLookupRetry = 10 * time.Minute

// forgetNameLookups drops who was looked up (at logout).
func forgetNameLookups() {
	nameLookupLock.Lock()
	nameLookups = map[string]time.Time{}
	nameLookupLock.Unlock()
}

// lookUpNames asks for the names (and avatars) of the chat's people who lack one. This covers
// unnamed chats (1:1 chats, unnamed groups) whose people arrive before their contact rows, and
// named groups whose members are strangers with no contact row, so they'd otherwise render with
// no name and a "?" avatar. The chats they're in are sent again once resolved.
func (c *Core) lookUpNames(t *threadRow, conv apiConversation) {
	self := c.selfID()
	var ids []string
	nameLookupLock.Lock()
	for _, p := range conv.Participants {
		if p.ID == self || p.ID == "" {
			continue
		}
		// A named group's members can have a nickname but no contact row, so name or avatar may
		// be missing; look them up when either is absent.
		if p.Name != "" && p.AvatarURL != "" {
			continue
		}
		if last, ok := nameLookups[p.ID]; ok && time.Since(last) < nameLookupRetry {
			continue
		}
		nameLookups[p.ID] = time.Now()
		ids = append(ids, p.ID)
	}
	nameLookupLock.Unlock()
	if len(ids) == 0 {
		return
	}
	go func() {
		for _, id := range ids {
			c.lookUpName(id)
		}
	}()
}

// lookUpAllNames covers the unnamed chats listed before the connection was up (whose lookups
// couldn't run then) and old chats that get no updates.
func (c *Core) lookUpAllNames() {
	self := c.selfID()
	for _, t := range c.store.ListThreads() {
		c.lookUpNames(t, c.store.Conversation(t, self))
	}
}

// forgetNameLookup lets the person be looked up again right away (the lookup couldn't run).
func forgetNameLookup(userID string) {
	nameLookupLock.Lock()
	delete(nameLookups, userID)
	nameLookupLock.Unlock()
}

func (c *Core) lookUpName(userID string) {
	key, err := strconv.ParseInt(userID, 10, 64)
	if err != nil {
		return
	}
	cli := c.client()
	if cli == nil {
		forgetNameLookup(userID)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	resp, err := cli.ExecuteTasks(ctx, &socket.GetContactsFullTask{ContactID: key})
	if err != nil || resp == nil {
		c.log.Warn().Err(err).Str("user_id", userID).Msg("Couldn't look up a name")
		// E.g. not connected yet: the chat's next update tries again.
		forgetNameLookup(userID)
		return
	}
	// Saves the contact like any sync.
	c.handleTable(resp)
	cs := newChangeSet()
	for _, threadID := range c.store.ThreadsWithParticipant(userID) {
		cs.thread(threadID)
	}
	// 1:1 chats are keyed by the other person's ID.
	if c.store.GetThread(userID) != nil {
		cs.thread(userID)
	}
	c.log.Info().Str("user_id", userID).Int("contacts", len(resp.LSDeleteThenInsertContact)).
		Int("chats", len(cs.threads)).Msg("Looked up a name")
	c.flush(cs)
}
