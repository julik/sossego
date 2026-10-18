// The plain JS client, with no framework.
import { createSossegoStream, createDispatcher, maxCursor } from "@sossego/client"

const root = document.getElementById("chat")
const $ = (selector) => root.querySelector(selector)
let knownHead = root.dataset.head

const notice = (text) => {
  $("[data-notice]").hidden = false
  $("[data-notice]").textContent = text
}

const events = createDispatcher()
events.on("chat_message", (message, event) => {
  const li = document.createElement("li")
  const author = document.createElement("b")
  author.textContent = message.author
  const sseq = document.createElement("small")
  sseq.textContent = `#${event.sseq}`
  li.append(author, " ", message.text, " ", sseq)
  $("[data-messages]").append(li)
  li.scrollIntoView({ block: "nearest" })
})

const stream = createSossegoStream({
  url: root.dataset.streamUrl,
  // Resume from what the page rendered: nothing is missed, nothing doubled.
  lastEventId: root.dataset.head,
  onEvent: (event) => {
    knownHead = maxCursor(knownHead, event.head)
    $("[data-cursor]").textContent = event.seq
    $("[data-head]").textContent = knownHead
    return events.dispatch(event)
  },
  onGap: (_event, expectedSseq) => notice(`Missed events from #${expectedSseq} (pruned, or more than the backlog). A real page would refetch here.`),
  onPing: ({ head, time }) => {
    knownHead = maxCursor(knownHead, head)
    $("[data-head]").textContent = knownHead
    $("[data-ping]").textContent = new Date(time).toLocaleTimeString()
  },
  onStateChange: ({ status }) => ($("[data-status]").textContent = status),
  onClose: (reason) => {
    notice(`The stream was closed: ${reason}. It will not reconnect; reload to start over.`)
    $("[data-form] button").disabled = true
  },
  onError: (err) => console.debug("sossego:", err),
})
window.addEventListener("pagehide", () => stream.close())

const post = (url, body) =>
  fetch(url, { method: "POST", body, headers: { "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content } })

$("[data-form]").addEventListener("submit", (e) => {
  e.preventDefault()
  const form = new FormData(e.target)
  if (!form.get("text")) return
  post(root.dataset.messagesUrl, form)
  e.target.elements.text.value = ""
})

$("[data-close]").addEventListener("click", () => post(root.dataset.closeUrl, new FormData($("[data-form]"))))
