#!/usr/bin/ucode -S

'use strict';

import { md5 } from 'digest';
import { open } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';

import { urldecode, urlencode } from 'luci.http';

import {
	curlGET, decodeBase64Str, getTime, isEmpty, parseURL,
	validation, HP_DIR, RUN_DIR,
	reconcileUrltestNodes, synchronizeNodeLabels
} from 'homeproxy';

const uci = cursor();

const uciconfig = 'homeproxy';
uci.load(uciconfig);

const ucimain = 'config',
      ucinode = 'node',
      ucisubscription = 'subscription';

const allow_insecure = uci.get(uciconfig, ucisubscription, 'allow_insecure') || '0',
      filter_mode = uci.get(uciconfig, ucisubscription, 'filter_nodes') || 'disabled',
      filter_keywords = uci.get(uciconfig, ucisubscription, 'filter_keywords') || [],
      packet_encoding = uci.get(uciconfig, ucisubscription, 'packet_encoding') || 'xudp',
      subscription_urls = uci.get(uciconfig, ucisubscription, 'subscription_url') || [],
      user_agent = uci.get(uciconfig, ucisubscription, 'user_agent'),
      via_proxy = uci.get(uciconfig, ucisubscription, 'update_via_proxy') || '0';

function filter_check(name) {
	if (isEmpty(name) || filter_mode === 'disabled' || isEmpty(filter_keywords))
		return false;

	let ret = false;
	for (let i in filter_keywords) {
		const patten = regexp(i);
		if (match(name, patten))
			ret = true;
	}
	if (filter_mode === 'whitelist')
		ret = !ret;

	return ret;
}

function init_action(service, action) {
	return system(`/etc/init.d/${service} ${action} >/dev/null 2>&1`);
}

const node_cache = {},
      node_result = [];

const ubus = connect();
const sing_features = ubus.call('luci.homeproxy', 'singbox_get_features', {}) || {};

system(`mkdir -p ${RUN_DIR}`);
function log(...args) {
	const logfile = open(`${RUN_DIR}/homeproxy.log`, 'a');
	logfile.write(`${getTime()} [SUBSCRIBE] ${join(' ', args)}\n`);
	logfile.close();
}

function has_value(value) {
	return value !== null && value !== '' && value !== 'nil';
}

function to_string(value) {
	return has_value(value) ? sprintf('%s', value) : null;
}

function bool_to_uci(value) {
	if (value === true)
		return '1';
	if (value === false)
		return '0';
	return null;
}

function normalize_list(value) {
	if (!has_value(value))
		return null;
	if (type(value) === 'array')
		return value;
	return [to_string(value)];
}

function normalize_alpn(value) {
	if (!has_value(value))
		return null;
	if (type(value) === 'array')
		return value;
	if (type(value) === 'string') {
		let items = map(split(value, ','), (v) => trim(v));
		items = filter(items, (v) => length(v));
		return length(items) ? items : null;
	}
	return [to_string(value)];
}

function normalize_host_list(value) {
	if (!has_value(value))
		return null;
	if (type(value) === 'array')
		return value;
	return split(to_string(value), ',');
}

function normalize_first(value) {
	if (!has_value(value))
		return null;
	if (type(value) === 'array')
		return length(value) ? value[0] : null;
	return to_string(value);
}

function normalize_hysteria_hopping_port(mport) {
	if (!has_value(mport))
		return null;

	let ports = [];
	for (let p in split(to_string(mport), ',')) {
		p = trim(p);
		if (!p)
			continue;
		if (match(p, /^\d+$/))
			p = p + ':' + p;
		else
			p = replace(p, '-', ':');
		push(ports, p);
	}

	return length(ports) ? ports : null;
}

function normalize_mihomo_ports(ports) {
	if (!has_value(ports))
		return null;

	if (type(ports) === 'array')
		return map(ports, (p) => {
			const v = to_string(p);
			if (match(v, /^\d+$/))
				return v + ':' + v;
			return replace(v, '-', ':');
		});

	return normalize_hysteria_hopping_port(to_string(ports));
}

function parse_mihomo_speed(value) {
	if (!has_value(value))
		return null;

	const str = to_string(value);
	const match_val = match(str, /[0-9]+(\.[0-9]+)?/);
	if (!match_val)
		return null;

	const num_str = type(match_val) === 'array' ? match_val[0] : match_val;
	if (!num_str)
		return null;

	const num = int(num_str);
	if (num === null || num != num)
		return null;

	return to_string(num);
}

function get_header_host(headers) {
	if (type(headers) !== 'object')
		return null;

	return headers.Host || headers.host || headers['HOST'];
}

function apply_transport_opts(config, proxy) {
	const network = proxy.network;
	if (!has_value(network) || network === 'tcp')
		return;

	let ws_opts = proxy['ws-opts'] || {};
	let grpc_opts = proxy['grpc-opts'] || {};
	let http_opts = proxy['http-opts'] || proxy['h2-opts'] || {};
	let httpupgrade_opts = proxy['http-upgrade-opts'] || {};

	switch (network) {
	case 'ws':
		config.transport = 'ws';
		config.ws_path = ws_opts.path ? to_string(ws_opts.path) : null;
		config.ws_host = get_header_host(ws_opts.headers);
		config.websocket_early_data = ws_opts['early-data'] ? to_string(ws_opts['early-data']) : null;
		config.websocket_early_data_header = ws_opts['early-data-header-name'] ?
			to_string(ws_opts['early-data-header-name']) : null;
		break;
	case 'grpc':
		config.transport = 'grpc';
		config.grpc_servicename = to_string(grpc_opts['grpc-service-name'] || grpc_opts['service-name']);
		break;
	case 'http':
	case 'h2':
		config.transport = 'http';
		config.http_path = normalize_first(http_opts.path);
		config.http_host = normalize_host_list(get_header_host(http_opts.headers) || http_opts.host);
		break;
	case 'httpupgrade':
		config.transport = 'httpupgrade';
		config.httpupgrade_host = get_header_host(httpupgrade_opts.headers) || httpupgrade_opts.host;
		config.http_path = normalize_first(httpupgrade_opts.path);
		break;
	}
}
function parse_mihomo_proxy(proxy) {
	if (type(proxy) !== 'object')
		return null;

	let config;
	const tls_sni = proxy.servername || proxy.sni;
	const tls_fingerprint = proxy['client-fingerprint'] || proxy.fingerprint;
	const tls_insecure = (proxy['skip-cert-verify'] === true || proxy.insecure === '1' || proxy.allowInsecure === true || proxy.allowInsecure === '1') ? '1'
		: (proxy['skip-cert-verify'] === false || proxy.insecure === '0' || proxy.allowInsecure === false || proxy.allowInsecure === '0') ? '0'
		: null;

	switch (proxy.type) {
	case 'anytls': {
		let anytls_fp = (proxy['client-fingerprint'] !== null && proxy['client-fingerprint'] !== undefined) ?
			proxy['client-fingerprint'] : proxy.fingerprint;
		anytls_fp = to_string(anytls_fp);
		if (anytls_fp === 'none' || anytls_fp === 'disable' || anytls_fp === 'disabled')
			anytls_fp = null;
		else if (!has_value(anytls_fp))
			anytls_fp = 'chrome';
		config = {
			label: proxy.name,
			type: 'anytls',
			address: proxy.server,
			port: to_string(proxy.port),
			password: proxy.password,
			tls: '1',
			tls_sni: tls_sni || proxy.peer,
			tls_alpn: normalize_alpn(proxy.alpn),
			tls_insecure,
			tls_utls: sing_features.with_utls ? anytls_fp : null,
			anytls_idle_session_check_interval: to_string(proxy['idle-session-check-interval']),
			anytls_idle_session_timeout: to_string(proxy['idle-session-timeout']),
			anytls_min_idle_session: to_string(proxy['min-idle-session']),
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	}
	case 'vmess':
		config = {
			label: proxy.name,
			type: 'vmess',
			address: proxy.server,
			port: to_string(proxy.port),
			uuid: proxy.uuid,
			vmess_alterid: has_value(proxy.alterId) ? to_string(proxy.alterId) : null,
			vmess_encrypt: proxy.cipher,
			packet_encoding: proxy['packet-encoding'],
			tls: (proxy.tls === true) ? '1' : '0',
			tls_sni,
			tls_alpn: normalize_alpn(proxy.alpn),
			tls_insecure,
			tls_utls: sing_features.with_utls ? tls_fingerprint : null,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		apply_transport_opts(config, proxy);
		break;
	case 'hysteria2':
		if (!sing_features.with_quic) {
			log(sprintf('Skipping unsupported %s node: %s.', proxy.type, proxy.name || proxy.server));
			log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));
			return null;
		}
		config = {
			label: proxy.name,
			type: 'hysteria2',
			address: proxy.server,
			port: to_string(proxy.port),
			password: proxy.password,
			hysteria_hopping_port: normalize_mihomo_ports(proxy.ports),
			hysteria_down_mbps: parse_mihomo_speed(proxy.down),
			hysteria_up_mbps: parse_mihomo_speed(proxy.up),
			hysteria_obfs_type: proxy.obfs,
			hysteria_obfs_password: proxy['obfs-password'],
			tls: '1',
			tls_sni,
			tls_alpn: normalize_alpn(proxy.alpn),
			tls_insecure,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	case 'hysteria':
		if (!sing_features.with_quic) {
			log(sprintf('Skipping unsupported %s node: %s.', proxy.type, proxy.name || proxy.server));
			log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));
			return null;
		}
		config = {
			label: proxy.name,
			type: 'hysteria',
			address: proxy.server,
			port: to_string(proxy.port),
			hysteria_hopping_port: normalize_mihomo_ports(proxy.ports),
			hysteria_auth_type: proxy['auth-str'] ? 'string' : (proxy.auth ? 'base64' : null),
			hysteria_auth_payload: proxy['auth-str'] || proxy.auth,
			hysteria_obfs_password: proxy.obfs,
			hysteria_down_mbps: parse_mihomo_speed(proxy.down),
			hysteria_up_mbps: parse_mihomo_speed(proxy.up),
			tls: '1',
			tls_sni,
			tls_alpn: normalize_alpn(proxy.alpn),
			tls_insecure,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	case 'vless':
		config = {
			label: proxy.name,
			type: 'vless',
			address: proxy.server,
			port: to_string(proxy.port),
			uuid: proxy.uuid,
			vless_flow: proxy.flow,
			packet_encoding: proxy['packet-encoding'],
			tls: (proxy.tls === true || proxy['reality-opts']) ? '1' : '0',
			tls_sni,
			tls_alpn: normalize_alpn(proxy.alpn),
			tls_insecure,
			tls_utls: sing_features.with_utls ? tls_fingerprint : null,
			tls_reality: proxy['reality-opts'] ? '1' : '0',
			tls_reality_public_key: proxy['reality-opts'] ? proxy['reality-opts']['public-key'] : null,
			tls_reality_short_id: proxy['reality-opts'] ? proxy['reality-opts']['short-id'] : null,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		apply_transport_opts(config, proxy);
		break;
	case 'trojan':
		config = {
			label: proxy.name,
			type: 'trojan',
			address: proxy.server,
			port: to_string(proxy.port),
			password: proxy.password,
			tls: (proxy.tls === false) ? '0' : '1',
			tls_sni,
			tls_alpn: normalize_alpn(proxy.alpn),
			tls_insecure,
			tls_utls: sing_features.with_utls ? tls_fingerprint : null,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		apply_transport_opts(config, proxy);
		break;
	case 'ss': {
		let ss_plugin = proxy.plugin;
		if (ss_plugin === 'simple-obfs')
			ss_plugin = 'obfs-local';
		config = {
			label: proxy.name,
			type: 'shadowsocks',
			address: proxy.server,
			port: to_string(proxy.port),
			shadowsocks_encrypt_method: proxy.cipher,
			password: proxy.password,
			shadowsocks_plugin: ss_plugin,
			shadowsocks_plugin_opts: proxy['plugin-opts'],
			udp_over_tcp: bool_to_uci(proxy['udp-over-tcp']),
			udp_over_tcp_version: to_string(proxy['udp-over-tcp-version']),
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	}
	case 'ssr':
		log(sprintf('Skipping unsupported ssr node: %s.', proxy.name || proxy.server));
		return null;
	case 'socks5':
	case 'socks':
	case 'socks4':
	case 'socks4a':
		config = {
			label: proxy.name,
			type: 'socks',
			address: proxy.server,
			port: to_string(proxy.port),
			username: proxy.username,
			password: proxy.password,
			socks_version: (proxy.type === 'socks4a') ? '4a' : ((proxy.type === 'socks4') ? '4' : '5'),
			tls: (proxy.tls === true) ? '1' : '0',
			tls_sni,
			tls_insecure,
			tls_utls: sing_features.with_utls ? tls_fingerprint : null,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	case 'http':
		config = {
			label: proxy.name,
			type: 'http',
			address: proxy.server,
			port: to_string(proxy.port),
			username: proxy.username,
			password: proxy.password,
			tls: (proxy.tls === true) ? '1' : '0',
			tls_sni,
			tls_insecure,
			tls_utls: sing_features.with_utls ? tls_fingerprint : null,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	case 'tuic': {
		if (!sing_features.with_quic) {
			log(sprintf('Skipping unsupported %s node: %s.', proxy.type, proxy.name || proxy.server));
			log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));
			return null;
		}
		let tuic_heartbeat = proxy['heartbeat-interval'];
		if (has_value(tuic_heartbeat)) {
			tuic_heartbeat = int(tuic_heartbeat);
			if (tuic_heartbeat >= 1000)
				tuic_heartbeat = int(tuic_heartbeat / 1000);
		}
		config = {
			label: proxy.name,
			type: 'tuic',
			address: proxy.server,
			port: to_string(proxy.port),
			uuid: proxy.uuid,
			password: proxy.password || proxy.token,
			tuic_congestion_control: proxy['congestion-controller'],
			tuic_udp_relay_mode: proxy['udp-relay-mode'],
			tuic_udp_over_stream: bool_to_uci(proxy['udp-over-stream']),
			tuic_enable_zero_rtt: bool_to_uci(proxy['zero-rtt-handshake']),
			tuic_heartbeat: has_value(tuic_heartbeat) ? to_string(tuic_heartbeat) : null,
			tls: '1',
			tls_sni: proxy['disable-sni'] ? null : tls_sni,
			tls_alpn: normalize_alpn(proxy.alpn),
			tls_insecure,
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	}
	case 'ssh':
		config = {
			label: proxy.name,
			type: 'ssh',
			address: proxy.server,
			port: to_string(proxy.port),
			username: proxy.username,
			password: proxy.password,
			ssh_client_version: proxy['client-version'],
			ssh_host_key: normalize_list(proxy['host-key']),
			ssh_host_key_algo: normalize_list(proxy['host-key-algorithms']),
			ssh_priv_key: normalize_list(proxy['private-key']),
			ssh_priv_key_pp: proxy['private-key-passphrase'],
			tcp_fast_open: (proxy.tfo === true) ? '1' : null
		};
		break;
	case 'wireguard': {
		let wg_addresses = [];
		if (has_value(proxy.ip))
			push(wg_addresses, to_string(proxy.ip));
		if (has_value(proxy.ipv6))
			push(wg_addresses, to_string(proxy.ipv6));
		config = {
			label: proxy.name,
			type: 'wireguard',
			address: proxy.server,
			port: to_string(proxy.port),
			wireguard_local_address: length(wg_addresses) ? wg_addresses : null,
			wireguard_private_key: proxy['private-key'],
			wireguard_peer_public_key: proxy['public-key'],
			wireguard_pre_shared_key: proxy['pre-shared-key'],
			wireguard_reserved: normalize_list(proxy.reserved),
			wireguard_mtu: to_string(proxy.mtu),
			wireguard_persistent_keepalive_interval: to_string(proxy['persistent-keepalive'] || proxy['persistent-keepalive-interval'] || proxy.keepalive)
		};
		break;
	}
	default:
		return null;
	}

	return config;
}

function yaml_flow_to_json(s) {
	if (type(s) !== 'string')
		return null;

	const len = length(s);
	let out = '';
	let i = 0;
	let stack = [];
	let expect_key = false;

	while (i < len) {
		const c = substr(s, i, 1);

		if (c === ' ' || c === '\t') {
			out += c;
			i++;
			continue;
		}

		if (c === '{') {
			push(stack, '{');
			expect_key = true;
			out += c;
			i++;
			continue;
		}

		if (c === '[') {
			push(stack, '[');
			expect_key = false;
			out += c;
			i++;
			continue;
		}

		if (c === '}' || c === ']') {
			pop(stack);
			expect_key = false;
			out += c;
			i++;
			continue;
		}

		if (c === ',') {
			const top = stack[length(stack) - 1];
			expect_key = (top === '{');
			out += c;
			i++;
			continue;
		}

		if (c === ':') {
			expect_key = false;
			out += c;
			i++;
			continue;
		}

		if (c === '"' || c === '\'') {
			const quote = c;
			let str = '';
			i++;
			while (i < len && substr(s, i, 1) !== quote) {
				if (substr(s, i, 1) === '\\' && i + 1 < len) {
					str += substr(s, i, 2);
					i += 2;
				} else {
					str += substr(s, i, 1);
					i++;
				}
			}
			i++;
			if (quote === '\'')
				str = replace(str, '"', '\\"');
			out += '"' + str + '"';
			continue;
		}

		const start = i;
		while (i < len) {
			const ch = substr(s, i, 1);
			if (ch === ',' || ch === '}' || ch === ']')
				break;
			if (ch === ':' && expect_key)
				break;
			i++;
		}

		const token = trim(substr(s, start, i - start));
		if (expect_key) {
			out += '"' + replace(token, '"', '\\"') + '"';
		} else if (token === '' || token === '~' || token === 'null') {
			out += 'null';
		} else if (token === 'true' || token === 'false') {
			out += token;
		} else if (match(token, /^-?[0-9]+(\.[0-9]+)?$/)) {
			out += token;
		} else {
			out += '"' + replace(token, '"', '\\"') + '"';
		}
	}

	return out;
}

function parse_mihomo_yaml(text) {
	if (isEmpty(text) || type(text) !== 'string')
		return null;

	let in_proxies = false;
	let proxies = [];
	for (let line in split(text, '\n')) {
		line = trim(line);
		if (line === 'proxies:' || match(line, /^proxies:\s*$/)) {
			in_proxies = true;
			continue;
		}
		if (!in_proxies)
			continue;

		if (!line)
			continue;

		if (match(line, /^[\w-]+:\s*$/) && line !== '-')
			break;

		const m = match(line, /^-\s*(\{.*\})\s*(#.*)?$/);
		if (!m)
			continue;

		const json_text = yaml_flow_to_json(m[1]);

		let obj;
		try {
			obj = json_text ? json(json_text) : null;
		} catch(e) {
			log(sprintf('Failed to parse mihomo proxy line: %s (%s)', line, e));
			obj = null;
		}
		if (obj) {
			obj.nodetype = 'mihomo';
			push(proxies, obj);
		}
	}

	return length(proxies) ? proxies : null;
}

function parse_uri(uri) {
	let config, url, params;

	if (type(uri) === 'object') {
		if (uri.nodetype === 'mihomo') {
			config = parse_mihomo_proxy(uri);
		} else if (uri.nodetype === 'sip008') {
			config = {
				label: uri.remarks,
				type: 'shadowsocks',
				address: uri.server,
				port: uri.server_port,
				shadowsocks_encrypt_method: uri.method,
				password: uri.password,
				shadowsocks_plugin: uri.plugin,
				shadowsocks_plugin_opts: uri.plugin_opts
			};
		}
	} else if (type(uri) === 'string') {
		uri = split(trim(uri), '://');

		switch (uri[0]) {
		case 'anytls':
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'anytls',
				address: url.hostname,
				port: url.port,
				password: urldecode(url.username),
				tls: '1',
				tls_sni: params.sni,
				tls_insecure: (params.insecure === '1') ? '1' : '0'
			};

			break;
		case 'http':
		case 'https':
			url = parseURL('http://' + uri[1]) || {};

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'http',
				address: url.hostname,
				port: url.port,
				username: url.username ? urldecode(url.username) : null,
				password: url.password ? urldecode(url.password) : null,
				tls: (uri[0] === 'https') ? '1' : '0'
			};

			break;
		case 'hysteria':
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			if (!sing_features.with_quic || (params.protocol && params.protocol !== 'udp')) {
				log(sprintf('Skipping unsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				if (!sing_features.with_quic)
					log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));

				return null;
			}

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'hysteria',
				address: url.hostname,
				port: url.port,
				hysteria_protocol: params.protocol || 'udp',
				hysteria_auth_type: params.auth ? 'string' : null,
				hysteria_auth_payload: params.auth,
				hysteria_obfs_password: params.obfsParam,
				hysteria_down_mbps: params.downmbps,
				hysteria_up_mbps: params.upmbps,
				tls: '1',
				tls_insecure: (params.insecure in ['true', '1']) ? '1' : '0',
				tls_sni: params.peer,
				tls_alpn: params.alpn
			};

			break;
		case 'hysteria2':
		case 'hy2':
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			if (!sing_features.with_quic) {
				log(sprintf('Skipping unsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));
				return null;
			}

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'hysteria2',
				address: url.hostname,
				port: url.port,
				password: url.username ? (
					urldecode(url.username + (url.password ? (':' + url.password) : ''))
				) : null,
				hysteria_obfs_type: params.obfs,
				hysteria_obfs_password: params['obfs-password'],
				tls: '1',
				tls_insecure: (params.insecure === '1') ? '1' : '0',
				tls_sni: params.sni
			};

			break;
		case 'socks':
		case 'socks4':
		case 'socks4a':
		case 'socsk5':
		case 'socks5h':
			url = parseURL('http://' + uri[1]) || {};

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'socks',
				address: url.hostname,
				port: url.port,
				username: url.username ? urldecode(url.username) : null,
				password: url.password ? urldecode(url.password) : null,
				socks_version: (match(uri[0], /4/)) ? '4' : '5'
			};

			break;
		case 'ss':
			const ss_suri = split(uri[1], '#');
			let ss_slabel = '';
			if (length(ss_suri) <= 2) {
				if (length(ss_suri) === 2)
					ss_slabel = '#' + urlencode(ss_suri[1]);
				if (decodeBase64Str(ss_suri[0]))
					uri[1] = decodeBase64Str(ss_suri[0]) + ss_slabel;
			}


			url = parseURL('http://' + uri[1]) || {};

			let ss_userinfo = {};
			if (url.username && url.password)
				ss_userinfo = [url.username, urldecode(url.password)];
			else if (url.username)
				ss_userinfo = split(decodeBase64Str(urldecode(url.username)), ':', 2);

			let ss_plugin, ss_plugin_opts;
			if (url.search && url.searchParams.plugin) {
				const ss_plugin_info = split(url.searchParams.plugin, ';', 2);
				ss_plugin = ss_plugin_info[0];
				if (ss_plugin === 'simple-obfs')
					ss_plugin = 'obfs-local';
				ss_plugin_opts = ss_plugin_info[1];
			}

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'shadowsocks',
				address: url.hostname,
				port: url.port,
				shadowsocks_encrypt_method: ss_userinfo[0],
				password: ss_userinfo[1],
				shadowsocks_plugin: ss_plugin,
				shadowsocks_plugin_opts: ss_plugin_opts
			};

			break;
		case 'trojan':
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'trojan',
				address: url.hostname,
				port: url.port,
				password: urldecode(url.username),
				transport: (params.type !== 'tcp') ? params.type : null,
				tls: '1',
				tls_sni: params.sni
			};
			switch(params.type) {
			case 'grpc':
				config.grpc_servicename = params.serviceName;
				break;
			case 'ws':
				config.ws_host = params.host ? urldecode(params.host) : null;
				config.ws_path = params.path ? urldecode(params.path) : null;
				if (config.ws_path && match(config.ws_path, /\?ed=/)) {
					config.websocket_early_data_header = 'Sec-WebSocket-Protocol';
					config.websocket_early_data = split(config.ws_path, '?ed=')[1];
					config.ws_path = split(config.ws_path, '?ed=')[0];
				}
				break;
			}

			break;
		case 'tuic':
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			if (!sing_features.with_quic) {
				log(sprintf('Skipping unsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));

				return null;
			}

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'tuic',
				address: url.hostname,
				port: url.port,
				uuid: url.username,
				password: url.password ? urldecode(url.password) : null,
				tuic_congestion_control: params.congestion_control,
				tuic_udp_relay_mode: params.udp_relay_mode,
				tls: '1',
				tls_sni: params.sni,
				tls_alpn: params.alpn ? split(urldecode(params.alpn), ',') : null,
			};

			break;
		case 'vless':
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			if (params.type === 'kcp') {
				log(sprintf('Skipping sunsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				return null;
			} else if (params.type === 'quic' && ((params.quicSecurity && params.quicSecurity !== 'none') || !sing_features.with_quic)) {
				log(sprintf('Skipping sunsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				if (!sing_features.with_quic)
					log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));

				return null;
			}

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'vless',
				address: url.hostname,
				port: url.port,
				uuid: url.username,
				transport: (params.type !== 'tcp') ? params.type : null,
				tls: (params.security in ['tls', 'xtls', 'reality']) ? '1' : '0',
				tls_sni: params.sni,
				tls_alpn: params.alpn ? split(urldecode(params.alpn), ',') : null,
				tls_reality: (params.security === 'reality') ? '1' : '0',
				tls_reality_public_key: params.pbk ? urldecode(params.pbk) : null,
				tls_reality_short_id: params.sid,
				tls_utls: sing_features.with_utls ? params.fp : null,
				vless_flow: (params.security in ['tls', 'reality']) ? params.flow : null
			};
			switch(params.type) {
			case 'grpc':
				config.grpc_servicename = params.serviceName;
				break;
			case 'http':
			case 'tcp':
				if (params.type === 'http' || params.headerType === 'http') {
					config.http_host = params.host ? split(urldecode(params.host), ',') : null;
					config.http_path = params.path ? urldecode(params.path) : null;
				}
				break;
			case 'httpupgrade':
				config.httpupgrade_host = params.host ? urldecode(params.host) : null;
				config.http_path = params.path ? urldecode(params.path) : null;
				break;
			case 'ws':
				config.ws_host = params.host ? urldecode(params.host) : null;
				config.ws_path = params.path ? urldecode(params.path) : null;
				if (config.ws_path && match(config.ws_path, /\?ed=/)) {
					config.websocket_early_data_header = 'Sec-WebSocket-Protocol';
					config.websocket_early_data = split(config.ws_path, '?ed=')[1];
					config.ws_path = split(config.ws_path, '?ed=')[0];
				}
				break;
			}

			break;
		case 'vmess':
			if (match(uri, /&/)) {
				log(sprintf('Skipping unsupported %s format.', uri[0]));
				return null;
			}

			try {
				uri = json(decodeBase64Str(uri[1])) || {};
			} catch(e) {
				log(sprintf('Skipping unsupported %s format.', uri[0]));
				return null;
			}

			if (uri.v != '2') {
				log(sprintf('Skipping unsupported %s format.', uri[0]));
				return null;
			} else if (uri.net === 'kcp') {
				log(sprintf('Skipping unsupported %s node: %s.', uri[0], uri.ps || uri.add));
				return null;
			} else if (uri.net === 'quic' && ((uri.type && uri.type !== 'none') || uri.path || !sing_features.with_quic)) {
				log(sprintf('Skipping unsupported %s node: %s.', uri[0], uri.ps || uri.add));
				if (!sing_features.with_quic)
					log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));

				return null;
			}

			config = {
				label: uri.ps ? urldecode(uri.ps) : null,
				type: 'vmess',
				address: uri.add,
				port: uri.port,
				uuid: uri.id,
				vmess_alterid: uri.aid,
				vmess_encrypt: uri.scy || 'auto',
				vmess_global_padding: '1',
				transport: (uri.net !== 'tcp') ? uri.net : null,
				tls: (uri.tls === 'tls') ? '1' : '0',
				tls_sni: uri.sni || uri.host,
				tls_alpn: uri.alpn ? split(uri.alpn, ',') : null,
				tls_utls: sing_features.with_utls ? uri.fp : null
			};
			switch (uri.net) {
			case 'grpc':
				config.grpc_servicename = uri.path;
				break;
			case 'h2':
			case 'tcp':
				if (uri.net === 'h2' || uri.type === 'http') {
					config.transport = 'http';
					config.http_host = uri.host ? split(uri.host, ',') : null;
					config.http_path = uri.path;
				}
				break;
			case 'httpupgrade':
				config.httpupgrade_host = uri.host;
				config.http_path = uri.path;
				break;
			case 'ws':
				config.ws_host = uri.host;
				config.ws_path = uri.path;
				if (config.ws_path && match(config.ws_path, /\?ed=/)) {
					config.websocket_early_data_header = 'Sec-WebSocket-Protocol';
					config.websocket_early_data = split(config.ws_path, '?ed=')[1];
					config.ws_path = split(config.ws_path, '?ed=')[0];
				}
				break;
			}

			break;
		}
	}

	if (!isEmpty(config)) {
		if (config.address)
			config.address = replace(config.address, /\[|\]/g, '');

		if (!validation('host', config.address) || !validation('port', config.port)) {
			log(sprintf('Skipping invalid %s node: %s.', config.type, config.label || 'NULL'));
			return null;
		} else if (!config.label)
			config.label = (validation('ip6addr', config.address) ?
				`[${config.address}]` : config.address) + ':' + config.port;
	}

	return config;
}

function main() {
	if (via_proxy !== '1') {
		log('Stopping service...');
		init_action('homeproxy', 'stop');
	}

	for (let url in subscription_urls) {
		url = replace(url, /#.*$/, '');
		const groupHash = md5(url);
		node_cache[groupHash] = {};

		const res = curlGET(url, user_agent);
		if (isEmpty(res)) {
			log(sprintf('Failed to fetch resources from %s.', url));
			continue;
		}

		let nodes;
		const mihomo_nodes = parse_mihomo_yaml(res);
		if (mihomo_nodes) {
			nodes = mihomo_nodes;
		} else {
			try {
				nodes = json(res).servers || json(res);

				if (type(nodes) === 'array' && length(nodes) && type(nodes[0]) === 'object' && nodes[0].server && nodes[0].method)
					map(nodes, (_, i) => nodes[i].nodetype = 'sip008');
			} catch(e) {
				nodes = decodeBase64Str(res);
				nodes = nodes ? split(trim(replace(nodes, / /g, '_')), '\n') : [];
			}
		}

		let count = 0;
		for (let node in nodes) {
			let config;
			if (!isEmpty(node))
				config = parse_uri(node);
			if (isEmpty(config))
				continue;

			const label = config.label;
			config.label = null;
			const confHash = md5(sprintf('%J', config)),
			      nameHash = md5(label);
			config.label = label;
			const idHash = md5(confHash + nameHash);
			config.confhash = idHash;

			if (filter_check(config.label))
				log(sprintf('Skipping blacklist node: %s.', config.label));
			else if (node_cache[groupHash][idHash])
				log(sprintf('Skipping duplicate node: %s.', config.label));
			else {
				if (config.tls === '1' && allow_insecure === '1')
					config.tls_insecure = '1';
				if (config.type in ['vless', 'vmess'])
					config.packet_encoding = packet_encoding;

				config.grouphash = groupHash;
				push(node_result, []);
				push(node_result[length(node_result)-1], config);
				node_cache[groupHash][idHash] = config;

				count++;
			}
		}

		if (count == 0)
			log(sprintf('No valid node found in %s.', url));
		else
			log(sprintf('Successfully fetched %s nodes of total %s from %s.', count, length(nodes), url));
	}

	if (isEmpty(node_result)) {
		log('Failed to update subscriptions: no valid node found.');

		if (via_proxy !== '1') {
			log('Starting service...');
			init_action('homeproxy', 'start');
		}

		return false;
	}

	let added = 0, removed = 0;
	uci.foreach(uciconfig, ucinode, (cfg) => {
		if (!cfg.grouphash)
			return null;

		if (length(node_cache[cfg.grouphash]) === 0)
			return null;

		if (!node_cache[cfg.grouphash] || !node_cache[cfg.grouphash][cfg['.name']]) {
			uci.delete(uciconfig, cfg['.name']);
			removed++;

			log(sprintf('Removing node: %s.', cfg.label || cfg['name']));
		} else {
			const fresh = node_cache[cfg.grouphash][cfg['.name']];
			map(keys(cfg), (v) => {
				if (substr(v, 0, 1) === '.')
					return;

				if (v in fresh)
					uci.set(uciconfig, cfg['.name'], v, fresh[v]);
				else
					uci.delete(uciconfig, cfg['.name'], v);
			});
			map(keys(fresh), (v) => {
				if (v !== 'confhash' && !(v in cfg))
					uci.set(uciconfig, cfg['.name'], v, fresh[v]);
			});
			node_cache[cfg.grouphash][cfg['.name']].isExisting = true;
		}
	});
	for (let nodes in node_result)
		map(nodes, (node) => {
			if (node.isExisting)
				return null;

			const nodeId = node.confhash;
			delete node.confhash;

			uci.set(uciconfig, nodeId, 'node');
			map(keys(node), (v) => uci.set(uciconfig, nodeId, v, node[v]));

			added++;
			log(sprintf('Adding node: %s.', node.label));
		});

	const label_state = synchronizeNodeLabels(uci, uciconfig, null);
	if (label_state.changed)
		log(sprintf('Renamed %s duplicate node label(s) to keep them unique.', label_state.changed));

	uci.commit(uciconfig);

	let need_restart = (via_proxy !== '1');

	const urltest_result = reconcileUrltestNodes(uci, uciconfig, (message) => log(message));
	if (urltest_result.changed) {
		uci.commit(uciconfig);
		need_restart = true;
	}

	if (need_restart) {
		log('Restarting service...');
		init_action('homeproxy', 'stop');
		init_action('homeproxy', 'start');
	}

	log(sprintf('%s nodes added, %s removed.', added, removed));
	log('Successfully updated subscriptions.');
}

if (!isEmpty(subscription_urls))
	try {
		call(main);
	} catch(e) {
		log('[FATAL ERROR] An error occurred during updating subscriptions:');
		log(sprintf('%s: %s', e.type, e.message));
		log(e.stacktrace[0].context);

		log('Restarting service...');
		init_action('homeproxy', 'stop');
		init_action('homeproxy', 'start');
	}
