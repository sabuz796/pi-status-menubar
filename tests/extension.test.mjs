/**
 * State machine test for extensions/pi-statusbar.ts.
 *
 * Runs the extension in-process against a throwaway HOME so it never touches
 * the real ~/.pi/statusbar or launches the menu bar app. Node strips the
 * TypeScript types, so a plain .mjs file can import the .ts module directly.
 *
 * Run from the repo root: node tests/extension.test.mjs
 */

import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

test("pi-statusbar extension state machine", async (t) => {
	// Isolate HOME before the import: the extension reads os.homedir() once at
	// module load. A temp HOME also keeps its state.d writes off the real one.
	const home = fs.mkdtempSync(path.join(os.tmpdir(), "pi-statusbar-test-"));
	const oldHome = process.env.HOME;
	process.env.HOME = home;

	const statusDir = path.join(home, ".pi", "statusbar");
	fs.mkdirSync(statusDir, { recursive: true });

	// ensureAppRunning() returns early when the app looks alive. Claiming our
	// own PID makes appRunning() true, so it never spawns `open -g -b ...`.
	// The pid-identity check asks ps for the process name, so a tiny fake ps
	// names every process PiStatusBar; the ppid query pane detection needs
	// fails, which is exactly the "probe unreliable" path it must survive;
	// anything else still runs the real ps.
	const binDir = path.join(home, "bin");
	fs.mkdirSync(binDir, { recursive: true });
	fs.writeFileSync(path.join(binDir, "ps"),
		"#!/bin/sh\nif [ \"$2\" = \"comm=\" ]; then echo PiStatusBar; elif [ \"$2\" = \"ppid=\" ]; then exit 1; else exec /bin/ps \"$@\"; fi\n");
	fs.chmodSync(path.join(binDir, "ps"), 0o755);
	process.env.PATH = binDir + ":" + process.env.PATH;
	fs.writeFileSync(path.join(statusDir, "app.pid"), String(process.pid));

	// Capture the 30s heartbeat instead of waiting for it. The extension also
	// starts a 3s pane-refresh timer, told apart by its interval. Both call
	// .unref(), so the stub must expose that.
	const realSetInterval = globalThis.setInterval;
	const realClearInterval = globalThis.clearInterval;
	let beat = null;
	let paneCb = null;
	let beatsCleared = 0;
	globalThis.setInterval = (cb, ms) => {
		if (ms === 30000) beat = cb;
		else if (ms === 3000) paneCb = cb;
		return { unref() {} };
	};
	globalThis.clearInterval = (handle) => {
		beatsCleared += 1;
		return realClearInterval(handle);
	};

	t.after(() => {
		globalThis.setInterval = realSetInterval;
		globalThis.clearInterval = realClearInterval;
		if (oldHome === undefined) delete process.env.HOME;
		else process.env.HOME = oldHome;
		fs.rmSync(home, { recursive: true, force: true });
	});

	const extensionPath = fileURLToPath(new URL("../extensions/pi-statusbar.ts", import.meta.url));
	const { default: register, paneFromTmux, paneFromCmux } = await import(extensionPath);

	const handlers = {};
	const pi = {
		on: (name, fn) => {
			handlers[name] = fn;
		},
		getSessionName: () => "",
	};
	register(pi);

	const ctx = { cwd: "/tmp/my-app", sessionManager: { getSessionId: () => "sess-1" } };
	const stateFile = path.join(statusDir, "state.d", "sess-1.json");
	const readState = () => JSON.parse(fs.readFileSync(stateFile, "utf8"));
	const TOTAL = 27;
	const done = [];

	function step(name, fn) {
		fn();
		done.push(name);
		console.log("PASS " + name);
	}

	try {
		await handlers.session_start(undefined, ctx);
		step("session_start seeds idle", () => assert.strictEqual(readState().state, "idle"));

		// A. A run starts with a fresh clock.
		await handlers.agent_start(undefined, ctx);
		const started = readState();
		step("A agent_start -> thinking", () => assert.strictEqual(started.state, "thinking"));
		step("A agent_start starts the clock", () => assert.ok(started.startedAt > 0));

		// B. A tool call swaps the label but keeps the clock.
		await handlers.tool_execution_start({ toolName: "edit" }, ctx);
		const tooling = readState();
		step("B tool_execution_start -> tool", () => assert.strictEqual(tooling.state, "tool"));
		step("B tool_execution_start label", () => assert.strictEqual(tooling.label, "Editing"));

		// C. A blocking prompt takes over the icon.
		await handlers.ui_prompt_start(undefined, ctx);
		step("C ui_prompt_start -> permission", () => assert.strictEqual(readState().state, "permission"));
		step("C heartbeat keeps running while waiting", () => assert.strictEqual(beatsCleared, 0));

		// D. Regression: the heartbeat must not erase the prompt. The beat used
		// to rewrite the remembered tool state, dropping the amber dot. This
		// fails if the `if (prompting.has(sid)) continue;` guard is removed.
		step("D heartbeat captured", () => assert.strictEqual(typeof beat, "function"));
		beat();
		step("D heartbeat keeps permission", () => assert.strictEqual(readState().state, "permission"));

		// E. Closing the prompt restores the pre-prompt state and clock.
		await handlers.ui_prompt_end(undefined, ctx);
		const restored = readState();
		step("E ui_prompt_end -> tool", () => assert.strictEqual(restored.state, "tool"));
		step("E ui_prompt_end label", () => assert.strictEqual(restored.label, "Editing"));
		step("E ui_prompt_end clock is continuous", () =>
			assert.strictEqual(restored.startedAt, tooling.startedAt));

		// F. Esc / abort settles to idle.
		await handlers.agent_settled({ aborted: true }, ctx);
		step("F agent_settled aborted -> idle", () => assert.strictEqual(readState().state, "idle"));
		step("F heartbeat stops when the work ends", () => assert.ok(beatsCleared >= 1));

		// G. A normal finish settles to done.
		await handlers.agent_settled({ aborted: false }, ctx);
		const finished = readState();
		step("G agent_settled -> done", () => assert.strictEqual(finished.state, "done"));
		step("G agent_settled label", () => assert.strictEqual(finished.label, "Done"));

		// H. Pane refresh: the app's failed-focus marker is consumed by the
		// pane timer, and the tick keeps the user-visible state fields intact
		// (terminal fields legitimately change when a multiplexer is present).
		step("H pane timer captured", () => assert.strictEqual(typeof paneCb, "function"));
		fs.writeFileSync(path.join(statusDir, "refresh-pane"), JSON.stringify({ ts: Math.floor(Date.now() / 1000) }));
		paneCb();
		const afterPane = readState();
		step("H pane tick consumes the refresh marker", () =>
			assert.ok(!fs.existsSync(path.join(statusDir, "refresh-pane"))));
		step("H pane tick preserves the session row", () => {
			for (const key of ["state", "label", "tool", "project", "cwd", "sessionId", "pid", "started", "startedAt"]) {
				assert.strictEqual(afterPane[key], finished[key]);
			}
		});

		// J. The marker names its session. A session owned by another Pi
		// process must be left for up to 15 s; a stale marker is dropped so
		// no one waits on a dead owner.
		fs.writeFileSync(path.join(statusDir, "state.d", "foreignsess.json"),
			JSON.stringify({ pid: 1 }));
		fs.writeFileSync(path.join(statusDir, "refresh-pane"),
			JSON.stringify({ sessionId: "foreignsess", ts: Math.floor(Date.now() / 1000) }));
		paneCb();
		step("J sibling leaves a foreign marker", () =>
			assert.ok(fs.existsSync(path.join(statusDir, "refresh-pane"))));
		fs.writeFileSync(path.join(statusDir, "refresh-pane"),
			JSON.stringify({ sessionId: "foreignsess", ts: Math.floor(Date.now() / 1000) - 20 }));
		paneCb();
		step("J a stale foreign marker is dropped", () =>
			assert.ok(!fs.existsSync(path.join(statusDir, "refresh-pane"))));

		// K. The pane parsers the tick shares with startup: tmux matches only
		// own-ancestor panes, cmux reads its caller refs, garbage stays null.
		step("K tmux parser matches an ancestor pane", () =>
			assert.deepStrictEqual(
				paneFromTmux("%0 300\n%1 500\n", [300, 500], "tmux"),
				{ app: "tmux", paneId: "%0" }));
		step("L tmux parser ignores foreign panes", () =>
			assert.strictEqual(paneFromTmux("%0 999\n", [300], "tmux"), null));
		step("L cmux parser reads the caller refs", () =>
			assert.deepStrictEqual(
				paneFromCmux('{"caller":{"pane_ref":"p1","workspace_ref":"w1"}}'),
				{ app: "cmux", paneId: "p1", workspaceId: "w1" }));
		step("L cmux parser survives garbage", () =>
			assert.strictEqual(paneFromCmux("not json"), null));

		// M. Structured logging: a failed state write lands in log.jsonl as a
		// JSON record. A regular file where state.d belongs makes mkdir fail.
		fs.rmSync(path.join(statusDir, "state.d"), { recursive: true, force: true });
		fs.writeFileSync(path.join(statusDir, "state.d"), "not a directory");
		await handlers.tool_execution_start({ toolName: "edit" }, ctx);
		const logLine = fs.readFileSync(path.join(statusDir, "log.jsonl"), "utf8").trim().split("\n").pop();
		step("I handler failure is logged as JSON", () => {
			const rec = JSON.parse(logLine);
			assert.strictEqual(rec.level, "error");
			assert.strictEqual(rec.source, "extension");
			assert.strictEqual(rec.event, "state-write-failed");
		});
		// N. A re-detect whose own probe failed (ps exits 1 here) must keep the
		// pane it already wrote: blanking it would strand click-to-focus on
		// garbage, and the panel row needs the id to stay clickable. Section M
		// replaced state.d with a plain file for the logging test, so rebuild.
		fs.rmSync(path.join(statusDir, "state.d"), { force: true });
		fs.mkdirSync(path.join(statusDir, "state.d"));
		fs.writeFileSync(stateFile, JSON.stringify({
			state: "done", label: "Done", tool: "", project: "x", cwd: "/tmp",
			sessionId: "sess-1", terminalApp: "cmux",
			terminalWindowId: "pane:999", terminalWorkspaceId: "workspace:9",
			pid: process.pid, started: true, ts: Math.floor(Date.now() / 1000),
		}));
		paneCb();
		await new Promise((resolve) => setTimeout(resolve, 60));
		const kept = JSON.parse(fs.readFileSync(stateFile, "utf8"));
		step("N failed re-detect keeps the known pane", () => {
			assert.strictEqual(kept.terminalApp, "cmux");
			assert.strictEqual(kept.terminalWindowId, "pane:999");
		});
	} finally {
		const failed = done.length !== TOTAL;
		console.log(
			"\n" + (failed ? "FAIL" : "PASS") + ": " + done.length + "/" + TOTAL + " checks passed" +
				(failed ? " (stopped at first failure, see above)" : ""),
		);
	}
});
