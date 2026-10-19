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
func (c *Core) handleWAEvent(rawEvt any) {
	switch evt := rawEvt.(type) {
	case *events.FBMessage:
		c.handleFBMessage(evt)
	case *events.Receipt:
		c.handleReceipt(evt)
	case *events.ChatPresence:
		emitEvent("typing", apiTypingEvent{
			ThreadID: evt.Chat.User,
			SenderID: evt.Sender.User,
			IsTyping: evt.State == waTypes.ChatPresenceComposing,
		})
	case *events.Presence:
		var lastSeen int64
		if !evt.LastSeen.IsZero() {
			lastSeen = evt.LastSeen.UnixMilli()
		}
		emitEvent("presence", apiPresenceEvent{UserID: evt.From.User, IsOnline: !evt.Unavailable, LastSeen: lastSeen})
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
}

// unsupportedText stands in for an encrypted message this app can't show.
const unsupportedText = "Unsupported message, view it in the Messenger app"

// handleFBMessage stores a message from an encrypted chat, or applies the change it carries
// (an unsend, a reaction or an edit).
func (c *Core) handleFBMessage(evt *events.FBMessage) {
	chat := evt.Info.Chat
	threadID := chat.User
	threadType := table.ENCRYPTED_OVER_WA_ONE_TO_ONE
	if chat.Server == waTypes.GroupServer {
		threadType = table.ENCRYPTED_OVER_WA_GROUP
	}
	c.store.EnsureThread(threadID, threadType, folderInbox)
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
		content := payload.GetContent()
		switch {
		case payload.GetApplicationData().GetRevoke() != nil:
			c.applyUnsend(cs, payload.GetApplicationData().GetRevoke().GetKey().GetID())
			c.flush(cs)
			return
		case content.GetReactionMessage() != nil:
			reaction := content.GetReactionMessage()
			target := reaction.GetKey().GetID()
			c.setReaction(target, senderID, reaction.GetText(), ts)
			c.emitMessage(target)
			return
		case content.GetEditMessage() != nil:
			edit := content.GetEditMessage()
			c.applyEdit(cs, edit.GetKey().GetID(), edit.GetMessage().GetText())
			c.flush(cs)
			return
		}
		if !fillConsumerContent(row, content) {
			c.log.Debug().Str("message_id", row.ID).Msg("Unsupported E2EE consumer message")
			row.Text = unsupportedText
			row.IsSystem = true
		}
	case *waArmadilloApplication.Armadillo:
		content := msg.GetPayload().GetContent()
		if x := content.GetExtendedContentMessage(); x != nil {
			row.Text = x.GetMessageText()
			if title := firstNonEmpty(x.GetTitleText(), x.GetSubtitleText()); title != "" {
				subtitle := x.GetOverlayDescription()
				if subtitle == "" && x.GetTitleText() != "" {
					subtitle = x.GetSubtitleText() // not already used as the title
				}
				link := storedAttachment{apiAttachment: apiAttachment{
					ID: row.ID + "-xma", Kind: kindLink, Title: title,
					Subtitle: subtitle, Source: x.GetTargetUsername(),
				}}
				if ctas := x.GetCtas(); len(ctas) > 0 {
					link.URL = firstNonEmpty(ctas[0].GetActionURL(), ctas[0].GetNativeURL())
				}
				row.Attachments = append(row.Attachments, link)
			}
		} else {
			row.Text = unsupportedText
			row.IsSystem = true
		}
	default:
		return
	}

	if quoted := evt.FBApplication.GetMetadata().GetQuotedMessage(); quoted != nil && quoted.GetStanzaID() != "" {
		row.ReplyTo = c.replyPreview(quoted.GetStanzaID())
		if jid, err := waTypes.ParseJID(quoted.GetParticipant()); err == nil && row.ReplyTo.SenderID == "" {
			row.ReplyTo.SenderID = jid.User
		}
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

// handleReceipt stores a read receipt from an encrypted chat: someone else's, or ours from
// another device.
func (c *Core) handleReceipt(evt *events.Receipt) {
	threadID := evt.Chat.User
	ts := evt.Timestamp.UnixMilli()
	switch {
	case evt.Type == waTypes.ReceiptTypeRead && !evt.IsFromMe:
		reader := evt.Sender.User
		c.store.SetReadWatermark(threadID, reader, ts)
		emitEvent("readReceipt", apiReadReceiptEvent{ThreadID: threadID, ReaderID: reader, Timestamp: ts})
	case evt.Type == waTypes.ReceiptTypeRead, evt.Type == waTypes.ReceiptTypeReadSelf:
		c.log.Debug().Str("thread", threadID).Int64("ts", ts).Msg("Read on another device (E2EE receipt)")
		c.markThreadReadLocally(threadID, ts)
	}
}
