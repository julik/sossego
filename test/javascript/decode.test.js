import { describe, it, expect } from "vitest"

import { decodeFrame, registerPayloadDecoder, SossegoDecodeError } from "sossego"
import { closeData, eventData, frameData, pingData } from "sossego/testing"

describe("decodeFrame — ejson", () => {
  it("returns the envelope of a sossego frame with its pld", async () => {
    const frame = await decodeFrame(eventData("entity", "12345", 9, "17168", { id: 7, in_inbox: true }, "user:1:mail_messages"))

    expect(frame).toEqual({
      fmt: "ejson",
      evt: "entity",
      seq: "12345",
      sseq: 9,
      head: "17168",
      sid: "user:1:mail_messages",
      pld: { id: 7, in_inbox: true },
    })
  })

  it("returns a ping's head and pld, with no position", async () => {
    const frame = await decodeFrame(pingData("118", "2026-10-02T09:00:00Z"))

    expect(frame).toEqual({ fmt: "ejson", evt: "ping", head: "118", pld: { head: "118", time: "2026-10-02T09:00:00Z" } })
  })

  it("returns a refusal close with no position", async () => {
    const frame = await decodeFrame(closeData("flag_off"))

    expect(frame).toEqual({ fmt: "ejson", evt: "close", pld: { reason: "flag_off" } })
    expect("seq" in frame).toBe(false)
  })

  it("handles a single-line envelope and ignores keys it does not know", async () => {
    const frame = await decodeFrame(`{"fmt":"ejson","evt":"entity","seq":"1","sseq":1,"head":"1","sid":"x:1:y","pld":[1],"later":true}`)
    expect(frame.pld).toEqual([1])
  })

  it("handles unicode and emoji in the pld", async () => {
    const frame = await decodeFrame (eventData("entity", "1", 1, "1", { msg: "Hello 👋 你好" }))
    expect(frame.pld.msg).toBe("Hello 👋 你好")
  })
})

describe("decodeFrame — error paths", () => {
  it("throws on malformed JSON", async () => {
    await expect(decodeFrame("{ not json")).rejects.toThrow(SossegoDecodeError)
    await expect(decodeFrame(`json:{"fmt": "ejson"}`)).rejects.toThrow(/malformed sossego frame/)
  })

  it("throws on JSON that is not an object", async () => {
    await expect(decodeFrame("[1, 2]")).rejects.toThrow(/not a JSON object/)
  })

  it("throws on a missing fmt", async () => {
    await expect(decodeFrame(`{"evt": "x", "pld": {}}`)).rejects.toThrow(SossegoDecodeError)
    await expect(decodeFrame(`{"evt": "x", "pld": {}}`)).rejects.toThrow(/has no fmt/)
  })

  it("throws on an unknown fmt, naming it", async () => {
    const raw = frameData({ fmt: "weasel", evt: "x", pld: {} })
    await expect(decodeFrame(raw)).rejects.toThrow(SossegoDecodeError)
    await expect(decodeFrame(raw)).rejects.toThrow(/unknown sossego fmt: weasel/)
  })

  it("error class is named SossegoDecodeError for catch-by-instance checks", async () => {
    const error = await decodeFrame("{ broken").catch((e) => e)
    expect(error).toBeInstanceOf(SossegoDecodeError)
    expect((error).name).toBe("SossegoDecodeError")
  })
})

describe("registerPayloadDecoder", () => {
  it("runs pld through the decoder its fmt names, sync or async", async () => {
    registerPayloadDecoder("test-upcase", (pld) => (pld).toUpperCase())
    registerPayloadDecoder("test-async", async (pld) => ({ async: pld }))

    expect((await decodeFrame(frameData({ fmt: "test-upcase", evt: "x", pld: "a:b" }))).pld).toBe("A:B")
    expect((await decodeFrame(frameData({ fmt: "test-async", evt: "x", pld: "x" }))).pld).toEqual({ async: "x" })
  })

  it("wraps a failing decoder in SossegoDecodeError", async () => {
    registerPayloadDecoder("test-fails", () => {
      throw new Error("nope")
    })

    await expect(decodeFrame(frameData({ fmt: "test-fails", evt: "x", pld: "x" }))).rejects.toThrow(
      /malformed test-fails pld: nope/,
    )
  })
})
