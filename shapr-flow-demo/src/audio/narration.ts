// Narration lines: captions on screen plus an optional voice file (public/audio/<id>.mp3).
// The film is designed to work with sound off: every line is also a caption.
import { clock } from "../engine/clock";
import { caption } from "../ui/desktop";
import { audio, cueLog } from "./sfx";

export const LINES: Record<string, string> = {
  n01: "Your computer sees everything you do.",
  n02: "But does it understand any of it?",
  n03: "What if you never had to explain your work again?",
  n04: "Start a session. Choose what Shapr can see.",
  n05: "Start working. Shapr keeps up.",
  n06: "Not everything you did. Everything you need to continue.",
  n07: "Circle anything.",
  n08: "Lens starts from where you are, not from zero.",
  n09: "Your work keeps moving. Its context stays connected.",
  n10: "Stop now. Continue tomorrow.",
  n11: "Explore the options, and the evidence behind them.",
  n12: "Pause it. Review it. Delete it. It's your context.",
  n13: "Your computer. Your context. Finally connected.",
};
export const DUR: Record<string, number> = {}; // filled from public/audio/lines.json when present

let current: HTMLAudioElement | null = null;
export function say(id: string, ms?: number, showCaption = true) {
  const text = LINES[id];
  cueLog.push({ t: clock.now(), kind: "line", id });
  const d = ms ?? DUR[id] ?? 700 + text.split(" ").length * 380;
  if (audio.captions && showCaption) caption(text, d + 500);
  if (!audio.muted && !audio.capture) {
    try { current?.pause(); current = new Audio(`audio/${id}.mp3`); current.play().catch(() => {}); } catch { /* captions still show */ }
  }
}

let music: HTMLAudioElement | null = null;
export function musicAt(program: string, seconds: number, playing: boolean) {
  if (audio.capture) return;
  if (!music || music.dataset.p !== program) { music?.pause(); music = new Audio(`audio/music_${program}.mp3`); music.dataset.p = program; music.volume = 0.55; }
  if (audio.muted || !playing) { music.pause(); return; }
  if (Math.abs(music.currentTime - seconds) > 0.4) music.currentTime = seconds;
  music.play().catch(() => {});
}
export function stopMusic() { music?.pause(); }
export async function loadDurations() {
  try { const r = await fetch("audio/lines.json"); Object.assign(DUR, await r.json()); } catch { /* defaults */ }
}
