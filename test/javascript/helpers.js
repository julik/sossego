/**
 * Test helpers for sossego streams.
 *
 * `FakeEventSource` is a minimal stand-in for the browser's native
 * EventSource that can be driven manually in tests. Install it via
 * `installFakeEventSource()` before each test; restore via the
 * returned uninstall function.
 *
 * The fake records lifecycle calls so tests can assert "the connection
 * was closed" or "we reopened with Last-Event-ID=X" without poking
 * at internals.
 */

/**
 * The `data:` text of a frame: the envelope with `fmt` first, pretty-printed
 * as the server writes it and as EventSource hands it over.
 */
export function frameData(envelope

 ) {
  const { fmt = "ejson", evt, seq, sseq, head, sid, pld } = envelope
  return JSON.stringify({ fmt, evt, seq, sseq, head, sid, pld }, null, 2)
}

/** The `data:` text of a `sossego` frame. `seq` and `head` are cursors. */
export function eventData(
  evt,
  seq,
  sseq,
  head,
  pld,
  sid = "test:1:stream",
) {
  return frameData({ evt, seq, sseq, head, sid, pld })
}

/** The `data:` text of a `ping` frame. */
export function pingData(head, time = "2026-10-02T08:00:00Z") {
  return frameData({ evt: "ping", head, pld: { head, time } })
}

/**
 * The `data:` text of a `close` frame: a refusal without `position`, a
 * stored close with it.
 */
export function closeData(
  reason,
  position,
) {
  return frameData({ evt: "close", ...position, pld: { reason } })
}

export class FakeEventSource {
  static instances = []
  static lastInstance() {
    return FakeEventSource.instances[FakeEventSource.instances.length - 1]
  }

  static reset() {
    FakeEventSource.instances = []
  }

  // EventSource readyState values (per WHATWG)
  static CONNECTING = 0
  static OPEN = 1
  static CLOSED = 2

  url
  withCredentials
  readyState

  onopen = null
  onmessage = null
  onerror = null

  listeners = new Map()
  closed = false

  constructor(url, init) {
    this.url = url
    this.withCredentials = init?.withCredentials ?? false
    this.readyState = FakeEventSource.CONNECTING
    FakeEventSource.instances.push(this)
  }

  addEventListener(kind, listener) {
    const existing = this.listeners.get(kind) ?? []
    existing.push(listener)
    this.listeners.set(kind, existing)
  }

  removeEventListener(kind, listener) {
    const existing = this.listeners.get(kind) ?? []
    this.listeners.set(
      kind,
      existing.filter((l) => l !== listener),
    )
  }

  /** The SSE event names a listener was added for, in order. */
  listenedNames() {
    return [...this.listeners.keys()]
  }

  close() {
    this.readyState = FakeEventSource.CLOSED
    this.closed = true
  }

  isClosed() {
    return this.closed
  }

  /** Simulate the connection opening — fires `onopen`. */
  simulateOpen() {
    if (this.closed) return
    this.readyState = FakeEventSource.OPEN
    this.onopen?.call(this, new Event("open"))
  }

  /** Simulate a typed event (`event: kind` in the SSE frame). */
  simulateEvent(kind, id, data) {
    if (this.closed) return
    const listeners = this.listeners.get(kind) ?? []
    const event = new MessageEvent(kind, { data, lastEventId: id })
    listeners.forEach((l) => l(event))
  }

  /** Simulate an unnamed event (default `event: message`). */
  simulateMessage(id, data) {
    if (this.closed) return
    const event = new MessageEvent("message", { data, lastEventId: id })
    this.onmessage?.call(this, event)
  }

  /**
   * Simulate a network-level error. By default models a transient drop
   * — EventSource fires onerror but stays in CONNECTING and will
   * auto-reconnect itself.
   *
   * Pass `{ browserGivesUp: true }` to model the spec-defined "fail
   * the connection" path (non-2xx response, etc.): readyState
   * transitions to CLOSED before onerror fires, simulating the
   * browser deciding to stop.
   */
  simulateError({ browserGivesUp = false } = {}) {
    if (this.closed) return
    if (browserGivesUp) {
      this.readyState = FakeEventSource.CLOSED
    }
    this.onerror?.call(this, new Event("error"))
  }
}

/**
 * Install FakeEventSource as the global `EventSource`. Returns a
 * function that restores the original.
 */
export function installFakeEventSource() {
  const original = (globalThis).EventSource
  ;(globalThis).EventSource =
    FakeEventSource
  FakeEventSource.reset()
  return () => {
    ;(globalThis).EventSource = original
  }
}
