import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { renderHook, act } from "@testing-library/react"

import { useSossegoStream } from "@julik/sossego-react"

import { closeData, eventData, FakeEventSource, installFakeEventSource } from "@julik/sossego-testing"

// Build the `data:` text of a `sossego` frame (the SSE event name is
// "sossego"; the application's name rides inside the envelope as `evt`).
function envelopeWire(opts






 ) {
  return eventData(
    opts.eventName ?? "entity",
    opts.seq,
    opts.sseq ?? 1,
    opts.head ?? opts.seq,
    opts.body ?? {},
    opts.streamId ?? "test:1:foo",
  )
}

function emitSossego(src, opts) {
  src.simulateEvent("sossego", opts.seq, envelopeWire(opts))
}

// Drain microtasks so queue.push tasks resolve.
async function flushMicrotasks() {
  for (let i = 0; i < 20; i++) await Promise.resolve()
}

describe("useSossegoStream — lifecycle and event delivery", () => {
  let uninstall

  beforeEach(() => {
    uninstall = installFakeEventSource()
  })

  afterEach(() => {
    uninstall()
  })

  it("opens an EventSource at the given URL with credentials", () => {
    const onEvent = vi.fn()
    renderHook(() => useSossegoStream({ url: "/sync/events", onEvent }))

    const source = FakeEventSource.lastInstance()
    expect(source).toBeDefined()
    expect(source .url).toBe("/sync/events")
    expect(source .withCredentials).toBe(true)
  })

  it("transitions through connecting → open on EventSource open", () => {
    const onEvent = vi.fn()
    const { result } = renderHook(() =>
      useSossegoStream({ url: "/sync/events", onEvent }),
    )

    expect(result.current.status).toBe("connecting")

    act(() => {
      FakeEventSource.lastInstance() .simulateOpen()
    })

    expect(result.current.status).toBe("open")
  })

  it("decodes the envelope and dispatches with sossego-level fields", async () => {
    const onEvent = vi.fn ()
    renderHook(() => useSossegoStream({ url: "/sync/events", onEvent }))

    await act(async () => {
      const src = FakeEventSource.lastInstance()
      src.simulateOpen()
      emitSossego(src, {
        eventName: "entity",
        seq: "12345",
        sseq: 9,
        head: "17168",
        streamId: "user:1:mail_messages",
        body: { id: 7, in_inbox: true },
      })
      await flushMicrotasks()
    })

    expect(onEvent).toHaveBeenCalledTimes(1)
    expect(onEvent).toHaveBeenCalledWith({
      id: "12345",
      eventName: "entity",
      seq: "12345",
      sseq: 9,
      head: "17168",
      streamId: "user:1:mail_messages",
      payload: { id: 7, in_inbox: true },
    })
  })

  it("tracks lastEventId from incoming events", async () => {
    const { result } = renderHook(() =>
      useSossegoStream({ url: "/sync/events", onEvent: vi.fn() }),
    )

    await act(async () => {
      const src = FakeEventSource.lastInstance()
      src.simulateOpen()
      emitSossego(src, { seq: "12345" })
      await flushMicrotasks()
    })

    expect(result.current.lastEventId).toBe("12345")
  })

  it("sends the lastEventId it is given as the cursor of the first connect", () => {
    renderHook(() => useSossegoStream({ url: "/sync/events", lastEventId: "41", onEvent: vi.fn() }))

    expect(FakeEventSource.lastInstance() .url).toBe("/sync/events?last_event_id=41")
  })

  it("closes EventSource and fires onClose with the reason and seq on a stored close", async () => {
    const onClose = vi.fn()
    const onEvent = vi.fn()
    const { result } = renderHook(() =>
      useSossegoStream({ url: "/sync/events", onEvent, onClose }),
    )

    await act(async () => {
      const src = FakeEventSource.lastInstance()
      src.simulateOpen()
      src.simulateEvent("close", "99", closeData("server_recycle", { seq: "99", sseq: 4, head: "99", sid: "test:1:foo" }))
      await flushMicrotasks()
    })

    expect(onEvent).not.toHaveBeenCalled()
    expect(onClose).toHaveBeenCalledWith("server_recycle", "99")
    expect(FakeEventSource.lastInstance() .isClosed()).toBe(true)
    expect(result.current.status).toBe("closed")
  })

  it("treats no application event name as terminal", async () => {
    const onClose = vi.fn()
    const onEvent = vi.fn()
    renderHook(() => useSossegoStream({ url: "/chat/messages/42/stream", onEvent, onClose }))

    await act(async () => {
      const src = FakeEventSource.lastInstance()
      src.simulateOpen()
      emitSossego(src, { eventName: "message_complete", seq: "5", body: { final: true } })
      await flushMicrotasks()
    })

    expect(onEvent).toHaveBeenCalledWith(expect.objectContaining({ eventName: "message_complete" }))
    expect(onClose).not.toHaveBeenCalled()
    expect(FakeEventSource.lastInstance() .isClosed()).toBe(false)
  })

  it("transitions to reconnecting on EventSource error", () => {
    const onError = vi.fn()
    const { result } = renderHook(() =>
      useSossegoStream({ url: "/sync/events", onEvent: vi.fn(), onError }),
    )

    act(() => {
      const src = FakeEventSource.lastInstance()
      src.simulateOpen()
      src.simulateError()
    })

    expect(onError).toHaveBeenCalled()
    expect(result.current.status).toBe("reconnecting")
  })

  it("calls onError on decode failure but stays open for the next event", async () => {
    const onError = vi.fn()
    const onEvent = vi.fn()
    renderHook(() =>
      useSossegoStream({ url: "/sync/events", onEvent, onError }),
    )

    act(() => {
      const src = FakeEventSource.lastInstance()
      src.simulateOpen()
      // Malformed JSON in a sossego envelope — decoder throws, onError
      // fires, stream stays open.
      src.simulateEvent("sossego", "1", "{ not json")
    })
    await flushMicrotasks()

    expect(onError).toHaveBeenCalled()
    expect(onEvent).not.toHaveBeenCalled()
  })

  it("force-reconnects after STALL_THRESHOLD_MS of silence", () => {
    vi.useFakeTimers()
    try {
      renderHook(() => useSossegoStream({ url: "/sync/events", onEvent: vi.fn() }))

      const firstSource = FakeEventSource.lastInstance()
      act(() => firstSource.simulateOpen())

      // Stall fires after the threshold and closes the pipe, but the
      // reconnect is deferred by the idle backoff (2s).
      act(() => vi.advanceTimersByTime(25_000))
      expect(firstSource.isClosed()).toBe(true)
      expect(FakeEventSource.instances.length).toBe(1)

      // After the idle backoff elapses, a fresh connection opens.
      act(() => vi.advanceTimersByTime(2_000))
      expect(FakeEventSource.instances.length).toBeGreaterThanOrEqual(2)
    } finally {
      vi.useRealTimers()
    }
  })

  it("closes EventSource on unmount", () => {
    const { unmount } = renderHook(() =>
      useSossegoStream({ url: "/sync/events", onEvent: vi.fn() }),
    )

    const source = FakeEventSource.lastInstance()
    act(() => source.simulateOpen())
    unmount()

    expect(source.isClosed()).toBe(true)
  })

  it("does not open an EventSource when enabled=false", () => {
    const { result } = renderHook(() =>
      useSossegoStream({ url: "/sync/events", onEvent: vi.fn(), enabled: false }),
    )

    expect(FakeEventSource.instances.length).toBe(0)
    expect(result.current.status).toBe("closed")
  })

  it("uses the latest onEvent callback without restarting the connection", async () => {
    const firstCallback = vi.fn()
    const secondCallback = vi.fn()

    const { rerender } = renderHook(
      ({ cb }) =>
        useSossegoStream({ url: "/sync/events", onEvent: cb }),
      { initialProps: { cb: firstCallback } },
    )

    const source = FakeEventSource.lastInstance()
    await act(async () => {
      source.simulateOpen()
      emitSossego(source, { seq: "1" })
      await flushMicrotasks()
    })

    expect(firstCallback).toHaveBeenCalledTimes(1)
    expect(secondCallback).toHaveBeenCalledTimes(0)

    rerender({ cb: secondCallback })

    await act(async () => {
      emitSossego(source, { seq: "2", sseq: 2 })
      await flushMicrotasks()
    })

    expect(firstCallback).toHaveBeenCalledTimes(1)
    expect(secondCallback).toHaveBeenCalledTimes(1)
    expect(FakeEventSource.instances.length).toBe(1)
  })

  it("calls the events of the latest render, without reconnecting", async () => {
    const first = vi.fn()
    const second = vi.fn()
    const { rerender } = renderHook(({ handler }) => useSossegoStream({ url: "/sync/events", events: { changed: handler } }), {
      initialProps: { handler: first },
    })
    const source = FakeEventSource.lastInstance()
    act(() => source.simulateOpen())

    rerender({ handler: second })
    emitSossego(source, { seq: "1", eventName: "changed", body: { id: 3 } })
    await act(flushMicrotasks)

    expect(first).not.toHaveBeenCalled()
    expect(second).toHaveBeenCalledWith({ id: 3 }, expect.objectContaining({ eventName: "changed" }))
    expect(FakeEventSource.instances.length).toBe(1)
  })
})
