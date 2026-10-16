package main

import (
	"encoding/xml"
	"strings"

	"github.com/rs/zerolog"
)

// MARK: - Calls in encrypted chats

// Calls in encrypted chats come as "fb:call" notifications on the encrypted (WhatsApp)
// connection: one when a call starts, then one when it ends or is missed (its parent_id is the
// first one's ID). whatsmeow doesn't handle them or offer a hook for unknown notifications, but
// it logs every node it receives, so this hook on the logger it gets picks them out.
type callNotificationHook struct{ c *Core }

func (h callNotificationHook) Run(_ *zerolog.Event, level zerolog.Level, msg string) {
	if level == zerolog.DebugLevel && strings.HasPrefix(msg, "<notification ") && strings.Contains(msg, `type="fb:call"`) {
		h.c.handleCallNotification(msg)
	}
}

type callNotification struct {
	ID    string `xml:"id,attr"`
	Event struct {
		CallType string `xml:"call_type,attr"` // "voice" or "video"
		Duration int    `xml:"duration,attr"`  // seconds
		Actor    string `xml:"event_actor_id,attr"`
		Time     int64  `xml:"event_time,attr"` // milliseconds
		Type     string `xml:"event_type,attr"` // "started", "ended", "missed", …
		JID      string `xml:"jid,attr"`        // the chat
		ParentID string `xml:"parent_id,attr"`
	} `xml:"call_event"`
}

// handleCallNotification stores the call as a message (its ID is the starting notification's),
// and updates it when the call ends.
func (c *Core) handleCallNotification(node string) {
	var n callNotification
	if err := xml.Unmarshal([]byte(node), &n); err != nil || n.Event.JID == "" {
		c.log.Debug().Err(err).Msg("Unreadable call notification")
		return
	}
	e := n.Event
	user := func(jid string) string { return strings.SplitN(jid, "@", 2)[0] }
	threadID := user(e.JID)
	// Regular chats have their own call log cards (callFromXMA).
	if t := c.store.GetThread(threadID); t == nil || !t.Type.IsWhatsApp() {
		return
	}
	callID := firstNonEmpty(e.ParentID, n.ID)
	messageID := "call." + callID
	outcome := e.Type
	if outcome != callStarted && outcome != callEnded && outcome != callMissed {
		// e.g. a declined call: shown like a missed one.
		c.log.Debug().Str("event_type", e.Type).Msg("Unknown call event type")
		outcome = callMissed
	}
	call := &apiCall{IsVideo: e.CallType == "video", Outcome: outcome, Duration: e.Duration}
	row := c.store.GetMessage(messageID)
	if row == nil {
		ts := e.Time
		if e.ParentID != "" {
			// The start wasn't seen: it was this long before the end.
			ts -= int64(e.Duration) * 1000
		}
		row = &messageRow{ID: messageID, ThreadID: threadID, SenderID: user(e.Actor), Timestamp: ts}
	} else if e.Type == callStarted {
		return
	}
	row.Attachments = []storedAttachment{{apiAttachment: apiAttachment{ID: messageID, Kind: kindCall, Call: call}}}
	c.store.PutMessage(row)
	c.log.Info().Str("thread_id", threadID).Str("call", callID).Str("outcome", outcome).Int("duration", e.Duration).Msg("Call")

	snippet := "Audio call"
	if call.IsVideo {
		snippet = "Video call"
	}
	if outcome == callMissed {
		snippet = "Missed " + strings.ToLower(snippet)
	}
	c.store.BumpThread(threadID, row.Timestamp, snippet, row.SenderID)
	cs := newChangeSet()
	cs.message(messageID)
	cs.thread(threadID)
	c.flush(cs)
}
