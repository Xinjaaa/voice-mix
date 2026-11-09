import { invoke, isTauri } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import type { Request, Snapshot } from './types';
export const desktop = isTauri();
export const preview: Snapshot = {
  serviceInstanceId: "preview",
  devices: [
    { id: 'speaker::output', uid: 'speaker', name: 'MacBook 扬声器', direction: 'output', isDefault: true, volume: .7, muted: false, canSetVolume: true, canMute: true },
    { id: 'mic::input', uid: 'mic', name: 'MacBook 麦克风', direction: 'input', isDefault: true, volume: .45, muted: null, canSetVolume: true, canMute: false },
  ],
  apps: [{ id: 'music', name: '音乐', processCount: 1, controllable: true, controlled: false, error: null, callbackCount: 0 }, { id: 'browser', name: '浏览器', processCount: 2, controllable: true, controlled: false, error: null, callbackCount: 0 }],
  rules: {}, capturePermission: 'unknown', mixingEnabled: false, revision: 0, configError: null,
};
let simulated = structuredClone(preview);
export async function request(req: Request): Promise<Snapshot> {
  if (desktop) return invoke<Snapshot>('audio_request', { request: req });
  if (req.op === 'enable_mixing') simulated.mixingEnabled = true;
  if (req.op === 'restore') { simulated.mixingEnabled = false; simulated.apps.forEach(a => a.controlled = false); }
  if (req.op === 'app_control') {
    simulated.rules[String(req.appId)] = { volume: Number(req.volume), muted: Boolean(req.muted) };
    const a = simulated.apps.find(a => a.id === req.appId); if (a) a.controlled = Number(req.volume) < 1 || Boolean(req.muted);
  }
  if (req.op === 'app_reset') { delete simulated.rules[String(req.appId)]; const a = simulated.apps.find(a => a.id === req.appId); if (a) a.controlled = false; }
  const d = simulated.devices.find(d => d.uid === req.uid && d.direction === req.direction);
  if (d && req.op === 'device_volume') d.volume = Number(req.volume);
  if (d && req.op === 'device_mute') d.muted = Boolean(req.muted);
  if (d && req.op === 'device_default') simulated.devices.forEach(x => { if (x.direction === d.direction) x.isDefault = x === d; });
  simulated.revision++; return structuredClone(simulated);
}
export async function subscribe(onState: (s: Snapshot) => void, onError: (e: string) => void) {
  if (!desktop) return () => {};
  const stateListener = await listen<Snapshot>('audio-state-changed', e => onState(e.payload));
  try {
    const errorListener = await listen<string>('audio-error', e => onError(e.payload));
    return () => { stateListener(); errorListener(); };
  } catch (error) { stateListener(); throw error; }
}
export function describeError(error: unknown): string {
  const text = String(error);
  try {
    const detail = JSON.parse(text) as { code: string; message: string; platformCode?: number };
    const labels: Record<string, string> = { Unsupported: '暂不支持此音频路径', DeviceUnavailable: '设备已断开', SessionUnavailable: '应用已停止播放', BackendFailure: '音频操作失败，请检查系统音频录制权限', InvalidArgument: '音量参数无效', PermissionDenied: '请在系统设置中允许音频录制' };
    return `${labels[detail.code] || '操作失败'}：${detail.message}${detail.platformCode ? ` (${detail.platformCode})` : ''}`;
  } catch { return text; }
}
