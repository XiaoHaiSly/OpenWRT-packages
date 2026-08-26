#!/usr/bin/ucode -S

'use strict';

import { writefile } from 'fs';
import { cursor } from 'uci';

import { executeCommand, shellQuote, curlGET, getTime, isEmpty, HP_DIR } from 'homeproxy';

const uci = cursor();
const uciconfig = 'homeproxy';
uci.load(uciconfig);

const CUSTOM_DIR = `${HP_DIR}/custom`;
const SUB_DIR = `${CUSTOM_DIR}/.subscriptions`;

function formatFilesize(bytes) {
	if (isEmpty(bytes))
		return null;

	const units = [ 'B', 'KB', 'MB', 'GB', 'TB', 'PB' ];
	let size = +bytes, i = 0;
	while (size >= 1024 && i < length(units) - 1) {
		size /= 1024;
		i++;
	}

	return sprintf('%.2f %s', size, units[i]);
}

function fetchHeaders(url, ua) {
	if (isEmpty(url))
		return null;

	const result = executeCommand(
		`/usr/bin/curl -o /dev/null -sS -D - -A ${shellQuote(ua || 'sing-box/1.14.0')} --connect-timeout 10 --max-time 15 ${shellQuote(url)}`
	);

	return result?.stdout || null;
}

function parseUserinfo(headers) {
	if (isEmpty(headers))
		return {};

	const line = match(headers, /[Ss]ubscription-[Uu]serinfo:[^\r\n]+/);
	if (!line)
		return {};

	const info = line[0];
	const expireM = match(info, /expire=([0-9]+)/),
	      uploadM = match(info, /upload=([0-9]+)/),
	      downloadM = match(info, /download=([0-9]+)/),
	      totalM = match(info, /total=([0-9]+)/);

	let ret = {};
	if (expireM)
		ret.expire = int(expireM[1]);
	if (uploadM)
		ret.upload = int(uploadM[1]);
	if (downloadM)
		ret.download = int(downloadM[1]);
	if (totalM)
		ret.total = int(totalM[1]);

	return ret;
}

let profile_id = ARGV[0];
if (isEmpty(profile_id)) {
	const active = uci.get(uciconfig, 'config', 'main_core_profile');
	if (active && index(active, 'sub:') === 0)
		profile_id = substr(active, 4);
}

if (isEmpty(profile_id)) {
	warn('Error: no subscription profile specified and "Core only" is not currently using one.\n');
	exit(1);
}

let section_name;
uci.foreach(uciconfig, 'custom_profile', (s) => {
	if (s.id === profile_id)
		section_name = s['.name'];
});

if (isEmpty(section_name)) {
	warn(`Error: no subscription profile found with id "${profile_id}".\n`);
	exit(1);
}

const label = uci.get(uciconfig, section_name, 'label') || profile_id,
      info_url = uci.get(uciconfig, section_name, 'info_url'),
      url = uci.get(uciconfig, section_name, 'url'),
      user_agent = uci.get(uciconfig, section_name, 'user_agent');

if (isEmpty(url)) {
	warn(`Error: profile "${label}" has no subscription URL configured.\n`);
	exit(1);
}

uci.delete(uciconfig, section_name, 'used');
uci.delete(uciconfig, section_name, 'total');
uci.delete(uciconfig, section_name, 'expire');
uci.delete(uciconfig, section_name, 'success');

system(`mkdir -p ${SUB_DIR}`);

let userinfo = parseUserinfo(fetchHeaders(!isEmpty(info_url) ? info_url : url, user_agent));

const body = curlGET(url, user_agent);
if (isEmpty(body)) {
	warn(`Error: failed to fetch subscription "${label}" from ${url}.\n`);
	exit(1);
}

if (!writefile(`${SUB_DIR}/${profile_id}.json`, body)) {
	warn(`Error: failed to save subscription "${label}".\n`);
	exit(1);
}

if (userinfo.expire)
	uci.set(uciconfig, section_name, 'expire', getTime(userinfo.expire));
if (!isEmpty(userinfo.upload) && !isEmpty(userinfo.download))
	uci.set(uciconfig, section_name, 'used', formatFilesize(userinfo.upload + userinfo.download));
if (userinfo.total)
	uci.set(uciconfig, section_name, 'total', formatFilesize(userinfo.total));

uci.set(uciconfig, section_name, 'update', getTime());
uci.set(uciconfig, section_name, 'success', '1');
uci.commit(uciconfig);

print(`Subscription "${label}" fetched successfully.\n`);
