package main

import (
	"strings"
	"testing"
)

func TestSearchFold(t *testing.T) {
	cases := []struct{ text, query string }{
		{"Árvíztűrő tükörfúrógép", "tukorfuro"},
		{"Árvíztűrő tükörfúrógép", "ARVIZTURO"},
		{"Hello World", "o w"},
	}
	for _, c := range cases {
		if !strings.Contains(searchFold(c.text), searchFold(c.query)) {
			t.Errorf("%q should match %q", c.text, c.query)
		}
	}
	if strings.Contains(searchFold("kerek"), searchFold("kérdés")) {
		t.Error("kerek shouldn't match kérdés")
	}
}
