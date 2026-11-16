// The demo's Memory Kernel: a deterministic simulation of the proposed SHAPR FLOW algorithm.
// It is NOT a production AI system. Observations are synthetic, with known meaning (demo-data/aurora.ts).
//
// For every observation:  session gate → app permission gate → repetition check → relevance →
// immediate memory (expires) → task working memory update (with source refs) → budget.
import { OBS, type AppId, type ObsDef } from "../demo-data/aurora";

export type Scope = "once" | "session" | "always" | "deny";
export type Session = "off" | "active" | "paused" | "ended";
export type Status = "observed" | "inferred" | "confirmed";

export interface Line { text: string; refs: string[]; status: Status }
export interface Imm { id: string; obs: ObsDef; count: number; at: number; expiresAt: number }
export interface LongItem { text: string; refs: string[]; kind: "checkpoint" | "fact" | "pinned" | "decision"; at: number }
export type Outcome = "ignored" | "blocked" | "duplicate" | "noise" | "retained";
export interface Decision { obsId: string; app: AppId; outcome: Outcome; reason: string; at: number }

export interface Task {
  status: "none" | Status;
  title: string;
  goal: Line | null;
  tried: Line[];
  blocker: Line | null;
  next: Line | null;
  facts: Line[];
}

export interface DemoState {
  session: Session;
  day: 1 | 2;
  permissions: Partial<Record<AppId, Scope>>;
  project: string;
  immediate: Imm[];
  task: Task;
  longTerm: LongItem[];
  decisions: Decision[];
  blockedCount: number;
  selection: { id: string; text: string } | null;
  mode: "L" | "T" | "S" | null;
  simulateChoice: "A" | "B" | null;
  deletedSessions: number;
  lastPermissions: Partial<Record<AppId, Scope>>;
}

export const POLICY = {
  immediateTtl: 90_000,     // demo minutes compressed: immediate memory expires after 90 s of demo time
  noiseTtl: 12_000,         // irrelevant activity expires fast
  immediateBudget: 6,       // at most six immediate items
  triedBudget: 4,
  inferAfter: 3,            // signals needed before Shapr proposes a task
};

export function initialState(): DemoState {
  return {
    session: "off", day: 1, permissions: {}, project: "Aurora", immediate: [],
    task: { status: "none", title: "", goal: null, tried: [], blocker: null, next: null, facts: [] },
    longTerm: [], decisions: [], blockedCount: 0, selection: null, mode: null, simulateChoice: null, deletedSessions: 0, lastPermissions: {},
  };
}

const clone = <T>(x: T): T => JSON.parse(JSON.stringify(x));

export function allowed(s: DemoState, app: AppId) {
  const p = s.permissions[app];
  return p === "once" || p === "session" || p === "always";
}

export function observe(prev: DemoState, id: string, now: number): { state: DemoState; decision: Decision } {
  const s = clone(prev);
  const obs = OBS[id];
  const d = (outcome: Outcome, reason: string): Decision => ({ obsId: id, app: obs.app, outcome, reason, at: now });
  let decision: Decision;
  if (s.session !== "active") decision = d("ignored", s.session === "paused" ? "Observation paused" : "No active session");
  else if (!allowed(s, obs.app)) {
    // Nothing from a blocked app is stored: only that something was not observed.
    s.blockedCount++;
    decision = d("blocked", `${obs.app} is not allowed`);
  } else {
    if (s.permissions[obs.app] === "once") delete s.permissions[obs.app];
    const dup = s.immediate.find((m) => m.obs.key === obs.key);
    if (dup) {
      dup.count++; dup.expiresAt = now + POLICY.immediateTtl;
      decision = d("duplicate", `Repeats “${dup.obs.label}”`);
      // A repeated error after attempts confirms the blocker is still open.
      if (obs.kind === "error" && s.task.blocker) s.task.blocker.refs = uniq([...s.task.blocker.refs, obs.ref + " (again)"]);
    } else if (obs.noise) {
      s.immediate.push({ id, obs, count: 1, at: now, expiresAt: now + POLICY.noiseTtl });
      decision = d("noise", "Not related to the active task; expires soon");
    } else {
      s.immediate.push({ id, obs, count: 1, at: now, expiresAt: now + POLICY.immediateTtl });
      applyEffect(s, obs);
      decision = d("retained", obs.effect && Object.keys(obs.effect).length ? "Updated task memory" : "Kept as recent context");
    }
    // budget: oldest immediate items go first
    while (s.immediate.length > POLICY.immediateBudget) s.immediate.shift();
    maybeInfer(s);
  }
  s.decisions.push(decision);
  return { state: s, decision };
}

const uniq = (a: string[]) => [...new Set(a)];

function applyEffect(s: DemoState, o: ObsDef) {
  const e = o.effect || {};
  const status: Status = "observed";
  if (e.goal && !s.task.goal) s.task.goal = { text: e.goal, refs: [o.ref], status: "inferred" };
  if (e.blocker) s.task.blocker = { text: e.blocker, refs: uniq([...(s.task.blocker?.refs || []), o.ref]), status };
  if (e.tried && !s.task.tried.some((t) => t.text === e.tried)) {
    s.task.tried.push({ text: e.tried, refs: [o.ref], status });
    if (s.task.tried.length > POLICY.triedBudget) s.task.tried.shift();
  }
  if (e.next) s.task.next = { text: e.next, refs: [o.ref], status: "inferred" };
  if (e.fact && !s.task.facts.some((f) => f.text === e.fact)) s.task.facts.push({ text: e.fact, refs: [o.ref], status });
}

function maybeInfer(s: DemoState) {
  const signals = s.decisions.filter((d) => d.outcome === "retained").length;
  if (s.task.status === "none" && signals >= POLICY.inferAfter && s.task.blocker) {
    s.task.status = "inferred";
    s.task.title = "Fix database connection";
  }
  // Without a confirmed next step, propose one from the evidence Shapr is allowed to use.
  if (s.task.blocker && !s.task.next && s.task.tried.length >= 2)
    s.task.next = { text: "Inspect environment configuration (DB_HOST)", refs: ["db.js · .env", ...(s.task.facts.some((f) => f.refs[0].startsWith("PostgreSQL")) ? ["PostgreSQL docs · Connecting"] : [])], status: "inferred" };
}

export function expire(prev: DemoState, now: number): DemoState {
  if (!prev.immediate.some((m) => m.expiresAt <= now)) return prev;
  const s = clone(prev);
  s.immediate = s.immediate.filter((m) => m.expiresAt > now);
  return s;
}

export function confirmTask(prev: DemoState): DemoState {
  const s = clone(prev);
  if (s.task.status !== "none") s.task.status = "confirmed";
  if (s.task.goal) s.task.goal.status = "confirmed";
  return s;
}

export function pin(prev: DemoState, text: string, ref: string, now: number): DemoState {
  const s = clone(prev);
  s.longTerm.push({ text, refs: [ref], kind: "pinned", at: now });
  if (/docker|container|localhost/i.test(text)) s.task.next = { text: "Inspect environment configuration (DB_HOST)", refs: [ref, "db.js · .env"], status: "confirmed" };
  return s;
}

/** End of a working session: the compact task state becomes a long-term checkpoint; immediate memory is dropped. */
export function endSession(prev: DemoState, now: number): DemoState {
  const s = clone(prev);
  if (s.task.status !== "none")
    s.longTerm.push({ text: "Checkpoint: " + (s.task.title || "task"), refs: uniq([s.task.blocker?.refs[0] || "", ...s.task.tried.map((t) => t.refs[0])].filter(Boolean)), kind: "checkpoint", at: now });
  s.immediate = [];
  s.session = "ended";
  // "Allow once" / "Allow this session" end with the session; "Always allow" stays.
  s.lastPermissions = { ...s.permissions };
  for (const a of Object.keys(s.permissions) as AppId[]) if (s.permissions[a] !== "always" && s.permissions[a] !== "deny") delete s.permissions[a];
  return s;
}

export function resume(prev: DemoState): DemoState {
  const s = clone(prev);
  s.session = "active"; s.day = 2; s.mode = null; s.selection = null;
  // Continuing is an explicit choice to reuse yesterday's app choices (shown on the Resume card).
  s.permissions = { ...s.lastPermissions, ...s.permissions };
  return s;
}

/** Delete the temporary session: immediate memory and anything not checkpointed or pinned. */
export function deleteSession(prev: DemoState): DemoState {
  const s = clone(prev);
  s.immediate = []; s.decisions = []; s.deletedSessions++;
  if (!s.longTerm.some((l) => l.kind === "checkpoint")) s.task = initialState().task;
  return s;
}

// ---------- what Shapr can say, computed from state (never from pixels of blocked apps) ----------

export interface Insight { headline: string; lines: string[]; sources: string[]; limited?: string }

export function lens(s: DemoState): Insight {
  if (s.session === "off" || s.task.status === "none")
    return { headline: "Not enough context yet.", lines: ["Lens uses only apps you've allowed in an active session."], sources: ["Current selection"], limited: "Start a session and allow VS Code to add context." };
  const lines: string[] = [];
  const sources = ["Current terminal error"];
  const tried = s.task.tried.map((t) => t.text.toLowerCase());
  if (tried.length) { lines.push(`Your previous attempt ${tried.join(" and ")}, but the connection was still refused.`); sources.push("Earlier task memory"); }
  const config = s.immediate.some((m) => m.obs.key === "file:db.js") || s.task.facts.some((f) => f.text.includes("DB_HOST"));
  if (config) { lines.push("Your current configuration may be using the wrong database host."); sources.push("Database configuration file"); }
  const docs = s.task.facts.find((f) => f.refs[0].startsWith("PostgreSQL"));
  let limited: string | undefined;
  if (docs) sources.push("PostgreSQL docs");
  else if (!allowed(s, "safari")) limited = "Safari isn't allowed, so documentation you read there isn't used.";
  return { headline: "This may be related to your earlier connection attempt.", lines, sources, limited };
}

export function resumeCard(s: DemoState) {
  const t = s.task;
  return {
    title: "Welcome back.",
    question: `Continue ${s.project}?`,
    lines: [
      t.blocker ? "Yesterday you were troubleshooting the PostgreSQL connection." : "Yesterday you worked on Aurora.",
      t.tried.length ? `You ${t.tried.map((x) => x.text.toLowerCase()).join(" and ")}.` : "",
      t.blocker ? "The connection remained unresolved." : "",
      t.next ? `Next: ${t.next.text.replace(" (DB_HOST)", "")}.` : "",
    ].filter(Boolean),
    apps: (Object.keys(s.lastPermissions) as AppId[]).filter((a) => s.lastPermissions[a] !== "deny"),
  };
}

export function simulate(s: DemoState) {
  const spec = s.task.facts.some((f) => f.text.startsWith("New requirement"));
  const arch = s.task.facts.some((f) => f.text.startsWith("Decision"));
  const evidence = [spec ? "Requirements" : null, arch ? "Architecture notes" : null].filter(Boolean) as string[];
  return {
    selected: "Store user data locally.",
    requirement: "Support real-time team collaboration.",
    paths: [
      { id: "A" as const, title: "Local-first + synchronization", pros: ["Preserves offline-first behavior", "Keeps local ownership central"], cons: ["More complex synchronization and conflict resolution"] },
      { id: "B" as const, title: "Managed cloud backend", pros: ["Shared-state collaboration", "Potentially simpler initial implementation"], cons: ["Hosting dependencies and additional privacy considerations"] },
    ],
    evidence: evidence.length ? evidence : ["Selection only"],
    questions: ["Expected team size", "Offline requirements"],
  };
}
