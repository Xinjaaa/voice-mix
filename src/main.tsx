import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { invoke } from '@tauri-apps/api/core';
import { AudioLines, Volume2, VolumeX, Mic, Headphones, RotateCcw, SlidersHorizontal, ChevronDown, Check, Power, ShieldCheck, X } from 'lucide-react';
import { desktop, request, subscribe, describeError } from './shared/audio';
import type { AppAudio, Device, Request, Snapshot } from './shared/types';
import { VolumeQueue } from './shared/volume-queue';
import { SnapshotOrder } from './shared/snapshot-order';
import './style.css';

function VolumeSlider({ value, disabled, label, onChange }: {value: number | null; disabled: boolean; label: string; onChange: (v: number) => Promise<void>}) {
  const [draft, setDraft] = useState(value ?? 0);
  const [dragging, setDragging] = useState(false);
  const [settled, setSettled] = useState(0);
  const change = useRef(onChange); change.current = onChange;
  const queue = useRef<VolumeQueue | null>(null);
  useEffect(() => {
    queue.current = new VolumeQueue(v => change.current(v), () => setSettled(n => n + 1));
    return () => { queue.current?.dispose(); queue.current = null; };
  }, []);
  useEffect(() => { if (!dragging && !queue.current?.isPending()) setDraft(value ?? 0); }, [value, dragging, settled]);
  function update(next: number) { setDraft(next); queue.current?.schedule(next); }
  function finish() { setDragging(false); void queue.current?.flush(); }
  return <div className="slider-line"><input aria-label={label} type="range" min="0" max="100" value={Math.round(draft * 100)} disabled={disabled} style={{'--fill':`${draft*100}%`} as React.CSSProperties} onPointerDown={() => setDragging(true)} onPointerUp={finish} onPointerCancel={finish} onBlur={finish} onChange={e => update(Number(e.target.value) / 100)} /><span className="percentage">{value === null ? '—' : `${Math.round(draft*100)}%`}</span></div>;
}
function Mixer() {
  const [state, setState] = useState<Snapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [settings, setSettings] = useState(false);
  const [expanded, setExpanded] = useState<string | null>(null);
  const order = useRef(new SnapshotOrder());
  const apply = (next: Snapshot) => { if (order.current.accept(next)) setState(next); };
  useEffect(() => {
    let cancelled=false; let unlisten: (()=>void) | undefined;
    void (async () => { try { const stop=await subscribe(s=>{if(!cancelled)apply(s);},e=>{if(!cancelled)setError(describeError(e));}); if(cancelled){stop();return;} unlisten=stop; const s=await request({op:'snapshot'}); if(!cancelled)apply(s); }catch(e){if(!cancelled)setError(describeError(e));} })();
    return () => {cancelled=true;unlisten?.();};
  }, []);
  function hidePanel() { void invoke('hide_panel').catch(e => setError(describeError(e))); }
  useEffect(() => {
    if (!desktop) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') { event.preventDefault(); hidePanel(); }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, []);
  async function send(req: Request) { try { apply(await request(req)); setError(null); } catch(e) { setError(describeError(e)); } }
  function deviceSection(direction: 'input' | 'output') {
    const devices=state?.devices.filter(d=>d.direction===direction) ?? [];
    const selected=devices.find(d=>d.isDefault) ?? devices[0];
    const Icon=direction==='input'?Mic:Headphones;
    return <section className="card device-card"><div className="section-label"><Icon size={15}/>{direction==='input'?'声音输入':'声音输出'}<span className="section-hint">{direction==='input'?'麦克风增益':'系统设备音量'}</span></div>
      {selected ? <><button className="device-picker" onClick={()=>setExpanded(expanded===direction?null:direction)}><span className="device-icon"><Icon size={21}/></span><span><strong>{selected.name}</strong><small>{selected.isDefault?'当前默认设备':'可用设备'}</small></span><ChevronDown size={17}/></button>
      {expanded===direction && <div className="device-list">{devices.map(d=><button key={d.id} onClick={()=>{void send({op:'device_default',uid:d.uid,direction});setExpanded(null);}}>{d.name}{d.isDefault&&<Check size={14}/>}</button>)}</div>}
      <div className="volume-row"><button className={`mute ${selected.muted?'active':''}`} aria-label={`${selected.name}静音`} disabled={!selected.canMute} onClick={()=>void send({op:'device_mute',uid:selected.uid,direction,muted:!selected.muted})}>{selected.muted?<VolumeX size={19}/>:<Volume2 size={19}/>}</button><VolumeSlider key={selected.id} label={`${selected.name}音量`} value={selected.volume} disabled={!selected.canSetVolume} onChange={v=>send({op:'device_volume',uid:selected.uid,direction,volume:v})}/></div>
      {!selected.canSetVolume&&<p className="note">此设备不支持系统音量调节，仍可切换设备。</p>}</>:<p className="empty">没有可用的{direction==='input'?'输入':'输出'}设备</p>}
    </section>;
  }
  function appRow(app:AppAudio) {
    const rule=state?.rules[app.id] ?? {volume:1,muted:false};
    return <div className="app-row" key={app.id}><div className="app-top"><div className="app-icon">{app.name.slice(0,1).toUpperCase()}</div><div className="app-name"><strong>{app.name}</strong><small>{app.controlled?'正在混音':app.error?'已恢复原声':`${app.processCount} 个音频进程`}</small></div><button className={`mute ${rule.muted?'active':''}`} aria-label={`${app.name}静音`} disabled={!state?.mixingEnabled||!app.controllable} onClick={()=>void send({op:'app_control',appId:app.id,volume:rule.volume,muted:!rule.muted})}>{rule.muted?<VolumeX size={17}/>:<Volume2 size={17}/>}</button></div><VolumeSlider label={`${app.name}音量`} value={rule.volume} disabled={!state?.mixingEnabled||!app.controllable} onChange={v=>send({op:'app_control',appId:app.id,volume:v,muted:rule.muted})}/>{!app.controllable&&<p className="note">{app.unsupportedReason ?? '首版支持默认输出设备上的双声道音频。'}</p>}{app.error&&<p className="note warning">{app.error}<button className="retry-button" disabled={!state?.mixingEnabled || !app.controllable} onClick={()=>void send({op:'app_control',appId:app.id,volume:rule.volume,muted:rule.muted})}>重新应用音量</button></p>}</div>;
  }
  return <main><header><div className="brand-icon"><AudioLines size={23}/></div><div className="brand"><h1>Mac Voice Mix</h1><p>让每一种声音，恰到好处</p></div><button className={`icon-button ${settings?'selected':''}`} aria-label="设置" onClick={()=>setSettings(!settings)}><SlidersHorizontal size={19}/></button>{desktop&&<button className="icon-button" aria-label="收起面板" title="收起面板（Esc）" onClick={hidePanel}><X size={19}/></button>}</header>
    {!desktop&&<div className="preview-banner">界面预览 · 此页面不会修改系统音频</div>}
    {error&&<div role="alert" className="error-banner">{error}<button onClick={()=>setError(null)}>关闭</button></div>}
    {!state ? <div className="loading">正在连接音频设备…</div> : settings ? <section className="card settings"><h2>偏好设置</h2><p>音量规则保存在本机。重启后点击启用混音，即可恢复正在播放的应用规则。</p><h3>所有音频设备</h3>{state.devices.map(d=><div className="managed-device" key={d.id}><div className="managed-device-title"><strong>{d.name}</strong><span>{d.direction==='input'?'输入':'输出'}{d.isDefault?' · 默认':''}</span></div><div className="volume-row"><button className={`mute ${d.muted?'active':''}`} aria-label={`${d.name}${d.direction}静音`} disabled={!d.canMute} onClick={()=>void send({op:'device_mute',uid:d.uid,direction:d.direction,muted:!d.muted})}>{d.muted?<VolumeX size={17}/>:<Volume2 size={17}/>}</button><VolumeSlider label={`${d.name}${d.direction}音量`} value={d.volume} disabled={!d.canSetVolume} onChange={v=>send({op:'device_volume',uid:d.uid,direction:d.direction,volume:v})}/></div>{!d.canSetVolume&&<p className="note">此设备不支持系统音量调节</p>}</div>)}<h3>已保存的应用规则</h3>{Object.entries(state.rules).length ? Object.entries(state.rules).map(([id,r])=><div className="saved-rule" key={id}><div><strong>{state.apps.find(a=>a.id===id)?.name??id}</strong><small>{Math.round(r.volume*100)}%{r.muted?' · 静音':''}</small></div><button aria-label={`重置 ${id}`} onClick={()=>void send({op:'app_reset',appId:id})}><RotateCcw size={16}/></button></div>):<p className="empty">还没有保存的应用规则</p>}{state.configError&&<p className="warning">{state.configError}</p>}<h3>系统权限</h3><p>首次调整应用音量时，macOS 会申请系统音频录制权限。可以在“系统设置 → 隐私与安全性”中管理。设备音量无需捕获音频。</p><button className="secondary" onClick={()=>void send({op:'restore'})}>恢复所有应用原声</button>{desktop&&<button className="exit" onClick={()=>void invoke('quit_app').catch(e=>setError(describeError(e)))}><Power size={15}/>退出应用</button>}</section> : <>{deviceSection('output')}{deviceSection('input')}<section className="card apps-card"><div className="section-label"><AudioLines size={15}/>应用音量<span className="app-count">{state.apps.length}</span></div>{!state.mixingEnabled&&<div className="permission"><ShieldCheck size={22}/><div><strong>单独调节每个应用</strong><p>启用后，首次调节将申请系统音频录制权限。音频仅在本机实时处理。</p><button className="primary" onClick={()=>void send({op:'enable_mixing'})}>启用应用混音</button></div></div>}{state.apps.length?state.apps.map(appRow):<div className="empty"><AudioLines size={26}/><p>播放一些声音，应用就会出现在这里</p></div>}</section></>}
    <footer><span className={`status-dot ${state?.mixingEnabled?'on':''}`}/>{state?.mixingEnabled?'应用混音已启用':'设备控制就绪'}<button aria-label="刷新音频状态" onClick={()=>void send({op:'snapshot'})}><RotateCcw size={12}/>刷新</button></footer>
  </main>;
}
createRoot(document.getElementById('root')!).render(<React.StrictMode><Mixer/></React.StrictMode>);
