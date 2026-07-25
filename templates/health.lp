<?
mg.include("scripts/lua/header_authenticated.lp","r")
?>

<script src="/admin/scripts/js/health.js"></script>

<style>
    /* 72h Uptime Grid Styling in Native Darker Theme */
    .grid-row { display: flex; align-items: center; gap: 10px; margin-bottom: 8px; }
    .row-label { width: 100px; font-weight: bold; color: #aaa; font-size: 0.9em; }
    .row-cells { display: flex; gap: 3px; flex-grow: 1; }
    .hour-cell { flex: 1; height: 22px; background-color: #00a65a; border-radius: 3px; transition: transform 0.15s; }
    .hour-cell:hover { transform: scaleY(1.2); }
    .hour-cell.hour-warning { background-color: #f39c12; }
    .hour-cell.hour-danger { background-color: #dd4b39; }
    .hour-cell.hour-inactive { background-color: #444; opacity: 0.4; }
    
    /* DNS Chain Node Styling */
    .chain-flow { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 10px 0; }
    .chain-node { background: rgba(0, 0, 0, 0.2); border: 2px solid #00a65a; border-radius: 6px; padding: 12px 16px; flex: 1; text-align: center; }
    .chain-node.node-fail { border-color: #dd4b39; }
    .node-name { font-weight: bold; font-size: 1.1em; color: #fff; }
    .node-status-desc { font-size: 0.85em; color: #aaa; font-family: monospace; }
    .connector-arrow { font-size: 1.4em; color: #00a65a; font-weight: bold; }
</style>

<!-- Main Header -->
<section class="content-header" style="padding-bottom: 15px;">
    <h1>
        Internet Health Diagnostics
        <small>Real-time DNS Chain & SLA Uptime</small>
    </h1>
</section>

<section class="content">
    <!-- Live DNS Chain Box -->
    <div class="box box-success">
        <div class="box-header with-border">
            <h3 class="box-title"><i class="fas fa-network-wired"></i> Live DNS Chain Diagnostics</h3>
            <div class="box-tools pull-right">
                <span id="header-status-label" class="label label-success" style="font-size: 0.9em;">● Status: Operational</span>
            </div>
        </div>
        <div class="box-body">
            <div class="chain-flow">
                <div id="node-client" class="chain-node">
                    <div class="node-name">CLIENT</div>
                    <div class="node-status-desc">Local Machine (Active)</div>
                </div>
                <div id="arrow-1" class="connector-arrow">&rarr;</div>
                <div id="node-pihole" class="chain-node">
                    <div class="node-name">Pi-hole</div>
                    <div id="node-pihole-desc" class="node-status-desc">127.0.0.1:53 (OK)</div>
                </div>
                <div id="arrow-2" class="connector-arrow">&rarr;</div>
                <div id="node-dnscrypt" class="chain-node">
                    <div class="node-name">dnscrypt-proxy</div>
                    <div id="node-dnscrypt-desc" class="node-status-desc">127.0.0.1:5053 (OK)</div>
                </div>
                <div id="arrow-3" class="connector-arrow">&rarr;</div>
                <div id="node-cloudflare" class="chain-node">
                    <div class="node-name">Cloudflare (DoH)</div>
                    <div id="node-cloudflare-desc" class="node-status-desc">1.1.1.1:53 (OK)</div>
                </div>
            </div>
        </div>
    </div>

    <!-- 72h Uptime Grid Box -->
    <div class="box box-primary">
        <div class="box-header with-border">
            <h3 class="box-title"><i class="fas fa-history"></i> Historical Uptime (Last 72 Hours)</h3>
            <div class="box-tools pull-right">
                <span id="grid-uptime-pct" class="label label-success" style="font-size: 0.9em;">100% SLA</span>
            </div>
        </div>
        <div class="box-body">
            <div class="grid-row">
                <div class="row-label">Today</div>
                <div class="row-cells" id="row-today"></div>
            </div>
            <div class="grid-row">
                <div class="row-label">Yesterday</div>
                <div class="row-cells" id="row-yesterday"></div>
            </div>
            <div class="grid-row">
                <div class="row-label">2 Days Ago</div>
                <div class="row-cells" id="row-2daysago"></div>
            </div>
        </div>
    </div>

    <!-- Stat Boxes Row -->
    <div class="row">
        <div class="col-md-6">
            <div class="box box-info">
                <div class="box-header with-border">
                    <h3 class="box-title"><i class="fas fa-tachometer-alt"></i> Hop Latency Benchmark</h3>
                </div>
                <div class="box-body">
                    <table class="table table-bordered">
                        <tr><td>Pi-hole DNS Hop</td><td><span id="lat-pi" class="label label-success">4ms</span></td></tr>
                        <tr><td>dnscrypt-proxy Hop</td><td><span id="lat-dns" class="label label-success">0ms</span></td></tr>
                        <tr><td>Cloudflare Upstream</td><td><span id="lat-cf" class="label label-success">16ms</span></td></tr>
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
                        <tr><td>Wired Link (eth0)</td><td><span id="if-eth" class="label label-success">Online</span></td></tr>
                        <tr><td>Wireless Link (wlan0)</td><td><span id="if-wlan" class="label label-success">Online</span></td></tr>
                        <tr><td>Packet Loss (Ping)</td><td><span id="if-loss" class="label label-success">0.0%</span></td></tr>
                    </table>
                </div>
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

<?
mg.include("scripts/lua/footer.lp","r")
?>
<script src="/admin/scripts/js/health.js"></script>
