// Types for sossego/testing.

export interface FrameEnvelope {
  fmt?: string
  evt: string
  seq?: string
  sseq?: number
  head?: string
  sid?: string
  pld: unknown
}

export function frameData(envelope: FrameEnvelope): string
export function eventData(evt: string, seq: string, sseq: number, head: string, pld: unknown, sid?: string): string
export function pingData(head: string, time?: string): string
export function closeData(reason: string, position?: { seq: string; sseq: number; head: string; sid: string }): string

export type FakeEventListener = (event: MessageEvent) => void

export class FakeEventSource {
  static instances: FakeEventSource[]
  static lastInstance(): FakeEventSource | undefined
  static reset(): void
  static readonly CONNECTING: 0
  static readonly OPEN: 1
  static readonly CLOSED: 2

  url: string
  withCredentials: boolean
  readyState: number
  onopen: ((e: Event) => void) | null
  onmessage: ((e: MessageEvent) => void) | null
  onerror: ((e: Event) => void) | null

  constructor(url: string, init?: { withCredentials?: boolean })
  addEventListener(kind: string, listener: FakeEventListener): void
  removeEventListener(kind: string, listener: FakeEventListener): void
  listenedNames(): string[]
  close(): void
  isClosed(): boolean
  simulateOpen(): void
  simulateEvent(kind: string, id: string, data: string): void
  simulateMessage(id: string, data: string): void
  simulateError(options?: { browserGivesUp?: boolean }): void
}

export function installFakeEventSource(): () => void
