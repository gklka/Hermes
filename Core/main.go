// Package main is the Go core of MessengerMac, built as a C archive and linked
// into the Swift app. It exposes two C functions:
//
//	MMStart(dataDir, callback)  initialises the core and registers the callback
//	MMRequest(json)             sends a JSON-RPC style request
//
// Everything the core says goes through the callback as a JSON string, either a
// response ({"type":"response","id":…}) or an event ({"type":"event","event":…}).
package main

/*
#include <stdlib.h>

typedef void (*mm_callback)(const char *message);

static inline void mm_invoke(mm_callback cb, const char *message) {
	cb(message);
}
*/
import "C"

import (
	"encoding/json"
	"sync"
	"unsafe"
)

var (
	callback C.mm_callback
	emitLock sync.Mutex
	core     *Core
	// Requests are queued in arrival order; the dispatcher starts once the core is ready.
	requests = make(chan []byte, 4096)
)

//export MMStart
func MMStart(dataDir *C.char, cb C.mm_callback) {
	callback = cb
	dir := C.GoString(dataDir)
	go func() {
		core = NewCore(dir)
		ready := make(chan struct{})
		go func() {
			<-ready
			for data := range requests {
				core.HandleRequest(data)
			}
		}()
		core.Start(ready)
	}()
}

//export MMRequest
func MMRequest(request *C.char) {
	requests <- []byte(C.GoString(request))
}

type responseEnvelope struct {
	Type   string `json:"type"`
	ID     int64  `json:"id"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

type eventEnvelope struct {
	Type  string `json:"type"`
	Event string `json:"event"`
	Data  any    `json:"data"`
}

func emitResponse(id int64, result any, err error) {
	env := responseEnvelope{Type: "response", ID: id}
	if err != nil {
		env.Error = err.Error()
	} else if result == nil {
		env.Result = struct{}{}
	} else {
		env.Result = result
	}
	emitJSON(env)
}

func emitEvent(name string, data any) {
	emitJSON(eventEnvelope{Type: "event", Event: name, Data: data})
}

func emitJSON(v any) {
	data, err := json.Marshal(v)
	if err != nil {
		if core != nil {
			core.log.Err(err).Msg("Failed to marshal outgoing message")
		}
		return
	}
	// Serialise callbacks so Swift receives events in the order they were emitted.
	emitLock.Lock()
	defer emitLock.Unlock()
	if callback == nil {
		return
	}
	cs := C.CString(string(data))
	C.mm_invoke(callback, cs)
	C.free(unsafe.Pointer(cs))
}

func main() {}
