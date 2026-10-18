/**
 * React hook around {@link createSossegoStream}. Owns the connection for
 * the lifetime of the component; closes on unmount. Reopens when `url` or
 * `enabled` change; the callbacks can change on every render.
 *
 * @example
 *   const state = useSossegoStream({ url, onEvent: (e) => console.log(e.eventName) })
 *   state.status // "connecting" | "open" | "reconnecting" | "closed"
 */
import { useEffect, useRef, useState } from "react"
import { createSossegoStream } from "sossego"

const CLOSED = { status: "closed", lastEventId: null }

/**
 * @param {import("sossego").SossegoStreamOptions & { enabled?: boolean }} opts
 *   `enabled` defaults to true; set it false to pause without unmounting
 * @returns {import("sossego").SossegoStreamState}
 */
export function useSossegoStream(opts) {
  const [state, setState] = useState({ status: "connecting", lastEventId: null })
  const optsRef = useRef(opts)
  useEffect(() => {
    optsRef.current = opts
  }, [opts])

  useEffect(() => {
    if (opts.enabled === false) {
      setState(CLOSED)
      return
    }
    const handle = createSossegoStream({
      url: opts.url,
      // Read at connect only: a new cursor alone does not reopen the stream.
      lastEventId: optsRef.current.lastEventId,
      stallThresholdMs: opts.stallThresholdMs,
      withCredentials: opts.withCredentials,
      onEvent: (e) => optsRef.current.onEvent(e),
      onGap: (e, expected) => optsRef.current.onGap?.(e, expected),
      onClose: (reason, seq) => optsRef.current.onClose?.(reason, seq),
      onError: (e) => optsRef.current.onError?.(e),
      onPing: (p) => optsRef.current.onPing?.(p),
      onStateChange: setState,
    })
    return () => handle.close()
  }, [opts.url, opts.enabled])

  return state
}
