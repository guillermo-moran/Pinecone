const policy = {
  boundaryMode: "metadataOnly",
  deniedSuffixes: [".ipsw", ".im4p", ".im4m", ".img4", ".bbfw"],
  deniedTerms: ["ipsw", "secure enclave", "sep secret", "activation", "attestation", "apns", "imessage"]
};

const adapters = [
  {
    id: "toy-uart",
    name: "Toy UART Guest",
    status: "runnable",
    required: [],
    optional: [],
    next: ["Run with the built-in CLI command."]
  },
  {
    id: "raw-arm64-binary",
    name: "Raw ARM64 Binary",
    status: "planned",
    required: ["rawARM64Binary"],
    optional: ["metadataManifest"],
    next: ["Add load address metadata.", "Map RAM and UART."]
  },
  {
    id: "rtos-direct",
    name: "RTOS / Microkernel",
    status: "planned",
    required: ["arm64KernelImage"],
    optional: ["deviceTreeBlob", "rawARM64Binary"],
    next: ["Define entry point.", "Add timer and UART expectations."]
  },
  {
    id: "linux-direct",
    name: "Linux Direct Boot",
    status: "loadable",
    required: ["arm64KernelImage"],
    optional: ["initrd", "deviceTreeBlob", "diskImage", "rootFilesystem"],
    next: ["Handoff loads kernel/initrd/FDT.", "Execution now reaches exception/fault routing before shell."]
  },
  {
    id: "aosp",
    name: "AOSP Android",
    status: "planned",
    required: ["arm64KernelImage", "initrd"],
    optional: ["androidSystemImage", "androidVendorImage", "androidProductImage", "androidSuperImage", "diskImage"],
    next: ["Boot open Linux first.", "Model Android storage and virtio devices."]
  },
  {
    id: "bsd-direct",
    name: "BSD ARM64",
    status: "planned",
    required: ["arm64KernelImage"],
    optional: ["diskImage", "deviceTreeBlob"],
    next: ["Confirm boot ABI.", "Generate platform description."]
  },
  {
    id: "proprietary-boundary",
    name: "Proprietary Guest Boundary",
    status: "boundaryOnly",
    required: ["metadataManifest"],
    optional: [],
    next: ["Validate metadata.", "Use open guests for VM bring-up."]
  }
];

const state = {
  artifacts: []
};

const alpineCanary = {
  kernel: "artifacts/linux-shell/out/Image",
  initrd: "artifacts/linux-shell/out/initramfs-virt-ttyinit.cpio",
  memory: "512 MiB",
  entry: "0x40080000",
  bootArgs: "console=ttyAMA0 earlycon=pl011,mmio32,0x9000000 rdinit=/init loglevel=7",
  blocker: "ttyAMA0 shell reached through the custom /init path; command injection can run foreground shell commands.",
  next: "Add raw terminal key events, persistent block storage, and framebuffer display after console bring-up."
};

const dropZone = document.getElementById("dropZone");
const fileInput = document.getElementById("fileInput");
const pickButton = document.getElementById("pickButton");
const clearButton = document.getElementById("clearButton");
const artifactRows = document.getElementById("artifactRows");
const artifactTable = document.getElementById("artifactTable");
const emptyState = document.getElementById("emptyState");
const adapterList = document.getElementById("adapterList");
const adapterCount = document.getElementById("adapterCount");
const machineStatus = document.getElementById("machineStatus");
const bootSessionStatus = document.getElementById("bootSessionStatus");
const sessionMeta = document.getElementById("sessionMeta");
const terminalOutput = document.getElementById("terminalOutput");
const canvas = document.getElementById("machineCanvas");
const ctx = canvas.getContext("2d");

pickButton.addEventListener("click", () => fileInput.click());
clearButton.addEventListener("click", () => {
  state.artifacts = [];
  fileInput.value = "";
  render();
});

fileInput.addEventListener("change", event => {
  addFiles([...event.target.files]);
});

dropZone.addEventListener("dragover", event => {
  event.preventDefault();
  dropZone.classList.add("is-dragging");
});

dropZone.addEventListener("dragleave", () => {
  dropZone.classList.remove("is-dragging");
});

dropZone.addEventListener("drop", event => {
  event.preventDefault();
  dropZone.classList.remove("is-dragging");
  addFiles([...event.dataTransfer.files]);
});

function addFiles(files) {
  const mapped = files.map(file => ({
    name: file.name,
    size: file.size,
    kind: classify(file.name)
  }));
  state.artifacts = [...state.artifacts, ...mapped];
  render();
}

function classify(name) {
  const lower = name.toLowerCase();
  if (policy.deniedSuffixes.some(suffix => lower.endsWith(suffix))) return "restrictedPackage";
  if (lower.endsWith(".dtb") || lower.endsWith(".dtbo")) return "deviceTreeBlob";
  if (lower.includes("initrd") || lower.includes("ramdisk") || lower.endsWith(".cpio") || lower.endsWith(".cpio.gz")) return "initrd";
  if (lower === "image" || lower.includes("vmlinuz") || lower.includes("kernel") || lower.endsWith(".elf")) return "arm64KernelImage";
  if (lower === "system.img") return "androidSystemImage";
  if (lower === "vendor.img") return "androidVendorImage";
  if (lower === "product.img") return "androidProductImage";
  if (lower === "super.img") return "androidSuperImage";
  if (lower.endsWith(".app.js") || lower.endsWith(".mobile.js")) return "mobileAppBundle";
  if (lower.endsWith(".json")) return "metadataManifest";
  if (lower.endsWith(".bin")) return "rawARM64Binary";
  if (lower.endsWith(".img") || lower.endsWith(".raw") || lower.endsWith(".qcow2")) return "diskImage";
  return "unknown";
}

function artifactFindings(artifact) {
  const lower = artifact.name.toLowerCase();
  const findings = [];
  if (artifact.kind === "restrictedPackage") findings.push("restricted package");
  for (const suffix of policy.deniedSuffixes) {
    if (lower.endsWith(suffix)) findings.push(`denied suffix ${suffix}`);
  }
  for (const term of policy.deniedTerms) {
    if (lower.includes(term)) findings.push(`denied term ${term}`);
  }
  return findings;
}

function plan(adapter) {
  const kinds = new Set(state.artifacts.map(artifact => artifact.kind));
  const accepted = new Set([...adapter.required, ...adapter.optional]);
  const missing = adapter.required.filter(kind => !kinds.has(kind));
  const restricted = state.artifacts.flatMap(artifactFindings);
  const hasMatch = adapter.required.length === 0
    ? state.artifacts.length === 0
    : state.artifacts.some(artifact => accepted.has(artifact.kind));

  return {
    matches: hasMatch && missing.length === 0 && restricted.length === 0,
    canLaunch: adapter.status === "runnable" && state.artifacts.length === 0,
    missing,
    restricted
  };
}

function render() {
  renderArtifacts();
  renderAdapters();
  renderBootSession();
  drawMachine();
}

function renderArtifacts() {
  artifactRows.innerHTML = "";
  const hasArtifacts = state.artifacts.length > 0;
  artifactTable.hidden = !hasArtifacts;
  emptyState.hidden = hasArtifacts;

  for (const artifact of state.artifacts) {
    const findings = artifactFindings(artifact);
    const row = document.createElement("tr");
    row.innerHTML = `
      <td class="name-cell">${escapeHtml(artifact.name)}</td>
      <td>${kindLabel(artifact.kind)}</td>
      <td>${formatBytes(artifact.size)}</td>
      <td>${findings.length ? badge("deny", "Blocked") : badge("ok", "Allowed")}</td>
    `;
    artifactRows.appendChild(row);
  }
}

function renderAdapters() {
  adapterList.innerHTML = "";
  adapterCount.textContent = String(adapters.length);

  for (const adapter of adapters) {
    const result = plan(adapter);
    const item = document.createElement("article");
    item.className = "adapter-item";
    const statusClass = adapter.status === "runnable" ? "ok" : adapter.status === "boundaryOnly" ? "warn" : "warn";
    const matchBadge = result.matches ? badge("ok", "Match") : badge("warn", "Pending");
    const blocked = result.restricted.length ? badge("deny", "Blocked") : "";
    const missing = result.missing.length
      ? `<li>Missing: ${result.missing.map(kindLabel).join(", ")}</li>`
      : "";
    const restricted = result.restricted.length
      ? `<li>${[...new Set(result.restricted)].join(", ")}</li>`
      : "";

    item.innerHTML = `
      <div class="adapter-title">
        <h3>${escapeHtml(adapter.name)}</h3>
        ${badge(statusClass, adapter.status)}
      </div>
      <div class="adapter-meta">${matchBadge}${blocked}</div>
      <ul>
        ${missing}
        ${restricted}
        <li>${adapter.next.map(escapeHtml).join(" ")}</li>
      </ul>
    `;
    adapterList.appendChild(item);
  }
}

function renderBootSession() {
  const summary = bootSummary();
  bootSessionStatus.textContent = summary.status;
  bootSessionStatus.className = summary.statusClass;
  sessionMeta.innerHTML = [
    ["Kernel", alpineCanary.kernel],
    ["Initrd", alpineCanary.initrd],
    ["Memory", alpineCanary.memory],
    ["Entry", alpineCanary.entry],
    ["Boot Args", alpineCanary.bootArgs]
  ].map(([label, value]) => `
    <div class="meta-row">
      <span>${escapeHtml(label)}</span>
      <code>${escapeHtml(value)}</code>
    </div>
  `).join("");

  terminalOutput.textContent = [
    "arm64viz boot-lab",
    "$ swift run arm64viz prepare-linux artifacts/linux-shell/out/Image --initrd artifacts/linux-shell/out/initramfs-virt-ttyinit.cpio --memory-mib 512 --minimal-devices --bootargs \"console=ttyAMA0 earlycon=pl011,mmio32,0x9000000 rdinit=/init loglevel=7\"",
    "handoff: ok",
    `entry: ${alpineCanary.entry}`,
    "fdt: generated and passed in x0",
    "initrd: staged in guest RAM",
    "",
    "$ swift run -c release arm64viz run-linux-trace artifacts/linux-shell/out/Image --initrd artifacts/linux-shell/out/initramfs-virt-ttyinit.cpio --memory-mib 512 --minimal-devices --max-steps 400000000 --trace-depth 256 --bootargs \"console=ttyAMA0 earlycon=pl011,mmio32,0x9000000 rdinit=/init loglevel=7\" --uart-input-after-output \"arm64viz init: ttyAMA0 console ready\" --uart-input-line \"echo TTYINIT_OK\"",
    `trace: ${alpineCanary.blocker}`,
    "",
    "ttyAMA0: /init launched a controlling-terminal shell.",
    `next: ${alpineCanary.next}`
  ].join("\n");
}

function bootSummary() {
  if (state.artifacts.some(artifact => artifactFindings(artifact).length > 0)) {
    return { status: "policy blocked", statusClass: "deny-text" };
  }
  return { status: "fault blocked", statusClass: "warn-text" };
}

function drawMachine() {
  const width = canvas.width;
  const height = canvas.height;
  ctx.clearRect(0, 0, width, height);
  ctx.fillStyle = "#101820";
  ctx.fillRect(0, 0, width, height);

  const hasRestricted = state.artifacts.some(artifact => artifactFindings(artifact).length > 0);
  machineStatus.textContent = hasRestricted ? "blocked" : "fault blocked";

  const lanes = [
    { label: "CPU", x: 42, y: 58, w: 140, h: 58, color: "#73d6c9" },
    { label: "RAM", x: 42, y: 162, w: 140, h: 58, color: "#93c5fd" },
    { label: "MMIO", x: 300, y: 110, w: 160, h: 58, color: "#facc15" },
    { label: "Guest", x: 574, y: 110, w: 140, h: 58, color: hasRestricted ? "#fca5a5" : "#86efac" }
  ];

  ctx.lineWidth = 3;
  ctx.strokeStyle = "#5b7080";
  drawLine(182, 87, 300, 139);
  drawLine(182, 191, 300, 139);
  drawLine(460, 139, 574, 139);

  for (const lane of lanes) {
    ctx.fillStyle = "rgba(255,255,255,0.06)";
    ctx.strokeStyle = lane.color;
    roundRect(lane.x, lane.y, lane.w, lane.h, 8);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = "#ffffff";
    ctx.font = "700 19px system-ui, sans-serif";
    ctx.fillText(lane.label, lane.x + 18, lane.y + 36);
  }

  ctx.fillStyle = "#b8c7d3";
  ctx.font = "650 15px system-ui, sans-serif";
  const summary = state.artifacts.length
    ? `${state.artifacts.length} artifact${state.artifacts.length === 1 ? "" : "s"} staged`
    : "Alpine aarch64 canary staged in artifacts/";
  ctx.fillText(summary, 42, 296);
  ctx.font = "520 15px system-ui, sans-serif";
  ctx.fillText(hasRestricted ? "Policy blocks restricted packages before boot planning." : "Linux handoff is prepared; execution stops before /bin/sh at exception vector translation.", 42, 322);
}

function drawLine(x1, y1, x2, y2) {
  ctx.beginPath();
  ctx.moveTo(x1, y1);
  ctx.lineTo(x2, y2);
  ctx.stroke();
}

function roundRect(x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

function badge(type, label) {
  return `<span class="badge ${type}">${escapeHtml(label)}</span>`;
}

function kindLabel(kind) {
  return kind.replace(/([A-Z])/g, " $1").replace(/^./, value => value.toUpperCase());
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KiB", "MiB", "GiB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(value >= 10 ? 1 : 2)} ${units[unit]}`;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

render();
