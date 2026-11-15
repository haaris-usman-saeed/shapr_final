// Shared by the page (burned-in captions) and node (SRT/VTT): turns narration cues into caption chunks.
// Each narration line is split at sentence boundaries; time is shared by character count.

export function estimateDur(text) {
  return 0.35 + text.split(/\s+/).length / 2.55;
}

export function chunk(text) {
  const parts = text.match(/[^.?!…:]+[.?!…:]+["”]?|[^.?!…:]+$/g) || [text];
  const out = [];
  let buf = "";
  for (const p of parts.map((x) => x.trim()).filter(Boolean)) {
    if (buf && (buf + " " + p).length > 64) { out.push(buf); buf = p; } else buf = buf ? buf + " " + p : p;
  }
  if (buf) out.push(buf);
  // A chunk longer than ~84 characters is split at a comma near the middle.
  return out.flatMap((c) => {
    if (c.length <= 84) return [c];
    const mid = c.length / 2;
    let best = -1;
    for (let i = 0; i < c.length; i++) if (c[i] === "," && (best < 0 || Math.abs(i - mid) < Math.abs(best - mid))) best = i;
    return best > 0 ? [c.slice(0, best + 1), c.slice(best + 1).trim()] : [c];
  });
}

// narration: [{id, at, text}] (scene-relative); durs: {id: seconds}. Returns [{at, dur, text}].
export function captionCues(narration, durs = {}) {
  const cues = [];
  for (const n of narration || []) {
    const total = durs[n.id] ?? estimateDur(n.text);
    const chunks = chunk(n.text);
    const chars = chunks.reduce((a, c) => a + c.length, 0);
    let at = n.at;
    chunks.forEach((c, i) => {
      const d = (total * c.length) / chars;
      cues.push({ at, dur: d + (i === chunks.length - 1 ? 0.35 : 0.02), text: c, id: n.id });
      at += d;
    });
  }
  return cues;
}
