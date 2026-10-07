// LokalBot pi extension: registers the app-configured local LLM as a
// provider and gates every tool except workspace reads behind the host UI.
//
// Runs inside pi (RPC mode) under Bun. The env contract comes from
// PiLaunchPlanner; the confirm() below surfaces in LokalBot as an
// extension_ui_request on stdout, answered over stdin.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { openAICompletionsApi } from "@earendil-works/pi-ai/compat";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { homedir } from "node:os";

// Tools whose approval card shows a dedicated preview. Any other tool is
// reviewed from its exact arguments, which must fit in full.
const PREVIEWED_TOOLS = new Set(["read", "write", "edit", "bash"]);
const REASONING_DIALECTS = ["llama-server", "openai", "openrouter", "ollama", "generic"] as const;
type ReasoningDialect = typeof REASONING_DIALECTS[number];
const REASONING_LEVELS = ["automatic", "off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
type ReasoningLevel = typeof REASONING_LEVELS[number];
/// ThinkReasoningLevel.budgetTokens, so a level means the same thinking
/// allowance in Agent Mode as in summaries.
const THINKING_BUDGETS: Record<Exclude<ReasoningLevel, "automatic">, number> = {
  off: 0, minimal: 256, low: 512, medium: 4096, high: 8192, xhigh: 16384, max: 24576,
};
const MAX_APPROVAL_TEXT = 64 * 1024;
const API_KEY = Symbol.for("lokalbot.llmApiKey");

/// The provider key stays inside this process. pi gives every shell command
/// a copy of its environment, so a command or a script it starts could
/// otherwise read the key. pi evaluates this module again for a new session,
/// so the key is kept on globalThis rather than read from the environment.
export function takeProviderAPIKey(): string {
  const store = globalThis as unknown as Record<symbol, string | undefined>;
  store[API_KEY] ??= process.env.LOKALBOT_LLM_API_KEY;
  delete process.env.LOKALBOT_LLM_API_KEY;
  // llama.cpp ignores the key; Ollama/LM Studio may want one.
  return store[API_KEY] ?? "lokalbot";
}

export default function lokalbotExtension(pi: ExtensionAPI) {
  const protectedRoots = privateRoots();
  const apiKey = takeProviderAPIKey();
  const baseUrl = process.env.LOKALBOT_LLM_BASE_URL;
  const model = process.env.LOKALBOT_LLM_MODEL;
  if (!baseUrl || !model) {
    throw new Error(
      "LOKALBOT_LLM_BASE_URL and LOKALBOT_LLM_MODEL must be set (launched outside LokalBot?)",
    );
  }
  const parsedContextWindow = Number(process.env.LOKALBOT_LLM_CTX ?? "16384");
  const contextWindow = Number.isSafeInteger(parsedContextWindow)
    && parsedContextWindow >= 1024
    && parsedContextWindow <= 1_048_576
    ? parsedContextWindow
    : 16384;
  const endpoint = new URL(baseUrl);
  const loopback = endpoint.hostname === "localhost"
    || endpoint.hostname.endsWith(".localhost")
    || isIPv4Loopback(endpoint.hostname)
    || endpoint.hostname === "[::1]"
    || endpoint.hostname === "::1";
  if (!loopback && endpoint.protocol !== "https:") {
    throw new Error("Remote LokalBot LLM endpoints must use HTTPS");
  }
  const dialect = reasoningDialect(process.env.LOKALBOT_LLM_REASONING_DIALECT);
  const reasoningFile = process.env.LOKALBOT_LLM_REASONING_FILE;
  const completions = openAICompletionsApi();
  const inferenceFetch = retryRejectedReasoning(inferenceFetchForOrigin(endpoint));

  pi.registerProvider("lokalbot", {
    baseUrl,
    api: "openai-completions",
    // Pi has its own HTTP client: the host's URLSession redirect policy does
    // not cover it. Inject only this provider's supported transport hook.
    // LokalBot writes the Agent reasoning level (already limited to what the
    // model accepts) to a file it may change mid-task; read it per request.
    streamSimple: (selectedModel, context, options) => completions.streamSimple(
      selectedModel, context, {
        ...options,
        fetch: inferenceFetch,
        onPayload: async (payload, payloadModel) => {
          const upstream = (await options?.onPayload?.(payload, payloadModel)) ?? payload;
          return applyReasoningLevel(
            upstream as Record<string, unknown>, readReasoningLevel(reasoningFile), dialect, model);
        },
      },
    ),
    apiKey,
    models: [
      {
        id: model,
        contextWindow,
        // Required: pi's registerProvider path does NOT default `input`
        // (unlike its models.json path), and pi-ai's openai-completions
        // dereferences model.input unguarded — omitting this crashes every
        // completion with "undefined is not an object".
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
  });

  pi.on("tool_call", async (event, ctx) => {
    // The exact shell command must fit in the approval payload. Never ask for
    // approval of a prefix and then execute the unchanged, longer request.
    if (event.toolName === "bash") {
      const command = (event.input as Record<string, unknown> | undefined)?.command;
      if (typeof command !== "string" || command.length > MAX_APPROVAL_TEXT) {
        return { block: true, reason: "The shell command cannot be reviewed in full. Keep each command within 65,536 characters; this request was not run." };
      }
    }
    if (!PREVIEWED_TOOLS.has(event.toolName)) {
      const args = argumentsText(event.input);
      if (args === undefined || args.length > MAX_APPROVAL_TEXT) {
        return { block: true, reason: `The ${event.toolName} request cannot be reviewed in full. Keep its arguments within 65,536 characters; this request was not run.` };
      }
    }
    if (!requiresApproval(event.toolName, event.input, protectedRoots)) return undefined;

    // Machine-parseable payload: the host renders exact commands and file
    // changes, rather than relying on a model-authored summary.
    const approved = await ctx.ui.confirm(
      "lokalbot_tool_approval",
      JSON.stringify(approvalPayload(event.toolName, event.input)),
    );
    if (!approved) {
      return {
        block: true,
        reason:
          "The user denied this request in LokalBot. Nothing changed. Do not retry it or suggest changing approval settings unless the user explicitly asks.",
      };
    }
    return undefined;
  });
}

/// A launched Agent task has approval for one origin. Reject redirects before
/// the HTTP client can replay context or credentials, including same-origin
/// redirects: configure the final inference endpoint instead.
export function inferenceFetchForOrigin(endpoint: URL, implementation = globalThis.fetch) {
  if (!["http:", "https:"].includes(endpoint.protocol) || endpoint.username || endpoint.password) {
    throw new Error("Agent inference requires an HTTP(S) endpoint without URL credentials");
  }
  const approvedOrigin = endpoint.origin;
  return async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.origin !== approvedOrigin || url.username || url.password) {
      throw new Error("Agent inference request left the task's approved origin");
    }
    return implementation(input, { ...init, redirect: "error" });
  };
}

export function reasoningDialect(value: string | undefined): ReasoningDialect {
  if (value === undefined || value === "") return "generic";
  if (!(REASONING_DIALECTS as readonly string[]).includes(value)) {
    throw new Error("Invalid reasoning dialect in the LokalBot launch configuration");
  }
  return value as ReasoningDialect;
}

/// `{"level": "<ThinkReasoningLevel>"}`. Missing or unreadable: Automatic,
/// which leaves every request exactly as pi built it.
export function readReasoningLevel(path: string | undefined): ReasoningLevel {
  if (!path) return "automatic";
  try {
    const level = (JSON.parse(readFileSync(path, "utf8")) as { level?: unknown }).level;
    return (REASONING_LEVELS as readonly unknown[]).includes(level) ? level as ReasoningLevel : "automatic";
  } catch {
    return "automatic";
  }
}

/// Mirrors OpenAICompatibleEngine.applyGenerationOptions for a level the host
/// already limited to the model's (ReasoningSupport). Automatic leaves every
/// request exactly as pi built it.
export function applyReasoningLevel(
  payload: Record<string, unknown>,
  level: ReasoningLevel,
  dialect: ReasoningDialect,
  model: string,
): Record<string, unknown> {
  if (level === "automatic") return payload;
  const effort = level === "off" ? "none" : level;
  switch (dialect) {
    case "llama-server": {
      const ceiling = payload.max_tokens ?? payload.max_completion_tokens;
      const budget = typeof ceiling === "number"
        ? Math.min(THINKING_BUDGETS[level], Math.floor(ceiling / 2))
        : THINKING_BUDGETS[level];
      const shaped: Record<string, unknown> = { ...payload, thinking_budget_tokens: budget };
      if (budget === 0) {
        // A zero budget alone still opens Qwen's thinking turn.
        const kwargs = (payload.chat_template_kwargs ?? {}) as Record<string, unknown>;
        shaped.chat_template_kwargs = { ...kwargs, enable_thinking: false };
      }
      return shaped;
    }
    case "openai":
      return /^(o1|o3|o4|gpt-5)/i.test(model) ? { ...payload, reasoning_effort: effort } : payload;
    case "openrouter":
      return { ...payload, reasoning: { effort } };
    case "ollama":
      // Only gpt-oss takes a graded level; other thinking models can only be
      // switched off, which the host limits the level to.
      return level === "off" || /gpt-oss/i.test(model) ? { ...payload, reasoning_effort: effort } : payload;
    case "generic":
      return { ...payload, reasoning_effort: effort };
  }
}

/// A chosen level can be one the selected model does not accept. When the
/// server names reasoning in a 400/422, retry once: `none` becomes `low` for
/// models that always reason; any other level falls back to the server's
/// default. Mirrors OpenAICompatibleEngine.shouldRetryRejectedReasoningLevel.
export function retryRejectedReasoning(implementation: typeof globalThis.fetch) {
  return async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const response = await implementation(input, init);
    if ((response.status !== 400 && response.status !== 422) || typeof init?.body !== "string") {
      return response;
    }
    let body: Record<string, unknown>;
    try {
      body = JSON.parse(init.body) as Record<string, unknown>;
    } catch {
      return response;
    }
    const nested = body.reasoning as Record<string, unknown> | undefined;
    const effort = body.reasoning_effort ?? nested?.effort;
    if (typeof effort !== "string") return response;
    if (!/reasoning/i.test(await response.clone().text())) return response;
    const retried = { ...body };
    if (effort === "none") {
      if (body.reasoning_effort !== undefined) retried.reasoning_effort = "low";
      else retried.reasoning = { ...nested, effort: "low" };
    } else {
      delete retried.reasoning_effort;
      delete retried.reasoning;
    }
    return implementation(input, { ...init, body: JSON.stringify(retried) });
  };
}

function isIPv4Loopback(hostname: string): boolean {
  const octets = hostname.split(".");
  return octets.length === 4
    && octets.every((octet) => /^\d{1,3}$/.test(octet) && Number(octet) <= 255)
    && Number(octets[0]) === 127;
}

function requestedPath(value: unknown): string | undefined {
  const path = String(value ?? "");
  if (!path) return undefined;
  if (path === "~") return homedir();
  if (path.startsWith("~/")) return resolve(homedir(), path.slice(2));
  return resolve(process.cwd(), path);
}

function canonicalPath(value: unknown): string | undefined {
  const requested = requestedPath(value);
  if (!requested) return undefined;
  try {
    return realpathSync(requested);
  } catch {
    // Canonicalize the nearest existing ancestor so a path through a symlink
    // cannot escape merely because its final component does not exist yet.
    let ancestor = requested;
    const suffix: string[] = [];
    while (!existsSync(ancestor)) {
      const parent = dirname(ancestor);
      if (parent === ancestor) return undefined;
      suffix.unshift(ancestor.slice(parent.length).replace(/^\//, ""));
      ancestor = parent;
    }
    try {
      return resolve(realpathSync(ancestor), ...suffix);
    } catch {
      return undefined;
    }
  }
}

function isInside(path: string, root: string): boolean {
  const child = relative(root, path);
  return child === "" || (child !== ".." && !child.startsWith("../") && !isAbsolute(child));
}

function privateRoots(): string[] {
  const value: unknown = JSON.parse(process.env.LOKALBOT_AGENT_PRIVATE_ROOTS ?? "[]");
  if (!Array.isArray(value) || value.some((root) => typeof root !== "string" || !isAbsolute(root))) {
    throw new Error("Invalid private-library roots in the LokalBot launch configuration");
  }
  return value.map((root) => {
    const path = canonicalPath(root);
    if (!path) throw new Error("Could not resolve a private-library root");
    return path;
  });
}

/// Allowlist: a read inside the selected workspace and outside the private
/// library is the only call that runs without asking. Every other tool asks,
/// including MCP tools, codemode, and tools that later Pi releases add.
function requiresApproval(toolName: string, input: unknown, protectedRoots: string[]): boolean {
  if (toolName !== "read") return true;
  const args = (input ?? {}) as Record<string, unknown>;
  const path = canonicalPath(args.path ?? args.file_path);
  // Missing/unresolvable paths are never silently treated as in-workspace.
  // Choosing Home or another ancestor as a workspace does not silently make
  // the private library, server credentials, or Agent history normal files.
  return !path || protectedRoots.some((root) => isInside(path, root))
    || !isInside(path, realpathSync(process.cwd()));
}

/// The exact arguments a tool without a dedicated preview will run with.
function argumentsText(input: unknown): string | undefined {
  try {
    return JSON.stringify(input ?? {}, null, 2);
  } catch {
    return undefined;
  }
}

function boundedText(value: unknown): { text: string; truncated: boolean } {
  const text = String(value ?? "");
  if (text.length <= MAX_APPROVAL_TEXT) return { text, truncated: false };
  return { text: text.slice(0, MAX_APPROVAL_TEXT), truncated: true };
}

function approvalPayload(toolName: string, input: unknown): Record<string, unknown> {
  const args = (input ?? {}) as Record<string, unknown>;
  const payload: Record<string, unknown> = {
    tool: toolName,
    workspace: process.cwd(),
    truncated: false,
  };

  switch (toolName) {
    case "bash": {
      const bounded = boundedText(args.command ?? args.cmd ?? JSON.stringify(args));
      payload.command = bounded.text;
      payload.truncated = bounded.truncated;
      break;
    }
    case "write": {
      payload.path = canonicalPath(args.path ?? args.file_path) ?? requestedPath(args.path ?? args.file_path);
      const bounded = boundedText(args.content);
      payload.content = bounded.text;
      payload.truncated = bounded.truncated;
      break;
    }
    case "edit": {
      let wasTruncated = false;
      const edits = Array.isArray(args.edits)
        ? args.edits.map((value) => {
            const edit = (value ?? {}) as Record<string, unknown>;
            const oldText = boundedText(edit.oldText ?? edit.old_text);
            const newText = boundedText(edit.newText ?? edit.new_text);
            wasTruncated ||= oldText.truncated || newText.truncated;
            return {
              oldText: oldText.text,
              newText: newText.text,
            };
          })
        : [];
      payload.path = canonicalPath(args.path ?? args.file_path) ?? requestedPath(args.path ?? args.file_path);
      payload.edits = edits.slice(0, 100);
      payload.truncated = wasTruncated || edits.length > 100;
      break;
    }
    case "read": {
      payload.path = canonicalPath(args.path ?? args.file_path) ?? requestedPath(args.path ?? args.file_path);
      break;
    }
    default:
      // Checked against MAX_APPROVAL_TEXT before approval is requested.
      payload.arguments = argumentsText(input);
  }
  return payload;
}
