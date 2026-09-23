import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// The extension keeps its cross-session handoff under $HOME/.cache, so HOME is
// redirected to a throwaway directory before the module (and its HANDOFF_FILE)
// is evaluated.
const FAKE_HOME = mkdtempSync(join(tmpdir(), "ctx-router-home-"));
process.env.HOME = FAKE_HOME;
const HANDOFF_FILE = join(FAKE_HOME, ".cache", "pi", "context-router", "pending-route.json");
const EXT_PATH = fileURLToPath(new URL("../extensions/context-router.ts", import.meta.url));
const SKILL_PATH = fileURLToPath(new URL("../skills/assess/SKILL.md", import.meta.url));

const { default: contextRouterExtension } = await import(EXT_PATH);

const SOURCE_SESSION_ID = "session-1";
const SOURCE_SESSION_FILE = "/tmp/source-session.jsonl";
const HAIKU = { provider: "anthropic", id: "claude-haiku-4.5" };
const OPUS = { provider: "anthropic", id: "claude-opus-4.6" };

const SENTINEL_BEGIN = "<!-- ASSESS-DOSSIER:BEGIN -->";
const SENTINEL_END = "<!-- ASSESS-DOSSIER:END -->";

// What the `assess` skill ships as its fenced schema template — placeholders and
// sentinels included. This lands in the transcript as prompt content.
const SKILL_TEMPLATE = `${SENTINEL_BEGIN}
## Symptom
<observed, expected, trigger — one line each>

## Fault
<path:line of the divergent line>
<one-paragraph root cause hypothesis>
<confidence: high | medium | low>

## Exhibits
<verbatim code>
${SENTINEL_END}`;

const REAL_DOSSIER = `${SENTINEL_BEGIN}
## Symptom
observed: NaN price; expected: 42.10; trigger: load a chain with no bid.
## Fault
src/quotes.py:88 — divides by mid when mid is 0.
confidence: high — line 88 divides by zero.
## Exhibits
src/quotes.py:86-90
\`\`\`python
def mid(bid, ask):
    return (bid + ask) / 2
\`\`\`
${SENTINEL_END}`;

const NEWER_DOSSIER = REAL_DOSSIER.replace("src/quotes.py", "src/nested/quotes.py");

function textPart(text) {
	return [{ type: "text", text }];
}

function assistantEntry(text) {
	return { type: "message", message: { role: "assistant", content: textPart(text) } };
}
function userEntry(text) {
	return { type: "message", message: { role: "user", content: textPart(text) } };
}

/** The default bindings SelectList resolves for `tui.select.*` actions. */
function defaultMatches(data, action) {
	switch (action) {
		case "tui.select.up":
			return data === "\x1b[A";
		case "tui.select.down":
			return data === "\x1b[B";
		case "tui.select.confirm":
			return data === "\r" || data === "\n";
		case "tui.select.cancel":
			return data === "\x1b" || data === "\x03";
		default:
			return false;
	}
}

/** One extension instance, with its own `pi`, context, and captured sent messages. */
function makeInstance({ entries = [], scopedModels = [], available = [], currentModel = HAIKU } = {}) {
	const events = new Map();
	const commands = new Map();
	const sent = [];
	const notices = [];
	const modelCalls = [];
	let sessionName;

	const pi = {
		on(name, handler) {
			events.set(name, handler);
		},
		registerCommand(name, def) {
			commands.set(name, def);
		},
		sendUserMessage(text, opts) {
			sent.push({ text, opts });
		},
		async setModel(model) {
			modelCalls.push(model);
			return true;
		},
		setSessionName(name) {
			sessionName = name;
		},
	};

	const ctx = {
		mode: "tui",
		hasUI: true,
		model: currentModel,
		scopedModels,
		sessionManager: {
			getEntries: () => entries,
			getSessionId: () => SOURCE_SESSION_ID,
			getSessionFile: () => SOURCE_SESSION_FILE,
		},
		modelRegistry: { getAvailable: async () => available },
		sendUserMessage: async (content) => {
			sent.push({ text: content, opts: undefined });
		},
		ui: {
			notify: (message, level) => notices.push({ message, level }),
		},
	};

	return {
		events,
		commands,
		sent,
		notices,
		modelCalls,
		ctx,
		pi,
		get sessionName() {
			return sessionName;
		},
	};
}

/**
 * Wires a source instance and the replacement instance that a real
 * `ctx.newSession()` would create, preserving pi's documented ordering: the new
 * instance receives `session_start` before `withSession` runs in the old closure.
 */
function makeHarness(options = {}) {
	const source = makeInstance({
		entries: options.entries,
		scopedModels: options.scopedModels,
		available: options.available,
		currentModel: options.currentModel,
	});
	const replacement = makeInstance({
		// A scoped model is always also an authenticated model, so the replacement
		// session's registry is at least as wide as the scope used to pick it.
		available: options.replacementAvailable ?? options.available,
	});
	const pickerComponents = [];
	const newSessions = [];

	source.ctx.ui.select = async (title, labels) =>
		options.selectAnswer ? options.selectAnswer(title, labels) : undefined;

	source.ctx.ui.custom = async (factory) => {
		let result;
		let settled = false;
		const done = (value) => {
			result = value;
			settled = true;
		};
		const tui = { requestRender: () => {} };
		const theme = { fg: (_color, text) => text, bold: (text) => text };
		const component = await factory(tui, theme, { matches: defaultMatches }, done);
		pickerComponents.push(component);
		for (const key of options.pickerKeys ?? ["\r"]) component.handleInput(key);
		assert.ok(settled, "the picker never produced a selection");
		return result;
	};

	source.ctx.newSession = async (opts) => {
		newSessions.push(opts);
		// A successful replacement rebinds a fresh extension instance.
		contextRouterExtension(replacement.pi);
		const startHandler = replacement.events.get("session_start");
		if (startHandler) {
			await startHandler(
				{ type: "session_start", reason: "new", previousSessionFile: SOURCE_SESSION_FILE },
				replacement.ctx,
			);
		}
		if (opts.withSession) await opts.withSession(replacement.ctx);
		return { cancelled: options.cancelSession === true };
	};

	contextRouterExtension(source.pi);

	return { ...source, replacement, pickerComponents, newSessions };
}

const extractionPromptOf = (sent) =>
	sent.find((m) => m.text.includes("Create a compact debugging dossier"));
const finalizeIdOf = (sent) => {
	const msg = sent.find((m) => m.text.startsWith("/context-router-finalize "));
	return msg?.text.split(" ")[1];
};
const continuationOf = (sent) => sent.find((m) => m.text.startsWith("Continue the work"));

/** Run a full route-to-finalize cycle and hand back both instances. */
async function route(h, args = "") {
	await h.commands.get("route-context").handler(args, h.ctx);
	await h.commands.get("context-router-finalize").handler(finalizeIdOf(h.sent), h.ctx);
	return h;
}

/** Read the handoff file, or undefined when it is absent or unparsable. */
function readHandoff() {
	try {
		return JSON.parse(readFileSync(HANDOFF_FILE, "utf8"));
	} catch {
		return undefined;
	}
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

// --- 1. The skill's own template (prompt content) must NOT count as a dossier.
test("ignores the assess skill template arriving as prompt content", async () => {
	const h = makeHarness({ entries: [userEntry(SKILL_TEMPLATE)] });
	await h.commands.get("route-context").handler("", h.ctx);
	assert.ok(extractionPromptOf(h.sent), "expected the extraction path");
	assert.equal(finalizeIdOf(h.sent), undefined, "must not reuse a template");
});

// --- 2. A template echoed back by the *model* is also not a dossier.
test("rejects a template echoed back inside an assistant message", async () => {
	const h = makeHarness({ entries: [assistantEntry(`Here is my plan:\n\n${SKILL_TEMPLATE}`)] });
	await h.commands.get("route-context").handler("", h.ctx);
	assert.ok(extractionPromptOf(h.sent), "expected the extraction path");
	assert.equal(finalizeIdOf(h.sent), undefined);
});

// --- 3. A real dossier in an assistant message is reused, with no extraction call.
test("reuses a real assess dossier and skips extraction entirely", async () => {
	const h = makeHarness({ entries: [userEntry("bug report"), assistantEntry(REAL_DOSSIER)] });
	await h.commands.get("route-context").handler("", h.ctx);
	assert.equal(extractionPromptOf(h.sent), undefined, "must not re-extract");
	assert.ok(finalizeIdOf(h.sent), "expected the finalize handoff");
	assert.match(h.notices.at(-1).message, /dossier from \/assess/);
});

// --- 4. A half-written block (BEGIN with no END) is not a dossier.
test("rejects an unterminated sentinel block", async () => {
	const half = `${SENTINEL_BEGIN}\n## Symptom\nsomething broke`;
	const h = makeHarness({ entries: [assistantEntry(half)] });
	await h.commands.get("route-context").handler("", h.ctx);
	assert.ok(extractionPromptOf(h.sent), "expected the extraction path");
});

// --- 5. With several dossiers, the newest one wins.
test("selects the newest dossier when several exist", async () => {
	const h = await route(
		makeHarness({
			entries: [assistantEntry(REAL_DOSSIER), assistantEntry(NEWER_DOSSIER)],
			available: [OPUS],
		}),
	);
	assert.match(continuationOf(h.replacement.sent).text, /src\/nested\/quotes\.py/);
});

// --- 6. The extractor's own reply advances the flow via turn_end.
test("turn_end picks up a freshly written dossier and advances", async () => {
	const h = makeHarness();
	await h.commands.get("route-context").handler("", h.ctx);
	assert.ok(extractionPromptOf(h.sent));

	h.events.get("turn_end")(
		{ message: { role: "assistant", content: textPart(`Done.\n\n${REAL_DOSSIER}`) } },
		h.ctx,
	);
	assert.ok(finalizeIdOf(h.sent), "expected finalize to be triggered by turn_end");
});

// --- 7. Full handoff: new session, parent recorded, model adopted, prompt seeded.
test("full handoff creates the continuation session with the right parent", async () => {
	const h = await route(makeHarness({ entries: [assistantEntry(REAL_DOSSIER)], available: [HAIKU] }));

	assert.equal(h.newSessions.length, 1);
	assert.equal(h.newSessions[0].parentSession, SOURCE_SESSION_FILE);

	// The crash was caused by using the captured pi/ctx after newSession(), so the
	// continuation must be delivered by the *replacement* context, never the old one.
	assert.equal(continuationOf(h.sent), undefined, "stale source instance must not send");
	assert.ok(continuationOf(h.replacement.sent), "replacement context delivers the prompt");
	assert.ok(
		continuationOf(h.replacement.sent).text.includes(SENTINEL_BEGIN),
		"dossier travels with the prompt",
	);

	// The new instance adopts the picked model in its own session_start.
	assert.deepEqual(h.replacement.modelCalls, [HAIKU]);
	assert.equal(h.replacement.sessionName, `Routed to ${HAIKU.id}`);
});

// --- 8. Cancelling the model picker leaves the source session untouched.
test("cancelled model selection creates no session", async () => {
	const h = await route(
		makeHarness({ entries: [assistantEntry(REAL_DOSSIER)], available: [HAIKU], pickerKeys: ["\x1b"] }),
	);
	assert.equal(h.newSessions.length, 0);
	assert.match(h.notices.at(-1).message, /cancelled/i);
	assert.equal(readHandoff(), undefined, "a cancelled pick writes no handoff");
});

// --- 9. A mismatched requestId cannot hijack the handoff.
test("rejects a finalize call with the wrong requestId", async () => {
	const h = makeHarness({ entries: [assistantEntry(REAL_DOSSIER)], available: [HAIKU] });
	await h.commands.get("route-context").handler("", h.ctx);
	await h.commands.get("context-router-finalize").handler("not-the-id", h.ctx);
	assert.equal(h.newSessions.length, 0);
});

// --- 10. Scoped models take precedence over the global registry.
test("prefers scoped models over the available list", async () => {
	const h = await route(
		makeHarness({
			entries: [assistantEntry(REAL_DOSSIER)],
			scopedModels: [{ model: OPUS }],
			available: [HAIKU],
			replacementAvailable: [HAIKU, OPUS],
		}),
	);
	assert.deepEqual(h.replacement.modelCalls, [OPUS]);
	assert.equal(h.replacement.sessionName, `Routed to ${OPUS.id}`);
});

// --- 11. The fallback extractor prompt carries the skill's dossier schema.
test("extractor prompt matches the assess dossier schema", async () => {
	const h = makeHarness({ entries: [userEntry("no dossier here")] });
	await h.commands.get("route-context").handler("", h.ctx);
	const prompt = extractionPromptOf(h.sent).text;
	for (const heading of [
		"## Symptom",
		"## Fault",
		"## Paths",
		"## Exhibits",
		"## Ruled out",
		"## Unknowns",
		"## Excluded",
	]) {
		assert.ok(prompt.includes(heading), `extractor prompt missing ${heading}`);
	}
	assert.ok(prompt.includes(SENTINEL_BEGIN) && prompt.includes(SENTINEL_END));
});

// --- 12. Typing narrows the list: the filter reaches SelectList, not the list's keys.
test("typed filter narrows the model list before selecting", async () => {
	const h = await route(
		makeHarness({
			entries: [assistantEntry(REAL_DOSSIER)],
			available: [HAIKU, OPUS],
			// "opus" must filter out haiku, so enter selects opus rather than the
			// alphabetically-first entry.
			pickerKeys: ["o", "p", "u", "s", "\r"],
		}),
	);
	assert.deepEqual(h.replacement.modelCalls, [OPUS]);
});

// --- 13. The handoff is consumed exactly once.
test("session_start consumes the handoff so it cannot fire twice", async () => {
	await route(makeHarness({ entries: [assistantEntry(REAL_DOSSIER)], available: [HAIKU] }));
	assert.equal(readHandoff(), undefined, "handoff removed after adoption");

	const again = makeInstance({ available: [HAIKU] });
	contextRouterExtension(again.pi);
	await again.events.get("session_start")(
		{ type: "session_start", reason: "new", previousSessionFile: SOURCE_SESSION_FILE },
		again.ctx,
	);
	assert.deepEqual(again.modelCalls, [], "no second adoption");
});

// --- 14. A handoff from a different source session is ignored.
test("ignores a handoff that names a different source session", async () => {
	writeFileSync(
		HANDOFF_FILE,
		JSON.stringify({
			requestId: "r1",
			sourceSessionId: "other",
			sourceSessionFile: "/tmp/some-other-session.jsonl",
			sourceModel: "anthropic/claude-haiku-4.5",
			targetProvider: OPUS.provider,
			targetModelId: OPUS.id,
			dossier: REAL_DOSSIER,
			createdAt: Date.now(),
		}),
	);
	const h = makeInstance({ available: [HAIKU, OPUS] });
	contextRouterExtension(h.pi);
	await h.events.get("session_start")(
		{ type: "session_start", reason: "new", previousSessionFile: SOURCE_SESSION_FILE },
		h.ctx,
	);
	assert.deepEqual(h.modelCalls, [], "must not adopt a foreign handoff");
});

// --- 15. An expired handoff is discarded rather than adopted.
test("discards an expired handoff", async () => {
	writeFileSync(
		HANDOFF_FILE,
		JSON.stringify({
			requestId: "r2",
			sourceSessionId: SOURCE_SESSION_ID,
			sourceSessionFile: SOURCE_SESSION_FILE,
			sourceModel: "anthropic/claude-haiku-4.5",
			targetProvider: OPUS.provider,
			targetModelId: OPUS.id,
			dossier: REAL_DOSSIER,
			createdAt: Date.now() - 60_000 - 1,
		}),
	);
	const h = makeInstance({ available: [OPUS] });
	contextRouterExtension(h.pi);
	await h.events.get("session_start")(
		{ type: "session_start", reason: "new", previousSessionFile: SOURCE_SESSION_FILE },
		h.ctx,
	);
	assert.deepEqual(h.modelCalls, [], "must not adopt an expired handoff");
	assert.equal(readHandoff(), undefined, "expired handoff cleared");
});

// --- 16. A startup does not consume a handoff left behind by a crash.
test("ignores a handoff on plain startup", async () => {
	writeFileSync(
		HANDOFF_FILE,
		JSON.stringify({
			requestId: "r3",
			sourceSessionId: SOURCE_SESSION_ID,
			sourceSessionFile: SOURCE_SESSION_FILE,
			sourceModel: "anthropic/claude-haiku-4.5",
			targetProvider: OPUS.provider,
			targetModelId: OPUS.id,
			dossier: REAL_DOSSIER,
			createdAt: Date.now(),
		}),
	);
	const h = makeInstance({ available: [OPUS] });
	contextRouterExtension(h.pi);
	await h.events.get("session_start")({ type: "session_start", reason: "startup" }, h.ctx);
	assert.deepEqual(h.modelCalls, [], "startup must not adopt a handoff");
});

// --- 17. No authenticated models means no session is created.
test("stops cleanly when no target models are available", async () => {
	const h = await route(makeHarness({ entries: [assistantEntry(REAL_DOSSIER)], available: [] }));
	assert.equal(h.newSessions.length, 0);
	assert.match(h.notices.at(-1).message, /No authenticated target models/);
});

// --- The skill and the extension each carry the dossier schema; these pin them together.

/** The fenced dossier template the `assess` skill actually ships. */
function shippedSkillTemplate() {
	const skill = readFileSync(SKILL_PATH, "utf8");
	const match = skill.match(/````text\n([\s\S]*?)\n````/);
	assert.ok(match, "assess skill must ship a ````text dossier template");
	return match[1];
}

// --- 18. Drift guard: every section the skill asks for, the fallback extractor asks for too.
test("extractor prompt carries every section of the shipped skill template", async () => {
	const headings = shippedSkillTemplate().match(/^## .+$/gm) ?? [];
	assert.ok(headings.length >= 6, "template should declare its sections");
	const h = makeHarness({ entries: [userEntry("no dossier here")] });
	await h.commands.get("route-context").handler("", h.ctx);
	const prompt = extractionPromptOf(h.sent).text;
	for (const heading of headings) {
		assert.ok(prompt.includes(`\n${heading}\n`), `extractor prompt missing ${heading}`);
	}
});

// --- 19. Drift guard: the real shipped template is still recognised as a template.
test("the shipped skill template is never mistaken for a dossier", async () => {
	const h = makeHarness({ entries: [assistantEntry(shippedSkillTemplate())] });
	await h.commands.get("route-context").handler("", h.ctx);
	assert.ok(extractionPromptOf(h.sent), "expected the extraction path");
	assert.equal(finalizeIdOf(h.sent), undefined, "must not reuse the shipped template");
});

// --- 20. Exhibits are only authoritative inside the Root they were read from.
test("continuation prompt scopes exhibits to the dossier's Root", async () => {
	const h = await route(makeHarness({ entries: [assistantEntry(REAL_DOSSIER)], available: [OPUS] }));
	const text = continuationOf(h.replacement.sent).text;
	assert.match(text, /relative to Root/);
	assert.match(text, /re-read a file/i);
	assert.match(text, /uncommitted changes/);
});

let failures = 0;
for (const { name, fn } of tests) {
	rmSync(HANDOFF_FILE, { force: true });
	try {
		await fn();
		console.log(`PASS  ${name}`);
	} catch (error) {
		failures++;
		console.log(`FAIL  ${name}`);
		console.log(`      ${error.message}`);
	}
}

rmSync(FAKE_HOME, { recursive: true, force: true });
console.log(`\n${tests.length - failures}/${tests.length} passed`);
if (failures > 0) process.exitCode = 1;