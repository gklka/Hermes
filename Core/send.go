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
func (c *Core) emitEcho(threadID string, out outgoing, text string, replyTo *apiReply, attachments []apiAttachment) {
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

func (c *Core) sendText(ctx context.Context, threadID, text, replyTo string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	out := newOutgoing()
	reply := c.replyPreview(replyTo)
	c.emitEcho(threadID, out, text, reply, nil)

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
	if t.Folder == folderRequests {
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
	chat := t.chatJID()
	resp, err := e2ee.SendFBMessage(ctx, chat, consumerMessage(content), meta, whatsmeow.SendRequestExtra{ID: out.otidStr})
	if err != nil {
		return failPending(t.ID, out.pendingID, err)
	}
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
	return nil
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

func (c *Core) sendMedia(ctx context.Context, threadID, path string) error {
	t, err := c.thread(threadID)
	if err != nil {
		return err
	}
	f, err := readMediaFile(path)
	if err != nil {
		return err
	}
	out := newOutgoing()
	c.emitEcho(threadID, out, "", nil, []apiAttachment{f.attachment(out.pendingID + "-0")})
	if t.Type.IsWhatsApp() {
		return c.sendE2EEMedia(ctx, t, out, f)
	}
	return c.sendFBMedia(ctx, t, out, f)
}

func (c *Core) sendFBMedia(ctx context.Context, t *threadRow, out outgoing, f *mediaFile) error {
	cli, err := c.requireClient()
	if err != nil {
		return failPending(t.ID, out.pendingID, err)
	}
	resp, err := cli.GetHTTP().SendMercuryUploadRequest(ctx, c.fbThreadKey(t.ID), &httpclient.MercuryUploadMedia{
		Filename: f.filename, MimeType: f.mimeType, MediaData: f.data,
	})
	if err != nil {
		return failPending(t.ID, out.pendingID, fmt.Errorf("upload failed: %w", err))
	}
	if resp.Payload.RealMetadata == nil || resp.Payload.RealMetadata.GetFbId() == 0 {
		return failPending(t.ID, out.pendingID, errors.New("upload failed: no attachment ID"))
	}
	task := c.newSendTask(t, out, table.MEDIA)
	task.AttachmentFBIds = []int64{resp.Payload.RealMetadata.GetFbId()}
	return c.sendFBTask(ctx, t.ID, out, task)
}

func (c *Core) sendE2EEMedia(ctx context.Context, t *threadRow, out outgoing, f *mediaFile) error {
	e2ee, err := c.requireE2EE()
	if err != nil {
		return failPending(t.ID, out.pendingID, err)
	}
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
		return failPending(t.ID, out.pendingID, fmt.Errorf("upload failed: %w", err))
	}
	content, err := e2eeMediaContent(f, mediaType, uploaded)
	if err != nil {
		return failPending(t.ID, out.pendingID, err)
	}
	stored := storedAttachment{
		apiAttachment: f.attachment("0"),
		WA: &waMediaInfo{
			MediaType: string(mediaType), Key: uploaded.MediaKey, SHA256: uploaded.FileSHA256,
			EncSHA256: uploaded.FileEncSHA256, DirectPath: uploaded.DirectPath,
		},
	}
	row := &messageRow{Attachments: []storedAttachment{stored}}
	return c.sendE2EE(ctx, t, out, content, nil, row)
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
