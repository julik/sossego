/**
 * Stimulus controller for a Sossego stream, with handlers for the events
 * that `Sossego::PublishingHelpers` jobs (and the `Sossego::Stream#publish_*` helpers) publish: a progress bar, form prefill,
 * Turbo Streams and navigation.
 *
 * Register it under any name; the examples use "sossego":
 *
 *   import { application } from "controllers/application"
 *   import SossegoController from "@julik/sossego-stimulus"
 *   application.register("sossego", SossegoController)
 *
 *   <div data-controller="sossego"
 *        data-sossego-url-value="<%= sossego_signed_stream_path(@stream) %>"
 *        data-sossego-await-task-value="true">
 *     <div data-sossego-progress hidden>
 *       <span data-sossego-progress-text></span>
 *     </div>
 *   </div>
 *
 * Every event goes, in wire order, to the method `static events` maps its
 * name to. A subclass adds its own events, or overrides a built-in's method:
 *
 *   export default class extends SossegoController {
 *     static events = { poof: "showPoof" }
 *     showPoof(bytes, event) { ... }
 *     progressFinished(payload, event) { super.progressFinished(payload, event); ... }
 *   }
 *
 * Every event is also announced as two bubbling DOM events, with
 * `{eventName, payload, seq, sseq}` as their detail, so a page can react with
 * plain Stimulus actions: `sossego:event` for all of them
 * (`data-action="sossego:event->board#refresh"`), and `sossego:event:<name>`
 * for one (`data-action="sossego:event:poof->gallery#show"`).
 *
 * Other DOM events, all bubbling from the controller element:
 *
 * - `sossego:complete` - a task settled (`progress_finished`,
 *   `progress_warning` or `error_message` arrived); fired at once, while the
 *   progress element may still linger
 * - `sossego:stalled` - an awaited task went silent for `taskTimeout` ms
 * - `sossego:closed` - the stream ended for good; detail `{reason, seq}`,
 *   `seq` null when the server refused the stream
 * - `sossego:disconnected` - the server refused the stream while a task was
 *   awaited
 * - `sossego:prefilled` - dispatched on each input `field_prefill` changed
 *
 * ## Awaiting a task
 *
 * A stream opened for one background task is silent only when the task is
 * not coming. With `await-task` set (or after a `sossego:await-task` event
 * on the element, for a form that starts the task later), a silence longer
 * than `task-timeout` gives up on the task: the stream closes, the progress
 * bar says so, and `sossego:stalled` fires. Any event re-arms the timer and
 * a terminal one (`progress_finished`, `visit`, a published `close`)
 * disarms it. Keep the
 * timeout above the longest silence a healthy task can produce - a single
 * slow LLM request, say.
 */
import { Controller } from "@hotwired/stimulus"
import { createSossegoStream } from "@julik/sossego-client/index.js"

// For a value inside a double-quoted attribute selector.
const quoted = (value) => String(value).replace(/["\\]/g, "\\$&")

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/** How long a finished progress bar stays up before it fades. */
export const FINISHED_LINGER_MS = 3000
/** How long a warning stays up before it fades. */
export const WARNING_LINGER_MS = 5000
/** How long the fading state is held before the bar is hidden. */
export const FADE_MS = 64
/** Delay between two fields `field_prefill` sets, so the eye can follow. */
export const PREFILL_STAGGER_MS = 300

// After one of these the task is settled and the stream owes us nothing.
const TERMINAL_EVENTS = ["progress_finished", "visit"]

// A single connection error is routine: the server ends every response
// after 30 seconds. This many in a row without a frame is not.
const ERRORS_BEFORE_WARNING = 3

/**
 * The progress element: `[data-sossego-progress]` inside the controller
 * element, else anywhere in the document. Its attribute value is the state:
 * `working`, `warning`, `error` or `finished`; style it with attribute
 * selectors. `data-sossego-fading` is present while it fades out.
 *
 * @param {SossegoController} controller
 * @returns {HTMLElement | null}
 */
export function progressElement(controller) {
  return controller.element.querySelector("[data-sossego-progress]") ?? document.querySelector("[data-sossego-progress]")
}

/**
 * Show a message in the progress element, in a state.
 *
 * @param {SossegoController} controller
 * @param {string} state
 * @param {string | null} message null leaves the text alone
 */
export function showProgress(controller, state, message) {
  const el = progressElement(controller)
  if (!el) return null
  el.hidden = false
  el.removeAttribute("data-sossego-fading")
  setState(el, state)
  const textEl = el.querySelector("[data-sossego-progress-text]")
  if (textEl && message !== null && message !== undefined) textEl.textContent = String(message)
  return el
}

// Handlers are not waited for, so a linger that ends after a newer message
// arrived must leave the element alone. Each state change bumps the
// element's generation; a delayed fade only goes ahead if it hasn't moved.
const generations = new WeakMap()

function setState(el, state) {
  generations.set(el, (generations.get(el) ?? 0) + 1)
  el.setAttribute("data-sossego-progress", state)
  return generations.get(el)
}

// Shows the element for `ms`, then fades and hides it, unless its state
// changes in the meantime.
async function lingerThenFade(el, generation, ms) {
  await sleep(ms)
  if (generations.get(el) !== generation) return
  el.setAttribute("data-sossego-fading", "")
  await sleep(FADE_MS)
  el.removeAttribute("data-sossego-fading")
  if (generations.get(el) === generation) el.hidden = true
}

function complete(controller) {
  controller.element.dispatchEvent(new CustomEvent("sossego:complete", { bubbles: true }))
}

function setFieldValue(input, value) {
  if (input.tagName === "SELECT") {
    const index = Array.from(input.options).findIndex((opt) => opt.value === String(value))
    if (index >= 0 && input.selectedIndex !== index) {
      input.selectedIndex = index
      return true
    }
  } else if (input.type === "checkbox") {
    const checked = value === true || value === "1" || value === "true"
    if (input.checked !== checked) {
      input.checked = checked
      return true
    }
  } else if (input.type === "radio") {
    const radio = input.form?.querySelector(`[name="${quoted(input.name)}"][value="${quoted(String(value))}"]`) ??
      document.querySelector(`[name="${quoted(input.name)}"][value="${quoted(String(value))}"]`)
    if (radio && !radio.checked) {
      radio.checked = true
      return true
    }
  } else if (input.value !== String(value)) {
    input.value = value
    return true
  }
  return false
}

// Sets the named fields in document order, one by one, firing `change` and
// `sossego:prefilled` on each one it changed.
async function prefill(fields) {
  const updates = Object.entries(fields ?? {})
    .filter(([, value]) => value !== undefined && value !== null)
    .map(([name, value]) => ({
      input: document.querySelector(`input[type="checkbox"][name="${quoted(name)}"]`) ??
        document.querySelector(`[name="${quoted(name)}"]`),
      value,
    }))
    .filter(({ input }) => input)
    .sort((a, b) => {
      const pos = a.input.compareDocumentPosition(b.input)
      if (pos & Node.DOCUMENT_POSITION_FOLLOWING) return -1
      if (pos & Node.DOCUMENT_POSITION_PRECEDING) return 1
      return 0
    })

  for (const [i, { input, value }] of updates.entries()) {
    if (setFieldValue(input, value)) {
      input.dispatchEvent(new CustomEvent("sossego:prefilled", { bubbles: true }))
      input.dispatchEvent(new Event("change", { bubbles: true }))
    }
    if (i < updates.length - 1) await sleep(PREFILL_STAGGER_MS)
  }
}

// The merged `static events` of a controller class and its ancestors,
// nearest last so a subclass overrides what it inherits.
const eventMaps = new WeakMap()

function eventsOf(constructor) {
  let events = eventMaps.get(constructor)
  if (!events) {
    const maps = []
    for (let c = constructor; c && c !== Controller; c = Object.getPrototypeOf(c)) {
      if (Object.hasOwn(c, "events")) maps.unshift(c.events)
    }
    events = Object.assign(Object.create(null), ...maps)
    eventMaps.set(constructor, events)
  }
  return events
}

export default class SossegoController extends Controller {
  static values = {
    url: String,
    lastEventId: String,
    awaitTask: Boolean,
    taskTimeout: { type: Number, default: 180_000 },
    stalledMessage: { type: String, default: "Nothing came back from the server. The task did not run - please try again." },
    reconnectingMessage: { type: String, default: "Trying to reach the server..." },
    closedMessage: { type: String, default: "Lost the connection to the server. Reload the page to try again." },
  }

  // Event name => the method that handles it, called with the decoded
  // payload and the whole event. A subclass lists its own events; they are
  // merged over these.
  static events = {
    progress: "progress",
    progress_warning: "progressWarning",
    error_message: "errorMessage",
    progress_finished: "progressFinished",
    field_prefill: "fieldPrefill",
    turbo_stream: "turboStream",
    visit: "visit",
  }

  connect() {
    this.onAwaitTask = () => this.awaitTask()
    this.element.addEventListener("sossego:await-task", this.onAwaitTask)
    this.open()
    if (this.awaitTaskValue) this.awaitTask()
  }

  disconnect() {
    this.element.removeEventListener("sossego:await-task", this.onAwaitTask)
    this.stopAwaitingTask()
    this.close()
  }

  urlValueChanged(url, previousUrl) {
    // The initial value is opened by connect().
    if (this.stream && url !== previousUrl) {
      this.close()
      this.open()
    }
  }

  open() {
    if (this.stream || !this.urlValue) return
    this.connectionErrors = 0
    this.stream = createSossegoStream({
      url: this.urlValue,
      lastEventId: this.lastEventIdValue || null,
      onEvent: (event) => this.handle(event),
      onPing: () => this.frameArrived(),
      onClose: (reason, seq) => this.closed(reason, seq),
      onError: (err) => this.errored(err),
    })
  }

  close() {
    this.stream?.close()
    this.stream = null
  }

  // Start (or restart) the clock on an outstanding task. Reopens the
  // stream if a stalled task made us drop it, so trying again is listened
  // to.
  awaitTask() {
    this.open()
    this.stopAwaitingTask()
    this.silenceTimer = setTimeout(() => this.stalled(), this.taskTimeoutValue)
  }

  stopAwaitingTask() {
    clearTimeout(this.silenceTimer)
    this.silenceTimer = null
  }

  get awaitingTask() {
    return this.silenceTimer != null
  }

  // Called in wire order. The handler's promise, if it returns one, goes back
  // to the stream, which doesn't wait for it but reports a rejection.
  handle(event) {
    this.frameArrived()
    if (this.awaitingTask) {
      if (TERMINAL_EVENTS.includes(event.eventName)) this.stopAwaitingTask()
      else this.awaitTask()
    }

    const { eventName, payload, seq, sseq } = event
    const detail = { eventName, payload, seq, sseq }
    this.dispatch("event", { prefix: "sossego", detail })
    this.dispatch(`event:${eventName}`, { prefix: "sossego", detail })

    const method = eventsOf(this.constructor)[eventName]
    if (!method) return
    if (typeof this[method] !== "function") {
      throw new Error(`static events maps ${eventName} to ${method}, which is not a method of ${this.identifier}`)
    }
    return this[method](payload, event)
  }

  frameArrived() {
    this.connectionErrors = 0
  }

  errored(err) {
    if (err instanceof Error) {
      console.error("Sossego:", err)
      return
    }
    this.connectionErrors += 1
    if (this.connectionErrors >= ERRORS_BEFORE_WARNING) showProgress(this, "warning", this.reconnectingMessageValue)
  }

  // A close with a position was published: the stream's task is over, which
  // is how a one-off task or a wizard step says it is done. A close without
  // one is the server refusing the stream, which a waiting task never
  // recovers from.
  closed(reason, seq) {
    this.stream = null
    this.dispatch("closed", { prefix: "sossego", detail: { reason, seq } })
    if (!this.awaitingTask) return

    this.stopAwaitingTask()
    if (seq === null) {
      showProgress(this, "error", this.closedMessageValue)
      this.dispatch("disconnected", { prefix: "sossego", detail: { reason } })
    } else {
      complete(this)
    }
  }

  // Nothing arrived for long enough that nothing is going to. Dropping the
  // stream costs the server a polling loop that ends on its next deadline.
  stalled() {
    this.stopAwaitingTask()
    this.close()
    showProgress(this, "error", this.stalledMessageValue)
    this.dispatch("stalled", { prefix: "sossego" })
  }

  // Built-in events. Called in wire order, but a method that returns a
  // promise is not waited for: the next event is handled while it runs.

  // Payload: the message to show.
  progress(message, _event) {
    showProgress(this, "working", message)
  }

  // Payload: the message. Held for a while, then the bar fades, unless
  // something newer is shown by then.
  progressWarning(message, _event) {
    const el = showProgress(this, "warning", message)
    complete(this)
    if (el) return lingerThenFade(el, generations.get(el), WARNING_LINGER_MS)
  }

  // Payload: the message. A reported error is the end of the task: the bar
  // stays up so it can be read.
  errorMessage(message, _event) {
    showProgress(this, "error", message)
    complete(this)
  }

  // No payload. A bar showing an error or warning stays; otherwise the
  // last message lingers, then the bar fades, unless something newer is
  // shown by then.
  progressFinished(_payload, _event) {
    complete(this)
    const el = progressElement(this)
    const state = el?.getAttribute("data-sossego-progress")
    if (el && !el.hidden && state !== "error" && state !== "warning") {
      return lingerThenFade(el, setState(el, "finished"), FINISHED_LINGER_MS)
    }
  }

  // Payload: `{"model[field]": value, ...}`. Sets the named fields in
  // document order, one by one, firing `change` and `sossego:prefilled` on
  // each one it changed.
  fieldPrefill(fields, _event) {
    return prefill(fields)
  }

  // Payload: one or more `<turbo-stream>` elements as HTML.
  turboStream(html, _event) {
    window.Turbo.renderStreamMessage(html)
  }

  // Payload: the URL to go to.
  visit(url, _event) {
    if (!url) return
    if (window.Turbo) {
      window.Turbo.visit(url)
    } else {
      window.location.href = url
    }
  }
}
