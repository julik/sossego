import type { SossegoStreamOptions, SossegoStreamState } from "sossego"

export function useSossegoStream<T = any>(opts: SossegoStreamOptions<T> & { enabled?: boolean }): SossegoStreamState
