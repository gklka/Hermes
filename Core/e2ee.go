package main

import (
	"context"
	"fmt"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waArmadilloApplication"
	"go.mau.fi/whatsmeow/proto/waConsumerApplication"
	"go.mau.fi/whatsmeow/proto/waMediaTransport"
	waTypes "go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"

	"go.mau.fi/mautrix-meta/pkg/messagix/table"
)

// handleWAEvent handles events from the end-to-end encrypted (WhatsApp-protocol) connection.
func (c *Core) handleWAEvent(rawEvt any) bool {
	switch evt := rawEvt.(type) {
	case *events.FBMessage:
		c.handleFBMessage(evt)
	case *events.Receipt:
		c.handleReceipt(evt)
	case *events.ChatPresence:
		emitEvent("typing", map[string]any{
			"threadID": evt.Chat.User,
			"senderID": evt.Sender.User,
			"isTyping": evt.State == waTypes.ChatPresenceComposing,
		})
	case *events.Presence:
		c.log.Debug().Str("user", evt.From.User).Bool("unavailable", evt.Unavailable).Time("last_seen", evt.LastSeen).Msg("Presence")
		var lastSeen int64
		if !evt.LastSeen.IsZero() {
			lastSeen = evt.LastSeen.UnixMilli()
		}
		emitEvent("presence", map[string]any{
			"userID":   evt.From.User,
			"isOnline": !evt.Unavailable,
			"lastSeen": lastSeen,
		})
	case *events.Connected:
		c.log.Info().Msg("E2EE connected")
		if cli := c.e2eeClient(); cli != nil {
			// WhatsApp only delivers typing notifications while we're "available".
			go func() { _ = cli.SendPresence(context.Background(), waTypes.PresenceAvailable) }()
		}
	case *events.CATRefreshError:
		c.log.Err(evt.Error).Msg("E2EE crypto auth token refresh failed")
	case *events.LoggedOut:
		c.log.Warn().Str("reason", evt.PermanentDisconnectDescription()).Msg("E2EE device logged out, re-registering")
		c.resetE2EE()
	case *events.ConnectFailure:
		c.log.Warn().Int("reason", int(evt.Reason)).Str("message", evt.Message).Msg("E2EE connect failure")
		if evt.Reason == events.ConnectFailureNotFound || evt.Reason == events.ConnectFailureClientUnknown {
			c.resetE2EE()
		}
	default:
		c.log.Debug().Str("type", fmt.Sprintf("%T", rawEvt)).Msg("Unhandled E2EE event")
	}
	return true
}

func (c *Core) handleFBMessage(evt *events.FBMessage) {
	chat := evt.Info.Chat
	threadID := chat.User
	threadType := table.ENCRYPTED_OVER_WA_ONE_TO_ONE
	if chat.Server == waTypes.GroupServer {
		threadType = table.ENCRYPTED_OVER_WA_GROUP
	}
	c.store.EnsureThread(threadID, threadType, "inbox")
	if t := c.store.GetThread(threadID); t != nil && !t.Type.IsWhatsApp() {
		c.store.SetThreadType(threadID, threadType)
	}

	sender := evt.Info.Sender.ToNonAD()
	senderID := sender.User
	ts := evt.Info.Timestamp.UnixMilli()
	cs := newChangeSet()
	row := &messageRow{
		ID:        evt.Info.ID,
		ThreadID:  threadID,
		SenderID:  senderID,
		Timestamp: ts,
		WAChat:    chat.String(),
		WASender:  sender.String(),
	}

	switch msg := evt.Message.(type) {
	case *waConsumerApplication.ConsumerApplication:
		payload := msg.GetPayload()
		if revoke := payload.GetApplicationData().GetRevoke(); revoke != nil {
			target := revoke.GetKey().GetID()
			c.store.UnsendMessage(target)
			cs.message(target)
			c.flush(cs)
			return
		}
		content := payload.GetContent()
		if reaction := content.GetReactionMessage(); reaction != nil {
			target := reaction.GetKey().GetID()
			c.store.SetReaction(target, senderID, reaction.GetText())
			cs.message(target)
			c.flush(cs)
			return
		}
		if edit := content.GetEditMessage(); edit != nil {
			target := edit.GetKey().GetID()
			c.store.EditMessage(target, edit.GetMessage().GetText())
			cs.message(target)
			c.flush(cs)
			return
		}
		if !fillConsumerContent(row, content) {
			c.log.Debug().Str("message_id", row.ID).Msg("Unsupported E2EE consumer message")
			row.Text = "Unsupported message, view it in the Messenger app"
			row.IsSystem = true
		}
	case *waArmadilloApplication.Armadillo:
		content := msg.GetPayload().GetContent()
		if x := content.GetExtendedContentMessage(); x != nil {
			row.Text = x.GetMessageText()
			if title := x.GetTitleText(); title != "" {
				link := storedAttachment{apiAttachment: apiAttachment{ID: row.ID + "-xma", Kind: kindLink, Title: title}}
				if ctas := x.GetCtas(); len(ctas) > 0 {
					link.URL = firstNonEmpty(ctas[0].GetActionURL(), ctas[0].GetNativeURL())
				}
				row.Attachments = append(row.Attachments, link)
			}
		} else {
			row.Text = "Unsupported message, view it in the Messenger app"
			row.IsSystem = true
		}
	default:
		return
	}

	if quoted := evt.FBApplication.GetMetadata().GetQuotedMessage(); quoted != nil && quoted.GetStanzaID() != "" {
		reply := &apiReply{MessageID: quoted.GetStanzaID()}
		if target := c.store.GetMessage(reply.MessageID); target != nil {
			reply.Text = target.Text
			reply.SenderID = target.SenderID
		} else if jid, err := waTypes.ParseJID(quoted.GetParticipant()); err == nil {
			reply.SenderID = jid.User
		}
		row.ReplyTo = reply
	}

	c.store.PutMessage(row)
	c.store.BumpThread(threadID, ts, snippetFor(row.Text, len(row.Attachments) > 0), senderID)
	cs.message(row.ID)
	cs.thread(threadID)
	c.flush(cs)
}

// fillConsumerContent converts the message body; returns false for unsupported content.
func fillConsumerContent(row *messageRow, content *waConsumerApplication.ConsumerApplication_Content) bool {
	attachmentID := func() string { return fmt.Sprintf("%s-%d", row.ID, len(row.Attachments)) }
	switch {
	case content.GetMessageText() != nil:
		row.Text = content.GetMessageText().GetText()
	case content.GetExtendedTextMessage() != nil:
		ext := content.GetExtendedTextMessage()
		row.Text = ext.GetText().GetText()
		if url := firstNonEmpty(ext.GetCanonicalURL(), ext.GetMatchedText()); url != "" && ext.GetTitle() != "" {
			row.Attachments = append(row.Attachments, storedAttachment{apiAttachment: apiAttachment{
				ID: attachmentID(), Kind: kindLink, URL: url, Title: ext.GetTitle(),
			}})
		}
	case content.GetImageMessage() != nil:
		img := content.GetImageMessage()
		transport, err := img.Decode()
		if err != nil {
			return false
		}
		a := waAttachment(attachmentID(), kindImage, transport.GetIntegral().GetTransport(), whatsmeow.MediaImage)
		a.Width, a.Height = int(transport.GetAncillary().GetWidth()), int(transport.GetAncillary().GetHeight())
		row.Attachments = append(row.Attachments, a)
		row.Text = img.GetCaption().GetText()
	case content.GetVideoMessage() != nil:
		video := content.GetVideoMessage()
		transport, err := video.Decode()
		if err != nil {
			return false
		}
		kind := kindVideo
		if transport.GetAncillary().GetGifPlayback() {
			kind = kindGIF
		}
		a := waAttachment(attachmentID(), kind, transport.GetIntegral().GetTransport(), whatsmeow.MediaVideo)
		a.Width, a.Height = int(transport.GetAncillary().GetWidth()), int(transport.GetAncillary().GetHeight())
		row.Attachments = append(row.Attachments, a)
		row.Text = video.GetCaption().GetText()
	case content.GetAudioMessage() != nil:
		transport, err := content.GetAudioMessage().Decode()
		if err != nil {
			return false
		}
		row.Attachments = append(row.Attachments, waAttachment(attachmentID(), kindAudio, transport.GetIntegral().GetTransport(), whatsmeow.MediaAudio))
	case content.GetDocumentMessage() != nil:
		doc := content.GetDocumentMessage()
		transport, err := doc.Decode()
		if err != nil {
			return false
		}
		a := waAttachment(attachmentID(), kindFile, transport.GetIntegral().GetTransport(), whatsmeow.MediaDocument)
		a.Filename = doc.GetFileName()
		row.Attachments = append(row.Attachments, a)
	case content.GetStickerMessage() != nil:
		transport, err := content.GetStickerMessage().Decode()
		if err != nil {
			return false
		}
		a := waAttachment(attachmentID(), kindSticker, transport.GetIntegral().GetTransport(), whatsmeow.MediaImage)
		a.Width, a.Height = int(transport.GetAncillary().GetWidth()), int(transport.GetAncillary().GetHeight())
		row.Attachments = append(row.Attachments, a)
	case content.GetViewOnceMessage() != nil:
		row.Text = "View-once media, open it in the Messenger app"
		row.IsSystem = true
	case content.GetLocationMessage() != nil:
		row.Text = "📍 " + firstNonEmpty(content.GetLocationMessage().GetAddress(), "Shared a location")
	default:
		return false
	}
	return true
}

func waAttachment(id, kind string, t *waMediaTransport.WAMediaTransport, mediaType whatsmeow.MediaType) storedAttachment {
	integral := t.GetIntegral()
	return storedAttachment{
		apiAttachment: apiAttachment{ID: id, Kind: kind, MimeType: t.GetAncillary().GetMimetype()},
		WA: &waMediaInfo{
			MediaType:  string(mediaType),
			Key:        integral.GetMediaKey(),
			SHA256:     integral.GetFileSHA256(),
			EncSHA256:  integral.GetFileEncSHA256(),
			DirectPath: integral.GetDirectPath(),
		},
	}
}

func (c *Core) handleReceipt(evt *events.Receipt) {
	threadID := evt.Chat.User
	ts := evt.Timestamp.UnixMilli()
	switch evt.Type {
	case waTypes.ReceiptTypeRead:
		if evt.IsFromMe {
			c.markThreadReadLocally(threadID, ts)
			return
		}
		reader := evt.Sender.User
		c.store.SetReadWatermark(threadID, reader, ts)
		emitEvent("readReceipt", map[string]any{"threadID": threadID, "readerID": reader, "timestamp": ts})
	case waTypes.ReceiptTypeReadSelf:
		c.markThreadReadLocally(threadID, ts)
	}
}

func (c *Core) markThreadReadLocally(threadID string, ts int64) {
	c.store.SetThreadLastRead(threadID, ts)
	c.store.Delete("unread:" + threadID)
	cs := newChangeSet()
	cs.thread(threadID)
	c.flush(cs)
}
