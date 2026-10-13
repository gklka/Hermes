package main

import (
	"testing"
	"time"
)

func TestParseAge(t *testing.T) {
	day := 24 * time.Hour
	cases := map[string]time.Duration{
		"6 órája": 6 * time.Hour, "6 ó.": 6 * time.Hour, "5 napja": 5 * day, "5 n.": 5 * day,
		"2 hete": 14 * day, "3 hónapja": 90 * day, "1 éve": 365 * day, "12 perce": 12 * time.Minute,
		"6h": 6 * time.Hour, "3d": 3 * day, "2w": 14 * day, "1y": 365 * day, "5 minutes ago": 5 * time.Minute,
		"most": 0,
	}
	for label, want := range cases {
		got, ok := parseAge(label)
		if !ok || got != want {
			t.Errorf("parseAge(%q) = %v, %v; want %v", label, got, ok, want)
		}
	}
	if _, ok := parseAge("tegnap"); ok {
		t.Errorf("parseAge(tegnap) should fail")
	}
}

func TestWebMessageID(t *testing.T) {
	id, ts, ok := webMessageID("100000400487929@msgr.7515335101685728864")
	// 2026-10-12 10:58:36.416 +02:00
	if !ok || id != "7515335101685728864" || ts != 1791795516416 {
		t.Errorf("webMessageID = %q, %d, %v", id, ts, ok)
	}
}

func TestUnrestoredPlaceholder(t *testing.T) {
	for _, text := range []string{"Az üzenetet nem sikerült visszaállítani.", "Unable to restore this message"} {
		if !isUnrestoredPlaceholder(text) {
			t.Errorf("isUnrestoredPlaceholder(%q) = false", text)
		}
	}
	if isUnrestoredPlaceholder("Jövő héten egy bor nálunk?") {
		t.Errorf("a normal message was treated as a placeholder")
	}
}

func TestWithoutEmoji(t *testing.T) {
	// The same message read before (no emoji) and after emoji were collected.
	if withoutEmoji("Lusta felkelni ") != withoutEmoji("Lusta felkelni 😆") {
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
	url := "https://scontent-vie1-1.xx.fbcdn.net/v/t39.30808-1/805854260_28617347014528600_4651105664370678377_n.jpg?stp=cp6"
	if got := avatarKey(url); got != "805854260_28617347014528600_4651105664370678377" {
		t.Errorf("avatarKey = %q", got)
	}
}
