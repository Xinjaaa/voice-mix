/** Serialize updates for one slider and coalesce drafts while an operation is pending. */
export class VolumeQueue {
  private next: number | undefined;
  private running = false;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private stopped = false;
  constructor(private readonly apply: (value: number) => Promise<void>, private readonly onSettled: () => void = () => {}) {}
  schedule(value: number) {
    if (this.stopped) return;
    this.next = value;
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => { void this.flush(); }, 40);
  }
  async flush() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    if (this.running || this.stopped) return;
    this.running = true;
    try {
      while (this.next !== undefined && !this.stopped) {
        const value = this.next; this.next = undefined;
        await this.apply(value);
      }
    } finally { this.running = false; if (!this.stopped) this.onSettled(); }
  }
  isPending() { return this.running || this.next !== undefined; }
  dispose() { this.stopped = true; this.next = undefined; if (this.timer) clearTimeout(this.timer); }
}
