import { Controller } from "@hotwired/stimulus"
import type { SossegoEvent } from "@sossego/client"

export interface SossegoHandlerContext {
  controller: SossegoController
  event: SossegoEvent
}

export type SossegoHandler = (payload: any, context: SossegoHandlerContext) => void | Promise<void>

export const FINISHED_LINGER_MS: number
export const WARNING_LINGER_MS: number
export const FADE_MS: number
export const PREFILL_STAGGER_MS: number

export const handlers: Record<string, SossegoHandler>
export function registerHandler(eventName: string, handler: SossegoHandler): void
export function progressElement(controller: SossegoController): HTMLElement | null
export function showProgress(controller: SossegoController, state: string, message: string | null): HTMLElement | null

export default class SossegoController extends Controller<HTMLElement> {
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
}
