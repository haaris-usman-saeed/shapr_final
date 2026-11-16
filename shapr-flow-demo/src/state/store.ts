// The single demo state shared by autoplay and interactive mode. UI subscribes; scenes and presenter
// controls both change it only through these actions.
import { clock } from "../engine/clock";
import * as K from "./kernel";
import type { AppId } from "../demo-data/aurora";

type Listener = (s: K.DemoState, why: string) => void;
let state = K.initialState();
const listeners: Listener[] = [];

export const getState = () => state;
export function clearListeners() { listeners.length = 0; }
export function subscribe(fn: Listener) { listeners.push(fn); fn(state, "init"); }
function commit(next: K.DemoState, why: string) { state = next; listeners.forEach((l) => l(state, why)); }

export const actions = {
  reset() { commit(K.initialState(), "reset"); },
  startSession() { commit({ ...state, session: "active" }, "session"); },
  pause() { commit({ ...state, session: state.session === "paused" ? "active" : "paused" }, "session"); },
  endSession() { commit(K.endSession(state, clock.now()), "session"); },
  resume() { commit(K.resume(state), "session"); },
  permit(app: AppId, scope: K.Scope) { commit({ ...state, permissions: { ...state.permissions, [app]: scope } }, "permission"); },
  observe(id: string) { const r = K.observe(state, id, clock.now()); commit(r.state, "observe"); return r.decision; },
  tick() { const n = K.expire(state, clock.now()); if (n !== state) commit(n, "expire"); },
  confirmTask() { commit(K.confirmTask(state), "task"); },
  pin(text: string, ref: string) { commit(K.pin(state, text, ref, clock.now()), "task"); },
  select(sel: K.DemoState["selection"]) { commit({ ...state, selection: sel, mode: null }, "selection"); },
  mode(m: K.DemoState["mode"]) { commit({ ...state, mode: m }, "mode"); },
  choose(p: "A" | "B") { commit({ ...state, simulateChoice: p, longTerm: [...state.longTerm, { text: `Exploring path ${p}`, refs: ["Simulate"], kind: "decision", at: clock.now() }] }, "simulate"); },
  deleteSession() { commit(K.deleteSession(state), "delete"); },
};
