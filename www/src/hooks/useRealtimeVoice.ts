import * as React from "react";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { dispatch } from "@/state/store";
import type { RealtimeEvent } from "@/runtime/connector";

export interface TranscriptLine { role: string; text: string; done: boolean }

// PCM16 codec helpers for the realtime audio bridge (browser ↔ thread/realtime/*).
function floatToPCM16(f32: Float32Array): Uint8Array {
  const buf = new ArrayBuffer(f32.length * 2);
  const view = new DataView(buf);
  for (let i = 0; i < f32.length; i++) {
    const s = Math.max(-1, Math.min(1, f32[i]));
    view.setInt16(i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }
  return new Uint8Array(buf);
}
function base64FromBytes(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}
function pcm16ToFloat(b64: string): Float32Array {
  const bin = atob(b64);
  const len = bin.length >> 1;
  const out = new Float32Array(len);
  const view = new DataView(new ArrayBuffer(2));
  for (let i = 0; i < len; i++) {
    view.setUint8(0, bin.charCodeAt(i * 2));
    view.setUint8(1, bin.charCodeAt(i * 2 + 1));
    out[i] = view.getInt16(0, true) / 0x8000;
  }
  return out;
}

/**
 * Realtime-voice session bridge for a thread. Subscribes to transcript + audio
 * output and (optionally) captures the mic, streaming base64 PCM16 frames to
 * `thread/realtime/appendAudio`. Audio output frames are decoded and played.
 *
 * The backend realtime layer currently echoes input, so this proves the full
 * round-trip; it works unchanged against a real audio model.
 */
export function useRealtimeVoice(threadId: string, active: boolean) {
  const { connector } = useRuntime();
  const [transcript, setTranscript] = React.useState<TranscriptLine[]>([]);
  const [micOn, setMicOn] = React.useState(false);
  const micRef = React.useRef<{ stream: MediaStream; ctx: AudioContext; proc: ScriptProcessorNode } | null>(null);
  const playCtxRef = React.useRef<AudioContext | null>(null);

  const appendDelta = (role: string, delta: string) =>
    setTranscript((lines) => {
      const last = lines[lines.length - 1];
      if (last && last.role === role && !last.done) {
        return [...lines.slice(0, -1), { ...last, text: last.text + delta }];
      }
      return [...lines, { role, text: delta, done: false }];
    });

  const playAudio = React.useCallback((audio: unknown) => {
    const a = audio as { data?: string; sampleRate?: number; numChannels?: number } | undefined;
    if (!a?.data) return;
    try {
      const ctx = playCtxRef.current ?? new AudioContext();
      playCtxRef.current = ctx;
      // A context created outside a user gesture starts 'suspended' — resume it
      // or the audio is silently never heard.
      if (ctx.state === "suspended") void ctx.resume();
      const f32 = pcm16ToFloat(a.data);
      if (!f32.length) return;
      const buf = ctx.createBuffer(1, f32.length, a.sampleRate || 24000);
      buf.getChannelData(0).set(f32);
      const src = ctx.createBufferSource();
      src.buffer = buf;
      src.connect(ctx.destination);
      src.start();
    } catch { /* playback best-effort */ }
  }, []);

  // Close the lazily-created playback context (browsers cap concurrent
  // AudioContexts; leaking one per opened thread eventually throws).
  const closePlayback = React.useCallback(() => {
    if (playCtxRef.current) {
      try { void playCtxRef.current.close(); } catch { /* ignore */ }
      playCtxRef.current = null;
    }
  }, []);

  // Subscribe to the realtime output stream while the session is active.
  React.useEffect(() => {
    if (!threadId || !active) return;
    const unsub = connector.onRealtime?.(threadId, (e: RealtimeEvent) => {
      if (e.kind === "transcript-delta") appendDelta(e.role, e.delta);
      else if (e.kind === "transcript-done")
        setTranscript((lines) => {
          const last = lines[lines.length - 1];
          if (last && last.role === e.role && !last.done) {
            return [...lines.slice(0, -1), { role: e.role, text: e.text || last.text, done: true }];
          }
          return [...lines, { role: e.role, text: e.text, done: true }];
        });
      else if (e.kind === "audio") playAudio(e.audio);
    });
    return () => unsub?.();
  }, [threadId, active, connector, playAudio]);

  const stopMic = React.useCallback(() => {
    const m = micRef.current;
    if (m) {
      try { m.proc.disconnect(); } catch { /* ignore */ }
      try { void m.ctx.close(); } catch { /* ignore */ }
      m.stream.getTracks().forEach((t) => t.stop());
      micRef.current = null;
    }
    setMicOn(false);
  }, []);

  const startMic = React.useCallback(async () => {
    if (micRef.current || !threadId) return;
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const ctx = new AudioContext({ sampleRate: 24000 });
      const src = ctx.createMediaStreamSource(stream);
      const proc = ctx.createScriptProcessor(4096, 1, 1);
      proc.onaudioprocess = (ev) => {
        const input = ev.inputBuffer.getChannelData(0);
        const b64 = base64FromBytes(floatToPCM16(input));
        void dispatch.sendRealtimeAudio(threadId, b64, ctx.sampleRate, 1);
      };
      src.connect(proc);
      proc.connect(ctx.destination);
      micRef.current = { stream, ctx, proc };
      setMicOn(true);
    } catch {
      setMicOn(false);
    }
  }, [threadId]);

  // Tear the mic + transcript + playback down when the session ends.
  React.useEffect(() => {
    if (!active) { stopMic(); closePlayback(); setTranscript([]); }
  }, [active, stopMic, closePlayback]);
  React.useEffect(() => () => { stopMic(); closePlayback(); }, [stopMic, closePlayback]);

  return { transcript, micOn, startMic, stopMic };
}
