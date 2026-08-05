const isNativeHost = Boolean(window.webkit?.messageHandlers?.mobileOSHost);

if (isNativeHost) {
  document.body.classList.add("native-host");
}

const bootLines = [
  "mobileos: arm64viz prototype",
  "mobileos: kernel stage online",
  "mobileos: framebuffer compositor ready",
  "mobileos: touch input ready",
  "mobileos: app runtime=javascript",
  "mobileos: shell ready"
];

const appStage = document.getElementById("appStage");
const bootLog = document.getElementById("bootLog");
const clock = document.getElementById("clock");
const hostBoot = document.getElementById("hostBoot");
const hostDiagnostics = document.getElementById("hostDiagnostics");

let hostReport = null;
let activeAppID = null;
let terminalLines = [
  { kind: "system", text: "MobileOS POSIX shell. Type `help`." }
];
let lastNativePTYTranscript = null;
let nativePromptOverride = null;

const packageIndex = {
  "mobileos-runtime": {
    version: "0.1.0",
    summary: "JavaScript MobileOS shell, compositor policy, and app runtime",
    essential: true,
    installed: true
  },
  "mobileos-mail": {
    version: "0.1.0",
    summary: "Mail prototype app",
    app: "mail",
    installed: true
  },
  "mobileos-browser": {
    version: "0.1.0",
    summary: "Local browser prototype app",
    app: "browser",
    installed: true
  },
  "mobileos-files": {
    version: "0.1.0",
    summary: "Files prototype app",
    app: "files",
    installed: true
  },
  "mobileos-settings": {
    version: "0.1.0",
    summary: "Settings prototype app",
    app: "settings",
    installed: true
  },
  "mobileos-terminal": {
    version: "0.1.0",
    summary: "Terminal and POSIX-shaped JavaScript shell",
    app: "console",
    installed: true
  },
  "mobileos-camera": {
    version: "0.1.0",
    summary: "Virtual camera prototype app",
    app: "camera",
    installed: true
  },
  "mobileos-notes": {
    version: "0.1.0",
    summary: "Notes prototype app",
    app: "notes",
    installed: true
  },
  "mobileos-store": {
    version: "0.1.0",
    summary: "Local package catalog app",
    app: "store",
    installed: true
  },
  "unix-tools": {
    version: "0.1.0",
    summary: "Core Unix/POSIX-shaped commands for the JavaScript terminal",
    installed: true
  },
  "mobileos-devtools": {
    version: "0.0.1",
    summary: "Prototype SDK headers, package metadata tools, and debug helpers",
    installed: false
  },
  "netstack-preview": {
    version: "0.0.1",
    summary: "Stub network service APIs for future device work",
    installed: false
  }
};

let installedPackageIDs = new Set(
  Object.entries(packageIndex)
    .filter(([, metadata]) => metadata.installed)
    .map(([id]) => id)
);

const shellState = {
  cwd: "/home/mobile",
  env: {
    USER: "mobile",
    LOGNAME: "mobile",
    HOME: "/home/mobile",
    SHELL: "/bin/msh",
    PATH: "/bin:/usr/bin:/apps",
    TERM: "xterm-256color",
    OSTYPE: "mobileos",
    PWD: "/home/mobile"
  },
  lastStatus: 0
};

const virtualFS = new Map();

const appRegistry = {
  mail: {
    identifier: "dev.arm64viz.mail",
    title: "Mail",
    color: "#2563eb",
    icon: envelopeIcon(),
    render: () => `
      <div class="list">
        ${[
          ["Platform", "Framebuffer compositor is ready for the app shell."],
          ["Runtime", "JavaScript app registry mounted successfully."],
          ["Storage", "Virtual block driver is staged for the next milestone."]
        ].map(listItem).join("")}
      </div>
    `
  },
  browser: {
    identifier: "dev.arm64viz.browser",
    title: "Browser",
    color: "#0f766e",
    icon: compassIcon(),
    render: () => `
      <input class="search-bar" value="arm64viz://start" aria-label="Address">
      <section class="browser-page">
        <strong>Local Start</strong>
        <p>Network is sandboxed. The first browser target is a local page renderer backed by the JavaScript app runtime.</p>
      </section>
    `
  },
  files: {
    identifier: "dev.arm64viz.files",
    title: "Files",
    color: "#a16207",
    icon: folderIcon(),
    render: () => `
      <div class="list">
        ${[
          ["System", "kernel.log"],
          ["Apps", "mail.app.js"],
          ["Apps", "browser.app.js"],
          ["Config", "policy.json"]
        ].map(([location, name]) => listItem([name, location])).join("")}
      </div>
    `
  },
  settings: {
    identifier: "dev.arm64viz.settings",
    title: "Settings",
    color: "#475569",
    icon: settingsIcon(),
    render: () => `
      ${settingRow("Airplane Mode", "Network devices stay isolated", false)}
      ${settingRow("Developer HUD", "Show runtime and frame metrics", true)}
      ${settingRow("Touch Debug", "Trace pointer events", false)}
    `
  },
  camera: {
    identifier: "dev.arm64viz.camera",
    title: "Camera",
    color: "#4f46e5",
    icon: cameraIcon(),
    render: () => `
      <section class="camera-preview">
        <strong>Camera</strong>
        <span>Virtual camera device pending.</span>
      </section>
    `
  },
  notes: {
    identifier: "dev.arm64viz.notes",
    title: "Notes",
    color: "#ca8a04",
    icon: noteIcon(),
    render: () => `
      <textarea class="notes-editor" aria-label="Notes">MobileOS JS app runtime notes:

- apps are JavaScript modules
- compositor state is host-bridged
- device services are capability scoped</textarea>
    `
  },
  console: {
    identifier: "dev.arm64viz.console",
    title: "Terminal",
    color: "#111827",
    icon: terminalIcon(),
    render: () => terminalMarkup()
  },
  store: {
    identifier: "dev.arm64viz.store",
    title: "Store",
    color: "#7c3aed",
    icon: packageIcon(),
    render: () => `
      <div class="list">
        ${Object.entries(packageIndex).map(([id, metadata]) => listItem([
          `${id} ${metadata.version}`,
          `${isPackageInstalled(id) ? "Installed" : "Available"} · ${metadata.summary}`
        ])).join("")}
      </div>
    `
  }
};

initializeVirtualFS();

window.MobileOSHostBridge = {
  receiveHostReport(report) {
    hostReport = report;
    syncTerminalFromHostReport(report);
    renderHostBootLog(report);

    if (activeAppID === "console") {
      openApp("console", { silent: true });
    }
  }
};

hostBoot?.addEventListener("click", () => postHostMessage("boot"));
hostDiagnostics?.addEventListener("click", () => postHostMessage("diagnostics"));

document.querySelectorAll("[data-app]").forEach(button => {
  const id = button.dataset.app;
  const app = appRegistry[id];
  if (!app) return;
  button.innerHTML = `<span class="dock-icon" style="background:${app.color}">${app.icon}</span>`;
  button.addEventListener("click", () => openApp(id));
});

function renderHome() {
  activeAppID = null;
  appStage.innerHTML = `
    <div class="home-grid">
      ${Object.entries(appRegistry).map(([id, app]) => `
        <button class="app-icon" data-home-app="${id}">
          <span class="icon-tile" style="background:${app.color}">${app.icon}</span>
          <span>${app.title}</span>
        </button>
      `).join("")}
    </div>
  `;

  document.querySelectorAll("[data-home-app]").forEach(button => {
    button.addEventListener("click", () => openApp(button.dataset.homeApp));
  });
}

function openApp(id, options = {}) {
  const app = appRegistry[id];
  if (!app) return;

  activeAppID = id;
  appStage.innerHTML = `
    <section class="app-window">
      <header class="app-header">
        <button class="back-button" type="button" aria-label="Home">Home</button>
        <h2>${app.title}</h2>
        <button class="command-button" type="button">Run</button>
      </header>
      <div class="app-body">${app.render()}</div>
    </section>
  `;

  appStage.querySelector(".back-button").addEventListener("click", renderHome);
  appStage.querySelector(".command-button").addEventListener("click", () => {
    appendBootLine(`mobileos-js: launched ${app.identifier}`);
  });
  appStage.querySelectorAll(".switch").forEach(button => {
    button.addEventListener("click", () => {
      button.setAttribute("aria-pressed", button.getAttribute("aria-pressed") !== "true");
    });
  });
  if (id === "console") {
    setupTerminal();
  }

  if (!options.silent) {
    appendBootLine(`mobileos-js: focused ${app.identifier}`);
  }
}

function listItem([title, detail]) {
  return `
    <article class="list-item">
      <strong>${title}</strong>
      <span>${detail}</span>
    </article>
  `;
}

function settingRow(label, description, enabled) {
  return `
    <div class="setting-row">
      <div>
        <strong>${label}</strong>
        <span>${description}</span>
      </div>
      <button class="switch" type="button" aria-label="${label}" aria-pressed="${enabled}"></button>
    </div>
  `;
}

function terminalMarkup() {
  return `
    <section class="terminal-window" aria-label="Terminal">
      <div class="terminal-output" id="terminalOutput"></div>
      <form class="terminal-form" id="terminalForm">
        <span class="terminal-prompt" id="shellPrompt">${escapeHTML(shellPromptText())}</span>
        <input
          class="terminal-input"
          id="terminalInput"
          type="text"
          aria-label="Command"
          autocomplete="off"
          autocapitalize="none"
          spellcheck="false"
        >
      </form>
    </section>
  `;
}

function setupTerminal() {
  const output = document.getElementById("terminalOutput");
  const form = document.getElementById("terminalForm");
  const input = document.getElementById("terminalInput");
  const prompt = document.getElementById("shellPrompt");
  if (!output || !form || !input) return;

  renderTerminalOutput(output);
  renderShellPrompt(prompt);
  form.addEventListener("submit", event => {
    event.preventDefault();
    const command = input.value;
    input.value = "";
    runTerminalCommand(command);
    renderTerminalOutput(output);
    renderShellPrompt(prompt);
    input.focus();
  });

  window.setTimeout(() => input.focus({ preventScroll: true }), 0);
}

function renderShellPrompt(prompt) {
  if (prompt) prompt.textContent = shellPromptText();
}

function shellPromptText() {
  if (usesNativeUnixPTY() && nativePromptOverride) {
    return nativePromptOverride.trimEnd();
  }

  const home = shellState.env.HOME;
  const displayCwd = shellState.cwd === home
    ? "~"
    : shellState.cwd.startsWith(`${home}/`)
      ? `~${shellState.cwd.slice(home.length)}`
      : shellState.cwd;
  return `${shellState.env.USER}@mobileos:${displayCwd}$`;
}

function renderTerminalOutput(output) {
  output.innerHTML = terminalLines.map(line => {
    if (line.kind === "command") {
      return `<div class="terminal-line"><span class="terminal-prompt">${escapeHTML(line.prompt ?? "$")}</span> ${escapeHTML(line.text)}</div>`;
    }
    return `<div class="terminal-line ${line.kind}">${escapeHTML(line.text)}</div>`;
  }).join("");
  output.scrollTop = output.scrollHeight;
}

function runTerminalCommand(rawCommand) {
  const raw = rawCommand.trim();
  terminalLines.push({ kind: "command", text: rawCommand, prompt: shellPromptText() });
  if (usesNativeUnixPTY()) {
    postHostMessage("terminalInput", { input: rawCommand });
    return;
  }
  if (!raw) return;

  const result = executeShellLine(raw);
  shellState.lastStatus = result.status;
  if (result.clear) {
    terminalLines = [];
    return;
  }

  if (result.output) {
    terminalLines.push({ kind: result.status === 0 ? "output" : "error", text: result.output });
  }
}

function executeShellLine(line) {
  const parsed = splitCommandList(line);
  if (parsed.error) return shellResult(parsed.error, 2);

  const output = [];
  let lastStatus = 0;
  let pendingOperator = null;

  for (const item of parsed.items) {
    if (item.type === "operator") {
      pendingOperator = item.operator;
      continue;
    }

    const shouldRun = pendingOperator === "&&"
      ? lastStatus === 0
      : pendingOperator === "||"
        ? lastStatus !== 0
        : true;
    pendingOperator = null;

    if (!shouldRun) continue;

    const result = executePipeline(item.text);
    if (result.clear) return result;
    if (result.output) output.push(result.output);
    lastStatus = result.status;
    shellState.lastStatus = lastStatus;
  }

  return shellResult(output.join("\n"), lastStatus);
}

function splitCommandList(line) {
  const items = [];
  let current = "";
  let quote = null;
  let escaped = false;

  const pushCommand = () => {
    const text = current.trim();
    if (text) items.push({ type: "command", text });
    current = "";
  };

  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    const next = line[index + 1];

    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }

    if (char === "\\" && quote !== "'") {
      current += char;
      escaped = true;
      continue;
    }

    if (quote) {
      current += char;
      if (char === quote) quote = null;
      continue;
    }

    if (char === "'" || char === "\"") {
      quote = char;
      current += char;
      continue;
    }

    if (char === ";" || (char === "&" && next === "&") || (char === "|" && next === "|")) {
      const operator = char === ";" ? ";" : `${char}${next}`;
      if (!current.trim() && (items.length === 0 || items[items.length - 1].type === "operator")) {
        return { error: `msh: syntax error near unexpected token '${operator}'` };
      }
      pushCommand();
      items.push({ type: "operator", operator });
      if (operator !== ";") index += 1;
      continue;
    }

    current += char;
  }

  if (escaped) return { error: "msh: trailing escape" };
  if (quote) return { error: "msh: unmatched quote" };
  pushCommand();

  if (items[items.length - 1]?.type === "operator") items.pop();
  return { items };
}

function executePipeline(commandText) {
  const split = splitPipeline(commandText);
  if (split.error) return shellResult(split.error, 2);

  let stdin = "";
  let output = "";
  let status = 0;

  for (const segment of split.segments) {
    const parsed = parseSimpleCommand(segment);
    if (parsed.error) return shellResult(parsed.error, 2);

    let commandInput = stdin;
    if (parsed.stdinPath) {
      const inputFile = readVirtualFile(parsed.stdinPath);
      if (!inputFile.ok) return shellResult(inputFile.error, 1);
      commandInput = inputFile.content;
    }

    const result = executeSimpleCommand(parsed.argv, commandInput, parsed.assignments);
    if (result.clear) return result;

    output = result.output ?? "";
    status = result.status ?? 0;

    for (const redirect of parsed.stdoutRedirects) {
      const writeResult = writeVirtualFile(redirect.path, output, { append: redirect.append });
      if (!writeResult.ok) return shellResult(writeResult.error, 1);
      output = "";
    }

    stdin = output;
  }

  return shellResult(output, status);
}

function splitPipeline(commandText) {
  const segments = [];
  let current = "";
  let quote = null;
  let escaped = false;

  const pushSegment = () => {
    const text = current.trim();
    if (!text) return false;
    segments.push(text);
    current = "";
    return true;
  };

  for (let index = 0; index < commandText.length; index += 1) {
    const char = commandText[index];
    const next = commandText[index + 1];

    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }

    if (char === "\\" && quote !== "'") {
      current += char;
      escaped = true;
      continue;
    }

    if (quote) {
      current += char;
      if (char === quote) quote = null;
      continue;
    }

    if (char === "'" || char === "\"") {
      quote = char;
      current += char;
      continue;
    }

    if (char === "|" && next !== "|") {
      if (!pushSegment()) return { error: "msh: syntax error near unexpected token '|'" };
      continue;
    }

    current += char;
  }

  if (escaped) return { error: "msh: trailing escape" };
  if (quote) return { error: "msh: unmatched quote" };
  if (!pushSegment()) return { error: "msh: empty command" };
  return { segments };
}

function parseSimpleCommand(segment) {
  const tokenized = tokenizeShell(segment);
  if (tokenized.error) return { error: tokenized.error };

  const argv = [];
  const assignments = {};
  const stdoutRedirects = [];
  let stdinPath = null;
  let acceptsAssignments = true;

  for (let index = 0; index < tokenized.tokens.length; index += 1) {
    const token = tokenized.tokens[index];

    if (token === ">" || token === ">>" || token === "<") {
      const target = tokenized.tokens[index + 1];
      if (!target) return { error: `msh: syntax error near unexpected token '${token}'` };
      const normalized = normalizeVirtualPath(target);
      if (token === "<") {
        stdinPath = normalized;
      } else {
        stdoutRedirects.push({ path: normalized, append: token === ">>" });
      }
      index += 1;
      continue;
    }

    if (acceptsAssignments && isAssignmentToken(token)) {
      const equalsIndex = token.indexOf("=");
      assignments[token.slice(0, equalsIndex)] = token.slice(equalsIndex + 1);
      continue;
    }

    acceptsAssignments = false;
    argv.push(token);
  }

  return { argv, assignments, stdoutRedirects, stdinPath };
}

function tokenizeShell(input) {
  const tokens = [];
  let current = "";
  let quote = null;
  let escaped = false;
  let quotedWord = false;

  const pushToken = () => {
    if (!current.length && !quotedWord) return;
    tokens.push(expandTilde(current));
    current = "";
    quotedWord = false;
  };

  for (let index = 0; index < input.length; index += 1) {
    const char = input[index];

    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }

    if (char === "\\" && quote !== "'") {
      escaped = true;
      continue;
    }

    if (quote) {
      if (char === quote) {
        quote = null;
        quotedWord = true;
        continue;
      }
      if (quote === "\"" && char === "$") {
        const expanded = expandShellVariable(input, index);
        current += expanded.value;
        index = expanded.index;
        continue;
      }
      current += char;
      continue;
    }

    if (/\s/.test(char)) {
      pushToken();
      continue;
    }

    if (char === "'" || char === "\"") {
      quote = char;
      quotedWord = true;
      continue;
    }

    if (char === "$") {
      const expanded = expandShellVariable(input, index);
      current += expanded.value;
      index = expanded.index;
      continue;
    }

    if (char === ">" || char === "<") {
      pushToken();
      if (char === ">" && input[index + 1] === ">") {
        tokens.push(">>");
        index += 1;
      } else {
        tokens.push(char);
      }
      continue;
    }

    current += char;
  }

  if (escaped) return { error: "msh: trailing escape" };
  if (quote) return { error: "msh: unmatched quote" };
  pushToken();
  return { tokens };
}

function expandShellVariable(input, dollarIndex) {
  const next = input[dollarIndex + 1];
  if (next === "?") return { value: String(shellState.lastStatus), index: dollarIndex + 1 };
  if (next === "$") return { value: "1", index: dollarIndex + 1 };

  if (next === "{") {
    const closeIndex = input.indexOf("}", dollarIndex + 2);
    if (closeIndex === -1) return { value: "$", index: dollarIndex };
    const name = input.slice(dollarIndex + 2, closeIndex);
    return { value: shellState.env[name] ?? "", index: closeIndex };
  }

  let index = dollarIndex + 1;
  let name = "";
  while (index < input.length && /[A-Za-z0-9_]/.test(input[index])) {
    name += input[index];
    index += 1;
  }

  if (!name) return { value: "$", index: dollarIndex };
  return { value: shellState.env[name] ?? "", index: index - 1 };
}

function expandTilde(value) {
  if (value === "~") return shellState.env.HOME;
  if (value.startsWith("~/")) return `${shellState.env.HOME}${value.slice(1)}`;
  return value;
}

function isAssignmentToken(token) {
  return /^[A-Za-z_][A-Za-z0-9_]*=.*/.test(token);
}

function executeSimpleCommand(argv, stdin, assignments) {
  const assignmentEntries = Object.entries(assignments);
  if (!argv.length) {
    assignmentEntries.forEach(([key, value]) => {
      shellState.env[key] = value;
    });
    syncShellPWD();
    return shellResult("", 0);
  }

  if (!assignmentEntries.length) return executeShellCommand(argv, stdin);

  const previousEnv = { ...shellState.env };
  assignmentEntries.forEach(([key, value]) => {
    shellState.env[key] = value;
  });

  const result = executeShellCommand(argv, stdin);
  shellState.env = previousEnv;
  syncShellPWD();
  return result;
}

function executeShellCommand(argv, stdin) {
  const rawCommand = argv[0];
  const command = resolveShellCommand(rawCommand);
  const args = argv.slice(1);

  if (rawCommand.includes("/")) {
    const path = normalizeVirtualPath(rawCommand);
    const executablePath = resolveBuiltinPath(command);
    if (!virtualPathExists(path)) return shellResult(`${rawCommand}: No such file or directory`, 127);
    if (executablePath !== path) return shellResult(`${rawCommand}: Permission denied`, 126);
  }

  switch (command) {
  case "help":
    return shellResult(shellHelp(), 0);
  case "msh":
  case "sh":
    return shellResult("msh: interactive subshell already attached to the GUI terminal", 0);
  case "clear":
    return { output: "", status: 0, clear: true };
  case "uname":
    return shellResult(args.includes("-a") ? "MobileOS mobileos 0.1 arm64-js JavaScript/POSIX" : "MobileOS", 0);
  case "date":
    return shellResult(new Date().toString(), 0);
  case "whoami":
    return shellResult(shellState.env.USER, 0);
  case "pwd":
    return shellResult(shellState.cwd, 0);
  case "cd":
    return changeDirectory(args);
  case "ls":
    return listCommand(args);
  case "cat":
    return catCommand(args, stdin);
  case "echo":
    return echoCommand(args);
  case "printf":
    return printfCommand(args);
  case "touch":
    return touchCommand(args);
  case "mkdir":
    return mkdirCommand(args);
  case "rm":
    return rmCommand(args);
  case "rmdir":
    return rmdirCommand(args);
  case "cp":
    return cpCommand(args);
  case "mv":
    return mvCommand(args);
  case "grep":
    return grepCommand(args, stdin);
  case "wc":
    return wcCommand(args, stdin);
  case "head":
    return headTailCommand(args, stdin, "head");
  case "tail":
    return headTailCommand(args, stdin, "tail");
  case "env":
    return envCommand(args, stdin);
  case "export":
    return exportCommand(args);
  case "unset":
    return unsetCommand(args);
  case "set":
    return shellResult(formatEnvironment({ includeShellState: true }), 0);
  case "which":
    return whichCommand(args);
  case "command":
    return commandCommand(args);
  case "true":
    return shellResult("", 0);
  case "false":
    return shellResult("", 1);
  case "test":
    return shellResult("", testCommand(args) ? 0 : 1);
  case "[":
    return bracketTestCommand(args);
  case "ps":
    return shellResult(formatProcesses(), 0);
  case "apps":
    return shellResult(formatApps(), 0);
  case "surfaces":
    return shellResult(formatSurfaces(), 0);
  case "bootlog":
    return shellResult((hostReport?.bootLog?.length ? hostReport.bootLog : bootLines).join("\n"), 0);
  case "pkg":
    return packageShellResult(executePackageCommand(args, "pkg"));
  case "apt":
    return packageShellResult(executePackageCommand(args, "apt"));
  case "open":
    return openShellResult(args);
  case "reboot":
    postHostMessage("boot");
    return shellResult(isNativeHost ? "requested host VM reboot" : "host bridge unavailable in browser preview", 0);
  case "diag":
  case "diagnostics":
    postHostMessage("diagnostics");
    return shellResult(isNativeHost ? "opening native diagnostics" : "host bridge unavailable in browser preview", 0);
  case "exit":
  case "logout":
    return shellResult("msh: terminal session is owned by the GUI; use Home to close the app", 0);
  default:
    return shellResult(`${rawCommand}: command not found`, 127);
  }
}

function shellHelp() {
  return [
    "MobileOS msh - POSIX-shaped JavaScript shell",
    "grammar: quotes, $VAR, $?, ;, &&, ||, |, <, >, >>",
    "builtins:",
    "  cd pwd ls cat echo printf touch mkdir rm rmdir cp mv",
    "  grep wc head tail env export unset set which command",
    "  true false test [ ps apps surfaces bootlog open clear",
    "  pkg apt uname date whoami reboot diagnostics"
  ].join("\n");
}

function shellResult(output, status) {
  return { output, status };
}

function resolveShellCommand(command) {
  const basename = command.split("/").pop();
  return basename.toLowerCase();
}

function changeDirectory(args) {
  let target = args[0] ?? shellState.env.HOME;
  let printTarget = false;
  if (target === "-") {
    target = shellState.env.OLDPWD ?? shellState.env.HOME;
    printTarget = true;
  }

  const path = normalizeVirtualPath(target);
  const entry = getVirtualEntry(path);
  if (!entry) return shellResult(`cd: ${args[0] ?? target}: No such file or directory`, 1);
  if (entry.type !== "dir") return shellResult(`cd: ${args[0] ?? target}: Not a directory`, 1);

  shellState.env.OLDPWD = shellState.cwd;
  shellState.cwd = path;
  syncShellPWD();
  return shellResult(printTarget ? path : "", 0);
}

function listCommand(args) {
  const options = { all: false, long: false };
  const paths = [];

  for (const arg of args) {
    if (arg.startsWith("-") && arg !== "-") {
      if (arg.includes("a")) options.all = true;
      if (arg.includes("l")) options.long = true;
      continue;
    }
    paths.push(arg);
  }

  const targets = paths.length ? paths : ["."];
  const output = [];
  let status = 0;

  targets.forEach((target, index) => {
    const result = listVirtualPath(target, options);
    if (!result.ok) {
      output.push(result.error);
      status = 1;
      return;
    }
    if (targets.length > 1) {
      if (index > 0) output.push("");
      output.push(`${target}:`);
    }
    output.push(result.output);
  });

  return shellResult(output.join("\n"), status);
}

function catCommand(args, stdin) {
  if (!args.length) return shellResult(stdin, 0);

  const output = [];
  let status = 0;
  for (const arg of args) {
    const result = readVirtualFile(normalizeVirtualPath(arg));
    if (!result.ok) {
      output.push(result.error);
      status = 1;
      continue;
    }
    output.push(result.content);
  }
  return shellResult(output.join("\n"), status);
}

function echoCommand(args) {
  const noNewline = args[0] === "-n";
  const body = (noNewline ? args.slice(1) : args).join(" ");
  return shellResult(body, 0);
}

function printfCommand(args) {
  if (!args.length) return shellResult("printf: missing format", 1);
  let argIndex = 1;
  const rendered = args[0]
    .replaceAll("\\n", "\n")
    .replaceAll("\\t", "\t")
    .replace(/%s/g, () => args[argIndex++] ?? "")
    .replace(/%d/g, () => String(Number(args[argIndex++] ?? 0)));
  return shellResult(rendered, 0);
}

function touchCommand(args) {
  if (!args.length) return shellResult("touch: missing file operand", 1);

  const output = [];
  let status = 0;
  for (const arg of args) {
    const path = normalizeVirtualPath(arg);
    const entry = getVirtualEntry(path);
    if (entry?.type === "dir") {
      output.push(`touch: ${arg}: Is a directory`);
      status = 1;
      continue;
    }
    if (!entry) {
      const result = writeVirtualFile(path, "");
      if (!result.ok) {
        output.push(result.error);
        status = 1;
      }
    }
  }
  return shellResult(output.join("\n"), status);
}

function mkdirCommand(args) {
  const recursive = args.includes("-p");
  const targets = args.filter(arg => arg !== "-p");
  if (!targets.length) return shellResult("mkdir: missing operand", 1);

  const output = [];
  let status = 0;
  for (const target of targets) {
    const result = createVirtualDirectory(normalizeVirtualPath(target), { recursive });
    if (!result.ok) {
      output.push(result.error);
      status = 1;
    }
  }
  return shellResult(output.join("\n"), status);
}

function rmCommand(args) {
  const recursive = args.some(arg => arg.includes("r") && arg.startsWith("-"));
  const force = args.some(arg => arg.includes("f") && arg.startsWith("-"));
  const targets = args.filter(arg => !arg.startsWith("-"));
  if (!targets.length) return shellResult("rm: missing operand", 1);

  const output = [];
  let status = 0;
  for (const target of targets) {
    const result = removeVirtualPath(normalizeVirtualPath(target), { recursive, force });
    if (!result.ok) {
      output.push(result.error);
      status = 1;
    }
  }
  return shellResult(output.join("\n"), status);
}

function rmdirCommand(args) {
  if (!args.length) return shellResult("rmdir: missing operand", 1);

  const output = [];
  let status = 0;
  for (const target of args) {
    const result = removeVirtualPath(normalizeVirtualPath(target), { directoryOnly: true });
    if (!result.ok) {
      output.push(result.error);
      status = 1;
    }
  }
  return shellResult(output.join("\n"), status);
}

function cpCommand(args) {
  if (args.length < 2) return shellResult("cp: missing file operand", 1);

  const sourcePath = normalizeVirtualPath(args[0]);
  let targetPath = normalizeVirtualPath(args[1]);
  const source = readVirtualFile(sourcePath);
  if (!source.ok) return shellResult(source.error, 1);

  const targetEntry = getVirtualEntry(targetPath);
  if (targetEntry?.type === "dir") targetPath = joinVirtualPath(targetPath, basename(sourcePath));
  const write = writeVirtualFile(targetPath, source.content);
  return shellResult(write.ok ? "" : write.error, write.ok ? 0 : 1);
}

function mvCommand(args) {
  if (args.length < 2) return shellResult("mv: missing file operand", 1);

  const sourcePath = normalizeVirtualPath(args[0]);
  let targetPath = normalizeVirtualPath(args[1]);
  const source = getVirtualEntry(sourcePath);
  if (!source) return shellResult(`mv: ${args[0]}: No such file or directory`, 1);

  const targetEntry = getVirtualEntry(targetPath);
  if (targetEntry?.type === "dir") targetPath = joinVirtualPath(targetPath, basename(sourcePath));
  const result = moveVirtualPath(sourcePath, targetPath);
  return shellResult(result.ok ? "" : result.error, result.ok ? 0 : 1);
}

function grepCommand(args, stdin) {
  const ignoreCase = args.includes("-i");
  const lineNumbers = args.includes("-n");
  const operands = args.filter(arg => arg !== "-i" && arg !== "-n");
  const pattern = operands[0];
  const files = operands.slice(1);
  if (!pattern) return shellResult("grep: missing pattern", 2);

  const matcher = new RegExp(escapeRegExp(pattern), ignoreCase ? "i" : "");
  const output = [];
  let status = 1;

  const scan = (label, content, showLabel) => {
    content.split("\n").forEach((line, index) => {
      if (!matcher.test(line)) return;
      const prefix = [
        showLabel ? `${label}:` : "",
        lineNumbers ? `${index + 1}:` : ""
      ].join("");
      output.push(`${prefix}${line}`);
      status = 0;
    });
  };

  if (!files.length) {
    scan("", stdin, false);
    return shellResult(output.join("\n"), status);
  }

  for (const file of files) {
    const result = readVirtualFile(normalizeVirtualPath(file));
    if (!result.ok) {
      output.push(result.error);
      status = 2;
      continue;
    }
    scan(file, result.content, files.length > 1);
  }

  return shellResult(output.join("\n"), status);
}

function wcCommand(args, stdin) {
  const flags = args.filter(arg => arg.startsWith("-"));
  const files = args.filter(arg => !arg.startsWith("-"));
  const wantsLines = !flags.length || flags.some(flag => flag.includes("l"));
  const wantsWords = !flags.length || flags.some(flag => flag.includes("w"));
  const wantsBytes = !flags.length || flags.some(flag => flag.includes("c"));
  const rows = [];
  let status = 0;

  const format = (content, label = "") => {
    const counts = [];
    if (wantsLines) counts.push(String(content.length ? content.split("\n").length : 0).padStart(7));
    if (wantsWords) counts.push(String(content.trim() ? content.trim().split(/\s+/).length : 0).padStart(7));
    if (wantsBytes) counts.push(String(content.length).padStart(7));
    if (label) counts.push(label);
    return counts.join(" ");
  };

  if (!files.length) return shellResult(format(stdin), 0);

  for (const file of files) {
    const result = readVirtualFile(normalizeVirtualPath(file));
    if (!result.ok) {
      rows.push(result.error);
      status = 1;
      continue;
    }
    rows.push(format(result.content, file));
  }
  return shellResult(rows.join("\n"), status);
}

function headTailCommand(args, stdin, mode) {
  let count = 10;
  const files = [];
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === "-n") {
      count = Math.max(0, Number(args[index + 1] ?? 10));
      index += 1;
      continue;
    }
    if (/^-\d+$/.test(args[index])) {
      count = Math.max(0, Number(args[index].slice(1)));
      continue;
    }
    files.push(args[index]);
  }

  const select = content => {
    const lines = content.split("\n");
    return (mode === "head" ? lines.slice(0, count) : lines.slice(-count)).join("\n");
  };

  if (!files.length) return shellResult(select(stdin), 0);

  const output = [];
  let status = 0;
  for (const file of files) {
    const result = readVirtualFile(normalizeVirtualPath(file));
    if (!result.ok) {
      output.push(result.error);
      status = 1;
      continue;
    }
    output.push(select(result.content));
  }
  return shellResult(output.join("\n"), status);
}

function envCommand(args, stdin) {
  if (!args.length) return shellResult(formatEnvironment(), 0);

  const assignments = {};
  const command = [];
  let parsingAssignments = true;
  for (const arg of args) {
    if (parsingAssignments && isAssignmentToken(arg)) {
      const equalsIndex = arg.indexOf("=");
      assignments[arg.slice(0, equalsIndex)] = arg.slice(equalsIndex + 1);
      continue;
    }
    parsingAssignments = false;
    command.push(arg);
  }

  if (!command.length) {
    return shellResult(formatEnvironment({ overlay: assignments }), 0);
  }
  return executeSimpleCommand(command, stdin, assignments);
}

function exportCommand(args) {
  if (!args.length) {
    return shellResult(Object.entries(shellState.env)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, value]) => `export ${key}="${value.replaceAll("\"", "\\\"")}"`)
      .join("\n"), 0);
  }

  for (const arg of args) {
    if (isAssignmentToken(arg)) {
      const equalsIndex = arg.indexOf("=");
      shellState.env[arg.slice(0, equalsIndex)] = arg.slice(equalsIndex + 1);
    } else if (!(arg in shellState.env)) {
      shellState.env[arg] = "";
    }
  }
  syncShellPWD();
  return shellResult("", 0);
}

function unsetCommand(args) {
  args.forEach(arg => {
    if (arg !== "PWD" && arg !== "HOME") delete shellState.env[arg];
  });
  syncShellPWD();
  return shellResult("", 0);
}

function whichCommand(args) {
  if (!args.length) return shellResult("which: missing command", 1);

  const rows = [];
  let status = 0;
  for (const arg of args) {
    const resolved = resolveBuiltinPath(arg);
    if (resolved) {
      rows.push(resolved);
    } else {
      status = 1;
    }
  }
  return shellResult(rows.join("\n"), status);
}

function commandCommand(args) {
  if (args[0] === "-v") return whichCommand(args.slice(1));
  if (!args.length) return shellResult("", 0);
  return executeShellCommand(args, "");
}

function testCommand(args) {
  if (!args.length) return false;
  if (args.length === 1) return Boolean(args[0]);

  if (args.length === 2) {
    const path = normalizeVirtualPath(args[1]);
    switch (args[0]) {
    case "-e":
      return virtualPathExists(path);
    case "-f":
      return getVirtualEntry(path)?.type === "file";
    case "-d":
      return getVirtualEntry(path)?.type === "dir";
    case "-n":
      return args[1].length > 0;
    case "-z":
      return args[1].length === 0;
    default:
      return false;
    }
  }

  if (args.length === 3) {
    const [left, op, right] = args;
    switch (op) {
    case "=":
    case "==":
      return left === right;
    case "!=":
      return left !== right;
    case "-eq":
      return Number(left) === Number(right);
    case "-ne":
      return Number(left) !== Number(right);
    case "-gt":
      return Number(left) > Number(right);
    case "-ge":
      return Number(left) >= Number(right);
    case "-lt":
      return Number(left) < Number(right);
    case "-le":
      return Number(left) <= Number(right);
    default:
      return false;
    }
  }

  return false;
}

function bracketTestCommand(args) {
  if (args[args.length - 1] !== "]") return shellResult("[: missing ']'", 2);
  return shellResult("", testCommand(args.slice(0, -1)) ? 0 : 1);
}

function packageShellResult(output) {
  const failed = /(^|\n)(E:|.*: missing |.*: unknown |.*: Unable to locate)/.test(output);
  return shellResult(output, failed ? 1 : 0);
}

function openShellResult(args) {
  const output = openAppFromTerminal(args[0]);
  return shellResult(output, output.includes("missing") || output.includes("not found") ? 1 : 0);
}

function syncTerminalFromHostReport(report) {
  const pty = primaryPTYSession(report);
  if (!pty) {
    return;
  }
  if (pty.transcript === lastNativePTYTranscript) {
    return;
  }

  lastNativePTYTranscript = pty.transcript;
  const transcript = splitNativeTranscript(pty.transcript ?? "");
  nativePromptOverride = transcript.prompt ?? `mobile@mobileos:${shellState.cwd}$ `;
  terminalLines = [
    { kind: "system", text: `Kernel Unix PTY ${pty.devicePath} attached to pid ${pty.foregroundPID}.` }
  ];
  const output = transcript.output.trimEnd();
  if (output) {
    terminalLines.push({ kind: "output", text: output });
  }
}

function splitNativeTranscript(transcript) {
  const match = transcript.match(/(mobile@mobileos:[^\n]*\$ )$/);
  if (!match) {
    return { output: transcript, prompt: null };
  }
  return {
    output: transcript.slice(0, transcript.length - match[1].length),
    prompt: match[1]
  };
}

function usesNativeUnixPTY() {
  return Boolean(isNativeHost && primaryPTYSession(hostReport));
}

function primaryPTYSession(report) {
  const unix = report?.unix;
  if (!unix?.ptySessions?.length) return null;
  return unix.ptySessions.find(pty => pty.id === unix.primaryPTYID) ?? unix.ptySessions[0];
}

function initializeVirtualFS() {
  [
    "/",
    "/apps",
    "/bin",
    "/dev",
    "/dev/pts",
    "/etc",
    "/home",
    "/home/mobile",
    "/proc",
    "/system",
    "/tmp",
    "/usr",
    "/usr/bin",
    "/var",
    "/var/lib",
    "/var/lib/mobileos-pkg",
    "/var/log",
    "/var/tmp"
  ].forEach(path => {
    virtualFS.set(path, { type: "dir" });
  });

  writeVirtualFile("/etc/os-release", [
    "NAME=MobileOS",
    "PRETTY_NAME=\"MobileOS JavaScript Prototype\"",
    "ID=mobileos",
    "VERSION_ID=0.1"
  ].join("\n"), { system: true });

  writeVirtualFile("/etc/profile", [
    "export PATH=/bin:/usr/bin:/apps",
    "export SHELL=/bin/msh",
    "export HOME=/home/mobile"
  ].join("\n"), { system: true });

  writeVirtualFile(
    "/home/mobile/notes.txt",
    "JavaScript owns the OS shell and app layer. Native host owns VM bridge and diagnostics.",
    { system: true }
  );

  writeVirtualFile("/dev/null", "", { system: true });
  writeVirtualFile("/var/log/boot.log", bootLines.join("\n"), { system: true });

  const commandNames = [
    "[", "msh", "sh", "cat", "cd", "cp", "date", "echo", "env", "false", "grep",
    "head", "ls", "mkdir", "mv", "printf", "pwd", "rm", "rmdir", "tail",
    "test", "touch", "true", "uname", "wc", "which"
  ];
  commandNames.forEach(command => {
    writeVirtualFile(`/bin/${command}`, `# builtin ${command}\n`, { system: true });
  });
  ["apt", "pkg"].forEach(command => {
    writeVirtualFile(`/usr/bin/${command}`, `# MobileOS package frontend ${command}\n`, { system: true });
  });

  Object.entries(appRegistry).forEach(([id, app]) => {
    writeVirtualFile(`/apps/${id}.app.js`, [
      `// ${app.identifier}`,
      `export const title = ${JSON.stringify(app.title)};`,
      "export default function launch() { return true; }"
    ].join("\n"), { system: true });
  });
}

function listVirtualPath(path, options = {}) {
  const normalized = normalizeVirtualPath(path);
  const entry = getVirtualEntry(normalized);
  if (!entry) return { ok: false, error: `ls: ${path}: No such file or directory` };

  if (entry.type === "file") return { ok: true, output: basename(normalized) };

  const names = listDirectoryNames(normalized, options);
  if (options.long) {
    const rows = names.map(name => {
      const child = getVirtualEntry(joinVirtualPath(normalized, name));
      const mode = child?.type === "dir" ? "drwxr-xr-x" : "-rw-r--r--";
      const size = child?.type === "file" ? String(readVirtualFile(joinVirtualPath(normalized, name)).content.length) : "0";
      return `${mode} 1 mobile mobile ${size.padStart(5)} ${name}`;
    });
    return { ok: true, output: rows.join("\n") };
  }

  return { ok: true, output: names.join("  ") };
}

function catVirtualPath(path) {
  if (!path) return "cat: missing operand";
  const result = readVirtualFile(normalizeVirtualPath(path));
  return result.ok ? result.content : result.error;
}

function readVirtualFile(path) {
  const dynamic = readDynamicVirtualFile(path);
  if (dynamic !== null) return { ok: true, content: dynamic };

  const entry = virtualFS.get(path);
  if (!entry) return { ok: false, error: `cat: ${path}: No such file or directory` };
  if (entry.type !== "file") return { ok: false, error: `cat: ${path}: Is a directory` };
  return { ok: true, content: entry.content };
}

function readDynamicVirtualFile(path) {
  switch (path) {
  case "/proc/bootlog":
    return (hostReport?.bootLog?.length ? hostReport.bootLog : bootLines).join("\n");
  case "/proc/processes":
    return formatProcesses();
  case "/proc/apps":
    return Object.values(appRegistry).map(app => app.identifier).join("\n");
  case "/proc/surfaces":
    return formatSurfaces();
  case "/proc/syscalls":
    return formatUnixSyscalls();
  case "/proc/tty":
    return formatUnixTTY();
  case "/proc/unix":
    return formatUnixReport();
  case "/var/lib/mobileos-pkg/status":
    return listPackages(["--installed"]);
  case "/var/lib/mobileos-pkg/available":
    return listPackages([]);
  default:
    if (path.startsWith("/dev/pts/")) {
      const id = Number(path.slice("/dev/pts/".length));
      const pty = hostReport?.unix?.ptySessions?.find(session => session.id === id);
      return pty ? pty.transcript : null;
    }
    return null;
  }
}

function writeVirtualFile(path, content, options = {}) {
  if (path === "/dev/null" && !options.system) return { ok: true };
  if (path.startsWith("/proc/")) return { ok: false, error: `${path}: Read-only file system` };
  if (dynamicVirtualPaths().includes(path)) return { ok: false, error: `${path}: Read-only file system` };

  const parent = dirname(path);
  const parentEntry = getVirtualEntry(parent);
  if (!parentEntry) return { ok: false, error: `${path}: No such directory` };
  if (parentEntry.type !== "dir") return { ok: false, error: `${parent}: Not a directory` };

  const existing = getVirtualEntry(path);
  if (existing?.type === "dir") return { ok: false, error: `${path}: Is a directory` };
  const previous = options.append && existing?.type === "file" ? existing.content : "";
  virtualFS.set(path, { type: "file", content: `${previous}${content}`, system: Boolean(options.system) });
  return { ok: true };
}

function createVirtualDirectory(path, options = {}) {
  if (getVirtualEntry(path)) return { ok: false, error: `mkdir: ${path}: File exists` };
  if (path.startsWith("/proc/")) return { ok: false, error: `mkdir: ${path}: Read-only file system` };

  const parts = path.split("/").filter(Boolean);
  let current = "/";
  for (const part of parts) {
    current = joinVirtualPath(current, part);
    const entry = getVirtualEntry(current);
    if (entry) {
      if (entry.type !== "dir") return { ok: false, error: `mkdir: ${current}: Not a directory` };
      continue;
    }

    if (!options.recursive && current !== path) {
      return { ok: false, error: `mkdir: ${path}: No such file or directory` };
    }
    virtualFS.set(current, { type: "dir" });
  }
  return { ok: true };
}

function removeVirtualPath(path, options = {}) {
  const entry = getVirtualEntry(path);
  if (!entry) {
    return options.force ? { ok: true } : { ok: false, error: `rm: ${path}: No such file or directory` };
  }
  if (entry.dynamic || path.startsWith("/proc/")) return { ok: false, error: `rm: ${path}: Read-only file system` };
  if (path === "/" || path === shellState.env.HOME) return { ok: false, error: `rm: ${path}: Operation not permitted` };
  if (options.directoryOnly && entry.type !== "dir") return { ok: false, error: `rmdir: ${path}: Not a directory` };

  if (entry.type === "dir") {
    const children = listDirectoryNames(path, { all: true });
    if (children.length && !options.recursive) {
      return { ok: false, error: `${options.directoryOnly ? "rmdir" : "rm"}: ${path}: Directory not empty` };
    }
    [...virtualFS.keys()]
      .filter(candidate => candidate === path || candidate.startsWith(`${path}/`))
      .forEach(candidate => virtualFS.delete(candidate));
    return { ok: true };
  }

  if (options.directoryOnly) return { ok: false, error: `rmdir: ${path}: Not a directory` };
  virtualFS.delete(path);
  return { ok: true };
}

function moveVirtualPath(sourcePath, targetPath) {
  const source = getVirtualEntry(sourcePath);
  if (!source) return { ok: false, error: `mv: ${sourcePath}: No such file or directory` };
  if (source.dynamic || sourcePath.startsWith("/proc/")) return { ok: false, error: `mv: ${sourcePath}: Read-only file system` };

  const parent = getVirtualEntry(dirname(targetPath));
  if (!parent || parent.type !== "dir") return { ok: false, error: `mv: ${targetPath}: No such directory` };

  if (source.type === "file") {
    const read = readVirtualFile(sourcePath);
    if (!read.ok) return { ok: false, error: read.error };
    const write = writeVirtualFile(targetPath, read.content);
    if (!write.ok) return write;
    virtualFS.delete(sourcePath);
    return { ok: true };
  }

  virtualFS.set(targetPath, { type: "dir" });
  [...virtualFS.entries()]
    .filter(([candidate]) => candidate.startsWith(`${sourcePath}/`))
    .forEach(([candidate, entry]) => {
      virtualFS.set(`${targetPath}${candidate.slice(sourcePath.length)}`, entry);
      virtualFS.delete(candidate);
    });
  virtualFS.delete(sourcePath);
  return { ok: true };
}

function getVirtualEntry(path) {
  if (virtualFS.has(path)) return virtualFS.get(path);
  if (dynamicVirtualPaths().includes(path)) return { type: "file", dynamic: true };
  return null;
}

function virtualPathExists(path) {
  return Boolean(getVirtualEntry(path));
}

function listDirectoryNames(path, options = {}) {
  const names = new Set();
  const childPaths = [...virtualFS.keys(), ...dynamicVirtualPaths()];
  for (const childPath of childPaths) {
    if (childPath === path) continue;
    if (dirname(childPath) === path) {
      const name = basename(childPath);
      if (options.all || !name.startsWith(".")) names.add(name);
    }
  }
  return [...names].sort((left, right) => left.localeCompare(right));
}

function dynamicVirtualPaths() {
  const ptyPaths = hostReport?.unix?.ptySessions?.map(pty => `/dev/pts/${pty.id}`) ?? [];
  return [
    "/proc/apps",
    "/proc/bootlog",
    "/proc/processes",
    "/proc/syscalls",
    "/proc/surfaces",
    "/proc/tty",
    "/proc/unix",
    "/var/lib/mobileos-pkg/available",
    "/var/lib/mobileos-pkg/status",
    ...ptyPaths
  ];
}

function normalizeVirtualPath(path) {
  let candidate = expandTilde(String(path || "."));
  if (!candidate.startsWith("/")) candidate = joinVirtualPath(shellState.cwd, candidate);

  const parts = [];
  candidate.split("/").forEach(part => {
    if (!part || part === ".") return;
    if (part === "..") {
      parts.pop();
      return;
    }
    parts.push(part);
  });

  return `/${parts.join("/")}`.replace(/\/+$/, "") || "/";
}

function joinVirtualPath(left, right) {
  if (left === "/") return `/${right}`.replace(/\/+/g, "/");
  return `${left}/${right}`.replace(/\/+/g, "/");
}

function dirname(path) {
  if (path === "/") return "/";
  const parts = path.split("/").filter(Boolean);
  parts.pop();
  return parts.length ? `/${parts.join("/")}` : "/";
}

function basename(path) {
  if (path === "/") return "/";
  return path.split("/").filter(Boolean).pop() ?? "/";
}

function syncShellPWD() {
  shellState.env.PWD = shellState.cwd;
}

function formatEnvironment(options = {}) {
  const env = { ...shellState.env, ...(options.overlay ?? {}) };
  const rows = Object.entries(env)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value]) => `${key}=${value}`);
  if (options.includeShellState) rows.push(`?=${shellState.lastStatus}`);
  return rows.join("\n");
}

function resolveBuiltinPath(command) {
  const name = resolveShellCommand(command);
  const builtinNames = new Set([
    "apt", "apps", "bootlog", "cat", "cd", "clear", "command", "cp", "date", "diag",
    "[", "diagnostics", "echo", "env", "export", "false", "grep", "head", "help", "ls",
    "mkdir", "mv", "open", "pkg", "printf", "ps", "pwd", "reboot", "rm", "rmdir",
    "set", "sh", "msh", "surfaces", "tail", "test", "touch", "true", "uname",
    "unset", "wc", "which"
  ]);
  if (!builtinNames.has(name)) return null;
  return name === "apt" || name === "pkg" ? `/usr/bin/${name}` : `/bin/${name}`;
}

function formatApps() {
  return Object.entries(appRegistry)
    .map(([id, app]) => `${id.padEnd(10)} ${app.identifier}`)
    .join("\n");
}

function formatUnixReport() {
  const unix = hostReport?.unix;
  if (!unix) return "MobileOS Unix environment is not attached.";
  return [
    `primary_pty=${unix.primaryPTYID ?? "-"}`,
    `primary_shell_pid=${unix.primaryShellPID ?? "-"}`,
    `mounts=${unix.mountedPaths?.length ?? 0}`,
    `processes=${unix.processes?.length ?? 0}`,
    `syscalls=${unix.supportedSyscalls?.length ?? 0}`
  ].join("\n");
}

function formatUnixSyscalls() {
  const syscalls = hostReport?.unix?.supportedSyscalls;
  return syscalls?.length ? syscalls.join("\n") : "open\nread\nwrite\nclose\nchdir\ngetcwd\nfork\nexecve\nwait4";
}

function formatUnixTTY() {
  const sessions = hostReport?.unix?.ptySessions;
  if (!sessions?.length) return "no PTY sessions";
  return sessions
    .map(session => `${session.devicePath} pid=${session.foregroundPID} ${session.rows}x${session.columns}`)
    .join("\n");
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function formatProcesses() {
  const processes = hostReport?.processes;
  if (!processes?.length) {
    return "PID  STATE    COMMAND\n1    running  js-shell";
  }
  return [
    "PID  STATE    COMMAND",
    ...processes.map(process => `${String(process.pid).padEnd(4)} ${String(process.state).padEnd(8)} ${process.name}`)
  ].join("\n");
}

function formatSurfaces() {
  const surfaces = hostReport?.surfaces;
  if (!surfaces?.length) return "no compositor surfaces";
  return surfaces
    .map(surface => `${surface.id}: ${surface.title} pid=${surface.ownerPID} ${surface.frame.width}x${surface.frame.height}+${surface.frame.x}+${surface.frame.y}`)
    .join("\n");
}

function openAppFromTerminal(id) {
  if (!id) return "open: missing app id";
  const normalized = id.toLowerCase().replace(/\.app\.js$/, "");
  const entry = Object.entries(appRegistry).find(([key, app]) => key === normalized || app.identifier.endsWith(`.${normalized}`));
  if (!entry) return `open: ${id}: app not found`;
  window.setTimeout(() => openApp(entry[0]), 0);
  return `opening ${entry[1].title}`;
}

function executePackageCommand(args, frontend) {
  const command = args[0]?.toLowerCase();
  const rest = args.slice(1);
  if (!command || command === "help") {
    return [
      `${frontend} commands:`,
      `  ${frontend} update              refresh local package index`,
      `  ${frontend} list                list packages`,
      `  ${frontend} list --installed    list installed packages`,
      `  ${frontend} search <term>       search packages`,
      `  ${frontend} show <package>      show package metadata`,
      `  ${frontend} install <package>   install package from local index`,
      `  ${frontend} remove <package>    remove non-essential package`,
      `  ${frontend} upgrade             check for upgrades`,
      `  ${frontend} policy              show repository policy`
    ].join("\n");
  }

  switch (command) {
  case "update":
    return [
      "Reading package lists... Done",
      "Repository: mobileos://local",
      `${Object.keys(packageIndex).length} packages indexed`,
      "Network repositories are disabled in this prototype."
    ].join("\n");
  case "list":
    return listPackages(rest);
  case "search":
    return searchPackages(rest.join(" "));
  case "show":
    return showPackage(rest[0]);
  case "install":
    return installPackages(rest);
  case "remove":
  case "purge":
    return removePackages(rest);
  case "upgrade":
    return "Calculating upgrade... Done\n0 upgraded, 0 newly installed, 0 to remove.";
  case "policy":
    return [
      "Package policy:",
      "  source: mobileos://local",
      "  network: disabled",
      "  scripts: disabled",
      "  signatures: planned",
      "  apt: compatibility shim over MobileOS pkg"
    ].join("\n");
  case "version":
  case "--version":
    return "mobileos-pkg 0.1.0 (apt-compatible shim)";
  default:
    return `${frontend}: unknown command '${command}'`;
  }
}

function listPackages(args) {
  const installedOnly = args.includes("--installed");
  const availableOnly = args.includes("--available");
  const rows = Object.entries(packageIndex)
    .filter(([id]) => {
      if (installedOnly) return isPackageInstalled(id);
      if (availableOnly) return !isPackageInstalled(id);
      return true;
    })
    .map(([id, metadata]) => packageListLine(id, metadata));

  return rows.length ? rows.join("\n") : "No packages matched.";
}

function searchPackages(term) {
  const query = term.trim().toLowerCase();
  if (!query) return "search: missing search term";
  const rows = Object.entries(packageIndex)
    .filter(([id, metadata]) => `${id} ${metadata.summary}`.toLowerCase().includes(query))
    .map(([id, metadata]) => `${id} - ${metadata.summary}`);
  return rows.length ? rows.join("\n") : `No packages found matching '${term}'.`;
}

function showPackage(name) {
  const id = resolvePackageID(name);
  if (!id) return "show: missing package name";
  const metadata = packageIndex[id];
  if (!metadata) return `E: Unable to locate package ${name}`;
  return [
    `Package: ${id}`,
    `Version: ${metadata.version}`,
    `Status: ${isPackageInstalled(id) ? "install ok installed" : "not-installed"}`,
    `Essential: ${metadata.essential ? "yes" : "no"}`,
    `App: ${metadata.app ?? "-"}`,
    `Description: ${metadata.summary}`
  ].join("\n");
}

function installPackages(names) {
  if (!names.length) return "install: missing package name";
  const output = [];
  for (const name of names) {
    const id = resolvePackageID(name);
    if (!id || !packageIndex[id]) {
      output.push(`E: Unable to locate package ${name}`);
      continue;
    }
    if (isPackageInstalled(id)) {
      output.push(`${id} is already the newest version (${packageIndex[id].version}).`);
      continue;
    }
    installedPackageIDs.add(id);
    output.push(`Selecting previously unselected package ${id}.`);
    output.push(`Setting up ${id} (${packageIndex[id].version}) ...`);
    if (packageIndex[id].app) {
      output.push(`Registered app target ${packageIndex[id].app}.`);
    }
  }
  return output.join("\n");
}

function removePackages(names) {
  if (!names.length) return "remove: missing package name";
  const output = [];
  for (const name of names) {
    const id = resolvePackageID(name);
    const metadata = id ? packageIndex[id] : null;
    if (!id || !metadata) {
      output.push(`E: Unable to locate package ${name}`);
      continue;
    }
    if (metadata.essential) {
      output.push(`E: Refusing to remove essential package ${id}.`);
      continue;
    }
    if (!isPackageInstalled(id)) {
      output.push(`Package ${id} is not installed.`);
      continue;
    }
    installedPackageIDs.delete(id);
    output.push(`Removing ${id} (${metadata.version}) ...`);
  }
  return output.join("\n");
}

function resolvePackageID(name) {
  if (!name) return null;
  const normalized = name.toLowerCase();
  if (packageIndex[normalized]) return normalized;
  const prefixed = `mobileos-${normalized}`;
  if (packageIndex[prefixed]) return prefixed;
  return normalized;
}

function packageListLine(id, metadata) {
  const status = isPackageInstalled(id) ? "installed" : "available";
  return `${id}/${status} ${metadata.version} arm64-js - ${metadata.summary}`;
}

function isPackageInstalled(id) {
  return installedPackageIDs.has(id);
}

function startBootLog() {
  bootLog.innerHTML = "";
  bootLines.forEach((line, index) => {
    window.setTimeout(() => appendBootLine(line), 120 * index);
  });
}

function renderHostBootLog(report) {
  if (!report?.bootLog?.length) return;
  bootLog.innerHTML = "";
  [
    ...report.bootLog,
    report.framebufferChecksum ? `host: framebuffer checksum ${report.framebufferChecksum.toString(16)}` : null,
    `host: status ${report.status}`
  ].filter(Boolean).forEach(appendBootLine);
}

function appendBootLine(line) {
  const div = document.createElement("div");
  div.className = "boot-line";
  div.textContent = line;
  bootLog.appendChild(div);
  bootLog.scrollTop = bootLog.scrollHeight;
}

function updateClock() {
  const now = new Date();
  clock.textContent = now.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function postHostMessage(type, payload = {}) {
  window.webkit?.messageHandlers?.mobileOSHost?.postMessage({ type, ...payload });
}

function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function envelopeIcon() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 6h16v12H4z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/><path d="m4 7 8 6 8-6" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/></svg>`;
}

function compassIcon() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="8" fill="none" stroke="currentColor" stroke-width="2"/><path d="m15 8-2 6-4 2 2-6z" fill="currentColor"/></svg>`;
}

function settingsIcon() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z" fill="none" stroke="currentColor" stroke-width="2"/><path d="M4 12h3m10 0h3M12 4v3m0 10v3M6.4 6.4l2.1 2.1m7 7 2.1 2.1m0-11.2-2.1 2.1m-7 7-2.1 2.1" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>`;
}

function folderIcon() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 7h7l2 2h9v9H3z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/></svg>`;
}

function cameraIcon() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 8h3l1.4-2h5.2L16 8h3v10H5z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/><circle cx="12" cy="13" r="3" fill="none" stroke="currentColor" stroke-width="2"/></svg>`;
}

function noteIcon() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 4h12v16H6z" fill="none" stroke="currentColor" stroke-width="2"/><path d="M9 8h6M9 12h6M9 16h4" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>`;
}

function terminalIcon() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m7 8 4 4-4 4M12 16h5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><rect x="3" y="5" width="18" height="14" rx="2" fill="none" stroke="currentColor" stroke-width="2"/></svg>`;
}

function packageIcon() {
  return `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m4 8 8-4 8 4-8 4zM4 8v8l8 4 8-4V8M12 12v8" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/></svg>`;
}

renderHome();
startBootLog();
updateClock();
window.setInterval(updateClock, 30_000);
