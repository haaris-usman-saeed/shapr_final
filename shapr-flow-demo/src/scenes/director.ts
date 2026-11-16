// Runs a program (list of scenes) on the shared clock. Seeking replays deterministically from the start
// with the clock in fast-forward, so every scene starts from exactly the state the story produced.
import { clock } from "../engine/clock";
import { frame } from "../engine/anim";
import { PROGRAMS, type Scene } from "./hero";

export const director = {
  program: "hero",
  scenes: [] as Scene[],
  starts: [] as number[],
  total: 0,
  index: 0,
  running: false,
  load(program: string) {
    this.program = program; this.scenes = PROGRAMS[program];
    let t = 0; this.starts = this.scenes.map((s) => { const a = t; t += s.dur; return a; }); this.total = t;
  },
  /** Start the program at time 0 (call after the world has been reset). */
  async run() {
    this.running = true;
    const gen = clock.gen;
    for (let i = 0; i < this.scenes.length; i++) {
      if (gen !== clock.gen) return;
      this.index = i;
      const start = this.starts[i];
      await clock.until(start);
      await this.scenes[i].run();
      const over = clock.now() - (start + this.scenes[i].dur);
      if (over > 30) console.warn(`scene ${this.scenes[i].id} overran by ${Math.round(over)} ms`);
      await clock.until(start + this.scenes[i].dur);
    }
    this.running = false;
    (window as any).__ended = true;
  },
  /** Jump to an absolute program time by fast-forwarding (no rendering in between). */
  async seek(ms: number) {
    const manual = clock.manual; clock.manual = true;
    await clock.advanceTo(ms);
    frame();
    clock.manual = manual;
  },
  sceneAt(ms: number) { let i = 0; while (i + 1 < this.starts.length && this.starts[i + 1] <= ms) i++; return i; },
};
