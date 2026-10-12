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

// Message statuses.
const (
	statusPending = "pending"
	statusSent    = "sent"
	statusFailed  = "failed"
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
}

type apiState struct {
	State   string      `json:"state"`
	Account *apiAccount `json:"account,omitempty"`
	Error   string      `json:"error,omitempty"`
}

// Connection states.
const (
	stateLoggedOut    = "loggedOut"
	stateConnecting   = "connecting"
	stateConnected    = "connected"
	stateDisconnected = "disconnected"
)
