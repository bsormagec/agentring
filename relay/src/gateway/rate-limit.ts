/**
 * In-memory fixed-window counters (one window per key). Good enough for abuse limits
 * on a single gateway process; a restart resets them.
 */
export class RateLimiter {
  private readonly windows = new Map<string, { start: number; count: number }>();

  constructor(
    private readonly windowMs: number,
    /** Keys remembered at most; expired windows go first, then the oldest. */
    private readonly maxKeys = 100_000,
  ) {}

  /** Counts one hit for `key`; false if that would go over `limit` in the current window. */
  take(key: string, limit: number, now = Date.now()): boolean {
    let w = this.windows.get(key);
    if (!w || now - w.start >= this.windowMs) {
      w = { start: now, count: 0 };
      this.windows.delete(key);
      this.windows.set(key, w);
      this.prune(now);
    }
    if (w.count >= limit) return false;
    w.count++;
    return true;
  }

  private prune(now: number): void {
    if (this.windows.size <= this.maxKeys) return;
    for (const [k, w] of this.windows) {
      if (this.windows.size <= this.maxKeys && now - w.start < this.windowMs) break;
      this.windows.delete(k);
    }
  }
}
