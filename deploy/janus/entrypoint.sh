#!/bin/sh
set -eu

JANUS_RTP_PORT_RANGE="${JANUS_RTP_PORT_RANGE:-20000-20100}"
JANUS_MEDIA_RTP_PORT_RANGE="${JANUS_MEDIA_RTP_PORT_RANGE:-${JANUS_RTP_PORT_RANGE}}"
JANUS_SIP_RTP_PORT_RANGE="${JANUS_SIP_RTP_PORT_RANGE:-${JANUS_RTP_PORT_RANGE}}"
JANUS_STUN_SERVER="${JANUS_STUN_SERVER-stun.l.google.com}"
JANUS_STUN_PORT="${JANUS_STUN_PORT:-19302}"
JANUS_FULL_TRICKLE="${JANUS_FULL_TRICKLE:-true}"
JANUS_NICE_DEBUG="${JANUS_NICE_DEBUG:-false}"
JANUS_ICE_ENFORCE_LIST="${JANUS_ICE_ENFORCE_LIST:-}"
JANUS_ICE_IGNORE_LIST="${JANUS_ICE_IGNORE_LIST:-}"
JANUS_HTTP_PORT="${JANUS_HTTP_PORT:-8088}"
JANUS_HTTP_IP="${JANUS_HTTP_IP:-0.0.0.0}"
JANUS_HTTP_INTERFACE="${JANUS_HTTP_INTERFACE:-}"
JANUS_WS_PORT="${JANUS_WS_PORT:-8188}"
JANUS_WS_IP="${JANUS_WS_IP:-}"
JANUS_WS_INTERFACE="${JANUS_WS_INTERFACE:-}"
JANUS_WS_PINGPONG_TRIGGER="${JANUS_WS_PINGPONG_TRIGGER:-30}"
JANUS_WS_PINGPONG_TIMEOUT="${JANUS_WS_PINGPONG_TIMEOUT:-10}"
JANUS_RECLAIM_SESSION_TIMEOUT="${JANUS_RECLAIM_SESSION_TIMEOUT:-15}"
JANUS_DEBUG_LEVEL="${JANUS_DEBUG_LEVEL:-3}"
JANUS_NAT_1_1_MAPPING="${JANUS_NAT_1_1_MAPPING:-${JANUS_PUBLIC_IP:-}}"
JANUS_SIP_BEHIND_NAT="${JANUS_SIP_BEHIND_NAT:-}"
if [ -z "${JANUS_SIP_BEHIND_NAT}" ]; then
	if [ -n "${JANUS_NAT_1_1_MAPPING}" ]; then
		JANUS_SIP_BEHIND_NAT=true
	else
		JANUS_SIP_BEHIND_NAT=false
	fi
fi
JANUS_SIP_SDP_IP="${JANUS_SIP_SDP_IP:-${JANUS_NAT_1_1_MAPPING}}"
JANUS_SIP_LOCAL_IP="${JANUS_SIP_LOCAL_IP:-}"
JANUS_SIP_LOCAL_MEDIA_IP="${JANUS_SIP_LOCAL_MEDIA_IP:-}"
JANUS_SIP_REGISTER_TTL="${JANUS_SIP_REGISTER_TTL:-60}"
JANUS_SIP_KEEPALIVE_INTERVAL="${JANUS_SIP_KEEPALIVE_INTERVAL:-25}"
JANUS_SIP_TIMER_T1X64="${JANUS_SIP_TIMER_T1X64:-32000}"
JANUS_DISABLED_PLUGINS="${JANUS_DISABLED_PLUGINS:-libjanus_audiobridge.so,libjanus_echotest.so,libjanus_nosip.so,libjanus_recordplay.so,libjanus_streaming.so,libjanus_textroom.so,libjanus_videocall.so,libjanus_videoroom.so}"
JANUS_SANITIZE_RESOLV_CONF="${JANUS_SANITIZE_RESOLV_CONF:-true}"
JANUS_AUDIOBRIDGE_ENABLED="${JANUS_AUDIOBRIDGE_ENABLED:-false}"
JANUS_KEEP_PRIVATE_HOST="${JANUS_KEEP_PRIVATE_HOST:-${JANUS_AUDIOBRIDGE_ENABLED}}"

case "${JANUS_AUDIOBRIDGE_ENABLED}:${JANUS_KEEP_PRIVATE_HOST}" in
	true:true|true:false|false:true|false:false) ;;
	*) printf '%s\n' 'Janus AudioBridge and private-host options must be true or false' >&2; exit 1 ;;
esac

if [ "${JANUS_AUDIOBRIDGE_ENABLED}" = "true" ]; then
	# This server-only key is shared with the Telegram adapter, never a browser.
	case "${JANUS_AUDIOBRIDGE_ADMIN_KEY:-}" in
		''|*[!A-Za-z0-9_-]*) printf '%s\n' 'A URL-safe JANUS_AUDIOBRIDGE_ADMIN_KEY is required' >&2; exit 1 ;;
	esac
	if [ "${#JANUS_AUDIOBRIDGE_ADMIN_KEY}" -lt 32 ] || [ "${#JANUS_AUDIOBRIDGE_ADMIN_KEY}" -gt 256 ]; then
		printf '%s\n' 'JANUS_AUDIOBRIDGE_ADMIN_KEY must contain 32 to 256 characters' >&2
		exit 1
	fi
	disabled_plugins=''
	for plugin in $(printf '%s' "${JANUS_DISABLED_PLUGINS}" | tr ',' ' '); do
		[ "${plugin}" = 'libjanus_audiobridge.so' ] && continue
		disabled_plugins="${disabled_plugins}${disabled_plugins:+,}${plugin}"
	done
	JANUS_DISABLED_PLUGINS="${disabled_plugins}"
	# No sample/static rooms; all call rooms are created privately by the adapter.
	umask 077
	cat > /etc/janus/janus.plugin.audiobridge.jcfg <<EOF
general: {
	admin_key = "${JANUS_AUDIOBRIDGE_ADMIN_KEY}"
	lock_rtp_forward = true
	lock_play_file = true
}
EOF
fi

if [ "${JANUS_SANITIZE_RESOLV_CONF}" = "true" ] && [ -w /etc/resolv.conf ]; then
	awk '/^nameserver[[:space:]]+/ { print }' /etc/resolv.conf > /tmp/janus-resolv.conf
	if [ -s /tmp/janus-resolv.conf ]; then
		cp /tmp/janus-resolv.conf /etc/resolv.conf
	fi
	rm -f /tmp/janus-resolv.conf
fi

cat > /etc/janus/janus.transport.http.jcfg <<EOF
general: {
	json = "compact"
	base_path = "/janus"
	http = true
	port = ${JANUS_HTTP_PORT}
EOF

if [ -n "${JANUS_HTTP_INTERFACE}" ]; then
	printf '\tinterface = "%s"\n' "${JANUS_HTTP_INTERFACE}" >> /etc/janus/janus.transport.http.jcfg
fi

if [ -n "${JANUS_HTTP_IP}" ]; then
	printf '\tip = "%s"\n' "${JANUS_HTTP_IP}" >> /etc/janus/janus.transport.http.jcfg
fi

cat >> /etc/janus/janus.transport.http.jcfg <<EOF
	https = false
}

admin: {
	admin_http = false
	admin_https = false
}

cors: {
}

certificates: {
}
EOF

cat > /etc/janus/janus.transport.websockets.jcfg <<EOF
general: {
	json = "compact"
	ws = true
	ws_port = ${JANUS_WS_PORT}
	pingpong_trigger = ${JANUS_WS_PINGPONG_TRIGGER}
	pingpong_timeout = ${JANUS_WS_PINGPONG_TIMEOUT}
EOF

if [ -n "${JANUS_WS_INTERFACE}" ]; then
	printf '\tws_interface = "%s"\n' "${JANUS_WS_INTERFACE}" >> /etc/janus/janus.transport.websockets.jcfg
fi

if [ -n "${JANUS_WS_IP}" ]; then
	printf '\tws_ip = "%s"\n' "${JANUS_WS_IP}" >> /etc/janus/janus.transport.websockets.jcfg
fi

cat >> /etc/janus/janus.transport.websockets.jcfg <<EOF
	wss = false
}

admin: {
	admin_ws = false
	admin_wss = false
}

cors: {
}

certificates: {
}
EOF

cat > /etc/janus/janus.jcfg <<EOF
general: {
	configs_folder = "/etc/janus"
	plugins_folder = "/opt/janus/plugins"
	transports_folder = "/opt/janus/transports"
	events_folder = "/opt/janus/events"
	loggers_folder = "/opt/janus/loggers"
	log_to_stdout = true
	debug_level = ${JANUS_DEBUG_LEVEL}
	reclaim_session_timeout = ${JANUS_RECLAIM_SESSION_TIMEOUT}
}

nat: {
	nice_debug = ${JANUS_NICE_DEBUG}
	full_trickle = ${JANUS_FULL_TRICKLE}
EOF

if [ -n "${JANUS_STUN_SERVER}" ]; then
	printf '\tstun_server = "%s"\n\tstun_port = %s\n' "${JANUS_STUN_SERVER}" "${JANUS_STUN_PORT}" >> /etc/janus/janus.jcfg
fi

if [ -n "${JANUS_NAT_1_1_MAPPING}" ]; then
	printf '\tnat_1_1_mapping = "%s"\n' "${JANUS_NAT_1_1_MAPPING}" >> /etc/janus/janus.jcfg
	# The browser uses the public address; the Telegram adapter stays on Docker LAN.
	printf '\tkeep_private_host = %s\n' "${JANUS_KEEP_PRIVATE_HOST}" >> /etc/janus/janus.jcfg
fi

if [ -n "${JANUS_ICE_ENFORCE_LIST}" ]; then
	printf '\tice_enforce_list = "%s"\n' "${JANUS_ICE_ENFORCE_LIST}" >> /etc/janus/janus.jcfg
fi

if [ -n "${JANUS_ICE_IGNORE_LIST}" ]; then
	printf '\tice_ignore_list = "%s"\n' "${JANUS_ICE_IGNORE_LIST}" >> /etc/janus/janus.jcfg
fi

cat >> /etc/janus/janus.jcfg <<EOF
}

media: {
	rtp_port_range = "${JANUS_MEDIA_RTP_PORT_RANGE}"
}
EOF

if [ -n "${JANUS_DISABLED_PLUGINS}" ]; then
	cat >> /etc/janus/janus.jcfg <<EOF

plugins: {
	disable = "${JANUS_DISABLED_PLUGINS}"
}
EOF
fi

cat > /etc/janus/janus.plugin.sip.jcfg <<EOF
general: {
EOF

if [ -n "${JANUS_SIP_LOCAL_IP}" ]; then
	printf '\tlocal_ip = "%s"\n' "${JANUS_SIP_LOCAL_IP}" >> /etc/janus/janus.plugin.sip.jcfg
fi

if [ -n "${JANUS_SIP_LOCAL_MEDIA_IP}" ]; then
	printf '\tlocal_media_ip = "%s"\n' "${JANUS_SIP_LOCAL_MEDIA_IP}" >> /etc/janus/janus.plugin.sip.jcfg
fi

if [ -n "${JANUS_SIP_SDP_IP}" ]; then
	printf '\tsdp_ip = "%s"\n' "${JANUS_SIP_SDP_IP}" >> /etc/janus/janus.plugin.sip.jcfg
fi

cat >> /etc/janus/janus.plugin.sip.jcfg <<EOF
	keepalive_interval = ${JANUS_SIP_KEEPALIVE_INTERVAL}
	behind_nat = ${JANUS_SIP_BEHIND_NAT}
	register_ttl = ${JANUS_SIP_REGISTER_TTL}
	rtp_port_range = "${JANUS_SIP_RTP_PORT_RANGE}"
	sip_timer_t1x64 = ${JANUS_SIP_TIMER_T1X64}
	user_agent = "OneLink Janus SIP"
}
EOF

exec janus -F /etc/janus
