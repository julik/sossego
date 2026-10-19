/**
 * Sossego stream client. Framework-agnostic: no React, no Stimulus, no DOM
 * beyond EventSource. The wire format is specified in WIRE_FORMAT.md at the
 * root of the gem.
 *
 * Plain ES module, no build step needed. Types are in JSDoc, and in
 * sossego.d.ts for TypeScript consumers.
 *
 * @example Resume from a known cursor and learn why the stream ended
 *   import { createSossegoStream } from "@sossego/client"
 *
 *   const stream = createSossegoStream({
 *     url: "/inbox_stream?account=42",
 *     lastEventId: "118",                       // first connect sends last_event_id=118
 *     onEvent: ({ eventName, seq, sseq, payload }) => console.log(eventName, seq, sseq, payload),  // every event
 *     onGap: (event, expectedSseq) => refetchEverything(),
 *     onPing: (ping) => console.log("head is", ping.head),
 *     onClose: (reason, seq) => console.log(reason, seq),  // "over_budget", null
 *   })
 *   stream.close()
 *
 * @example Handle events by name
 *   import { createSossegoStream } from "@sossego/client"
 *
 *   createSossegoStream({
 *     url,
 *     events: {
 *       inbox_changed: () => refresh(),
 *       email_added: (email, event) => emailStore.add(email),
 *     },
 *   })
 */

// ---------------------------------------------------------------------------
// Cursors
// ---------------------------------------------------------------------------

/**
 * Compare two cursors: a shorter string is smaller; strings of equal length
 * compare lexicographically. Correct for decimal ids without leading zeros
 * and for fixed-width lowercase UUIDs. Cursors are opaque: never `Number()`,
 * never `Math.max`, never `<` or `>` - use this.
 *
 * @param {string} a
 * @param {string} b
 * @returns {number} negative when `a` is older, positive when newer, 0 when equal
 */
export function compareCursors(a, b) {
  if (a.length !== b.length) return a.length - b.length
  if (a === b) return 0
  return a < b ? -1 : 1
}

/**
 * The newer of two cursors (by {@link compareCursors}).
 *
 * @param {string} a
 * @param {string} b
 * @returns {string}
 */
export function maxCursor(a, b) {
  return compareCursors(a, b) >= 0 ? a : b
}

// ---------------------------------------------------------------------------
// Frame decoding
// ---------------------------------------------------------------------------

export class SossegoDecodeError extends Error {
  /** @param {string} message */
  constructor(message) {
    super(message)
    this.name = "SossegoDecodeError"
  }
}

/**
 * A decoded envelope.
 *
 * @typedef {Object} Frame
 * @property {string} fmt how `pld` was encoded on the wire
 * @property {string} evt the application's event name, or `ping` / `close`
 * @property {string} [seq] the cursor; only on frames with a position
 * @property {number} [sseq] the stream sequence; only on frames with a position
 * @property {string} [head] the stream's head cursor; on positioned frames and pings
 * @property {string} [sid] the stream id; only on frames with a position
 * @property {*} pld the payload, decoded
 */

/** @type {Map<string, (pld: unknown) => unknown>} */
const payloadDecoders = new Map()

/**
 * Register (or replace) the `pld` decoder for a `fmt`. The decoder may
 * return a Promise; the client keeps wire order either way.
 *
 * @example
 *   registerPayloadDecoder("b64json", (pld) => JSON.parse(atob(pld)))
 *
 * @param {string} fmt
 * @param {(pld: unknown) => unknown} decoder
 */
export function registerPayloadDecoder(fmt, decoder) {
  payloadDecoders.set(fmt, decoder)
}

const base64ToBytes = (base64) => Uint8Array.from(atob(String(base64)), (c) => c.charCodeAt(0))

const gunzip = async (base64) => {
  const stream = new Response(base64ToBytes(base64)).body.pipeThrough(new DecompressionStream("gzip"))
  return new Uint8Array(await new Response(stream).arrayBuffer())
}

const utf8 = new TextDecoder()

// A JSON value, as-is.
registerPayloadDecoder("ejson", (pld) => pld)
// A string, as-is.
registerPayloadDecoder("text", (pld) => pld)
// Bytes, as base64. Handed over as a Uint8Array.
registerPayloadDecoder("bytes", (pld) => base64ToBytes(pld))
// The same three gzipped, as base64: what a server body configured with
// `compress_above_bytes` writes, or what was published with a `gz:` fmt.
registerPayloadDecoder("gz:ejson", async (pld) => JSON.parse(utf8.decode(await gunzip(pld))))
registerPayloadDecoder("gz:text", async (pld) => utf8.decode(await gunzip(pld)))
registerPayloadDecoder("gz:bytes", (pld) => gunzip(pld))

/**
 * Decode the `data:` text of a frame: parse the envelope, then run `pld`
 * through the decoder its `fmt` names.
 *
 * @param {string} raw
 * @returns {Promise<Frame>}
 * @throws {SossegoDecodeError} on malformed JSON, a missing or unknown `fmt`,
 *   or when the decoder fails
 */
export async function decodeFrame(raw) {
  let envelope
  try {
    envelope = JSON.parse(raw)
  } catch (err) {
    throw new SossegoDecodeError(`malformed sossego frame: ${err.message}`)
  }
  if (typeof envelope !== "object" || envelope === null || Array.isArray(envelope)) {
    throw new SossegoDecodeError("sossego frame is not a JSON object")
  }
  if (typeof envelope.fmt !== "string") {
    throw new SossegoDecodeError("sossego frame has no fmt")
  }
  const decoder = payloadDecoders.get(envelope.fmt)
  if (!decoder) {
    throw new SossegoDecodeError(`unknown sossego fmt: ${envelope.fmt}`)
  }

  let pld
  try {
    pld = await decoder(envelope.pld)
  } catch (err) {
    throw new SossegoDecodeError(`malformed ${envelope.fmt} pld: ${err.message}`)
  }
  return { ...envelope, pld }
}

// ---------------------------------------------------------------------------
// Queue
// ---------------------------------------------------------------------------

/**
 * A tiny concurrency-limited promise queue.
 * @see https://blog.julik.nl/2025/05/a-tiny-promise-queue
 *
 * `push(fn)` returns a Promise resolving to the result of `fn`. With a
 * concurrency of 1 the next task can't start until the previous one
 * resolves or rejects (errors don't break the queue).
 *
 * @param {number} maxConcurrent
 */
export function createQueue(maxConcurrent) {
  /** @type {Array<() => void>} */
  const tasks = []
  let running = 0

  const startNext = () => {
    if (running >= maxConcurrent) return
    const nextTask = tasks.shift()
    if (!nextTask) return
    running++
    nextTask()
  }

  return {
    get running() {
      return running
    },
    get pending() {
      return tasks.length
    },
    /**
     * @template T
     * @param {() => Promise<T>} asyncStartFn
     * @returns {Promise<T>}
     */
    push(asyncStartFn) {
      return new Promise((resolve, reject) => {
        tasks.push(() => {
          asyncStartFn()
            .then(resolve, reject)
            .finally(() => {
              running--
              startNext()
            })
        })
        startNext()
      })
    },
  }
}

// ---------------------------------------------------------------------------
// The stream
// ---------------------------------------------------------------------------

/**
 * @typedef {Object} SossegoEvent
 * @property {string} id SSE id field - same value as `seq`
 * @property {string} eventName the application's event name (the envelope's `evt`)
 * @property {string} seq the cursor, compared only with `compareCursors`
 * @property {number} sseq position within the stream; for gap detection, never a cursor
 * @property {string} head the stream's head cursor when the frame was written
 * @property {string} streamId the envelope's `sid`
 * @property {*} payload decoded payload (the envelope's `pld`)
 */

/**
 * @typedef {Object} SossegoStreamState
 * @property {"connecting" | "open" | "reconnecting" | "closed"} status
 * @property {string | null} lastEventId
 */

/**
 * @typedef {Object} SossegoStreamOptions
 * @property {string} url
 * @property {string | null} [lastEventId] cursor for the first connect, sent
 *   as `last_event_id`. Without it the server decides where to start.
 * @property {Record<string, (payload: any, event: SossegoEvent) => unknown>} [events]
 *   handlers by event name, each given the decoded payload and the whole
 *   event. An event with no handler here is ignored.
 * @property {(event: SossegoEvent) => unknown} [onEvent] called
 *   for every event, before its handler in `events`.
 * @property {(event: SossegoEvent, expectedSseq: number) => void} [onGap]
 *   called before an event whose `sseq` is not the previous one plus one:
 *   events were pruned or skipped, or the stream was reset. The first event
 *   a stream delivers is never a gap.
 * @property {(reason: string, seq: string | null) => void} [onClose] called
 *   once when a `close` frame ends the stream for good, after every event
 *   received before it. `seq` is null for a refusal.
 * @property {(err: Event | Error) => void} [onError] an `Event` for a
 *   connection error, an `Error` for a frame that could not be decoded or a
 *   handler that threw
 * @property {(state: SossegoStreamState) => void} [onStateChange]
 * @property {(ping: {head: string, time: string}) => void} [onPing]
 * @property {number} [stallThresholdMs] reopen when no frame arrives for this
 *   long. The server pings every 10s.
 * @property {boolean} [withCredentials] passed to EventSource, default true
 */

// The only SSE event names sossego uses. Application names ride inside
// the envelope as `evt`.
const SSE_EVENT_SOSSEGO = "sossego"
const SSE_EVENT_PING = "ping"
const SSE_EVENT_CLOSE = "close"

const DEFAULT_STALL_MS = 25_000
// Reopen delay after a failed connection: doubles per failure in a row from
// MIN to MAX, plus up to one more base delay of jitter (still capped at MAX).
const RECONNECT_BACKOFF_MIN_MS = 3_000
const RECONNECT_BACKOFF_MAX_MS = 60_000
// When the pipe goes idle and we tear the connection down ourselves, wait
// this long before reconnecting. A quiet-but-wedged stream would otherwise
// reconnect-spam with the same lastEventId; the gap also frees the
// server-side thread between attempts.
const IDLE_RECONNECT_DELAY_MS = 2_000

const ES_CLOSED = 2

/**
 * Open a stream. Owns the EventSource lifecycle, frame decoding, gap and
 * stall detection.
 *
 * Exactly three SSE names are listened to: `sossego`, `ping` and `close`.
 * `sossego` and `close` frames go through a sequential queue that decodes
 * them one at a time and calls the handlers (`onEvent`, then the one in
 * `events`) in wire order, even when a payload decoder is async (gzip); a
 * `close` is handled after every event received before it. Handlers are
 * called, not waited for: one that returns a promise runs on alongside the
 * next events, and its rejection goes to `onError`. To serialize your own async
 * work, put it on a queue of your own (`createQueue(1)`). Pings reset the stall timer
 * on arrival and bypass the queue. A connection error keeps that order too,
 * so the end of a response that a `close` frame ended is never reported.
 *
 * If no frame arrives within `stallThresholdMs` the connection is closed
 * and reopened. If the browser gives up on the EventSource (readyState
 * CLOSED, typically a non-2xx during a server restart) it is reopened after
 * a backoff that doubles from 3s to 60s, with jitter. A delivered frame
 * resets the backoff.
 *
 * @param {SossegoStreamOptions} opts
 * @returns {{ close(): void }}
 */
export function createSossegoStream(opts) {
  const stallMs = opts.stallThresholdMs ?? DEFAULT_STALL_MS

  /** @type {EventSource | null} */
  let source = null
  let stallTimer = null
  let reconnectTimer = null
  let lastEventId = opts.lastEventId ?? null
  /** @type {number | null} */
  let lastSseq = null
  let closedByConsumer = false
  // Failed connections in a row since the last delivered frame.
  let failedConnections = 0

  const nextReconnectBackoffMs = () => {
    const base = Math.min(RECONNECT_BACKOFF_MAX_MS, RECONNECT_BACKOFF_MIN_MS * 2 ** failedConnections)
    failedConnections += 1
    return Math.min(RECONNECT_BACKOFF_MAX_MS, base * (1 + Math.random()))
  }

  const clearReconnectTimer = () => {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer)
      reconnectTimer = null
    }
  }

  const queue = createQueue(1)

  const setState = (state) => opts.onStateChange?.(state)

  // Called in wire order, but not waited for: what a handler does after it
  // returns is its own business. Its rejection still lands in onError.
  const callHandler = (handler, ...args) => {
    try {
      const result = handler(...args)
      if (typeof result?.then === "function") result.then(undefined, handleErr)
    } catch (err) {
      handleErr(err)
    }
  }

  // `opts.events` is read for each event, so its handlers can change. Own
  // properties only: an event named `constructor` is not Object's.
  const handlerFor = (eventName) => {
    const events = opts.events
    return events && Object.hasOwn(events, eventName) ? events[eventName] : undefined
  }

  const handleErr = (e) => {
    opts.onError?.(e instanceof Error || e instanceof Event ? e : new Error(String(e)))
  }

  const resetStallTimer = () => {
    if (stallTimer) clearTimeout(stallTimer)
    stallTimer = setTimeout(() => {
      if (source && !closedByConsumer) {
        source.close()
        setState({ status: "reconnecting", lastEventId })
        clearReconnectTimer()
        reconnectTimer = setTimeout(() => connect(), IDLE_RECONNECT_DELAY_MS)
      }
    }, stallMs)
  }

  // A frame arrived: the connection delivers.
  const frameArrived = () => {
    resetStallTimer()
    failedConnections = 0
  }

  // Decodes in the queue, one frame at a time, so frames are handed over in
  // wire order and no two payloads are inflated at once. The handler is
  // called from the queue but not waited for.
  const enqueueFrame = (handle, raw) => {
    queue
      .push(async () => {
        if (closedByConsumer) return
        let frame
        try {
          frame = await decodeFrame(raw)
        } catch (err) {
          handleErr(err)
          return
        }
        if (closedByConsumer) return
        await handle(frame)
      })
      .catch(() => {})
  }

  const handleSossegoFrame = (sseId, raw) => {
    frameArrived()
    enqueueFrame(async (frame) => {
      const { seq, sseq, head, sid } = frame
      if (typeof seq !== "string" || typeof sseq !== "number" || typeof head !== "string" || typeof sid !== "string") {
        handleErr(new Error(`sossego frame without a position: ${frame.evt}`))
        return
      }

      const id = sseId || seq
      lastEventId = id
      setState({ status: "open", lastEventId })

      const event = { id, eventName: frame.evt, seq, sseq, head, streamId: sid, payload: frame.pld }
      const expectedSseq = lastSseq === null ? sseq : lastSseq + 1
      lastSseq = sseq
      if (sseq !== expectedSseq && opts.onGap) callHandler(opts.onGap, event, expectedSseq)
      if (opts.onEvent) callHandler(opts.onEvent, event)
      const handler = handlerFor(event.eventName)
      if (handler) callHandler(handler, event.payload, event)
    }, raw)
  }

  const handleCloseFrame = (sseId, raw) => {
    frameArrived()
    enqueueFrame((frame) => {
      // A refusal has no position and must not move the cursor.
      const seq = typeof frame.seq === "string" ? frame.seq : null
      if (seq !== null) lastEventId = sseId || seq
      const reason = typeof frame.pld?.reason === "string" ? frame.pld.reason : ""

      closedByConsumer = true
      source?.close()
      if (stallTimer) clearTimeout(stallTimer)
      clearReconnectTimer()
      setState({ status: "closed", lastEventId })
      opts.onClose?.(reason, seq)
    }, raw)
  }

  const handlePingFrame = (raw) => {
    frameArrived()
    const onPing = opts.onPing
    if (!onPing) return
    decodeFrame(raw).then(
      (frame) => {
        if (!closedByConsumer) onPing(frame.pld)
      },
      () => {}, // malformed ping: the stall timer is reset already
    )
  }

  const connect = () => {
    if (closedByConsumer) return
    clearReconnectTimer()
    setState({ status: source ? "reconnecting" : "connecting", lastEventId })

    // Pass last_event_id as a query param so manual reopens (when the
    // browser put EventSource into CLOSED) still resume from the right
    // cursor. Native auto-reconnects send the Last-Event-ID header
    // themselves; the server prefers the header.
    const url = lastEventId
      ? `${opts.url}${opts.url.includes("?") ? "&" : "?"}last_event_id=${encodeURIComponent(lastEventId)}`
      : opts.url

    source = new EventSource(url, { withCredentials: opts.withCredentials ?? true })
    source.onopen = () => {
      setState({ status: "open", lastEventId })
      resetStallTimer()
    }
    const handleConnectionError = (err) => {
      // A frame handled first may have been a `close`: the end of its
      // response is not an error.
      if (closedByConsumer) return
      opts.onError?.(err)

      if (source && source.readyState === ES_CLOSED) {
        if (stallTimer) clearTimeout(stallTimer)
        setState({ status: "reconnecting", lastEventId })
        clearReconnectTimer()
        reconnectTimer = setTimeout(() => connect(), nextReconnectBackoffMs())
      } else {
        setState({ status: "reconnecting", lastEventId })
        resetStallTimer()
      }
    }
    source.onerror = (err) => {
      // In order with frames: while one is still in the queue, the error
      // waits its turn. With none in flight it is handled at once.
      if (queue.running || queue.pending) {
        queue.push(async () => handleConnectionError(err)).catch(() => {})
      } else {
        handleConnectionError(err)
      }
    }
    source.addEventListener(SSE_EVENT_SOSSEGO, (e) => handleSossegoFrame(e.lastEventId, e.data))
    source.addEventListener(SSE_EVENT_PING, (e) => handlePingFrame(e.data))
    source.addEventListener(SSE_EVENT_CLOSE, (e) => handleCloseFrame(e.lastEventId, e.data))
  }

  connect()

  return {
    close() {
      closedByConsumer = true
      if (stallTimer) clearTimeout(stallTimer)
      clearReconnectTimer()
      source?.close()
      setState({ status: "closed", lastEventId })
    },
  }
}
