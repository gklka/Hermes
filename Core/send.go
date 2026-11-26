package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waConsumerApplication"
	"go.mau.fi/whatsmeow/proto/waMediaTransport"
	"go.mau.fi/whatsmeow/proto/waMsgApplication"
	"google.golang.org/protobuf/proto"

	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"go.mau.fi/mautrix-meta/pkg/messagix/methods"
	"go.mau.fi/mautrix-meta/pkg/messagix/socket"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
)

// MARK: - Sending messages

// A sent message shows up in its chat right away as a local echo (status pending, ID
// pendingID). The server's confirmation replaces it with the real message (flushWithPending
// tags that with the pendingID), or a "pendingResolved" event reports that it failed.

// outgoing identifies a message being sent: its offline threading ID, which the server's
// confirmation names, and its local echo's ID.
type outgoing struct {
	otid      int64
	otidStr   string
	pendingID string
}

func newOutgoing() outgoing {
	otid := methods.GenerateEpochID()
	return outgoing{otid: otid, otidStr: id64(otid), pendingID: "pending:" + id64(otid)}
}

// emitEcho shows the message being sent in its chat.
func (c *Core) emitEcho(threadID string, out outgoing, text string, mentions []apiMention, replyTo *apiReply, attachments []apiAttachment) {
	if attachments == nil {
		attachments = []apiAttachment{}
	}
	emitEvent("message", apiMessage{
		ID:          out.pendingID,
		ThreadID:    threadID,
		SenderID:    c.selfID(),
		IsFromMe:    true,
		Text:        text,
		Timestamp:   time.Now().UnixMilli(),
		Attachments: attachments,
		ReplyTo:     replyTo,
		Reactions:   []apiReaction{},
		Status:      statusPending,
		PendingID:   out.pendingID,
		Mentions:    mentions,
	})
}

// replyPreview is the quote of the message replied to, as far as it's stored.
func (c *Core) replyPreview(replyTo string) *apiReply {
	if replyTo == "" {
		return nil
	}
	reply := &apiReply{MessageID: replyTo}
	if target := c.store.GetMessage(replyTo); target != nil {
		reply.Text = target.Text
		reply.SenderID = target.SenderID
	}
	return reply
}

// sendText sends a text message; mentions are the people tagged in it (not in encrypted chats).
func (c *Core) sendText(ctx context.Context, threadID, text, replyTo string, mentions []apiMention) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	if t.Type.IsWhatsApp() {
		mentions = nil
	}
	out := newOutgoing()
	reply := c.replyPreview(replyTo)
	c.emitEcho(threadID, out, text, mentions, reply, nil)

	if t.Type.IsWhatsApp() {
		content := &waConsumerApplication.ConsumerApplication_Content{
			Content: &waConsumerApplication.ConsumerApplication_Content_MessageText{
				MessageText: &waCommon.MessageText{Text: proto.String(text)},
			},
		}
		row := &messageRow{Text: text, ReplyTo: reply}
		return c.sendE2EE(ctx, t, out, content, c.quotedMetadata(replyTo), row)
	}

	task := c.newSendTask(t, out, table.TEXT)
	task.Text = text
	if len(mentions) > 0 {
		tags := make(socket.Mentions, 0, len(mentions))
		for _, m := range mentions {
			userID, err := strconv.ParseInt(m.UserID, 10, 64)
			if err != nil {
				continue
			}
			tags = append(tags, socket.Mention{ID: userID, Offset: m.Offset, Length: m.Length, Type: socket.MentionTypePerson})
		}
		if len(tags) > 0 {
			task.MentionData = tags.ToData()
		}
	}
	if reply != nil {
		replySender, _ := strconv.ParseInt(reply.SenderID, 10, 64)
		task.ReplyMetaData = &socket.ReplyMetaData{ReplyMessageId: replyTo, ReplySourceType: 1, ReplyType: 0, ReplySender: replySender}
	}
	return c.sendFBTask(ctx, t.ID, out, task)
}

// MARK: Over the Facebook connection

func (c *Core) newSendTask(t *threadRow, out outgoing, sendType table.SendType) *socket.SendMessageTask {
	task := &socket.SendMessageTask{
		ThreadId:         c.fbThreadKey(t.ID),
		Otid:             out.otid,
		Source:           table.MESSENGER_INBOX_IN_THREAD,
		InitiatingSource: table.FACEBOOK_INBOX,
		SendType:         sendType,
		SyncGroup:        syncGroupMain,
	}
	if t.IsRequest() {
		task.Source = table.MESSENGER_INBOX_PENDING_REQUESTS
	}
	return task
}

// sendFBTask sends the message, and marks the chat read as the web app does. The server
// confirms it in the response or a later sync (resolvePending).
func (c *Core) sendFBTask(ctx context.Context, threadID string, out outgoing, task *socket.SendMessageTask) error {
	cli, err := c.requireClient()
	if err != nil {
		return failPending(threadID, out.pendingID, err)
	}
	c.addPending(out.otidStr, threadID, out.pendingID)
	if err := cli.WaitUntilCanSendMessages(ctx, 30*time.Second); err != nil {
		c.resolvePending(out.otidStr, "", err.Error())
		return err
	}
	readTask := &socket.ThreadMarkReadTask{ThreadId: task.ThreadId, LastReadWatermarkTs: time.Now().UnixMilli(), SyncGroup: syncGroupMain}
	resp, err := cli.ExecuteTasks(ctx, task, readTask)
	if err != nil {
		c.resolvePending(out.otidStr, "", err.Error())
		return err
	}
	c.handleTable(resp)
	return nil
}

// MARK: Over the encrypted connection

// consumerMessage wraps message content for the encrypted connection.
func consumerMessage(content *waConsumerApplication.ConsumerApplication_Content) *waConsumerApplication.ConsumerApplication {
	return &waConsumerApplication.ConsumerApplication{
		Payload: &waConsumerApplication.ConsumerApplication_Payload{
			Payload: &waConsumerApplication.ConsumerApplication_Payload_Content{Content: content},
		},
	}
}

// quotedMetadata names the message replied to, for the encrypted connection.
func (c *Core) quotedMetadata(replyTo string) *waMsgApplication.MessageApplication_Metadata {
	if replyTo == "" {
		return nil
	}
	target := c.store.GetMessage(replyTo)
	if target == nil || target.WASender == "" {
		return nil
	}
	return &waMsgApplication.MessageApplication_Metadata{
		QuotedMessage: &waMsgApplication.MessageApplication_Metadata_QuotedMessage{
			StanzaID:    proto.String(target.ID),
			Participant: proto.String(target.WASender),
		},
	}
}

// sendE2EE sends a consumer message over the encrypted connection and stores our copy, row
// (whatsmeow doesn't echo our own messages back).
func (c *Core) sendE2EE(
	ctx context.Context, t *threadRow, out outgoing,
	content *waConsumerApplication.ConsumerApplication_Content,
	meta *waMsgApplication.MessageApplication_Metadata,
	row *messageRow,
) error {
	e2ee, err := c.requireE2EE()
	if err != nil {
		return failPending(t.ID, out.pendingID, err)
	}
	resp, err := e2ee.SendFBMessage(ctx, t.chatJID(), consumerMessage(content), meta, whatsmeow.SendRequestExtra{ID: out.otidStr})
	if err != nil {
		return failPending(t.ID, out.pendingID, err)
	}
	c.storeSentE2EE(t, out, row, resp)
	return nil
}

// storeSentE2EE stores a message sent over the encrypted connection and replaces its echo.
func (c *Core) storeSentE2EE(t *threadRow, out outgoing, row *messageRow, resp whatsmeow.SendResponse) {
	e2ee, err := c.requireE2EE()
	if err != nil {
		return
	}
	chat := t.chatJID()
	row.ID = resp.ID
	row.ThreadID = t.ID
	row.SenderID = c.selfID()
	row.Timestamp = resp.Timestamp.UnixMilli()
	row.WAChat = chat.String()
	row.WASender = e2ee.Store.ID.ToNonAD().String()
	c.store.PutMessage(row)
	c.store.BumpThread(t.ID, row.Timestamp, snippetFor(row.Text, len(row.Attachments) > 0), row.SenderID)
	cs := newChangeSet()
	cs.messages[row.ID] = out.pendingID
	cs.thread(t.ID)
	c.flush(cs)
	// Sending reads the chat, as with Facebook messages (sendFBTask), also in the official apps.
	go c.sendE2EEReadWatermark(context.Background(), t, readMarkAfterSending(resp.Timestamp))
}

// MARK: - Sending files

// mediaFile is a file to send, read from disk.
type mediaFile struct {
	path, filename, mimeType, kind string
	data                           []byte
	width, height                  int // pixels, for images
}

func readMediaFile(path string) (*mediaFile, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	f := &mediaFile{path: path, filename: filepath.Base(path), data: data}
	f.mimeType = mime.TypeByExtension(strings.ToLower(filepath.Ext(path)))
	if f.mimeType == "" {
		f.mimeType = http.DetectContentType(data)
	}
	f.mimeType, _, _ = strings.Cut(f.mimeType, ";")
	f.kind = kindForMime(f.mimeType)
	if cfg, _, err := image.DecodeConfig(bytes.NewReader(data)); err == nil {
		f.width, f.height = cfg.Width, cfg.Height
	}
	return f, nil
}

// attachment describes the file as an attachment with the ID.
func (f *mediaFile) attachment(id string) apiAttachment {
	return apiAttachment{
		ID: id, Kind: f.kind, LocalPath: f.path, Width: f.width, Height: f.height, Filename: f.filename, MimeType: f.mimeType,
	}
}

func kindForMime(mimeType string) string {
	switch {
	case mimeType == "image/gif":
		return kindGIF
	case strings.HasPrefix(mimeType, "image/"):
		return kindImage
	case strings.HasPrefix(mimeType, "video/"):
		return kindVideo
	case strings.HasPrefix(mimeType, "audio/"):
		return kindAudio
	default:
		return kindFile
	}
}

// sendMedia sends files as one message (several photos and videos are one album).
func (c *Core) sendMedia(ctx context.Context, threadID string, paths []string) error {
	if len(paths) == 0 {
		return errors.New("no files to send")
	}
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	files := make([]*mediaFile, 0, len(paths))
	for _, path := range paths {
		f, err := readMediaFile(path)
		if err != nil {
			return err
		}
		files = append(files, f)
	}
	out := newOutgoing()
	attachments := make([]apiAttachment, len(files))
	for i, f := range files {
		attachments[i] = f.attachment(out.pendingID + "-" + strconv.Itoa(i))
	}
	c.emitEcho(threadID, out, "", nil, nil, attachments)
	if t.Type.IsWhatsApp() {
		return c.sendE2EEMedia(ctx, t, out, files)
	}
	return c.sendFBMedia(ctx, t, out, files)
}

// sendFBMedia uploads the files and sends them in one message.
func (c *Core) sendFBMedia(ctx context.Context, t *threadRow, out outgoing, files []*mediaFile) error {
	cli, err := c.requireClient()
	if err != nil {
		return failPending(t.ID, out.pendingID, err)
	}
	ids := make([]int64, 0, len(files))
	for _, f := range files {
		resp, err := cli.GetHTTP().SendMercuryUploadRequest(ctx, c.fbThreadKey(t.ID), &httpclient.MercuryUploadMedia{
			Filename: f.filename, MimeType: f.mimeType, MediaData: f.data,
		})
		if err != nil {
			return failPending(t.ID, out.pendingID, fmt.Errorf("upload failed: %w", err))
		}
		if resp.Payload.RealMetadata == nil || resp.Payload.RealMetadata.GetFbId() == 0 {
			return failPending(t.ID, out.pendingID, errors.New("upload failed: no attachment ID"))
		}
		ids = append(ids, resp.Payload.RealMetadata.GetFbId())
	}
	task := c.newSendTask(t, out, table.MEDIA)
	task.AttachmentFBIds = ids
	return c.sendFBTask(ctx, t.ID, out, task)
}

// sendE2EEMedia sends the files over the encrypted connection. Each file is its own message
// there; several are marked as one group (an album), and stored here as one message.
func (c *Core) sendE2EEMedia(ctx context.Context, t *threadRow, out outgoing, files []*mediaFile) error {
	e2ee, err := c.requireE2EE()
	if err != nil {
		return failPending(t.ID, out.pendingID, err)
	}
	type prepared struct {
		content *waConsumerApplication.ConsumerApplication_Content
		stored  storedAttachment
	}
	parts := make([]prepared, 0, len(files))
	for i, f := range files {
		content, stored, err := c.uploadE2EEMedia(ctx, e2ee, f, strconv.Itoa(i))
		if err != nil {
			return failPending(t.ID, out.pendingID, err)
		}
		parts = append(parts, prepared{content, stored})
	}
	if len(parts) == 1 {
		row := &messageRow{Attachments: []storedAttachment{parts[0].stored}}
		return c.sendE2EE(ctx, t, out, parts[0].content, nil, row)
	}
	groupID := out.otidStr
	row := &messageRow{}
	var first whatsmeow.SendResponse
	for i, part := range parts {
		meta := &waMsgApplication.MessageApplication_Metadata{
			GroupID:    proto.String(groupID),
			GroupSize:  proto.Uint32(uint32(len(parts))),
			GroupIndex: proto.Uint32(uint32(i)),
		}
		id := out.otidStr
		if i > 0 {
			id = newOutgoing().otidStr
		}
		resp, err := e2ee.SendFBMessage(ctx, t.chatJID(), consumerMessage(part.content), meta, whatsmeow.SendRequestExtra{ID: id})
		if err != nil {
			if i == 0 {
				return failPending(t.ID, out.pendingID, err)
			}
			// Keep what went out.
			c.storeSentE2EE(t, out, row, first)
			return err
		}
		if i == 0 {
			first = resp
		}
		row.Attachments = append(row.Attachments, part.stored)
	}
	c.storeSentE2EE(t, out, row, first)
	return nil
}

// uploadE2EEMedia uploads a file for the encrypted connection: the message content, and the
// attachment as it's stored (with the keys to download it again).
func (c *Core) uploadE2EEMedia(ctx context.Context, e2ee *whatsmeow.Client, f *mediaFile, id string) (*waConsumerApplication.ConsumerApplication_Content, storedAttachment, error) {
	mediaType := whatsmeow.MediaDocument
	switch f.kind {
	case kindImage:
		mediaType = whatsmeow.MediaImage
	case kindVideo, kindGIF:
		// Messenger wants GIFs sent as (looping) videos.
		mediaType = whatsmeow.MediaVideo
	}
	uploaded, err := e2ee.Upload(ctx, f.data, mediaType)
	if err != nil {
		return nil, storedAttachment{}, fmt.Errorf("upload failed: %w", err)
	}
	content, err := e2eeMediaContent(f, mediaType, uploaded)
	if err != nil {
		return nil, storedAttachment{}, err
	}
	stored := storedAttachment{
		apiAttachment: f.attachment(id),
		WA: &waMediaInfo{
			MediaType: string(mediaType), Key: uploaded.MediaKey, SHA256: uploaded.FileSHA256,
			EncSHA256: uploaded.FileEncSHA256, DirectPath: uploaded.DirectPath,
		},
	}
	return content, stored, nil
}

// e2eeMediaContent is the message content for an uploaded file.
func e2eeMediaContent(f *mediaFile, mediaType whatsmeow.MediaType, uploaded whatsmeow.UploadResponse) (*waConsumerApplication.ConsumerApplication_Content, error) {
	thumbW, thumbH := clampTo400(f.width, f.height)
	transport := &waMediaTransport.WAMediaTransport{
		Integral: &waMediaTransport.WAMediaTransport_Integral{
			FileSHA256:        uploaded.FileSHA256,
			MediaKey:          uploaded.MediaKey,
			FileEncSHA256:     uploaded.FileEncSHA256,
			DirectPath:        &uploaded.DirectPath,
			MediaKeyTimestamp: proto.Int64(time.Now().Unix()),
		},
		Ancillary: &waMediaTransport.WAMediaTransport_Ancillary{
			FileLength: proto.Uint64(uint64(len(f.data))),
			Mimetype:   &f.mimeType,
			// Messenger's mobile apps won't show media without thumbnail dimensions.
			Thumbnail: &waMediaTransport.WAMediaTransport_Ancillary_Thumbnail{
				ThumbnailWidth:  proto.Uint32(uint32(thumbW)),
				ThumbnailHeight: proto.Uint32(uint32(thumbH)),
			},
			ObjectID: &uploaded.ObjectID,
		},
	}
	width, height := proto.Uint32(uint32(f.width)), proto.Uint32(uint32(f.height))

	content := &waConsumerApplication.ConsumerApplication_Content{}
	var err error
	switch mediaType {
	case whatsmeow.MediaImage:
		msg := &waConsumerApplication.ConsumerApplication_ImageMessage{}
		err = msg.Set(&waMediaTransport.ImageTransport{
			Integral:  &waMediaTransport.ImageTransport_Integral{Transport: transport},
			Ancillary: &waMediaTransport.ImageTransport_Ancillary{Width: width, Height: height},
		})
		content.Content = &waConsumerApplication.ConsumerApplication_Content_ImageMessage{ImageMessage: msg}
	case whatsmeow.MediaVideo:
		msg := &waConsumerApplication.ConsumerApplication_VideoMessage{}
		err = msg.Set(&waMediaTransport.VideoTransport{
			Integral: &waMediaTransport.VideoTransport_Integral{Transport: transport},
			Ancillary: &waMediaTransport.VideoTransport_Ancillary{
				Width: width, Height: height, GifPlayback: proto.Bool(f.kind == kindGIF),
			},
		})
		content.Content = &waConsumerApplication.ConsumerApplication_Content_VideoMessage{VideoMessage: msg}
	default:
		msg := &waConsumerApplication.ConsumerApplication_DocumentMessage{FileName: proto.String(f.filename)}
		err = msg.Set(&waMediaTransport.DocumentTransport{
			Integral:  &waMediaTransport.DocumentTransport_Integral{Transport: transport},
			Ancillary: &waMediaTransport.DocumentTransport_Ancillary{},
		})
		content.Content = &waConsumerApplication.ConsumerApplication_Content_DocumentMessage{DocumentMessage: msg}
	}
	return content, err
}

// clampTo400 fits the size into 400×400 (the thumbnail size Messenger expects).
func clampTo400(w, h int) (int, int) {
	if w <= 0 || h <= 0 {
		return 400, 400
	}
	if w > h && w > 400 {
		return 400, h * 400 / w
	} else if h > 400 {
		return w * 400 / h, 400
	}
	return w, h
}
