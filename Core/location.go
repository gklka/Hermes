package main

import (
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// mapCoordREs pull a point out of the URL forms Messenger uses for a shared place: a static map's
// `center=`, a query/pin parameter, a `/@lat,lng` path, or Google's `!3dlat!4dlng`. The comma and
// `=` may be percent-encoded once or twice (places come through an fbcdn proxy that wraps the real
// URL in a `url=` parameter, encoding it again).
var mapCoordREs = []*regexp.Regexp{
	regexp.MustCompile(`(?:center|query|q|ll|daddr|destination)(?:=|%3D)(-?\d{1,3}\.\d+)(?:,|%2C|%252C)(-?\d{1,3}\.\d+)`),
	regexp.MustCompile(`@(-?\d{1,3}\.\d+)(?:,|%2C|%252C)(-?\d{1,3}\.\d+)`),
	regexp.MustCompile(`!3d(-?\d{1,3}\.\d+)!4d(-?\d{1,3}\.\d+)`),
}

// coordsFromMapURL returns the point a Maps URL refers to, if it is one.
func coordsFromMapURL(raw string) (lat, lng float64, ok bool) {
	// All Maps URLs (static map, google.com/maps, maps.app.goo.gl, maps.apple.com) contain "map";
	// requiring it keeps a stray "@lat,lng" in an ordinary link from being read as a place.
	if !strings.Contains(strings.ToLower(raw), "map") {
		return 0, 0, false
	}
	// Undo the proxy's `url=` wrapping and percent-encoded commas, best effort.
	dec := raw
	for range 3 {
		u, err := url.QueryUnescape(dec)
		if err != nil || u == dec {
			break
		}
		dec = u
	}
	for _, re := range mapCoordREs {
		for _, s := range []string{dec, raw} {
			if m := re.FindStringSubmatch(s); m != nil {
				la, e1 := strconv.ParseFloat(m[1], 64)
				lo, e2 := strconv.ParseFloat(m[2], 64)
				if e1 == nil && e2 == nil {
					return la, lo, true
				}
			}
		}
	}
	return 0, 0, false
}

// classifyLocationAttachments turns a shared place — a link or image whose preview is a Google
// static map — into a location card, so it shows a real map and opens in Maps instead of a web
// link or the image viewer. Done at read time, so places shared before this existed show too.
func classifyLocationAttachments(attachments []apiAttachment) {
	for i := range attachments {
		a := &attachments[i]
		if a.Kind != kindLink && a.Kind != kindImage || a.Location != nil {
			continue
		}
		lat, lng, ok := coordsFromMapURL(a.PreviewURL)
		if !ok {
			lat, lng, ok = coordsFromMapURL(a.URL)
		}
		if !ok {
			continue
		}
		name := a.Title
		if strings.ContainsAny(name, "°") {
			name = "" // a plain pin's title is its DMS coordinates, not a place name
		}
		a.Kind = kindLocation
		a.Location = &apiLocation{Latitude: lat, Longitude: lng, Name: name}
		a.URL, a.PreviewURL, a.Title, a.Subtitle, a.Source = "", "", "", "", ""
		a.Width, a.Height = 0, 0
	}
}
