(function() {
    function renderEmptyGrid() {
        const rows = ['row-today', 'row-yesterday', 'row-2daysago'];
        rows.forEach(rowId => {
            const container = document.getElementById(rowId);
            if (!container) return;
            container.innerHTML = '';
            for (let h = 0; h < 24; h++) {
                const cell = document.createElement('div');
                cell.className = 'hour-cell';
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
        const activeStatus = data.status || 'Healthy';
        const headerLabel = document.getElementById('header-status-label');
        if (headerLabel) {
            headerLabel.className = activeStatus === 'Healthy' ? 'label label-success' : 'label label-danger';
            headerLabel.textContent = '● Status: ' + activeStatus;
        }

        let activeIface = null;
        if (data.interfaces) {
            if (data.interfaces.eth0 && data.interfaces.eth0.exists) activeIface = data.interfaces.eth0;
            else if (data.interfaces.wlan0 && data.interfaces.wlan0.exists) activeIface = data.interfaces.wlan0;
            
            updateInterfaceRow('if-eth', data.interfaces.eth0);
            updateInterfaceRow('if-wlan', data.interfaces.wlan0);
            
            if (activeIface) {
                const lossVal = activeIface.packet_loss !== undefined ? activeIface.packet_loss : 0.0;
                const lossEl = document.getElementById('if-loss');
                if (lossEl) {
                    lossEl.textContent = lossVal.toFixed(1) + '%';
                    lossEl.className = 'label ' + (lossVal > 0 ? 'label-danger' : 'label-success');
                }
            }
        }

        if (activeIface && activeIface.connectivity === 'OK') {
            const upstreamIp = (activeIface && activeIface.upstream_ip) ? activeIface.upstream_ip : '1.1.1.3';
            updateNodeState('node-pihole', 'node-pihole-desc', activeIface.pihole, '127.0.0.1:53');
            updateNodeState('node-dnscrypt', 'node-dnscrypt-desc', activeIface.dnscrypt, '127.0.0.1:5053');
            updateNodeState('node-cloudflare', 'node-cloudflare-desc', activeIface.cloudflare, upstreamIp + ':53');
            
            updateLatencyText('lat-pi', activeIface.latency_pihole);
            updateLatencyText('lat-dns', activeIface.latency_dnscrypt);
            updateLatencyText('lat-cf', activeIface.latency_cloudflare);
        }

        if (data.history) renderHistoricalGrid(data.history);

        if (data.sla_percentage !== undefined) {
            const slaEl = document.getElementById('grid-uptime-pct');
            if (slaEl) slaEl.textContent = data.sla_percentage.toFixed(2) + '% SLA';
        }
    }

    function updateInterfaceRow(elementId, iface) {
        const el = document.getElementById(elementId);
        if (!el) return;
        if (!iface || !iface.exists) { el.textContent = 'Inactive'; el.className = 'label label-default'; }
        else if (iface.connectivity === 'DOWN') { el.textContent = 'Offline'; el.className = 'label label-danger'; }
        else { el.textContent = 'Online'; el.className = 'label label-success'; }
    }

    function updateNodeState(nodeId, descId, isOk, portLabel) {
        const nodeEl = document.getElementById(nodeId);
        const descEl = document.getElementById(descId);
        if (!nodeEl || !descEl) return;
        nodeEl.className = isOk ? 'chain-node' : 'chain-node node-fail';
        descEl.textContent = portLabel + (isOk ? ' (OK)' : ' (FAIL)');
    }

    function updateLatencyText(elId, val) {
        const el = document.getElementById(elId);
        if (!el) return;
        if (val === undefined || val === -1 || val === null) {
            el.textContent = 'TIMEOUT'; el.className = 'label label-danger';
        } else {
            el.textContent = val + 'ms'; el.className = 'label label-success';
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
            row.hours.forEach(hourData => {
                const cell = document.createElement('div');
                let cellClass = 'hour-cell';
                if (hourData.status === 'WARNING') cellClass += ' hour-warning';
                else if (hourData.status === 'DANGER') cellClass += ' hour-danger';
                else if (hourData.status !== 'OK') cellClass += ' hour-inactive';
                cell.className = cellClass;
                container.appendChild(cell);
            });
        });
    }

    document.addEventListener('DOMContentLoaded', function() {
        renderEmptyGrid();
        refreshDashboard();
        setInterval(refreshDashboard, 30000);
    });
})();
