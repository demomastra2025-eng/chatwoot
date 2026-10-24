// The server keeps a SIP line for one browser at a time. This reason means the
// line is held by another browser: another computer of the same employee (or,
// without Web Locks, another tab). The employee moves it here explicitly.
export const WEBPHONE_LINE_ELSEWHERE_REASON =
  'sip_profile_registration_lease_owned_by_another_tab';

// The other computer is on a call, so the line was not moved.
export const WEBPHONE_TAKEOVER_REFUSED_CALL = 'call_in_progress';

export const isLineOpenElsewhere = session =>
  session?.reason === WEBPHONE_LINE_ELSEWHERE_REASON;
