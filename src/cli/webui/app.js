const nodesTbody = document.getElementById("nodes-tbody");
const nodesEmpty = document.getElementById("nodes-empty");
const nodesCount = document.getElementById("nodes-count");
const topicsTbody = document.getElementById("topics-tbody");
const topicsEmpty = document.getElementById("topics-empty");
const topicsCount = document.getElementById("topics-count");
const netTbody = document.getElementById("net-tbody");
const netEmpty = document.getElementById("net-empty");
const netCount = document.getElementById("net-count");
const conn = document.getElementById("conn");
const connText = document.getElementById("conn-text");
const detailTopicName = document.getElementById("detail-topic-name");
const topicDetail = document.getElementById("topic-detail");
const logsBody = document.getElementById("logs-body");
const logsTarget = document.getElementById("logs-target");
const logsCount = document.getElementById("logs-count");
const logTabs = document.querySelectorAll("[data-log-mode]");

let selectedTopic = null;
let topicsData = [];
let selectedNode = null;
let logMode = "tail";
let logNode = null;

function setConn(ok) {
  conn.classList.toggle("ok", ok);
  connText.textContent = ok ? "connected" : "disconnected";
}
function fmt(v) {
  return v === null || v === undefined ? "\u2014" : Number(v).toLocaleString();
}
function tosLabel(t) {
  return t === 0 ? "reliable" : t === 1 ? "best_effort" : String(t);
}
function tosClass(t) {
  return t === 0 ? "badge-reliable" : t === 1 ? "badge-best_effort" : "";
}
function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "\x26amp;")
    .replace(/</g, "\x3clt;")
    .replace(/>/g, "\x3egt;")
    .replace(/"/g, "\x26quot;")
    .replace(/'/g, "\x26#39;");
}

function renderNodes(nodes) {
  nodesTbody.innerHTML = "";
  if (!nodes?.length) {
    nodesEmpty.hidden = false;
    nodesCount.textContent = "0";
    if (selectedNode) selectNode(null);
    return;
  }
  nodesEmpty.hidden = true;
  nodesCount.textContent = nodes.length;
  for (const n of nodes) {
    const tr = document.createElement("tr");
    tr.tabIndex = 0;
    tr.dataset.nodeName = n.name;
    tr.innerHTML = `
      <td class="cell-name">${escapeHtml(n.name ?? "\u2014")}</td>
      <td class="cell-mono cell-right">${n.pid ?? "-"}</td>
      <td class="cell-mono">${n.uptime_s !== undefined ? n.uptime_s + "s" : "\u2014"}</td>
      <td class="cell-center"><span class="mono state ${n.alive ? "alive" : "dead"}">${n.alive ? "alive" : "dead"}</span></td>
    `;
    const onSelect = () => selectNode(n.name);
    tr.addEventListener("click", onSelect);
    tr.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        onSelect();
      }
    });
    nodesTbody.appendChild(tr);
  }
  if (selectedNode) {
    if (nodes.some((n) => n.name === selectedNode)) {
      applyNodeSelection();
    } else {
      selectNode(null);
    }
  }
}

function selectNode(name) {
  selectedNode = name;
  applyNodeSelection();
  loadLogs();
}

function applyNodeSelection() {
  document.querySelectorAll("#nodes-tbody tr").forEach((tr) => {
    tr.classList.toggle("selected", tr.dataset.nodeName === selectedNode);
  });
  if (selectedNode) {
    logsTarget.textContent = selectedNode;
    logsTarget.classList.remove("empty");
  } else {
    logsTarget.textContent = "Select a node to view its logs";
    logsTarget.classList.add("empty");
    logsCount.textContent = "";
    logsBody.innerHTML = '<span class="log-empty">No node selected</span>';
  }
}

logTabs.forEach((tab) =>
  tab.addEventListener("click", () => {
    logMode = tab.dataset.logMode;
    logTabs.forEach((t) => {
      const active = t === tab;
      t.classList.toggle("active", active);
      t.setAttribute("aria-selected", active ? "true" : "false");
    });
    loadLogs();
  }),
);

function logLevelClass(line) {
  const l = line.toLowerCase();
  if (/\b(error|fatal|panic|fail(ed|ure)?)\b/.test(l)) return "log-error";
  if (/\b(warn(ing)?)\b/.test(l)) return "log-warn";
  return "";
}

async function loadLogs() {
  if (!selectedNode) return;
  const node = selectedNode;
  const params = new URLSearchParams({ node, tail: "200" });
  if (logMode === "head") {
    params.set("head", "200");
    params.delete("tail");
  }
  try {
    const r = await fetch("/api/logs?" + params.toString(), {
      cache: "no-store",
    });
    const j = await r.json();
    if (selectedNode !== node) return; // selection changed mid-flight
    logNode = node;
    if (j.status !== "ok") {
      logsBody.innerHTML = `<span class="log-empty">${escapeHtml(j.error || "no log available")}</span>`;
      logsCount.textContent = "";
      return;
    }
    const content = j.content || "";
    const lines = content.length ? content.replace(/\n$/, "").split("\n") : [];
    if (lines.length === 0) {
      logsBody.innerHTML = '<span class="log-empty">Log is empty</span>';
    } else {
      logsBody.innerHTML = lines
        .map(
          (l) =>
            `<span class="log-line ${logLevelClass(l)}">${escapeHtml(l)}</span>`,
        )
        .join("");
    }
    logsCount.textContent =
      lines.length + (lines.length === 1 ? " line" : " lines");
    if (logMode === "follow") logsBody.scrollTop = logsBody.scrollHeight;
  } catch (e) {
    if (selectedNode !== node) return;
    logsBody.innerHTML = `<span class="log-error">${escapeHtml(String(e))}</span>`;
    logsCount.textContent = "";
  }
}

function renderTopics(topics) {
  topicsData = topics || [];
  topicsTbody.innerHTML = "";
  if (!topicsData.length) {
    topicsEmpty.hidden = false;
    topicsCount.textContent = "0";
    clearSelection();
    return;
  }
  topicsEmpty.hidden = true;
  topicsCount.textContent = topicsData.length;
  for (const t of topicsData) {
    const pctFull = t.pct_full ?? 0;
    const tr = document.createElement("tr");
    tr.dataset.topicName = t.name;
    tr.tabIndex = 0;
    tr.innerHTML = `
      <td class="cell-name" title="${escapeHtml(t.name)}">${escapeHtml(t.name)}</td>
      <td class="cell-center"><span class="badge ${tosClass(t.tos)}">${tosLabel(t.tos)}</span></td>
      <td class="cell-mono cell-right">${fmt(t.msg_size)}B</td>
      <td class="cell-mono cell-right">${fmt(t.capacity)}</td>
      <td class="cell-mono cell-right">${fmt(t.queued)}</td>
      <td class="cell-mono cell-right"><div class="progress"><div class="progress-fill" style="width:${Math.min(pctFull, 100)}%"></div></div></td>
      <td class="cell-mono cell-right pid">${t.writer_pid ?? "-"}</td>
      <td class="cell-mono">${escapeHtml(t.owner ?? "-")}</td>
      <td class="cell-mono cell-right">${t.readers?.length || 0} / ${t.num_readers}</td>
    `;
    tr.addEventListener("click", () => selectTopic(t));
    tr.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        selectTopic(t);
      }
    });
    topicsTbody.appendChild(tr);
  }
  if (selectedTopic && topicsData.some((t) => t.name === selectedTopic.name)) {
    selectTopic(selectedTopic);
  } else {
    clearSelection();
  }
}

function selectTopic(t) {
  selectedTopic = t;
  document.querySelectorAll("#topics-tbody tr").forEach((tr) => {
    tr.classList.toggle("selected", tr.dataset.topicName === t.name);
  });
  detailTopicName.textContent = t.name;
  renderTopicDetail(t);
}

function clearSelection() {
  selectedTopic = null;
  document
    .querySelectorAll("#topics-tbody tr")
    .forEach((tr) => tr.classList.remove("selected"));
  detailTopicName.textContent = "\u2014";
  topicDetail.innerHTML = `
    <div class="no-selection">
      <span class="no-selection-icon">\u25b8</span>
      <span>Select a topic to view details</span>
    </div>
  `;
}

function renderTopicDetail(t) {
  const pctFull = t.pct_full ?? 0;
  const queueWidth = Math.min(pctFull, 100);

  let readersHtml = "";
  if (t.readers && t.readers.length > 0) {
    for (const r of t.readers) {
      const behindPct = t.capacity > 0 ? (r.behind / t.capacity) * 100 : 0;
      const barWidth = Math.min(behindPct, 100);
      readersHtml += `
      <div class="subscriber active">
        <span class="sub-index">[${r.index}]</span>
        <span class="sub-name" title="${escapeHtml(r.name)}">${escapeHtml(r.name)}</span>
        <span class="sub-pid">${r.pid}</span>
        <span class="sub-cursor">${fmt(r.cursor)}</span>
        <span class="sub-behind">${fmt(r.behind)} behind</span>
        <div class="sub-bar"><div class="sub-bar-fill" style="width:${barWidth}%"></div></div>
      </div>
    `;
    }
  } else {
    readersHtml =
      '<div style="color: var(--fg-subtle); padding: 0.5rem; font-size: 11px; text-align: center;">No active subscribers</div>';
  }

  topicDetail.innerHTML = `
    <section class="detail-section" aria-label="Publisher">
      <h3 class="detail-section-title">Publisher</h3>
      <div class="detail-grid">
        <span class="detail-label">PID</span>
        <span class="detail-value pid">${t.writer_pid}</span>
        <span class="detail-label">Owner</span>
        <span class="detail-value">${escapeHtml(t.owner)}</span>
        <span class="detail-label">Write Cursor</span>
        <span class="detail-value cursor">${fmt(t.write_cursor)}</span>
        <span class="detail-label">Queued</span>
        <span class="detail-value">${fmt(t.queued)} msgs (${pctFull.toFixed(1)}%)</span>
      </div>
      <div class="queue-bar"><div class="queue-fill" style="width:${queueWidth}%"></div></div>
    </section>
    <section class="detail-section" aria-label="Subscribers">
      <h3 class="detail-section-title">Subscribers (${t.readers?.length || 0} active / ${t.num_readers} total)</h3>
      ${readersHtml}
    </section>
    <section class="detail-section" aria-label="Topic Info">
      <h3 class="detail-section-title">Topic Info</h3>
      <div class="detail-grid">
        <span class="detail-label">TOS</span>
        <span class="detail-value"><span class="badge ${tosClass(t.tos)}">${tosLabel(t.tos)}</span></span>
        <span class="detail-label">Msg Size</span>
        <span class="detail-value">${fmt(t.msg_size)}B</span>
        <span class="detail-label">Capacity</span>
        <span class="detail-value">${fmt(t.capacity)}</span>
        <span class="detail-label">Total Readers</span>
        <span class="detail-value">${t.num_readers}</span>
      </div>
    </section>
  `;
}

function renderNet(nets) {
  netTbody.innerHTML = "";
  if (!nets?.length) {
    netEmpty.hidden = false;
    netCount.textContent = "0";
    return;
  }
  netEmpty.hidden = true;
  netCount.textContent = nets.length;
  for (const n of nets) {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td class="cell-name">${escapeHtml(n.name ?? "\u2014")}</td>
      <td class="cell-mono cell-right">${n.port ?? "-"}</td>
      <td class="cell-mono cell-right">${n.writer_pid ?? "-"}</td>
      <td class="cell-center"><span class="badge ${tosClass(n.tos)}">${tosLabel(n.tos)}</span></td>
      <td class="cell-mono cell-right">${fmt(n.msg_size)}</td>
      <td class="cell-mono cell-right">${fmt(n.capacity)}</td>
      <td class="cell-mono cell-right">${fmt(n.num_reg)}</td>
    `;
    netTbody.appendChild(tr);
  }
}

async function poll() {
  try {
    const [statusRes, topicsRes] = await Promise.all([
      fetch("/api/status", { cache: "no-store" }),
      fetch("/api/topics", { cache: "no-store" }),
    ]);
    if (!statusRes.ok) throw new Error("HTTP " + statusRes.status);
    if (!topicsRes.ok) throw new Error("Topics HTTP " + topicsRes.status);
    const [statusData, topicsData] = await Promise.all([
      statusRes.json(),
      topicsRes.json(),
    ]);
    renderNodes(statusData.nodes);
    renderTopics(topicsData.topics);
    renderNet(statusData.net || []);
    setConn(statusData.status === "ok");
    if (selectedNode && selectedNode === logNode) loadLogs();
  } catch (e) {
    renderNodes([]);
    renderTopics([]);
    renderNet([]);
    setConn(false);
  }
}

poll();
setInterval(poll, 1000);
