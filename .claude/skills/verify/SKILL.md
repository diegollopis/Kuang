---
name: verify
description: How to verify Kuang changes end-to-end (library surface — consume the package from a scratch executable against a local server).
---

# Verifying Kuang

Kuang is a library; its surface is the package boundary. Verify by consuming
`import Kuang` from a scratch executable package hitting a real local server —
not by re-running `swift test`.

## Recipe

1. Scratch executable package (in a temp dir) with a path dependency:
   `.package(path: "/Users/matheus.tavares/Desktop/Kuang")`, product `Kuang`,
   `platforms: [.macOS(.v12)]`, swift-tools 5.10.
2. Local server: a small Python `http.server` script works. For streaming
   endpoints, send `Content-Type: text/event-stream` with
   `Transfer-Encoding: chunked` (HTTP/1.1 + hand-rolled chunk framing:
   `f"{len(frame):x}\r\n" + frame + b"\r\n"`, terminated by `0\r\n\r\n`), and
   `time.sleep` between events — the sleep is what proves progressive delivery.
3. In the demo, timestamp each received token (`ms since start`); spacing that
   matches the server's sleep proves streaming, all-at-once proves buffering.
4. Worthwhile probes: non-2xx handshake (expect the mapped `NetworkError` with
   the parsed server message), connection refused (expect `transportFailure`),
   the `[DONE]` terminator on the decoded stream.

## Gotchas

- `swift run` inside the scratch package builds Kuang from the path dependency
  automatically; no need to build Kuang first.
- Kill the Python server afterwards (`pkill -f <script>.py`).
