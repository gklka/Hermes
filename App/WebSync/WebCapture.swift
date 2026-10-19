import Foundation
import WebKit

/// Development aid for reimplementing the encrypted backup restore natively (docs/Labyrinth.md):
/// records everything the web app sends and receives (fetch, XHR, WebSocket frames, in full),
/// its Web Crypto calls (keys, inputs and outputs), WebAssembly modules and workers, to
/// Application Support/Hermes/capture/capture.jsonl (one JSON object per line).
///
/// The file holds secrets (session tokens, backup keys): keep it local.
///
/// Enable with: defaults write com.kristofgruber.Hermes WebCapture -bool YES (then relaunch).
/// It also makes the web view inspectable in Safari's Develop menu (for workers, which this
/// can't see into).
final class WebCapture: NSObject, WKScriptMessageHandler {
    static let shared = WebCapture()

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "WebCapture") }

    static let folder = AppData.folder.appendingPathComponent("capture", isDirectory: true)
    private static let logURL = folder.appendingPathComponent("capture.jsonl")

    private let queue = DispatchQueue(label: "WebCapture")
    private var handle: FileHandle?

    static func install(in config: WKWebViewConfiguration) {
        guard isEnabled else { return }
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: false, in: .page))
        config.userContentController.add(shared, contentWorld: .page, name: "hermesCapture")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        queue.async { [self] in
            if handle == nil {
                try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: Self.logURL.path) {
                    FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: Self.logURL)
                _ = try? handle?.seekToEnd()
            }
            handle?.write(data)
            handle?.write(Data("\n".utf8))
        }
    }

    private static let script = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hermesCapture;
      if (!handler) return;
      let seq = 0;
      const where = String(location.href).slice(0, 200);
      const emit = entry => { try { entry.seq = ++seq; entry.t = Date.now(); entry.frame = where; handler.postMessage(entry); } catch (e) {} };
      const LIMIT = 8 * 1024 * 1024;

      const b64 = bytes => {
        let s = '';
        for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        return btoa(s);
      };
      const asBytes = v => {
        if (v instanceof ArrayBuffer) return new Uint8Array(v);
        if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
        return null;
      };
      // A body or frame as {text} or {b64} (binary), cut at `limit` bytes.
      const encode = async (v, limit = LIMIT) => {
        try {
          if (v == null) return null;
          if (typeof v === 'string') return { text: v.slice(0, limit), len: v.length };
          if (v instanceof URLSearchParams) { const s = v.toString(); return { text: s.slice(0, limit), len: s.length }; }
          if (v instanceof Blob) return encode(new Uint8Array(await v.arrayBuffer()), limit);
          if (v instanceof FormData) {
            const parts = [];
            for (const [k, x] of v.entries()) parts.push([k, typeof x === 'string' ? x : await encode(x, limit)]);
            return { form: parts };
          }
          const bytes = asBytes(v);
          if (bytes) return { b64: b64(bytes.subarray(0, limit)), len: bytes.length };
          return { other: String(v).slice(0, 200) };
        } catch (e) { return { error: String(e) }; }
      };
      const headersOf = h => { try { return h ? Object.fromEntries(new Headers(h).entries()) : undefined; } catch (e) { return undefined; } };
      const isText = type => /json|text|javascript|xml|x-www-form-urlencoded/.test(type || '');

      emit({ kind: 'page' });

      // fetch
      const origFetch = window.fetch;
      if (origFetch) window.fetch = async function (input, init) {
        const id = ++seq;
        const url = input && input.url || String(input);
        let reqBody = init && init.body;
        if (reqBody == null && input instanceof Request) { try { reqBody = await input.clone().arrayBuffer(); } catch (e) {} }
        const method = (init && init.method) || (input instanceof Request ? input.method : 'GET');
        const headers = headersOf((init && init.headers) || (input instanceof Request ? input.headers : undefined));
        emit({ kind: 'fetch', id, method, url, headers, body: await encode(reqBody) });
        let res;
        try { res = await origFetch.apply(this, arguments); }
        catch (e) { emit({ kind: 'fetchError', id, url, error: String(e) }); throw e; }
        try {
          const copy = res.clone();
          const type = copy.headers.get('content-type') || '';
          (isText(type) ? copy.text() : copy.arrayBuffer()).then(async b => {
            emit({ kind: 'fetchResponse', id, url, status: res.status, type, headers: headersOf(copy.headers), body: await encode(b) });
          }).catch(e => emit({ kind: 'fetchResponse', id, url, status: res.status, error: String(e) }));
        } catch (e) {}
        return res;
      };

      // XHR
      const xopen = XMLHttpRequest.prototype.open, xsend = XMLHttpRequest.prototype.send, xheader = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.open = function (method, url) { this.__hc = { id: ++seq, method, url: String(url), headers: {} }; return xopen.apply(this, arguments); };
      XMLHttpRequest.prototype.setRequestHeader = function (k, v) { if (this.__hc) this.__hc.headers[k] = v; return xheader.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function (body) {
        const info = this.__hc || { id: ++seq };
        encode(body).then(b => emit({ kind: 'xhr', id: info.id, method: info.method, url: info.url, headers: info.headers, body: b }));
        this.addEventListener('loadend', async () => {
          let out;
          try {
            const rt = this.responseType;
            out = rt === '' || rt === 'text' ? await encode(this.responseText)
                : rt === 'json' ? await encode(JSON.stringify(this.response))
                : await encode(this.response);
          } catch (e) { out = { error: String(e) }; }
          emit({ kind: 'xhrResponse', id: info.id, url: info.url, status: this.status, type: this.getResponseHeader('content-type'), body: out });
        });
        return xsend.apply(this, arguments);
      };

      // WebSocket
      if (window.WebSocket) window.WebSocket = new Proxy(window.WebSocket, {
        construct(target, args) {
          const ws = Reflect.construct(target, args);
          const id = ++seq, url = String(args[0]);
          emit({ kind: 'ws', id, url, protocols: args[1] });
          const send = ws.send;
          ws.send = function (data) { encode(data).then(d => emit({ kind: 'wsOut', id, url, data: d })); return send.apply(this, arguments); };
          ws.addEventListener('message', e => encode(e.data).then(d => emit({ kind: 'wsIn', id, url, data: d })));
          ws.addEventListener('close', e => emit({ kind: 'wsClose', id, url, code: e.code }));
          return ws;
        }
      });

      // Workers: only their creation (the hooks above don't reach inside).
      for (const name of ['Worker', 'SharedWorker']) {
        if (window[name]) window[name] = new Proxy(window[name], {
          construct(target, args) {
            emit({ kind: 'worker', type: name, url: String(args[0]), options: typeof args[1] === 'object' ? args[1] : args[1] && String(args[1]) });
            return Reflect.construct(target, args);
          }
        });
      }

      // WebAssembly modules
      if (window.WebAssembly) {
        const wa = WebAssembly;
        const saveModule = (how, src) => encode(src).then(m => emit({ kind: 'wasm', how, module: m }));
        const inst = wa.instantiate, comp = wa.compile, instS = wa.instantiateStreaming, compS = wa.compileStreaming;
        wa.instantiate = function (src) { if (!(src instanceof WebAssembly.Module)) saveModule('instantiate', src); return inst.apply(this, arguments); };
        wa.compile = function (src) { saveModule('compile', src); return comp.apply(this, arguments); };
        const streamed = (how, orig) => function (source) {
          Promise.resolve(source).then(r => { emit({ kind: 'wasm', how, url: r && r.url }); r.clone().arrayBuffer().then(b => saveModule(how, b)); }).catch(() => {});
          return orig.apply(this, arguments);
        };
        if (instS) wa.instantiateStreaming = streamed('instantiateStreaming', instS);
        if (compS) wa.compileStreaming = streamed('compileStreaming', compS);
      }

      // Web Crypto: every call with its inputs and result.
      const subtle = window.crypto && crypto.subtle;
      if (subtle) {
        const keyIDs = new WeakMap();
        let nextKey = 0;
        const CRYPTO_LIMIT = 256 * 1024;
        const describe = async v => {
          if (v == null) return v;
          if (typeof CryptoKey !== 'undefined' && v instanceof CryptoKey) {
            if (!keyIDs.has(v)) keyIDs.set(v, ++nextKey);
            return { key: keyIDs.get(v), type: v.type, algorithm: await describe(v.algorithm), extractable: v.extractable, usages: v.usages };
          }
          if (v.publicKey && v.privateKey) return { publicKey: await describe(v.publicKey), privateKey: await describe(v.privateKey) };
          if (v instanceof ArrayBuffer || ArrayBuffer.isView(v)) return encode(v, CRYPTO_LIMIT);
          if (Array.isArray(v)) return Promise.all(v.map(describe));
          if (typeof v === 'object') {
            const out = {};
            for (const k of Object.keys(v)) out[k] = await describe(v[k]);
            return out;
          }
          return v;
        };
        for (const method of ['importKey', 'exportKey', 'generateKey', 'deriveKey', 'deriveBits', 'encrypt', 'decrypt',
                              'sign', 'verify', 'digest', 'wrapKey', 'unwrapKey']) {
          const orig = subtle[method];
          if (!orig) continue;
          subtle[method] = function (...args) {
            const stack = (new Error().stack || '').split('\\n').slice(1, 6).join(' | ');
            const result = orig.apply(this, args);
            Promise.all([Promise.all(args.map(describe)), result.then(describe, e => ({ error: String(e) }))])
              .then(([a, r]) => emit({ kind: 'crypto', method, args: a, result: r, stack }))
              .catch(() => {});
            return result;
          };
        }
      }
    })();
    """
}
