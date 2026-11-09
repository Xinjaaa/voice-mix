export interface Device { id: string; uid: string; name: string; direction: 'input' | 'output'; isDefault: boolean; volume: number | null; muted: boolean | null; canSetVolume: boolean; canMute: boolean }
export interface AppAudio { id: string; name: string; processCount: number; controllable: boolean; controlled: boolean; error: string | null; unsupportedReason?: string | null; callbackCount: number }
export interface Rule { volume: number; muted: boolean }
export interface Snapshot { serviceInstanceId: string; devices: Device[]; apps: AppAudio[]; rules: Record<string, Rule>; capturePermission: string; mixingEnabled: boolean; revision: number; configError: string | null }
export type Request = { op: string; [key: string]: unknown };
