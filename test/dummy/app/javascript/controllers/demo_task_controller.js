import SossegoController from "@sossego/stimulus"

// The sossego controller with one event of the demo's own, `receipt_read`.
// Starts the demo job, telling the server which stream to report to, and
// gives the buttons back once the task settles.
export default class extends SossegoController {
  static targets = ["button", "confidence"]
  static values = { analyzeUrl: String }
  static events = { receipt_read: "receiptRead" }

  // Payload: `{"confidence": 0.87}`
  receiptRead({ confidence }) {
    this.confidenceTarget.hidden = false
    this.confidenceTarget.textContent = `The model is ${Math.round(confidence * 100)}% sure of what it read.`
  }

  async start({ params }) {
    this.buttonTargets.forEach((b) => (b.disabled = true))
    this.confidenceTarget.hidden = true

    // Arm the silence timer before the request, so a request that never
    // starts a task is noticed too.
    this.awaitTask()

    const body = new FormData()
    body.append("stream_url", this.urlValue)
    if (params.fail) body.append("fail", "1")
    const response = await fetch(this.analyzeUrlValue, {
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
