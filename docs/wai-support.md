# Supported WAI features

Everything below is verified end to end, by `scripts/smoke.mjs` and by `curl`
against `wrangler dev`.

This is a proof of concept and deliberately implements a small subset. Where a
faithful implementation was not possible, the handler fails loudly rather than
pretending.

## Request

| Field | Notes |
|---|---|
| `requestMethod` | |
| `rawPathInfo`, `pathInfo` | from `new URL(request.url).pathname` |
| `rawQueryString`, `queryString` | from `.search` |
| `requestHeaders` | names arrive lowercased, as the Fetch API normalizes them |
| `requestBody`, `requestBodyLength` | read fully into memory, delivered as one chunk |
| `isSecure` | `protocol === 'https:'` |
| `remoteHost` | recovered from `CF-Connecting-IP` when it parses as IPv4 |
| `httpVersion` | always `HTTP/1.1` — Workers does not expose the real version |
| `vault` | always empty |

`remoteHost` has to be a `SockAddr`, which Workers has no direct equivalent for.
An IPv6 `CF-Connecting-IP` — which is what `wrangler dev` sends for `::1` — falls
back to the `0.0.0.0:0` placeholder. The port is always 0.

## Response

| Constructor | Notes |
|---|---|
| `responseLBS`, `responseBuilder` (`ResponseBuilder`) | fully supported |
| `responseStream` (`ResponseStream`) | **buffered**: the body is accumulated in full before the `Response` is constructed |

Status codes and response headers pass through. `101`, `204`, `205` and `304` get
a `null` body, because `new Response(body, ...)` rejects a body for those.

Uncaught exceptions in the `Application` become a `500` carrying the exception
text, and are also written to `console.error`.

## Not supported

| Feature | Behaviour |
|---|---|
| `responseFile` | `501`, with an explanatory body — there is no filesystem |
| `responseRaw` | `501` — requires hijacking the connection |
| WebSocket | not attempted; would need Workers' `WebSocketPair` instead of WAI |
| True streaming | `responseStream` buffers, so no server-sent events and no progressive download |
| Streaming request bodies | the body is read in full before the `Application` runs |
| Trailers, HTTP/2 details, `Expect: 100-continue` | not represented |
| `HEAD` | not special-cased; the runtime drops the body |
| **Yesod sessions** | the `clientsession` shim has no cryptography — see [shims.md](shims.md) |
| Yesod file uploads, gzip middleware | link, but rest on shimmed code paths; untested |
| Persistent / PostgreSQL, D1 / KV / R2, Durable Objects, Cron / Queues | out of scope for this PoC |

## Where the limits come from

`responseStream` buffering is the one worth understanding. The handler runs the
`StreamingBody` to completion, accumulating into a `Builder`, and only then
constructs the `Response`. That is enough for Yesod's `respondSource` and for
anything that streams for convenience rather than for latency. It is not enough
for server-sent events or a long-lived download, both of which need the client to
see bytes before the producer finishes.

Doing it properly means building a `ReadableStream` on the JavaScript side and
having the Haskell writer push into it — feasible with the async JSFFI already in
use, but out of scope here.
