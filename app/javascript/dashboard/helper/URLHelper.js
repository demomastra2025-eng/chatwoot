export const frontendURL = (path, params) => {
  const queryEntries = Object.entries(params || {}).filter(
    ([, value]) => value !== undefined && value !== null && value !== ''
  );
  const stringifiedParams = queryEntries.length
    ? `${path.includes('?') ? '&' : '?'}${new URLSearchParams(queryEntries)}`
    : '';
  return `/app/${path}${stringifiedParams}`;
};

const CONVERSATION_STATUSES = ['open', 'pending', 'snoozed', 'resolved'];
const CONVERSATION_ASSIGNEE_TYPES = ['me', 'unassigned', 'all'];

const normalizeConversationStatus = status => {
  return CONVERSATION_STATUSES.includes(status) ? status : undefined;
};

const normalizeConversationAssigneeType = assigneeType => {
  return CONVERSATION_ASSIGNEE_TYPES.includes(assigneeType)
    ? assigneeType
    : undefined;
};

const currentConversationStatusFromLocation = () => {
  if (typeof window === 'undefined' || !window.location?.search) {
    return undefined;
  }

  const params = new URLSearchParams(window.location.search);
  return normalizeConversationStatus(params.get('status'));
};

const currentConversationAssigneeTypeFromLocation = () => {
  if (typeof window === 'undefined' || !window.location?.search) {
    return undefined;
  }

  const params = new URLSearchParams(window.location.search);
  return normalizeConversationAssigneeType(
    params.get('assignee_type') || params.get('assigneeType')
  );
};

const conversationQuery = ({
  status,
  assigneeType,
  defaultAssigneeType,
} = {}) => {
  const normalizedAssigneeType =
    normalizeConversationAssigneeType(assigneeType) ??
    currentConversationAssigneeTypeFromLocation() ??
    normalizeConversationAssigneeType(defaultAssigneeType);

  return {
    status:
      normalizeConversationStatus(status) ??
      currentConversationStatusFromLocation(),
    assignee_type: normalizedAssigneeType,
  };
};

const appendQueryToPath = (path, query = {}) => {
  const queryEntries = Object.entries(query).filter(
    ([, value]) => value !== undefined && value !== null && value !== ''
  );

  if (!queryEntries.length) {
    return path;
  }

  return `${path}?${new URLSearchParams(queryEntries).toString()}`;
};

export const conversationUrl = ({
  accountId,
  activeInbox,
  id,
  label,
  teamId,
  conversationType = '',
  foldersId,
  status,
  assigneeType,
  communicationThread = false,
}) => {
  let url = communicationThread
    ? `accounts/${accountId}/communication_threads/${id}`
    : `accounts/${accountId}/conversations/${id}`;
  if (communicationThread) {
    return appendQueryToPath(
      url,
      conversationQuery({
        status,
        assigneeType,
        defaultAssigneeType: 'me',
      })
    );
  }
  if (activeInbox) {
    url = `accounts/${accountId}/inbox/${activeInbox}/conversations/${id}`;
  } else if (label) {
    url = `accounts/${accountId}/label/${label}/conversations/${id}`;
  } else if (teamId) {
    url = `accounts/${accountId}/team/${teamId}/conversations/${id}`;
  } else if (foldersId && foldersId !== 0) {
    url = `accounts/${accountId}/custom_view/${foldersId}/conversations/${id}`;
  } else if (conversationType === 'mention') {
    url = `accounts/${accountId}/mentions/conversations/${id}`;
  } else if (conversationType === 'participating') {
    url = `accounts/${accountId}/participating/conversations/${id}`;
  } else if (conversationType === 'unattended') {
    url = `accounts/${accountId}/unattended/conversations/${id}`;
  }
  return appendQueryToPath(url, conversationQuery({ status, assigneeType }));
};

export const conversationListPageURL = ({
  accountId,
  conversationType = '',
  inboxId,
  label,
  teamId,
  customViewId,
  status,
  assigneeType,
  communicationThread = false,
}) => {
  let url = communicationThread
    ? `accounts/${accountId}/communication_threads`
    : `accounts/${accountId}/dashboard`;
  if (communicationThread) {
    return frontendURL(
      appendQueryToPath(
        url,
        conversationQuery({
          status,
          assigneeType,
          defaultAssigneeType: 'me',
        })
      )
    );
  }
  if (label) {
    url = `accounts/${accountId}/label/${label}`;
  } else if (teamId) {
    url = `accounts/${accountId}/team/${teamId}`;
  } else if (inboxId) {
    url = `accounts/${accountId}/inbox/${inboxId}`;
  } else if (customViewId) {
    url = `accounts/${accountId}/custom_view/${customViewId}`;
  } else if (conversationType) {
    const urlMap = {
      mention: 'mentions/conversations',
      participating: 'participating/conversations',
      unattended: 'unattended/conversations',
    };
    url = `accounts/${accountId}/${urlMap[conversationType]}`;
  }
  return frontendURL(
    appendQueryToPath(url, conversationQuery({ status, assigneeType }))
  );
};

export const isValidURL = value => {
  /* eslint-disable no-useless-escape */
  const URL_REGEX =
    /^https?:\/\/(?:www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&//=]*)$/gm;
  return URL_REGEX.test(value);
};

export const getArticleSearchURL = ({
  host,
  portalSlug,
  pageNumber,
  locale,
  status,
  authorId,
  categorySlug,
  sort,
  query,
}) => {
  const queryParams = new URLSearchParams({});

  const params = {
    page: pageNumber,
    locale,
    status,
    author_id: authorId,
    category_slug: categorySlug,
    sort,
    query,
  };

  Object.entries(params).forEach(([key, value]) => {
    if (value !== null && value !== undefined) {
      queryParams.set(key, value);
    }
  });

  return `${host}/${portalSlug}/articles?${queryParams.toString()}`;
};

export const hasValidAvatarUrl = avatarUrl => {
  try {
    const { host: avatarUrlHost } = new URL(avatarUrl);
    const isFromGravatar = ['www.gravatar.com', 'gravatar'].includes(
      avatarUrlHost
    );
    return avatarUrl && !isFromGravatar;
  } catch (error) {
    return false;
  }
};

export const timeStampAppendedURL = dataUrl => {
  const url = new URL(dataUrl);
  if (!url.searchParams.has('t')) {
    url.searchParams.append('t', Date.now());
  }

  return url.toString();
};

export const getHostNameFromURL = url => {
  try {
    return new URL(url).hostname;
  } catch (error) {
    return null;
  }
};

/**
 * Extracts filename from a URL
 * @param {string} url - The URL to extract filename from
 * @returns {string} - The extracted filename or original URL if extraction fails
 */
export const extractFilenameFromUrl = url => {
  if (!url || typeof url !== 'string') return url;

  try {
    const urlObj = new URL(url);
    const pathname = urlObj.pathname;
    const filename = pathname.split('/').pop();
    return filename || url;
  } catch (error) {
    // If URL parsing fails, try to extract filename using regex
    const match = url.match(/\/([^/?#]+)(?:[?#]|$)/);
    return match ? match[1] : url;
  }
};

/**
 * Normalizes a comma/newline separated list of domains
 * @param {string} domains - The comma/newline separated list of domains
 * @returns {string} - The normalized list of domains
 * - Converts newlines to commas
 * - Trims whitespace
 * - Lowercases entries
 * - Removes empty values
 * - De-duplicates while preserving original order
 */
export const sanitizeAllowedDomains = domains => {
  if (!domains) return '';

  const tokens = domains
    .replace(/\r\n/g, '\n')
    .replace(/\s*\n\s*/g, ',')
    .split(',')
    .map(d => d.trim().toLowerCase())
    .filter(d => d.length > 0);

  // De-duplicate while preserving order using Set and filter index
  const seen = new Set();
  const unique = tokens.filter(d => {
    if (seen.has(d)) return false;
    seen.add(d);
    return true;
  });

  return unique.join(',');
};
