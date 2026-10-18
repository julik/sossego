/**
 * Stimulus controller that draws the eye to fields something else filled
 * in: the fields `field_prefill` sets, or any field your own code fills
 * after dispatching `sossego:prefilled` on it. Ported from Moneymaker's
 * "magic fields".
 *
 * The highlights run one at a time, in the order the fields were filled,
 * each starting halfway through the one before. The first field is
 * scrolled into view. While highlighted, a field has the
 * `data-sossego-highlighted` attribute; the stylesheet
 * `@sossego/highlight/highlight.css` gives it a pulse, or style it yourself.
 *
 *   import SossegoHighlightController from "@sossego/highlight"
 *   application.register("sossego-highlight", SossegoHighlightController)
 *
 *   <form data-controller="sossego-highlight">...</form>
 *
 *   // a field filled without a stream
 *   input.value = suggestion
 *   input.dispatchEvent(new CustomEvent("sossego:prefilled", { bubbles: true }))
 */
import { Controller } from "@hotwired/stimulus"

export default class SossegoHighlightController extends Controller {
  static values = {
    duration: { type: Number, default: 600 },
    event: { type: String, default: "sossego:prefilled" },
    scroll: { type: Boolean, default: true },
  }

  connect() {
    this.queue = []
    this.animating = false
    this.scrolledToFirst = false
    this.timers = new Set()
    this.onFilled = (event) => this.enqueue(event.target)
    this.element.addEventListener(this.eventValue, this.onFilled)
  }

  disconnect() {
    this.element.removeEventListener(this.eventValue, this.onFilled)
    this.timers.forEach((timer) => clearTimeout(timer))
    this.element.querySelectorAll("[data-sossego-highlighted]").forEach((el) => el.removeAttribute("data-sossego-highlighted"))
    this.queue = []
    this.animating = false
  }

  enqueue(field) {
    if (!this.queue.includes(field)) this.queue.push(field)
    if (this.scrollValue && !this.scrolledToFirst) {
      this.scrolledToFirst = true
      field.scrollIntoView?.({ behavior: "smooth", block: "center" })
    }
    this.next()
  }

  next() {
    if (this.animating || this.queue.length === 0) return

    this.animating = true
    const field = this.queue.shift()
    field.setAttribute("data-sossego-highlighted", "")
    field.style.setProperty("--sossego-highlight-duration", `${this.durationValue}ms`)

    this.after(this.durationValue, () => field.removeAttribute("data-sossego-highlighted"))
    // The next one starts halfway through this one.
    this.after(this.durationValue / 2, () => {
      this.animating = false
      this.next()
    })
  }

  after(ms, fn) {
    const timer = setTimeout(() => {
      this.timers.delete(timer)
      fn()
    }, ms)
    this.timers.add(timer)
  }
}
