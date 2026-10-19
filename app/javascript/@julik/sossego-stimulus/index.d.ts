import { Controller } from "@hotwired/stimulus"
import type { SossegoEvent } from "@julik/sossego-client"

export const FINISHED_LINGER_MS: number
export const WARNING_LINGER_MS: number
export const FADE_MS: number
export const PREFILL_STAGGER_MS: number

export function progressElement(controller: SossegoController): HTMLElement | null
export function showProgress(controller: SossegoController, state: string, message: string | null): HTMLElement | null

export default class SossegoController extends Controller<HTMLElement> {
  // Event name => the name of the method that handles it, merged over the
  // parent class's.
  static events: Record<string, string>

  urlValue: string
  lastEventIdValue: string
  awaitTaskValue: boolean
  taskTimeoutValue: number
  stalledMessageValue: string
  reconnectingMessageValue: string
  closedMessageValue: string

  open(): void
  close(): void
  awaitTask(): void
  stopAwaitingTask(): void
  readonly awaitingTask: boolean

  progress(message: string, event: SossegoEvent<string>): void
  progressWarning(message: string, event: SossegoEvent<string>): void | Promise<void>
  errorMessage(message: string, event: SossegoEvent<string>): void
  progressFinished(payload: unknown, event: SossegoEvent): void | Promise<void>
  fieldPrefill(fields: Record<string, unknown> | null, event: SossegoEvent): Promise<void>
  turboStream(html: string, event: SossegoEvent<string>): void
  visit(url: string, event: SossegoEvent<string>): void
}
