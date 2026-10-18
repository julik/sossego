import { describe, expect, it } from "vitest"

import { compareCursors, maxCursor } from "@sossego/client"

describe("compareCursors", () => {
  it("orders decimal cursors of different lengths by length", () => {
    expect(compareCursors("99", "119")).toBeLessThan(0)
    expect(compareCursors("119", "99")).toBeGreaterThan(0)
    expect(compareCursors("9", "10")).toBeLessThan(0)
    expect(compareCursors("9007199254740993", "9007199254740992")).toBeGreaterThan(0)
    expect(compareCursors("12345678901234567890", "9")).toBeGreaterThan(0)
  })

  it("orders decimal cursors of equal length lexicographically", () => {
    expect(compareCursors("119", "120")).toBeLessThan(0)
    expect(compareCursors("120", "119")).toBeGreaterThan(0)
    expect(compareCursors("119", "119")).toBe(0)
  })

  it("orders UUID-shaped cursors lexicographically", () => {
    const earlier = "0190a8e2-7c3b-7d4e-8f00-000000000001"
    const later = "0190a8e2-7c3b-7d4e-8f00-00000000000a"
    const muchLater = "0191ffff-0000-7000-8000-000000000000"

    expect(compareCursors(earlier, later)).toBeLessThan(0)
    expect(compareCursors(later, muchLater)).toBeLessThan(0)
    expect(compareCursors(muchLater, earlier)).toBeGreaterThan(0)
    expect(compareCursors(earlier, earlier)).toBe(0)
  })

  it("treats the empty string as older than any cursor", () => {
    expect(compareCursors("", "0")).toBeLessThan(0)
    expect(compareCursors("1", "")).toBeGreaterThan(0)
  })
})

describe("maxCursor", () => {
  it("returns the newer cursor", () => {
    expect(maxCursor("99", "119")).toBe("119")
    expect(maxCursor("120", "119")).toBe("120")
    expect(maxCursor("7", "7")).toBe("7")
  })
})
