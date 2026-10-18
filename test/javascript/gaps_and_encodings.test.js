import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { gzipSync } from "node:zlib"

import { createSossegoStream, decodeFrame } from "sossego"
import { eventData, FakeEventSource, frameData, installFakeEventSource } from "./helpers.js"

async function flushMicrotasks() {
  for (let i = 0; i < 20; i++) await Promise.resolve()
}

describe("gap detection by sseq", () => {
  let uninstall

  beforeEach(() => {
    uninstall = installFakeEventSource()
  })

  afterEach(() => uninstall())

  const emit = (src, seq, sseq) => src.simulateEvent("sossego", seq, eventData("tick", seq, sseq, seq, {}))

  it("does not report the first event as a gap", async () => {
    const onGap = vi.fn()
    createSossegoStream({ url: "/x", onEvent: () => {}, onGap })
    emit(FakeEventSource.lastInstance(), "40", 17)
    await flushMicrotasks()

    expect(onGap).not.toHaveBeenCalled()
  })

  it("reports a jump in sseq before the event that jumped, with the sseq it expected", async () => {
    const calls = []
    createSossegoStream({
      url: "/x",
      onEvent: (e) => calls.push(["event", e.sseq]),
      onGap: (e, expected) => calls.push(["gap", e.sseq, expected]),
    })
    const src = FakeEventSource.lastInstance()
    emit(src, "1", 1)
    emit(src, "2", 2)
    emit(src, "9", 5)
    await flushMicrotasks()

    expect(calls).toEqual([["event", 1], ["event", 2], ["gap", 5, 3], ["event", 5]])
  })

  it("reports a decrease in sseq (the stream was pruned and restarted) as a gap", async () => {
    const onGap = vi.fn()
    createSossegoStream({ url: "/x", onEvent: () => {}, onGap })
    const src = FakeEventSource.lastInstance()
    emit(src, "10", 7)
    emit(src, "11", 1)
    await flushMicrotasks()

    expect(onGap).toHaveBeenCalledTimes(1)
    expect(onGap.mock.calls[0][1]).toBe(8)
  })
})

describe("EventSource options", () => {
  let uninstall

  beforeEach(() => {
    uninstall = installFakeEventSource()
  })

  afterEach(() => uninstall())

  it("opens with credentials unless told not to", () => {
    createSossegoStream({ url: "/a", onEvent: () => {} })
    expect(FakeEventSource.lastInstance().withCredentials).toBe(true)

    createSossegoStream({ url: "/b", onEvent: () => {}, withCredentials: false })
    expect(FakeEventSource.lastInstance().withCredentials).toBe(false)
  })
})

describe("payload formats", () => {
  const decode = (fmt, pld) => decodeFrame(frameData({ fmt, evt: "x", pld })).then((frame) => frame.pld)
  const gz = (buffer) => gzipSync(buffer).toString("base64")

  it("hands text over as the string it is, even when it looks like JSON", async () => {
    expect(await decode("text", "42")).toBe("42")
    expect(await decode("text", '{"a":1}')).toBe('{"a":1}')
  })

  it("hands bytes over as a Uint8Array", async () => {
    const bytes = await decode("bytes", Buffer.from([0, 255, 13, 10]).toString("base64"))

    expect(bytes).toBeInstanceOf(Uint8Array)
    expect([...bytes]).toEqual([0, 255, 13, 10])
  })

  it("gunzips gz:ejson, gz:text and gz:bytes as the Ruby encoders write them", async () => {
    const value = { html: "<turbo-stream></turbo-stream>".repeat(50), n: 1 }

    expect(await decode("gz:ejson", gz(JSON.stringify(value)))).toEqual(value)
    expect(await decode("gz:text", gz("Olá, sossego"))).toBe("Olá, sossego")
    expect([...(await decode("gz:bytes", gz(Buffer.from([1, 2, 3]))))]).toEqual([1, 2, 3])
  })
})
