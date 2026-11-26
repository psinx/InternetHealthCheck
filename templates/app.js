(function() {
    function pad(n) {
        return n < 10 ? '0' + n : '' + n;
    }

    function formatHourRange(h) {
        const start = pad(h) + ':00';
        const end = pad((h + 1) % 24) + ':00';
        return start + ' - ' + end;
    }

    function getQuarterFillPct(minutes) {
        const m = Math.max(0, Math.min(59, Number(minutes) || 0));
        if (m < 15) return 25;
        if (m < 30) return 50;
        if (m < 45) return 75;
        return 90;
    }

    function getCurrentHourFillPct(rowLabel, hourData) {
        if (!hourData || hourData.status === 'INACTIVE') return null;
        const isCurrent = hourData.is_current === true ||
            (hourData.is_current === undefined && rowLabel === 'Today' && hourData.hour === new Date().getHours());
        if (!isCurrent) return null;
        const mins = typeof hourData.elapsed_minutes === 'number'
            ? hourData.elapsed_minutes
            : new Date().getMinutes();
        return getQuarterFillPct(mins);
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

    function isWirelessName(name) {
        return /^(wlan|wlp|wlo|wlx|wifi|ath)/i.test(name);
    }

    function formatRelativeAge(timestampMs) {
        const diffSeconds = Math.max(0, Math.floor((Date.now() - timestampMs) / 1000));
        if (diffSeconds < 10) return { text: 'just now', stale: false };
        if (diffSeconds < 60) return { text: diffSeconds + 's ago', stale: false };
        if (diffSeconds < 3600) {
            return { text: Math.floor(diffSeconds / 60) + 'm ago', stale: diffSeconds >= 900 };
        }
        return { text: Math.floor(diffSeconds / 3600) + 'h ago', stale: true };
    }

    let lastDataTimestamp = null;
    let lastCanaryTimestamp = null;
    let currentMetadata = {};
    let lastDashboardData = null;
    let lastCanaryData = null;

    function updateFreshnessTicker() {
        const el = document.getElementById('header-last-updated');
        if (el && lastDataTimestamp) {
            const age = formatRelativeAge(lastDataTimestamp);
            if (age.stale) {
                el.className = 'label label-warning';
                el.textContent = 'Updated: ' + age.text + ' (Stale)';
            } else {
                el.className = 'text-muted';
                el.textContent = 'Updated: ' + age.text;
            }
            if (lastDashboardData) {
                renderRemediationGuide(lastDashboardData, lastCanaryData);
            }
        }
        const canaryEl = document.getElementById('canary-last-updated');
        if (canaryEl && lastCanaryTimestamp) {
            const cAge = formatRelativeAge(lastCanaryTimestamp);
            if (cAge.stale) {
                canaryEl.className = 'label label-warning';
                canaryEl.textContent = 'Updated: ' + cAge.text + ' (Stale)';
            } else {
                canaryEl.className = 'text-muted';
                canaryEl.textContent = 'Updated: ' + cAge.text;
            }
        }
    }

    let tooltipEl = null;
    let pinnedCell = null;

    function getOrCreateTooltip() {
        if (!tooltipEl) {
            tooltipEl = document.createElement('div');
            tooltipEl.id = 'grid-custom-tooltip';
            tooltipEl.setAttribute('role', 'tooltip');
            tooltipEl.style.cssText = 'position: absolute; display: none; background: #222d32; color: #fff; padding: 10px 12px; border-radius: 6px; font-size: 12px; box-shadow: 0 4px 16px rgba(0,0,0,0.45); z-index: 9999; pointer-events: none; max-width: min(460px, calc(100vw - 16px)); width: max-content; transition: opacity 0.15s ease-in-out; border: 1px solid #4b646f;';
            document.body.appendChild(tooltipEl);
        }
        return tooltipEl;
    }

    function hideTooltip() {
        pinnedCell = null;
        if (tooltipEl) {
            tooltipEl.style.opacity = '0';
            tooltipEl.style.display = 'none';
        }
    }

    function positionTooltipForCell(cell) {
        if (!tooltipEl || !cell) return;
        const rect = cell.getBoundingClientRect();
        const tipWidth = tooltipEl.offsetWidth || 300;
        const tipHeight = tooltipEl.offsetHeight || 110;
        const scrollX = window.pageXOffset || document.documentElement.scrollLeft || 0;
        const scrollY = window.pageYOffset || document.documentElement.scrollTop || 0;

        let left = rect.left + (rect.width / 2) - (tipWidth / 2);
        const minLeft = 8;
        const maxLeft = Math.max(minLeft, window.innerWidth - tipWidth - 8);
        left = Math.max(minLeft, Math.min(left, maxLeft));

        let top;
        if (rect.top >= tipHeight + 14) {
            top = rect.top + scrollY - tipHeight - 10;
        } else {
            top = rect.bottom + scrollY + 10;
        }

        tooltipEl.style.left = (left + scrollX) + 'px';
        tooltipEl.style.top = top + 'px';
    }

    function renderHopSpan(label, state, slow) {
        if (state === null || state === undefined) {
            return '<span style="color: #9aaeb7;">' + escapeHTML(label) + ' (Untested)</span>';
        }
        if (state === false) {
            return '<span style="color: #ff6b5b; font-weight: bold;">' + escapeHTML(label) + ' (FAIL)</span>';
        }
        if (slow) {
            return '<span style="color: #f39c12; font-weight: bold;">' + escapeHTML(label) + ' (SLOW)</span>';
        }
        return '<span style="color: #2ecc71; font-weight: bold;">' + escapeHTML(label) + ' (OK)</span>';
    }

    function getTooltipFixHint(hourData) {
        if (!hourData || hourData.status === 'OK' || hourData.status === 'INACTIVE') return '';
        const slowSet = new Set(Array.isArray(hourData.slow_hops) ? hourData.slow_hops : []);
        if (hourData.client_ok === false) {
            return 'Suggested check: Inspect Ethernet cable / switch link or router DHCP lease.';
        }
        if (hourData.pihole === false) {
            return 'Suggested check: Run systemctl status pihole-FTL or inspect /var/log/pihole/FTL.log.';
        }
        if (!currentMetadata.skip_dnscrypt && hourData.dnscrypt === false) {
            return 'Suggested check: Restart dnscrypt-proxy & check DoH logs via journalctl -u dnscrypt-proxy.';
        }
        if (hourData.cloudflare === false) {
            return 'Suggested check: Verify ISP WAN link, modem status, and outbound port 53/443.';
        }
        if (slowSet.has('pihole')) {
            return 'Suggested check: Review Pi-hole Query Log for client floods, DB size, or SD card I/O wait.';
        }
        if (slowSet.has('dnscrypt')) {
            return 'Suggested check: Check dnscrypt-proxy DoH resolver latency in dnscrypt-proxy.toml.';
        }
        if (slowSet.has('cloudflare')) {
            return 'Suggested check: Inspect ISP / WAN congestion or upstream resolver response times.';
        }
        return 'Suggested check: Inspect logs for packet loss, Wi-Fi interference, or link flaps.';
    }

    function renderMiniChainHtml(hourData, dayLabel, timeRange, isResolved) {
        const safeDay = escapeHTML(dayLabel);
        const safeTime = escapeHTML(timeRange);
        const headerTime = safeDay + ' ' + safeTime + (hourData && hourData.is_current === true && hourData.status !== 'INACTIVE' ? ' (In Progress)' : '');

        if (hourData.status === 'INACTIVE') {
            return '<div style="font-weight: bold; margin-bottom: 6px; border-bottom: 1px solid #4b646f; padding-bottom: 4px; display: flex; justify-content: space-between; align-items: center; gap: 12px;">' +
                   '<span>' + safeDay + ' ' + safeTime + '</span>' +
                   '<span class="label label-default">Pending / No Data</span>' +
                   '</div>' +
                   '<div style="font-size: 11px; color: #b8c7ce; margin-top: 4px; text-align: center; background: #1a2226; padding: 6px 8px; border-radius: 4px;">' +
                   'No monitoring telemetry recorded for this hour' +
                   '</div>';
        }

        const isOk = hourData.status === 'OK';
        const hasRecovered = Boolean(hourData.has_recovered);
        const skipDc = Boolean(currentMetadata.skip_dnscrypt);
        const slowSet = new Set(Array.isArray(hourData.slow_hops) ? hourData.slow_hops : []);

        const clientOk = isOk ? true : (hourData.client_ok !== false);
        const piState = isOk ? true : hourData.pihole;
        const dcState = isOk ? (skipDc ? null : true) : hourData.dnscrypt;
        const cfState = isOk ? true : hourData.cloudflare;

        let badgesHtml = '';
        if (isOk) {
            badgesHtml = '<span class="label label-success">100% Operational</span>';
        } else {
            const primaryBadge = hourData.status === 'DANGER'
                ? '<span class="label label-danger">Outage</span>'
                : '<span class="label label-warning">Degraded</span>';
            badgesHtml = primaryBadge;
            if (hasRecovered) {
                badgesHtml += ' <span class="label label-success"><i class="fa fa-check"></i> Recovered</span>';
            }
        }

        let html = '<div style="font-weight: bold; margin-bottom: 6px; border-bottom: 1px solid #4b646f; padding-bottom: 4px; display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap;">' +
                   '<span>' + headerTime + '</span>' +
                   '<span>' + badgesHtml + '</span>' +
                   '</div>';

        if (!isOk) {
            html += '<div style="font-size: 10px; text-transform: uppercase; letter-spacing: 0.5px; color: #b8c7ce; margin-top: 2px;">Incident Root Cause</div>';
        }

        const arrowStyle = 'color: #b8c7ce;';
        const hops = [renderHopSpan('Client', clientOk, false)];
        hops.push(renderHopSpan('Pi-hole', piState, slowSet.has('pihole')));
        if (!skipDc && dcState !== undefined && !(isOk && dcState === null)) {
            if (dcState !== null || piState !== false) {
                hops.push(renderHopSpan('dnscrypt', dcState, slowSet.has('dnscrypt')));
            }
        }
        hops.push(renderHopSpan('Upstream', cfState, slowSet.has('cloudflare')));

        html += '<div style="display: flex; flex-wrap: wrap; align-items: center; gap: 5px; margin: 4px 0 6px 0; background: #1a2226; padding: 6px 8px; border-radius: 4px; font-family: monospace; font-size: 11px;">' +
                hops.join('<span style="' + arrowStyle + '">&rarr;</span>') +
                '</div>';

        if (!isOk) {
            const affectedText = escapeHTML(hourData.iface || hourData.tested_ifaces || 'unknown');
            html += '<div style="font-size: 11px; color: #f39c12; margin-top: 4px;">Affected Interface(s): <strong>' + affectedText + '</strong>';
            if (hourData.uptime !== undefined) {
                html += ' &middot; <span style="color: #b8c7ce;">Hour Uptime: <strong>' + Number(hourData.uptime) + '%</strong></span>';
            }
            html += '</div>';

            if (hourData.earliest_issue) {
                let timeline = 'Started: <strong>' + escapeHTML(hourData.earliest_issue) + '</strong>';
                if (hasRecovered && hourData.recovered_at) {
                    timeline += ' &rarr; <span style="color: #2ecc71;">Recovered at <strong>' + escapeHTML(hourData.recovered_at) + '</strong></span>';
                }
                html += '<div style="font-size: 11px; color: #e1e8eb; margin-top: 2px;">' + timeline + '</div>';
            } else if (hasRecovered && hourData.recovered_at) {
                html += '<div style="font-size: 11px; color: #2ecc71; margin-top: 2px;">Recovered at <strong>' + escapeHTML(hourData.recovered_at) + '</strong></div>';
            }
            const resolved = Boolean(isResolved || hasRecovered);
            const fixHint = !resolved ? getTooltipFixHint(hourData) : '';
            if (fixHint) {
                html += '<div style="font-size: 11px; color: #f7dc6f; margin-top: 4px; border-top: 1px dashed #4b646f; padding-top: 4px; white-space: normal;"><i class="fa fa-wrench"></i> ' + escapeHTML(fixHint) + '</div>';
            }
        } else {
            const testedText = escapeHTML(hourData.tested_ifaces || 'active link');
            html += '<div style="font-size: 11px; color: #b8c7ce; margin-top: 4px;">Tested Interfaces: <strong>' + testedText + '</strong></div>';
        }

        return html;
    }

    function showTooltipForCell(cell, hourData, dayLabel, timeRange, isResolved) {
        const tip = getOrCreateTooltip();
        tip.innerHTML = renderMiniChainHtml(hourData, dayLabel, timeRange, isResolved);
        tip.style.display = 'block';
        tip.style.opacity = '1';
        positionTooltipForCell(cell);
    }

    function attachTooltipEvents(cell, hourData, dayLabel, timeRange, isResolved) {
        const recoveredLabel = hourData.has_recovered ? ', recovered at ' + (hourData.recovered_at || 'hour end') : '';
        cell.setAttribute('tabindex', '0');
        cell.setAttribute('role', 'button');
        cell.setAttribute('aria-label', dayLabel + ' ' + timeRange + ': ' + hourData.status + recoveredLabel);

        cell.addEventListener('mouseenter', function() {
            pinnedCell = null;
            showTooltipForCell(cell, hourData, dayLabel, timeRange, isResolved);
        });

        cell.addEventListener('mouseleave', function() {
            if (pinnedCell !== cell) {
                hideTooltip();
            }
        });

        cell.addEventListener('focus', function() {
            showTooltipForCell(cell, hourData, dayLabel, timeRange, isResolved);
        });

        cell.addEventListener('blur', function() {
            if (pinnedCell !== cell) {
                hideTooltip();
            }
        });

        cell.addEventListener('click', function(e) {
            e.stopPropagation();
            if (pinnedCell === cell && tooltipEl && tooltipEl.style.display === 'block') {
                hideTooltip();
            } else {
                pinnedCell = cell;
                showTooltipForCell(cell, hourData, dayLabel, timeRange, isResolved);
            }
        });
    }

    document.addEventListener('click', function() {
        if (pinnedCell) hideTooltip();
    });

    document.addEventListener('keydown', function(e) {
        if (e.key === 'Escape') hideTooltip();
    });

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
                const defaultData = { status: 'INACTIVE', has_recovered: false };
                attachTooltipEvents(cell, defaultData, dayLabel, timeRange);
                container.appendChild(cell);
            }
        });
    }

    function showFetchError(show, msg) {
        const banner = document.getElementById('fetch-error-banner');
        const msgEl = document.getElementById('fetch-error-msg');
        if (!banner) return;
        banner.style.display = show ? 'block' : 'none';
        if (show && msgEl && msg) msgEl.textContent = msg;
    }

    async function refreshDashboard() {
        const paths = ['/status.json', 'status.json', '/dev/shm/status.json'];
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
        if (data) {
            showFetchError(false);
            updateUI(data);
        } else {
            showFetchError(true, 'Unable to load status.json from web root. Verify cron job and file permissions.');
        }
    }

    async function refreshCanary() {
        const box = document.getElementById('box-lan-canary');
        const titleEl = document.getElementById('canary-box-title');
        const statusLabel = document.getElementById('canary-status-label');
        if (!box) return;

        let canary = null;
        for (const path of ['/canary_status.json', 'canary_status.json']) {
            try {
                const res = await fetch(path + '?t=' + Date.now());
                if (res.ok) {
                    canary = await res.json();
                    break;
                }
            } catch (e) {}
        }

        if (!canary || !canary.interfaces) {
            lastCanaryData = null;
            lastCanaryTimestamp = null;
            box.style.display = 'none';
            if (lastDashboardData) renderRemediationGuide(lastDashboardData, null);
            return;
        }
        lastCanaryData = canary;

        if (canary.timestamp) {
            const parsed = new Date(canary.timestamp);
            lastCanaryTimestamp = !isNaN(parsed.getTime()) ? parsed.getTime() : null;
        } else {
            lastCanaryTimestamp = null;
        }
        updateFreshnessTicker();

        const cMeta = canary.metadata || {};
        const cStatus = canary.status || 'Unknown';
        const statusType = cStatus === 'Healthy' ? 'success' : (cStatus === 'Degraded' ? 'warning' : 'danger');
        if (titleEl) {
            titleEl.textContent = 'LAN Canary';
        }
        box.className = 'box box-' + statusType;
        if (statusLabel) {
            statusLabel.className = 'label label-' + statusType;
            statusLabel.textContent = 'STATUS: ' + cStatus;
        }

        const cIfaces = Object.entries(canary.interfaces).filter(([, d]) => d && d.state !== 'unused' && d.admin_up !== false);
        const activePair = cIfaces.find(([, d]) => d.connectivity === 'OK') || cIfaces[0] || [null, null];
        const [activeName, cActive] = activePair;
        const cThresholds = (cMeta && cMeta.thresholds) || { pihole_ms: 150, upstream_ms: 200, loss_pct: 5 };

        // Card 1: Canary Host
        const hostEl = document.getElementById('canary-node-host');
        const hostDescEl = document.getElementById('canary-node-host-desc');
        if (hostEl && hostDescEl) {
            const hostTarget = (activeName || 'link') + (cActive && cActive.ip ? (' \u00b7 ' + cActive.ip) : '');
            const hostTargetSpan = '<span class="node-target" title="' + escapeHTML(hostTarget) + '">' + escapeHTML(hostTarget) + '</span>';
            if (cActive && cActive.connectivity === 'OK') {
                hostEl.className = 'chain-node node-ok';
                hostDescEl.innerHTML = hostTargetSpan + '<span class="node-result text-green"><i class="fa fa-check-circle"></i> Online</span>';
            } else {
                hostEl.className = 'chain-node node-fail';
                hostDescEl.innerHTML = hostTargetSpan + '<span class="node-result text-red"><i class="fa fa-times-circle"></i> Offline</span>';
            }
        }

        // Card 2: DNS via Pi-hole
        updateNodeState(
            'canary-node-pihole',
            'canary-node-pihole-desc',
            cActive ? cActive.pihole : null,
            cMeta.pihole_target || 'Pi-hole',
            cActive ? cActive.latency_pihole : -1,
            cThresholds.pihole_ms,
            'Untested'
        );

        // Card 3: Upstream DNS
        const upTarget = cMeta.upstream_ip || (cActive && cActive.upstream_ip) || '1.1.1.1';
        updateNodeState(
            'canary-node-upstream',
            'canary-node-upstream-desc',
            cActive ? cActive.cloudflare : null,
            upTarget,
            cActive ? cActive.latency_cloudflare : -1,
            cThresholds.upstream_ms,
            'Untested'
        );

        // Card 4: WAN Ping
        const wanEl = document.getElementById('canary-node-wan');
        const wanDescEl = document.getElementById('canary-node-wan-desc');
        if (wanEl && wanDescEl) {
            const lossVal = cActive ? cActive.packet_loss : null;
            const lossMissing = lossVal === null || lossVal === undefined;
            const pingMs = (cActive && cActive.latency_ping >= 0) ? Math.round(cActive.latency_ping) : -1;
            const wanTarget = lossMissing ? '1.1.1.1' : (Number(lossVal).toFixed(1) + '% loss');
            const wanTargetSpan = '<span class="node-target" title="' + escapeHTML(wanTarget) + '">' + escapeHTML(wanTarget) + '</span>';
            const pingPrefix = pingMs >= 0 ? (pingMs + 'ms &middot; ') : '';

            if (!cActive || cActive.connectivity !== 'OK') {
                wanEl.className = 'chain-node node-fail';
                wanDescEl.innerHTML = wanTargetSpan + '<span class="node-result text-red"><i class="fa fa-times-circle"></i> FAIL</span>';
            } else if (!lossMissing && Number(lossVal) >= cThresholds.loss_pct) {
                wanEl.className = 'chain-node node-warning';
                wanDescEl.innerHTML = wanTargetSpan + '<span class="node-result text-yellow"><i class="fa fa-exclamation-triangle"></i> ' + pingPrefix + 'LOSS</span>';
            } else {
                wanEl.className = 'chain-node node-ok';
                wanDescEl.innerHTML = wanTargetSpan + '<span class="node-result text-green"><i class="fa fa-check-circle"></i> ' + pingPrefix + 'OK</span>';
            }
        }

        box.style.display = 'block';
        if (lastDashboardData) renderRemediationGuide(lastDashboardData, canary);
    }

    function updateSmallBox(boxId, metricId, subId, valText, subText, color) {
        const box = document.getElementById(boxId);
        const metric = document.getElementById(metricId);
        const sub = document.getElementById(subId);
        if (metric) metric.textContent = valText;
        if (sub) sub.textContent = subText;
        if (box) {
            box.className = 'small-box bg-' + color + ' no-user-select';
        }
    }

    function updateNodeState(nodeId, descId, isOk, targetLabel, latencyVal, warnThreshold, unusedText, fullTitle) {
        const nodeEl = document.getElementById(nodeId);
        const descEl = document.getElementById(descId);
        if (!nodeEl || !descEl) return;

        const targetTitle = fullTitle || targetLabel;
        const targetSpan = '<span class="node-target" title="' + escapeHTML(targetTitle) + '">' + escapeHTML(targetLabel) + '</span>';

        if (isOk === null || isOk === undefined) {
            nodeEl.className = 'chain-node';
            descEl.innerHTML = targetSpan + '<span class="node-result text-muted"><i class="fa fa-minus-circle"></i> ' + escapeHTML(unusedText || 'Untested') + '</span>';
            return;
        }
        const latKnown = latencyVal !== undefined && latencyVal !== null && latencyVal >= 0;
        const latPrefix = latKnown ? (latencyVal + 'ms &middot; ') : '';
        const isDegraded = isOk === true && Boolean(warnThreshold) && latKnown && latencyVal >= warnThreshold;

        if (!isOk) {
            nodeEl.className = 'chain-node node-fail';
            descEl.innerHTML = targetSpan + '<span class="node-result text-red"><i class="fa fa-times-circle"></i> FAIL</span>';
        } else if (isDegraded) {
            nodeEl.className = 'chain-node node-warning';
            descEl.innerHTML = targetSpan + '<span class="node-result text-yellow"><i class="fa fa-exclamation-triangle"></i> ' + latPrefix + 'SLOW</span>';
        } else {
            nodeEl.className = 'chain-node node-ok';
            descEl.innerHTML = targetSpan + '<span class="node-result text-green"><i class="fa fa-check-circle"></i> ' + latPrefix + 'OK</span>';
        }
    }

    function selectConfiguredAndActive(data) {
        const ifacesObj = (data && data.interfaces) || {};
        const ifaceEntries = Object.entries(ifacesObj);
        const configuredEntries = ifaceEntries.filter(([, d]) => d && d.state !== 'unused' && d.admin_up !== false);
        const activeEntry =
            configuredEntries.find(([n, d]) => !isWirelessName(n) && d.connectivity === 'OK' && d.dns_ok !== false) ||
            configuredEntries.find(([, d]) => d.connectivity === 'OK' && d.dns_ok !== false) ||
            configuredEntries.find(([, d]) => d.connectivity === 'OK') ||
            configuredEntries[0] ||
            ifaceEntries[0];
        return { ifaceEntries, configuredEntries, activeIface: activeEntry ? activeEntry[1] : null };
    }

    function buildRemediationItems(data, activeIface, configuredEntries, canaryData) {
        const items = [];
        let severity = null;
        function bump(lvl) {
            if (lvl === 'danger') severity = 'danger';
            else if (lvl === 'warning' && severity !== 'danger') severity = 'warning';
        }

        const meta = (data && data.metadata) || {};
        const thresholds = meta.thresholds || { pihole_ms: 150, dnscrypt_ms: 200, upstream_ms: 200, loss_pct: 5 };
        const skipDc = Boolean(meta.skip_dnscrypt);
        const allDown = configuredEntries.length > 0 && configuredEntries.every(([, d]) => d.connectivity === 'DOWN');

        // 1. Client physical link / DHCP lease errors
        configuredEntries.forEach(([name, d]) => {
            if (d.connectivity === 'DOWN') {
                const safe = escapeHTML(name);
                if (d.carrier === 0) {
                    bump(allDown ? 'danger' : 'warning');
                    items.push('<strong>' + safe + ' Link Disconnected:</strong> Check Ethernet cable, switch port LED, or Wi-Fi AP association.');
                } else if (d.has_ip === false) {
                    bump(allDown ? 'danger' : 'warning');
                    items.push('<strong>' + safe + ' Missing IP Lease:</strong> Verify router DHCP pool or renew lease on <code>' + safe + '</code>.');
                } else if (!allDown) {
                    bump('warning');
                    items.push('<strong>Backup Link (' + safe + ') Down:</strong> Secondary interface cannot reach <code>1.1.1.1</code>; reconnect if failover is needed.');
                }
            }
        });

        if (activeIface) {
            const isConnOk = activeIface.connectivity === 'OK';
            const hasClientLink = configuredEntries.some(([, d]) => d.carrier !== 0 && d.has_ip !== false);

            // 2. WAN / ISP outage
            if ((allDown || !isConnOk) && hasClientLink) {
                bump('danger');
                items.push('<strong>WAN Connectivity Down:</strong> Primary ping targets unreachable (<code>1.1.1.1</code> / <code>9.9.9.9</code>). Check ISP modem/ONT lights, router WAN port, or ISP status.');
            }

            // 3. Pi-hole / dnscrypt / Upstream DNS failures
            if (hasClientLink && isConnOk) {
                const upHealthy = activeIface.cloudflare === true || activeIface.upstream_secondary_ok === true;
                if (activeIface.pihole === false && (skipDc || activeIface.dnscrypt === true) && upHealthy) {
                    bump('danger');
                    items.push('<strong>Pi-hole Service Down:</strong> Restart FTL (<code>sudo systemctl restart pihole-FTL</code>) and inspect <code>/var/log/pihole/FTL.log</code>.');
                } else if (!skipDc && activeIface.dnscrypt === false && upHealthy) {
                    bump('danger');
                    items.push('<strong>dnscrypt-proxy Failed:</strong> Restart local forwarder (<code>sudo systemctl restart dnscrypt-proxy</code>) and check <code>sudo journalctl -u dnscrypt-proxy -n 30</code>.');
                } else if (!upHealthy && activeIface.cloudflare === false) {
                    bump('danger');
                    items.push('<strong>Upstream DNS Unreachable:</strong> Check WAN routing and firewall rules for outbound DNS (UDP <code>53</code> / DoH HTTPS <code>443</code>).');
                } else if (activeIface.cloudflare === false && activeIface.upstream_secondary_ok === true) {
                    bump('warning');
                    items.push('<strong>Primary Upstream Failover Active:</strong> Primary resolver unreachable; secondary resolver (<code>' + escapeHTML(activeIface.upstream_secondary_ip || '9.9.9.9') + '</code>) is handling traffic.');
                } else if (activeIface.upstream_secondary_ok === false && activeIface.upstream_secondary_ip) {
                    bump('warning');
                    items.push('<strong>Secondary Upstream Unreachable:</strong> Failover resolver <code>' + escapeHTML(activeIface.upstream_secondary_ip) + '</code> timed out; redundancy reduced.');
                }

                // 4. Latency & packet loss degradations
                if (activeIface.pihole === true && activeIface.latency_pihole >= thresholds.pihole_ms) {
                    bump('warning');
                    items.push('<strong>Slow Pi-hole Response (' + activeIface.latency_pihole + 'ms):</strong> Check <a href="/admin/queries">Pi-hole Query Log</a> for high-volume clients, inspect <code>pihole-FTL.db</code> size, and check flash I/O wait.');
                }
                if (!skipDc && activeIface.dnscrypt === true && activeIface.latency_dnscrypt >= thresholds.dnscrypt_ms) {
                    bump('warning');
                    items.push('<strong>Slow dnscrypt-proxy (' + activeIface.latency_dnscrypt + 'ms):</strong> Inspect DoH server latency or switch resolvers in <code>/etc/dnscrypt-proxy/dnscrypt-proxy.toml</code>.');
                }
                if (activeIface.cloudflare === true && activeIface.latency_cloudflare >= thresholds.upstream_ms) {
                    bump('warning');
                    items.push('<strong>High Upstream Latency (' + activeIface.latency_cloudflare + 'ms):</strong> Upstream DNS or ISP link is congested; check WAN bandwidth saturation and modem stats.');
                }
                if (activeIface.packet_loss >= thresholds.loss_pct) {
                    bump('warning');
                    items.push('<strong>ICMP Packet Loss (' + Number(activeIface.packet_loss).toFixed(1) + '%):</strong> Inspect coax/fiber modem signal levels, Ethernet cabling, or Wi-Fi interference.');
                }
            }
        }

        // 5. Stale telemetry or LAN Canary split-brain disagreement
        if (lastDataTimestamp && formatRelativeAge(lastDataTimestamp).stale) {
            bump('warning');
            items.push('<strong>Telemetry Stale (&gt;15m):</strong> Cron check may have stopped. Verify <code>crontab -l</code> and lock file in <code>/tmp/</code> or <code>/dev/shm/</code>.');
        }
        if (canaryData && canaryData.status && canaryData.status !== 'Healthy' && data && data.status === 'Healthy') {
            bump('warning');
            const cHost = escapeHTML((canaryData.metadata && canaryData.metadata.host) || 'LAN Canary');
            items.push('<strong>LAN Canary Disagreement:</strong> Remote client <code>' + cHost + '</code> reports <strong>' + escapeHTML(canaryData.status) + '</strong> while local checks pass — SSH in and check host CPU/I/O wait or LAN switching.');
        }

        return { severity, items };
    }

    function renderRemediationGuide(data, canaryData) {
        const callout = document.getElementById('remediation-callout');
        const listEl = document.getElementById('remediation-list');
        const titleEl = document.getElementById('remediation-title');
        if (!callout || !listEl || !titleEl) return;

        const { configuredEntries, activeIface } = selectConfiguredAndActive(data);
        const result = buildRemediationItems(data, activeIface, configuredEntries, canaryData);

        if (!result.items.length) {
            callout.style.display = 'none';
            listEl.innerHTML = '';
            return;
        }

        callout.className = 'callout ' + (result.severity === 'danger' ? 'callout-danger' : 'callout-warning');
        titleEl.innerHTML = result.severity === 'danger'
            ? '<i class="fa fa-wrench"></i> Recommended Actions (Outage Detected)'
            : '<i class="fa fa-wrench"></i> Recommended Actions (Degradation Advisory)';
        listEl.innerHTML = result.items.map(item => '<li>' + item + '</li>').join('');
        callout.style.display = 'block';
    }

    function updateArrowState(arrowId, isOk) {
        const arrowEl = document.getElementById(arrowId);
        if (!arrowEl) return;
        if (isOk === null || isOk === undefined) {
            arrowEl.className = 'connector-arrow';
        } else {
            arrowEl.className = isOk ? 'connector-arrow arrow-ok' : 'connector-arrow arrow-fail';
        }
    }

    function updateUI(data) {
        lastDashboardData = data;
        if (data.timestamp) {
            const parsed = new Date(data.timestamp);
            if (!isNaN(parsed.getTime())) {
                lastDataTimestamp = parsed.getTime();
                updateFreshnessTicker();
            }
        }

        const meta = data.metadata || {};
        currentMetadata = meta;
        const thresholds = meta.thresholds || { pihole_ms: 150, dnscrypt_ms: 200, upstream_ms: 200, loss_pct: 5 };
        const skipDc = Boolean(meta.skip_dnscrypt);

        const { ifaceEntries, configuredEntries, activeIface } = selectConfiguredAndActive(data);

        let activeStatus = data.status || 'Healthy';
        let degReason = '';
        if (configuredEntries.length > 0) {
            const allDown = configuredEntries.every(([, d]) => d.connectivity === 'DOWN');
            const anyFail = configuredEntries.some(([, d]) => d.connectivity === 'DOWN' || d.dns_ok === false);
            const anyDeg = configuredEntries.some(([, d]) => d.degraded === true);
            const degEntry = configuredEntries.find(([, d]) => d.degradation_reason);
            if (degEntry) degReason = degEntry[1].degradation_reason;

            if (allDown) {
                activeStatus = 'Outage';
            } else if (anyFail || anyDeg || data.status === 'Degraded') {
                activeStatus = 'Degraded';
            } else {
                activeStatus = 'Healthy';
            }
        }

        const headerLabel = document.getElementById('header-status-label');
        const sidebarBadge = document.getElementById('sidebar-status-badge');
        const chainBox = document.getElementById('box-live-chain');

        if (headerLabel) {
            if (activeStatus === 'Healthy') {
                headerLabel.className = 'label label-success';
                headerLabel.textContent = 'STATUS: Healthy';
            } else if (activeStatus === 'Degraded' || activeStatus === 'Partial Outage' || activeStatus === 'DNS Issues') {
                headerLabel.className = 'label label-warning';
                headerLabel.textContent = degReason ? ('STATUS: Degraded (' + degReason + ')') : 'STATUS: Degraded';
            } else {
                headerLabel.className = 'label label-danger';
                headerLabel.textContent = 'STATUS: ' + activeStatus;
            }
        }

        if (sidebarBadge) {
            const badgeCls = activeStatus === 'Healthy' ? 'label-success' : (activeStatus === 'Degraded' ? 'label-warning' : 'label-danger');
            sidebarBadge.className = 'label ' + badgeCls;
            sidebarBadge.innerHTML = '<i class="fa fa-circle"></i> ' + escapeHTML(activeStatus);
        }

        if (chainBox) {
            const boxCls = activeStatus === 'Healthy' ? 'box-success' : (activeStatus === 'Degraded' ? 'box-warning' : 'box-danger');
            chainBox.className = 'box ' + boxCls;
        }

        // Dynamic 4-state CLIENT node rendering (never drops failed/unplugged NICs)
        const clientDesc = document.getElementById('node-client-desc');
        const clientNode = document.getElementById('node-client');
        if (clientDesc && clientNode) {
            let rowsHtml = '';
            let anyConfUp = false;
            let allConfUp = configuredEntries.length > 0;
            let anyConfDeg = false;

            ifaceEntries.forEach(([name, d]) => {
                if (!d) return;
                const safeName = escapeHTML(name);
                if (d.state === 'unused' || d.admin_up === false) {
                    rowsHtml += '<div class="client-iface-row client-iface-muted">' +
                                '<span><i class="fa fa-minus-circle"></i> <strong>' + safeName + '</strong></span>' +
                                '<span>Unused</span></div>';
                    return;
                }
                if (d.connectivity === 'OK') {
                    anyConfUp = true;
                    if (d.degraded) {
                        anyConfDeg = true;
                        rowsHtml += '<div class="client-iface-row">' +
                                    '<span><i class="fa fa-exclamation-triangle text-yellow"></i> <strong>' + safeName + '</strong></span>' +
                                    '<span class="text-yellow">Degraded</span></div>';
                    } else if (d.dns_ok === false) {
                        anyConfDeg = true;
                        rowsHtml += '<div class="client-iface-row">' +
                                    '<span><i class="fa fa-exclamation-triangle text-yellow"></i> <strong>' + safeName + '</strong></span>' +
                                    '<span class="text-yellow">DNS Fail</span></div>';
                    } else {
                        rowsHtml += '<div class="client-iface-row">' +
                                    '<span><i class="fa fa-check-circle text-green"></i> <strong>' + safeName + '</strong></span>' +
                                    '<span class="text-green">Online</span></div>';
                    }
                } else {
                    allConfUp = false;
                    let downReason = 'Offline';
                    if (d.carrier === 0) downReason = 'No Link';
                    else if (d.has_ip === false) downReason = 'No IP';
                    rowsHtml += '<div class="client-iface-row">' +
                                '<span><i class="fa fa-times-circle text-red"></i> <strong>' + safeName + '</strong></span>' +
                                '<span class="text-red">' + downReason + '</span></div>';
                }
            });

            clientDesc.innerHTML = rowsHtml || 'Local Machine';
            if (configuredEntries.length === 0 || !anyConfUp) {
                clientNode.className = 'chain-node node-fail';
            } else if (!allConfUp || anyConfDeg) {
                clientNode.className = 'chain-node node-warning';
            } else {
                clientNode.className = 'chain-node node-ok';
            }
        }

        // Handle skipped dnscrypt cleanly in Client Mode
        const dcNode = document.getElementById('node-dnscrypt');
        const arrow2 = document.getElementById('arrow-2');
        if (dcNode) dcNode.style.display = skipDc ? 'none' : '';
        if (arrow2) arrow2.style.display = skipDc ? 'none' : '';

        if (activeIface) {
            const isConnOk = activeIface.connectivity === 'OK';
            const piTarget = meta.pihole_target || '127.0.0.1:53';
            const dcTarget = meta.dnscrypt_target || '127.0.0.1:5053';
            const upstreamIp = activeIface.upstream_ip || meta.upstream_ip || '1.1.1.1';
            const secondaryIp = activeIface.upstream_secondary_ip || meta.upstream_secondary_ip || '';
            const upstreamProto = meta.upstream_protocol || 'UDP/53';
            const upLabel = secondaryIp
                ? upstreamIp + ' + ' + secondaryIp
                : upstreamIp + ':53';
            const upTitle = secondaryIp
                ? upstreamIp + ' + ' + secondaryIp + ' (' + upstreamProto + ')'
                : upstreamIp + ':53 (' + upstreamProto + ')';

            updateNodeState('node-pihole', 'node-pihole-desc', activeIface.pihole, piTarget, activeIface.latency_pihole, thresholds.pihole_ms);
            if (!skipDc) {
                updateNodeState('node-dnscrypt', 'node-dnscrypt-desc', activeIface.dnscrypt, dcTarget, activeIface.latency_dnscrypt, thresholds.dnscrypt_ms);
            }

            const cfPass = (activeIface.cloudflare === true || activeIface.upstream_secondary_ok === true) && isConnOk;
            const cfState = (activeIface.cloudflare === null && !isConnOk) ? null : cfPass;
            updateNodeState('node-cloudflare', 'node-cloudflare-desc', cfState, upLabel, activeIface.latency_cloudflare, thresholds.upstream_ms, undefined, upTitle);

            updateArrowState('arrow-1', activeIface.pihole);
            updateArrowState('arrow-2', activeIface.dnscrypt);
            updateArrowState('arrow-3', cfState);

            // Top KPI Cards (handle undefined/null/negative strictly)
            const piVal = activeIface.latency_pihole;
            const piInvalid = piVal === undefined || piVal === null || piVal < 0 || activeIface.pihole !== true;
            updateSmallBox(
                'box-pihole-lat',
                'metric-pihole-lat',
                'sub-pihole-lat',
                piInvalid ? 'TIMEOUT' : (piVal + ' ms'),
                piInvalid ? 'Pi-hole Unreachable' : (piVal >= thresholds.pihole_ms ? ('High Latency (>= ' + thresholds.pihole_ms + 'ms)') : (piTarget + (meta.cache_busted ? ' · Uncached' : ''))),
                piInvalid ? 'red' : (piVal >= thresholds.pihole_ms ? 'yellow' : 'green')
            );

            const upVal = activeIface.latency_cloudflare;
            const upInvalid = !isConnOk || upVal === undefined || upVal === null || upVal < 0 || (activeIface.cloudflare !== true && activeIface.upstream_secondary_ok !== true);
            const upDisplayVal = (upVal !== undefined && upVal !== null && upVal >= 0) ? upVal : activeIface.latency_upstream_secondary;
            const upFailover = activeIface.cloudflare !== true && activeIface.upstream_secondary_ok === true;
            updateSmallBox(
                'box-upstream-lat',
                'metric-upstream-lat',
                'sub-upstream-lat',
                upInvalid ? 'TIMEOUT' : ((upDisplayVal >= 0 ? upDisplayVal : '--') + ' ms'),
                upInvalid ? 'Upstream Unreachable' : (upFailover ? ('Failover: ' + secondaryIp) : (upDisplayVal >= thresholds.upstream_ms ? ('Slow (>= ' + thresholds.upstream_ms + 'ms)') : (secondaryIp ? (upstreamIp + ' + ' + secondaryIp) : upstreamIp))),
                upInvalid ? 'red' : ((upFailover || upDisplayVal >= thresholds.upstream_ms) ? 'yellow' : 'green')
            );

            const lossVal = activeIface.packet_loss;
            const lossMissing = lossVal === undefined || lossVal === null;
            const lossWarn = thresholds.loss_pct !== undefined ? thresholds.loss_pct : 5;
            updateSmallBox(
                'box-loss',
                'metric-loss',
                'sub-loss',
                lossMissing ? '--' : (Number(lossVal).toFixed(1) + '%'),
                lossMissing ? 'Unknown' : (!isConnOk ? 'Total Outage' : (lossVal >= lossWarn ? ('Loss >= ' + lossWarn + '%') : '1.1.1.1 Ping (' + (activeIface.latency_ping >= 0 ? Math.round(activeIface.latency_ping) + 'ms' : 'OK') + ')')),
                lossMissing ? 'gray' : (!isConnOk ? 'red' : (lossVal >= lossWarn ? 'yellow' : 'green'))
            );
        }

        if (data.history) renderHistoricalGrid(data.history);
        if (data.incidents) renderIncidentsList(data.incidents);

        if (data.sla_percentage !== undefined) {
            const val = Number(data.sla_percentage);
            const slaEl = document.getElementById('grid-uptime-pct');
            if (slaEl) {
                if (val < 95.0) slaEl.className = 'label label-danger';
                else if (val < 99.0) slaEl.className = 'label label-warning';
                else slaEl.className = 'label label-success';
                slaEl.textContent = 'SLA: ' + val.toFixed(2) + '%';
            }
            updateSmallBox(
                'box-sla',
                'metric-sla',
                'sub-sla',
                val.toFixed(2) + '%',
                'Apdex Quality Weighted',
                val < 95.0 ? 'red' : (val < 99.0 ? 'yellow' : 'green')
            );
        }

        renderRemediationGuide(data, lastCanaryData);
    }

    function renderHistoricalGrid(history) {
        hideTooltip();
        const containerIds = { 'Today': 'row-today', 'Yesterday': 'row-yesterday', '2 Days Ago': 'row-2daysago' };
        const labelIds = { 'Today': 'label-today', 'Yesterday': 'label-yesterday', '2 Days Ago': 'label-2daysago' };

        const dayOrder = ['2 Days Ago', 'Yesterday', 'Today'];
        const chronologicalCells = [];
        dayOrder.forEach(label => {
            const row = history.find(r => r.label === label);
            if (row && Array.isArray(row.hours)) {
                row.hours.forEach(h => chronologicalCells.push(h));
            }
        });
        let resolvedAfter = Boolean(lastDashboardData && lastDashboardData.status === 'Healthy');
        const resolvedMap = new WeakMap();
        for (let i = chronologicalCells.length - 1; i >= 0; i--) {
            const h = chronologicalCells[i];
            const isCellResolved = Boolean(h.has_recovered) || resolvedAfter;
            resolvedMap.set(h, isCellResolved);
            if (h.status === 'OK' || h.has_recovered) {
                resolvedAfter = true;
            }
        }

        history.forEach(row => {
            const containerId = containerIds[row.label];
            const labelId = labelIds[row.label];
            const dateText = getDisplayDate(row.label, row.date);

            if (labelId) {
                const lblEl = document.getElementById(labelId);
                if (lblEl) {
                    lblEl.innerHTML = escapeHTML(row.label) + '<span class="row-date">' + escapeHTML(dateText) + '</span>';
                }
            }

            if (!containerId) return;
            const container = document.getElementById(containerId);
            if (!container) return;
            container.innerHTML = '';

            row.hours.forEach(hourData => {
                const cell = document.createElement('div');
                let stateClass = 'hour-inactive';
                if (hourData.status === 'OK') {
                    stateClass = 'hour-ok';
                } else if (hourData.status === 'WARNING') {
                    stateClass = hourData.has_recovered ? 'hour-warning-recovered' : 'hour-warning';
                } else if (hourData.status === 'DANGER') {
                    stateClass = hourData.has_recovered ? 'hour-danger-recovered' : 'hour-danger';
                }

                const fillPct = getCurrentHourFillPct(row.label, hourData);
                if (fillPct !== null) {
                    cell.className = 'hour-cell hour-current';
                    const fill = document.createElement('span');
                    fill.className = 'hour-cell-fill ' + stateClass;
                    fill.style.width = fillPct + '%';
                    cell.appendChild(fill);
                } else {
                    cell.className = 'hour-cell ' + stateClass;
                }

                const timeRange = formatHourRange(hourData.hour);
                attachTooltipEvents(cell, hourData, dateText, timeRange, resolvedMap.get(hourData) === true);
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
            desc.style.opacity = '0.9';
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
        refreshCanary();
        setInterval(refreshDashboard, 30000);
        setInterval(refreshCanary, 30000);
        setInterval(updateFreshnessTicker, 5000);
    });
})();
