#!/usr/bin/ucode -S

'use strict';

import { readfile, writefile } from 'fs';
import { HP_DIR } from 'homeproxy';

const input = ARGV[0], output = ARGV[1];

let raw = readfile(input);
let conf;
try {
	conf = json(raw);
} catch (e) {
	conf = null;
}

if (type(conf) == 'object') {
	if (type(conf.experimental) != 'object')
		conf.experimental = {};

	if (conf.experimental.cache_file == null) {
		conf.experimental.cache_file = {
			enabled: true,
			path: `${HP_DIR}/cache/core_cache.db`
		};
	} else if (type(conf.experimental.cache_file) == 'object' &&
	           conf.experimental.cache_file.path == null) {
		conf.experimental.cache_file.path = `${HP_DIR}/cache/core_cache.db`;
	}

	writefile(output, sprintf('%.J\n', conf));
} else {
	writefile(output, raw || '');
}
