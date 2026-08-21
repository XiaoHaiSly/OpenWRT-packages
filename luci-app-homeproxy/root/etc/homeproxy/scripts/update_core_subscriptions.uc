#!/usr/bin/ucode -S

'use strict';

import { lstat } from 'fs';
import { cursor } from 'uci';

import { shellQuote, HP_DIR, RUN_DIR } from 'homeproxy';

const uci = cursor();
const uciconfig = 'homeproxy';
uci.load(uciconfig);

const SUB_DIR = `${HP_DIR}/custom/.subscriptions`;
const now_minute = int(time() / 60);

const main_node = uci.get(uciconfig, 'config', 'main_node');
const main_core_profile = uci.get(uciconfig, 'config', 'main_core_profile');

uci.foreach(uciconfig, 'custom_profile', (s) => {
	const profile_id = s.id;
	const url = s.url;

	if (!profile_id || !url || s.auto_update_enabled !== '1')
		return;

	let interval_min = int(s.auto_update_interval);
	if (!interval_min || interval_min < 1)
		interval_min = 1440;

	const json_path = `${SUB_DIR}/${profile_id}.json`;
	const filestat = lstat(json_path);

	const last_minute = filestat ? int(filestat.mtime / 60) : 0;

	if ((now_minute - last_minute) < interval_min)
		return;

	const exitcode = system(`/usr/bin/ucode -S ${HP_DIR}/scripts/update_custom_config.uc ${shellQuote(profile_id)} >>${RUN_DIR}/homeproxy.log 2>&1`);
	if (exitcode !== 0)
		return;

	const is_active = (main_node === 'core_only') && (main_core_profile === `sub:${profile_id}`);
	if (!is_active)
		return;

	system(`/etc/init.d/homeproxy restart >>${RUN_DIR}/homeproxy.log 2>&1 &`);
});
