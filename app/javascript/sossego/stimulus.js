/**
 * Stimulus controller for a Sossego stream, with handlers for the events
 * that `Sossego::Reporting` jobs publish: a progress bar, form prefill,
 * Turbo Streams and navigation.
 *
 * Register it under any name; the examples use "sossego":
 *
 *   import { application } from "controllers/application"
 *   import SossegoController from "sossego/stimulus"
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
 * Every event goes, in wire order, to the handler registered for its name
 * (see `handlers` and `registerHandler`), and is also announced as a
 * bubbling `sossego:event` DOM event with `{eventName, payload, seq, sseq}`
 * as its detail, so a page can react with plain Stimulus actions:
 * `data-action="sossego:event->board#refresh"`.
 *
 * Other DOM events, all bubbling from the controller element:
 *
 * - `sossego:complete` - a task settled (`progress_finished`,
 *   `progress_warning` or `error_message` was handled)
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
import { createSossegoStream } from "sossego"

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
  el.setAttribute("data-sossego-progress", state)
  const textEl = el.querySelector("[data-sossego-progress-text]")
  if (textEl && message !== null && message !== undefined) textEl.textContent = String(message)
  return el
}

async function fadeOut(el) {
  el.setAttribute("data-sossego-fading", "")
  await sleep(FADE_MS)
  el.hidden = true
  el.removeAttribute("data-sossego-fading")
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

/**
 * Handlers by event name. Each gets the decoded payload and
 * `{controller, event}`; it may return a Promise, and the next event waits
 * for it.
 *
 * @type {Record<string, (payload: any, context: {controller: SossegoController, event: import("sossego").SossegoEvent}) => void | Promise<void>>}
 */
export const handlers = {
  // Payload: the message to show.
  progress(message, { controller }) {
    showProgress(controller, "working", message)
  },

  // Payload: the message. Held for a while, then the bar fades.
  async progress_warning(message, { controller }) {
    const el = showProgress(controller, "warning", message)
    if (el) {
      await sleep(WARNING_LINGER_MS)
      await fadeOut(el)
    }
    complete(controller)
  },

  // Payload: the message. A reported error is the end of the task: the bar
  // stays up so it can be read.
  error_message(message, { controller }) {
    showProgress(controller, "error", message)
    complete(controller)
  },

  // No payload. A bar showing an error or warning stays; otherwise the
  // last message lingers, then the bar fades.
  async progress_finished(_payload, { controller }) {
    const el = progressElement(controller)
    const state = el?.getAttribute("data-sossego-progress")
    if (el && !el.hidden && state !== "error" && state !== "warning") {
      el.setAttribute("data-sossego-progress", "finished")
      await sleep(FINISHED_LINGER_MS)
      await fadeOut(el)
    }
    complete(controller)
  },

  // Payload: `{"model[field]": value, ...}`. Sets the named fields in
  // document order, one by one, firing `change` and `sossego:prefilled` on
  // each one it changed.
  async field_prefill(fields, _context) {
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
  },

  // Payload: one or more `<turbo-stream>` elements as HTML.
  turbo_stream(html, _context) {
    window.Turbo.renderStreamMessage(html)
  },

  // Payload: the URL to go to.
  visit(url, _context) {
    if (!url) return
    if (window.Turbo) {
      window.Turbo.visit(url)
    } else {
      window.location.href = url
    }
  },
}

/**
 * Add or replace the handler for an event name, for every controller.
 *
 * @param {string} eventName
 * @param {(payload: any, context: {controller: SossegoController, event: import("sossego").SossegoEvent}) => void | Promise<void>} handler
 */
export function registerHandler(eventName, handler) {
  handlers[eventName] = handler
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

  // Runs in wire order: the stream waits for the returned promise before
  // handing over the next event.
  async handle(event) {
    this.frameArrived()
    if (this.awaitingTask) {
      if (TERMINAL_EVENTS.includes(event.eventName)) this.stopAwaitingTask()
      else this.awaitTask()
    }

    const { eventName, payload, seq, sseq } = event
    this.dispatch("event", { prefix: "sossego", detail: { eventName, payload, seq, sseq } })

    const handler = handlers[eventName]
    if (handler) await handler(payload, { controller: this, event })
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
}
