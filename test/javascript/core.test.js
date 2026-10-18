import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"

import { createSossegoStream } from "@sossego/client"
import { registerPayloadDecoder } from "@sossego/client"
import { closeData, eventData, FakeEventSource, frameData, installFakeEventSource, pingData } from "@sossego/testing"

// Build the `data:` text of a `sossego` frame matching the Ruby
// StreamingBody output. The application's name rides in the envelope as
// `evt`; the SSE event name is always "sossego".
function envelopeWire(opts






 ) {
  return eventData(
    opts.eventName ?? "entity",
    opts.seq,
    opts.sseq ?? Number(opts.seq),
    opts.head ?? opts.seq,
    opts.body ?? {},
    opts.streamId ?? "test:1:foo",
  )
}

// Helper to emit a sossego frame through the FakeEventSource.
function emitSossego(src, opts) {
  src.simulateEvent("sossego", opts.seq, envelopeWire(opts))
}

// The endpoint's refusal: a `close` frame with no `id:` line and no position.
function emitRefusal(src, reason) {
  src.simulateEvent("close", "", closeData(reason))
}

// A close stored with Stream#publish_close: a `close` frame with its position.
function emitStoredClose(src, seq, reason) {
  src.simulateEvent("close", seq, closeData(reason, { seq, sseq: Number(seq), head: seq, sid: "test:1:foo" }))
}

// Drain microtasks so queue.push tasks resolve. Each queued task adds
// one or two microtask hops (decode promise + onEvent), so flush
// generously — the cost is just a few `await Promise.resolve()` calls.
async function flushMicrotasks() {
  for (let i = 0; i < 20; i++) await Promise.resolve()
}

describe("createSossegoStream — framework-agnostic core", () => {
  let uninstall

  beforeEach(() => {
    uninstall = installFakeEventSource()
  })

  afterEach(() => {
    uninstall()
  })

  it("opens an EventSource and dispatches decoded events", async () => {
    const onEvent = vi.fn ()
    createSossegoStream({ url: "/x", onEvent })

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    emitSossego(src, { seq: "1", sseq: 1, head: "5", streamId: "user:1:m", body: { id: 7 } })

    await flushMicrotasks()

    expect(onEvent).toHaveBeenCalledWith({
      id: "1",
      eventName: "entity",
      seq: "1",
      sseq: 1,
      head: "5",
      streamId: "user:1:m",
      payload: { id: 7 },
    })
  })

  it("reports a sossego frame whose cursor is not a string, and does not deliver it", async () => {
    const onEvent = vi.fn()
    const onError = vi.fn()
    createSossegoStream({ url: "/x", onEvent, onError })

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    src.simulateEvent("sossego", "1", `{"fmt":"ejson","evt":"entity","seq":1,"sseq":1,"head":1,"sid":"s:1","pld":{}}`)
    await flushMicrotasks()

    expect(onEvent).not.toHaveBeenCalled()
    expect(onError).toHaveBeenCalledWith(expect.objectContaining({ message: "sossego frame without a position: entity" }))
  })

  it("sends the starting event id as the cursor on the first connect", () => {
    createSossegoStream({ url: "/x?account=1", lastEventId: "41", onEvent: vi.fn() })

    expect(FakeEventSource.lastInstance() .url).toBe("/x?account=1&last_event_id=41")
  })

  it("listens to exactly the three substrate names", () => {
    createSossegoStream({ url: "/x", onEvent: vi.fn() })

    expect(FakeEventSource.lastInstance() .listenedNames()).toEqual(["sossego", "ping", "close"])
  })

  it("calls onClose with a refusal's reason and a null seq, never onEvent, and stops", async () => {
    const onEvent = vi.fn ()
    const onClose = vi.fn()
    createSossegoStream({ url: "/x", onEvent, onClose })

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    emitRefusal(src, "over_budget")
    await flushMicrotasks()

    expect(onEvent).not.toHaveBeenCalled()
    expect(onClose).toHaveBeenCalledExactlyOnceWith("over_budget", null)
    expect(src.isClosed()).toBe(true)
  })

  it("delivers a close after the sossego frames queued before it, with its reason and seq", async () => {
    const order = []
    let release
    const blocker = new Promise ((r) => {
      release = r
    })
    const states = []
    createSossegoStream({
      url: "/x",
      onEvent: async (e) => {
        if (e.seq === "1") await blocker
        order.push(`event ${e.seq}`)
      },
      onClose: (reason, seq) => void order.push(`close ${reason} ${seq}`),
      onStateChange: (s) => states.push(s),
    })

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    emitSossego(src, { seq: "1" })
    emitSossego(src, { seq: "2" })
    emitStoredClose(src, "3", "finished")
    await flushMicrotasks()
    expect(order).toEqual([])
    expect(src.isClosed()).toBe(false)

    release()
    await flushMicrotasks()

    expect(order).toEqual(["event 1", "event 2", "close finished 3"])
    expect(src.isClosed()).toBe(true)
    expect(states.at(-1)).toEqual({ status: "closed", lastEventId: "3" })
  })

  it("does not reconnect after a close, and cancels a reopen that was pending", async () => {
    vi.useFakeTimers()
    try {
      createSossegoStream({ url: "/x", onEvent: vi.fn() })
      const src = FakeEventSource.lastInstance()
      src.simulateOpen()
      emitRefusal(src, "flag_off")
      // The browser gives up on the ended response before the close is handled.
      src.simulateError({ browserGivesUp: true })
      await vi.advanceTimersByTimeAsync(120_000)

      expect(FakeEventSource.instances.length).toBe(1)
    } finally {
      vi.useRealTimers()
    }
  })

  it("reports a frame that does not decode through onError and goes on", async () => {
    const onEvent = vi.fn ()
    const onError = vi.fn()
    createSossegoStream({ url: "/x", onEvent, onError })

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    src.simulateEvent("sossego", "1", "json:{}")
    emitSossego(src, { seq: "2" })
    await flushMicrotasks()

    expect(onError).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({ name: "SossegoDecodeError" }))
    expect(onEvent).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({ seq: "2" }))
  })

  it("leaves the last event id alone on a refusal", async () => {
    const states = []
    createSossegoStream({ url: "/x", onEvent: vi.fn(), onStateChange: (s) => states.push(s) })

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    emitSossego(src, { seq: "42" })
    emitRefusal(src, "flag_off")
    await flushMicrotasks()

    expect(states[states.length - 1]).toEqual({ status: "closed", lastEventId: "42" })
  })

  it("emits state transitions through onStateChange", () => {
    const states = []
    createSossegoStream({
      url: "/x",
      onEvent: vi.fn(),
      onStateChange: (s) => states.push(s.status),
    })
    FakeEventSource.lastInstance() .simulateOpen()

    expect(states).toContain("connecting")
    expect(states).toContain("open")
  })

  it("close() shuts down EventSource and emits closed state", () => {
    const states = []
    const handle = createSossegoStream({
      url: "/x",
      onEvent: vi.fn(),
      onStateChange: (s) => states.push(s.status),
    })
    FakeEventSource.lastInstance() .simulateOpen()
    handle.close()

    expect(FakeEventSource.lastInstance() .isClosed()).toBe(true)
    expect(states[states.length - 1]).toBe("closed")
  })
})

describe("createSossegoStream — sequential decode pipeline", () => {
  let uninstall
  beforeEach(() => {
    uninstall = installFakeEventSource()
  })
  afterEach(() => {
    uninstall()
  })

  it("releases events to the consumer in the order they arrived", async () => {
    const seen = []
    createSossegoStream({
      url: "/x",
      onEvent: (e) => {
        seen.push(e.seq)
      },
    })

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    emitSossego(src, { seq: "1" })
    emitSossego(src, { seq: "2" })
    emitSossego(src, { seq: "3" })

    await flushMicrotasks()

    expect(seen).toEqual(["1", "2", "3"])
  })

  it("waits for an async handler to resolve before the next event runs", async () => {
    const order = []
    let resolveFirst
    const blocker = new Promise ((r) => {
      resolveFirst = r
    })

    createSossegoStream({
      url: "/x",
      onEvent: async (e) => {
        order.push(`start ${e.seq}`)
        if (e.seq === "1") await blocker
        order.push(`end ${e.seq}`)
      },
    })

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    emitSossego(src, { seq: "1" })
    emitSossego(src, { seq: "2" })

    await flushMicrotasks()
    expect(order).toEqual(["start 1"])

    resolveFirst()
    await flushMicrotasks()

    expect(order).toEqual(["start 1", "end 1", "start 2", "end 2"])
  })

  it("a handler error doesn't break the queue", async () => {
    const order = []
    const onError = vi.fn()
    createSossegoStream({
      url: "/x",
      onEvent: async (e) => {
        if (e.seq === "1") throw new Error("boom")
        order.push(e.seq)
      },
      onError,
    })

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    emitSossego(src, { seq: "1" })
    emitSossego(src, { seq: "2" })

    await flushMicrotasks()

    expect(onError).toHaveBeenCalled()
    expect(order).toEqual(["2"])
  })

  it("reports a connection error after the frames received before it", async () => {
    const order = []
    createSossegoStream({
      url: "/x",
      onEvent: (e) => void order.push(`event ${e.seq}`),
      onError: () => void order.push("error"),
    })

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    emitSossego(src, { seq: "1" })
    emitSossego(src, { seq: "2" })
    // The response ends before the frames have been decoded.
    src.simulateError()
    expect(order).toEqual([])

    await flushMicrotasks()

    expect(order).toEqual(["event 1", "event 2", "error"])
  })

  it("does not report the error that ends a response whose close frame is still in the queue", async () => {
    const onError = vi.fn()
    const onClose = vi.fn()
    const statuses = []
    createSossegoStream({
      url: "/x",
      onEvent: () => {},
      onError,
      onClose,
      onStateChange: ({ status }) => void statuses.push(status),
    })

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    emitRefusal(src, "over_budget")
    src.simulateError()

    await flushMicrotasks()

    expect(onClose).toHaveBeenCalledExactlyOnceWith("over_budget", null)
    expect(onError).not.toHaveBeenCalled()
    expect(statuses.at(-1)).toBe("closed")
    expect(statuses).not.toContain("reconnecting")
    expect(FakeEventSource.instances.length).toBe(1)
  })

  it("hands a ping to onPing while an event handler is still running: pings bypass the queue", async () => {
    const order = []
    let release
    const blocker = new Promise ((r) => {
      release = r
    })
    createSossegoStream({
      url: "/x",
      onEvent: async (e) => {
        await blocker
        order.push(`event ${e.seq}`)
      },
      onPing: (ping) => void order.push(`ping ${ping.head}`),
    })

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    emitSossego(src, { seq: "1" })
    src.simulateEvent("ping", "", pingData("7"))
    await flushMicrotasks()

    expect(order).toEqual(["ping 7"])

    release()
    await flushMicrotasks()
    expect(order).toEqual(["ping 7", "event 1"])
  })

  it("handles connection errors at once while no frame is in flight", () => {
    const onError = vi.fn()
    createSossegoStream({ url: "/x", onEvent: () => {}, onError })

    const src = FakeEventSource.lastInstance()
    src.simulateError()
    src.simulateError()

    expect(onError).toHaveBeenCalledTimes(2)
  })
})

describe("createSossegoStream — server-restart resilience", () => {
  let uninstall
  let random
  beforeEach(() => {
    uninstall = installFakeEventSource()
    vi.useFakeTimers()
    // Jitter adds up to one more base delay; 0 pins each reopen to its base.
    random = vi.spyOn(Math, "random").mockReturnValue(0)
  })
  afterEach(() => {
    uninstall()
    vi.useRealTimers()
    random.mockRestore()
  })

  // Fail the newest connection and report how long the reopen took.
  function failAndMeasureReopenMs() {
    const before = FakeEventSource.instances.length
    FakeEventSource.lastInstance() .simulateError({ browserGivesUp: true })
    let waited = 0
    while (FakeEventSource.instances.length === before) {
      vi.advanceTimersByTime(500)
      waited += 500
    }
    return waited
  }

  it("backs off failed reopens from 3s to 60s and returns to 3s after a delivered frame", () => {
    createSossegoStream({ url: "/sync", onEvent: vi.fn() })

    const delays = Array.from({ length: 7 }, failAndMeasureReopenMs)
    expect(delays).toEqual([3_000, 6_000, 12_000, 24_000, 48_000, 60_000, 60_000])

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    src.simulateEvent("ping", "", pingData("0"))

    expect(failAndMeasureReopenMs()).toBe(3_000)
  })

  it("returns to 3s after a delivered event", async () => {
    createSossegoStream({ url: "/sync", onEvent: vi.fn() })
    failAndMeasureReopenMs()
    failAndMeasureReopenMs()

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    emitSossego(src, { seq: "1" })
    await vi.advanceTimersByTimeAsync(0)

    expect(failAndMeasureReopenMs()).toBe(3_000)
  })

  it("adds jitter to the reopen delay", () => {
    random.mockReturnValue(0.5)
    createSossegoStream({ url: "/sync", onEvent: vi.fn() })

    expect(failAndMeasureReopenMs()).toBe(4_500)
  })

  it("manually reopens when the browser gives up (readyState=CLOSED)", () => {
    createSossegoStream({ url: "/sync", onEvent: vi.fn() })

    const first = FakeEventSource.lastInstance()
    first.simulateOpen()
    expect(FakeEventSource.instances.length).toBe(1)

    first.simulateError({ browserGivesUp: true })
    vi.advanceTimersByTime(3_000)

    expect(FakeEventSource.instances.length).toBe(2)
  })

  it("does NOT manually reopen on transient drops (browser auto-reconnects)", () => {
    createSossegoStream({ url: "/sync", onEvent: vi.fn() })

    const first = FakeEventSource.lastInstance()
    first.simulateOpen()
    first.simulateError()  // no browserGivesUp — readyState stays CONNECTING

    vi.advanceTimersByTime(5_000)
    expect(FakeEventSource.instances.length).toBe(1)
  })

  it("appends last_event_id to the URL on manual reopen so we resume", async () => {
    createSossegoStream({ url: "/sync", onEvent: vi.fn() })

    const first = FakeEventSource.lastInstance()
    first.simulateOpen()
    emitSossego(first, { seq: "42" })
    await vi.advanceTimersByTimeAsync(0)  // let queue process the event
    first.simulateError({ browserGivesUp: true })

    await vi.advanceTimersByTimeAsync(3_000)

    const second = FakeEventSource.lastInstance()
    expect(second.url).toContain("last_event_id=42")
  })
})

describe("createSossegoStream — idle-pipe reconnect backoff", () => {
  let uninstall
  beforeEach(() => {
    uninstall = installFakeEventSource()
    vi.useFakeTimers()
  })
  afterEach(() => {
    uninstall()
    vi.useRealTimers()
  })

  it("waits IDLE_RECONNECT_DELAY_MS before reconnecting a stalled pipe", () => {
    createSossegoStream({ url: "/sync", onEvent: vi.fn(), stallThresholdMs: 25_000 })

    const first = FakeEventSource.lastInstance()
    first.simulateOpen()
    expect(FakeEventSource.instances.length).toBe(1)

    // No event or ping arrives → the stall timer fires and closes the pipe.
    vi.advanceTimersByTime(25_000)
    expect(first.readyState).toBe(FakeEventSource.CLOSED)
    // ...but we do NOT reconnect on the spot.
    expect(FakeEventSource.instances.length).toBe(1)

    // Just before the backoff elapses: still no reconnect.
    vi.advanceTimersByTime(1_999)
    expect(FakeEventSource.instances.length).toBe(1)

    // After the 2s backoff: a fresh connection opens.
    vi.advanceTimersByTime(1)
    expect(FakeEventSource.instances.length).toBe(2)
  })

  it("cancels a pending idle reconnect when the consumer closes", () => {
    const handle = createSossegoStream({ url: "/sync", onEvent: vi.fn(), stallThresholdMs: 25_000 })

    const first = FakeEventSource.lastInstance()
    first.simulateOpen()
    vi.advanceTimersByTime(25_000)  // stall → close + schedule reconnect

    handle.close()
    vi.advanceTimersByTime(5_000)   // backoff window passes

    // No reconnect: the consumer close cancelled the pending timer.
    expect(FakeEventSource.instances.length).toBe(1)
  })
})

describe("createSossegoStream — asynchronous payload decoders", () => {
  let uninstall
  beforeEach(() => {
    uninstall = installFakeEventSource()
  })
  afterEach(() => {
    vi.useRealTimers()
    uninstall()
  })

  it("delivers async-decoded events in wire order, then the close", async () => {
    // The first frame decodes slower than the second: wire order must still win.
    registerPayloadDecoder("test-async", async (payload) => {
      const { n, delayMs } = payload
      await new Promise((resolve) => setTimeout(resolve, delayMs))
      return { decoded: n }
    })
    const order = []
    const closed = new Promise ((resolve) => {
      createSossegoStream({
        url: "/x",
        onEvent: (e) => void order.push(`event ${e.seq} ${JSON.stringify(e.payload)}`),
        onClose: (reason, seq) => {
          order.push(`close ${reason} ${seq}`)
          resolve()
        },
      })
    })

    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    const frame = (seq, sseq, pld) =>
      frameData({ fmt: "test-async", evt: "progress", seq, sseq, head: "3", sid: "test:1:foo", pld })
    src.simulateEvent("sossego", "1", frame("1", 1, { n: 1, delayMs: 20 }))
    src.simulateEvent("sossego", "2", frame("2", 2, { n: 2, delayMs: 0 }))
    emitStoredClose(src, "3", "finished")
    await closed

    expect(order).toEqual(['event 1 {"decoded":1}', 'event 2 {"decoded":2}', "close finished 3"])
  })

  it("resets the stall timer when a ping arrives, before its async payload decodes", async () => {
    vi.useFakeTimers()
    let release = () => {}
    const gate = new Promise ((resolve) => {
      release = resolve
    })
    registerPayloadDecoder("test-async-gated", async (payload) => {
      await gate
      return payload
    })
    const onPing = vi.fn()
    createSossegoStream({ url: "/x", onEvent: vi.fn(), onPing, stallThresholdMs: 1_000 })
    const src = FakeEventSource.lastInstance()
    src.simulateOpen()

    vi.advanceTimersByTime(900)
    src.simulateEvent("ping", "", frameData({ fmt: "test-async-gated", evt: "ping", head: "5", pld: { head: "5", time: "t" } }))
    // Past the threshold counted from the open, inside it counted from the ping.
    vi.advanceTimersByTime(900)

    expect(src.isClosed()).toBe(false)
    expect(onPing).not.toHaveBeenCalled()

    release()
    await vi.advanceTimersByTimeAsync(0)
    expect(onPing).toHaveBeenCalledExactlyOnceWith({ head: "5", time: "t" })
  })
})
