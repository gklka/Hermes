package main

// JSON shapes shared with the Swift app (App/Core/Models.swift). Keep in sync.

type apiAccount struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	AvatarURL string `json:"avatarURL,omitempty"`
}

type apiParticipant struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	AvatarURL     string `json:"avatarURL,omitempty"`
	ReadWatermark int64  `json:"readWatermark,omitempty"`
	// Detail is what Messenger's people search says about someone ("Friends", a mutual friend).
	Detail string `json:"detail,omitempty"`
}

type apiConversation struct {
	ID              string           `json:"id"`
	Name            string           `json:"name"`
	AvatarURL       string           `json:"avatarURL,omitempty"`
	Snippet         string           `json:"snippet"`
	SnippetSenderID string           `json:"snippetSenderID,omitempty"`
	LastActivity    int64            `json:"lastActivity"`
	UnreadCount     int              `json:"unreadCount"`
	IsGroup         bool             `json:"isGroup"`
	IsEncrypted     bool             `json:"isEncrypted"`
	IsMuted         bool             `json:"isMuted"`
	IsMarketplace   bool             `json:"isMarketplace"`
	Participants    []apiParticipant `json:"participants"`
	// The chat's custom Messenger theme for outgoing bubbles: one CSS color, or several for a
	// gradient (top to bottom of the visible chat). Empty for the default theme.
	BubbleColors []string `json:"bubbleColors,omitempty"`
	// The chat's custom quick reaction emoji (the composer's like button). Empty for the default like.
	QuickEmoji string `json:"quickEmoji,omitempty"`
	// SnippetUnsent: the latest message was unsent by SnippetSenderID (so there's no snippet text).
	SnippetUnsent bool `json:"snippetUnsent,omitempty"`
}

type apiReaction struct {
	SenderID string `json:"senderID"`
	Emoji    string `json:"emoji"`
}

type apiReply struct {
	MessageID string `json:"messageID"`
	SenderID  string `json:"senderID,omitempty"`
	Text      string `json:"text"`
}

// Attachment kinds understood by the app.
const (
	kindImage   = "image"
	kindGIF     = "gif"
	kindVideo   = "video"
	kindAudio   = "audio"
	kindSticker = "sticker"
	kindFile    = "file"
	kindLink    = "link"
)

type apiAttachment struct {
	ID         string `json:"id"`
	Kind       string `json:"kind"`
	URL        string `json:"url,omitempty"`
	PreviewURL string `json:"previewURL,omitempty"`
	LocalPath  string `json:"localPath,omitempty"`
	Width      int    `json:"width,omitempty"`
	Height     int    `json:"height,omitempty"`
	Filename   string `json:"filename,omitempty"`
	MimeType   string `json:"mimeType,omitempty"`
	Title      string `json:"title,omitempty"`
}

// Message statuses. ("failed" is set by the app, when a send request fails.)
const (
	statusPending = "pending"
	statusSent    = "sent"
)

type apiMessage struct {
	ID          string          `json:"id"`
	ThreadID    string          `json:"threadID"`
	SenderID    string          `json:"senderID"`
	IsFromMe    bool            `json:"isFromMe"`
	IsSystem    bool            `json:"isSystem"`
	Text        string          `json:"text"`
	Timestamp   int64           `json:"timestamp"`
	Attachments []apiAttachment `json:"attachments"`
	ReplyTo     *apiReply       `json:"replyTo,omitempty"`
	Reactions   []apiReaction   `json:"reactions"`
	Status      string          `json:"status"`
	IsUnsent    bool            `json:"isUnsent"`
	IsEdited    bool            `json:"isEdited"`
	PendingID   string          `json:"pendingID,omitempty"`
	// Earlier versions of an edited message (oldest first), as far as this app saw them.
	PreviousTexts []string `json:"previousTexts,omitempty"`
}

// apiReactionEvent is someone else reacting to one of your messages (the "reaction" event),
// for a notification.
type apiReactionEvent struct {
	ThreadID    string `json:"threadID"`
	MessageID   string `json:"messageID"`
	SenderID    string `json:"senderID"`
	Emoji       string `json:"emoji"`
	Timestamp   int64  `json:"timestamp"`
	MessageText string `json:"messageText"`
}

// apiThreadReadEvent is the chat being read up to Timestamp, here or on another device (the
// "threadRead" event), to remove notifications seen elsewhere.
type apiThreadReadEvent struct {
	ThreadID  string `json:"threadID"`
	Timestamp int64  `json:"timestamp"`
}

// apiThreadRemovedEvent is a chat leaving the list (deleted, or moved to requests/spam).
type apiThreadRemovedEvent struct {
	ThreadID string `json:"threadID"`
}

// apiMessageRemovedEvent is a message deleted for everyone (not unsent: that's an update).
type apiMessageRemovedEvent struct {
	ThreadID  string `json:"threadID"`
	MessageID string `json:"messageID"`
}

// apiPendingResolvedEvent is the outcome of a send: the local echo PendingID became the
// message MessageID, or failed with Error.
type apiPendingResolvedEvent struct {
	ThreadID  string `json:"threadID"`
	PendingID string `json:"pendingID"`
	MessageID string `json:"messageID,omitempty"`
	Error     string `json:"error,omitempty"`
}

type apiTypingEvent struct {
	ThreadID string `json:"threadID"`
	SenderID string `json:"senderID"`
	IsTyping bool   `json:"isTyping"`
}

// apiPresenceEvent is a 1:1 contact's online status; LastSeen is 0 if they hide it.
type apiPresenceEvent struct {
	UserID   string `json:"userID"`
	IsOnline bool   `json:"isOnline"`
	LastSeen int64  `json:"lastSeen"`
}

// apiReadReceiptEvent is someone else reading the chat up to Timestamp.
type apiReadReceiptEvent struct {
	ThreadID  string `json:"threadID"`
	ReaderID  string `json:"readerID"`
	Timestamp int64  `json:"timestamp"`
}

// apiMessagesPage is a page of a chat's messages (messages.list, .stored and .search), oldest
// first; HasMore: there's more before it (in the database or on Messenger).
type apiMessagesPage struct {
	Messages []apiMessage `json:"messages"`
	HasMore  bool         `json:"hasMore"`
}

// apiFetchOlderResult is messages.fetchOlder's result: how many messages one page of history
// added, and whether Messenger has more.
type apiFetchOlderResult struct {
	Fetched int  `json:"fetched"`
	HasMore bool `json:"hasMore"`
}

type apiState struct {
	State   string      `json:"state"`
	Account *apiAccount `json:"account,omitempty"`
	Error   string      `json:"error,omitempty"`
}

// apiThreadImportResult is web.importThreads' result: how many chats were stored, and the web
// IDs of those whose user couldn't be determined (the app opens them to find out).
type apiThreadImportResult struct {
	Imported   int      `json:"imported"`
	Unresolved []string `json:"unresolved"`
}

// apiMessageImportResult is web.importMessages' result: how many messages were stored, and
// how many the web app couldn't decrypt yet (the history isn't restored with the PIN).
type apiMessageImportResult struct {
	Imported   int `json:"imported"`
	Unrestored int `json:"unrestored"`
}

// Connection states.
const (
	stateLoggedOut    = "loggedOut"
	stateConnecting   = "connecting"
	stateConnected    = "connected"
	stateDisconnected = "disconnected"
)
