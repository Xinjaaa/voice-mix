import type { Snapshot } from './types';
/** Full snapshots from a single backend instance can arrive via events or commands. */
export class SnapshotOrder {
  private instance: string | undefined;
  private revision = -1;
  private readonly retired = new Set<string>();
  accept(snapshot: Snapshot) {
    if (this.retired.has(snapshot.serviceInstanceId)) return false;
    if (this.instance !== snapshot.serviceInstanceId) { if (this.instance) this.retired.add(this.instance); this.instance = snapshot.serviceInstanceId; this.revision = -1; }
    if (snapshot.revision < this.revision) return false;
    this.revision = snapshot.revision;
    return true;
  }
}
