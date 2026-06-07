const ERROR_SOURCE_KEYS = [
  'last_error',
  'authorization_error',
  'connection_error',
  'webhook_error',
  'provider_error',
  'error',
];

const DISCONNECTED_STATES = [
  'disconnected',
  'disconnecting',
  'inactive',
  'logged_out',
  'not connected',
  'not_connected',
  'unauthorized',
  'unauthenticated',
  'pending_auth',
  'qr_expired',
  'closed',
];

const ERROR_STATES = ['degraded', 'error', 'failed', 'failure'];

const SENSITIVE_KEY_NAMES =
  'access[_-]?token|refresh[_-]?token|auth[_-]?token|token|secret|password|api[_-]?key|private[_-]?key|authorization|signature|x[-_]?hub[-_]?signature(?:[-_]?256)?|cookie|session(?:[_-]?id|[_-]?key)?|cw[_-]?session';

const AUTHORIZATION_HEADER_PATTERN =
  /(\b(?:authorization|proxy-authorization)\b\s*[:=]\s*)(?:bearer|basic|token)\s+[^\s,;]+/gi;

const COOKIE_HEADER_PATTERN = /(\bcookie\b\s*[:=]\s*)[^\r\n]+/gi;

const SIGNATURE_DIGEST_PATTERN = /\b(sha1|sha256|hmac)[:=][a-z0-9+/=_-]{8,}/gi;

const SIGNATURE_COMPARISON_PATTERN =
  /\b(expected|actual|provided|received|got)\s*(?::|=|\s)\s*[a-z0-9+/=_:-]{8,}/gi;

const QUERY_SECRET_PATTERN = new RegExp(
  `([?&](?:${SENSITIVE_KEY_NAMES})=)[^&\\s]+`,
  'gi'
);

const SENSITIVE_KEY_PATTERN = new RegExp(
  `(["']?(?:${SENSITIVE_KEY_NAMES})["']?\\s*[:=]\\s*)("[^"]+"|'[^']+'|[^\\s,;}&]+)`,
  'gi'
);

export const sanitizeInboxHealthDetail = value => {
  if (!value || typeof value !== 'string') {
    return '';
  }

  return value
    .replace(AUTHORIZATION_HEADER_PATTERN, (_match, prefix) => {
      return `${prefix}[REDACTED]`;
    })
    .replace(COOKIE_HEADER_PATTERN, (_match, prefix) => {
      return `${prefix}[REDACTED]`;
    })
    .replace(SIGNATURE_DIGEST_PATTERN, (_match, algorithm) => {
      return `${algorithm}=[REDACTED]`;
    })
    .replace(SIGNATURE_COMPARISON_PATTERN, (_match, label) => {
      return `${label} [REDACTED]`;
    })
    .replace(QUERY_SECRET_PATTERN, (_match, prefix) => {
      return `${prefix}[REDACTED]`;
    })
    .replace(SENSITIVE_KEY_PATTERN, (_match, prefix) => {
      return `${prefix}[REDACTED]`;
    });
};

const normalizeState = value =>
  String(value || '')
    .trim()
    .toLowerCase();

const stateFrom = (source, keys) => {
  if (!source || typeof source !== 'object') {
    return '';
  }

  return keys
    .map(key => normalizeState(source[key]))
    .filter(Boolean)
    .join(' ');
};

const errorValuesFrom = sources =>
  sources.flatMap(source =>
    ERROR_SOURCE_KEYS.map(key =>
      source && typeof source === 'object' ? source[key] : undefined
    )
  );

const hasErrorValue = value => {
  if (typeof value === 'string') {
    return Boolean(value.trim());
  }

  if (Array.isArray(value)) {
    return value.length > 0;
  }

  if (value && typeof value === 'object') {
    return Object.keys(value).length > 0;
  }

  return Boolean(value);
};

const errorInfoFrom = sources => {
  const errorValues = errorValuesFrom(sources);
  const rawDetail = errorValues.find(
    value => typeof value === 'string' && value.trim()
  );

  return {
    detail: sanitizeInboxHealthDetail(rawDetail),
    present: errorValues.some(hasErrorValue),
  };
};

export const getInboxHealthStatus = inbox => {
  if (!inbox) {
    return null;
  }

  const runtimeState = inbox.runtime_state || {};
  const additionalAttributes = inbox.additional_attributes || {};
  const providerConfig = inbox.provider_config || {};
  const evolutionState = additionalAttributes.evolution || {};
  const sources = [
    inbox,
    runtimeState,
    additionalAttributes,
    providerConfig,
    evolutionState,
  ];
  const errorInfo = errorInfoFrom(sources);
  const detail = errorInfo.detail;
  const combinedState = [
    detail,
    stateFrom(inbox, ['lifecycle_state', 'connection_state', 'status']),
    stateFrom(runtimeState, [
      'lifecycle_state',
      'connection_state',
      'auth_state',
      'status',
    ]),
    stateFrom(additionalAttributes, [
      'lifecycle_state',
      'connection_state',
      'auth_state',
      'status',
    ]),
    stateFrom(providerConfig, [
      'authorization_status',
      'connection_state',
      'status',
    ]),
    stateFrom(evolutionState, ['status', 'state']),
  ]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();

  if (inbox.reauthorization_required || inbox.requires_reauthorization) {
    return {
      id: 'reauthorization_required',
      tone: 'ruby',
      icon: 'i-lucide-plug-zap',
      labelKey: 'INBOX_MGMT.HEALTH_STATUS.REAUTHORIZATION_REQUIRED',
      descriptionKey:
        'INBOX_MGMT.HEALTH_STATUS.REAUTHORIZATION_REQUIRED_DESCRIPTION',
      detail,
    };
  }

  if (/signature|hmac|webhook.*invalid|invalid.*webhook/.test(combinedState)) {
    return {
      id: 'webhook_signature_invalid',
      tone: 'amber',
      icon: 'i-lucide-shield-alert',
      labelKey: 'INBOX_MGMT.HEALTH_STATUS.WEBHOOK_SIGNATURE_INVALID',
      descriptionKey:
        'INBOX_MGMT.HEALTH_STATUS.WEBHOOK_SIGNATURE_INVALID_DESCRIPTION',
      detail,
    };
  }

  if (
    /provider.*unavailable|unavailable|timeout|temporar|connection reset|network error/.test(
      combinedState
    )
  ) {
    return {
      id: 'provider_unavailable',
      tone: 'amber',
      icon: 'i-lucide-cloud-off',
      labelKey: 'INBOX_MGMT.HEALTH_STATUS.PROVIDER_UNAVAILABLE',
      descriptionKey:
        'INBOX_MGMT.HEALTH_STATUS.PROVIDER_UNAVAILABLE_DESCRIPTION',
      detail,
    };
  }

  if (DISCONNECTED_STATES.some(state => combinedState.includes(state))) {
    return {
      id: 'disconnected',
      tone: 'ruby',
      icon: 'i-lucide-plug-zap',
      labelKey: 'INBOX_MGMT.HEALTH_STATUS.DISCONNECTED',
      descriptionKey: 'INBOX_MGMT.HEALTH_STATUS.DISCONNECTED_DESCRIPTION',
      detail,
    };
  }

  if (
    errorInfo.present ||
    ERROR_STATES.some(state => combinedState.includes(state))
  ) {
    return {
      id: 'provider_unavailable',
      tone: 'amber',
      icon: 'i-lucide-cloud-off',
      labelKey: 'INBOX_MGMT.HEALTH_STATUS.PROVIDER_UNAVAILABLE',
      descriptionKey:
        'INBOX_MGMT.HEALTH_STATUS.PROVIDER_UNAVAILABLE_DESCRIPTION',
      detail,
    };
  }

  return {
    id: 'connected',
    tone: 'teal',
    icon: 'i-lucide-check-circle',
    labelKey: 'INBOX_MGMT.HEALTH_STATUS.CONNECTED',
    descriptionKey: 'INBOX_MGMT.HEALTH_STATUS.CONNECTED_DESCRIPTION',
    detail: '',
  };
};
