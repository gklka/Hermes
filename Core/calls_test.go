package main

import (
	"encoding/xml"
	"testing"
)

func TestCallNotificationParsing(t *testing.T) {
	node := `<notification from="100000000000001@msgr" id="7516879303900734" t="1792163711" type="fb:call"><call_event call_type="video" duration="28" event_actor_id="100000000000001@msgr" event_time="1792163711321" event_type="ended" jid="100000000000002@msgr" parent_id="7516879301854072" server_info_data="AAAA"/></notification>`
	var n callNotification
	if err := xml.Unmarshal([]byte(node), &n); err != nil {
		t.Fatal(err)
	}
	e := n.Event
	if n.ID != "7516879303900734" || e.CallType != "video" || e.Duration != 28 || e.Type != "ended" ||
		e.JID != "100000000000002@msgr" || e.ParentID != "7516879301854072" || e.Time != 1792163711321 || e.Actor != "100000000000001@msgr" {
		t.Fatalf("unexpected: %+v", n)
	}
}
