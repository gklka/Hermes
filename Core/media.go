package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"go.mau.fi/whatsmeow"

	"go.mau.fi/mautrix-meta/pkg/messagix/useragent"
)

// MARK: - Downloading attachments

// GetDirectPath etc. let waMediaInfo be passed to whatsmeow's Download.
func (m *waMediaInfo) GetDirectPath() string             { return m.DirectPath }
func (m *waMediaInfo) GetMediaKey() []byte               { return m.Key }
func (m *waMediaInfo) GetFileSHA256() []byte             { return m.SHA256 }
func (m *waMediaInfo) GetFileEncSHA256() []byte          { return m.EncSHA256 }
func (m *waMediaInfo) GetMediaType() whatsmeow.MediaType { return whatsmeow.MediaType(m.MediaType) }

// downloadMedia returns the attachment's file, downloading it (and decrypting it, from an
// encrypted chat) into the media folder the first time.
func (c *Core) downloadMedia(ctx context.Context, messageID, attachmentID string) (string, error) {
	m := c.store.GetMessage(messageID)
	if m == nil {
		return "", fmt.Errorf("unknown message %s", messageID)
	}
	att := m.attachment(attachmentID)
	if att == nil {
		return "", fmt.Errorf("unknown attachment %s", attachmentID)
	}
	if att.LocalPath != "" {
		if _, err := os.Stat(att.LocalPath); err == nil {
			return att.LocalPath, nil
		}
	}

	var data []byte
	var err error
	switch {
	case att.WA != nil:
		e2ee, connErr := waitForConnection(ctx, c, c.requireE2EE)
		if connErr != nil {
			return "", connErr
		}
		data, err = e2ee.Download(ctx, att.WA)
	case att.URL != "" && att.Kind != kindLink:
		data, err = httpGet(ctx, att.URL)
	default:
		return "", errors.New("attachment has no downloadable media")
	}
	if err != nil {
		return "", fmt.Errorf("download failed: %w", err)
	}

	ext := filepath.Ext(att.Filename)
	if ext == "" {
		ext = extensionFor(firstNonEmpty(att.MimeType, http.DetectContentType(data)))
	}
	name := strings.NewReplacer("/", "_", ":", "_", "$", "_", ".", "_").Replace(messageID + "-" + attachmentID)
	path := filepath.Join(c.mediaDir(), name+ext)
	if err = os.WriteFile(path, data, 0o600); err != nil {
		return "", err
	}
	c.store.SetAttachmentLocalPath(messageID, attachmentID, path)
	return path, nil
}

// httpGet downloads from Facebook's CDN the way the web app's <img> does.
func httpGet(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", useragent.UserAgent)
	req.Header.Set("sec-ch-ua", useragent.SecCHUserAgent)
	req.Header.Set("sec-ch-ua-platform", useragent.SecCHPlatform)
	req.Header.Set("Sec-Fetch-Dest", "image")
	req.Header.Set("Sec-Fetch-Mode", "no-cors")
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

var preferredExtensions = map[string]string{
	"image/jpeg": ".jpg", "image/png": ".png", "image/gif": ".gif", "image/webp": ".webp",
	"video/mp4": ".mp4", "video/quicktime": ".mov", "audio/mpeg": ".mp3", "audio/mp4": ".m4a",
	"audio/aac": ".aac", "audio/ogg": ".ogg", "application/pdf": ".pdf",
}

func extensionFor(mimeType string) string {
	mimeType, _, _ = strings.Cut(mimeType, ";")
	if ext, ok := preferredExtensions[mimeType]; ok {
		return ext
	}
	if exts, _ := mime.ExtensionsByType(mimeType); len(exts) > 0 {
		return exts[0]
	}
	return ""
}
