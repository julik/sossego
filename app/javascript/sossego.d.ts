// Types for sossego.js. The module itself is plain JavaScript; nothing here
// is needed to use it.

export interface SossegoEvent<T = any> {
  id: string
  eventName: string
  seq: string
  sseq: number
  head: string
  streamId: string
  payload: T
}

export interface SossegoStreamState {
  status: "connecting" | "open" | "reconnecting" | "closed"
  lastEventId: string | null
}

export interface SossegoStreamOptions<T = any> {
  url: string
  lastEventId?: string | null
  onEvent: (event: SossegoEvent<T>) => void | Promise<void>
  onGap?: (event: SossegoEvent<T>, expectedSseq: number) => void
  onClose?: (reason: string, seq: string | null) => void
  onError?: (err: Event | Error) => void
  onStateChange?: (state: SossegoStreamState) => void
  onPing?: (ping: { head: string; time: string }) => void
  stallThresholdMs?: number
  withCredentials?: boolean
}

export interface Frame<T = any> {
  fmt: string
  evt: string
  seq?: string
  sseq?: number
  head?: string
  sid?: string
  pld: T
}

export interface SossegoStreamHandle {
  close(): void
}

export function createSossegoStream<T = any>(opts: SossegoStreamOptions<T>): SossegoStreamHandle
export function compareCursors(a: string, b: string): number
export function maxCursor(a: string, b: string): string
export function decodeFrame<T = any>(raw: string): Promise<Frame<T>>
export function registerPayloadDecoder(fmt: string, decoder: (pld: unknown) => unknown): void
export function createQueue(maxConcurrent: number): {
  readonly running: number
  readonly pending: number
  push<R>(fn: () => Promise<R>): Promise<R>
}
export function createDispatcher(): {
  on<T = any>(eventName: string, handle: (payload: T, event: SossegoEvent<T>) => void | Promise<void>): void
  off(eventName: string): void
  dispatch(event: SossegoEvent): void | Promise<void>
}
export class SossegoDecodeError extends Error {}
