package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"go.mau.fi/mautrix-meta/pkg/messagix/useragent"
)

// MARK: - Requests from the app

type rpcRequest struct {
	ID     int64           `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

// HandleRequest routes one request. Anything that sends to a chat runs on a single
// sequential queue so messages go out in the order they were typed.
func (c *Core) HandleRequest(data []byte) {
	var req rpcRequest
	if err := json.Unmarshal(data, &req); err != nil {
		c.log.Err(err).Msg("Invalid request")
		return
	}
	run := func() {
		defer func() {
			if r := recover(); r != nil {
				c.log.Error().Any("panic", r).Str("method", req.Method).Msg("Request panicked")
				emitResponse(req.ID, nil, fmt.Errorf("internal error: %v", r))
			}
		}()
		result, err := c.dispatch(req)
		if err != nil {
			c.log.Warn().Err(err).Str("method", req.Method).Msg("Request failed")
		}
		emitResponse(req.ID, result, err)
	}
	switch req.Method {
	case "messages.send", "messages.sendMedia", "messages.react", "messages.unsend", "messages.edit":
		c.sendQueue <- run
	default:
		go run()
	}
}

// requestParams are every request's parameters; each request uses the ones it needs.
type requestParams struct {
	ThreadID     string            `json:"threadID"`
	UserID       string            `json:"userID"`
	MessageID    string            `json:"messageID"`
	AttachmentID string            `json:"attachmentID"`
	Text         string            `json:"text"`
	ReplyTo      string            `json:"replyTo"`
	Emoji        string            `json:"emoji"`
	Path         string            `json:"path"`
	IsTyping     bool              `json:"isTyping"`
	Enabled      bool              `json:"enabled"`
	Before       int64             `json:"before"`
	Limit        int               `json:"limit"`
	Cookies      map[string]string `json:"cookies"`

	// What the app read from Messenger's web app (the web.* requests).
	Rows     []webThreadRow `json:"rows"`
	Messages []webMessage   `json:"messages"`
	Colors   []string       `json:"colors"`
}

func (c *Core) dispatch(req rpcRequest) (any, error) {
	if c.store == nil {
		return nil, errors.New("core failed to start")
	}
	var p requestParams
	if len(req.Params) > 0 {
		if err := json.Unmarshal(req.Params, &p); err != nil {
			return nil, fmt.Errorf("invalid params: %w", err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	switch req.Method {
	// Session
	case "log":
		c.log.Info().Str("source", "app").Msg(p.Text)
		return nil, nil
	case "userAgent":
		return map[string]string{"userAgent": useragent.UserAgent}, nil
	case "login":
		return nil, c.Login(ctx, p.Cookies)
	case "logout":
		c.Logout(ctx)
		return nil, nil
	case "session.cookies":
		return c.sessionCookies()

	// What the app read from the web app
	case "web.importThreads":
		return c.importWebThreads(p.Rows), nil
	case "web.importMessages":
		return c.importWebMessages(p.ThreadID, p.Messages), nil
	case "web.setThreadTheme":
		c.setThreadTheme(p.ThreadID, p.Colors, p.Emoji)
		return nil, nil
	case "web.threadWebID":
		return map[string]string{"webID": c.webThreadID(p.ThreadID)}, nil
	case "web.threadPath":
		return map[string]string{"path": c.webThreadPath(p.ThreadID)}, nil
	case "web.oldestEncrypted":
		return map[string]int64{"timestamp": c.store.OldestEncryptedMessage(p.ThreadID)}, nil

	// Chats
	case "threads.list":
		return c.listThreads(), nil
	case "threads.loadMore":
		return nil, c.loadMoreThreads(ctx)
	case "threads.open":
		return c.openDirectThread(p.UserID)
	case "threads.resync":
		return nil, c.resyncThread(p.ThreadID)
	case "threads.markRead":
		return nil, c.markRead(ctx, p.ThreadID)
	case "threads.setUnread":
		return nil, c.setUnread(ctx, p.ThreadID, p.Enabled)
	case "threads.typing":
		return nil, c.sendTyping(ctx, p.ThreadID, p.IsTyping)
	case "threads.mute":
		return nil, c.muteThread(ctx, p.ThreadID, p.Enabled)
	case "threads.delete":
		return nil, c.deleteThread(ctx, p.ThreadID)
	case "threads.leave":
		return nil, c.leaveThread(ctx, p.ThreadID)
	case "threads.refreshTheme":
		return nil, c.refreshTheme(ctx, p.ThreadID)
	case "threads.subscribePresence":
		return nil, c.subscribePresence(ctx, p.ThreadID)
	case "users.block":
		return nil, c.blockUser(ctx, p.UserID)
	case "contacts.search":
		return c.store.SearchContacts(p.Text, c.selfID(), 50), nil
	case "contacts.searchPeople":
		return c.searchPeople(ctx, p.Text)

	// Messages
	case "messages.list":
		return c.listMessages(p.ThreadID, p.Before, p.Limit), nil
	case "messages.stored":
		// The newest stored messages, without fetching history (for the Spotlight index).
		return c.messagesPage(c.store.ListMessages(p.ThreadID, p.Before, p.Limit), false), nil
	case "messages.search":
		return c.searchMessages(p.ThreadID, p.Text, p.Limit), nil
	case "messages.fetchOlder":
		return c.fetchOlder(p.ThreadID), nil
	case "messages.send":
		return nil, c.sendText(ctx, p.ThreadID, p.Text, p.ReplyTo)
	case "messages.sendMedia":
		return nil, c.sendMedia(ctx, p.ThreadID, p.Path)
	case "messages.react":
		return nil, c.react(ctx, p.ThreadID, p.MessageID, p.Emoji)
	case "messages.unsend":
		return nil, c.unsend(ctx, p.ThreadID, p.MessageID)
	case "messages.edit":
		return nil, c.editMessage(ctx, p.ThreadID, p.MessageID, p.Text)
	case "media.download":
		path, err := c.downloadMedia(ctx, p.MessageID, p.AttachmentID)
		if err != nil {
			return nil, err
		}
		return map[string]string{"path": path}, nil
	default:
		return nil, fmt.Errorf("unknown method %q", req.Method)
	}
}

// sessionCookies lets the app's hidden web view share this session (to read encrypted chats
// from the web app).
func (c *Core) sessionCookies() (map[string]string, error) {
	ck := c.currentCookies()
	if ck == nil {
		return nil, errors.New("not logged in")
	}
	out := map[string]string{}
	for name, value := range ck.GetAll() {
		out[string(name)] = value
	}
	return out, nil
}
