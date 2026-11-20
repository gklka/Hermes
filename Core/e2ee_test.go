package main

import (
	"bytes"
	"testing"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waMediaTransport"
	"google.golang.org/protobuf/proto"
)

func TestVideoThumbnailInfoKeepsInlineThumbnail(t *testing.T) {
	thumbnail := []byte{0xff, 0xd8, 0xff, 0xd9}
	transport := &waMediaTransport.VideoTransport{
		Integral: &waMediaTransport.VideoTransport_Integral{
			Transport: &waMediaTransport.WAMediaTransport{
				Ancillary: &waMediaTransport.WAMediaTransport_Ancillary{
					Thumbnail: &waMediaTransport.WAMediaTransport_Ancillary_Thumbnail{
						JPEGThumbnail: thumbnail,
					},
				},
			},
		},
	}

	got, media := videoThumbnailInfo(transport)
	if !bytes.Equal(got, thumbnail) {
		t.Fatalf("thumbnail = %v, want %v", got, thumbnail)
	}
	if media != nil {
		t.Fatalf("downloadable thumbnail = %+v, want nil", media)
	}
}

func TestVideoThumbnailInfoKeepsDownloadableThumbnail(t *testing.T) {
	thumbnail := &waMediaTransport.WAMediaTransport_Ancillary_Thumbnail_DownloadableThumbnail{
		FileSHA256:    []byte{1},
		FileEncSHA256: []byte{2},
		DirectPath:    proto.String("/thumbnail"),
		MediaKey:      []byte{3},
	}
	transport := &waMediaTransport.VideoTransport{
		Integral: &waMediaTransport.VideoTransport_Integral{
			Transport: &waMediaTransport.WAMediaTransport{
				Ancillary: &waMediaTransport.WAMediaTransport_Ancillary{
					Thumbnail: &waMediaTransport.WAMediaTransport_Ancillary_Thumbnail{
						DownloadableThumbnail: thumbnail,
					},
				},
			},
		},
	}

	_, media := videoThumbnailInfo(transport)
	if media == nil {
		t.Fatal("downloadable thumbnail was not retained")
	}
	if media.MediaType != string(whatsmeow.MediaImage) ||
		media.DirectPath != thumbnail.GetDirectPath() ||
		!bytes.Equal(media.Key, thumbnail.GetMediaKey()) ||
		!bytes.Equal(media.SHA256, thumbnail.GetFileSHA256()) ||
		!bytes.Equal(media.EncSHA256, thumbnail.GetFileEncSHA256()) {
		t.Fatalf("downloadable thumbnail metadata = %+v, want source metadata", media)
	}
}
