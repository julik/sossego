import type { SossegoStreamOptions, SossegoStreamState } from "@sossego/client"

export function useSossegoStream<T = any>(opts: SossegoStreamOptions<T> & { enabled?: boolean }): SossegoStreamState
