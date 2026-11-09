import { describe, expect, it } from 'vitest';
import { SnapshotOrder } from './snapshot-order';
import { preview } from './audio';
describe('SnapshotOrder',()=>{
  it('ignores a delayed command response after a newer event',()=>{
    const order=new SnapshotOrder();
    expect(order.accept({...preview,revision:8})).toBe(true);
    expect(order.accept({...preview,revision:5})).toBe(false);
  });
  it('accepts a fresh backend revision and rejects retired instance events',()=>{
    const order=new SnapshotOrder();
    expect(order.accept({...preview,serviceInstanceId:'old',revision:900})).toBe(true);
    expect(order.accept({...preview,serviceInstanceId:'new',revision:1})).toBe(true);
    expect(order.accept({...preview,serviceInstanceId:'old',revision:901})).toBe(false);
  });
});
