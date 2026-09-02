#!/usr/bin/ucode -S

'use strict';

import { writefile } from 'fs';
import { cursor } from 'uci';
import { isEmpty, RUN_DIR } from 'homeproxy';

const cfgname = 'homeproxy';
const uci = cursor();
uci.load(cfgname);

const main_node = uci.get(cfgname, 'config', 'main_node') || 'nil',
      proxy_mode = uci.get(cfgname, 'config', 'proxy_mode') || 'redirect_tproxy';

let outbound_node, tun_name;
if (match(proxy_mode, /tun/)) {
	outbound_node = main_node;

	if (outbound_node !== 'nil')
		tun_name = uci.get(cfgname, 'infra', 'tun_name') || 'singtun0';
}

const server_enabled = uci.get(cfgname, 'server', 'enabled');

let forward = [],
    input = [];

if (tun_name) {
	push(forward, `oifname ${tun_name} counter accept comment "!${cfgname}: accept tun forward"`);
	push(input ,`iifname ${tun_name} counter accept comment "!${cfgname}: accept tun input"`);
}

if (server_enabled === '1') {
	uci.foreach(cfgname, 'server', (s) => {
		if (s.enabled !== '1' || s.firewall !== '1')
			return;

		let proto = s.network || '{ tcp, udp }';
		push(input, `meta l4proto ${proto} th dport ${s.port} counter accept comment "!${cfgname}: accept server ${s['.name']}"`);
	});
}

writefile(RUN_DIR + '/fw4_forward.nft', isEmpty(forward) ? '' : (join('\n', forward) + '\n'));

writefile(RUN_DIR + '/fw4_input.nft', isEmpty(input) ? '' : (join('\n', input) + '\n'));
