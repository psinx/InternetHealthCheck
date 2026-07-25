(function() {
    function pad(n) {
        return n < 10 ? '0' + n : '' + n;
    }

    function formatHourRange(h) {
        const start = pad(h) + ':00';
        const end = pad((h + 1) % 24) + ':00';
        return start + ' - ' + end;
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
        let piOk = hourData.pihole !== undefined ? hourData.pihole : (hourData.status === 'OK');
        let dnsOk = hourData.dnscrypt !== undefined ? hourData.dnscrypt : (hourData.status === 'OK');
        let cfOk = hourData.cloudflare !== undefined ? hourData.cloudflare : (hourData.status === 'OK');

        // Safety fallback: if status is DANGER and node states were all true, mark all false for general outage
        if (hourData.status === 'DANGER' && piOk && dnsOk && cfOk) {
            piOk = false;
            dnsOk = false;
            cfOk = false;
        }

        const badgeClass = hourData.status === 'OK' ? 'label label-success' : (hourData.status === 'DANGER' ? 'label label-danger' : (hourData.status === 'WARNING' ? 'label label-warning' : 'label label-default'));
        const badgeText = hourData.status === 'OK' ? '100% Operational' : (hourData.status === 'DANGER' ? 'Outage' : (hourData.status === 'INACTIVE' ? 'Pending' : hourData.status));

        const piStyle = piOk ? 'color: #00a65a;' : 'color: #dd4b39;';
        const dnsStyle = dnsOk ? 'color: #00a65a;' : 'color: #dd4b39;';
        const cfStyle = cfOk ? 'color: #00a65a;' : 'color: #dd4b39;';

        const piLabel = 'Pi-hole (' + (piOk ? 'OK' : 'FAIL') + ')';
        const dnsLabel = 'dnscrypt (' + (dnsOk ? 'OK' : 'FAIL') + ')';
        const cfLabel = 'Cloudflare (' + (cfOk ? 'OK' : 'FAIL') + ')';

        let html = '<div style="font-weight: bold; margin-bottom: 6px; border-bottom: 1px solid #4b646f; padding-bottom: 4px; display: flex; justify-content: space-between; align-items: center; gap: 15px;">' +
                   '<span>' + dayLabel + ' ' + timeRange + '</span>' +
                   '<span class="' + badgeClass + '">' + badgeText + '</span>' +
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

        if (hourData.earliest_issue) {
            html += '<div style="font-size: 11px; color: #b8c7ce; margin-top: 4px;">First issue detected at <strong>' + hourData.earliest_issue + '</strong></div>';
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
            for (let h = 0; h < 24; h++) {
                const cell = document.createElement('div');
                cell.className = 'hour-cell';
                const timeRange = formatHourRange(h);
                const defaultData = { status: 'OK', pihole: true, dnscrypt: true, cloudflare: true };
                attachTooltipEvents(cell, defaultData, labels[rowId], timeRange);
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

        if (data.incidents) renderIncidentsList(data.incidents);

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
                else if (hourData.status === 'INACTIVE') cellClass += ' hour-inactive';
                cell.className = cellClass;
                
                const timeRange = formatHourRange(hourData.hour);
                attachTooltipEvents(cell, hourData, row.label, timeRange);
                
                container.appendChild(cell);
            });
        });
    }

    function renderIncidentsList(incidents) {
        const container = document.getElementById('incident-list');
        if (!container) return;
        if (!incidents || incidents.length === 0) {
            container.innerHTML = '<div class="text-center text-muted" style="padding: 10px; color: #777;">No incidents logged in the last 72 hours.</div>';
            return;
        }
        container.innerHTML = '';
        incidents.forEach(item => {
            const row = document.createElement('div');
            row.style.cssText = 'padding: 8px 10px; border-bottom: 1px dashed #eee; font-size: 0.95em;';
            const badgeClass = item.badge === 'Outage' ? 'label label-danger' : 'label label-warning';
            row.innerHTML = '<span class="' + badgeClass + '" style="margin-right: 8px;">' + item.badge + '</span>' +
                            '<strong style="color: #333;">' + item.timestamp + '</strong> — ' +
                            '<span style="color: #555;">' + item.description + '</span>';
            container.appendChild(row);
        });
    }

    document.addEventListener('DOMContentLoaded', function() {
        renderEmptyGrid();
        refreshDashboard();
        setInterval(refreshDashboard, 30000);
    });
})();
