import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"

import SossegoHighlightController from "@julik/sossego-highlight"

async function flush() {
  for (let i = 0; i < 10; i++) await Promise.resolve()
}

describe("sossego-highlight Stimulus controller", () => {
  let application
  const field = (name) => document.querySelector(`[name="${name}"]`)
  const highlighted = () => [...document.querySelectorAll("[data-sossego-highlighted]")].map((el) => el.name)
  const fill = (name) => field(name).dispatchEvent(new CustomEvent("sossego:prefilled", { bubbles: true }))

  beforeEach(async () => {
    vi.useFakeTimers()
    Element.prototype.scrollIntoView = vi.fn()
    document.body.innerHTML = `
      <form data-controller="sossego-highlight">
        <input name="a"><input name="b"><input name="c">
      </form>`
    application = Application.start()
    application.register("sossego-highlight", SossegoHighlightController)
    await flush()
  })

  afterEach(() => {
    application.stop()
    vi.useRealTimers()
  })

  it("highlights fields one after another, each starting halfway through the previous one", async () => {
    fill("a")
    fill("b")
    fill("c")

    expect(highlighted()).toEqual(["a"])
    await vi.advanceTimersByTimeAsync(300)
    expect(highlighted()).toEqual(["a", "b"])
    await vi.advanceTimersByTimeAsync(300)
    expect(highlighted()).toEqual(["b", "c"])
    await vi.advanceTimersByTimeAsync(600)
    expect(highlighted()).toEqual([])
  })

  it("scrolls only the first field into view", () => {
    fill("b")
    fill("c")

    expect(Element.prototype.scrollIntoView).toHaveBeenCalledTimes(1)
    expect(Element.prototype.scrollIntoView.mock.contexts[0]).toBe(field("b"))
  })

  it("does not queue a field twice while it waits", async () => {
    fill("a")
    fill("b")
    fill("b")

    await vi.advanceTimersByTimeAsync(300)
    await vi.advanceTimersByTimeAsync(300)
    expect(highlighted()).toEqual(["b"])
  })

  it("stops listening and clears highlights when it disconnects, and listens once after reconnecting", async () => {
    const form = document.querySelector("form")
    fill("a")
    form.remove()
    await flush()
    expect(field("a")).toBeNull()

    document.body.append(form)
    await flush()
    expect(form.querySelector("[data-sossego-highlighted]")).toBeNull()

    const setAttribute = vi.spyOn(form.querySelector("[name=b]"), "setAttribute")
    fill("b")
    expect(setAttribute.mock.calls.filter(([name]) => name === "data-sossego-highlighted").length).toBe(1)
  })

  it("listens to another event when told to", async () => {
    document.body.innerHTML = `<form data-controller="sossego-highlight" data-sossego-highlight-event-value="app:suggested"><input name="x"></form>`
    await flush()

    field("x").dispatchEvent(new CustomEvent("app:suggested", { bubbles: true }))

    expect(highlighted()).toEqual(["x"])
  })
})
