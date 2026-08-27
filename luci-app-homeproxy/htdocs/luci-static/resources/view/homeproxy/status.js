
'use strict';
'require dom';
'require form';
'require fs';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

const css = '				\
#log_textarea {				\
	padding: 10px;			\
	text-align: left;		\
}					\
#log_textarea pre {			\
	padding: .5rem;			\
	word-break: break-all;		\
	margin: 0;			\
}					\
.description {				\
	background-color: #33ccff;	\
}';

const hp_dir = '/var/run/homeproxy';

function pollJobStatus(fetchStatus, onTick, intervalMs) {
	return new Promise((resolve) => {
		let misses = 0;
		const tick = () => {
			L.resolveDefault(fetchStatus(), null).then((st) => {
				if (!st || !st.state || st.state === 'idle') {
					if (++misses > 5) {
						resolve({ state: 'error' });
						return;
					}
					setTimeout(tick, intervalMs);
					return;
				}
				misses = 0;
				onTick(st);
				if (st.state === 'running')
					setTimeout(tick, intervalMs);
				else
					resolve(st);
			});
		};
		tick();
	});
}

function getConnStat(o, site) {
	const callConnStat = rpc.declare({
		object: 'luci.homeproxy',
		method: 'connection_check',
		params: ['site'],
		expect: { '': {} }
	});

	o.default = E('div', { 'style': 'cbi-value-field' }, [
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, () => {
				return L.resolveDefault(callConnStat(site), {}).then((ret) => {
                                        let ele = o.default.firstElementChild.nextElementSibling;
					if (ret.result) {
						ele.style.setProperty('color', 'green');
                                                ele.innerHTML = _('passed');
					} else {
						ele.style.setProperty('color', 'red');
                                                ele.innerHTML = _('failed');
					}
				});
			})
		}, [ _('Check') ]),
		' ',
		E('strong', { 'style': 'color:gray' }, _('unchecked')),
	]);
}

function getResVersion(o, type) {
	const callResVersion = rpc.declare({
		object: 'luci.homeproxy',
		method: 'resources_get_version',
		params: ['type'],
		expect: { '': {} }
	});

	const callResUpdateStart = rpc.declare({
		object: 'luci.homeproxy',
		method: 'resources_update_start',
		params: ['type'],
		expect: { '': {} }
	});

	const callResUpdateStatus = rpc.declare({
		object: 'luci.homeproxy',
		method: 'resources_update_status',
		params: ['type'],
		expect: { '': {} }
	});

	return L.resolveDefault(callResVersion(type), {}).then((res) => {
		const versionEl = E('strong', { 'style': (res.error ? 'color:red' : 'color:green') },
			[ res.error ? 'not found' : res.version ]
		);
		const msgEl = E('span', { 'style': 'margin-left:8px; font-size:0.9em; color:gray' }, '');

		let spanTemp = E('div', { 'style': 'cbi-value-field' }, [
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, async function() {
					const start = await L.resolveDefault(callResUpdateStart(type), {});

					const updRes = start.result
						? await pollJobStatus(() => callResUpdateStatus(type), () => {}, 1500)
						: {};

					let msg, color;
					switch (updRes.state) {
					case 'success':
						msg = _('Successfully updated.'); color = 'green';
						break;
					case 'locked':
						msg = _('Already in updating.'); color = 'darkorange';
						break;
					case 'latest':
						msg = _('Already at the latest version.'); color = 'gray';
						break;
					case 'error':
						msg = _('Update failed.'); color = 'red';
						break;
					default:
						msg = _('Unknown error.'); color = 'red';
						break;
					}
					msgEl.textContent = msg;
					msgEl.style.color = color;

					const verRes = await L.resolveDefault(callResVersion(type), {});
					versionEl.textContent = verRes.error ? 'not found' : verRes.version;
					versionEl.style.color = verRes.error ? 'red' : 'green';
				})
			}, [ _('Check update') ]),
			' ',
			versionEl,
			msgEl
		]);

		o.default = spanTemp;
	});
}

function callCoreInfo() {
	return rpc.declare({ object: 'luci.homeproxy', method: 'core_info', expect: { '': {} } })();
}
function callCoreCheckRemote(core, channel) {
	return rpc.declare({ object: 'luci.homeproxy', method: 'core_check_remote', params: ['core', 'channel'], expect: { '': {} } })(core, channel);
}
function callCoreUpdateStart(channel) {
	return rpc.declare({ object: 'luci.homeproxy', method: 'core_update_start', params: ['channel'], expect: { '': {} } })(channel);
}
function callCoreUpdateStatus() {
	return rpc.declare({ object: 'luci.homeproxy', method: 'core_update_status', expect: { '': {} } })();
}
function callCoreRestore() {
	return rpc.declare({ object: 'luci.homeproxy', method: 'core_restore', expect: { '': {} } })();
}

function buildCoreContext() {
	const vendorEl = E('strong', { 'style': 'color:gray' }, _('Loading...'));
	const versionEl = E('strong', { 'style': 'color:gray' }, '');
	const restoreMsgEl = E('span', { 'style': 'margin-left:8px; font-size:0.9em' }, '');
	const setRestoreMsg = (txt, color) => { restoreMsgEl.textContent = txt; restoreMsgEl.style.color = color || 'gray'; };

	let restoreBtn;

	let busy = false;
	const lockables = [];
	function registerLockable(el) { lockables.push(el); return el; }
	function setBusy(state) {
		busy = state;
		for (let el of lockables) el.disabled = state || (el === restoreBtn && !restoreBtn.__hasBackup);
	}

	const savedChannel = uci.get('homeproxy', 'config', 'core_channel');
	const channelSelect = registerLockable(E('select', {
		'class': 'cbi-input-select',
		'change': ui.createHandlerFn(this, (ev) => {
			const newChannel = ev.target.value;
			uci.set('homeproxy', 'config', 'core_channel', newChannel);
			return uci.save().then(() => {
				return ui.changes.apply(true);
			}).catch((err) => {
				ui.addNotification(null, E('p', _('Failed to save channel: %s').format(err || '')), 'error');
			});
		})
	}, [
		E('option', { 'value': 'latest', 'selected': (savedChannel !== 'stable') ? '' : null }, [ _('Latest') ]),
		E('option', { 'value': 'stable', 'selected': (savedChannel === 'stable') ? '' : null }, [ _('Stable') ])
	]));
	const getChannel = () => channelSelect.value;

	function refreshStatus() {
		return L.resolveDefault(callCoreInfo(), {}).then((info) => {
			if (info.installed) {
				vendorEl.textContent = 'sing-box';
				vendorEl.style.color = 'green';
				versionEl.textContent = 'v' + info.version;
				versionEl.style.color = 'green';
			} else {
				vendorEl.textContent = _('Not detected');
				vendorEl.style.color = 'red';
				versionEl.textContent = '';
			}
			if (restoreBtn) {
				restoreBtn.__hasBackup = !!info.has_backup;
				restoreBtn.disabled = busy || !info.has_backup;
			}
			return info;
		});
	}

	function buildUpdateRow(core, label) {
		const remoteEl = E('strong', { 'style': 'color:gray; margin-left:8px; font-weight:normal; font-size:0.9em' }, '');

		const updateBtn = registerLockable(E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, async function() {
				if (busy) return;
				setBusy(true);
				remoteEl.textContent = _('Checking requirements...');
				remoteEl.style.color = 'gray';

				const start = await L.resolveDefault(callCoreUpdateStart(getChannel()), {});

				const final = start.result
					? await pollJobStatus(callCoreUpdateStatus, (st) => {
						if (st.stage === 'downloading')
							remoteEl.textContent = _('Downloading') + (st.version ? ' v' + st.version : '') + '...';
						else if (st.stage === 'installing')
							remoteEl.textContent = _('Installing (service will restart)...');
						else
							remoteEl.textContent = _('Checking requirements...');
						remoteEl.style.color = 'gray';
					}, 1500)
					: {};

				if (final.state === 'success') {
					remoteEl.textContent = _('Updated successfully');
					remoteEl.style.color = 'green';
				} else {
					remoteEl.textContent = final.message || _('Update failed.');
					remoteEl.style.color = 'red';
				}
				await refreshStatus();
				setBusy(false);
			})
		}, [ label ]));

		return E('div', { 'style': 'cbi-value-field' }, [ updateBtn, remoteEl ]);
	}

	function buildCheckRow(core) {
		const remoteEl = E('strong', { 'style': 'color:gray; margin-left:8px; font-weight:normal; font-size:0.9em' }, '');

		const checkBtn = registerLockable(E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(this, async function() {
				if (busy) return;
				setBusy(true);
				remoteEl.textContent = _('Checking...');
				remoteEl.style.color = 'gray';
				const ret = await L.resolveDefault(callCoreCheckRemote(core, getChannel()), {});
				setBusy(false);
				if (ret.error) {
					remoteEl.textContent = ret.error;
					remoteEl.style.color = 'red';
				} else {
					remoteEl.textContent = _('Latest') + ': v' + ret.version + (ret.prerelease ? ' (pre-release)' : '');
					remoteEl.style.color = 'darkorange';
				}
			})
		}, [ _('Check latest') ]));

		return E('div', { 'style': 'cbi-value-field' }, [ checkBtn, remoteEl ]);
	}

	restoreBtn = registerLockable(E('button', {
		'class': 'btn cbi-button cbi-button-negative',
		'disabled': true,
		'click': ui.createHandlerFn(this, async function() {
			if (busy) return;
			setBusy(true);
			setRestoreMsg(_('Restoring firmware-shipped version...'), 'gray');
			const ret = await L.resolveDefault(callCoreRestore(), {});
			if (ret.result) {
				setRestoreMsg(_('Restored successfully'), 'green');
				await refreshStatus();
			} else {
				setRestoreMsg(ret.error || _('Restore failed'), 'red');
			}
			setBusy(false);
		})
	}, [ _('Restore initial') ]));

	refreshStatus();

	return {
		vendorRow: E('div', { 'style': 'cbi-value-field' }, [ vendorEl ]),
		versionRow: E('div', { 'style': 'cbi-value-field' }, [ versionEl ]),
		channelRow: E('div', { 'style': 'cbi-value-field' }, [ channelSelect ]),
		officialRow: buildUpdateRow('official', _('Update core')),
		checkRow: buildCheckRow('official'),
		restoreRow: E('div', { 'style': 'cbi-value-field' }, [ restoreBtn, restoreMsgEl ])
	};
}

function getRuntimeLog(o, name, _option_index, section_id, _in_table) {
	const filename = o.option.split('_')[1];

	let section, log_level_el;
	switch (filename) {
	case 'homeproxy':
		section = null;
		break;
	case 'sing-box-c':
		section = 'config';
		break;
	case 'sing-box-s':
		section = 'server';
		break;
	}

	if (section) {
		const selected = uci.get('homeproxy', section, 'log_level') || 'warn';
		const choices = {
			trace: _('Trace'),
			debug: _('Debug'),
			info: _('Info'),
			warn: _('Warn'),
			error: _('Error'),
			fatal: _('Fatal'),
			panic: _('Panic')
		};

		log_level_el = E('select', {
			'id': o.cbid(section_id),
			'class': 'cbi-input-select',
			'style': 'margin-left: 4px; width: 6em;',
			'change': ui.createHandlerFn(this, (ev) => {
				uci.set('homeproxy', section, 'log_level', ev.target.value);
				return o.map.save(null, true).then(() => {
					ui.changes.apply(true);
				});
			})
		});

		Object.keys(choices).forEach((v) => {
			log_level_el.appendChild(E('option', {
				'value': v,
				'selected': (v === selected) ? '' : null
			}, [ choices[v] ]));
		});
	}

	const callLogClean = rpc.declare({
		object: 'luci.homeproxy',
		method: 'log_clean',
		params: ['type'],
		expect: { '': {} }
	});

	const log_textarea = E('div', { 'id': 'log_textarea' },
		E('img', {
			'src': L.resource('icons/loading.svg'),
			'alt': _('Loading'),
			'style': 'vertical-align:middle'
		}, _('Collecting data...'))
	);

	let log;
	poll.add(L.bind(() => {
		return fs.read_direct(String.format('%s/%s.log', hp_dir, filename), 'text')
		.then((res) => {
			log = E('pre', { 'wrap': 'pre' }, [
				res.trim() || _('Log is empty.')
			]);

			dom.content(log_textarea, log);
		}).catch((err) => {
			if (err.toString().includes('NotFoundError'))
				log = E('pre', { 'wrap': 'pre' }, [
					_('Log file does not exist.')
				]);
			else
				log = E('pre', { 'wrap': 'pre' }, [
					_('Unknown error: %s').format(err)
				]);

			dom.content(log_textarea, log);
		});
	}));

	return E([
		E('style', [ css ]),
		E('div', {'class': 'cbi-map'}, [
			E('h3', {'name': 'content', 'style': 'align-items: center; display: flex;'}, [
				_('%s log').format(name),
				log_level_el || '',
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'style': 'margin-left: 4px;',
					'click': ui.createHandlerFn(this, () => {
						return L.resolveDefault(callLogClean(filename), {});
					})
				}, [ _('Clean log') ])
			]),
			E('div', {'class': 'cbi-section'}, [
				log_textarea,
				E('div', {'style': 'text-align:right'},
					E('small', {}, _('Refresh every %s seconds.').format(L.env.pollinterval))
				)
			])
		])
	]);
}

return view.extend({
	render() {
		let m, s, o;

		m = new form.Map('homeproxy');

		s = m.section(form.NamedSection, 'config', 'homeproxy', _('Connection check'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_check_baidu', _('BaiDu'));
		o.cfgvalue = L.bind(getConnStat, this, o, 'baidu');

		o = s.option(form.DummyValue, '_check_google', _('Google'));
		o.cfgvalue = L.bind(getConnStat, this, o, 'google');

		s = m.section(form.NamedSection, 'config', 'homeproxy', _('Resources management'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_china_ip4_version', _('China IPv4 list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_ip4');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_china_ip6_version', _('China IPv6 list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_ip6');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_china_list_version', _('China list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_list');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_gfw_list_version', _('GFW list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'gfw_list');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_dashboard_version', _('Dashboard version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'dashboard');
		o.rawhtml = true;

		s = m.section(form.NamedSection, 'config', 'homeproxy', _('Core management'));
		s.anonymous = true;

		let coreCtx = null;
		const ensureCoreCtx = () => {
			if (!coreCtx)
				coreCtx = buildCoreContext.call(this);
			return coreCtx;
		};
		function bindCoreRow(opt, key) {
			opt.cfgvalue = () => { opt.default = ensureCoreCtx()[key]; };
			opt.rawhtml = true;
		}

		o = s.option(form.DummyValue, '_core_vendor', _('Active core'));
		bindCoreRow(o, 'vendorRow');

		o = s.option(form.DummyValue, '_core_version', _('Current version'));
		bindCoreRow(o, 'versionRow');

		o = s.option(form.DummyValue, '_core_channel', _('Update channel'));
		bindCoreRow(o, 'channelRow');

		o = s.option(form.DummyValue, '_core_official', _('SagerNet'));
		bindCoreRow(o, 'officialRow');

		o = s.option(form.DummyValue, '_core_check', _('Version check'));
		bindCoreRow(o, 'checkRow');

		o = s.option(form.DummyValue, '_core_restore', _('Restore core'));
		bindCoreRow(o, 'restoreRow');

		o = s.option(form.Value, 'github_token', _('GitHub token'));
		o.password = true;
		o.renderWidget = function() {
			let node = form.Value.prototype.renderWidget.apply(this, arguments);

			(node.querySelector('.control-group') || node).appendChild(E('button', {
				'class': 'cbi-button cbi-button-apply',
				'title': _('Save'),
				'click': ui.createHandlerFn(this, () => {
					return this.map.save(null, true).then(() => {
						ui.changes.apply(true);
					});
				}, this.option)
			}, [ _('Save') ]));

			return node;
		}

		s = m.section(form.NamedSection, 'config', 'homeproxy');
		s.anonymous = true;

		o = s.option(form.DummyValue, '_homeproxy_logview');
		o.render = L.bind(getRuntimeLog, this, o, _('HomeProxy'));

		o = s.option(form.DummyValue, '_sing-box-c_logview');
		o.render = L.bind(getRuntimeLog, this, o, _('sing-box client'));

		o = s.option(form.DummyValue, '_sing-box-s_logview');
		o.render = L.bind(getRuntimeLog, this, o, _('sing-box server'));

		return m.render();
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
