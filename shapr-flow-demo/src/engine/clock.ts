// One clock for everything. Live mode follows real time (speed, pause); manual mode is stepped by the
// video exporter, so every frame is a pure function of time. Scripts wait on the clock, never on setTimeout.

type Waiter = { due: number; seq: number; resolve: () => void; gen: number };

class Clock {
  manual = false;
  private t = 0;            // current time, ms
  private logical: number | null = null; // time of the event being resolved (new tweens start here)
  private waiters: Waiter[] = [];
  private seq = 0;
  gen = 0;                  // bumped on reset: older scripts stop silently
  paused = false;
  hook: (() => void) | null = null;
  private lastReal = 0;

  now(): number { return this.logical ?? this.t; }

  wait(ms: number): Promise<void> {
    const gen = this.gen;
    return new Promise((resolve) => this.waiters.push({ due: this.now() + Math.max(0, ms), seq: this.seq++, resolve, gen }));
  }
  /** Wait until an absolute time (ms). */
  until(ms: number): Promise<void> { return this.wait(ms - this.now()); }

  /** Advance to T, resolving due waiters in time order and letting their continuations run. */
  async advanceTo(T: number) {
    for (;;) {
      this.waiters = this.waiters.filter((w) => w.gen === this.gen);
      let i = -1;
      for (let k = 0; k < this.waiters.length; k++) {
        const w = this.waiters[k];
        if (w.due <= T && (i < 0 || w.due < this.waiters[i].due || (w.due === this.waiters[i].due && w.seq < this.waiters[i].seq))) i = k;
      }
      if (i < 0) break;
      const w = this.waiters.splice(i, 1)[0];
      this.logical = w.due; this.t = Math.max(this.t, w.due);
      this.hook?.();           // apply tweens as of this instant, so scripts read settled values
      w.resolve();
      for (let k = 0; k < 40; k++) await null; // let the awaiting script run up to its next wait
      this.logical = null;
    }
    this.t = Math.max(this.t, T);
  }

  /** Live mode: called every animation frame. */
  async liveStep(realNow: number, speed = 1) {
    const dt = this.lastReal ? Math.min(100, realNow - this.lastReal) : 0;
    this.lastReal = realNow;
    if (!this.paused) await this.advanceTo(this.t + dt * speed);
  }

  reset() { this.gen++; this.waiters = []; this.t = 0; this.logical = null; this.lastReal = 0; }
  get time() { return this.t; }
}

export const clock = new Clock();
export const wait = (ms: number) => clock.wait(ms);
