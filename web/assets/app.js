// =============================================================================
// Tor Security Router - Dashboard JavaScript
// =============================================================================

const REFRESH_INTERVAL = 10000; // ms

const IFACE_ROLES = {
  eth0:  'WAN 1 (Primary)',
  wlan0: 'WAN 2 (Failover)',
  eth1:  'LAN Standard',
  eth2:  'LAN Tor 1',
  eth3:  'LAN Tor 2',
};

// ── Clock ─────────────────────────────────────────────────────────────────────
function updateClock() {
  document.getElementById('clock').textContent =
    new Date().toLocaleTimeString();
}
setInterval(updateClock, 1000);
updateClock();

// ── Helpers ───────────────────────────────────────────────────────────────────
function setDot(id, state) {
  const el = document.getElementById(id);
  if (!el) return;
  el.className = 'dot ' + (state === 'active' ? 'active' : state === 'inactive' ? 'inactive' : 'unknown');
}

function setBar(id, pct) {
  const el = document.getElementById(id);
  if (!el) return;
  const clamped = Math.min(100, Math.max(0, pct));
  el.style.width = clamped + '%';
  el.classList.toggle('warn', clamped >= 70 && clamped < 90);
  el.classList.toggle('crit', clamped >= 90);
}

function feedback(id, msg, isError = false) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = msg;
  el.className = 'feedback' + (isError ? ' error' : '');
  setTimeout(() => { if (el.textContent === msg) el.textContent = ''; }, 5000);
}

async function api(path, body = null) {
  const opts = body
    ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
    : { method: 'GET' };
  const res = await fetch(path, opts);
  return res.json();
}

async function controlAction(action, extra = {}) {
  return api('/api/control.php', { action, ...extra });
}

// ── Status Refresh ────────────────────────────────────────────────────────────
async function refreshStatus() {
  let data;
  try {
    data = await api('/api/status.php');
  } catch (e) {
    console.error('Status fetch failed:', e);
    return;
  }

  // Services
  const s = data.services || {};
  setDot('svc-tor',     s.tor);
  setDot('svc-dnsmasq', s.dnsmasq);
  setDot('svc-nginx',   s.nginx);
  setDot('svc-pihole',  s.pihole);
  setDot('svc-vpn', (data.vpn?.connected) ? 'active' : 'inactive');

  // Tor exit IP
  document.getElementById('tor-exit-ip').textContent = data.tor_exit_ip || '—';

  // WAN state
  const wanEl   = document.getElementById('wan-state');
  const wanHint = document.getElementById('wan-hint');
  const ws = data.wan_state || 'unknown';
  wanEl.textContent = { normal: 'Normal', failover: 'Failover', nowan: 'NO WAN', manual: 'Manual', unknown: '—' }[ws] || ws;
  wanEl.style.color = ws === 'nowan' ? 'var(--red)' : ws === 'failover' ? 'var(--yellow)' : 'var(--green)';
  wanHint.textContent = {
    normal:   'eth0 primary, wlan0 standby',
    failover: 'eth0 down — using wlan0',
    nowan:    'Both WAN links are down!',
    manual:   'Manually configured',
  }[ws] || '';

  // CPU
  const cpu = data.cpu_percent ?? 0;
  document.getElementById('cpu-val').textContent = cpu;
  setBar('cpu-bar', cpu);

  // Memory
  const mem = data.memory || {};
  document.getElementById('mem-val').textContent   = mem.percent ?? '—';
  document.getElementById('mem-used').textContent  = mem.used_mb ?? '—';
  document.getElementById('mem-total').textContent = mem.total_mb ?? '—';
  setBar('mem-bar', mem.percent ?? 0);

  // Network table
  const tbody = document.getElementById('net-tbody');
  tbody.innerHTML = '';
  const net = data.network || {};
  for (const [iface, stats] of Object.entries(net)) {
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td><code>${iface}</code></td>
      <td>${IFACE_ROLES[iface] || '—'}</td>
      <td>${stats.rx_mb?.toLocaleString() ?? '—'}</td>
      <td>${stats.tx_mb?.toLocaleString() ?? '—'}</td>`;
    tbody.appendChild(tr);
  }

  // Pi-hole stats
  const ph = data.pihole || {};
  if (ph.available) {
    document.getElementById('ph-total').textContent   = (ph.dns_queries_today ?? 0).toLocaleString();
    document.getElementById('ph-blocked').textContent = (ph.ads_blocked_today  ?? 0).toLocaleString();
    document.getElementById('ph-pct').textContent     = (ph.ads_percentage     ?? 0).toFixed(1) + '%';
  } else {
    ['ph-total', 'ph-blocked', 'ph-pct'].forEach(id => {
      document.getElementById(id).textContent = 'N/A';
    });
  }

  // VPN profiles dropdown
  const profileSel = document.getElementById('vpn-profile-select');
  const current = profileSel.value;
  profileSel.innerHTML = '<option value="">— select —</option>';
  (data.vpn_profiles || []).forEach(p => {
    const opt = document.createElement('option');
    opt.value = p;
    opt.textContent = p;
    if (p === current) opt.selected = true;
    profileSel.appendChild(opt);
  });
}

// ── Button Handlers ───────────────────────────────────────────────────────────
document.getElementById('btn-new-circuit').addEventListener('click', async () => {
  feedback('tor-feedback', '⏳ Requesting new circuit…');
  const r = await controlAction('tor_new_circuit');
  feedback('tor-feedback', r.message || (r.ok ? '✓ Done' : '✗ Failed'), !r.ok);
  if (r.ok) setTimeout(refreshStatus, 3000);
});

document.getElementById('btn-restart-tor').addEventListener('click', async () => {
  feedback('tor-feedback', '⏳ Restarting Tor…');
  const r = await controlAction('tor_restart');
  feedback('tor-feedback', r.ok ? '✓ Tor restarted' : ('✗ ' + r.message), !r.ok);
  if (r.ok) setTimeout(refreshStatus, 5000);
});

document.getElementById('btn-vpn-connect').addEventListener('click', async () => {
  const profile = document.getElementById('vpn-profile-select').value;
  if (!profile) { feedback('vpn-feedback', '✗ Select a profile first.', true); return; }
  feedback('vpn-feedback', `⏳ Connecting to ${profile}…`);
  const r = await controlAction('vpn_connect', { profile });
  feedback('vpn-feedback', r.ok ? `✓ ${r.message}` : `✗ ${r.message}`, !r.ok);
  if (r.ok) setTimeout(refreshStatus, 3000);
});

document.getElementById('btn-vpn-disconnect').addEventListener('click', async () => {
  feedback('vpn-feedback', '⏳ Disconnecting VPN…');
  const r = await controlAction('vpn_disconnect');
  feedback('vpn-feedback', r.ok ? '✓ VPN disconnected' : `✗ ${r.message}`, !r.ok);
  if (r.ok) setTimeout(refreshStatus, 2000);
});

document.getElementById('btn-vpn-upload').addEventListener('click', async () => {
  const fileInput = document.getElementById('vpn-file-input');
  if (!fileInput.files.length) { feedback('vpn-feedback', '✗ Select a file first.', true); return; }
  const formData = new FormData();
  formData.append('file', fileInput.files[0]);
  feedback('vpn-feedback', '⏳ Uploading…');
  const res = await fetch('/api/control.php?action=vpn_upload', { method: 'POST', body: formData });
  const r = await res.json();
  feedback('vpn-feedback', r.ok ? `✓ ${r.message}` : `✗ ${r.message}`, !r.ok);
  fileInput.value = '';
  if (r.ok) setTimeout(refreshStatus, 1000);
});

document.getElementById('btn-set-wan').addEventListener('click', async () => {
  const iface = document.getElementById('wan-select').value;
  feedback('wan-feedback', `⏳ Setting primary WAN to ${iface}…`);
  const r = await controlAction('wan_set_primary', { interface: iface });
  feedback('wan-feedback', r.ok ? `✓ Primary WAN set to ${iface}` : `✗ ${r.message}`, !r.ok);
  if (r.ok) setTimeout(refreshStatus, 2000);
});

// ── Initial load & polling ────────────────────────────────────────────────────
refreshStatus();
setInterval(refreshStatus, REFRESH_INTERVAL);
