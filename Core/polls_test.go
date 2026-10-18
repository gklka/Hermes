package main

import (
	"testing"

	"go.mau.fi/mautrix-meta/pkg/messagix/table"
)

func TestPollFromXMA(t *testing.T) {
	x := &table.WrappedXMA{
		LSInsertXmaAttachment: &table.LSInsertXmaAttachment{
			AttachmentFbid:                    "123",
			ListItemsDescriptionText:          "Pizza?",
			ListItemsSecondaryDescriptionText: "2 további lehetőség",
			ListItemId1:                       11, ListItemTitleText1: "Yes", ListItemTotalCount1: 2, ListItemProgressBarFilledPercentage1: 50,
			ListItemContactUrlList1: "https://a/1.jpg, https://a/2.jpg",
			ListItemId2:             12, ListItemTitleText2: "No",
		},
		CTA: &table.LSInsertAttachmentCta{Type_: "xma_poll_details_card", TargetId: 123, Title: "Szavazás"},
	}
	poll := pollFromXMA(x)
	if poll == nil || poll.ID != "123" || poll.Question != "Pizza?" || poll.MoreCount != 2 || len(poll.Options) != 2 {
		t.Fatalf("poll = %+v", poll)
	}
	if o := poll.Options[0]; o.ID != "11" || o.VoteCount != 2 || o.Percent != 50 || len(o.Voters) != 2 {
		t.Fatalf("first option = %+v", o)
	}
	x.CTA.Type_ = "xma_web_url"
	if pollFromXMA(x) != nil {
		t.Fatal("a link isn't a poll")
	}
}

func TestVoterIDs(t *testing.T) {
	fallbacks := "/messaging/lightspeed/media_fallback/?entity_id=100000000000001&entity_type=1&width=100, " +
		"/messaging/lightspeed/media_fallback/?entity_id=100001&entity_type=1"
	if got := voterIDs(fallbacks); len(got) != 2 || got[0] != "100000000000001" || got[1] != "100001" {
		t.Fatalf("voterIDs = %v", got)
	}
	if got := voterIDs(""); len(got) != 0 {
		t.Fatalf("voterIDs(\"\") = %v", got)
	}
}

func TestLeadingNumber(t *testing.T) {
	for s, want := range map[string]int{"2 more options": 2, "+12 további": 12, "": 0, "more": 0} {
		if got := leadingNumber(s); got != want {
			t.Errorf("leadingNumber(%q) = %d, want %d", s, got, want)
		}
	}
}
