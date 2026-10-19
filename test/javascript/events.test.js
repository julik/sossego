import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"

import { createSossegoStream } from "@julik/sossego-client"
import { eventData, FakeEventSource, installFakeEventSource } from "@julik/sossego-testing"

const emit = (src, seq, eventName, body) =>
  src.simulateEvent("sossego", seq, eventData(eventName, seq, Number(seq), seq, body, "test:1:foo"))

async function flushMicrotasks() {
  for (let i = 0; i < 20; i++) await Promise.resolve()
}

describe("createSossegoStream events", () => {
  let uninstall

  beforeEach(() => {
    uninstall = installFakeEventSource()
  })

  afterEach(() => {
    uninstall()
  })

  const open = (opts) => {
    const stream = createSossegoStream({ url: "/x", ...opts })
    const src = FakeEventSource.lastInstance()
    src.simulateOpen()
    return { stream, src }
  }

  it("calls the handler named by the event with its payload and the event", async () => {
    const seen = []
    const { src } = open({
      events: {
        email_added: (body, event) => seen.push(`added ${body.id} at ${event.seq}`),
        email_archived: (body) => seen.push(`archived ${body.id}`),
      },
    })

    emit(src, "1", "email_added", { id: 7 })
    emit(src, "2", "email_archived", { id: 8 })
    await flushMicrotasks()

    expect(seen).toEqual(["added 7 at 1", "archived 8"])
  })

  it("ignores events with no handler, and names that only Object.prototype has", async () => {
    const onError = vi.fn()
    const handler = vi.fn()
    const { src } = open({ events: { known: handler }, onError })

    emit(src, "1", "unknown", {})
    emit(src, "2", "constructor", {})
    emit(src, "3", "toString", {})
    await flushMicrotasks()

    expect(handler).not.toHaveBeenCalled()
    expect(onError).not.toHaveBeenCalled()
  })

  it("calls onEvent for every event, before the named handler", async () => {
    const order = []
    const { src } = open({
      onEvent: (event) => order.push(`any ${event.eventName}`),
      events: { a: () => order.push("a") },
    })

    emit(src, "1", "a", {})
    emit(src, "2", "b", {})
    await flushMicrotasks()

    expect(order).toEqual(["any a", "a", "any b"])
  })

  it("finds the handlers of the events object as it is when each event arrives", async () => {
    const events = {}
    const late = vi.fn()
    const { src } = open({ events })

    emit(src, "1", "x", 1)
    await flushMicrotasks()
    events.x = late
    emit(src, "2", "x", 2)
    await flushMicrotasks()

    expect(late).toHaveBeenCalledExactlyOnceWith(2, expect.objectContaining({ seq: "2" }))
  })

  it("reports a throwing or rejecting handler to onError and keeps going", async () => {
    const onError = vi.fn()
    const after = vi.fn()
    const { src } = open({
      onError,
      events: {
        boom: () => {
          throw new Error("kaboom")
        },
        later: async () => {
          throw new Error("later kaboom")
        },
        after,
      },
    })

    emit(src, "1", "boom", {})
    emit(src, "2", "later", {})
    emit(src, "3", "after", {})
    await flushMicrotasks()

    expect(onError.mock.calls.map(([err]) => err.message)).toEqual(["kaboom", "later kaboom"])
    expect(after).toHaveBeenCalledOnce()
  })

  it("a throwing onEvent does not keep the named handler from running", async () => {
    const handler = vi.fn()
    const { src } = open({
      onError: () => {},
      onEvent: () => {
        throw new Error("nope")
      },
      events: { x: handler },
    })

    emit(src, "1", "x", {})
    await flushMicrotasks()

    expect(handler).toHaveBeenCalledOnce()
  })

  it("streams do not share handlers", async () => {
    const handler = vi.fn()
    open({ events: { x: handler } })
    const { src } = open({})

    emit(src, "1", "x", {})
    await flushMicrotasks()

    expect(handler).not.toHaveBeenCalled()
  })
})
