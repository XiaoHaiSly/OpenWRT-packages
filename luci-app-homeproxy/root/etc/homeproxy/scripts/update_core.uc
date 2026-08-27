#!/usr/bin/ucode -S

'use strict';

import { access, popen, readfile, writefile } from 'fs';

import { shellQuote, HP_DIR, RUN_DIR } from 'homeproxy';

const JOBS_DIR = `${RUN_DIR}/jobs`;
const JOB_NAME = 'core_official';

const SINGBOX_BIN     = '/usr/bin/sing-box';
const CORE_BACKUP_DIR = `${HP_DIR}/core-backup`;
const CORE_BACKUP_BIN = `${CORE_BACKUP_DIR}/sing-box.orig`;
const CORE_REPO       = 'SagerNet/sing-box';

function job_esc(s) {
	return replace(replace('' + (s ?? ''), '\\', '\\\\'), '"', '\\"');
}

function job_write(state, stage, message, version) {
	system(`mkdir -p ${shellQuote(JOBS_DIR)}`);

	let fields = [ `"ts":"${time()}"`, `"state":"${job_esc(state)}"`, `"stage":"${job_esc(stage)}"` ];
	if (message) push(fields, `"message":"${job_esc(message)}"`);
	if (version) push(fields, `"version":"${job_esc(version)}"`);

	const path = `${JOBS_DIR}/${JOB_NAME}.json`;
	writefile(`${path}.tmp`, '{' + join(',', fields) + '}');
	system(`mv -f ${shellQuote(path + '.tmp')} ${shellQuote(path)}`);
}

function fail(stage, message, version) {
	job_write('error', stage, message, version);
	exit(0);
}

function core_detect_arch() {
	const os_rel = readfile('/etc/os-release') || '';
	const m = match(os_rel, /OPENWRT_ARCH="?([^"\n]+)"?/);
	return m ? trim(m[1]) : '';
}

const CORE_GOARCH_MAP = {
	'x86_64': 'amd64',
	'i386_pentium4': '386', 'i386_pentium-mmx': '386',
	'aarch64_generic': 'arm64', 'aarch64_cortex-a53': 'arm64',
	'aarch64_cortex-a72': 'arm64', 'aarch64_cortex-a76': 'arm64',
	'arm_cortex-a7': 'armv7', 'arm_cortex-a7_neon-vfpv4': 'armv7',
	'arm_cortex-a7_vfpv4': 'armv7', 'arm_cortex-a8_vfpv3': 'armv7',
	'arm_cortex-a9': 'armv7', 'arm_cortex-a9_vfpv3-d16': 'armv7',
	'arm_cortex-a15_neon-vfpv4': 'armv7',
	'arm_arm1176jzf-s_vfp': 'armv6', 'arm_mpcore': 'armv6',
	'arm_xscale': 'armv5', 'arm_arm926ej-s': 'armv5', 'arm_fa526': 'armv5',
	'mipsel_24kc': 'mipsle', 'mipsel_74kc': 'mipsle', 'mipsel_mips32': 'mipsle',
	'mips_24kc': 'mips', 'mips_4kec': 'mips', 'mips_mips32': 'mips',
	'mips64_octeonplus': 'mips64', 'mips64_mips64r2': 'mips64',
	'mips64el_mips64r2': 'mips64le',
	'riscv64_generic': 'riscv64',
	'loongarch64_generic': 'loong64'
};

function core_goarch(owrt_arch) {
	if (owrt_arch in CORE_GOARCH_MAP) return CORE_GOARCH_MAP[owrt_arch];
	if (match(owrt_arch, /^aarch64/)) return 'arm64';
	if (match(owrt_arch, /^arm_cortex/)) return 'armv7';
	if (match(owrt_arch, /^mipsel/)) return 'mipsle';
	if (match(owrt_arch, /^mips_/)) return 'mips';
	if (match(owrt_arch, /^mips64el/)) return 'mips64le';
	if (match(owrt_arch, /^mips64/)) return 'mips64';
	if (match(owrt_arch, /^riscv64/)) return 'riscv64';
	if (match(owrt_arch, /^loongarch64/)) return 'loong64';
	if (match(owrt_arch, /^i386/)) return '386';
	return null;
}

function core_gh_token_header() {
	let token = null;
	const fd = popen('uci -q get homeproxy.config.github_token 2>/dev/null');
	if (fd) { token = trim(fd.read('all')); fd.close(); }
	return (token && length(token)) ? `-H ${shellQuote(`Authorization: Bearer ${token}`)}` : '';
}

function core_fetch_json(url) {
	const token_hdr = core_gh_token_header();
	const fd = popen(`/usr/bin/curl -4 -fsSL --connect-timeout 10 --max-time 15 ${token_hdr} ${shellQuote(url)} 2>/dev/null`);
	if (!fd) return null;
	const raw = trim(fd.read('all')); fd.close();
	if (!length(raw)) return null;

	try { return json(raw); } catch (e) { return null; }
}

function core_fetch_release(channel) {
	if (channel === 'latest') {
		const data = core_fetch_json(`https://api.github.com/repos/${CORE_REPO}/releases?per_page=1`);
		return (type(data) === 'array' && length(data)) ? data[0] : null;
	}

	const data = core_fetch_json(`https://api.github.com/repos/${CORE_REPO}/releases/latest`);
	if (data?.tag_name) return data;

	const list = core_fetch_json(`https://api.github.com/repos/${CORE_REPO}/releases?per_page=30`);
	if (type(list) === 'array')
		for (let rel in list)
			if (rel?.tag_name && !rel.prerelease && !rel.draft)
				return rel;

	return null;
}

function core_arch_matches(filename, goarch) {
	return !!match(filename, regexp('(^|[-_.])' + goarch + '($|[-_.])'));
}

function core_cache_paths() {
	let paths = [
		`${HP_DIR}/cache/core_cache.db`,
		`${HP_DIR}/cache/cache.db`,
		`${RUN_DIR}/cache.db`
	];

	for (let run_conf in [ `${RUN_DIR}/sing-box-core.json`, `${RUN_DIR}/sing-box-c.json` ]) {
		if (!access(run_conf)) continue;
		let conf;
		try { conf = json(readfile(run_conf)); } catch (e) { conf = null; }
		const p = conf?.experimental?.cache_file?.path;
		if (p && index(paths, p) < 0)
			push(paths, p);
	}

	return paths;
}

const channel = (ARGV[0] === 'stable') ? 'stable' : 'latest';

const arch = core_detect_arch();
if (!arch)
	fail('preparing', 'could not detect device architecture');

const goarch = core_goarch(arch);
if (!goarch)
	fail('preparing', `no Go-arch mapping for OpenWrt arch "${arch}"`);

const release = core_fetch_release(channel);
if (!release?.assets)
	fail('preparing', 'could not read release info from GitHub');

const version = replace(release.tag_name, /^v/, '');

let candidates = [];
for (let asset in release.assets) {
	const n = asset?.name || '';
	if (!match(n, /linux/i)) continue;
	if (match(n, /openwrt|alpine|\.apk$|\.deb$|\.rpm$/i)) continue;
	if (!match(n, /\.(tar\.gz|tgz)$/i)) continue;
	if (!core_arch_matches(n, goarch)) continue;
	push(candidates, asset);
}
let chosen = null;
for (let a in candidates)
	if (match(a?.name, /musl/i)) { chosen = a; break; }
if (!chosen) chosen = candidates[0];

if (!chosen)
	fail('preparing', `no linux/${goarch} tarball found in the latest official release`);

job_write('running', 'downloading', null, version);

const dl_url = chosen.browser_download_url;
const tmp_path = `/tmp/sing-box-official.tar.gz`;

const max_tries = 3;
let exit_code = 1;
for (let attempt = 1; attempt <= max_tries; attempt++) {
	exit_code = system(`/usr/bin/curl -4 -fsSL -o ${shellQuote(tmp_path)} -C - --connect-timeout 10 --max-time 30 ${shellQuote(dl_url)} 2>/dev/null`, 60000);
	if (exit_code === 0) break;
}
if (exit_code !== 0) {
	system(`rm -f ${shellQuote(tmp_path)}`);
	fail('downloading', 'download failed', version);
}

job_write('running', 'installing', null, version);

if (!access(CORE_BACKUP_BIN) && access(SINGBOX_BIN)) {
	system(`mkdir -p ${shellQuote(CORE_BACKUP_DIR)}`);
	system(`cp -f ${shellQuote(SINGBOX_BIN)} ${shellQuote(CORE_BACKUP_BIN)}`);
}

system('/etc/init.d/homeproxy stop >/dev/null 2>&1');

const extract_dir = '/tmp/singbox-core-extract';
system(`rm -rf ${shellQuote(extract_dir)}; mkdir -p ${shellQuote(extract_dir)}`);
const untar = system(`tar -xzf ${shellQuote(tmp_path)} -C ${shellQuote(extract_dir)} 2>/dev/null`, 60000);

let bin_path = null;
if (untar === 0) {
	const fd = popen(`find ${shellQuote(extract_dir)} -type f -name 'sing-box*' ! -name '*.txt' 2>/dev/null | head -n1`);
	if (fd) { bin_path = trim(fd.read('all')); fd.close(); }
}

let ok = false;
if (bin_path && length(bin_path) && access(bin_path)) {
	system(`cp -f ${shellQuote(bin_path)} ${shellQuote(SINGBOX_BIN)} && chmod 755 ${shellQuote(SINGBOX_BIN)}`);
	ok = true;

	for (let p in core_cache_paths())
		system(`rm -f ${shellQuote(p)} 2>/dev/null`);
}

system(`rm -rf ${shellQuote(extract_dir)} ${shellQuote(tmp_path)}`);
system('/etc/init.d/homeproxy start >/dev/null 2>&1');

if (!ok)
	fail('installing', 'installation failed', version);

job_write('success', 'done', null, version);
