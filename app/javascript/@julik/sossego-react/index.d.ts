import type { SossegoEventMap, SossegoStreamOptions, SossegoStreamState } from "@julik/sossego-client"

export function useSossegoStream<M extends SossegoEventMap = SossegoEventMap>(
  opts: SossegoStreamOptions<M> & { enabled?: boolean },
): SossegoStreamState
