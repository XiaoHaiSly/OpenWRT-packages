
'use strict';
'require form';
'require fs';
'require network';
'require poll';
'require rpc';
'require uci';
'require ui';
'require validation';
'require view';

'require homeproxy as hp';
'require tools.firewall as fwtool';
'require tools.widgets as widgets';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

const callReadDomainList = rpc.declare({
	object: 'luci.homeproxy',
	method: 'acllist_read',
	params: ['type'],
	expect: { '': {} }
});

const callWriteDomainList = rpc.declare({
	object: 'luci.homeproxy',
	method: 'acllist_write',
	params: ['type', 'content'],
	expect: { '': {} }
});

function getServiceStatus() {
	return L.resolveDefault(callServiceList('homeproxy'), {}).then((res) => {
		let isRunning = false;
		try {
			isRunning = res['homeproxy']['instances']['sing-box-c']['running'];
		} catch (e) { }
		return isRunning;
	});
}

function renderStatus(isRunning, version) {
	let spanTemp = '<em><span style="color:%s"><strong>%s (sing-box v%s) %s</strong></span></em>';
	let renderHTML;
	if (isRunning)
		renderHTML = spanTemp.format('green', _('HomeProxy'), version, _('RUNNING'));
	else
		renderHTML = spanTemp.format('red', _('HomeProxy'), version, _('NOT RUNNING'));

	return renderHTML;
}

let stubValidator = {
	factory: validation,
	apply(type, value, args) {
		if (value != null)
			this.value = value;

		return validation.types[type].apply(this, args);
	},
	assert(condition) {
		return !!condition;
	}
};

function openDashboardUrl(apiPort, apiSecret) {
	const params = new URLSearchParams({
		host: window.location.hostname,
		hostname: window.location.hostname,
		port: apiPort,
		secret: apiSecret || ''
	}).toString();

	window.open(`http://${window.location.hostname}:${apiPort}/ui/?${params}`, '_blank');
}

function isCoreOnlyActive() {
	return uci.get('homeproxy', 'config', 'main_node') === 'core_only';
}

function isNormalModeActive() {
	let main_node = uci.get('homeproxy', 'config', 'main_node');
	return main_node !== 'core_only' && main_node !== 'nil';
}

function noopFeedback() {
	return new Promise((resolve) => setTimeout(resolve, 400));
}

const callRcInit = rpc.declare({
	object: 'rc',
	method: 'init',
	params: ['name', 'action']
});

function restartService(refreshStatus) {
	if (!isCoreOnlyActive())
		return noopFeedback();

	return callRcInit('homeproxy', 'restart').then(() => {
		return new Promise((resolve) => setTimeout(resolve, 1500));
	}).then(() => {
		if (refreshStatus)
			return refreshStatus();
	}).catch((err) => {
		ui.addNotification(null, E('p', _('Failed to restart the homeproxy service: %s').format(err)));
	});
}

function openDashboard() {
	if (!isCoreOnlyActive())
		return noopFeedback();

	const selection = uci.get('homeproxy', 'config', 'main_core_profile');
	if (!selection) {
		ui.addNotification(null, E('p', _('No core config file is selected yet.')));
		return;
	}

	let path;
	if (selection.indexOf('file:') === 0)
		path = '/etc/homeproxy/custom/' + selection.substring(5);
	else if (selection.indexOf('sub:') === 0)
		path = '/etc/homeproxy/custom/.subscriptions/' + selection.substring(4) + '.json';

	if (!path) {
		ui.addNotification(null, E('p', _('No core config file is selected yet.')));
		return;
	}

	function extractApiConfigs(conf) {
		let configs = [];

		if (Array.isArray(conf?.services)) {
			for (let svc of conf.services) {
				if (svc && svc.type === 'api' && svc.listen_port) {
					let label = (svc.dashboard && svc.dashboard.path) || _('Dashboard');
					configs.push({ port: svc.listen_port, secret: svc.secret, label: `${label} (:${svc.listen_port})` });
				}
			}
		}

		const clash = conf?.experimental?.clash_api;
		if (clash && clash.external_controller) {
			const port = clash.external_controller.substring(clash.external_controller.lastIndexOf(':') + 1);
			let label = clash.external_ui || _('Clash API');
			configs.push({ port: port, secret: clash.secret, label: `${label} (:${port})` });
		}

		return configs;
	}

	function pickDashboard(apis) {
		ui.showModal(_('Open dashboard'), [
			E('p', _('More than one dashboard is configured. Choose which one to open:')),
			E('div', { 'class': 'cbi-section' },
				apis.map((api) => E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'style': 'display:block; width:100%; margin-bottom:.5em;',
					'click': () => {
						ui.hideModal();
						openDashboardUrl(api.port, api.secret);
					}
				}, [api.label]))
			),
			E('div', { 'class': 'right' },
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel'))
			)
		]);
	}

	function openFromConfig(content) {
		let conf;
		try {
			conf = JSON.parse(content);
		} catch (e) {
			throw _('Failed to parse the core config file as JSON.');
		}

		const apis = extractApiConfigs(conf);
		if (apis.length === 0) {
			let err = new Error('no dashboard configured');
			err.silent = true;
			throw err;
		}

		if (apis.length === 1)
			openDashboardUrl(apis[0].port, apis[0].secret);
		else
			pickDashboard(apis);
	}

	return fs.read_direct('/var/run/homeproxy/sing-box-core.json', 'text').then((runtimeContent) => {
		openFromConfig(runtimeContent);
	}).catch(() => {
		return fs.read_direct(path, 'text').then((content) => {
			openFromConfig(content);
		});
	}).catch((err) => {
		if (err && err.silent)
			return;
		ui.addNotification(null, E('p', _('Failed to open dashboard: %s').format(err)));
	});
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('homeproxy'),
			hp.getBuiltinFeatures(),
			network.getHostHints(),
			L.resolveDefault(fs.list('/etc/homeproxy/custom'), [])
		]);
	},

	render(data) {
		let m, s, o, ss, so;

		let features = data[1],
		    hosts = data[2]?.hosts;

		let proxy_nodes = {};
		uci.sections(data[0], 'node', (res) => {
			let nodeaddr = ((res.type === 'direct') ? res.override_address : res.address) || '',
			    nodeport = ((res.type === 'direct') ? res.override_port : res.port) || '';

			proxy_nodes[res['.name']] =
				String.format('[%s] %s', res.type, res.label || ((stubValidator.apply('ip6addr', nodeaddr) ?
					String.format('[%s]', nodeaddr) : nodeaddr) + ':' + nodeport));
		});

		let core_profiles = {};
		for (let f of (data[3] || []))
			if (f.type === 'file')
				core_profiles['file:' + f.name] = f.name;
		uci.sections(data[0], 'custom_profile', (res) => {
			const profile_id = res.id || res['.name'];
			core_profiles['sub:' + profile_id] = res.label || profile_id;
		});

		function refreshStatus() {
			return L.resolveDefault(getServiceStatus()).then((res) => {
				let view = document.getElementById('service_status');
				if (view) view.innerHTML = renderStatus(res, features.version);

				return res;
			});
		}

		m = new form.Map('homeproxy', _('HomeProxy'),
			_('The modern ImmortalWrt proxy platform for ARM64/AMD64.'));

		m.handleSaveApply = function (ev, mode) {
			return form.Map.prototype.handleSaveApply.call(this, ev, mode).then((res) => {
				refreshStatus();
				return res;
			});
		};

		s = m.section(form.TypedSection);
		s.render = function () {
			poll.add(refreshStatus);

			return E('div', { class: 'cbi-section', id: 'status_bar' }, [
					E('p', { id: 'service_status' }, _('Collecting data...'))
			]);
		}

		s = m.section(form.NamedSection, 'config', 'homeproxy');

		s.tab('routing', _('Routing Settings'));
		s.tab('dashboard', _('Dashboard'));

		o = s.taboption('routing', form.ListValue, 'main_node', _('Main node'));
		o.value('nil', _('Disable'));
		o.value('core_only', _('Core only'));
		o.value('urltest', _('URLTest'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.default = 'nil';
		o.rmempty = false;

		o = s.taboption('routing', hp.CBIStaticList, 'main_urltest_nodes', _('URLTest nodes'),
			_('List of nodes to test.'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.depends('main_node', 'urltest');
		o.rmempty = false;

		o = s.taboption('routing', form.Value, 'main_urltest_interval', _('Test interval'),
			_('The test interval in seconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '180';
		o.depends('main_node', 'urltest');

		o = s.taboption('routing', form.Value, 'main_urltest_tolerance', _('Test tolerance'),
			_('The test tolerance in milliseconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '50';
		o.depends('main_node', 'urltest');

		o = s.taboption('routing', form.Flag, 'main_urltest_interrupt_exist_connections', _('Interrupt existing connections'));
		o.default = o.disabled;
		o.rmempty = false;
		o.depends('main_node', 'urltest');

		o = s.taboption('routing', form.ListValue, 'main_core_profile', _('Core config file'));
		if (!Object.keys(core_profiles).length)
			o.value('', _('-- none --'));
		else
			for (let i in core_profiles)
				o.value(i, core_profiles[i]);
		o.depends('main_node', 'core_only');
		o.rmempty = false;

		o = s.taboption('routing', form.ListValue, 'main_udp_node', _('Main UDP node'));
		o.value('nil', _('Disable'));
		o.value('same', _('Same as main node'));
		o.value('urltest', _('URLTest'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.default = 'same';
		o.depends({'proxy_mode': /^((?!redirect$).)+$/, 'main_node': /^((?!core_only).)+$/});
		o.rmempty = false;

		o = s.taboption('routing', form.Button, '_open_dashboard', _('Actions'));
		o.inputstyle = 'apply';
		o.inputtitle = _('Open dashboard');
		o.depends('main_node', 'core_only');
		o.onclick = function() {
			return openDashboard();
		}
		o.renderWidget = function() {
			let node = form.Button.prototype.renderWidget.apply(this, arguments);

			let restartBtn = E('button', {
				'class': 'cbi-button cbi-button-reset',
				'title': _('Restart the homeproxy service'),
				'click': ui.createHandlerFn(this, () => {
					return restartService(refreshStatus);
				}, this.option)
			}, [ _('Restart service') ]);

			return E('div', { 'style': 'display: flex; flex-wrap: wrap; align-items: center; gap: .5em; max-width: 100%' }, [
				node,
				restartBtn
			]);
		}

		o = s.taboption('routing', hp.CBIStaticList, 'main_udp_urltest_nodes', _('URLTest nodes'),
			_('List of nodes to test.'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.depends({'main_udp_node': 'urltest', 'main_node': /^((?!core_only).)+$/});
		o.rmempty = false;

		o = s.taboption('routing', form.Value, 'main_udp_urltest_interval', _('Test interval'),
			_('The test interval in seconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '180';
		o.depends({'main_udp_node': 'urltest', 'main_node': /^((?!core_only).)+$/});

		o = s.taboption('routing', form.Value, 'main_udp_urltest_tolerance', _('Test tolerance'),
			_('The test tolerance in milliseconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '50';
		o.depends({'main_udp_node': 'urltest', 'main_node': /^((?!core_only).)+$/});

		o = s.taboption('routing', form.Flag, 'main_udp_urltest_interrupt_exist_connections', _('Interrupt existing connections'));
		o.default = o.disabled;
		o.rmempty = false;
		o.depends({'main_udp_node': 'urltest', 'main_node': /^((?!core_only).)+$/});

		o = s.taboption('routing', form.Value, 'dns_server', _('DNS server'),
			_('Support UDP, TCP, DoH, DoQ, DoT. TCP protocol will be used if not specified.'));
		o.value('wan', _('WAN DNS (read from interface)'));
		o.value('1.1.1.1', _('CloudFlare Public DNS (1.1.1.1)'));
		o.value('9.9.9.9', _('Quad9 Public DNS (9.9.9.9)'));
		o.value('8.8.8.8', _('Google Public DNS (8.8.8.8)'));
		o.value('', '---');
		o.value('223.5.5.5', _('Aliyun Public DNS (223.5.5.5)'));
		o.value('180.184.1.1', _('ByteDance Public DNS (180.184.1.1)'));
		o.value('119.29.29.29', _('Tencent Public DNS (119.29.29.29)'));
		o.default = '8.8.8.8';
		o.rmempty = false;
		o.depends({'routing_mode': 'gfwlist', 'main_node': /^((?!core_only).)+$/});
		o.depends({'routing_mode': 'bypass_mainland_china', 'main_node': /^((?!core_only).)+$/});
		o.depends({'routing_mode': 'proxy_mainland_china', 'main_node': /^((?!core_only).)+$/});
		o.depends({'routing_mode': 'global', 'main_node': /^((?!core_only).)+$/});
		o.validate = function(section_id, value) {
			if (section_id && !['wan'].includes(value)) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));

				let ipv6_support = this.section.formvalue(section_id, 'ipv6_support');
				try {
					let url = new URL(value.replace(/^.*:\/\//, 'http://'));
					if (stubValidator.apply('hostname', url.hostname))
						return true;
					else if (stubValidator.apply('ip4addr', url.hostname))
						return true;
					else if ((ipv6_support === '1') && stubValidator.apply('ip6addr', url.hostname.match(/^\[(.+)\]$/)?.[1]))
						return true;
					else
						return _('Expecting: %s').format(_('valid DNS server address'));
				} catch(e) {}

				if (!stubValidator.apply((ipv6_support === '1') ? 'ipaddr' : 'ip4addr', value))
					return _('Expecting: %s').format(_('valid DNS server address'));
			}

			return true;
		}

		o = s.taboption('routing', form.Value, 'china_dns_server', _('China DNS server'),
			_('The dns server for resolving China domains. Support UDP, TCP, DoH, DoQ, DoT.'));
		o.value('wan', _('WAN DNS (read from interface)'));
		o.value('223.5.5.5', _('Aliyun Public DNS (223.5.5.5)'));
		o.value('180.184.1.1', _('ByteDance Public DNS (180.184.1.1)'));
		o.value('119.29.29.29', _('Tencent Public DNS (119.29.29.29)'));
		o.depends({'routing_mode': 'bypass_mainland_china', 'main_node': /^((?!core_only).)+$/});
		o.default = '223.5.5.5';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (section_id && !['wan'].includes(value)) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));

				try {
					let url = new URL(value.replace(/^.*:\/\//, 'http://'));
					if (stubValidator.apply('hostname', url.hostname))
						return true;
					else if (stubValidator.apply('ip4addr', url.hostname))
						return true;
					else if (stubValidator.apply('ip6addr', url.hostname.match(/^\[(.+)\]$/)?.[1]))
						return true;
					else
						return _('Expecting: %s').format(_('valid DNS server address'));
				} catch(e) {}

				if (!stubValidator.apply('ipaddr', value))
					return _('Expecting: %s').format(_('valid DNS server address'));
			}

			return true;
		}

		o = s.taboption('routing', form.ListValue, 'routing_mode', _('Routing mode'));
		o.value('gfwlist', _('GFWList'));
		o.value('bypass_mainland_china', _('Bypass mainland China'));
		o.value('proxy_mainland_china', _('Only proxy mainland China'));
		o.value('global', _('Global'));
		o.default = 'bypass_mainland_china';
		o.rmempty = false;
		o.depends({'main_node': /^((?!core_only).)+$/});

		o = s.taboption('routing', form.Value, 'routing_port', _('Routing ports'),
			_('Specify target ports to be proxied. Multiple ports must be separated by commas.'));
		o.value('', _('All ports'));
		o.value('common', _('Common ports only (bypass P2P traffic)'));
		o.default = 'common';
		o.depends({'main_node': /^((?!core_only).)+$/});
		o.validate = function(section_id, value) {
			if (section_id && value && value !== 'common') {

				let ports = [];
				for (let i of value.split(',')) {
					if (!stubValidator.apply('port', i) && !stubValidator.apply('portrange', i))
						return _('Expecting: %s').format(_('valid port value'));
					if (ports.includes(i))
						return _('Port %s alrealy exists!').format(i);
					ports = ports.concat(i);
				}
			}

			return true;
		}

		o = s.taboption('routing', form.ListValue, 'proxy_mode', _('Proxy mode'));
		o.value('redirect', _('Redirect TCP'));
		if (features.hp_has_tproxy)
			o.value('redirect_tproxy', _('Redirect TCP + TProxy UDP'));
		if (features.hp_has_ip_full && features.hp_has_tun) {
			o.value('redirect_tun', _('Redirect TCP + Tun UDP'));
			o.value('tun', _('Tun TCP/UDP'));
		} else {
			o.description = _('To enable Tun support, you need to install <code>ip-full</code> and <code>kmod-tun</code>');
		}
		o.default = 'redirect_tproxy';
		o.rmempty = false;
		o.depends({'main_node': /^((?!core_only).)+$/});

		o = s.taboption('routing', form.ListValue, 'tcpip_stack', _('TCP/IP stack'),
			_('TCP/IP stack.'));
		if (features.with_gvisor) {
			o.value('mixed', _('Mixed'));
			o.value('gvisor', _('gVisor'));
		}
		o.value('system', _('System'));
		o.default = 'system';
		o.depends({'proxy_mode': 'redirect_tun', 'main_node': /^((?!core_only).)+$/});
		o.depends({'proxy_mode': 'tun', 'main_node': /^((?!core_only).)+$/});
		o.rmempty = false;
		o.onchange = function(ev, section_id, value) {
			let desc = ev.target.nextElementSibling;
			if (value === 'mixed')
				desc.innerHTML = _('Mixed <code>system</code> TCP stack and <code>gVisor</code> UDP stack.')
			else if (value === 'gvisor')
				desc.innerHTML = _('Based on google/gvisor.');
			else if (value === 'system')
				desc.innerHTML = _('Less compatibility and sometimes better performance.');
		}

		o = s.taboption('routing', form.Flag, 'endpoint_independent_nat', _('Enable endpoint-independent NAT'),
			_('Performance may degrade slightly, so it is not recommended to enable on when it is not needed.'));
		o.default = o.disabled;
		o.depends({'tcpip_stack': 'mixed', 'proxy_mode': 'redirect_tun', 'main_node': /^((?!core_only).)+$/});
		o.depends({'tcpip_stack': 'mixed', 'proxy_mode': 'tun', 'main_node': /^((?!core_only).)+$/});
		o.depends({'tcpip_stack': 'gvisor', 'proxy_mode': 'redirect_tun', 'main_node': /^((?!core_only).)+$/});
		o.depends({'tcpip_stack': 'gvisor', 'proxy_mode': 'tun', 'main_node': /^((?!core_only).)+$/});
		o.rmempty = false;

		o = s.taboption('routing', form.Flag, 'ipv6_support', _('IPv6 support'));
		o.default = o.disabled;
		o.rmempty = false;
		o.depends({'main_node': /^((?!core_only).)+$/});

		o = s.taboption('routing', form.Flag, 'auto_restart', _('Auto Restart'),
			_('Periodically restart the HomeProxy service.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('routing', form.Value, 'auto_restart_cron', _('Restart schedule'),
			_('Standard 5-field cron expression, e.g. <code>0 2 * * *</code> for every day at 2:00.'));
		o.default = '0 2 * * *';
		o.placeholder = '0 2 * * *';
		o.depends('auto_restart', '1');
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (value && value.trim().split(/\s+/).length !== 5)
				return _('Expecting: a 5-field cron expression, e.g. %s').format('"0 2 * * *"');
			return true;
		};

		o = s.taboption('dashboard', form.Value, 'dashboard_port', _('Listen port'));
		o.default = '9096';
		o.datatype = 'port';
		o.rmempty = false;
		o.depends({'main_node': /^((?!core_only).)+$/});

		o = s.taboption('dashboard', form.Value, 'dashboard_secret', _('API secret'));
		o.password = true;
		o.rmempty = true;
		o.depends({'main_node': /^((?!core_only).)+$/});

		o = s.taboption('dashboard', form.Button, '_open_dashboard_normal', _('sing-box dashboard'));
		o.inputtitle = _('Open dashboard');
		o.inputstyle = 'apply';
		o.depends({'main_node': /^((?!core_only).)+$/});
		o.onclick = function() {
			if (!isNormalModeActive())
				return noopFeedback();

			let host = window.location.hostname,
			    port = uci.get('homeproxy', 'config', 'dashboard_port') || '9096';
			if (host.includes(':') && !host.startsWith('['))
				host = '[' + host + ']';
			window.open('http://' + host + ':' + port + '/dashboard/', '_blank', 'noopener,noreferrer');
		};

		s.tab('control', _('Access Control'));

		o = s.taboption('control', form.SectionValue, '_control', form.NamedSection, 'control', 'homeproxy');
		ss = o.subsection;

		ss.tab('interface', _('Interface Control'));

		so = ss.taboption('interface', widgets.DeviceSelect, 'listen_interfaces', _('Listen interfaces'),
			_('Only process traffic from specific interfaces. Leave empty for all.'));
		so.multiple = true;
		so.noaliases = true;

		so = ss.taboption('interface', widgets.DeviceSelect, 'bind_interface', _('Bind interface'),
			_('Bind outbound traffic to specific interface. Leave empty to auto detect.'));
		so.multiple = false;
		so.noaliases = true;

		ss.tab('lan_ip_policy', _('LAN IP Policy'));

		so = ss.taboption('lan_ip_policy', form.ListValue, 'lan_proxy_mode', _('Proxy filter mode'));
		so.value('disabled', _('Disable'));
		so.value('listed_only', _('Proxy listed only'));
		so.value('except_listed', _('Proxy all except listed'));
		so.default = 'disabled';
		so.rmempty = false;

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_direct_ipv4_ips', _('Direct IPv4 IP-s'), null, 'ipv4', hosts, true);
		so.depends('lan_proxy_mode', 'except_listed');

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_direct_ipv6_ips', _('Direct IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends({'lan_proxy_mode': 'except_listed', 'homeproxy.config.ipv6_support': '1'});

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_direct_mac_addrs', _('Direct MAC-s'), null, hosts);
		so.depends('lan_proxy_mode', 'except_listed');

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_proxy_ipv4_ips', _('Proxy IPv4 IP-s'), null, 'ipv4', hosts, true);
		so.depends('lan_proxy_mode', 'listed_only');

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_proxy_ipv6_ips', _('Proxy IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends({'lan_proxy_mode': 'listed_only', 'homeproxy.config.ipv6_support': '1'});

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_proxy_mac_addrs', _('Proxy MAC-s'), null, hosts);
		so.depends('lan_proxy_mode', 'listed_only');

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_gaming_mode_ipv4_ips', _('Gaming mode IPv4 IP-s'), null, 'ipv4', hosts, true);

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_gaming_mode_ipv6_ips', _('Gaming mode IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends('homeproxy.config.ipv6_support', '1');

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_gaming_mode_mac_addrs', _('Gaming mode MAC-s'), null, hosts);

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_global_proxy_ipv4_ips', _('Global proxy IPv4 IP-s'), null, 'ipv4', hosts, true);

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_global_proxy_ipv6_ips', _('Global proxy IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends('homeproxy.config.ipv6_support', '1');

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_global_proxy_mac_addrs', _('Global proxy MAC-s'), null, hosts);

		ss.tab('wan_ip_policy', _('WAN IP Policy'));

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_proxy_ipv4_ips', _('Proxy IPv4 IP-s'));
		so.datatype = 'or(ip4addr, cidr4)';

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_proxy_ipv6_ips', _('Proxy IPv6 IP-s'));
		so.datatype = 'or(ip6addr, cidr6)';
		so.depends('homeproxy.config.ipv6_support', '1');

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_direct_ipv4_ips', _('Direct IPv4 IP-s'));
		so.datatype = 'or(ip4addr, cidr4)';

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_direct_ipv6_ips', _('Direct IPv6 IP-s'));
		so.datatype = 'or(ip6addr, cidr6)';
		so.depends('homeproxy.config.ipv6_support', '1');

		ss.tab('proxy_domain_list', _('Proxy Domain List'));

		so = ss.taboption('proxy_domain_list', form.TextValue, '_proxy_domain_list');
		so.rows = 10;
		so.monospace = true;
		so.datatype = 'hostname';
		so.load = function() {
			return L.resolveDefault(callReadDomainList('proxy_list')).then((res) => {
				return res.content;
			}, {});
		}
		so.write = function(_section_id, value) {
			return callWriteDomainList('proxy_list', value);
		}
		so.remove = function() {
			return callWriteDomainList('proxy_list', '');
		}
		so.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n'))
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));

			return true;
		}

		ss.tab('direct_domain_list', _('Direct Domain List'));

		so = ss.taboption('direct_domain_list', form.TextValue, '_direct_domain_list');
		so.rows = 10;
		so.monospace = true;
		so.datatype = 'hostname';
		so.load = function() {
			return L.resolveDefault(callReadDomainList('direct_list')).then((res) => {
				return res.content;
			}, {});
		}
		so.write = function(_section_id, value) {
			return callWriteDomainList('direct_list', value);
		}
		so.remove = function() {
			return callWriteDomainList('direct_list', '');
		}
		so.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n'))
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));

			return true;
		}

		return m.render();
	}
});
