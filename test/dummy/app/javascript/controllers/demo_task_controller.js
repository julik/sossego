import { Controller } from "@hotwired/stimulus"

// Starts the demo job, telling the server which stream to report to, and
// gives the buttons back once the task settles.
export default class extends Controller {
  static targets = ["button"]
  static values = { url: String }

  async start({ params }) {
    const sossego = this.element
    this.buttonTargets.forEach((b) => (b.disabled = true))

    // Arm the silence timer before the request, so a request that never
    // starts a task is noticed too.
    sossego.dispatchEvent(new CustomEvent("sossego:await-task"))

    const body = new FormData()
    body.append("stream_url", sossego.dataset.sossegoUrlValue)
    if (params.fail) body.append("fail", "1")
    const response = await fetch(this.urlValue, {
      method: "POST",
      body,
      headers: { "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content },
    })
    if (!response.ok) {
      console.error("Could not start the task", response.status)
      this.done()
    }
  }

  done() {
    this.buttonTargets.forEach((b) => (b.disabled = false))
  }
}
