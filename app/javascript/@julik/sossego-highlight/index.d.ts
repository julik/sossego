import { Controller } from "@hotwired/stimulus"

export default class SossegoHighlightController extends Controller<HTMLElement> {
  durationValue: number
  eventValue: string
  scrollValue: boolean

  enqueue(field: Element): void
}
