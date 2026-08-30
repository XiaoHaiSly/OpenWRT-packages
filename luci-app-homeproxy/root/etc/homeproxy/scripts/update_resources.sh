#!/bin/sh

NAME="homeproxy"

RESOURCES_DIR="/etc/$NAME/resources"
DASHBOARD_DIR="/etc/$NAME/dashboard"
mkdir -p "$RESOURCES_DIR" "$DASHBOARD_DIR"

RUN_DIR="/var/run/$NAME"
LOG_PATH="$RUN_DIR/$NAME.log"
JOBS_DIR="$RUN_DIR/jobs"
mkdir -p "$RUN_DIR" "$JOBS_DIR"

log() {
	echo -e "$(date "+%Y-%m-%d %H:%M:%S") $*" >> "$LOG_PATH"
}

json_esc() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

job_write() {
	local name="$1" state="$2" stage="$3" message="$4" version="$5"
	local f="$JOBS_DIR/res_$name.json"
	{
		printf '{"state":"%s","stage":"%s","ts":"%s"' "$(json_esc "$state")" "$(json_esc "$stage")" "$(date +%s)"
		[ -z "$message" ] || printf ',"message":"%s"' "$(json_esc "$message")"
		[ -z "$version" ] || printf ',"version":"%s"' "$(json_esc "$version")"
		printf '}\n'
	} > "$f.tmp"
	mv -f "$f.tmp" "$f"
}

to_upper() {
	echo -e "$1" | tr "[a-z]" "[A-Z]"
}

check_list_update() {
	local listtype="$1"
	local listrepo="$2"
	local listref="$3"
	local listname="$4"
	local lock="$RUN_DIR/update_resources-$listtype.lock"
	local github_token="$(uci -q get homeproxy.config.github_token)"

	exec 200>"$lock"
	if ! flock -n 200 &> "/dev/null"; then
		log "[$(to_upper "$listtype")] A task is already running."
		job_write "$listtype" "locked" "checking" "a task is already running"
		return 2
	fi

	set -- -fsSL --connect-timeout 10 --max-time 15
	[ -z "$github_token" ] || set -- "$@" -H "Authorization: Bearer $github_token"
	local list_info="$(curl "$@" "https://api.github.com/repos/$listrepo/commits?sha=$listref&path=$listname&per_page=1" 2>/dev/null)"
	local list_sha="$(echo -e "$list_info" | jsonfilter -qe "@[0].sha")"
	local list_ver="$(echo -e "$list_info" | jsonfilter -qe "@[0].commit.message" | grep -Eo "[0-9-]+" | tr -d '-')"
	if [ -z "$list_sha" ] || [ -z "$list_ver" ]; then
		log "[$(to_upper "$listtype")] Failed to get the latest version, please retry later."
		job_write "$listtype" "error" "checking" "failed to get the latest version, please retry later"
		return 1
	fi

	local local_list_ver="$(cat "$RESOURCES_DIR/$listtype.ver" 2>"/dev/null" || echo "NOT FOUND")"
	if [ "$local_list_ver" = "$list_ver" ]; then
		log "[$(to_upper "$listtype")] Current version: $list_ver."
		log "[$(to_upper "$listtype")] You're already at the latest version."
		job_write "$listtype" "latest" "done" "" "$list_ver"
		return 3
	else
		log "[$(to_upper "$listtype")] Local version: $local_list_ver, latest version: $list_ver."
	fi

	job_write "$listtype" "running" "downloading" "" "$list_ver"

	if ! curl -fsSL --connect-timeout 10 --max-time 45 --retry 1 -o "$RUN_DIR/$listname" \
		"https://fastly.jsdelivr.net/gh/$listrepo@$list_sha/$listname" || [ ! -s "$RUN_DIR/$listname" ]; then
		rm -f "$RUN_DIR/$listname"
		log "[$(to_upper "$listtype")] Update failed."
		job_write "$listtype" "error" "downloading" "update failed" "$list_ver"
		return 1
	fi

	mv -f "$RUN_DIR/$listname" "$RESOURCES_DIR/$listtype.${listname##*.}"
	echo -e "$list_ver" > "$RESOURCES_DIR/$listtype.ver"
	log "[$(to_upper "$listtype")] Successfully updated."
	job_write "$listtype" "success" "done" "" "$list_ver"

	return 0
}

check_dashboard_update() {
	local repo="SagerNet/sing-box-dashboard"
	local branch="gh-pages"
	local lock="$RUN_DIR/update_resources-dashboard.lock"
	local github_token="$(uci -q get homeproxy.config.github_token)"

	exec 201>"$lock"
	if ! flock -n 201 &> "/dev/null"; then
		log "[DASHBOARD] A task is already running."
		job_write "dashboard" "locked" "checking" "a task is already running"
		return 2
	fi

	set -- -fsSL --connect-timeout 10 --max-time 15
	[ -z "$github_token" ] || set -- "$@" -H "Authorization: Bearer $github_token"
	local commit_info="$(curl "$@" "https://api.github.com/repos/$repo/commits?sha=$branch&per_page=1" 2>/dev/null)"
	local commit_sha="$(echo -e "$commit_info" | jsonfilter -qe "@[0].sha")"
	if [ -z "$commit_sha" ]; then
		log "[DASHBOARD] Failed to get the latest version, please retry later."
		job_write "dashboard" "error" "checking" "failed to get the latest version, please retry later"
		return 1
	fi
	local dashboard_ver="$(echo -e "$commit_sha" | cut -c1-7)"

	local local_dashboard_ver="$(cat "$RESOURCES_DIR/dashboard.ver" 2>"/dev/null" || echo "NOT FOUND")"
	if [ "$local_dashboard_ver" = "$dashboard_ver" ] && [ -s "$DASHBOARD_DIR/index.html" ]; then
		log "[DASHBOARD] Current version: $dashboard_ver."
		log "[DASHBOARD] You're already at the latest version."
		job_write "dashboard" "latest" "done" "" "$dashboard_ver"
		return 3
	else
		log "[DASHBOARD] Local version: $local_dashboard_ver, latest version: $dashboard_ver."
	fi

	job_write "dashboard" "running" "downloading" "" "$dashboard_ver"

	local tmp_zip="$RUN_DIR/dashboard.zip"
	local tmp_extract="$RUN_DIR/dashboard-extract"
	rm -rf "$tmp_zip" "$tmp_extract"

	if ! curl -fsSL --connect-timeout 10 --max-time 90 --retry 1 -o "$tmp_zip" \
		"https://codeload.github.com/$repo/zip/$commit_sha" || [ ! -s "$tmp_zip" ]; then
		rm -f "$tmp_zip"
		log "[DASHBOARD] Update failed while downloading the dashboard."
		job_write "dashboard" "error" "downloading" "update failed while downloading the dashboard" "$dashboard_ver"
		return 1
	fi

	job_write "dashboard" "running" "installing" "" "$dashboard_ver"

	mkdir -p "$tmp_extract"
	if ! unzip -q -o "$tmp_zip" -d "$tmp_extract"; then
		rm -rf "$tmp_zip" "$tmp_extract"
		log "[DASHBOARD] Update failed while extracting the dashboard."
		job_write "dashboard" "error" "installing" "Update failed while extracting the dashboard" "$dashboard_ver"
		return 1
	fi

	local index_file="$(find "$tmp_extract" -maxdepth 2 -name "index.html" | head -n1)"
	local src_dir="${index_file%/index.html}"
	if [ -z "$src_dir" ]; then
		rm -rf "$tmp_zip" "$tmp_extract"
		log "[DASHBOARD] Update failed: invalid dashboard archive."
		job_write "dashboard" "error" "installing" "Update failed: invalid dashboard archive" "$dashboard_ver"
		return 1
	fi

	local dashboard_stage="$DASHBOARD_DIR.new.$$"
	rm -rf "$dashboard_stage"
	if ! cp -a "$src_dir" "$dashboard_stage"; then
		rm -rf "$tmp_zip" "$tmp_extract" "$dashboard_stage"
		log "[DASHBOARD] Update failed while staging the dashboard."
		job_write "dashboard" "error" "installing" "Update failed while staging the dashboard" "$dashboard_ver"
		return 1
	fi

	chmod 755 "$dashboard_stage"
	find "$dashboard_stage" -type d -exec chmod 755 {} +
	find "$dashboard_stage" -type f -exec chmod 644 {} +

	local new_list="$RUN_DIR/dashboard-new.list"
	find "$dashboard_stage" -type f > "$new_list"
	while read -r src; do
		rel="${src#$dashboard_stage/}"
		dest="$DASHBOARD_DIR/$rel"
		destdir="$(dirname "$dest")"
		if ! mkdir -p "$destdir"; then
			rm -f "$new_list"
			rm -rf "$tmp_zip" "$tmp_extract" "$dashboard_stage"
			log "[DASHBOARD] Update failed: unable to create $destdir."
			job_write "dashboard" "error" "installing" "Update failed: unable to create $destdir" "$dashboard_ver"
			return 1
		fi
		tmp="$dest.new.$$"
		if ! cp -a "$src" "$tmp"; then
			rm -f "$tmp" "$new_list"
			rm -rf "$tmp_zip" "$tmp_extract" "$dashboard_stage"
			log "[DASHBOARD] Update failed: unable to stage $rel."
			job_write "dashboard" "error" "installing" "Update failed: unable to stage $rel" "$dashboard_ver"
			return 1
		fi
		if ! mv -f "$tmp" "$dest"; then
			rm -f "$tmp" "$new_list"
			rm -rf "$tmp_zip" "$tmp_extract" "$dashboard_stage"
			log "[DASHBOARD] Update failed: unable to place $rel."
			job_write "dashboard" "error" "installing" "Update failed: unable to place $rel" "$dashboard_ver"
			return 1
		fi
	done < "$new_list"
	rm -f "$new_list"

	local pending_delete="$RUN_DIR/dashboard-pending-delete.list"

	if [ -s "$pending_delete" ]; then
		while read -r f; do
			rel="${f#$DASHBOARD_DIR/}"
			[ -e "$dashboard_stage/$rel" ] || rm -rf "$f"
		done < "$pending_delete"
	fi

	find "$DASHBOARD_DIR" -mindepth 1 > "$pending_delete.tmp"
	: > "$pending_delete"
	while read -r f; do
		rel="${f#$DASHBOARD_DIR/}"
		[ -e "$dashboard_stage/$rel" ] || echo -e "$f" >> "$pending_delete"
	done < "$pending_delete.tmp"
	rm -f "$pending_delete.tmp"

	rm -rf "$dashboard_stage"

	rm -rf "$tmp_zip" "$tmp_extract"
	echo -e "$dashboard_ver" > "$RESOURCES_DIR/dashboard.ver"
	log "[DASHBOARD] Successfully updated."
	job_write "dashboard" "success" "done" "" "$dashboard_ver"

	return 0
}

case "$1" in
"china_ip4")
	check_list_update "$1" "gaoyifan/china-operator-ip" "ip-lists" "china.txt"
	;;
"china_ip6")
	check_list_update "$1" "gaoyifan/china-operator-ip" "ip-lists" "china6.txt"
	;;
"gfw_list")
	check_list_update "$1" "Loyalsoldier/v2ray-rules-dat" "release" "gfw.txt"
	;;
"china_list")
	check_list_update "$1" "Loyalsoldier/v2ray-rules-dat" "release" "direct-list.txt" && \
		sed -i -e "s/full://g" -e "/:/d" "$RESOURCES_DIR/china_list.txt"
	;;
"dashboard")
	check_dashboard_update
	;;
*)
	echo -e "Usage: $0 <china_ip4 / china_ip6 / gfw_list / china_list / dashboard>"
	exit 1
	;;
esac
