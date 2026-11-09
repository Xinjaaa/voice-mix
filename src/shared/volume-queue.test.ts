import { afterEach, describe, expect, it, vi } from 'vitest';
import { VolumeQueue } from './volume-queue';
afterEach(() => vi.useRealTimers());
describe('VolumeQueue', () => {
  it('keeps the newest value while a native operation is pending', async () => {
    const values:number[]=[];
    let release:()=>void=()=>{};
    const first = new Promise<void>(resolve => release=resolve);
    const queue=new VolumeQueue(async value=>{values.push(value);if(values.length===1)await first;});
    queue.schedule(.2);const done=queue.flush();
    queue.schedule(.4);queue.schedule(.7);release();await done;
    expect(values).toEqual([.2,.7]);expect(queue.isPending()).toBe(false);queue.dispose();
  });
  it('cancels a pending draft when its device row is unmounted', async () => {
    vi.useFakeTimers();const apply=vi.fn(async()=>{});const queue=new VolumeQueue(apply);
    queue.schedule(.3);queue.dispose();await vi.runAllTimersAsync();expect(apply).not.toHaveBeenCalled();
  });
  it('coalesces keyboard changes and eventually sends the last value', async () => {
    vi.useFakeTimers();const apply=vi.fn(async()=>{});const queue=new VolumeQueue(apply);
    queue.schedule(.31);queue.schedule(.32);queue.schedule(.33);
    await vi.advanceTimersByTimeAsync(40);expect(apply).toHaveBeenCalledExactlyOnceWith(.33);queue.dispose();
  });
});
