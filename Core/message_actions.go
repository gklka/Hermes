package main

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waConsumerApplication"
	waTypes "go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"

	"go.mau.fi/mautrix-meta/pkg/messagix/socket"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
)

// MARK: - Reacting to, unsending and editing messages

// changeTarget is a message to react to, unsend or edit, in its chat.
type changeTarget struct {
	thread  *threadRow
	message *messageRow
}

func (c *Core) changeTarget(threadID, messageID string) (changeTarget, error) {
	t, err := c.thread(threadID)
	if err != nil {
		return changeTarget{}, err
	}
	m := c.store.GetMessage(messageID)
	if m == nil {
		return changeTarget{}, fmt.Errorf("unknown message %s", messageID)
	}
	return changeTarget{thread: t, message: m}, nil
}

// encrypted tells whether the change goes over the encrypted connection (an encrypted chat's
// unencrypted past goes over the Facebook one).
func (target changeTarget) encrypted() bool {
	return target.thread.Type.IsWhatsApp() && target.message.WAChat != ""
}

// waKey names the message on the encrypted connection.
func (target changeTarget) waKey(selfID string) *waCommon.MessageKey {
	m := target.message
	key := &waCommon.MessageKey{RemoteJID: proto.String(m.WAChat), ID: proto.String(m.ID)}
	if m.SenderID == selfID {
		key.FromMe = proto.Bool(true)
	}
	if chat, err := waTypes.ParseJID(m.WAChat); err == nil &&
		chat.Server != waTypes.MessengerServer && chat.Server != waTypes.DefaultUserServer {
		key.Participant = proto.String(m.WASender)
	}
	return key
}

// sendE2EEChange sends a change to an existing message over the encrypted connection.
func (c *Core) sendE2EEChange(ctx context.Context, target changeTarget, msg *waConsumerApplication.ConsumerApplication) error {
	e2ee, err := c.requireE2EE()
	if err != nil {
		return err
	}
	_, err = e2ee.SendFBMessage(ctx, target.thread.chatJID(), msg, nil)
	return err
}

// react sets (or with "" removes) your reaction to the message.
func (c *Core) react(ctx context.Context, threadID, messageID, emoji string) error {
	target, err := c.changeTarget(threadID, messageID)
	if err != nil {
		return err
	}
	self := c.selfID()
	if target.encrypted() {
		msg := consumerMessage(&waConsumerApplication.ConsumerApplication_Content{
			Content: &waConsumerApplication.ConsumerApplication_Content_ReactionMessage{
				ReactionMessage: &waConsumerApplication.ConsumerApplication_ReactionMessage{
					Key:               target.waKey(self),
					Text:              proto.String(emoji),
					SenderTimestampMS: proto.Int64(time.Now().UnixMilli()),
				},
			},
		})
		if err := c.sendE2EEChange(ctx, target, msg); err != nil {
			return err
		}
		c.store.SetReaction(messageID, self, emoji)
		c.emitMessage(messageID)
		return nil
	}

	cli, err := c.requireClient()
	if err != nil {
		return err
	}
	actor, _ := strconv.ParseInt(self, 10, 64)
	resp, err := cli.ExecuteTasks(ctx, &socket.SendReactionTask{
		ThreadKey:       c.fbThreadKey(threadID),
		MessageID:       messageID,
		ActorID:         actor,
		Reaction:        emoji,
		SyncGroup:       syncGroupMain,
		SendAttribution: table.MESSENGER_INBOX_IN_THREAD,
	})
	if err != nil {
		return err
	}
	// The response has the reaction, which stores it.
	c.handleTable(resp)
	return nil
}

// unsend removes one of your messages for everyone.
func (c *Core) unsend(ctx context.Context, threadID, messageID string) error {
	target, err := c.changeTarget(threadID, messageID)
	if err != nil {
		return err
	}
	if target.encrypted() {
		msg := &waConsumerApplication.ConsumerApplication{
			Payload: &waConsumerApplication.ConsumerApplication_Payload{
				Payload: &waConsumerApplication.ConsumerApplication_Payload_ApplicationData{
					ApplicationData: &waConsumerApplication.ConsumerApplication_ApplicationData{
						ApplicationContent: &waConsumerApplication.ConsumerApplication_ApplicationData_Revoke{
							Revoke: &waConsumerApplication.ConsumerApplication_RevokeMessage{Key: target.waKey(c.selfID())},
						},
					},
				},
			},
		}
		if err := c.sendE2EEChange(ctx, target, msg); err != nil {
			return err
		}
	} else {
		cli, err := c.requireClient()
		if err != nil {
			return err
		}
		resp, err := cli.ExecuteTasks(ctx, &socket.DeleteMessageTask{MessageId: messageID})
		if err != nil {
			return err
		}
		c.handleTable(resp)
	}
	cs := newChangeSet()
	c.applyUnsend(cs, messageID)
	c.flush(cs)
	return nil
}

// editMessage changes the text of one of our sent messages (Messenger allows this for 15 minutes).
func (c *Core) editMessage(ctx context.Context, threadID, messageID, text string) error {
	target, err := c.changeTarget(threadID, messageID)
	if err != nil {
		return err
	}
	if target.encrypted() {
		msg := consumerMessage(&waConsumerApplication.ConsumerApplication_Content{
			Content: &waConsumerApplication.ConsumerApplication_Content_EditMessage{
				EditMessage: &waConsumerApplication.ConsumerApplication_EditMessage{
					Key:         target.waKey(c.selfID()),
					Message:     &waCommon.MessageText{Text: proto.String(text)},
					TimestampMS: proto.Int64(time.Now().UnixMilli()),
				},
			},
		})
		if err := c.sendE2EEChange(ctx, target, msg); err != nil {
			return err
		}
	} else {
		cli, err := c.requireClient()
		if err != nil {
			return err
		}
		resp, err := cli.ExecuteTasks(ctx, &socket.EditMessageTask{MessageID: messageID, Text: text})
		if err != nil {
			return err
		}
		// The server answers with the message's current text; a different one means it refused
		// (e.g. too late to edit).
		for _, edit := range resp.LSEditMessage {
			if edit.MessageID == messageID && edit.Text != text {
				return errors.New("Messenger didn't accept the edit")
			}
		}
	}
	cs := newChangeSet()
	c.applyEdit(cs, messageID, text)
	c.flush(cs)
	return nil
}
