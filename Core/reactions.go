package main

// MARK: - Reactions

// setReaction stores a reaction (from the sync or an encrypted chat). Someone else's new
// reaction to one of your messages is also sent as a "reaction" event, for a notification;
// one already stored (e.g. synced again after reconnecting) isn't.
func (c *Core) setReaction(messageID, actorID, emoji string, ts int64) {
	previous := c.store.Reaction(messageID, actorID)
	c.store.SetReaction(messageID, actorID, emoji)
	self := c.selfID()
	if emoji == "" || emoji == previous || actorID == self {
		return
	}
	m := c.store.GetMessage(messageID)
	if m == nil || m.SenderID != self {
		return
	}
	emitEvent("reaction", apiReactionEvent{
		ThreadID:    m.ThreadID,
		MessageID:   messageID,
		SenderID:    actorID,
		Emoji:       emoji,
		Timestamp:   ts,
		MessageText: m.Text,
	})
}
