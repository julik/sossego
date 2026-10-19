// Types for sossego.js. The module itself is plain JavaScript; nothing here
// is needed to use it.

export interface SossegoEvent<T = any, N extends string = string> {
  id: string
  eventName: N
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

// Payload types by event name, e.g. `{ poof: Uint8Array<ArrayBuffer>; chat_message: Message }`.
export type SossegoEventMap = Record<string, any>

// One of the map's events, narrowed by `eventName`.
export type SossegoEventOf<M extends SossegoEventMap> = {
  [N in keyof M & string]: SossegoEvent<M[N], N>
}[keyof M & string]

export type SossegoHandlers<M extends SossegoEventMap> = {
  [N in keyof M & string]?: (payload: M[N], event: SossegoEvent<M[N]>) => unknown
}

export interface SossegoStreamOptions<M extends SossegoEventMap = SossegoEventMap> {
  url: string
  lastEventId?: string | null
  events?: SossegoHandlers<M>
  // What a handler returns is ignored, except that a rejected promise goes to onError.
  onEvent?: (event: SossegoEventOf<M>) => unknown
  onGap?: (event: SossegoEventOf<M>, expectedSseq: number) => void
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

export function createSossegoStream<M extends SossegoEventMap = SossegoEventMap>(opts: SossegoStreamOptions<M>): SossegoStreamHandle
export function compareCursors(a: string, b: string): number
export function maxCursor(a: string, b: string): string
export function decodeFrame<T = any>(raw: string): Promise<Frame<T>>
export function registerPayloadDecoder(fmt: string, decoder: (pld: unknown) => unknown): void
export function createQueue(maxConcurrent: number): {
  readonly running: number
  readonly pending: number
  push<R>(fn: () => Promise<R>): Promise<R>
}
export class SossegoDecodeError extends Error {}
