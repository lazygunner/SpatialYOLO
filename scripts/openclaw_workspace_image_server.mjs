#!/usr/bin/env node

import fs from "fs";
import http from "http";
import path from "path";
import crypto from "crypto";
import { spawn } from "child_process";
import { fileURLToPath } from "url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const TAOBAO_STEP_TOTAL = 9;

const DEFAULTS = {
  host: process.env.WORKSPACE_IMAGE_SERVER_HOST || "0.0.0.0",
  port: Number(process.env.WORKSPACE_IMAGE_SERVER_PORT || "18888"),
  workspaceImagePath:
    process.env.OPENCLAW_IMAGE_PATH ||
    process.env.WORKSPACE_IMAGE_PATH ||
    "/Users/gunner/.openclaw/workspace/image.png",
  jobsDir: process.env.WORKSPACE_IMAGE_JOBS_DIR || "/tmp/openclaw-image-jobs",
  uploadToken:
    process.env.WORKSPACE_IMAGE_SERVER_TOKEN ||
    process.env.OPENCLAW_UPLOAD_TOKEN ||
    process.env.OPENCLAW_TOKEN ||
    "",
  gatewayBaseUrl:
    process.env.OPENCLAW_BASE_URL ||
    process.env.OPENCLAW_GATEWAY_BASE_URL ||
    "http://127.0.0.1:18789",
  gatewayToken:
    process.env.OPENCLAW_GATEWAY_TOKEN ||
    process.env.OPENCLAW_TOKEN ||
    process.env.WORKSPACE_IMAGE_SERVER_TOKEN ||
    "",
  executor: process.env.WORKSPACE_IMAGE_EXECUTOR || "taobao-image-search",
  taobaoSkillDir:
    process.env.TAOBAO_IMAGE_SEARCH_DIR ||
    path.join(SCRIPT_DIR, "taobao-image-search"),
  taobaoStatePath:
    process.env.TAOBAO_IMAGE_SEARCH_STATE ||
    path.join(
      process.env.TAOBAO_IMAGE_SEARCH_DIR || path.join(SCRIPT_DIR, "taobao-image-search"),
      "verification-artifacts",
      "taobao-storage-state.json"
    ),
  taobaoDelayMs: Number(process.env.TAOBAO_IMAGE_SEARCH_DELAY_MS || "2500"),
  taobaoHeadless: process.env.TAOBAO_IMAGE_SEARCH_HEADLESS === "1",
  model: process.env.OPENCLAW_MODEL || process.env.OPENCLAW_GATEWAY_MODEL || "openclaw:main",
  taskTimeoutMs: Number(process.env.OPENCLAW_TASK_TIMEOUT_MS || "900000"),
  maxUploadBytes: Number(process.env.WORKSPACE_IMAGE_SERVER_MAX_UPLOAD_BYTES || "15728640"),
  debug: process.env.OPENCLAW_DEBUG === "1"
};

const HEADER_DELIMITER = Buffer.from("\r\n\r\n");
const CRLF = Buffer.from("\r\n");

class HttpError extends Error {
  constructor(statusCode, message) {
    super(message);
    this.statusCode = statusCode;
  }
}

function parseArgs(argv) {
  const out = { ...DEFAULTS };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];
    if (arg === "--host" && next) {
      out.host = next;
      i += 1;
    } else if (arg === "--port" && next) {
      out.port = Number(next);
      i += 1;
    } else if (arg === "--workspace-image" && next) {
      out.workspaceImagePath = next;
      i += 1;
    } else if (arg === "--jobs-dir" && next) {
      out.jobsDir = next;
      i += 1;
    } else if (arg === "--token" && next) {
      out.uploadToken = next;
      i += 1;
    } else if (arg === "--gateway-token" && next) {
      out.gatewayToken = next;
      i += 1;
    } else if (arg === "--gateway-url" && next) {
      out.gatewayBaseUrl = next;
      i += 1;
    } else if (arg === "--executor" && next) {
      out.executor = next;
      i += 1;
    } else if (arg === "--taobao-skill-dir" && next) {
      out.taobaoSkillDir = next;
      i += 1;
    } else if (arg === "--taobao-state" && next) {
      out.taobaoStatePath = next;
      i += 1;
    } else if (arg === "--taobao-delay-ms" && next) {
      out.taobaoDelayMs = Number(next);
      i += 1;
    } else if (arg === "--taobao-headless") {
      out.taobaoHeadless = true;
    } else if (arg === "--taobao-headed") {
      out.taobaoHeadless = false;
    } else if (arg === "--model" && next) {
      out.model = next;
      i += 1;
    } else if (arg === "--task-timeout-ms" && next) {
      out.taskTimeoutMs = Number(next);
      i += 1;
    } else if (arg === "--max-upload-bytes" && next) {
      out.maxUploadBytes = Number(next);
      i += 1;
    } else if (arg === "--debug") {
      out.debug = true;
    } else if (arg === "--help") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown or incomplete argument: ${arg}`);
    }
  }
  return out;
}

function printHelp() {
  console.log(`Usage:
  WORKSPACE_IMAGE_SERVER_TOKEN=... node scripts/openclaw_workspace_image_server.mjs

Options:
  --host              HTTP listen host (default: ${DEFAULTS.host})
  --port              HTTP listen port (default: ${DEFAULTS.port})
  --workspace-image   Target workspace image path
  --jobs-dir          Task metadata directory
  --token             Upload API token
  --gateway-token     OpenClaw gateway token
  --gateway-url       OpenClaw gateway base URL
  --executor          Task executor: taobao-image-search | openclaw
  --taobao-skill-dir  Local taobao-image-search directory
  --taobao-state      Taobao storage state JSON path
  --taobao-delay-ms   Playwright delay added per step
  --taobao-headless   Run local Taobao runner in headless mode
  --taobao-headed     Run local Taobao runner in headed mode
  --model             OpenClaw model name
  --task-timeout-ms   Async task timeout
  --max-upload-bytes  Maximum multipart body size
  --debug             Print debug logs

Endpoints:
  GET  /health
  POST /upload-image
  POST /tasks/openclaw
  GET  /tasks/:id`);
}

function formatLogDetails(details) {
  if (details === undefined) return "";
  if (typeof details === "string") return details;
  return JSON.stringify(details);
}

function logLine(level, message, details) {
  const suffix = details === undefined ? "" : ` ${formatLogDetails(details)}`;
  console.error(`[${new Date().toISOString()}] [${level}] ${message}${suffix}`);
}

function debugLog(options, message, details) {
  if (options.debug) {
    logLine("DEBUG", message, details);
  }
}

function redactToken(token) {
  if (!token) return "missing";
  const trimmed = token.trim();
  if (!trimmed) return "empty";
  if (trimmed.length <= 8) return `${trimmed.slice(0, 2)}...(${trimmed.length})`;
  return `${trimmed.slice(0, 4)}...${trimmed.slice(-4)} (${trimmed.length})`;
}

function ensureDirectory(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function atomicWriteFile(targetPath, buffer) {
  ensureDirectory(path.dirname(targetPath));
  const tempPath = path.join(
    path.dirname(targetPath),
    `.${path.basename(targetPath)}.${process.pid}.${Date.now()}.${crypto.randomUUID()}.tmp`
  );
  fs.writeFileSync(tempPath, buffer);
  fs.renameSync(tempPath, targetPath);
}

function taskFilePath(options, id) {
  return path.join(options.jobsDir, `${id}.json`);
}

function readTask(options, id) {
  const filePath = taskFilePath(options, id);
  if (!fs.existsSync(filePath)) {
    return null;
  }
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeTask(options, task) {
  ensureDirectory(options.jobsDir);
  atomicWriteFile(taskFilePath(options, task.id), Buffer.from(`${JSON.stringify(task, null, 2)}\n`));
}

function updateTask(options, id, mutate) {
  const current = readTask(options, id);
  if (!current) {
    throw new Error(`task not found: ${id}`);
  }
  const nextTask = mutate(current);
  nextTask.updatedAt = new Date().toISOString();
  writeTask(options, nextTask);
  return nextTask;
}

function clearExistingTasks(options) {
  ensureDirectory(options.jobsDir);
  let removed = 0;
  for (const entry of fs.readdirSync(options.jobsDir)) {
    const filePath = path.join(options.jobsDir, entry);
    try {
      fs.rmSync(filePath, { recursive: true, force: true });
      removed += 1;
    } catch (error) {
      logLine("WARN", "failed to remove stale task", { filePath, message: error.message });
    }
  }
  logLine("INFO", "cleared previous task files", { jobsDir: options.jobsDir, removed });
}

function parseHeaders(headerText) {
  const headers = {};
  for (const line of headerText.split("\r\n")) {
    const separator = line.indexOf(":");
    if (separator === -1) continue;
    const name = line.slice(0, separator).trim().toLowerCase();
    const value = line.slice(separator + 1).trim();
    headers[name] = value;
  }
  return headers;
}

function parseContentDisposition(value) {
  const result = {};
  if (!value) return result;
  for (const segment of value.split(";")) {
    const trimmed = segment.trim();
    const separator = trimmed.indexOf("=");
    if (separator === -1) {
      result.type = trimmed.toLowerCase();
      continue;
    }
    const key = trimmed.slice(0, separator).trim().toLowerCase();
    let partValue = trimmed.slice(separator + 1).trim();
    if (partValue.startsWith("\"") && partValue.endsWith("\"")) {
      partValue = partValue.slice(1, -1);
    }
    result[key] = partValue;
  }
  return result;
}

function mimeTypeFromFilename(filename) {
  const ext = path.extname(filename || "").toLowerCase();
  switch (ext) {
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".png":
      return "image/png";
    case ".webp":
      return "image/webp";
    case ".gif":
      return "image/gif";
    case ".heic":
      return "image/heic";
    case ".heif":
      return "image/heif";
    default:
      return "application/octet-stream";
  }
}

function parseMultipartFormData(bodyBuffer, contentType) {
  const match = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType || "");
  if (!match) {
    throw new HttpError(400, "missing multipart boundary");
  }

  const boundary = match[1] || match[2];
  const boundaryMarker = Buffer.from(`--${boundary}`);
  const searchBoundary = Buffer.from(`\r\n--${boundary}`);
  const parts = [];

  let cursor = bodyBuffer.indexOf(boundaryMarker);
  if (cursor === -1) {
    throw new HttpError(400, "invalid multipart payload");
  }

  while (cursor !== -1) {
    cursor += boundaryMarker.length;
    if (bodyBuffer.slice(cursor, cursor + 2).toString("utf8") === "--") {
      break;
    }
    if (bodyBuffer.slice(cursor, cursor + 2).equals(CRLF)) {
      cursor += 2;
    }

    const headerEnd = bodyBuffer.indexOf(HEADER_DELIMITER, cursor);
    if (headerEnd === -1) {
      throw new HttpError(400, "malformed multipart headers");
    }

    const headers = parseHeaders(bodyBuffer.slice(cursor, headerEnd).toString("utf8"));
    const disposition = parseContentDisposition(headers["content-disposition"]);
    const dataStart = headerEnd + HEADER_DELIMITER.length;
    const nextBoundary = bodyBuffer.indexOf(searchBoundary, dataStart);
    if (nextBoundary === -1) {
      throw new HttpError(400, "unterminated multipart payload");
    }

    const data = bodyBuffer.slice(dataStart, nextBoundary);
    parts.push({
      headers,
      name: disposition.name || "",
      filename: disposition.filename || "",
      mimeType: headers["content-type"] || mimeTypeFromFilename(disposition.filename),
      data
    });

    cursor = nextBoundary + 2;
  }

  return parts;
}

function jsonResponse(res, statusCode, payload) {
  const text = `${JSON.stringify(payload, null, 2)}\n`;
  res.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(text)
  });
  res.end(text);
}

function textResponse(res, statusCode, text) {
  res.writeHead(statusCode, { "Content-Type": "text/plain; charset=utf-8" });
  res.end(text);
}

function sendError(res, error) {
  const statusCode = error instanceof HttpError ? error.statusCode : 500;
  jsonResponse(res, statusCode, {
    error: error.message || "internal server error"
  });
}

function requireAuth(req, token) {
  if (!token) return;
  const header = req.headers.authorization || "";
  const expected = `Bearer ${token}`;
  if (header !== expected) {
    throw new HttpError(401, "unauthorized");
  }
}

function readRequestBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;

    req.on("data", (chunk) => {
      total += chunk.length;
      if (total > maxBytes) {
        reject(new HttpError(413, `payload too large (max ${maxBytes} bytes)`));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
    req.on("aborted", () => reject(new HttpError(499, "request aborted")));
  });
}

function saveWorkspaceImage(options, filePart) {
  if (!filePart || !filePart.data?.length) {
    throw new HttpError(400, "multipart field 'file' is required");
  }

  atomicWriteFile(options.workspaceImagePath, filePart.data);
  return {
    saved: true,
    path: options.workspaceImagePath,
    bytes: filePart.data.length,
    mimeType: filePart.mimeType || mimeTypeFromFilename(filePart.filename),
    filename: filePart.filename || path.basename(options.workspaceImagePath),
    fieldName: filePart.name || "file"
  };
}

function buildDefaultPrompt(workspaceImagePath) {
  return `MEDIA:${workspaceImagePath} 使用 skill淘宝搜索并加入购物车`;
}

function extractResponseText(payload) {
  const output = Array.isArray(payload?.output) ? payload.output : [];
  const texts = [];
  for (const item of output) {
    if (!Array.isArray(item?.content)) continue;
    for (const contentItem of item.content) {
      if (typeof contentItem?.text === "string" && contentItem.text.trim()) {
        texts.push(contentItem.text.trim());
      }
    }
  }
  return texts.join("\n").trim();
}

function ensureFileExists(filePath, label) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`${label} not found: ${filePath}`);
  }
}

function safeReadJson(filePath) {
  if (!fs.existsSync(filePath)) return null;
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function summarizeTaobaoResult(result) {
  const title = result?.selectedCandidate?.title || "未识别商品";
  const detailUrl = result?.addToCart?.detailUrl || result?.selectedCandidate?.href || "";
  const signal = result?.addToCart?.signal || "";

  if (result?.success && result?.addToCart?.success) {
    const lines = [`淘宝加购成功: ${title}`];
    if (signal) lines.push(`信号: ${signal}`);
    if (detailUrl) lines.push(`详情页: ${detailUrl}`);
    return lines.join("\n");
  }

  const reason =
    result?.addToCart?.reason ||
    result?.error ||
    result?.message ||
    "淘宝脚本执行失败";
  if (isTaobaoLoginRequiredMessage(reason)) {
    return buildTaobaoLoginRecoveryMessage(reason);
  }
  const lines = [`淘宝处理失败: ${reason}`];
  if (detailUrl) lines.push(`详情页: ${detailUrl}`);
  return lines.join("\n");
}

function isTaobaoLoginRequiredMessage(value) {
  if (typeof value !== "string") return false;
  return [
    "未检测到淘宝登录状态",
    "请先登录后重试",
    "save-taobao-cookie.js",
    "登录态"
  ].some((pattern) => value.includes(pattern));
}

function buildTaobaoLoginRecoveryMessage(reason) {
  const normalizedReason = typeof reason === "string" ? reason.trim() : "";
  const guidanceLines = [
    "服务会保持运行，请先手动登录淘宝；如需保存登录态，可运行 node save-taobao-cookie.js。",
    "登录完成后，请手动重启 scripts/run_openclaw_workspace_image_server.sh。"
  ];
  if (normalizedReason && guidanceLines.every((line) => normalizedReason.includes(line))) {
    return normalizedReason;
  }
  const firstLine =
    normalizedReason
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find(Boolean) || "未检测到淘宝登录状态";
  const prefix = firstLine.startsWith("淘宝处理失败:")
    ? firstLine
    : `淘宝处理失败: ${firstLine}`;
  return [prefix, ...guidanceLines].join("\n");
}

function parseTaggedLine(text, prefix) {
  const line = text
    .split(/\r?\n/)
    .map((entry) => entry.trim())
    .find((entry) => entry.startsWith(prefix));
  if (!line) return null;
  return line.slice(prefix.length);
}

function parseTaggedPayload(line, prefix) {
  if (!line.startsWith(prefix)) return null;
  return JSON.parse(line.slice(prefix.length));
}

function updateTaskStepProgress(options, taskId, step) {
  return updateTask(options, taskId, (current) => ({
    ...current,
    stepKey: step.key || null,
    stepLabel: step.label || null,
    stepIndex: step.index || 0,
    totalSteps: step.total || 0,
    progress: typeof step.progress === "number" ? step.progress : 0,
    stepUpdatedAt: step.updatedAt || new Date().toISOString()
  }));
}

async function callOpenClaw(options, prompt) {
  if (!options.gatewayToken) {
    throw new Error("OPENCLAW_GATEWAY_TOKEN or OPENCLAW_TOKEN is required");
  }

  const response = await fetch(`${options.gatewayBaseUrl}/v1/responses`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${options.gatewayToken}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      model: options.model,
      input: [
        {
          type: "message",
          role: "user",
          content: [
            {
              type: "input_text",
              text: prompt
            }
          ]
        }
      ]
    }),
    signal: AbortSignal.timeout(options.taskTimeoutMs)
  });

  const responseText = await response.text();
  if (!response.ok) {
    throw new Error(`OpenClaw HTTP ${response.status}: ${responseText.trim() || "empty body"}`);
  }

  let payload;
  try {
    payload = JSON.parse(responseText);
  } catch {
    throw new Error("OpenClaw returned non-JSON response");
  }

  const text = extractResponseText(payload);
  if (!text) {
    throw new Error("OpenClaw returned no readable text");
  }
  return text;
}

async function runTaobaoImageSearch(options, task) {
  ensureFileExists(options.taobaoRunnerPath, "taobao runner");

  const outDir = path.join(options.jobsDir, task.id);
  fs.rmSync(outDir, { recursive: true, force: true });
  ensureDirectory(outDir);

  const args = [
    options.taobaoRunnerPath,
    "--image",
    options.workspaceImagePath,
    "--out-dir",
    outDir,
    "--state",
    options.taobaoStatePath,
    "--delay-ms",
    String(options.taobaoDelayMs),
    options.taobaoHeadless ? "--headless" : "--headed"
  ];

  logLine("INFO", "launching taobao runner", {
    taskId: task.id,
    cwd: options.taobaoSkillDir,
    statePath: options.taobaoStatePath,
    outDir,
    headless: options.taobaoHeadless,
    delayMs: options.taobaoDelayMs
  });

  const child = spawn(process.execPath, args, {
    cwd: options.taobaoSkillDir,
    env: { ...process.env }
  });

  let stdout = "";
  let stderr = "";
  let stdoutLineBuffer = "";

  child.stdout.on("data", (chunk) => {
    const text = chunk.toString("utf8");
    stdout += text;
    stdoutLineBuffer += text;

    while (true) {
      const newlineIndex = stdoutLineBuffer.indexOf("\n");
      if (newlineIndex === -1) break;
      const line = stdoutLineBuffer.slice(0, newlineIndex).trim();
      stdoutLineBuffer = stdoutLineBuffer.slice(newlineIndex + 1);
      if (!line) continue;

      try {
        const step = parseTaggedPayload(line, "STEP_STATUS=");
        if (step) {
          updateTaskStepProgress(options, task.id, step);
          logLine("INFO", "task step updated", {
            id: task.id,
            stepIndex: step.index,
            totalSteps: step.total,
            stepLabel: step.label
          });
        }
      } catch (error) {
        logLine("WARN", "failed to parse task step", {
          id: task.id,
          line,
          message: error.message
        });
      }
    }
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString("utf8");
  });

  const exitCode = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error(`taobao runner timed out after ${options.taskTimeoutMs}ms`));
    }, options.taskTimeoutMs);

    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once("exit", (code, signal) => {
      clearTimeout(timer);
      if (signal) {
        reject(new Error(`taobao runner exited by signal ${signal}`));
        return;
      }
      resolve(code ?? 1);
    });
  });

  fs.writeFileSync(path.join(outDir, "stdout.log"), stdout);
  fs.writeFileSync(path.join(outDir, "stderr.log"), stderr);

  const result =
    safeReadJson(path.join(outDir, "result.json")) ||
    (() => {
      const tagged = parseTaggedLine(stdout, "VERIFICATION_RESULT=");
      return tagged ? JSON.parse(tagged) : null;
    })();

  if (!result) {
    const failure =
      parseTaggedLine(stderr, "VERIFICATION_FAILED=") ||
      parseTaggedLine(stdout, "VERIFICATION_FAILED=") ||
      stderr.trim() ||
      stdout.trim() ||
      `taobao runner exited with code ${exitCode}`;
    throw new Error(failure);
  }

  return {
    result,
    responseText: summarizeTaobaoResult(result),
    outDir,
    exitCode,
    succeeded: Boolean(result?.success && result?.addToCart?.success)
  };
}

async function executeTask(options, task) {
  if (options.executor === "taobao-image-search") {
    return runTaobaoImageSearch(options, task);
  }
  if (options.executor === "openclaw") {
    return {
      result: null,
      responseText: await callOpenClaw(options, task.prompt),
      outDir: null,
      exitCode: 0,
      succeeded: true
    };
  }
  throw new Error(`unsupported executor: ${options.executor}`);
}

function buildTask(options, input) {
  const now = new Date().toISOString();
  return {
    id: crypto.randomUUID(),
    executor: options.executor,
    status: "queued",
    prompt: input.prompt,
    stepKey: null,
    stepLabel: "等待处理",
    stepIndex: 0,
    totalSteps: options.executor === "taobao-image-search" ? TAOBAO_STEP_TOTAL : 0,
    progress: 0,
    stepUpdatedAt: null,
    sourceImagePath: input.sourceImagePath,
    sourceMimeType: input.sourceMimeType,
    workspaceImagePath: options.workspaceImagePath,
    createdAt: now,
    updatedAt: now,
    responseText: null,
    error: null
  };
}

function queueTaskProcessing(options, inFlightTasks, taskId) {
  if (inFlightTasks.has(taskId)) {
    return;
  }

  const runner = (async () => {
    let task = updateTask(options, taskId, (current) => ({
      ...current,
      status: "processing",
      error: null,
      stepLabel: current.stepLabel || (options.executor === "taobao-image-search" ? "启动淘宝流程" : "启动任务"),
      stepIndex: current.stepIndex || 0,
      totalSteps: current.totalSteps || (options.executor === "taobao-image-search" ? TAOBAO_STEP_TOTAL : 0),
      progress: current.progress || 0
    }));
    logLine("INFO", "task processing started", {
      id: task.id,
      promptChars: task.prompt.length
    });

    try {
      const execution = await executeTask(options, task);
      if (!execution.succeeded) {
        const failure = new Error(execution.responseText || "task execution reported failure");
        failure.execution = execution;
        throw failure;
      }
      task = updateTask(options, taskId, (current) => ({
        ...current,
        status: "completed",
        responseText: execution.responseText,
        error: null,
        result: execution.result,
        artifactsDir: execution.outDir
      }));
      logLine("INFO", "task completed", {
        id: task.id,
        executor: options.executor,
        responseTextChars: execution.responseText.length
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const execution = error?.execution || null;
      const taobaoLoginRequired = isTaobaoLoginRequiredMessage(message) ||
        isTaobaoLoginRequiredMessage(execution?.responseText);
      const surfacedMessage = taobaoLoginRequired
        ? buildTaobaoLoginRecoveryMessage(message)
        : message;
      task = updateTask(options, taskId, (current) => ({
        ...current,
        status: "failed",
        error: surfacedMessage,
        result: execution?.result || current.result || null,
        artifactsDir: execution?.outDir || current.artifactsDir || null,
        responseText: taobaoLoginRequired
          ? buildTaobaoLoginRecoveryMessage(execution?.responseText || message)
          : execution?.responseText || current.responseText || null,
        stepLabel: taobaoLoginRequired ? "等待淘宝登录后手动重启服务" : current.stepLabel
      }));
      logLine(taobaoLoginRequired ? "WARN" : "ERROR", taobaoLoginRequired ? "task blocked by taobao login" : "task failed", {
        id: task.id,
        message: surfacedMessage,
        serviceKeepsRunning: taobaoLoginRequired || undefined
      });
    } finally {
      inFlightTasks.delete(taskId);
    }
  })();

  inFlightTasks.set(taskId, runner);
}

async function parseUploadRequest(req, options) {
  const contentType = req.headers["content-type"] || "";
  if (!contentType.toLowerCase().startsWith("multipart/form-data")) {
    throw new HttpError(400, "content-type must be multipart/form-data");
  }

  const bodyBuffer = await readRequestBody(req, options.maxUploadBytes);
  const parts = parseMultipartFormData(bodyBuffer, contentType);
  const filePart = parts.find((part) => part.name === "file");
  const promptPart = parts.find((part) => part.name === "prompt");

  return {
    filePart,
    prompt: promptPart ? promptPart.data.toString("utf8").trim() : ""
  };
}

async function handleUploadImage(req, res, options) {
  requireAuth(req, options.uploadToken);
  const { filePart } = await parseUploadRequest(req, options);
  const saved = saveWorkspaceImage(options, filePart);
  logLine("INFO", "workspace image saved", saved);
  jsonResponse(res, 200, saved);
}

async function handleCreateTask(req, res, options, inFlightTasks) {
  requireAuth(req, options.uploadToken);
  const { filePart, prompt } = await parseUploadRequest(req, options);
  const saved = saveWorkspaceImage(options, filePart);
  const task = buildTask(options, {
    prompt: prompt || buildDefaultPrompt(options.workspaceImagePath),
    sourceImagePath: saved.path,
    sourceMimeType: saved.mimeType
  });
  writeTask(options, task);
  logLine("INFO", "task queued", {
    id: task.id,
    promptChars: task.prompt.length,
    sourceImagePath: task.sourceImagePath
  });
  queueTaskProcessing(options, inFlightTasks, task.id);
  jsonResponse(res, 202, task);
}

async function handleGetTask(req, res, options, taskId) {
  requireAuth(req, options.uploadToken);
  const task = readTask(options, taskId);
  if (!task) {
    throw new HttpError(404, "task not found");
  }
  jsonResponse(res, 200, task);
}

function createServer(options) {
  const inFlightTasks = new Map();

  return http.createServer(async (req, res) => {
    const startedAt = Date.now();
    const requestId = crypto.randomUUID();
    const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
    logLine("INFO", "request started", {
      id: requestId,
      method: req.method,
      path: url.pathname
    });
    debugLog(options, "request headers", { id: requestId, headers: req.headers });

    try {
      if (req.method === "GET" && url.pathname === "/health") {
        jsonResponse(res, 200, {
          ok: true,
          host: options.host,
          port: options.port,
          executor: options.executor,
          workspaceImagePath: options.workspaceImagePath,
          jobsDir: options.jobsDir,
          taobaoSkillDir: options.taobaoSkillDir,
          taobaoStatePath: options.taobaoStatePath,
          taobaoStateExists: fs.existsSync(options.taobaoStatePath),
          gatewayBaseUrl: options.gatewayBaseUrl,
          model: options.model,
          uploadToken: redactToken(options.uploadToken),
          gatewayToken: redactToken(options.gatewayToken),
          now: new Date().toISOString()
        });
      } else if (req.method === "POST" && url.pathname === "/upload-image") {
        await handleUploadImage(req, res, options);
      } else if (req.method === "POST" && url.pathname === "/tasks/openclaw") {
        await handleCreateTask(req, res, options, inFlightTasks);
      } else if (req.method === "GET" && url.pathname.startsWith("/tasks/")) {
        const taskId = decodeURIComponent(url.pathname.slice("/tasks/".length));
        await handleGetTask(req, res, options, taskId);
      } else {
        throw new HttpError(404, "not found");
      }

      logLine("INFO", "request completed", {
        id: requestId,
        method: req.method,
        path: url.pathname,
        durationMs: Date.now() - startedAt
      });
    } catch (error) {
      if (!res.headersSent) {
        sendError(res, error);
      } else {
        res.destroy();
      }
      logLine("ERROR", "request failed", {
        id: requestId,
        method: req.method,
        path: url.pathname,
        durationMs: Date.now() - startedAt,
        message: error.message
      });
    }
  });
}

function validateOptions(options) {
  if (!Number.isFinite(options.port) || options.port <= 0 || options.port > 65535) {
    throw new Error(`invalid port: ${options.port}`);
  }
  if (!["taobao-image-search", "openclaw"].includes(options.executor)) {
    throw new Error(`invalid executor: ${options.executor}`);
  }
  if (!options.workspaceImagePath) {
    throw new Error("workspace image path is required");
  }
  if (!options.jobsDir) {
    throw new Error("jobs directory is required");
  }
  if (options.executor === "taobao-image-search") {
    options.taobaoRunnerPath = path.join(options.taobaoSkillDir, "verify-taobao-runner.js");
    ensureFileExists(options.taobaoSkillDir, "taobao skill directory");
    ensureFileExists(options.taobaoRunnerPath, "taobao runner");
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  validateOptions(options);
  ensureDirectory(path.dirname(options.workspaceImagePath));
  ensureDirectory(options.jobsDir);
  clearExistingTasks(options);

  logLine("INFO", "starting workspace image service", {
    host: options.host,
    port: options.port,
    executor: options.executor,
    workspaceImagePath: options.workspaceImagePath,
    jobsDir: options.jobsDir,
    taobaoSkillDir: options.taobaoSkillDir,
    taobaoStatePath: options.taobaoStatePath,
    taobaoStateExists: fs.existsSync(options.taobaoStatePath),
    taobaoHeadless: options.taobaoHeadless,
    taobaoDelayMs: options.taobaoDelayMs,
    gatewayBaseUrl: options.gatewayBaseUrl,
    model: options.model,
    uploadToken: redactToken(options.uploadToken),
    gatewayToken: redactToken(options.gatewayToken),
    taskTimeoutMs: options.taskTimeoutMs,
    maxUploadBytes: options.maxUploadBytes,
    debug: options.debug
  });

  const server = createServer(options);

  server.on("clientError", (error, socket) => {
    logLine("WARN", "client error", { message: error.message });
    socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port, options.host, () => {
      server.off("error", reject);
      resolve();
    });
  });

  logLine("INFO", "workspace image service listening", {
    url: `http://${options.host}:${options.port}`,
    health: `http://${options.host}:${options.port}/health`
  });
}

main().catch((error) => {
  logLine("ERROR", "workspace image service failed to start", {
    message: error.stack || String(error)
  });
  process.exit(1);
});
