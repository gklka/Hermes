package main

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strconv"
	_ "unsafe" // go:linkname

	"go.mau.fi/mautrix-meta/pkg/messagix"
	"go.mau.fi/mautrix-meta/pkg/messagix/lightspeed"
)

// A Marketplace chat's listing comes in the banner Messenger shows above the chat. The web app
// fetches it when a chat opens (task label 72, queue in_thread_banner_fetch_activity_banners_queue);
// the reply's upsertCTA rows are the banner's buttons, whose links name the listing
// ("See details": /marketplace/item/<id>/, or /marketplace/similar_items/<id>/ once it's sold).
// messagix doesn't know upsertCTA and drops it while parsing, so the reply is decoded here.

// These reach messagix's own request plumbing: ExecuteTasks only returns the parsed tables.
//
//go:linkname newTaskManager go.mau.fi/mautrix-meta/pkg/messagix.(*Client).newTaskManager
func newTaskManager(c *messagix.Client) *messagix.TaskManager

//go:linkname makeLSRequest go.mau.fi/mautrix-meta/pkg/messagix.(*Client).makeLSRequest
func makeLSRequest(c *messagix.Client, ctx context.Context, payload []byte, t int) (*messagix.PublishResponseData, error)

type fetchBannersTask struct {
	ThreadKey int64 `json:"thread_key"`
}

func (t *fetchBannersTask) GetLabel() string { return "72" }

func (t *fetchBannersTask) Create() (any, string) {
	return t, "in_thread_banner_fetch_activity_banners_queue"
}

// lsUpsertCTA is one of the banner's buttons.
type lsUpsertCTA struct {
	CTAID     int64  `index:"1"`
	Type      string `index:"2"`
	ThreadKey int64  `index:"3"`
	Title     string `index:"4"`
	NativeURL string `index:"5"`
	WebURL    string `index:"6"`
}

type bannerTables struct {
	UpsertCTA []*lsUpsertCTA
}

var listingIDPattern = regexp.MustCompile(`marketplace/item/(\d+)|similar_items/(\d+)|productItemID=(\d+)|marketplace_product_details\?id=(\d+)`)

// marketplaceListingURL is the listing's page on facebook.com, fetched once and then kept.
func (c *Core) marketplaceListingURL(ctx context.Context, threadID string) (string, error) {
	if url := c.store.Get(kvListing + threadID); url != "" {
		return url, nil
	}
	key, err := strconv.ParseInt(threadID, 10, 64)
	if err != nil {
		return "", errors.New("not a Marketplace chat")
	}
	cli := c.client()
	if cli == nil {
		return "", errors.New("not connected")
	}
	tasks := newTaskManager(cli)
	tasks.AddNewTask(&fetchBannersTask{ThreadKey: key})
	payload, err := tasks.FinalizePayload()
	if err != nil {
		return "", err
	}
	resp, err := makeLSRequest(cli, ctx, payload, 3)
	if err != nil {
		return "", err
	}
	if resp == nil {
		return "", errors.New("no reply")
	}
	var data lightspeed.LightSpeedData
	if err := json.Unmarshal([]byte(resp.Payload), &data); err != nil {
		return "", err
	}
	var tables bannerTables
	lightspeed.NewLightSpeedDecoder(lightspeed.DependencyMap{"upsertCTA": "UpsertCTA"}, &tables).Decode(data.Steps)

	for _, cta := range tables.UpsertCTA {
		if cta.ThreadKey != key {
			continue
		}
		for _, link := range []string{cta.WebURL, cta.NativeURL} {
			match := listingIDPattern.FindStringSubmatch(link)
			for _, id := range match[min(1, len(match)):] {
				if id != "" {
					url := "https://www.facebook.com/marketplace/item/" + id + "/"
					c.store.Set(kvListing+threadID, url)
					return url, nil
				}
			}
		}
	}
	c.log.Info().Str("thread_id", threadID).Int("buttons", len(tables.UpsertCTA)).Msg("No Marketplace listing in the chat's banner")
	return "", errors.New("no listing found")
}
