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

        // Highlight stale data if older than 15 minutes
        if (diffSeconds >= 900) {
            el.className = 'label label-warning';
            el.textContent = text + ' (Stale)';
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
                       '<span class="label label-default">Pending</span>' +
                       '</div>';
            html += '<div style="font-size: 11px; color: #8a8a8a; margin-top: 4px; text-align: center; background: #1a2226; padding: 6px 8px; border-radius: 4px;">' +
                    'Monitoring slot pending' +
                    '</div>';
            return html;
        }

        const isOk = hourData.status === 'OK';
        // Green OK cells MUST always show 100% green OK nodes
        const piOk = isOk ? true : (hourData.pihole !== false);
        const dnsOk = isOk ? true : (hourData.dnscrypt !== false);
        const cfOk = isOk ? true : (hourData.cloudflare !== false);

        const badgeClass = isOk ? 'label label-success' : (hourData.status === 'DANGER' ? 'label label-danger' : (hourData.status === 'WARNING' ? 'label label-warning' : 'label label-default'));
        const badgeText = isOk ? '100% Operational' : (hourData.status === 'DANGER' ? 'Outage' : escapeHTML(hourData.status));

        const piStyle = piOk ? 'color: #00a65a;' : 'color: #dd4b39;';
        const dnsStyle = dnsOk ? 'color: #00a65a;' : 'color: #dd4b39;';
        const cfStyle = cfOk ? 'color: #00a65a;' : 'color: #dd4b39;';

        const piLabel = 'Pi-hole (' + (piOk ? 'OK' : 'FAIL') + ')';
        const dnsLabel = 'dnscrypt (' + (dnsOk ? 'OK' : 'FAIL') + ')';
        const cfLabel = 'Cloudflare (' + (cfOk ? 'OK' : 'FAIL') + ')';

        let html = '<div style="font-weight: bold; margin-bottom: 6px; border-bottom: 1px solid #4b646f; padding-bottom: 4px; display: flex; justify-content: space-between; align-items: center; gap: 15px;">' +
                   '<span>' + safeDay + ' ' + safeTime + '</span>' +
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
            if (activeStatus === 'Healthy') {
                headerLabel.className = 'label label-success';
            } else if (activeStatus === 'Degraded' || activeStatus === 'Partial Outage' || activeStatus === 'DNS Issues') {
                headerLabel.className = 'label label-warning';
            } else {
                headerLabel.className = 'label label-danger';
            }
            headerLabel.textContent = 'STATUS: ' + activeStatus;
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
                    parts.push('eth0: ' + (isOnline ? 'Online' : 'Down'));
                    if (isOnline) anyOnline = true;
                    else allOnline = false;
                }
                if (wlan && wlan.exists) {
                    const isOnline = (wlan.connectivity === 'OK');
                    parts.push('wlan0: ' + (isOnline ? 'Online' : 'Down'));
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
                    lossEl.textContent = lossVal.toFixed(1) + '%';
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
                if (val < 95.0) {
                    slaEl.className = 'label label-danger';
                } else if (val < 99.0) {
                    slaEl.className = 'label label-warning';
                } else {
                    slaEl.className = 'label label-success';
                }
                slaEl.textContent = 'SLA: ' + val.toFixed(2) + '%';
            }
        }
    }

    function updateInterfaceRow(elementId, iface) {
        const el = document.getElementById(elementId);
        if (!el) return;
        if (!iface || !iface.exists) { el.textContent = 'Inactive'; el.className = 'label label-default'; }
        else if (iface.connectivity === 'DOWN') { el.textContent = 'Offline'; el.className = 'label label-danger'; }
        else if (iface.dns_ok === false) { el.textContent = 'DNS Issue'; el.className = 'label label-warning'; }
        else { el.textContent = 'Online'; el.className = 'label label-success'; }
    }

    function updateNodeState(nodeId, descId, isOk, portLabel) {
        const nodeEl = document.getElementById(nodeId);
        const descEl = document.getElementById(descId);
        if (!nodeEl || !descEl) return;
        nodeEl.className = isOk ? 'chain-node node-ok' : 'chain-node node-fail';
        descEl.textContent = portLabel + (isOk ? ' (OK)' : ' (FAIL)');
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
            el.textContent = 'TIMEOUT'; el.className = 'label label-danger';
        } else if (val > 150) {
            el.textContent = val + 'ms'; el.className = 'label label-danger';
        } else if (val > 60) {
            el.textContent = val + 'ms'; el.className = 'label label-warning';
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
            badge.textContent = item.badge || 'Event';
            
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

    document.addEventListener('DOMContentLoaded', function() {
        renderEmptyGrid();
        refreshDashboard();
        setInterval(refreshDashboard, 30000);
        setInterval(updateFreshnessTicker, 5000);
    });
})();
