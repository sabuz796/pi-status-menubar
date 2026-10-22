/**
 * Pi Status Bar - menu bar companion extension.
 *
 * Listens to Pi lifecycle events and mirrors the current session state into
 * one tiny JSON file per session:
 *
 *   ~/.pi/statusbar/state.d/<sessionId>.json
 *
 * A separate Swift menu bar app polls that folder and renders the icon,
 * timer, and session list. Files are the whole protocol: they survive
 * crashes, support many sessions at once, and need no socket or port.
 *
 * State file schema (all fields always present):
 * {
 *   state:      "idle" | "thinking" | "tool" | "permission" | "done",
 *   label:      "Thinking…" | "Editing" | "Running command" | … (menu text),
 *   tool:       "edit" | "bash" | "" (raw Pi tool name, "" when not a tool),
 *   project:    "my-app" (basename of cwd),
 *   cwd:        "/Users/you/my-app",
 *   sessionId:  "<pi session id>",
 *   sessionName:"my fix" (pi session name, may be ""),
 *   entrypoint: "pi",
 *   term_program: "iTerm.app" | "" (for click-to-focus, may be ""),
 *   pid:        12345 (this pi process; the app uses kill(pid,0) for liveness),
 *   started:    true (false only for a merely-opened session with no activity yet),
 *   startedAt:  1730000000 (unix sec the turn began, 0 = no clock),
 *   ts:         1730000005 (unix sec of this write)
 * }
 *
 * Install: copy this file to ~/.pi/agent/extensions/ (the app does it on
 * first launch). Uninstall: delete it from there and remove ~/.pi/statusbar.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawn } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const BUNDLE_ID = "com.local.pistatusbar";

const DIR = path.join(os.homedir(), ".pi", "statusbar");
const STATE_DIR = path.join(DIR, "state.d");
const QUIT_MARKER = path.join(DIR, "quit-intent");

const TOOL_LABELS: Record<string, string> = {
	bash: "Running command",
	powershell: "Running command",
	edit: "Editing",
	write: "Writing",
	read: "Reading",
	grep: "Searching",
	find: "Searching",
	ls: "Browsing files",
	git: "Git operation",
	npm: "Running npm",
	npx: "Running npx",
	pnpm: "Running pnpm",
	yarn: "Running yarn",
	python: "Running Python",
	node: "Running Node.js",
	docker: "Docker operation",
};

type State = "idle" | "thinking" | "tool" | "permission" | "done";

interface StatusFile {
	state: State;
	label: string;
	tool: string;
	project: string;
	cwd: string;
	sessionId: string;
	sessionName: string;
	entrypoint: string;
	term_program: string;
	pid: number;
	started: boolean;
	startedAt: number;
	ts: number;
}

const safeId = (s: string): string =>
	String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

// Last non-prompt state per session. A blocking UI dialog (project-trust
// prompt, permission select, …) can open with NO run active; when it closes,
// ui_prompt_end must restore whatever was there before - not blindly write
// "thinking", which froze the icon on a clock-less thinking state forever.
const lastGood = new Map<string, { state: State; label: string; tool: string; startedAt: number }>();
// Sessions with a UI prompt open: the beat must not clobber "permission".
const prompting = new Set<string>();

// Heartbeat: a working state is refreshed every 30s so the app can treat a
// stale timestamp as a dead/stuck session after ~3 missed beats instead of
// waiting out the old 15-minute cap. A long model think emits no events, so
// without this the timestamp would legitimately go stale mid-turn.
const HEARTBEAT_MS = 30_000;
const lastCtx = new Map<string, ExtensionContext>();
let beat: ReturnType<typeof setInterval> | null = null;

function stopBeatIfIdle(): void {
	if (lastCtx.size === 0 && beat) {
		clearInterval(beat);
		beat = null;
	}
}

function sessionIdOf(ctx: ExtensionContext): string {
	try {
		const id = ctx.sessionManager.getSessionId();
		if (id) return safeId(String(id));
	} catch {}
	return "unknown";
}

function statePath(id: string): string {
	return path.join(STATE_DIR, id + ".json");
}

function readPrev(id: string): Partial<StatusFile> {
	try {
		return JSON.parse(fs.readFileSync(statePath(id), "utf8"));
	} catch {
		return {};
	}
}

function writeAtomic(file: string, obj: StatusFile): void {
	const tmp = file + "." + process.pid + ".tmp";
	try {
		fs.mkdirSync(STATE_DIR, { recursive: true });
		fs.writeFileSync(tmp, JSON.stringify(obj));
		fs.renameSync(tmp, file);
	} catch (e) {
		// A failed write leaves the temp file behind, so drop it.
		try {
			fs.rmSync(tmp, { force: true });
		} catch {}
		console.warn("pi-statusbar: state write failed", e);
	}
}

function pidAlive(pid: number): boolean {
	if (!pid || pid <= 0) return false;
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

// NOTE: process.pid here IS the Pi process because the extension runs
// inside Pi's Node.js process space. If the extension ever runs out-of-process,
// this would need to derive the actual Pi PID from Pi's API.
// The check runs on every Pi event and the answer rarely changes, so cache
// it for a few seconds.
let appCacheAt = 0;
let appCacheVal = false;

// The PID file is the source of truth: the Swift app writes its PID on
// startup and removes it on exit. A pgrep by bundle id cannot work here,
// because the running process command line is the app binary path
// (/Applications/Pi Status Bar.app/Contents/MacOS/PiStatusBar), not the
// bundle id.
function appRunning(): boolean {
	if (Date.now() - appCacheAt < 5000) return appCacheVal;
	let result = false;
	const pidFile = path.join(DIR, "app.pid");
	try {
		const pid = parseInt(fs.readFileSync(pidFile, "utf8"), 10);
		if (pid && pidAlive(pid)) result = true;
	} catch {}
	appCacheAt = Date.now();
	appCacheVal = result;
	return result;
}

// Best-effort relaunch: a session with live state but no app to show it
// brings the app back (install-while-open, crash, …). Skipped after an
// explicit menu Quit (quit-intent marker) - a new session_start clears it.
function ensureAppRunning(): void {
	try {
		if (fs.existsSync(QUIT_MARKER)) return;
		if (appRunning()) return;
		spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
	} catch {}
}

// Drop files left by dead sessions (crash, kill -9): they would otherwise
// pin a stale icon forever. Live files are untouched.
function sweepStale(): void {
	let files: string[] = [];
	try {
		files = fs.readdirSync(STATE_DIR).filter((f) => f.endsWith(".json"));
	} catch {
		return;
	}
	for (const f of files) {
		const full = path.join(STATE_DIR, f);
		const sid = f.slice(0, -5); // remove .json
		let stat: fs.Stats;
		try {
			stat = fs.statSync(full);
		} catch {
			continue; // file vanished
		}
		if (!stat.isFile()) continue;
		let o: any;
		try {
			o = JSON.parse(fs.readFileSync(full, "utf8"));
		} catch {
			// Could be a file being written; never delete on a parse failure
			console.warn("pi-statusbar: unreadable state file " + f);
			continue;
		}
		if (!pidAlive(o.pid)) {
			// Delete file and clean up maps
			lastCtx.delete(sid);
			lastGood.delete(sid);
			try { fs.rmSync(full, { force: true }); } catch {}
		}
	}
}

function writeState(
	ctx: ExtensionContext,
	pi: ExtensionAPI,
	state: State,
	label: string,
	opts: { tool?: string; freshClock?: boolean; started?: boolean; remember?: boolean; clock?: number } = {},
): void {
	const id = sessionIdOf(ctx);
	const prev = readPrev(id);
	const cwd = ctx.cwd || (typeof prev.cwd === "string" ? prev.cwd : "");
	const now = Math.floor(Date.now() / 1000);
	let sessionName = "";
	try {
		sessionName = pi.getSessionName() || "";
	} catch {}
	// A working state must never carry a zero clock (that froze the spinner
	// with no timer): start it when none is running.
	const prevClock = typeof prev.startedAt === "number" ? prev.startedAt : 0;
	const startedAt =
		state === "thinking" || state === "tool"
			? (opts.clock ?? (opts.freshClock || !prevClock ? now : prevClock))
			: 0;
	const out: StatusFile = {
		state,
		label,
		tool: opts.tool ?? "",
		project: cwd ? path.basename(cwd) : (typeof prev.project === "string" ? prev.project : ""),
		cwd,
		sessionId: id,
		sessionName,
		entrypoint: "pi",
		term_program: process.env.TERM_PROGRAM || "",
		pid: process.pid,
		started: opts.started ?? (typeof prev.started === "boolean" ? prev.started : true),
		startedAt,
		ts: now,
	};
	if (opts.remember ?? true) lastGood.set(id, { state, label, tool: out.tool, startedAt });
	writeAtomic(statePath(id), out);
	lastCtx.set(id, ctx);
	if ((state === "thinking" || state === "tool") && !beat) {
		beat = setInterval(() => {
			for (const [sid, sctx] of lastCtx) {
				if (prompting.has(sid)) continue;
				const g = lastGood.get(sid);
				if (!g || (g.state !== "thinking" && g.state !== "tool")) continue;
				writeState(sctx, pi, g.state, g.label, { tool: g.tool, started: true, remember: false });
			}
		}, HEARTBEAT_MS);
		// Must not hold the runtime open on its own.
		beat.unref?.();
	}
}

export default function (pi: ExtensionAPI) {
	const safe = (fn: (ctx: ExtensionContext) => void) => async (_e: unknown, ctx: ExtensionContext) => {
		try {
			fn(ctx);
		} catch (e) {
			console.warn("pi-statusbar: handler failed", e);
		}
	};

	pi.on(
		"session_start",
		safe((ctx) => {
			// A new session voids a prior explicit Quit.
			try {
				fs.rmSync(QUIT_MARKER, { force: true });
			} catch {}
			sweepStale();
			// Seed an idle file: counts the session for launch + liveness, and
			// clears any frozen state from a resume. started:false keeps a
			// merely-opened session out of the dropdown until real activity.
			const id = sessionIdOf(ctx);
			const cwd = ctx.cwd || "";
			const now = Math.floor(Date.now() / 1000);
			let sessionName = "";
			try {
				sessionName = pi.getSessionName() || "";
			} catch {}
			writeAtomic(statePath(id), {
				state: "idle",
				label: "",
				tool: "",
				project: cwd ? path.basename(cwd) : "",
				cwd,
				sessionId: id,
				sessionName,
				entrypoint: "pi",
				term_program: process.env.TERM_PROGRAM || "",
				pid: process.pid,
				started: false,
				startedAt: 0,
				ts: now,
			});
			ensureAppRunning();
		}),
	);

	// A run starts: fresh clock, real activity (visible in dropdown).
	const onRunStart = (ctx: ExtensionContext) => {
		writeState(ctx, pi, "thinking", "Thinking…", { freshClock: true, started: true });
		ensureAppRunning();
	};
	pi.on("agent_start", safe(onRunStart));

	// Later turns / tool round-trips: thinking, keep the turn clock.
	pi.on(
		"turn_start",
		safe((ctx) => writeState(ctx, pi, "thinking", "Thinking…", { started: true })),
	);
	pi.on(
		"tool_execution_end",
		safe((ctx) => writeState(ctx, pi, "thinking", "Thinking…", { started: true })),
	);

	// Tool starts: label per tool, keep the clock. Skip nested calls
	// (parentToolCallId set) - the parent tool already owns the label.
	pi.on("tool_execution_start", async (event, ctx) => {
		try {
			if (event.parentToolCallId) return;
			const name = event.toolName || "";
			writeState(ctx, pi, "tool", TOOL_LABELS[name] || (name ? `Using ${name}` : "Using tool"), {
				tool: name,
				started: true,
			});
		} catch {}
	});

	// Blocking UI prompt (confirm/select): Pi waits on the user. Not
	// remembered: ui_prompt_end restores lastGood instead.
	pi.on(
		"ui_prompt_start",
		safe((ctx) => {
			prompting.add(sessionIdOf(ctx));
			writeState(ctx, pi, "permission", "Awaiting input", { started: true, remember: false });
		}),
	);
	pi.on("ui_prompt_end", async (_event, ctx) => {
		try {
			const id = sessionIdOf(ctx);
			prompting.delete(id);
			const g = lastGood.get(id);
			ensureAppRunning();
			if (!g) {
				writeState(ctx, pi, "idle", "", { started: true });
				return;
			}
			writeState(ctx, pi, g.state, g.label, { tool: g.tool, started: true, clock: g.startedAt });
		} catch {}
	});

	// Full run settled. aborted (Esc) → idle, else done.
	pi.on("agent_settled", async (event, ctx) => {
		try {
			if (event.aborted) writeState(ctx, pi, "idle", "", { started: true });
			else writeState(ctx, pi, "done", "Done", { started: true });
		} catch {}
	});

	// Session gone: drop the file so the session leaves the aggregate.
	pi.on("session_shutdown", async (_event, ctx) => {
		try {
			const id = sessionIdOf(ctx);
			fs.rmSync(statePath(id), { force: true });
			lastCtx.delete(id);
			lastGood.delete(id);
			stopBeatIfIdle();
		} catch {}
	});
}
