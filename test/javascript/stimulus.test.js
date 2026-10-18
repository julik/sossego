import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"

import SossegoController, { registerHandler, handlers, FINISHED_LINGER_MS, FADE_MS } from "sossego/stimulus"
import { closeData, eventData, FakeEventSource, installFakeEventSource } from "./helpers.js"

async function flush() {
  for (let i = 0; i < 30; i++) await Promise.resolve()
}

let seq = 0
function emit(name, payload) {
  seq += 1
  FakeEventSource.lastInstance().simulateEvent("sossego", String(seq), eventData(name, String(seq), seq, String(seq), payload))
}

describe("sossego Stimulus controller", () => {
  let uninstall
  let application

  beforeEach(async () => {
    seq = 0
    uninstall = installFakeEventSource()
    document.body.innerHTML = `
      <form>
        <input name="expense[amount]" value="">
        <select name="expense[currency]"><option value="EUR">EUR</option><option value="USD">USD</option></select>
        <input type="checkbox" name="expense[paid]">
      </form>
      <div id="client" data-controller="sossego" data-sossego-url-value="/sossego/streams/task:1:progress?sig=x">
        <div data-sossego-progress hidden><span data-sossego-progress-text></span></div>
      </div>`
    application = Application.start()
    application.register("sossego", SossegoController)
    await flush()
  })

  afterEach(() => {
    application.stop()
    uninstall()
    vi.useRealTimers()
    delete window.Turbo
  })

  const client = () => document.getElementById("client")
  const progress = () => document.querySelector("[data-sossego-progress]")

  it("opens one stream for the url on connect", () => {
    expect(FakeEventSource.instances.length).toBe(1)
    expect(FakeEventSource.lastInstance().url).toBe("/sossego/streams/task:1:progress?sig=x")
  })

  it("shows progress messages and announces every event", async () => {
    const seen = []
    client().addEventListener("sossego:event", (e) => seen.push(e.detail.eventName))

    emit("progress", "Reading the receipt...")
    await flush()

    expect(progress().hidden).toBe(false)
    expect(progress().getAttribute("data-sossego-progress")).toBe("working")
    expect(progress().textContent).toBe("Reading the receipt...")
    expect(seen).toEqual(["progress"])
  })

  it("keeps an error up and completes the task", async () => {
    const completed = vi.fn()
    client().addEventListener("sossego:complete", completed)

    emit("error_message", "Boom")
    emit("progress_finished", null)
    await flush()

    expect(progress().getAttribute("data-sossego-progress")).toBe("error")
    expect(progress().hidden).toBe(false)
    expect(completed).toHaveBeenCalledTimes(2)
  })

  it("lets a finished bar linger, then hides it", async () => {
    vi.useFakeTimers()
    emit("progress", "Done soon")
    emit("progress_finished", null)
    await vi.advanceTimersByTimeAsync(0)

    expect(progress().getAttribute("data-sossego-progress")).toBe("finished")
    expect(progress().hidden).toBe(false)

    await vi.advanceTimersByTimeAsync(FINISHED_LINGER_MS + FADE_MS)
    expect(progress().hidden).toBe(true)
  })

  it("prefills fields in document order and fires change on each", async () => {
    vi.useFakeTimers()
    const changed = []
    document.querySelector("form").addEventListener("change", (e) => changed.push(e.target.name))

    emit("field_prefill", { "expense[paid]": true, "expense[amount]": "12.50", "expense[currency]": "USD", "expense[missing]": 1 })
    await vi.advanceTimersByTimeAsync(2_000)

    expect(document.querySelector("[name='expense[amount]']").value).toBe("12.50")
    expect(document.querySelector("[name='expense[currency]']").value).toBe("USD")
    expect(document.querySelector("[name='expense[paid]']").checked).toBe(true)
    expect(changed).toEqual(["expense[amount]", "expense[currency]", "expense[paid]"])
  })

  it("hands turbo_stream payloads to Turbo", async () => {
    window.Turbo = { renderStreamMessage: vi.fn() }

    emit("turbo_stream", "<turbo-stream action='remove' target='x'></turbo-stream>")
    await flush()

    expect(window.Turbo.renderStreamMessage).toHaveBeenCalledWith("<turbo-stream action='remove' target='x'></turbo-stream>")
  })

  it("handles events strictly in order, waiting for async handlers", async () => {
    vi.useFakeTimers()
    const order = []
    registerHandler("slow", async (payload) => {
      await new Promise((resolve) => setTimeout(resolve, 100))
      order.push(payload)
    })
    registerHandler("fast", (payload) => order.push(payload))

    emit("slow", 1)
    emit("fast", 2)
    await vi.advanceTimersByTimeAsync(200)

    expect(order).toEqual([1, 2])
    delete handlers.slow
    delete handlers.fast
  })

  it("gives up on an awaited task that goes silent", async () => {
    vi.useFakeTimers()
    client().setAttribute("data-sossego-task-timeout-value", "1000")
    const stalled = vi.fn()
    client().addEventListener("sossego:stalled", stalled)

    client().dispatchEvent(new CustomEvent("sossego:await-task"))
    await vi.advanceTimersByTimeAsync(999)
    expect(stalled).not.toHaveBeenCalled()

    await vi.advanceTimersByTimeAsync(1)
    expect(stalled).toHaveBeenCalledTimes(1)
    expect(FakeEventSource.lastInstance().isClosed()).toBe(true)
    expect(progress().getAttribute("data-sossego-progress")).toBe("error")
  })

  it("an event re-arms the silence timer and a terminal event disarms it", async () => {
    vi.useFakeTimers()
    client().setAttribute("data-sossego-task-timeout-value", "1000")
    const stalled = vi.fn()
    client().addEventListener("sossego:stalled", stalled)

    client().dispatchEvent(new CustomEvent("sossego:await-task"))
    await vi.advanceTimersByTimeAsync(800)
    emit("progress", "still here")
    await vi.advanceTimersByTimeAsync(800)
    expect(stalled).not.toHaveBeenCalled()

    window.Turbo = { visit: vi.fn() }
    emit("visit", "/somewhere")
    await vi.advanceTimersByTimeAsync(5_000)
    expect(stalled).not.toHaveBeenCalled()
    expect(window.Turbo.visit).toHaveBeenCalledWith("/somewhere")
  })

  it("reports a stream refused under an awaited task", async () => {
    const closed = vi.fn()
    const disconnected = vi.fn()
    client().addEventListener("sossego:closed", (e) => closed(e.detail))
    client().addEventListener("sossego:disconnected", disconnected)
    client().dispatchEvent(new CustomEvent("sossego:await-task"))

    FakeEventSource.lastInstance().simulateEvent("close", "", closeData("forbidden"))
    await flush()

    expect(closed).toHaveBeenCalledWith({ reason: "forbidden", seq: null })
    expect(disconnected).toHaveBeenCalledTimes(1)
    expect(progress().getAttribute("data-sossego-progress")).toBe("error")
  })

  it("takes a published close under an awaited task as the task ending, not as an error", async () => {
    const completed = vi.fn()
    const disconnected = vi.fn()
    const closed = vi.fn()
    client().addEventListener("sossego:complete", completed)
    client().addEventListener("sossego:disconnected", disconnected)
    client().addEventListener("sossego:closed", (e) => closed(e.detail))
    client().dispatchEvent(new CustomEvent("sossego:await-task"))

    emit("progress", "Working...")
    FakeEventSource.lastInstance().simulateEvent("close", "9", closeData("finished", { seq: "9", sseq: 2, head: "9", sid: "task:1:progress" }))
    await flush()

    expect(closed).toHaveBeenCalledWith({ reason: "finished", seq: "9" })
    expect(completed).toHaveBeenCalledTimes(1)
    expect(disconnected).not.toHaveBeenCalled()
    expect(progress().getAttribute("data-sossego-progress")).toBe("working")
  })

  it("closes the stream when the element goes away", async () => {
    const src = FakeEventSource.lastInstance()
    client().remove()
    await flush()

    expect(src.isClosed()).toBe(true)
  })
})
