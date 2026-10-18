import { describe, it, expect, vi } from "vitest"

import { createDispatcher } from "@sossego/client"

describe("createDispatcher", () => {
  it("routes events by eventName to the registered handler", () => {
    const { on, dispatch } = createDispatcher()
    const seen = []
    on("email_added", (body) => seen.push(`added ${body.id}`))
    on("email_archived", (body) => seen.push(`archived ${body.id}`))

    dispatch({ eventName: "email_added", payload: { id: 7 } })
    dispatch({ eventName: "email_archived", payload: { id: 8 } })

    expect(seen).toEqual(["added 7", "archived 8"])
  })

  it("ignores unknown event names", () => {
    const { on, dispatch } = createDispatcher()
    const handler = vi.fn()
    on("known", handler)

    expect(() => dispatch({ eventName: "unknown", payload: { whatever: 1 } })).not.toThrow()
    expect(handler).not.toHaveBeenCalled()
  })

  it("re-registering the same event name replaces the previous handler", () => {
    const { on, dispatch } = createDispatcher()
    const first = vi.fn()
    const second = vi.fn()
    on("x", first)
    on("x", second)

    const event = { eventName: "x", payload: 1 }
    dispatch(event)

    expect(first).not.toHaveBeenCalled()
    expect(second).toHaveBeenCalledWith(1, event)
  })

  it("off removes a handler", () => {
    const { on, off, dispatch } = createDispatcher()
    const handler = vi.fn()
    on("x", handler)
    off("x")

    dispatch({ eventName: "x", payload: 1 })

    expect(handler).not.toHaveBeenCalled()
  })

  it("returns an async handler's promise, so the stream waits for it", async () => {
    const { on, dispatch } = createDispatcher()
    let completed = false
    on("x", async () => {
      await Promise.resolve()
      completed = true
    })

    await dispatch({ eventName: "x", payload: null })
    expect(completed).toBe(true)
  })

  it("lets handler errors propagate", () => {
    const { on, dispatch } = createDispatcher()
    on("boom", () => {
      throw new Error("kaboom")
    })

    expect(() => dispatch({ eventName: "boom", payload: null })).toThrow("kaboom")
  })

  it("dispatchers do not share handlers", () => {
    const a = createDispatcher()
    const b = createDispatcher()
    const handler = vi.fn()
    a.on("x", handler)

    b.dispatch({ eventName: "x", payload: 1 })

    expect(handler).not.toHaveBeenCalled()
  })
})
