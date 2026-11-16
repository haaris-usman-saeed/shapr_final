// The Memory Kernel, made visible. Driven by the kernel's own decision log and state: fragments that were
// retained flow into working memory, repeats merge, noise expires, blocked apps contribute nothing.
import { animate, set, run, ease, lerp } from "../engine/anim";
import { wait } from "../engine/clock";
import { D, h, esc } from "./desktop";
import { getState } from "../state/store";
import { OBS } from "../demo-data/aurora";
import { sfx } from "../audio/sfx";

const ring = (k: number) => `<svg class="ring" viewBox="0 0 22 22"><circle cx="11" cy="11" r="9" fill="none" stroke="rgba(255,255,255,.15)" stroke-width="2.4"/><circle cx="11" cy="11" r="9" fill="none" stroke="#E08A5E" stroke-width="2.4" stroke-linecap="round" stroke-dasharray="${(56.5 * (1 - k)).toFixed(1)} 60" transform="rotate(-90 11 11)"/></svg>`;

export async function kernelView(opts: { fast?: boolean } = {}) {
  const k = D.kernel; k.innerHTML = "";
  const s = getState();
  const bg = h("div", "bg"); k.append(bg);
  const lanes = [["Immediate", "recent activity · expires on its own", 110], ["Working memory", "the task, kept compact", 690], ["Long-term", "checkpoints · what you confirm", 1460]] as const;
  lanes.forEach(([t, sub, x]) => { const l = h("div", "lane", `${t}<small>${sub}</small>`); l.style.left = x + "px"; k.append(l); });
  set(k, { o: 0 }); k.style.pointerEvents = "none";
  await animate(k, { o: 1 }, { dur: 700 });

  // every observation the kernel accepted, in order (blocked apps contribute only a contentless count)
  const seen = s.decisions.filter((d) => d.outcome !== "ignored" && d.outcome !== "blocked");
  const frags = new Map<string, { el: HTMLElement; d: typeof seen[0]; y: number; n: number }>();
  let row = 0;
  for (const d of seen) {
    const o = OBS[d.obsId];
    const orig = [...frags.values()].find((f) => OBS[f.d.obsId].key === o.key);
    const el = h("div", "frag", `${ring(0)}<span>${esc(o.label)}</span><span class="n"></span><span class="why"></span>`);
    k.append(el);
    const y = 290 + row * 66;
    set(el, { x: -380, y: y, o: 0 });
    animate(el, { x: 110, o: 1 }, { dur: opts.fast ? 300 : 620, ease: ease.enter });
    sfx("tick");
    if (orig) {
      // repetition: slides into the first one and merges
      await wait(opts.fast ? 250 : 520);
      (el.querySelector(".why") as HTMLElement).textContent = "repeat";
      await animate(el, { y: orig.y, o: 0.9 }, { dur: 600, ease: ease.move });
      orig.n++; (orig.el.querySelector(".n") as HTMLElement).textContent = `×${orig.n}`;
      run(420, (q) => (orig.el.style.boxShadow = `0 0 0 ${3 * Math.sin(Math.PI * q)}px rgba(224,138,94,.6)`));
      sfx("merge");
      await animate(el, { o: 0 }, { dur: 240 });
      el.remove();
    } else {
      frags.set(d.obsId, { el, d, y, n: 1 }); row++;
      await wait(opts.fast ? 220 : 420);
    }
  }
  if (s.blockedCount) {
    const b = h("div", "frag", `<span style="opacity:.7">🔒 ${s.blockedCount} event${s.blockedCount > 1 ? "s" : ""} from a blocked app · not observed</span>`);
    k.append(b); set(b, { x: 110, y: 290 + row * 66 + 10, o: 0 }); animate(b, { o: 0.75 }, { dur: 400 });
  }
  await wait(opts.fast ? 300 : 700);

  // working memory card, built from the kernel's task state
  const t = s.task;
  const rows: [string, string, string][] = [];
  if (t.goal) rows.push(["Goal", t.goal.text, t.goal.refs[0]]);
  if (t.tried.length) rows.push(["Tried", t.tried.map((x) => x.text).join(" · "), t.tried[0].refs[0]]);
  if (t.blocker) rows.push(["Current issue", t.blocker.text.replace(/ \(.*\)/, ""), t.blocker.refs[0].split(" · ")[0]]);
  if (t.next) rows.push(["Next", t.next.text.replace(" (DB_HOST)", ""), t.next.refs[0]]);
  const wm = h("div", "wm", `<div class="t">${esc(s.project.toUpperCase())} / BACKEND</div>${rows.map(([a, b, c]) => `<div class="r"><div class="k">${a}</div><div class="v">${esc(b)}<span class="src">${esc(c)}</span></div></div>`).join("")}`);
  k.append(wm); wm.style.left = "690px"; wm.style.top = "330px";
  set(wm, { o: 0, s: 0.6 });
  animate(wm, { o: 1, s: 1 }, { dur: 700, ease: ease.spring });
  const rEls = [...wm.querySelectorAll(".r")] as HTMLElement[];
  rEls.forEach((r) => set(r, { o: 0, y: 10 }));

  // relevant fragments send their light into the card; the card resolves line by line
  const relevant = [...frags.values()].filter((f) => f.d.outcome === "retained" && OBS[f.d.obsId].effect && Object.keys(OBS[f.d.obsId].effect!).length);
  relevant.forEach((f, i) => {
    const dot = h("div"); Object.assign(dot.style, { position: "absolute", left: "0", top: "0", width: "12px", height: "12px", margin: "-6px", borderRadius: "50%", background: "#E08A5E", boxShadow: "0 0 18px 4px rgba(224,138,94,.5)" });
    k.append(dot);
    const a = { x: 110 + f.el.offsetWidth, y: f.y + 24 }, b = { x: 760, y: 390 + i * 30 };
    run(800, (q) => { const u = 1 - q; const x = u * a.x + q * b.x, y = u * a.y + q * b.y - Math.sin(Math.PI * q) * 60; dot.style.transform = `translate(${x}px,${y}px)`; dot.style.opacity = String(q < 0.9 ? 1 : (1 - q) * 10); }, { ease: ease.inOut, delay: i * 160 }).then(() => dot.remove());
    animate(f.el, { o: 0.55 }, { dur: 400, delay: 500 + i * 160 });
  });
  await wait(700);
  for (const r of rEls) { animate(r, { o: 1, y: 0 }, { dur: 460, ease: ease.enter }); sfx("tick"); await wait(opts.fast ? 160 : 340); }

  // long-term: what was confirmed or checkpointed
  const lt = [...s.longTerm.map((l) => [l.kind, l.text]), ...(t.status === "confirmed" ? [["confirmed by you", `Task: ${t.title}`]] : [])];
  lt.forEach(([a, b], i) => {
    const e = h("div", "lt", `<div class="k">${esc(a)}</div>${esc(b)}`); k.append(e);
    e.style.left = "1460px"; e.style.top = 330 + i * 92 + "px"; set(e, { o: 0, x: 40 }); animate(e, { o: 1, x: 0 }, { dur: 520, ease: ease.enter, delay: 200 + i * 150 });
  });
  await wait(900);

  // noise and recent context expire; the immediate lane empties itself
  const order = [...frags.values()].sort((a, b) => (OBS[a.d.obsId].noise ? -1 : 0) - (OBS[b.d.obsId].noise ? -1 : 0));
  for (const f of order) {
    const r = f.el.querySelector(".ring")!;
    run(opts.fast ? 300 : 650, (q) => (r.outerHTML !== undefined && (f.el.querySelector(".ring")!.outerHTML = ring(q))));
    (f.el.querySelector(".why") as HTMLElement).textContent = OBS[f.d.obsId].noise ? "not related · expired" : "expired · kept in the task";
    animate(f.el, { o: 0, x: 60 }, { dur: 600, delay: opts.fast ? 250 : 600, ease: ease.exit });
    sfx("expire");
    await wait(opts.fast ? 140 : 300);
  }
  await wait(opts.fast ? 300 : 900);
  sfx("settle");
  return { wm, close: async (toIcon = true) => {
    k.querySelectorAll(".lane, .lt, .frag").forEach((e) => animate(e as HTMLElement, { o: 0 }, { dur: 400 }));
    if (toIcon) await animate(wm, { x: 700, y: -330, s: 0.1, o: 0 }, { dur: 900, ease: ease.move });
    await animate(k, { o: 0 }, { dur: 500 });
    k.innerHTML = "";
  } };
}
