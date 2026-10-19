import type { SossegoEventMap, SossegoStreamOptions, SossegoStreamState } from "@sossego/client"

export function useSossegoStream<M extends SossegoEventMap = SossegoEventMap>(
  opts: SossegoStreamOptions<M> & { enabled?: boolean },
): SossegoStreamState
