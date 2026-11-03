// pve-wdcbalancer GUI extension: Datacenter > Load Balancing
//
// Loaded after pvemanagerlib.js (see wdcbalancer-integrate). Uses only public
// widget-toolkit classes so it survives pve-manager updates. Every grid
// column list goes through PVE.wdcb.Utils.safeColumns, so text from guests
// (names) and from the configuration (group and rule names, comments) is
// HTML-encoded.

Proxmox.Utils.override_task_descriptions({
    wdcbapply: ['Load Balancing', gettext('Apply recommendations')],
    wdcbmaint: ['Node', gettext('Enter maintenance mode')],
    wdcbpoweron: ['Load Balancing', gettext('Power On (balanced)')],
});

Ext.define('PVE.wdcb.Utils', {
    singleton: true,

    safeColumns: function(columns) {
	return (columns || []).map(function(c) {
	    let col = Ext.apply({}, c);
	    if (col.columns) {
		col.columns = PVE.wdcb.Utils.safeColumns(col.columns);
	    } else if (!col.renderer && !col.xtype) {
		col.renderer = v => Ext.htmlEncode(v);
	    }
	    return col;
	});
    },

    // the node serving the GUI answers every cluster-wide call
    url: function(path) {
	return `/nodes/${Proxmox.NodeName}/wdcbalancer/${path}`;
    },

    thresholds: {
	1: gettext('Conservative: only mandatory moves (maintenance mode, rule violations).'),
	2: gettext('Moves that bring a large improvement, and fixes for soft (should) rules.'),
	3: gettext('Default: moves that bring a good improvement to VM scores.'),
	4: gettext('Also moves that even out load between nodes.'),
	5: gettext('Aggressive: even small improvements in balance.'),
    },

    automation: {
	disabled: gettext('Disabled'),
	manual: gettext('Manual'),
	partial: gettext('Partially automated'),
	full: gettext('Fully automated'),
    },

    renderAutomation: function(v) {
	return Ext.htmlEncode(PVE.wdcb.Utils.automation[v] || v || gettext('Cluster default'));
    },

    // 0..1 utilization as a bar with the percentage
    renderUtil: function(v) {
	if (v === undefined || v === null || v === '') {
	    return '';
	}
	let pct = Math.round(Number(v) * 100);
	let color = pct > 100 ? '#c9302c' : pct > 80 ? '#ec971f' : '#3892d4';
	let w = Math.min(100, Math.max(0, pct));
	return `<div style="position:relative;height:14px;border:1px solid #bbb;border-radius:2px">`
	    + `<div style="width:${w}%;height:100%;background:${color}"></div>`
	    + `<div style="position:absolute;top:0;left:0;right:0;text-align:center;font-size:11px;line-height:14px">${pct}%</div></div>`;
    },

    renderScore: function(v) {
	if (v === undefined || v === null || v === '') {
	    return '';
	}
	let n = Number(v);
	let color = n >= 80 ? '#21bf4b' : n >= 60 ? '#a0a000' : n >= 40 ? '#ec971f' : '#c9302c';
	return `<span style="color:${color};font-weight:bold">${Math.round(n)}%</span>`;
    },

    renderPriority: function(v) {
	let n = Number(v) || 0;
	let label = n === 1 ? gettext('1 (mandatory)') : String(n);
	return n === 1 ? `<b>${Ext.htmlEncode(label)}</b>` : Ext.htmlEncode(label);
    },

    renderGuest: function(value, meta, rec) {
	let name = rec.data.name ? ` (${rec.data.name})` : '';
	return Ext.htmlEncode(`${rec.data.vmid}${name}`);
    },

    renderTime: function(v) {
	return v ? Ext.htmlEncode(Proxmox.Utils.render_timestamp(v)) : '';
    },

    request: function(opts) {
	Proxmox.Utils.API2Request(Ext.apply({
	    failure: response => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
	}, opts));
    },

    // POST that starts a task, then show the task
    task: function(path, params, panel) {
	PVE.wdcb.Utils.request({
	    url: PVE.wdcb.Utils.url(path),
	    method: 'POST',
	    params: params || {},
	    waitMsgTarget: panel,
	    success: function(response) {
		let win = Ext.create('Proxmox.window.TaskViewer', { upid: response.result.data });
		win.on('destroy', () => panel.reload && panel.reload());
		win.show();
	    },
	});
    },

    enterMaintenance: function(node, panel) {
	Ext.create('Ext.window.Window', {
	    title: Ext.String.format(gettext('Enter maintenance mode: {0}'), node),
	    modal: true,
	    width: 480,
	    bodyPadding: 10,
	    layout: 'anchor',
	    items: [
		{ xtype: 'displayfield', value: gettext('Running guests are moved to other nodes now (HA guests through HA node maintenance). Nothing is placed on this node until it leaves maintenance mode.') },
		{ xtype: 'checkbox', itemId: 'stopped', boxLabel: gettext('Also move powered-off guests') },
	    ],
	    buttons: [{
		text: gettext('Enter maintenance mode'),
		handler: function() {
		    let win = this.up('window');
		    let stopped = win.down('#stopped').getValue();
		    win.close();
		    PVE.wdcb.Utils.task(`maintenance/${encodeURIComponent(node)}/enter`, stopped ? { 'move-stopped': 1 } : {}, panel);
		},
	    }],
	}).show();
    },

    exitMaintenance: function(node, panel) {
	PVE.wdcb.Utils.request({
	    url: PVE.wdcb.Utils.url(`maintenance/${encodeURIComponent(node)}/exit`),
	    method: 'POST',
	    waitMsgTarget: panel,
	    success: () => panel.reload(),
	});
    },

    // Power On (balanced): with manual automation, show where and let the user pick
    powerOn: function(vmids, panel) {
	PVE.wdcb.Utils.request({
	    url: PVE.wdcb.Utils.url('settings'),
	    method: 'GET',
	    success: function(response) {
		let manual = response.result.data.automation === 'manual';
		if (manual && vmids.length === 1) {
		    Ext.create('PVE.wdcb.PlacementWindow', { vmid: vmids[0], panel }).show();
		} else {
		    PVE.wdcb.Utils.task('poweron', { vmids: vmids.join(',') }, panel);
		}
	    },
	});
    },

    // apply recommendations (all when ids is undefined) and follow the task
    apply: function(ids, panel) {
	let n = ids ? ids.length : gettext('all');
	Ext.Msg.confirm(gettext('Apply recommendations'),
	    Ext.htmlEncode(Ext.String.format(gettext('Migrate the guests of {0} recommendation(s) now? Containers are restarted on their new node.'), n)),
	    function(btn) {
		if (btn !== 'yes') {
		    return;
		}
		PVE.wdcb.Utils.request({
		    url: PVE.wdcb.Utils.url('apply'),
		    method: 'POST',
		    params: ids ? { ids: ids.join(',') } : {},
		    waitMsgTarget: panel,
		    success: function(response) {
			let win = Ext.create('Proxmox.window.TaskViewer', { upid: response.result.data });
			win.on('destroy', () => panel.reload());
			win.show();
		    },
		});
	    });
    },
});

Ext.define('PVE.wdcb.BaseGrid', {
    extend: 'Ext.grid.Panel',

    stateful: true,

    initComponent: function() {
	let me = this;
	me.store = Ext.create('Ext.data.Store', {
	    proxy: { type: 'proxmox', url: '/api2/json' + PVE.wdcb.Utils.url(me.wdcbPath) },
	    sorters: me.wdcbSorters || [],
	});
	me.tbar = (me.tbar || []).concat(['->', {
	    text: gettext('Reload'),
	    iconCls: 'fa fa-refresh',
	    handler: () => me.reload(),
	}]);
	me.callParent();
	Proxmox.Utils.monStoreErrors(me, me.store);
	me.on('activate', () => me.reload());
	me.on('itemdblclick', () => me.onEdit && me.onEdit());
    },

    reload: function() {
	this.store.load();
	if (this.afterReload) {
	    this.afterReload();
	}
    },

    selected: function() {
	let sel = this.getSelection();
	return sel.length ? sel[0] : undefined;
    },
});

// "Run now" (vSphere: Run DRS Now) for any panel that shows pass results
PVE.wdcb.runNowButton = function(panel) {
    return {
	text: gettext('Run now'),
	iconCls: 'fa fa-play',
	handler: () => PVE.wdcb.Utils.request({
	    url: PVE.wdcb.Utils.url('run'),
	    method: 'POST',
	    waitMsgTarget: panel,
	    success: () => panel.reload(),
	}),
    };
};

Ext.define('PVE.wdcb.Summary', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveWdcbSummary',

    title: gettext('Summary'),
    layout: { type: 'vbox', align: 'stretch' },

    initComponent: function() {
	let me = this;
	me.nodeStore = Ext.create('Ext.data.Store', { sorters: 'node' });
	me.tbar = [
	    PVE.wdcb.runNowButton(me),
	    {
		text: gettext('Resume automation'),
		itemId: 'resume',
		iconCls: 'fa fa-play-circle',
		hidden: true,
		handler: () => Ext.Msg.confirm(gettext('Resume automation'),
		    gettext('Automation was paused because moves failed. Resume it now?'), function(btn) {
			if (btn !== 'yes') {
			    return;
			}
			PVE.wdcb.Utils.request({
			    url: PVE.wdcb.Utils.url('resume'),
			    method: 'POST',
			    waitMsgTarget: me,
			    success: () => me.reload(),
			});
		    }),
	    },
	    '->',
	    { text: gettext('Reload'), iconCls: 'fa fa-refresh', handler: () => me.reload() },
	];
	me.items = [
	    { xtype: 'component', itemId: 'info', padding: 10 },
	    {
		xtype: 'grid',
		flex: 1,
		store: me.nodeStore,
		title: gettext('Nodes'),
		columns: PVE.wdcb.Utils.safeColumns([
		    { header: gettext('Node'), dataIndex: 'node', width: 140 },
		    {
			header: gettext('State'),
			dataIndex: 'online',
			width: 100,
			renderer: (v, m, rec) => Ext.htmlEncode(!v ? gettext('offline')
			    : rec.data.maintenance ? gettext('maintenance') : gettext('online')),
		    },
		    { header: gettext('CPUs'), dataIndex: 'maxcpu', width: 60 },
		    { header: gettext('Memory'), dataIndex: 'maxmem', width: 90, renderer: v => Ext.htmlEncode(Proxmox.Utils.format_size(v)) },
		    { header: gettext('Guests'), dataIndex: 'guests', width: 70 },
		    { header: gettext('CPU demand'), dataIndex: 'cpu', flex: 1, renderer: PVE.wdcb.Utils.renderUtil },
		    { header: gettext('Memory demand'), dataIndex: 'mem', flex: 1, renderer: PVE.wdcb.Utils.renderUtil },
		    { header: gettext('CPU after recommendations'), dataIndex: 'expected_cpu', flex: 1, renderer: PVE.wdcb.Utils.renderUtil },
		    { header: gettext('Memory after recommendations'), dataIndex: 'expected_mem', flex: 1, renderer: PVE.wdcb.Utils.renderUtil },
		]),
	    },
	];
	me.callParent();
	me.on('activate', () => me.reload());
    },

    reload: function() {
	let me = this;
	PVE.wdcb.Utils.request({
	    url: PVE.wdcb.Utils.url('status'),
	    method: 'GET',
	    success: response => me.showStatus(response.result.data),
	});
    },

    showStatus: function(d) {
	let me = this;
	let enc = Ext.htmlEncode;
	let c = d.cluster || {};
	let s = d.settings || {};
	let html = '';
	if (c.crs_conflict) {
	    html += `<div style="padding:6px;margin-bottom:8px;border:1px solid #c9302c;color:#c9302c">`
		+ enc(gettext('Proxmox CRS automatic rebalancing (Datacenter > Options > Cluster Resource Scheduling, ha-auto-rebalance) is on. Two balancers would compete, so no moves are made until it is turned off.'))
		+ '</div>';
	}
	if (d.breaker) {
	    html += `<div style="padding:6px;margin-bottom:8px;border:1px solid #c9302c;color:#c9302c">`
		+ enc(Ext.String.format(gettext('Automation is paused since {0}: {1}. Moves are still recommended; resume automation once the cause is fixed.'),
		    Proxmox.Utils.render_timestamp(d.breaker.time), d.breaker.reason))
		+ '</div>';
	}
	if (c.quorate === 0) {
	    html += `<div style="padding:6px;margin-bottom:8px;border:1px solid #c9302c;color:#c9302c">`
		+ enc(gettext('The cluster is not quorate: no moves are recommended until quorum is back.'))
		+ '</div>';
	} else if (c.hold) {
	    html += `<div style="padding:6px;margin-bottom:8px;border:1px solid #f0ad4e">`
		+ enc(Ext.String.format(gettext('Load balancing is on hold: {0}. Only mandatory moves are recommended.'), c.hold))
		+ '</div>';
	}
	if (d.applying) {
	    html += `<div style="padding:6px;margin-bottom:8px;border:1px solid #3892d4">`
		+ enc(Ext.String.format(gettext('Applying {0} recommendation(s) (task on {1}, started {2}).'),
		    d.applying.count, d.applying.node, Proxmox.Utils.render_timestamp(d.applying.time)))
		+ '</div>';
	}
	if (!d.time) {
	    html += enc(gettext('No balancing pass yet. The timer runs one within a few minutes, or click Run now.'));
	} else {
	    let buckets = c.buckets || {};
	    let total = Object.values(buckets).reduce((a, b) => a + b, 0) || 1;
	    let bars = ['0-20', '20-40', '40-60', '60-80', '80-100'].map(function(b) {
		let n = buckets[b] || 0;
		let h = Math.round(60 * n / total);
		return `<div style="display:inline-block;width:56px;margin-right:6px;text-align:center;vertical-align:bottom">`
		    + `<div style="height:${60 - h}px"></div><div style="height:${h}px;background:#3892d4"></div>`
		    + `<div style="font-size:11px">${enc(b)}%</div><div style="font-size:11px">${n}</div></div>`;
	    }).join('');
	    html += '<table style="border-spacing:12px 2px"><tr><td style="vertical-align:top">'
		+ `<div style="font-size:13px">${enc(gettext('Cluster score'))}</div>`
		+ `<div style="font-size:32px">${PVE.wdcb.Utils.renderScore(c.score)}</div>`
		+ `<div>${enc(gettext('After recommendations'))}: ${PVE.wdcb.Utils.renderScore(c.expected)}</div>`
		+ `<div>${enc(gettext('Imbalance'))}: ${enc(String(c.imbalance))} &rarr; ${enc(String(c.expected_imbalance))}</div>`
		+ '</td><td style="vertical-align:top;padding-left:24px">'
		+ `<div style="font-size:13px">${enc(gettext('VM scores'))}</div>${bars}`
		+ '</td><td style="vertical-align:top;padding-left:24px">'
		+ `<div>${enc(gettext('Automation'))}: ${PVE.wdcb.Utils.renderAutomation(s.automation)}</div>`
		+ `<div>${enc(gettext('Migration threshold'))}: ${enc(String(s.threshold))} &mdash; ${enc(PVE.wdcb.Utils.thresholds[s.threshold] || '')}</div>`
		+ `<div>${enc(gettext('Guests'))}: ${enc(String(c.running || 0))} ${enc(gettext('running'))}, ${enc(String(c.movable || 0))} ${enc(gettext('can be moved'))}</div>`
		+ `<div>${enc(gettext('Recommendations'))}: ${enc(String(d.recommendations))}, ${enc(gettext('faults'))}: ${enc(String(d.faults))}</div>`
		+ `<div>${enc(gettext('Last pass'))}: ${PVE.wdcb.Utils.renderTime(d.time)} (${enc(d.node || '')}, ${enc(String(d.duration))} s)</div>`
		+ `<div>${enc(gettext('Next pass'))}: ${PVE.wdcb.Utils.renderTime(d.next)}</div>`
		+ '</td></tr></table>';
	}
	me.down('#resume').setHidden(!d.breaker);
	me.down('#info').update(html);
	me.nodeStore.setData(d.nodes || []);
    },
});

Ext.define('PVE.wdcb.ExplainWindow', {
    extend: 'Ext.window.Window',

    width: 820,
    height: 360,
    modal: true,
    layout: 'fit',

    initComponent: function() {
	let me = this;
	me.title = Ext.String.format(gettext('Placement of guest {0}'), me.vmid);
	let store = Ext.create('Ext.data.Store', {
	    proxy: { type: 'proxmox', url: '/api2/json' + PVE.wdcb.Utils.url('explain') + `?vmid=${encodeURIComponent(me.vmid)}` },
	    sorters: 'node',
	});
	me.items = [{
	    xtype: 'grid',
	    store,
	    columns: PVE.wdcb.Utils.safeColumns([
		{ header: gettext('Node'), dataIndex: 'node', width: 140, renderer: (v, m, rec) => Ext.htmlEncode(v + (rec.data.current ? ` (${gettext('current')})` : '')) },
		{ header: gettext('Allowed'), dataIndex: 'ok', width: 70, renderer: v => Ext.htmlEncode(Proxmox.Utils.format_boolean(v)) },
		{ header: gettext('VM score there'), dataIndex: 'score', width: 110, renderer: PVE.wdcb.Utils.renderScore },
		{ header: gettext('Gain'), dataIndex: 'gain', width: 70 },
		{ header: gettext('CPU'), dataIndex: 'cpu', width: 90, renderer: PVE.wdcb.Utils.renderUtil },
		{ header: gettext('Memory'), dataIndex: 'mem', width: 90, renderer: PVE.wdcb.Utils.renderUtil },
		{ header: gettext('Why not'), dataIndex: 'reason', flex: 1 },
	    ]),
	}];
	me.callParent();
	Proxmox.Utils.monStoreErrors(me.down('grid'), store);
	store.load();
    },
});

Ext.define('PVE.wdcb.PlacementWindow', {
    extend: 'Ext.window.Window',

    width: 700,
    height: 340,
    modal: true,
    layout: 'fit',

    initComponent: function() {
	let me = this;
	me.title = Ext.String.format(gettext('Power On (balanced): guest {0}'), me.vmid);
	let store = Ext.create('Ext.data.Store', { sorters: [{ property: 'ok', direction: 'DESC' }, { property: 'score', direction: 'DESC' }] });
	me.items = [{
	    xtype: 'grid',
	    store,
	    columns: PVE.wdcb.Utils.safeColumns([
		{ header: gettext('Node'), dataIndex: 'node', width: 140,
		    renderer: (v, m, rec) => Ext.htmlEncode(v + (v === me.recommended ? ` (${gettext('recommended')})` : '')) },
		{ header: gettext('Allowed'), dataIndex: 'ok', width: 70, renderer: v => Ext.htmlEncode(Proxmox.Utils.format_boolean(v)) },
		{ header: gettext('VM score there'), dataIndex: 'score', width: 110, renderer: PVE.wdcb.Utils.renderScore },
		{ header: gettext('Why not'), dataIndex: 'reason', flex: 1 },
	    ]),
	}];
	me.buttons = [{
	    text: gettext('Power on here'),
	    handler: function() {
		let sel = me.down('grid').getSelection()[0];
		let node = sel ? sel.data.node : me.recommended;
		if (!node || (sel && !sel.data.ok)) {
		    return;
		}
		me.close();
		PVE.wdcb.Utils.task('poweron', { vmids: String(me.vmid), target: node }, me.panel);
	    },
	}];
	me.callParent();
	PVE.wdcb.Utils.request({
	    url: PVE.wdcb.Utils.url('placement'),
	    method: 'GET',
	    params: { vmids: String(me.vmid) },
	    waitMsgTarget: me,
	    success: function(response) {
		let p = (response.result.data || [])[0] || {};
		me.recommended = p.to;
		store.setData(p.ranking || []);
		let rec = store.findRecord('node', p.to, 0, false, true, true);
		if (rec) {
		    me.down('grid').getSelectionModel().select(rec);
		}
	    },
	});
    },
});

Ext.define('PVE.wdcb.MaintenanceGrid', {
    extend: 'PVE.wdcb.BaseGrid',
    alias: 'widget.pveWdcbMaintenanceGrid',

    title: gettext('Maintenance'),
    wdcbPath: 'maintenance',
    stateId: 'grid-wdcb-maintenance',

    columns: PVE.wdcb.Utils.safeColumns([
	{ header: gettext('Node'), dataIndex: 'node', width: 140 },
	{ header: gettext('State'), dataIndex: 'state', width: 160 },
	{ header: gettext('Since'), dataIndex: 'since', width: 160, renderer: PVE.wdcb.Utils.renderTime },
	{ header: gettext('By'), dataIndex: 'user', width: 120 },
	{ header: gettext('Running guests'), dataIndex: 'running', width: 110 },
	{ header: gettext("Can't be moved"), dataIndex: 'blocked', flex: 1 },
    ]),

    initComponent: function() {
	let me = this;
	me.tbar = [
	    {
		xtype: 'proxmoxButton',
		text: gettext('Enter maintenance mode'),
		disabled: true,
		enableFn: rec => !rec.data.maintenance,
		handler: () => PVE.wdcb.Utils.enterMaintenance(me.selected().data.node, me),
	    },
	    {
		xtype: 'proxmoxButton',
		text: gettext('Exit maintenance mode'),
		disabled: true,
		enableFn: rec => !!rec.data.maintenance,
		handler: () => PVE.wdcb.Utils.exitMaintenance(me.selected().data.node, me),
	    },
	];
	me.callParent();
    },
});

// Node > Load Balancing: this node's state and guests, maintenance mode
Ext.define('PVE.wdcb.NodePanel', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveWdcbNodePanel',

    layout: { type: 'vbox', align: 'stretch' },

    initComponent: function() {
	let me = this;
	if (!me.nodename) {
	    throw "no node name specified";
	}
	me.guestStore = Ext.create('Ext.data.Store', { sorters: 'vmid' });
	me.tbar = [
	    { text: gettext('Enter maintenance mode'), itemId: 'enter', handler: () => PVE.wdcb.Utils.enterMaintenance(me.nodename, me) },
	    { text: gettext('Exit maintenance mode'), itemId: 'exit', handler: () => PVE.wdcb.Utils.exitMaintenance(me.nodename, me) },
	    '->',
	    { text: gettext('Reload'), iconCls: 'fa fa-refresh', handler: () => me.reload() },
	];
	me.items = [
	    { xtype: 'component', itemId: 'info', padding: 10 },
	    {
		xtype: 'grid',
		flex: 1,
		store: me.guestStore,
		columns: PVE.wdcb.Utils.safeColumns([
		    { header: 'ID', dataIndex: 'vmid', width: 70 },
		    { header: gettext('Name'), dataIndex: 'name', flex: 1 },
		    { header: gettext('Status'), dataIndex: 'status', width: 80 },
		    { header: gettext('VM score'), dataIndex: 'score', width: 80, renderer: PVE.wdcb.Utils.renderScore },
		    { header: gettext('Automation'), dataIndex: 'automation', width: 110, renderer: PVE.wdcb.Utils.renderAutomation },
		    { header: gettext('Can be moved'), dataIndex: 'movable', width: 100, renderer: v => Ext.htmlEncode(Proxmox.Utils.format_boolean(v)) },
		    { header: gettext('Why not'), dataIndex: 'reason', flex: 2 },
		]),
	    },
	];
	me.callParent();
	me.on('activate', () => me.reload());
    },

    reload: function() {
	let me = this;
	PVE.wdcb.Utils.request({
	    url: PVE.wdcb.Utils.url('maintenance'),
	    method: 'GET',
	    success: function(response) {
		let m = (response.result.data || []).find(x => x.node === me.nodename) || { state: 'online' };
		me.down('#enter').setDisabled(!!m.maintenance);
		me.down('#exit').setDisabled(!m.maintenance);
		me.down('#info').update(Ext.htmlEncode(`${gettext('State')}: ${m.state}`
		    + (m.maintenance ? `, ${gettext('since')} ${Proxmox.Utils.render_timestamp(m.since)} (${m.user})` : '')
		    + (m.blocked ? `. ${gettext("Can't be moved")}: ${m.blocked}` : '')));
	    },
	});
	PVE.wdcb.Utils.request({
	    url: PVE.wdcb.Utils.url('guests'),
	    method: 'GET',
	    success: response => me.guestStore.setData((response.result.data || []).filter(g => g.node === me.nodename)),
	});
    },
});

Ext.define('PVE.wdcb.RecGrid', {
    extend: 'PVE.wdcb.BaseGrid',
    alias: 'widget.pveWdcbRecGrid',

    title: gettext('Recommendations'),
    wdcbPath: 'recommendations',
    stateId: 'grid-wdcb-recommendations',
    emptyText: gettext('No recommendations.'),

    columns: PVE.wdcb.Utils.safeColumns([
	{ header: gettext('Priority'), dataIndex: 'priority', width: 100, renderer: PVE.wdcb.Utils.renderPriority },
	{ header: gettext('Guest'), dataIndex: 'vmid', width: 200, renderer: PVE.wdcb.Utils.renderGuest },
	{ header: gettext('From'), dataIndex: 'from', width: 120 },
	{ header: gettext('To'), dataIndex: 'to', width: 120 },
	{ header: gettext('Reason'), dataIndex: 'reason', flex: 1 },
	{ header: gettext('Rule'), dataIndex: 'rule', width: 120 },
	{ header: gettext('Gain'), dataIndex: 'gain', width: 70 },
	{
	    header: gettext('Notes'),
	    dataIndex: 'ha',
	    width: 160,
	    renderer: (v, m, rec) => Ext.htmlEncode([v ? gettext('HA guest') : '', rec.data.restart ? gettext('restarts (container)') : '']
		.filter(x => x).join(', ')),
	},
    ]),

    selModel: { selType: 'rowmodel', mode: 'MULTI' },

    initComponent: function() {
	let me = this;
	me.tbar = [
	    PVE.wdcb.runNowButton(me),
	    {
		xtype: 'proxmoxButton',
		text: gettext('Apply'),
		iconCls: 'fa fa-check',
		disabled: true,
		handler: () => PVE.wdcb.Utils.apply(me.getSelection().map(r => r.data.id), me),
	    },
	    {
		text: gettext('Apply all'),
		iconCls: 'fa fa-check-square-o',
		handler: () => me.store.getCount() && PVE.wdcb.Utils.apply(undefined, me),
	    },
	    {
		xtype: 'proxmoxButton',
		text: gettext('Dismiss'),
		disabled: true,
		handler: () => {
		    let rec = me.selected();
		    PVE.wdcb.Utils.request({
			url: PVE.wdcb.Utils.url('dismiss'),
			method: 'POST',
			params: { id: rec.data.id },
			success: () => me.reload(),
		    });
		},
	    },
	    {
		xtype: 'proxmoxButton',
		text: gettext('Placement'),
		disabled: true,
		handler: () => Ext.create('PVE.wdcb.ExplainWindow', { vmid: me.selected().data.vmid }).show(),
	    },
	];
	me.callParent();
    },
});

Ext.define('PVE.wdcb.OverrideEdit', {
    extend: 'Proxmox.window.Edit',

    subject: gettext('VM override'),
    width: 420,

    initComponent: function() {
	let me = this;
	me.isCreate = !me.vmid;
	me.method = 'PUT';
	me.submitUrl = (url, values) => PVE.wdcb.Utils.url(`overrides/${encodeURIComponent(me.vmid || values.vmid)}`);
	me.items = [{
	    xtype: 'inputpanel',
	    onGetValues: function(values) {
		me.vmid = me.vmid || values.vmid;
		delete values.vmid;
		return values;
	    },
	    items: [
		me.isCreate
		    ? { xtype: 'pveGuestIDSelector', name: 'vmid', fieldLabel: 'VM ID', loadNextFreeID: false, validateExists: true }
		    : { xtype: 'displayfield', name: 'vmid', fieldLabel: 'VM ID', value: me.vmid },
		{
		    xtype: 'proxmoxKVComboBox',
		    name: 'automation',
		    fieldLabel: gettext('Automation level'),
		    value: me.automation || 'disabled',
		    comboItems: ['disabled', 'manual', 'partial', 'full'].map(k => [k, PVE.wdcb.Utils.automation[k]]),
		},
		{ xtype: 'displayfield', userCls: 'pmx-hint',
		    value: gettext('Disabled: never moved for balancing or rules. Manual and partially automated: recommendations only. Fully automated: moved automatically, even when the cluster is set to manual.') },
	    ],
	}];
	me.url = PVE.wdcb.Utils.url('overrides');
	me.callParent();
    },
});

Ext.define('PVE.wdcb.GuestGrid', {
    extend: 'PVE.wdcb.BaseGrid',
    alias: 'widget.pveWdcbGuestGrid',

    title: gettext('Guests'),
    wdcbPath: 'guests',
    stateId: 'grid-wdcb-guests',
    wdcbSorters: 'vmid',
    selModel: { selType: 'rowmodel', mode: 'MULTI' },

    columns: PVE.wdcb.Utils.safeColumns([
	{ header: 'ID', dataIndex: 'vmid', width: 70 },
	{ header: gettext('Name'), dataIndex: 'name', flex: 1 },
	{ header: gettext('Type'), dataIndex: 'type', width: 60 },
	{ header: gettext('Node'), dataIndex: 'node', width: 120 },
	{ header: gettext('Status'), dataIndex: 'status', width: 80 },
	{ header: gettext('VM score'), dataIndex: 'score', width: 80, renderer: PVE.wdcb.Utils.renderScore },
	{ header: gettext('After'), dataIndex: 'expected', width: 70, renderer: PVE.wdcb.Utils.renderScore },
	{ header: gettext('CPU demand (cores)'), dataIndex: 'cpu_demand', width: 120 },
	{ header: gettext('Memory demand'), dataIndex: 'mem_demand', width: 110, renderer: v => Ext.htmlEncode(v ? Proxmox.Utils.format_size(v) : '') },
	{ header: 'HA', dataIndex: 'ha', width: 50, renderer: v => Ext.htmlEncode(v ? Proxmox.Utils.yesText : '') },
	{ header: gettext('Automation'), dataIndex: 'automation', width: 110, renderer: PVE.wdcb.Utils.renderAutomation },
	{ header: gettext('Can be moved'), dataIndex: 'movable', width: 100, renderer: v => Ext.htmlEncode(Proxmox.Utils.format_boolean(v)) },
	{ header: gettext('Why not'), dataIndex: 'reason', flex: 2 },
    ]),

    initComponent: function() {
	let me = this;
	me.tbar = [
	    {
		xtype: 'proxmoxButton',
		text: gettext('Placement'),
		disabled: true,
		handler: () => Ext.create('PVE.wdcb.ExplainWindow', { vmid: me.selected().data.vmid }).show(),
	    },
	    {
		xtype: 'proxmoxButton',
		text: gettext('Power On (balanced)'),
		iconCls: 'fa fa-play',
		disabled: true,
		enableFn: rec => rec.data.status === 'stopped',
		handler: () => PVE.wdcb.Utils.powerOn(me.getSelection().filter(r => r.data.status === 'stopped').map(r => r.data.vmid), me),
	    },
	    {
		xtype: 'proxmoxButton',
		text: gettext('Set override'),
		disabled: true,
		handler: () => {
		    let w = Ext.create('PVE.wdcb.OverrideEdit', { vmid: me.selected().data.vmid, automation: 'disabled' });
		    w.on('destroy', () => me.reload());
		    w.show();
		},
	    },
	];
	me.callParent();
    },
});

Ext.define('PVE.wdcb.FaultGrid', {
    extend: 'PVE.wdcb.BaseGrid',
    alias: 'widget.pveWdcbFaultGrid',

    title: gettext('Faults'),
    wdcbPath: 'faults',
    stateId: 'grid-wdcb-faults',
    emptyText: gettext('No faults.'),

    columns: PVE.wdcb.Utils.safeColumns([
	{ header: gettext('Type'), dataIndex: 'type', width: 110 },
	{ header: gettext('Rule'), dataIndex: 'rule', width: 140 },
	{ header: gettext('Guests'), dataIndex: 'vmids', width: 140, renderer: v => Ext.htmlEncode((v || []).join(', ')) },
	{ header: gettext('Message'), dataIndex: 'message', flex: 1 },
    ]),
});

Ext.define('PVE.wdcb.HistoryGrid', {
    extend: 'PVE.wdcb.BaseGrid',
    alias: 'widget.pveWdcbHistoryGrid',

    title: gettext('History'),
    wdcbPath: 'history',
    stateId: 'grid-wdcb-history',

    columns: PVE.wdcb.Utils.safeColumns([
	{ header: gettext('Time'), dataIndex: 'time', width: 160, renderer: PVE.wdcb.Utils.renderTime },
	{ header: gettext('Event'), dataIndex: 'type', width: 90 },
	{ header: gettext('Node'), dataIndex: 'node', width: 120 },
	{ header: gettext('Trigger / user'), dataIndex: 'trigger', width: 180, renderer: (v, m, rec) => Ext.htmlEncode(v || rec.data.user || '') },
	{ header: gettext('Cluster score'), dataIndex: 'score', width: 100, renderer: PVE.wdcb.Utils.renderScore },
	{ header: gettext('Recommendations'), dataIndex: 'recommendations', width: 120 },
	{ header: gettext('Faults'), dataIndex: 'faults', width: 70 },
	{
	    header: gettext('Details'),
	    dataIndex: 'id',
	    flex: 1,
	    renderer: function(v, m, rec) {
		let d = rec.data;
		if (d.type === 'dismiss') {
		    return Ext.htmlEncode(Ext.String.format(gettext('guest {0}: {1} to {2}'), d.vmid, d.from, d.to));
		}
		if (d.type === 'move') {
		    return Ext.htmlEncode(Ext.String.format(gettext('guest {0}: {1} to {2}, {3}'), d.vmid, d.from, d.to,
			d.result === 'ok' ? `OK (${d.duration} s)` : `${d.result}: ${d.message || ''}`));
		}
		if (d.type === 'ha-rules') {
		    return Ext.htmlEncode([].concat(d.changes || [], d.errors || []).join('; '));
		}
		return '';
	    },
	},
    ]),
});

Ext.define('PVE.wdcb.SettingsEdit', {
    extend: 'Proxmox.window.Edit',

    subject: gettext('Load balancing'),
    width: 640,
    method: 'PUT',

    initComponent: function() {
	let me = this;
	me.url = PVE.wdcb.Utils.url('settings');
	let hint = function(v) {
	    let f = me.down('#thresholdHint');
	    if (f) {
		f.setValue(PVE.wdcb.Utils.thresholds[v] || '');
	    }
	};
	me.items = [{
	    xtype: 'inputpanel',
	    onGetValues: function(values) {
		values.network_aware = values.network_aware ? 1 : 0;
		values.notify = values.notify ? 1 : 0;
		return values;
	    },
	    column1: [
		{
		    xtype: 'proxmoxKVComboBox',
		    name: 'automation',
		    fieldLabel: gettext('Automation level'),
		    comboItems: ['manual', 'partial', 'full'].map(k => [k, PVE.wdcb.Utils.automation[k]]),
		},
		{
		    xtype: 'sliderfield',
		    name: 'threshold',
		    fieldLabel: gettext('Migration threshold'),
		    minValue: 1,
		    maxValue: 5,
		    increment: 1,
		    value: 3,
		    listeners: { change: (f, v) => hint(v) },
		},
		{ xtype: 'displayfield', itemId: 'thresholdHint', userCls: 'pmx-hint', value: PVE.wdcb.Utils.thresholds[3] },
		{ xtype: 'proxmoxintegerfield', name: 'interval', fieldLabel: gettext('Pass interval (s)'), minValue: 60, maxValue: 86400 },
		{
		    xtype: 'proxmoxKVComboBox',
		    name: 'memory_metric',
		    fieldLabel: gettext('Memory demand'),
		    comboItems: [['active', gettext('Active memory')], ['consumed', gettext('Consumed memory')]],
		},
		{
		    xtype: 'proxmoxKVComboBox',
		    name: 'containers',
		    fieldLabel: gettext('Containers'),
		    comboItems: [['manual', gettext('Recommend only (a move restarts them)')], ['restart', gettext('May be moved with a restart')]],
		},
	    ],
	    column2: [
		{ xtype: 'proxmoxintegerfield', name: 'max_moves', fieldLabel: gettext('Max. moves per pass'), minValue: 1, maxValue: 256 },
		{ xtype: 'proxmoxintegerfield', name: 'max_concurrent', fieldLabel: gettext('Max. concurrent per node'), minValue: 1, maxValue: 16 },
		{ xtype: 'proxmoxintegerfield', name: 'cooldown', fieldLabel: gettext('Cooldown after a move (s)'), minValue: 0, maxValue: 86400 },
		{ xtype: 'proxmoxintegerfield', name: 'headroom', fieldLabel: gettext('Memory headroom (%)'), minValue: 0, maxValue: 50 },
		{ xtype: 'proxmoxintegerfield', name: 'migration_speed', fieldLabel: gettext('Migration speed (MB/s)'), minValue: 10, maxValue: 100000 },
		{ xtype: 'proxmoxcheckbox', name: 'network_aware', fieldLabel: gettext('Network-aware'), defaultValue: 0, deleteDefaultValue: false },
		{ xtype: 'proxmoxintegerfield', name: 'net_capacity', fieldLabel: gettext('Network capacity (MB/s)'), minValue: 10, maxValue: 1000000 },
		{ xtype: 'proxmoxintegerfield', name: 'net_threshold', fieldLabel: gettext('Network saturated at (%)'), minValue: 10, maxValue: 100 },
		{ xtype: 'proxmoxcheckbox', name: 'notify', fieldLabel: gettext('Notifications'), defaultValue: 0, deleteDefaultValue: false },
	    ],
	    columnB: [
		{ xtype: 'displayfield', userCls: 'pmx-hint',
		    value: gettext('Fully automated: the recommendations within the threshold are applied every pass. Partially automated and manual: recommendations only; apply them yourself.') },
	    ],
	}];
	me.callParent();
	me.load({
	    success: function(response) {
		let d = response.result.data;
		me.setValues(d);
		hint(d.threshold);
	    },
	});
    },
});

Ext.define('PVE.wdcb.SettingsView', {
    extend: 'Proxmox.grid.ObjectGrid',
    alias: 'widget.pveWdcbSettingsView',

    title: gettext('Configuration'),

    initComponent: function() {
	let me = this;
	me.url = '/api2/json' + PVE.wdcb.Utils.url('settings');
	me.rows = {
	    automation: { header: gettext('Automation level'), renderer: PVE.wdcb.Utils.renderAutomation },
	    threshold: { header: gettext('Migration threshold'),
		renderer: v => Ext.htmlEncode(`${v} - ${PVE.wdcb.Utils.thresholds[v] || ''}`) },
	    interval: { header: gettext('Pass interval (s)') },
	    memory_metric: { header: gettext('Memory demand') },
	    containers: { header: gettext('Containers') },
	    max_moves: { header: gettext('Max. moves per pass') },
	    max_concurrent: { header: gettext('Max. concurrent per node') },
	    cooldown: { header: gettext('Cooldown after a move (s)') },
	    headroom: { header: gettext('Memory headroom (%)') },
	    migration_speed: { header: gettext('Migration speed (MB/s)') },
	    network_aware: { header: gettext('Network-aware'), renderer: Proxmox.Utils.format_boolean },
	    net_capacity: { header: gettext('Network capacity (MB/s)') },
	    net_threshold: { header: gettext('Network saturated at (%)') },
	    notify: { header: gettext('Notifications'), renderer: Proxmox.Utils.format_boolean },
	};
	let edit = () => {
	    let w = Ext.create('PVE.wdcb.SettingsEdit');
	    w.on('destroy', () => me.rstore.load());
	    w.show();
	};
	me.tbar = [{ text: gettext('Edit'), handler: edit }];
	me.listeners = { itemdblclick: edit, activate: () => me.rstore.load() };
	me.callParent();
	me.rstore.load();
    },
});

Ext.define('PVE.wdcb.GroupEdit', {
    extend: 'Proxmox.window.Edit',

    subject: gettext('Group'),
    width: 520,

    initComponent: function() {
	let me = this;
	let rec = me.record || {};
	me.isCreate = !rec.name;
	me.method = me.isCreate ? 'POST' : 'PUT';
	me.url = PVE.wdcb.Utils.url('groups' + (me.isCreate ? '' : `/${encodeURIComponent(rec.name)}`));
	me.items = [{
	    xtype: 'inputpanel',
	    onGetValues: function(values) {
		if (!me.isCreate) {
		    delete values.name;
		    delete values.kind;
		}
		return values;
	    },
	    items: [
		{ xtype: me.isCreate ? 'textfield' : 'displayfield', name: 'name', fieldLabel: gettext('Name'), value: rec.name || '',
		    regex: /^[A-Za-z][A-Za-z0-9_.-]{0,63}$/, allowBlank: false },
		{
		    xtype: 'proxmoxKVComboBox',
		    name: 'kind',
		    fieldLabel: gettext('Type'),
		    value: rec.kind || 'vm',
		    disabled: !me.isCreate,
		    comboItems: [['vm', gettext('VM group')], ['host', gettext('Host group')]],
		},
		{ xtype: 'textfield', name: 'members', fieldLabel: gettext('Members'), value: (rec.members || []).join(','),
		    allowBlank: false, emptyText: gettext('VM IDs or node names, comma separated') },
		{ xtype: 'textfield', name: 'comment', fieldLabel: gettext('Comment'), value: rec.comment || '' },
	    ],
	}];
	me.callParent();
    },
});

Ext.define('PVE.wdcb.GroupGrid', {
    extend: 'PVE.wdcb.BaseGrid',
    alias: 'widget.pveWdcbGroupGrid',

    title: gettext('VM/Host Groups'),
    wdcbPath: 'groups',
    stateId: 'grid-wdcb-groups',

    columns: PVE.wdcb.Utils.safeColumns([
	{ header: gettext('Name'), dataIndex: 'name', width: 160 },
	{ header: gettext('Type'), dataIndex: 'kind', width: 110, renderer: v => Ext.htmlEncode(v === 'host' ? gettext('Host group') : gettext('VM group')) },
	{ header: gettext('Members'), dataIndex: 'members', flex: 1, renderer: v => Ext.htmlEncode((v || []).join(', ')) },
	{ header: gettext('Comment'), dataIndex: 'comment', flex: 1 },
    ]),

    initComponent: function() {
	let me = this;
	let edit = function(rec) {
	    let w = Ext.create('PVE.wdcb.GroupEdit', { record: rec ? rec.data : undefined });
	    w.on('destroy', () => me.reload());
	    w.show();
	};
	me.onEdit = () => me.selected() && edit(me.selected());
	me.tbar = [
	    { text: gettext('Add'), handler: () => edit() },
	    { xtype: 'proxmoxButton', text: gettext('Edit'), disabled: true, handler: () => edit(me.selected()) },
	    {
		xtype: 'proxmoxStdRemoveButton',
		getUrl: rec => PVE.wdcb.Utils.url(`groups/${encodeURIComponent(rec.data.name)}`),
		callback: () => me.reload(),
	    },
	];
	me.callParent();
    },
});

Ext.define('PVE.wdcb.RuleEdit', {
    extend: 'Proxmox.window.Edit',

    subject: gettext('Rule'),
    width: 560,

    initComponent: function() {
	let me = this;
	let rec = me.record || {};
	me.isCreate = !rec.name;
	me.method = me.isCreate ? 'POST' : 'PUT';
	me.url = PVE.wdcb.Utils.url('rules' + (me.isCreate ? '' : `/${encodeURIComponent(rec.name)}`));

	let groupStore = Ext.create('Ext.data.Store', {
	    proxy: { type: 'proxmox', url: '/api2/json' + PVE.wdcb.Utils.url('groups') },
	    autoLoad: true,
	});
	let applyType = function(type) {
	    let form = me.down('form') && me.down('form').getForm();
	    if (!form) {
		return;
	    }
	    let vmHost = type === 'vm-host';
	    ['vm-group', 'host-group', 'mode'].forEach(n => {
		form.findField(n).setHidden(!vmHost);
		form.findField(n).setDisabled(!vmHost);
	    });
	    form.findField('vms').setHidden(vmHost);
	    form.findField('vms').setDisabled(vmHost);
	    form.isValid();
	};
	let groupCombo = (name, kind, label) => ({
	    xtype: 'combobox',
	    name,
	    fieldLabel: label,
	    value: rec[name] || '',
	    allowBlank: false,
	    editable: false,
	    queryMode: 'local',
	    displayField: 'name',
	    valueField: 'name',
	    store: Ext.create('Ext.data.ChainedStore', { source: groupStore, filters: [{ property: 'kind', value: kind }] }),
	});
	me.items = [{
	    xtype: 'inputpanel',
	    onGetValues: function(values) {
		if (!me.isCreate) {
		    delete values.name;
		}
		values.enabled = values.enabled ? 1 : 0;
		return values;
	    },
	    items: [
		{ xtype: me.isCreate ? 'textfield' : 'displayfield', name: 'name', fieldLabel: gettext('Name'), value: rec.name || '',
		    regex: /^[A-Za-z][A-Za-z0-9_.-]{0,63}$/, allowBlank: false },
		{ xtype: 'proxmoxcheckbox', name: 'enabled', fieldLabel: gettext('Enable rule'), checked: rec.enabled === undefined ? true : !!rec.enabled,
		    deleteDefaultValue: false, defaultValue: 0 },
		{
		    xtype: 'proxmoxKVComboBox',
		    name: 'type',
		    fieldLabel: gettext('Type'),
		    value: rec.type || 'together',
		    comboItems: [
			['together', gettext('Keep virtual machines together')],
			['separate', gettext('Separate virtual machines')],
			['vm-host', gettext('Virtual machines to hosts')],
		    ],
		    listeners: { change: (f, v) => applyType(v) },
		},
		{ xtype: 'textfield', name: 'vms', fieldLabel: gettext('VMs'), value: rec.vms || '', allowBlank: false,
		    emptyText: gettext('VM IDs, comma separated (at least two)') },
		groupCombo('vm-group', 'vm', gettext('VM group')),
		{
		    xtype: 'proxmoxKVComboBox',
		    name: 'mode',
		    fieldLabel: gettext('Mode'),
		    value: rec.mode || 'should',
		    comboItems: [
			['must', gettext('Must run on hosts in group')],
			['should', gettext('Should run on hosts in group')],
			['must-not', gettext('Must not run on hosts in group')],
			['should-not', gettext('Should not run on hosts in group')],
		    ],
		},
		groupCombo('host-group', 'host', gettext('Host group')),
		{ xtype: 'textfield', name: 'comment', fieldLabel: gettext('Comment'), value: rec.comment || '' },
		{ xtype: 'displayfield', userCls: 'pmx-hint',
		    value: gettext('Must rules are never broken by load balancing and are fixed first. Should rules are fixed when possible and never broken for balancing. A rule that conflicts with another enabled rule cannot be saved enabled.') },
	    ],
	}];
	me.callParent();
	applyType(rec.type || 'together');
    },
});

Ext.define('PVE.wdcb.RuleGrid', {
    extend: 'PVE.wdcb.BaseGrid',
    alias: 'widget.pveWdcbRuleGrid',

    title: gettext('VM/Host Rules'),
    wdcbPath: 'rules',
    stateId: 'grid-wdcb-rules',

    columns: PVE.wdcb.Utils.safeColumns([
	{ header: gettext('Name'), dataIndex: 'name', width: 160 },
	{ header: gettext('Enabled'), dataIndex: 'enabled', width: 70, renderer: v => Ext.htmlEncode(Proxmox.Utils.format_boolean(v)) },
	{
	    header: gettext('Type'),
	    dataIndex: 'type',
	    width: 200,
	    renderer: v => Ext.htmlEncode({
		together: gettext('Keep virtual machines together'),
		separate: gettext('Separate virtual machines'),
		'vm-host': gettext('Virtual machines to hosts'),
	    }[v] || v),
	},
	{
	    header: gettext('Members'),
	    dataIndex: 'vms',
	    flex: 1,
	    renderer: (v, m, rec) => Ext.htmlEncode(rec.data.type === 'vm-host'
		? `${rec.data['vm-group']} ${rec.data.mode} ${rec.data['host-group']}` : v),
	},
	{ header: gettext('State'), dataIndex: 'state', width: 180 },
	{ header: gettext('Comment'), dataIndex: 'comment', flex: 1 },
    ]),

    initComponent: function() {
	let me = this;
	let edit = function(rec) {
	    let w = Ext.create('PVE.wdcb.RuleEdit', { record: rec ? rec.data : undefined });
	    w.on('destroy', () => me.reload());
	    w.show();
	};
	me.onEdit = () => me.selected() && edit(me.selected());
	me.tbar = [
	    { text: gettext('Add'), handler: () => edit() },
	    { xtype: 'proxmoxButton', text: gettext('Edit'), disabled: true, handler: () => edit(me.selected()) },
	    {
		xtype: 'proxmoxStdRemoveButton',
		getUrl: rec => PVE.wdcb.Utils.url(`rules/${encodeURIComponent(rec.data.name)}`),
		callback: () => me.reload(),
	    },
	];
	me.callParent();
    },
});

Ext.define('PVE.wdcb.OverrideGrid', {
    extend: 'PVE.wdcb.BaseGrid',
    alias: 'widget.pveWdcbOverrideGrid',

    title: gettext('VM Overrides'),
    wdcbPath: 'overrides',
    stateId: 'grid-wdcb-overrides',

    columns: PVE.wdcb.Utils.safeColumns([
	{ header: gettext('Guest'), dataIndex: 'vmid', width: 220, renderer: PVE.wdcb.Utils.renderGuest },
	{ header: gettext('Automation level'), dataIndex: 'automation', flex: 1, renderer: PVE.wdcb.Utils.renderAutomation },
    ]),

    initComponent: function() {
	let me = this;
	let edit = function(rec) {
	    let w = Ext.create('PVE.wdcb.OverrideEdit', rec ? { vmid: rec.data.vmid, automation: rec.data.automation } : {});
	    w.on('destroy', () => me.reload());
	    w.show();
	};
	me.onEdit = () => me.selected() && edit(me.selected());
	me.tbar = [
	    { text: gettext('Add'), handler: () => edit() },
	    { xtype: 'proxmoxButton', text: gettext('Edit'), disabled: true, handler: () => edit(me.selected()) },
	    {
		xtype: 'proxmoxStdRemoveButton',
		getUrl: rec => PVE.wdcb.Utils.url(`overrides/${encodeURIComponent(rec.data.vmid)}`),
		callback: () => me.reload(),
	    },
	];
	me.callParent();
    },
});

Ext.define('PVE.wdcb.DcPanel', {
    extend: 'Ext.tab.Panel',
    alias: 'widget.pveWdcbDcPanel',

    border: false,

    items: [
	{ xtype: 'pveWdcbSummary' },
	{ xtype: 'pveWdcbRecGrid' },
	{ xtype: 'pveWdcbGuestGrid' },
	{ xtype: 'pveWdcbFaultGrid' },
	{ xtype: 'pveWdcbHistoryGrid' },
	{ xtype: 'pveWdcbSettingsView' },
	{ xtype: 'pveWdcbGroupGrid' },
	{ xtype: 'pveWdcbRuleGrid' },
	{ xtype: 'pveWdcbOverrideGrid' },
	{ xtype: 'pveWdcbMaintenanceGrid' },
    ],
});

Ext.define('PVE.wdcb.ConfigHook', {
    override: 'PVE.panel.Config',

    initComponent: function() {
	let me = this;
	try {
	    if (me.$className === 'PVE.dc.Config' && Ext.isArray(me.items) &&
		Ext.ClassManager.getByAlias('widget.pveWdcbDcPanel')) {
		// its own Datacenter entry, right after HA (or at the end)
		let caps = Ext.state.Manager.get('GuiCap');
		if (caps && ((caps.dc && caps.dc['Sys.Audit']) || caps.nodes['Sys.Audit'])) {
		    let idx = me.items.findIndex(item => item.itemId === 'ha');
		    let after = idx;
		    while (after >= 0 && after + 1 < me.items.length && Ext.Array.contains(me.items[after + 1].groups || [], 'ha')) {
			after++;
		    }
		    let entry = {
			xtype: 'pveWdcbDcPanel',
			title: gettext('Load Balancing'),
			itemId: 'wdcbalancer',
			iconCls: 'fa fa-balance-scale',
		    };
		    if (after >= 0) {
			me.items.splice(after + 1, 0, entry);
		    } else {
			me.items.push(entry);
		    }
		}
	    }
	    if (me.$className === 'PVE.node.Config' && Ext.isArray(me.items) &&
		Ext.ClassManager.getByAlias('widget.pveWdcbNodePanel')) {
		// Node > Load Balancing (state, guests, maintenance mode)
		let caps = Ext.state.Manager.get('GuiCap');
		if (caps && caps.nodes['Sys.Audit']) {
		    me.items.push({
			xtype: 'pveWdcbNodePanel',
			title: gettext('Load Balancing'),
			itemId: 'wdcbalancer',
			iconCls: 'fa fa-balance-scale',
			nodename: me.pveSelNode.data.node,
		    });
		}
	    }
	} catch (err) {
	    console.error('pve-wdcbalancer: Load Balancing panel not added', err);
	}
	me.callParent(arguments);
    },
});
