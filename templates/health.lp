<?
mg.include("scripts/lua/header.lp","r")
?>
    <style>
        /* 72h Uptime Grid Styling */
        .grid-row { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; }
        .row-label { width: 100px; font-weight: 600; opacity: 0.8; font-size: 0.95em; }
        .row-cells { display: flex; gap: 3px; flex-grow: 1; position: relative; }
        
        .hour-cell { 
            flex: 1; 
            height: 26px; 
            background-color: #d2d6de; 
            opacity: 0.7;
            border-radius: 3px; 
            transition: transform 0.15s, box-shadow 0.15s, background-color 0.2s, opacity 0.2s; 
            position: relative;
            cursor: pointer;
        }
        .hour-cell:hover { 
            transform: scaleY(1.35); 
            z-index: 10;
            box-shadow: 0 2px 6px rgba(0,0,0,0.25);
        }
        .hour-cell.hour-ok { background-color: #00a65a; opacity: 1; }
        .hour-cell.hour-warning { background-color: #f39c12; opacity: 1; }
        .hour-cell.hour-danger { background-color: #dd4b39; opacity: 1; }
        .hour-cell.hour-inactive { background-color: #d2d6de; opacity: 0.7; }

        /* Time Labels Header above Grid */
        .time-header-row { display: flex; margin-left: 110px; margin-bottom: 6px; gap: 3px; font-size: 11px; font-weight: bold; }

        /* DNS Chain Node Styling */
        .chain-flow { 
            display: flex; 
            align-items: stretch; 
            justify-content: space-between; 
            gap: 12px; 
            padding: 15px 5px; 
        }
        .chain-node { 
            border: 2px solid #d2d6de; 
            border-radius: 6px; 
            padding: 14px 12px; 
            flex: 1 1 0; 
            min-width: 0; 
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
            text-align: center; 
            box-sizing: border-box;
            transition: border-color 0.2s;
        }
        .chain-node.node-ok { border-color: #00a65a; }
        .chain-node.node-warning { border-color: #f39c12; }
        .chain-node.node-fail { border-color: #dd4b39; }
        .node-name { font-weight: bold; font-size: 1.1em; }
        .node-status-desc { font-size: 0.85em; opacity: 0.7; font-family: monospace; margin-top: 4px; word-break: break-word; line-height: 1.35; }
        .connector-arrow { 
            display: flex; 
            align-items: center; 
            justify-content: center; 
            font-size: 1.5em; 
            color: #d2d6de; 
            font-weight: bold; 
            flex-shrink: 0; 
            transition: color 0.2s;
        }
        .connector-arrow.arrow-ok { color: #00a65a; }
        .connector-arrow.arrow-fail { color: #dd4b39; }

        @media (prefers-color-scheme: dark) {
            .hour-cell { background-color: #4b646f; opacity: 0.45; }
            .hour-cell.hour-ok { background-color: #00a65a; opacity: 1; }
            .hour-cell.hour-warning { background-color: #f39c12; opacity: 1; }
            .hour-cell.hour-danger { background-color: #dd4b39; opacity: 1; }
            .hour-cell.hour-inactive { background-color: #4b646f; opacity: 0.45; }
            .chain-node { border-color: #4b646f; }
            .chain-node.node-ok { border-color: #00a65a; }
            .chain-node.node-warning { border-color: #f39c12; }
            .chain-node.node-fail { border-color: #dd4b39; }
            .connector-arrow { color: #4b646f; }
            .connector-arrow.arrow-ok { color: #00a65a; }
            .connector-arrow.arrow-fail { color: #dd4b39; }
            .box.box-default { border-top-color: #4b646f; }
        }

        .box.box-default { border-top-color: #d2d6de; }

        /* Mobile: uniform 2x2 grid */
        @media (max-width: 767px) {
            .chain-flow { 
                display: grid; 
                grid-template-columns: 1fr 1fr; 
                grid-auto-rows: 1fr; 
                gap: 10px; 
                padding: 10px 0; 
            }
            .chain-node { 
                width: 100%; 
                height: 100%; 
                padding: 12px 6px; 
                min-height: 72px; 
            }
            .connector-arrow { display: none; }
            .node-name { font-size: 0.95em; }
            .node-status-desc { font-size: 0.75em; }
            .time-header-row span:nth-child(2),
            .time-header-row span:nth-child(3),
            .time-header-row span:nth-child(5),
            .time-header-row span:nth-child(6) { display: none; }
        }
    </style>
</head>
<body class="<?=theme.name?> hold-transition sidebar-mini <? if pihole.boxedlayout() then ?>layout-boxed<? end ?>">
<div class="wrapper">

    <!-- Header Navbar -->
    <header class="main-header">
        <a href="<?=webhome?>" class="logo">
            <span class="logo-mini">P<strong>h</strong></span>
            <span class="logo-lg">Pi-<strong>hole</strong></span>
        </a>
        <nav class="navbar navbar-static-top">
            <a href="#" class="sidebar-toggle" data-toggle="push-menu" role="button">
                <span class="sr-only">Toggle navigation</span>
            </a>
            <div class="navbar-custom-menu">
                <ul class="nav navbar-nav">
                    <li>
                        <a href="<?=webhome?>" class="btn btn-primary btn-sm" style="margin-top: 10px; margin-right: 15px; color: white !important; font-weight: bold; background-color: #3c8dbc; border: none;">
                            <i class="fas fa-tachometer-alt"></i> Pi-hole Admin Dashboard &rarr;
                        </a>
                    </li>
                </ul>
            </div>
        </nav>
    </header>

    <!-- Sidebar Navigation with ONLY 2 Items -->
    <aside class="main-sidebar">
        <section class="sidebar">
            <div class="user-panel" style="padding: 12px 10px;">
                <div class="pull-left image">
                    <img class="logo-img" src="<?=webhome?>img/logo.svg" alt="Pi-hole logo" width="45" height="65">
                </div>
                <div class="pull-left info" style="padding-left: 10px;">
                    <p style="margin-bottom: 5px; font-weight: bold;">Internet Health</p>
                    <span class="label label-success"><i class="fa fa-circle"></i> Active</span>
                </div>
            </div>
            <ul class="sidebar-menu" data-widget="tree">
                <li class="header text-uppercase">Navigation</li>
                <li class="active">
                    <a href="/">
                        <i class="fa fa-fw menu-icon fa-heartbeat text-red"></i> <span>Overview</span>
                    </a>
                </li>
                <li>
                    <a href="<?=webhome?>">
                        <i class="fa fa-fw menu-icon fa-home"></i> <span>Pi-hole Admin</span>
                    </a>
                </li>
            </ul>
        </section>
    </aside>

    <!-- Main Content Area -->
    <div class="content-wrapper" style="min-height: 900px; padding: 15px;">
        <section class="content-header" style="padding-bottom: 15px;">
            <h1>
                Internet Health Check
                <small style="color: #aaa;">Live WAN Link, DNS Chain & 72h Uptime</small>
            </h1>
        </section>

        <section class="content">
            <!-- Live DNS Chain Box (Live Status: Blue) -->
            <div class="box box-info">
                <div class="box-header with-border">
                    <h3 class="box-title"><i class="fas fa-network-wired"></i> Live DNS Chain Diagnostics</h3>
                    <div class="box-tools pull-right">
                        <span id="header-last-updated" class="text-muted" style="font-size: 0.85em; margin-right: 10px;">Updated: just now</span>
                        <span id="header-status-label" class="label label-default" style="font-size: 0.9em;">● STATUS: Initializing...</span>
                    </div>
                </div>
                <div class="box-body">
                    <div class="chain-flow">
                        <div id="node-client" class="chain-node">
                            <div class="node-name">CLIENT</div>
                            <div class="node-status-desc" id="node-client-desc">Loading...</div>
                        </div>
                        <div id="arrow-1" class="connector-arrow">&rarr;</div>
                        <div id="node-pihole" class="chain-node">
                            <div class="node-name">Pi-hole</div>
                            <div id="node-pihole-desc" class="node-status-desc">127.0.0.1:53 (Pending)</div>
                        </div>
                        <div id="arrow-2" class="connector-arrow">&rarr;</div>
                        <div id="node-dnscrypt" class="chain-node">
                            <div class="node-name">dnscrypt-proxy</div>
                            <div id="node-dnscrypt-desc" class="node-status-desc">127.0.0.1:5053 (Pending)</div>
                        </div>
                        <div id="arrow-3" class="connector-arrow">&rarr;</div>
                        <div id="node-cloudflare" class="chain-node">
                            <div class="node-name">Cloudflare (DoH)</div>
                            <div id="node-cloudflare-desc" class="node-status-desc">1.1.1.3:53 (Pending)</div>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Stat Boxes Row (Row 2: Live Status: Blue) -->
            <div class="row">
                <div class="col-md-6">
                    <div class="box box-info">
                        <div class="box-header with-border">
                            <h3 class="box-title"><i class="fas fa-tachometer-alt"></i> Hop Latency Benchmark</h3>
                        </div>
                        <div class="box-body">
                            <table class="table table-bordered">
                                <tr><td>Pi-hole DNS Hop</td><td><span id="lat-pi" class="label label-default">--</span></td></tr>
                                <tr><td>dnscrypt-proxy Hop</td><td><span id="lat-dns" class="label label-default">--</span></td></tr>
                                <tr><td>Cloudflare Upstream</td><td><span id="lat-cf" class="label label-default">--</span></td></tr>
                            </table>
                        </div>
                    </div>
                </div>
                <div class="col-md-6">
                    <div class="box box-info">
                        <div class="box-header with-border">
                            <h3 class="box-title"><i class="fas fa-plug"></i> Network Interfaces</h3>
                        </div>
                        <div class="box-body">
                            <table class="table table-bordered">
                                <tr><td>Wired Link (eth0)</td><td><span id="if-eth" class="label label-default">Pending</span></td></tr>
                                <tr><td>Wireless Link (wlan0)</td><td><span id="if-wlan" class="label label-default">Pending</span></td></tr>
                                <tr><td>Packet Loss (Ping)</td><td><span id="if-loss" class="label label-default">--%</span></td></tr>
                            </table>
                        </div>
                    </div>
                </div>
            </div>

            <!-- 72h Uptime Grid Box (Row 3: Historical) -->
            <div class="box box-default">
                <div class="box-header with-border">
                    <h3 class="box-title"><i class="fas fa-history"></i> Historical Uptime (Last 72 Hours)</h3>
                    <div class="box-tools pull-right">
                        <span id="grid-uptime-pct" class="label label-default" style="font-size: 0.9em;">● SLA: --%</span>
                    </div>
                </div>
                <div class="box-body">
                    <!-- Hour Markers Header -->
                    <div class="time-header-row">
                        <div style="display: flex; flex-grow: 1; justify-content: space-between; font-family: monospace; font-size: 11px; opacity: 0.7;">
                            <span>00:00</span>
                            <span>04:00</span>
                            <span>08:00</span>
                            <span>12:00</span>
                            <span>16:00</span>
                            <span>20:00</span>
                            <span>23:59</span>
                        </div>
                    </div>

                    <div class="grid-row">
                        <div class="row-label">2 Days Ago</div>
                        <div class="row-cells" id="row-2daysago"></div>
                    </div>
                    <div class="grid-row">
                        <div class="row-label">Yesterday</div>
                        <div class="row-cells" id="row-yesterday"></div>
                    </div>
                    <div class="grid-row">
                        <div class="row-label">Today</div>
                        <div class="row-cells" id="row-today"></div>
                    </div>
                </div>
            </div>

            <!-- Incidents Box -->
            <div class="box box-default">
                <div class="box-header with-border">
                    <h3 class="box-title"><i class="fas fa-exclamation-triangle"></i> Recent Events & Outages Log</h3>
                </div>
                <div class="box-body" id="incident-list">
                    <div class="text-center text-muted" style="padding: 10px;">
                        No incidents logged in the last 72 hours.
                    </div>
                </div>
            </div>
        </section>
    </div>

    <!-- Main Footer -->
    <footer class="main-footer">
        <div class="text-center">
            <a href="https://github.com/psinx/InternetHealthCheck" target="_blank" rel="noopener noreferrer">
                <i class="fab fa-github"></i> <strong>Internet Health Check</strong>
            </a>
            — Open-source extension for Pi-hole v6
        </div>
    </footer>
</div>

<script>
    (function() {
        function pad(n) {
            return n < 10 ? '0' + n : '' + n;
        }

        function formatHourRange(h) {
            const start = pad(h) + ':00';
            const end = pad((h + 1) % 24) + ':00';
            return start + ' - ' + end;
        }

        function getDisplayDate(label, dateStr) {
            if (dateStr) return dateStr;
            const now = new Date();
            if (label === 'Yesterday') {
                now.setDate(now.getDate() - 1);
            } else if (label === '2 Days Ago') {
                now.setDate(now.getDate() - 2);
            }
            const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
            return now.getDate() + ' ' + months[now.getMonth()];
        }

        function escapeHTML(str) {
            if (str === null || str === undefined) return '';
            return String(str)
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;')
                .replace(/'/g, '&#039;');
        }

        // Relative Freshness State
        let lastDataTimestamp = null;

        function updateFreshnessTicker() {
            const el = document.getElementById('header-last-updated');
            if (!el || !lastDataTimestamp) return;

            const diffSeconds = Math.max(0, Math.floor((Date.now() - lastDataTimestamp) / 1000));
            let text = '';
            if (diffSeconds < 10) {
                text = 'Updated: just now';
            } else if (diffSeconds < 60) {
                text = 'Updated: ' + diffSeconds + 's ago';
            } else if (diffSeconds < 3600) {
                const mins = Math.floor(diffSeconds / 60);
                text = 'Updated: ' + mins + 'm ago';
            } else {
                const hours = Math.floor(diffSeconds / 3600);
                text = 'Updated: ' + hours + 'h ago';
            }

            if (diffSeconds >= 900) {
                el.className = 'label label-warning';
                el.textContent = '! ' + text + ' (Stale)';
            } else {
                el.className = 'text-muted';
                el.textContent = text;
            }
        }

        // Floating Tooltip Element
        let tooltipEl = null;

        function getOrCreateTooltip() {
            if (!tooltipEl) {
                tooltipEl = document.createElement('div');
                tooltipEl.id = 'grid-custom-tooltip';
                tooltipEl.style.cssText = 'position: absolute; display: none; background: #222d32; color: #fff; padding: 8px 12px; border-radius: 6px; font-size: 12px; box-shadow: 0 4px 14px rgba(0,0,0,0.4); z-index: 9999; pointer-events: none; white-space: nowrap; transition: opacity 0.15s ease-in-out; border: 1px solid #4b646f;';
                document.body.appendChild(tooltipEl);
            }
            return tooltipEl;
        }

        function renderMiniChainHtml(hourData, dayLabel, timeRange) {
            const safeDay = escapeHTML(dayLabel);
            const safeTime = escapeHTML(timeRange);

            if (hourData.status === 'INACTIVE') {
                let html = '<div style="font-weight: bold; margin-bottom: 6px; border-bottom: 1px solid #4b646f; padding-bottom: 4px; display: flex; justify-content: space-between; align-items: center; gap: 15px;">' +
                           '<span>' + safeDay + ' ' + safeTime + '</span>' +
                           '<span class="label label-default">● Pending</span>' +
                           '</div>';
                html += '<div style="font-size: 11px; color: #8a8a8a; margin-top: 4px; text-align: center; background: #1a2226; padding: 6px 8px; border-radius: 4px;">' +
                        'Monitoring slot pending' +
                        '</div>';
                return html;
            }

            const isOk = hourData.status === 'OK';
            const piOk = isOk ? true : (hourData.pihole !== false);
            const dnsOk = isOk ? true : (hourData.dnscrypt !== false);
            const cfOk = isOk ? true : (hourData.cloudflare !== false);

            const badgeClass = isOk ? 'label label-success' : (hourData.status === 'DANGER' ? 'label label-danger' : (hourData.status === 'WARNING' ? 'label label-warning' : 'label label-default'));
            const badgeSymbol = isOk ? '✓ ' : (hourData.status === 'DANGER' ? '✕ ' : '! ');
            const badgeText = isOk ? '100% Operational' : (hourData.status === 'DANGER' ? 'Outage' : escapeHTML(hourData.status));

            const piStyle = piOk ? 'color: #00a65a;' : 'color: #dd4b39;';
            const dnsStyle = dnsOk ? 'color: #00a65a;' : 'color: #dd4b39;';
            const cfStyle = cfOk ? 'color: #00a65a;' : 'color: #dd4b39;';

            const piLabel = 'Pi-hole (' + (piOk ? '✓ OK' : '✕ FAIL') + ')';
            const dnsLabel = 'dnscrypt (' + (dnsOk ? '✓ OK' : '✕ FAIL') + ')';
            const cfLabel = 'Cloudflare (' + (cfOk ? '✓ OK' : '✕ FAIL') + ')';

            let html = '<div style="font-weight: bold; margin-bottom: 6px; border-bottom: 1px solid #4b646f; padding-bottom: 4px; display: flex; justify-content: space-between; align-items: center; gap: 15px;">' +
                       '<span>' + safeDay + ' ' + safeTime + '</span>' +
                       '<span class="' + badgeClass + '">' + badgeSymbol + badgeText + '</span>' +
                       '</div>';

            html += '<div style="display: flex; align-items: center; gap: 6px; margin: 6px 0; background: #1a2226; padding: 5px 8px; border-radius: 4px; font-family: monospace; font-size: 11px;">' +
                    '<span style="color: #00a65a; font-weight: bold;">Client</span>' +
                    '<span style="color: #777;">&rarr;</span>' +
                    '<span style="' + piStyle + ' font-weight: bold;">' + piLabel + '</span>' +
                    '<span style="color: #777;">&rarr;</span>' +
                    '<span style="' + dnsStyle + ' font-weight: bold;">' + dnsLabel + '</span>' +
                    '<span style="color: #777;">&rarr;</span>' +
                    '<span style="' + cfStyle + ' font-weight: bold;">' + cfLabel + '</span>' +
                    '</div>';

            if (!isOk) {
                const ifaceText = escapeHTML(hourData.iface ? hourData.iface : 'eth0, wlan0');
                html += '<div style="font-size: 11px; color: #f39c12; margin-top: 4px;">Affected Interface(s): <strong>' + ifaceText + '</strong></div>';
                if (hourData.earliest_issue) {
                    html += '<div style="font-size: 11px; color: #b8c7ce; margin-top: 2px;">First issue at <strong>' + escapeHTML(hourData.earliest_issue) + '</strong></div>';
                }
            } else {
                html += '<div style="font-size: 11px; color: #b8c7ce; margin-top: 4px;">Tested Interfaces: <strong>eth0, wlan0</strong></div>';
            }

            return html;
        }

        function attachTooltipEvents(cell, hourData, dayLabel, timeRange) {
            cell.addEventListener('mouseenter', function(e) {
                const tip = getOrCreateTooltip();
                tip.innerHTML = renderMiniChainHtml(hourData, dayLabel, timeRange);
                tip.style.display = 'block';
                tip.style.opacity = '1';
                positionTooltip(e);
            });

            cell.addEventListener('mousemove', function(e) {
                positionTooltip(e);
            });

            cell.addEventListener('mouseleave', function() {
                if (tooltipEl) {
                    tooltipEl.style.opacity = '0';
                    tooltipEl.style.display = 'none';
                }
            });
        }

        function positionTooltip(e) {
            if (!tooltipEl) return;
            const x = e.pageX;
            const y = e.pageY - 55;
            tooltipEl.style.left = (x - (tooltipEl.offsetWidth / 2)) + 'px';
            tooltipEl.style.top = y + 'px';
        }

        function renderEmptyGrid() {
            const rows = ['row-2daysago', 'row-yesterday', 'row-today'];
            const labels = { 'row-today': 'Today', 'row-yesterday': 'Yesterday', 'row-2daysago': '2 Days Ago' };
            rows.forEach(rowId => {
                const container = document.getElementById(rowId);
                if (!container) return;
                container.innerHTML = '';
                const dayLabel = getDisplayDate(labels[rowId]);
                for (let h = 0; h < 24; h++) {
                    const cell = document.createElement('div');
                    cell.className = 'hour-cell hour-inactive';
                    const timeRange = formatHourRange(h);
                    const defaultData = { status: 'INACTIVE', pihole: true, dnscrypt: true, cloudflare: true };
                    attachTooltipEvents(cell, defaultData, dayLabel, timeRange);
                    container.appendChild(cell);
                }
            });
        }

        async function refreshDashboard() {
            const paths = ['/health/status.json', 'status.json', '/status.json', '/dev/shm/status.json'];
            let data = null;
            for (const path of paths) {
                try {
                    const res = await fetch(path + '?t=' + Date.now());
                    if (res.ok) {
                        data = await res.json();
                        break;
                    }
                } catch (e) {}
            }
            if (data) updateUI(data);
        }

        function updateUI(data) {
            if (data.timestamp) {
                const parsed = new Date(data.timestamp);
                if (!isNaN(parsed.getTime())) {
                    lastDataTimestamp = parsed.getTime();
                    updateFreshnessTicker();
                }
            }

            let activeStatus = (data.status === 'Operational' || data.status === 'Healthy') ? 'Healthy' : (data.status || 'Healthy');
            if (data.interfaces) {
                const ethOk = !data.interfaces.eth0 || !data.interfaces.eth0.exists || (data.interfaces.eth0.connectivity === 'OK' && data.interfaces.eth0.dns_ok !== false);
                const wlanOk = !data.interfaces.wlan0 || !data.interfaces.wlan0.exists || (data.interfaces.wlan0.connectivity === 'OK');
                activeStatus = (ethOk && wlanOk) ? 'Healthy' : 'Degraded';
                if (data.interfaces.eth0 && data.interfaces.eth0.connectivity === 'DOWN' && 
                    (!data.interfaces.wlan0 || !data.interfaces.wlan0.exists || data.interfaces.wlan0.connectivity === 'DOWN')) {
                    activeStatus = 'Outage';
                }
            }
            const headerLabel = document.getElementById('header-status-label');
            if (headerLabel) {
                let symbol = '●';
                if (activeStatus === 'Healthy') {
                    headerLabel.className = 'label label-success';
                    symbol = '✓';
                } else if (activeStatus === 'Degraded' || activeStatus === 'Partial Outage' || activeStatus === 'DNS Issues') {
                    headerLabel.className = 'label label-warning';
                    symbol = '!';
                } else {
                    headerLabel.className = 'label label-danger';
                    symbol = '✕';
                }
                headerLabel.textContent = symbol + ' STATUS: ' + activeStatus;
            }

            let activeIface = null;
            if (data.interfaces) {
                if (data.interfaces.eth0 && data.interfaces.eth0.exists) activeIface = data.interfaces.eth0;
                else if (data.interfaces.wlan0 && data.interfaces.wlan0.exists) activeIface = data.interfaces.wlan0;
                
                const clientDesc = document.getElementById('node-client-desc');
                const clientNode = document.getElementById('node-client');
                if (clientDesc && clientNode) {
                    const eth = data.interfaces.eth0;
                    const wlan = data.interfaces.wlan0;
                    let parts = [];
                    let anyOnline = false;
                    let allOnline = true;
                    if (eth && eth.exists) {
                        const isOnline = (eth.connectivity === 'OK');
                        parts.push('eth0: ' + (isOnline ? '✓ Online' : '✕ Down'));
                        if (isOnline) anyOnline = true;
                        else allOnline = false;
                    }
                    if (wlan && wlan.exists) {
                        const isOnline = (wlan.connectivity === 'OK');
                        parts.push('wlan0: ' + (isOnline ? '✓ Online' : '✕ Down'));
                        if (isOnline) anyOnline = true;
                        else allOnline = false;
                    }
                    clientDesc.innerHTML = parts.length > 0 ? parts.join('<br>') : 'Local Machine (Active)';
                    if (allOnline) {
                        clientNode.className = 'chain-node node-ok';
                    } else if (anyOnline) {
                        clientNode.className = 'chain-node node-warning';
                    } else {
                        clientNode.className = 'chain-node node-fail';
                    }
                }

                updateInterfaceRow('if-eth', data.interfaces.eth0);
                updateInterfaceRow('if-wlan', data.interfaces.wlan0);
                
                if (activeIface) {
                    const lossVal = activeIface.packet_loss !== undefined ? activeIface.packet_loss : 0.0;
                    const lossEl = document.getElementById('if-loss');
                    if (lossEl) {
                        const lossSym = (lossVal === 0.0) ? '✓ ' : ((lossVal < 50.0) ? '! ' : '✕ ');
                        lossEl.textContent = lossSym + lossVal.toFixed(1) + '%';
                        if (lossVal === 0.0) {
                            lossEl.className = 'label label-success';
                        } else if (lossVal < 50.0) {
                            lossEl.className = 'label label-warning';
                        } else {
                            lossEl.className = 'label label-danger';
                        }
                    }
                }
            }

            // Always update the DNS chain nodes and latencies even during outages
            if (activeIface) {
                const isConnOk = (activeIface.connectivity === 'OK');
                const upstreamIp = (activeIface && activeIface.upstream_ip) ? activeIface.upstream_ip : '1.1.1.3';
                
                updateNodeState('node-pihole', 'node-pihole-desc', activeIface.pihole, '127.0.0.1:53');
                updateNodeState('node-dnscrypt', 'node-dnscrypt-desc', activeIface.dnscrypt, '127.0.0.1:5053');
                
                // Cloudflare upstream fails if either cloudflare check failed OR internet ping is DOWN
                const cfOk = (activeIface.cloudflare && isConnOk);
                updateNodeState('node-cloudflare', 'node-cloudflare-desc', cfOk, upstreamIp + ':53');
                
                updateArrowState('arrow-1', activeIface.pihole);
                updateArrowState('arrow-2', activeIface.dnscrypt);
                updateArrowState('arrow-3', cfOk);

                updateLatencyText('lat-pi', activeIface.latency_pihole);
                updateLatencyText('lat-dns', activeIface.latency_dnscrypt);
                updateLatencyText('lat-cf', isConnOk ? activeIface.latency_cloudflare : -1);
            }

            if (data.history) renderHistoricalGrid(data.history);
            if (data.incidents) renderIncidentsList(data.incidents);

            if (data.sla_percentage !== undefined) {
                const slaEl = document.getElementById('grid-uptime-pct');
                if (slaEl) {
                    const val = Number(data.sla_percentage);
                    let sym = '✓';
                    if (val < 95.0) {
                        slaEl.className = 'label label-danger';
                        sym = '✕';
                    } else if (val < 99.0) {
                        slaEl.className = 'label label-warning';
                        sym = '!';
                    } else {
                        slaEl.className = 'label label-success';
                        sym = '✓';
                    }
                    slaEl.textContent = sym + ' SLA: ' + val.toFixed(2) + '%';
                }
            }
        }

        function updateInterfaceRow(elementId, iface) {
            const el = document.getElementById(elementId);
            if (!el) return;
            if (!iface || !iface.exists) { el.textContent = '● Inactive'; el.className = 'label label-default'; }
            else if (iface.connectivity === 'DOWN') { el.textContent = '✕ Offline'; el.className = 'label label-danger'; }
            else if (iface.dns_ok === false) { el.textContent = '! DNS Issue'; el.className = 'label label-warning'; }
            else { el.textContent = '✓ Online'; el.className = 'label label-success'; }
        }

        function updateNodeState(nodeId, descId, isOk, portLabel) {
            const nodeEl = document.getElementById(nodeId);
            const descEl = document.getElementById(descId);
            if (!nodeEl || !descEl) return;
            nodeEl.className = isOk ? 'chain-node node-ok' : 'chain-node node-fail';
            descEl.textContent = portLabel + (isOk ? ' (✓ OK)' : ' (✕ FAIL)');
        }

        function updateArrowState(arrowId, isOk) {
            const arrowEl = document.getElementById(arrowId);
            if (!arrowEl) return;
            arrowEl.className = isOk ? 'connector-arrow arrow-ok' : 'connector-arrow arrow-fail';
        }

        function updateLatencyText(elId, val) {
            const el = document.getElementById(elId);
            if (!el) return;
            if (val === undefined || val === -1 || val === null) {
                el.textContent = '✕ TIMEOUT'; el.className = 'label label-danger';
            } else if (val > 150) {
                el.textContent = '✕ ' + val + 'ms'; el.className = 'label label-danger';
            } else if (val > 60) {
                el.textContent = '! ' + val + 'ms'; el.className = 'label label-warning';
            } else {
                el.textContent = '✓ ' + val + 'ms'; el.className = 'label label-success';
            }
        }

        function renderHistoricalGrid(history) {
            const containerIds = { 'Today': 'row-today', 'Yesterday': 'row-yesterday', '2 Days Ago': 'row-2daysago' };
            history.forEach(row => {
                const containerId = containerIds[row.label];
                if (!containerId) return;
                const container = document.getElementById(containerId);
                if (!container) return;
                container.innerHTML = '';
                const dayLabel = getDisplayDate(row.label, row.date);
                row.hours.forEach(hourData => {
                    const cell = document.createElement('div');
                    let cellClass = 'hour-cell';
                    if (hourData.status === 'OK') cellClass += ' hour-ok';
                    else if (hourData.status === 'WARNING') cellClass += ' hour-warning';
                    else if (hourData.status === 'DANGER') cellClass += ' hour-danger';
                    else cellClass += ' hour-inactive';
                    cell.className = cellClass;
                    
                    const timeRange = formatHourRange(hourData.hour);
                    attachTooltipEvents(cell, hourData, dayLabel, timeRange);
                    
                    container.appendChild(cell);
                });
            });
        }

        function renderIncidentsList(incidents) {
            const container = document.getElementById('incident-list');
            if (!container) return;
            if (!incidents || incidents.length === 0) {
                container.innerHTML = '<div class="text-center text-muted" style="padding: 10px;">No incidents logged in the last 72 hours.</div>';
                return;
            }
            container.innerHTML = '';
            incidents.forEach(item => {
                const row = document.createElement('div');
                row.style.cssText = 'padding: 8px 10px; border-bottom: 1px dashed rgba(128,128,128,0.3); font-size: 0.95em;';
                const isOutage = item.badge === 'Outage';
                
                const badge = document.createElement('span');
                badge.className = isOutage ? 'label label-danger' : 'label label-warning';
                badge.style.marginRight = '8px';
                badge.textContent = (isOutage ? '✕ ' : '! ') + (item.badge || 'Event');
                
                const ts = document.createElement('strong');
                ts.textContent = item.timestamp || '';
                
                const sep = document.createTextNode(' — ');
                
                const desc = document.createElement('span');
                desc.style.opacity = '0.85';
                desc.textContent = item.description || '';
                
                row.appendChild(badge);
                row.appendChild(ts);
                row.appendChild(sep);
                row.appendChild(desc);
                container.appendChild(row);
            });
        }

        renderEmptyGrid();

        // Inline initial JSON injection to ensure instant, zero-flicker UI render
        const initialData = <?
        local sf = io.open("/var/www/html/health/status.json", "r")
        if sf then
            local sc = sf:read("*all")
            sf:close()
            mg.write(sc)
        else
            mg.write("null")
        end
        ?>;
        if (initialData) updateUI(initialData);

        refreshDashboard();
        setInterval(refreshDashboard, 30000);
        setInterval(updateFreshnessTicker, 5000);
    })();
</script>
</body>
</html>
