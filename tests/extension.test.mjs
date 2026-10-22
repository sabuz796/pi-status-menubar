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
	fs.writeFileSync(path.join(statusDir, "app.pid"), String(process.pid));

	// Capture the 30s heartbeat instead of waiting for it. The extension calls
	// .unref() on the handle, so the stub must expose that.
	const realSetInterval = globalThis.setInterval;
	let beat = null;
	globalThis.setInterval = (cb) => {
		beat = cb;
		return { unref() {} };
	};

	t.after(() => {
		globalThis.setInterval = realSetInterval;
		if (oldHome === undefined) delete process.env.HOME;
		else process.env.HOME = oldHome;
		fs.rmSync(home, { recursive: true, force: true });
	});

	const extensionPath = fileURLToPath(new URL("../extensions/pi-statusbar.ts", import.meta.url));
	const { default: register } = await import(extensionPath);

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
	const TOTAL = 14;
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

		// G. A normal finish settles to done.
		await handlers.agent_settled({ aborted: false }, ctx);
		const finished = readState();
		step("G agent_settled -> done", () => assert.strictEqual(finished.state, "done"));
		step("G agent_settled label", () => assert.strictEqual(finished.label, "Done"));
	} finally {
		const failed = done.length !== TOTAL;
		console.log(
			"\n" + (failed ? "FAIL" : "PASS") + ": " + done.length + "/" + TOTAL + " checks passed" +
				(failed ? " (stopped at first failure, see above)" : ""),
		);
	}
});
