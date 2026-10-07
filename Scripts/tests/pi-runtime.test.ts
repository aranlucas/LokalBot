// Run against a checksum-pinned, frozen-lockfile runtime:
// LOKALBOT_PINNED_RUNTIME_ROOT=/path/to/runtime bash Scripts/tests/run-pi-runtime-tests.sh
import { expect, test } from "bun:test";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { mkdir, mkdtemp, readFile, realpath, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import lokalbotExtension, {
  applyReasoningLevel, inferenceFetchForOrigin, readReasoningLevel, retryRejectedReasoning,
} from "../../LokalBot/Resources/pi/lokalbot-extension/index";

const runtime = process.env.LOKALBOT_PINNED_RUNTIME_ROOT;
const repo = resolve(import.meta.dir, "../..");

test("Agent fetch rejects unapproved origins and URL credentials before sending", async () => {
  let requests = 0;
  const transport = inferenceFetchForOrigin(new URL("https://approved.example/v1"), (async () => {
    requests++; return new Response("fixture");
  }) as typeof fetch);
  for (const target of [
    "https://other.example/v1/chat", "http://approved.example/v1/chat",
    "https://approved.example:8443/v1/chat", "https://user:secret@approved.example/v1/chat",
  ]) {
    await expect(transport(target)).rejects.toThrow("approved origin");
  }
  expect(requests).toBe(0);
  await transport(new Request("https://approved.example/v1/chat"));
  expect(requests).toBe(1);
});

for (const status of [301, 302, 303, 307, 308]) {
  test(`Agent fetch never replays a POST through a ${status} redirect`, async () => {
    let targetRequests = 0;
    const target = Bun.serve({ hostname: "127.0.0.1", port: 0,
      fetch() { targetRequests++; return new Response("unexpected"); },
    });
    const observed: string[] = [];
    const source = Bun.serve({ hostname: "127.0.0.1", port: 0,
      async fetch(request) {
        observed.push(await request.text());
        expect(request.headers.get("authorization")).toBe("Bearer synthetic-token");
        return new Response(null, { status, headers: { location: `http://127.0.0.1:${target.port}/receive` } });
      },
    });
    try {
      const endpoint = new URL(`http://127.0.0.1:${source.port}/v1`);
      const transport = inferenceFetchForOrigin(endpoint);
      await expect(transport(endpoint, {
        method: "POST", body: "synthetic-private-context",
        headers: { authorization: "Bearer synthetic-token" }, redirect: "follow",
      })).rejects.toThrow();
      expect(observed).toEqual(["synthetic-private-context"]);
      expect(targetRequests).toBe(0);
    } finally {
      source.stop(true); target.stop(true);
    }
  });
}

test("Agent fetch rejects same-origin redirects and preserves normal response streaming", async () => {
  const paths: string[] = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0,
    fetch(request) {
      const path = new URL(request.url).pathname;
      paths.push(path);
      if (path === "/redirect") return new Response(null, { status: 307, headers: { location: "/stream" } });
      return new Response("data: synthetic-token\n\ndata: [DONE]\n\n", {
        headers: { "content-type": "text/event-stream" },
      });
    },
  });
  try {
    const endpoint = new URL(`http://127.0.0.1:${server.port}/`);
    const transport = inferenceFetchForOrigin(endpoint);
    await expect(transport(new URL("/redirect", endpoint))).rejects.toThrow();
    expect(paths).toEqual(["/redirect"]);
    const response = await transport(new URL("/stream", endpoint));
    expect(await response.text()).toBe("data: synthetic-token\n\ndata: [DONE]\n\n");
  } finally { server.stop(true); }
});

// Exercise the actual extension hook without a model, library, or tool runner.
// Returning undefined is what allows Pi to execute, so a blocking result must
// be returned even if the fake UI would approve every request.
async function withExtensionFixture(run: (fixture: {
  root: string; workspace: string; library: string;
  call: (toolName: string, input: unknown) => Promise<any>;
  approvals: any[];
  provider: any;
}) => Promise<void>, baseUrl = "http://127.0.0.1:1234/v1", extraEnvironment: Record<string, string> = {}) {
  const root = await realpath(await mkdtemp(join(tmpdir(), "lokalbot-agent-boundary-")));
  const workspace = join(root, "workspace");
  const library = join(root, "private-library");
  await mkdir(workspace); await mkdir(library);
  const originalCWD = process.cwd();
  const environment = { ...process.env };
  try {
    process.chdir(workspace);
    process.env.LOKALBOT_LLM_BASE_URL = baseUrl;
    process.env.LOKALBOT_LLM_MODEL = "fixture";
    process.env.LOKALBOT_LLM_API_KEY = "synthetic-token";
    process.env.LOKALBOT_AGENT_PRIVATE_ROOTS = JSON.stringify([library]);
    Object.assign(process.env, extraEnvironment);
    let handler: any;
    let provider: any;
    lokalbotExtension({ registerProvider(_name: string, config: any) { provider = config; }, on(name: string, callback: any) {
      if (name === "tool_call") handler = callback;
    } } as any);
    const approvals: any[] = [];
    const call = (toolName: string, input: unknown) => handler({ toolName, input }, {
      ui: { confirm: async (_title: string, message: string) => {
        approvals.push(JSON.parse(message)); return true;
      } },
    });
    await run({ root, workspace, library, call, approvals, provider });
  } finally {
    process.chdir(originalCWD);
    for (const key of Object.keys(process.env)) if (!(key in environment)) delete process.env[key];
    Object.assign(process.env, environment);
    await rm(root, { recursive: true, force: true });
  }
}

for (const status of [307, 308]) {
  test(`registered pinned Agent provider rejects ${status} without replaying context`, async () => {
    let targetRequests = 0;
    const target = Bun.serve({ hostname: "127.0.0.1", port: 0,
      fetch() { targetRequests++; return new Response("unexpected"); },
    });
    const observed: string[] = [];
    const source = Bun.serve({ hostname: "127.0.0.1", port: 0,
      async fetch(request) {
        observed.push(await request.text());
        expect(request.headers.get("authorization")).toBe("Bearer synthetic-token");
        return new Response(null, { status, headers: { location: `http://127.0.0.1:${target.port}/receive` } });
      },
    });
    try {
      const baseUrl = `http://127.0.0.1:${source.port}/v1`;
      await withExtensionFixture(async ({ provider }) => {
        const model = { ...provider.models[0], provider: "lokalbot", api: provider.api,
          baseUrl, maxTokens: 128, name: "Fixture", reasoning: false };
        let callerFetchUsed = false;
        const stream = provider.streamSimple(model, {
          messages: [{ role: "user", content: "synthetic-private-context", timestamp: Date.now() }],
        }, { apiKey: "synthetic-token", maxRetries: 0, timeoutMs: 2_000,
          fetch: () => { callerFetchUsed = true; throw new Error("must use scoped transport"); },
        });
        const events: any[] = [];
        for await (const event of stream) events.push(event);
        expect(events.at(-1)?.type).toBe("error");
        expect(callerFetchUsed).toBe(false);
        expect(observed).toHaveLength(1);
        expect(observed[0]).toContain("synthetic-private-context");
        expect(targetRequests).toBe(0);
      }, baseUrl);
    } finally { source.stop(true); target.stop(true); }
  });
}

test("the provider key never reaches the environment shell commands inherit", async () => {
  await withExtensionFixture(async ({ provider }) => {
    expect(provider.apiKey).toBe("synthetic-token");
    expect(process.env.LOKALBOT_LLM_API_KEY).toBeUndefined();
    // pi's bash tool spawns each command with a copy of process.env.
    const shell = Bun.spawnSync(["/usr/bin/env"], { env: { ...process.env } });
    expect(shell.stdout.toString()).not.toContain("synthetic-token");
    // pi evaluates the extension again for a new session.
    let renewed: any;
    lokalbotExtension({ registerProvider(_name: string, config: any) { renewed = config; }, on() {} } as any);
    expect(renewed.apiKey).toBe("synthetic-token");
  });
});

test("default workspace reads do not implicitly authorize the private library", async () => {
  await withExtensionFixture(async ({ workspace, library, call, approvals }) => {
    await writeFile(join(workspace, "draft.txt"), "synthetic draft");
    await writeFile(join(library, "transcript.txt"), "synthetic transcript");
    expect(await call("read", { path: "draft.txt" })).toBeUndefined();
    expect(approvals).toHaveLength(0);
    await call("read", { path: join(library, "transcript.txt") });
    expect(approvals).toHaveLength(1);
    expect(approvals[0].path).toBe(join(library, "transcript.txt"));
  });
});

test("selecting a parent workspace still gates private-library reads", async () => {
  await withExtensionFixture(async ({ root, library, call, approvals }) => {
    process.chdir(root);
    await call("read", { path: join(library, "journal.md") });
    expect(approvals).toHaveLength(1);
  });
});

test("workspace symlinks do not turn private-library reads into implicit access", async () => {
  await withExtensionFixture(async ({ workspace, library, call, approvals }) => {
    await symlink(library, join(workspace, "linked-library"));
    await call("read", { path: "linked-library/meeting.md" });
    expect(approvals).toHaveLength(1);
    expect(approvals[0].path).toBe(join(library, "meeting.md"));
  });
});

test("the entire shell command at the length boundary is sent for approval", async () => {
  await withExtensionFixture(async ({ call, approvals }) => {
    const command = "#".repeat(65_536);
    expect(await call("bash", { command })).toBeUndefined();
    expect(approvals).toHaveLength(1);
    expect(approvals[0].command).toBe(command);
    expect(approvals[0].truncated).toBe(false);
  });
});

for (const command of ["#".repeat(65_536) + "; hidden suffix", "😀".repeat(32_768) + "x"]) {
  test(`oversized shell request (${command.length} UTF-16 units) is blocked before approval`, async () => {
    await withExtensionFixture(async ({ call, approvals }) => {
      expect((await call("bash", { command })).block).toBe(true);
      expect(approvals).toHaveLength(0);
    });
  });
}

test("malformed shell requests cannot obtain approval through a fallback preview", async () => {
  await withExtensionFixture(async ({ call, approvals }) => {
    for (const input of [undefined, {}, { cmd: "hidden alias" }, { command: 1 }]) {
      expect((await call("bash", input)).block).toBe(true);
    }
    expect(approvals).toHaveLength(0);
  });
});

test("every tool outside the allowlist asks with its exact arguments", async () => {
  await withExtensionFixture(async ({ call, approvals }) => {
    const input = { path: "/tmp/anywhere", nested: { text: "synthetic" } };
    const tools = ["mcp__stub__touch", "codemode", "tool_search", "grep", "future_tool"];
    for (const toolName of tools) expect(await call(toolName, input)).toBeUndefined();
    expect(approvals.map(approval => approval.tool)).toEqual(tools);
    for (const approval of approvals) expect(approval.arguments).toBe(JSON.stringify(input, null, 2));
  });
});

test("arguments of a tool without a preview must fit in full before approval", async () => {
  await withExtensionFixture(async ({ call, approvals }) => {
    const wrapper = JSON.stringify({ code: "" }, null, 2).length;
    expect(await call("codemode", { code: "#".repeat(65_536 - wrapper) })).toBeUndefined();
    expect((await call("codemode", { code: "#".repeat(65_536 - wrapper + 1) })).block).toBe(true);
    expect(approvals).toHaveLength(1);
    expect(approvals[0].arguments).toHaveLength(65_536);
  });
});

// One Pi RPC turn against a stub model that requests `toolCall` and then
// replies STUB-REPLY. Every approval prompt is answered with `approved`.
async function piTurn(options: {
  workspace: string; toolCall: { name: string; arguments: unknown }; approved: boolean;
  extensions?: string[]; piConfig?: string; beforeAnswer?: (payload: any) => Promise<void>;
}) {
  const requests: any[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(req) {
      expect(new URL(req.url).pathname).toBe("/v1/chat/completions");
      const body = await req.json();
      requests.push(body);
      const toolResult = body.messages.find((message: any) => message.role === "tool");
      const delta = toolResult ? { content: "STUB-REPLY" } : {
        tool_calls: [{ index: 0, id: "tool-test", type: "function", function: {
          name: options.toolCall.name, arguments: JSON.stringify(options.toolCall.arguments),
        } }],
      };
      const base = { id: "stub", object: "chat.completion.chunk", model: "stub-model" };
      const chunks = [
        { ...base, choices: [{ index: 0, delta: { role: "assistant" } }] },
        { ...base, choices: [{ index: 0, delta }] },
        { ...base, choices: [{ index: 0, delta: {}, finish_reason: toolResult ? "stop" : "tool_calls" }] },
      ];
      return new Response(chunks.map(chunk => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n",
        { headers: { "content-type": "text/event-stream" } });
    },
  });
  const proc = Bun.spawn([
    join(runtime!, "bun/bun"),
    join(runtime!, "pi/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"),
    "--mode", "rpc", "--provider", "lokalbot", "--model", "stub-model",
    "--no-extensions", "-e", join(repo, "LokalBot/Resources/pi/lokalbot-extension"),
    ...(options.extensions ?? []).flatMap(extension => ["-e", extension]),
    "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-approve",
    "--session-dir", join(options.workspace, "sessions"), "--offline",
  ], {
    cwd: options.workspace, stdin: "pipe", stdout: "pipe", stderr: "pipe",
    env: { PATH: process.env.PATH, HOME: options.workspace,
      PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0",
      PI_CODING_AGENT_DIR: options.piConfig ?? join(options.workspace, "pi-config"),
      LOKALBOT_LLM_BASE_URL: `http://127.0.0.1:${server.port}/v1`,
      LOKALBOT_LLM_MODEL: "stub-model", LOKALBOT_LLM_CTX: "16384" },
  });
  const send = (message: unknown) => { proc.stdin.write(JSON.stringify(message) + "\n"); proc.stdin.flush(); };
  const stderr = new Response(proc.stderr).text();
  const approvals: any[] = [];
  let reply = false;
  const timeout = setTimeout(() => proc.kill(), 20_000);
  try {
    send({ type: "prompt", id: "test", message: "Run the requested tool." });
    let pending = "";
    const decoder = new TextDecoder();
    outer: for await (const bytes of proc.stdout) {
      pending += decoder.decode(bytes, { stream: true });
      let newline: number;
      while ((newline = pending.indexOf("\n")) !== -1) {
        const line = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        if (!line.trim()) continue;
        const event = JSON.parse(line);
        if (event.type === "extension_error") throw new Error(JSON.stringify(event));
        if (event.type === "response" && !event.success) throw new Error(event.error);
        if (event.type === "extension_ui_request" && event.method === "confirm") {
          expect(event.title).toBe("lokalbot_tool_approval");
          const payload = JSON.parse(event.message);
          approvals.push(payload);
          await options.beforeAnswer?.(payload);
          send({ type: "extension_ui_response", id: event.id, confirmed: options.approved });
        }
        if (event.type === "message_end" && event.message.role === "assistant") {
          reply ||= event.message.content.some((part: any) => part.text === "STUB-REPLY");
        }
        if (event.type === "agent_end") break outer;
      }
    }
    return { approvals, reply, requests };
  } finally {
    clearTimeout(timeout);
    proc.kill();
    await proc.exited;
    const errors = await stderr;
    if (errors.trim()) console.error(errors);
    server.stop(true);
  }
}

for (const approved of [false, true]) {
  test.skipIf(!runtime)(`Pi requires approval before writing; confirmed=${approved}`, async () => {
    const workspace = await mkdtemp(join(tmpdir(), "lokalbot-pi-upgrade-"));
    const output = join(workspace, "approved.txt");
    try {
      const turn = await piTurn({
        workspace, approved,
        toolCall: { name: "write", arguments: { path: output, content: "approved content" } },
        beforeAnswer: async () => { expect(await stat(output).catch(() => null)).toBeNull(); },
      });
      expect(turn.approvals).toHaveLength(1);
      expect(turn.reply).toBe(true);
      expect(turn.requests).toHaveLength(2);
      if (approved) expect(await readFile(output, "utf8")).toBe("approved content");
      else expect(await stat(output).catch(() => null)).toBeNull();
    } finally {
      await rm(workspace, { recursive: true, force: true });
    }
  }, 25_000);
}

// Pi's MCP client is a built-in extension that Agent Mode's --no-extensions
// leaves off. Loading it explicitly proves its tools still pass the gate.
const STUB_MCP_SERVER = String.raw`
import { writeFileSync } from "node:fs";
let pending = "";
const send = (message) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => {
  pending += chunk;
  let newline;
  while ((newline = pending.indexOf("\n")) !== -1) {
    const line = pending.slice(0, newline).trim();
    pending = pending.slice(newline + 1);
    if (!line) continue;
    const message = JSON.parse(line);
    if (message.id === undefined) continue;
    if (message.method === "initialize") send({ id: message.id, result: {
      protocolVersion: message.params.protocolVersion, capabilities: { tools: {} },
      serverInfo: { name: "stub", version: "1.0.0" } } });
    else if (message.method === "tools/list") send({ id: message.id, result: { tools: [{ name: "touch",
      description: "Create a file.", inputSchema: { type: "object", properties: { path: { type: "string" } } } }] } });
    else if (message.method === "tools/call") {
      writeFileSync(message.params.arguments.path, "touched by MCP");
      send({ id: message.id, result: { content: [{ type: "text", text: "done" }] } });
    } else send({ id: message.id, error: { code: -32601, message: "method not found" } });
  }
});
`;

for (const approved of [false, true]) {
  test.skipIf(!runtime)(`an MCP tool call requires approval; confirmed=${approved}`, async () => {
    const workspace = await mkdtemp(join(tmpdir(), "lokalbot-pi-mcp-"));
    const output = join(workspace, "touched.txt");
    const piConfig = join(workspace, "pi-config");
    try {
      await mkdir(piConfig);
      await writeFile(join(workspace, "stub-mcp.js"), STUB_MCP_SERVER);
      await writeFile(join(piConfig, "mcp.json"), JSON.stringify({ mcpServers: { stub: {
        command: join(runtime!, "bun/bun"), args: [join(workspace, "stub-mcp.js")], exposure: "direct",
      } } }));
      const turn = await piTurn({
        workspace, approved, piConfig, extensions: ["builtin:mcp"],
        toolCall: { name: "mcp__stub__touch", arguments: { path: output } },
        beforeAnswer: async () => { expect(await stat(output).catch(() => null)).toBeNull(); },
      });
      expect(turn.requests[0].tools.map((tool: any) => tool.function.name)).toContain("mcp__stub__touch");
      expect(turn.approvals).toHaveLength(1);
      expect(turn.approvals[0].tool).toBe("mcp__stub__touch");
      expect(JSON.parse(turn.approvals[0].arguments)).toEqual({ path: output });
      expect(turn.reply).toBe(true);
      if (approved) expect(await readFile(output, "utf8")).toBe("touched by MCP");
      else expect(await stat(output).catch(() => null)).toBeNull();
    } finally {
      await rm(workspace, { recursive: true, force: true });
    }
  }, 25_000);
}

test("Pi resumes append-only context edits without overwriting visible history", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "lokalbot-pi-context-upgrade-"));
  try {
    const sessions = join(workspace, "sessions");
    const manager = SessionManager.create(workspace, sessions);
    const original = manager.appendMessage({ role: "user", content: "Original synthetic context", timestamp: 1 });
    manager.appendContextEdit(original, { content: "Condensed synthetic context" });
    manager.appendMessage({ role: "user", content: "Continue the task", timestamp: 2 });
    const file = manager.getSessionFile();
    expect(file).toBeDefined();
    const resumed = SessionManager.open(file!, sessions);
    expect(resumed.buildSessionContext().messages.map(message => message.content))
      .toEqual(["Condensed synthetic context", "Continue the task"]);
    expect(await readFile(file!, "utf8")).toContain("Original synthetic context");
    expect(resumed.getEntries().some(entry => entry.type === "context_edit")).toBe(true);
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("a reasoning level becomes each server's own request fields", () => {
  const base = { model: "m", max_completion_tokens: 2_000 };
  expect(applyReasoningLevel(base, "automatic", "generic", "m")).toBe(base);
  expect(applyReasoningLevel(base, "off", "generic", "qwen-3.8-27b").reasoning_effort).toBe("none");
  expect(applyReasoningLevel(base, "xhigh", "openai", "gpt-5.4-mini").reasoning_effort).toBe("xhigh");
  expect(applyReasoningLevel(base, "high", "openai", "gpt-4.1").reasoning_effort).toBeUndefined();
  expect(applyReasoningLevel(base, "max", "openrouter", "z-ai/glm-5.3-flash").reasoning).toEqual({ effort: "max" });
  expect(applyReasoningLevel(base, "high", "ollama", "gpt-oss:20b").reasoning_effort).toBe("high");
  expect(applyReasoningLevel(base, "off", "ollama", "qwen3:8b").reasoning_effort).toBe("none");
  expect(applyReasoningLevel(base, "high", "ollama", "qwen3:8b").reasoning_effort).toBeUndefined();
  const medium = applyReasoningLevel(base, "medium", "llama-server", "qwen3.5-4b");
  expect(medium.thinking_budget_tokens).toBe(1_000);
  expect(medium.reasoning_effort).toBeUndefined();
  const off = applyReasoningLevel({ ...base, chat_template_kwargs: { keep: 1 } }, "off", "llama-server", "q");
  expect(off.thinking_budget_tokens).toBe(0);
  expect(off.chat_template_kwargs).toEqual({ keep: 1, enable_thinking: false });
});

test("the level file is read fresh and anything unreadable is Automatic", async () => {
  const root = await mkdtemp(join(tmpdir(), "lokalbot-reasoning-"));
  try {
    const file = join(root, "level.json");
    expect(readReasoningLevel(undefined)).toBe("automatic");
    expect(readReasoningLevel(file)).toBe("automatic");
    await writeFile(file, JSON.stringify({ level: "low" }));
    expect(readReasoningLevel(file)).toBe("low");
    await writeFile(file, JSON.stringify({ level: "extreme" }));
    expect(readReasoningLevel(file)).toBe("automatic");
    await writeFile(file, "not json");
    expect(readReasoningLevel(file)).toBe("automatic");
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("a rejected reasoning level is retried once without blocking the request", async () => {
  const bodies: any[] = [];
  const reply = (status: number, text: string) => new Response(text, { status });
  const replies = [reply(400, "reasoning_effort 'none' is not supported"), reply(200, "ok")];
  const fetchOnce = retryRejectedReasoning((async (_input: any, init: any) => {
    bodies.push(JSON.parse(init.body)); return replies.shift()!;
  }) as typeof fetch);
  expect((await fetchOnce("https://x/v1/chat/completions", {
    method: "POST", body: JSON.stringify({ model: "gpt-oss-120b", reasoning_effort: "none" }),
  })).status).toBe(200);
  expect(bodies.map((body) => body.reasoning_effort)).toEqual(["none", "low"]);

  bodies.length = 0;
  replies.push(reply(422, "unknown field reasoning"), reply(200, "ok"));
  await fetchOnce("https://x/v1", { method: "POST", body: JSON.stringify({ reasoning: { effort: "high" } }) });
  expect(bodies[1].reasoning).toBeUndefined();

  bodies.length = 0;
  replies.push(reply(400, "context length exceeded"));
  expect((await fetchOnce("https://x/v1", {
    method: "POST", body: JSON.stringify({ reasoning_effort: "low" }),
  })).status).toBe(400);
  expect(bodies).toHaveLength(1);
});

test("the registered provider sends the level LokalBot writes, and follows a change", async () => {
  const bodies: any[] = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      bodies.push(await request.json());
      const chunk = (delta: object, finish: string | null) =>
        `data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 0, model: "fixture",
          choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
      return new Response(chunk({ role: "assistant", content: "ok" }, null) + chunk({}, "stop") + "data: [DONE]\n\n",
        { headers: { "content-type": "text/event-stream" } });
    },
  });
  const root = await mkdtemp(join(tmpdir(), "lokalbot-reasoning-"));
  const file = join(root, "level.json");
  try {
    const baseUrl = `http://127.0.0.1:${server.port}/v1`;
    await withExtensionFixture(async ({ provider }) => {
      const model = { ...provider.models[0], provider: "lokalbot", api: provider.api,
        baseUrl, maxTokens: 128, name: "Fixture", reasoning: false };
      const ask = async () => {
        const stream = provider.streamSimple(model, {
          messages: [{ role: "user", content: "hi", timestamp: Date.now() }],
        }, { apiKey: "synthetic-token", maxRetries: 0, timeoutMs: 2_000 });
        for await (const _ of stream) {}
      };
      await ask();
      await writeFile(file, JSON.stringify({ level: "low" }));
      await ask();
      await writeFile(file, JSON.stringify({ level: "off" }));
      await ask();
    }, baseUrl, { LOKALBOT_LLM_REASONING_DIALECT: "generic", LOKALBOT_LLM_REASONING_FILE: file });
    expect(bodies.map((body) => body.reasoning_effort)).toEqual([undefined, "low", "none"]);
    expect(bodies[0].messages[0].role).not.toBe("developer");
  } finally {
    server.stop(true);
    await rm(root, { recursive: true, force: true });
  }
});
