# http-client on Workers

`http-client-cloudflare` (`haskell/http-client-cloudflare`) is an `http-client`
`Manager` that sends requests with the Workers `fetch` API. Workers has no
sockets, so the managers that ship with `http-client` cannot connect; anything
built on `http-client` (yesod-auth-oauth2, `Network.HTTP.Simple`, ...) needs this
one to reach the network.

## Usage

```haskell
import Network.HTTP.Client
import Network.HTTP.Client.Cloudflare (newFetchManager)

main :: IO ()
main = do
  manager <- newFetchManager
  res <- httpLbs "https://example.com/" manager
  print (responseStatus res)
```

`fetchManagerSettings` is the same thing as `ManagerSettings`, for when you want
to adjust a field (say `managerResponseTimeout`) before calling `newManager`.
Do not override the proxy settings; see below.

## How it works

`http-client` writes a complete HTTP/1.1 request to a connection and then reads
the response. The bridge supplies a connection that:

1. buffers everything written to it;
2. on the first read, parses the buffered request, builds a `fetch` call from it
   (scheme and host from the connection, the rest from the request), and waits
   for the whole response body;
3. renders the result as HTTP/1.1 bytes with `Connection: close` and hands them
   to `http-client`, then reports EOF.

TLS is `fetch`'s job, so no `tls` package or certificate store is involved. The
parsing and rendering live in `Network.HTTP.Client.Cloudflare.Wire`, which is
pure Haskell and has no JavaScript in it.

## Behaviour

| Topic | What happens |
| --- | --- |
| Redirects | `fetch` is called with `redirect: "manual"`; `http-client` follows redirects itself, with its own count and cookie handling. |
| Content-Encoding | `fetch` decodes the body, so the header is dropped before `http-client` sees it (otherwise it would decode again). |
| Content-Length | Recomputed from the buffered body. `HEAD` responses and 1xx, 204 and 304 responses keep the upstream value and get none if upstream sent none. |
| Transfer-Encoding, Connection | Dropped from the response; `Connection: close` is added. |
| Request headers not forwarded | `Host`, `Content-Length`, `Transfer-Encoding`, `Connection`, `Keep-Alive`, `Accept-Encoding`, `Expect`, `TE`, `Upgrade`, `Proxy-Connection`. `fetch` sets them itself. |
| Request target | Percent-encoded for the URL: bytes of 0x80 or above, bytes below 0x21, `#` and `\`. Existing escapes are kept. The URL parser then removes `.` and `..` segments, so `/a/../b` arrives as `/b`. |
| Request body | Content-Length and chunked bodies are both accepted and reassembled. |
| Bodies | Both are buffered completely in memory. |
| Proxies | Not supported. |

## Errors

- A `fetch` that yields no usable response, or a response body that fails part
  way through reading, is `HttpExceptionRequest _ (ConnectionFailure _)`.
- A request the bridge cannot send is `HttpExceptionRequest _ (InternalException _)`
  with the reason in the message: a malformed request, headers over 64 KiB, a
  body over 32 MiB, or `Expect: 100-continue`.
- `Expect: 100-continue` (exactly that value) is rejected, because `fetch` sends
  the whole request at once. Any other `Expect` value is not forwarded, and the
  request is sent.
- A configured proxy, for http and https URLs alike, is refused with
  `InternalException` "http-client-cloudflare does not support proxies".
  Environment proxy variables are ignored.

## Caveats

- The `Host` header is not forwarded: `fetch` sets it from the URL. Connecting to
  an IP address with a custom `Host` therefore reaches that IP's default host.
- A `GET` or `HEAD` with a body is rejected by `fetch` (a `TypeError`), which
  surfaces as `ConnectionFailure`.
- `managerResponseTimeout` covers the whole download, because the first read
  fetches the entire body.
- Request and response bodies are both held in memory, so they count against the
  Workers 128 MB limit (the request side is capped at 32 MiB).
- Do not override the proxy settings. A request whose target is not in origin
  form (what a proxied request looks like) is rejected.

## Not supported

- Streaming of request or response bodies.
- Connection reuse: each request is one `fetch`.
- Proxies.
- Workers `cf` request options.

## Tests

`test/fetch-manager.test.mjs` runs the Manager inside `test-vendor` (route
`/http`) against a local upstream; `scripts/check-wrangler.mjs` repeats six of
those checks on workerd. See [development.md](development.md).
