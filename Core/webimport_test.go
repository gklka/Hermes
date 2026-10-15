package main

import (
	"testing"
	"time"
)

func TestParseAge(t *testing.T) {
	day := 24 * time.Hour
	cases := map[string]time.Duration{
		"6 órája": 6 * time.Hour, "6 ó.": 6 * time.Hour, "5 napja": 5 * day, "5 n.": 5 * day,
		"2 hete": 14 * day, "3 hónapja": 90 * day, "1 éve": 365 * day, "12 perce": 12 * time.Minute, "14 p.": 14 * time.Minute,
		"kb. egy órája": time.Hour, "egy hete": 7 * day, "about an hour ago": time.Hour, "a week ago": 7 * day,
		"a minute ago": time.Minute, "one day ago": day,
		"6h": 6 * time.Hour, "3d": 3 * day, "2w": 14 * day, "1y": 365 * day, "5 minutes ago": 5 * time.Minute,
		"most": 0,
	}
	for label, want := range cases {
		got, _, ok := parseAge(label)
		if !ok || got != want {
			t.Errorf("parseAge(%q) = %v, %v; want %v", label, got, ok, want)
		}
	}
	if _, _, ok := parseAge("tegnap"); ok {
		t.Errorf("parseAge(tegnap) should fail")
	}
}

func TestWebMessageID(t *testing.T) {
	id, ts, ok := webMessageID("100000000000001@msgr.7412462596916434567")
	// 2026-01-01 12:00:00 UTC
	if !ok || id != "7412462596916434567" || ts != 1767268800000 {
		t.Errorf("webMessageID = %q, %d, %v", id, ts, ok)
	}
}

func TestUnrestoredPlaceholder(t *testing.T) {
	for _, text := range []string{"Az üzenetet nem sikerült visszaállítani.", "Unable to restore this message"} {
		if !isUnrestoredPlaceholder(text) {
			t.Errorf("isUnrestoredPlaceholder(%q) = false", text)
		}
	}
	if isUnrestoredPlaceholder("Mikor indulunk holnap?") {
		t.Errorf("a normal message was treated as a placeholder")
	}
	// In a language the list doesn't know: a long text on several messages.
	placeholder := "Impossible de restaurer ce message."
	messages := []webMessage{{Text: placeholder}, {Text: "ok"}, {Text: placeholder}, {Text: "ok"}, {Text: "ok"}, {Text: placeholder}}
	repeated := repeatedTexts(messages)
	if !repeated[placeholder] || repeated["ok"] {
		t.Errorf("repeatedTexts = %v", repeated)
	}
}

func TestWithoutEmoji(t *testing.T) {
	// The same message read before (no emoji) and after emoji were collected.
	if withoutEmoji("See you tomorrow ") != withoutEmoji("See you tomorrow 😆") {
		t.Errorf("texts differing only by emoji should match")
	}
	if withoutEmoji("👍🏽") != "" || withoutEmoji("❤️") != "" {
		t.Errorf("emoji with modifiers should be dropped")
	}
	if withoutEmoji("ok") == withoutEmoji("okay") {
		t.Errorf("different texts should differ")
	}
}

func TestAvatarKey(t *testing.T) {
	url := "https://scontent.xx.fbcdn.net/v/t39.30808-1/123456789_1234567890123456_1234567890123456789_n.jpg?stp=cp6"
	if got := avatarKey(url); got != "123456789_1234567890123456_1234567890123456789" {
		t.Errorf("avatarKey = %q", got)
	}
}
