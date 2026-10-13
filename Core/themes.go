package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"go.mau.fi/mautrix-meta/pkg/messagix/graphql"
	"go.mau.fi/mautrix-meta/pkg/messagix/socket"
)

// The web app's query for a theme's colors (by theme ID). Doc IDs change when Meta redeploys
// the web app; then this needs the new one (see WebDOMInspector's WebNetLog mode).
const themeQueryName = "MWPThreadThemeProviderQuery"

func init() {
	graphql.GraphQLDocs[themeQueryName] = graphql.GraphQLDoc{DocID: "27838938182397954", FriendlyName: themeQueryName}
}

// refreshTheme asks for the chat's row, as the web app does when it opens one. The row arrives
// through the sync shortly after, with the theme ID and quick reaction emoji (see noteTheme).
//
// Not for encrypted chats: their row is the unencrypted chat they replaced, with its old theme,
// and a theme changed while the app wasn't running is never sent to us. The app reads their
// theme from the web app instead; changes while running arrive as LSUpdateThreadTheme.
func (c *Core) refreshTheme(ctx context.Context, threadID string) error {
	if t := c.store.GetThread(threadID); t != nil && t.Type.IsWhatsApp() {
		return nil
	}
	// The chat shown at launch is opened before the connection is up.
	cli := c.client()
	for i := 0; cli == nil && i < 60; i++ {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
		cli = c.client()
	}
	if cli == nil {
		return errNotConnected
	}
	if err := cli.WaitUntilCanSendMessages(ctx, 30*time.Second); err != nil {
		return err
	}
	key := c.fbThreadKey(threadID)
	resp, err := cli.ExecuteTasks(ctx, &socket.CreateThreadTask{ThreadFBID: key, SyncGroup: 1})
	if err != nil {
		return err
	}
	c.handleTable(resp)
	return nil
}

// noteTheme stores a chat's theme from its thread row, fetching the theme's colors if they
// aren't cached yet.
func (c *Core) noteTheme(threadID string, themeID int64, emoji string) {
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		colors, err := c.themeColors(ctx, themeID)
		if err != nil {
			c.log.Warn().Err(err).Str("thread_id", threadID).Int64("theme", themeID).Msg("Couldn't get the theme's colors")
			return
		}
		c.log.Debug().Str("thread_id", threadID).Int64("theme", themeID).Strs("colors", colors).Str("emoji", emoji).Msg("Thread theme")
		c.setThreadTheme(threadID, colors, emoji)
	}()
}

// Messenger's default theme; the app keeps its own color for it.
var defaultThemeGradient = []string{"#aa00ff", "#0070f6"}

// themeColors returns a theme's outgoing bubble colors as "#rrggbb": one for a solid theme,
// several for a gradient, none for the default theme. Cached, since themes don't change.
func (c *Core) themeColors(ctx context.Context, themeID int64) ([]string, error) {
	if themeID == 0 {
		return nil, nil
	}
	cacheKey := "themecolors:" + id64(themeID)
	if cached := c.store.Get(cacheKey); cached != "" {
		if cached == "default" {
			return nil, nil
		}
		return strings.Split(cached, ","), nil
	}
	cli := c.client()
	if cli == nil {
		return nil, errNotConnected
	}
	_, body, err := cli.GetHTTP().MakeGraphQLRequest(ctx, themeQueryName, map[string]string{"id": id64(themeID)})
	if err != nil {
		return nil, err
	}
	var parsed struct {
		Data struct {
			Theme *struct {
				FallbackColor  string   `json:"fallback_color"`
				GradientColors []string `json:"gradient_colors"`
			} `json:"messenger_thread_theme"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("theme %d: %w", themeID, err)
	}
	theme := parsed.Data.Theme
	if theme == nil {
		return nil, fmt.Errorf("theme %d not in the response: %.200s", themeID, body)
	}
	var colors []string
	for _, value := range theme.GradientColors {
		if color, ok := argbToHex(value); ok {
			colors = append(colors, color)
		}
	}
	if len(colors) < 2 {
		colors = nil
		if color, ok := argbToHex(theme.FallbackColor); ok {
			colors = []string{color}
		}
	}
	if len(colors) == 0 {
		return nil, errors.New("theme has no colors")
	}
	if sameColors(colors, defaultThemeGradient) {
		c.store.Set(cacheKey, "default")
		return nil, nil
	}
	c.store.Set(cacheKey, strings.Join(colors, ","))
	return colors, nil
}

// argbToHex turns Messenger's "AARRGGBB" (or "RRGGBB") into "#rrggbb".
func argbToHex(value string) (string, bool) {
	value = strings.TrimPrefix(value, "#")
	if len(value) == 8 {
		value = value[2:]
	}
	if len(value) != 6 {
		return "", false
	}
	if _, err := strconv.ParseUint(value, 16, 32); err != nil {
		return "", false
	}
	return "#" + strings.ToLower(value), true
}

// sameColors compares in either order (top to bottom or the reverse).
func sameColors(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	forward, backward := true, true
	for i := range a {
		forward = forward && a[i] == b[i]
		backward = backward && a[i] == b[len(b)-1-i]
	}
	return forward || backward
}

var hexColorPattern = regexp.MustCompile(`^#[0-9a-f]{6}$`)

// setThreadTheme stores the chat's custom bubble colors and quick reaction emoji (empty:
// Messenger's default theme / like).
func (c *Core) setThreadTheme(threadID string, colors []string, emoji string) {
	for _, color := range colors {
		if !hexColorPattern.MatchString(color) {
			c.log.Warn().Str("thread_id", threadID).Strs("colors", colors).Msg("Ignoring invalid bubble colors")
			return
		}
	}
	if len(emoji) > 64 {
		c.log.Warn().Str("thread_id", threadID).Int("length", len(emoji)).Msg("Ignoring invalid quick reaction emoji")
		emoji = ""
	}
	changed := c.setOrDelete("colors:"+threadID, strings.Join(colors, ","))
	changed = c.setOrDelete("emoji:"+threadID, emoji) || changed
	if changed {
		cs := newChangeSet()
		cs.thread(threadID)
		c.flush(cs)
	}
}

// setOrDelete stores a kv value (deleting it when empty) and reports whether it changed.
func (c *Core) setOrDelete(key, value string) bool {
	if c.store.Get(key) == value {
		return false
	}
	if value == "" {
		c.store.Delete(key)
	} else {
		c.store.Set(key, value)
	}
	return true
}
