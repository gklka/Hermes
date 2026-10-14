package main

import "strconv"

// MARK: - Sending changes to the app

// changeSet collects the chats and messages an update touched, so each is sent to the app
// once, in its final state.
type changeSet struct {
	threads  map[string]bool
	messages map[string]string // messageID → pendingID (may be empty)
}

func newChangeSet() *changeSet {
	return &changeSet{threads: map[string]bool{}, messages: map[string]string{}}
}

func (cs *changeSet) thread(id string)  { cs.threads[id] = true }
func (cs *changeSet) message(id string) { cs.messages[id] = cs.messages[id] }

// flush sends the collected chats and messages to the app as they're stored now.
func (c *Core) flush(cs *changeSet) {
	self := c.selfID()
	for id := range cs.threads {
		if t := c.store.GetThread(id); t != nil {
			if t.Visible() {
				conv := c.store.Conversation(t, self)
				emitEvent("thread", conv)
				c.lookUpNames(t, conv)
			} else {
				// Also drops it from the list if it was just moved to requests/spam.
				emitThreadRemoved(id)
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

// emitThread sends one chat to the app as it's stored now.
func (c *Core) emitThread(id string) {
	cs := newChangeSet()
	cs.thread(id)
	c.flush(cs)
}

// emitMessage sends one message to the app as it's stored now.
func (c *Core) emitMessage(id string) {
	cs := newChangeSet()
	cs.message(id)
	c.flush(cs)
}

func emitThreadRemoved(id string) {
	emitEvent("threadRemoved", apiThreadRemovedEvent{ThreadID: id})
}

// removeThread forgets a chat and drops it from the app's list.
func (c *Core) removeThread(id string) {
	c.store.DeleteThread(id)
	emitThreadRemoved(id)
}

// MARK: - Changes from any connection

// applyEdit stores a message's new text (the chat's snippet follows if it's the latest).
func (c *Core) applyEdit(cs *changeSet, messageID, text string) {
	if threadID := c.store.EditMessage(messageID, text); threadID != "" {
		cs.thread(threadID)
	}
	cs.message(messageID)
}

// applyUnsend blanks a message unsent by its sender.
func (c *Core) applyUnsend(cs *changeSet, messageID string) {
	c.store.UnsendMessage(messageID)
	cs.message(messageID)
}

// applyRead records that the chat was read up to ts (here or on another device). It also
// clears "marked unread" if that was set before the read.
func (c *Core) applyRead(cs *changeSet, threadID string, ts int64) {
	c.store.SetThreadLastRead(threadID, ts)
	if marked := c.store.Get(kvUnread + threadID); marked != "" {
		// Older markers are "1" (no time): any read clears them.
		if at, err := strconv.ParseInt(marked, 10, 64); err != nil || at <= ts {
			c.store.Delete(kvUnread + threadID)
		}
	}
	cs.thread(threadID)
	emitEvent("threadRead", apiThreadReadEvent{ThreadID: threadID, Timestamp: ts})
}

func (c *Core) markThreadReadLocally(threadID string, ts int64) {
	cs := newChangeSet()
	c.applyRead(cs, threadID, ts)
	c.flush(cs)
}

// MARK: - Pending (optimistic) sends

// pendingSend is a message sent over the Facebook connection that the server hasn't
// confirmed yet, shown in its chat as a local echo.
type pendingSend struct {
	threadID  string
	pendingID string
}

func (c *Core) addPending(otid, threadID, pendingID string) {
	c.pendingLock.Lock()
	c.pending[otid] = pendingSend{threadID: threadID, pendingID: pendingID}
	c.pendingLock.Unlock()
}

// resolvePending tells the app what became of a pending send: the message it became, or why
// it failed (errMsg).
func (c *Core) resolvePending(otid, messageID, errMsg string) {
	c.pendingLock.Lock()
	p, ok := c.pending[otid]
	if ok && errMsg != "" {
		delete(c.pending, otid)
	}
	c.pendingLock.Unlock()
	if ok {
		emitEvent("pendingResolved", apiPendingResolvedEvent{
			ThreadID: p.threadID, PendingID: p.pendingID, MessageID: messageID, Error: errMsg,
		})
	}
}

// failPending tells the app a send failed before it reached the server, and returns the error.
func failPending(threadID, pendingID string, err error) error {
	emitEvent("pendingResolved", apiPendingResolvedEvent{ThreadID: threadID, PendingID: pendingID, Error: err.Error()})
	return err
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
