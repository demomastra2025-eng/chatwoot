import {
  CONVERSATION_PRIORITY_ORDER,
  MESSAGE_STATUS,
  MESSAGE_TYPE,
} from 'shared/constants/messages';
import { timestampInSeconds } from 'dashboard/helper/timestampHelper';

const PENDING_MESSAGE_MATCH_WINDOW_SECONDS = 5 * 60;
const ACCEPTED_OUTGOING_STATUSES = new Set([
  MESSAGE_STATUS.SENT,
  MESSAGE_STATUS.DELIVERED,
  MESSAGE_STATUS.READ,
]);

const hasAttachments = message =>
  Array.isArray(message?.attachments) && message.attachments.length > 0;

const timestampsAreClose = (leftMessage, rightMessage) => {
  const leftTimestamp = timestampInSeconds(leftMessage?.created_at);
  const rightTimestamp = timestampInSeconds(rightMessage?.created_at);
  if (leftTimestamp === null || rightTimestamp === null) return false;

  return (
    Math.abs(leftTimestamp - rightTimestamp) <=
    PENDING_MESSAGE_MATCH_WINDOW_SECONDS
  );
};

const sameConversation = (leftMessage, rightMessage) => {
  if (!leftMessage?.conversation_id || !rightMessage?.conversation_id) {
    return false;
  }

  return (
    String(leftMessage.conversation_id) === String(rightMessage.conversation_id)
  );
};

const normalizedContent = message => String(message?.content || '').trim();

const sameNonEmptyContent = (leftMessage, rightMessage) => {
  const leftContent = normalizedContent(leftMessage);
  if (!leftContent) return false;

  return leftContent === normalizedContent(rightMessage);
};

const isOutgoingTextMessage = message =>
  message?.message_type === MESSAGE_TYPE.OUTGOING && !hasAttachments(message);

export const isStalePendingMessageMatch = (pendingMessage, serverMessage) => {
  if (pendingMessage?.status !== MESSAGE_STATUS.PROGRESS) return false;
  if (!ACCEPTED_OUTGOING_STATUSES.has(serverMessage?.status)) return false;
  if (!isOutgoingTextMessage(pendingMessage)) return false;
  if (!isOutgoingTextMessage(serverMessage)) return false;
  if (!sameConversation(pendingMessage, serverMessage)) return false;
  if (!sameNonEmptyContent(pendingMessage, serverMessage)) return false;

  return timestampsAreClose(pendingMessage, serverMessage);
};

export const findPendingMessageIndex = (chat, message) => {
  const { echo_id: tempMessageId } = message;
  const sameMessageId = (leftId, rightId) =>
    leftId !== undefined &&
    leftId !== null &&
    rightId !== undefined &&
    rightId !== null &&
    String(leftId) === String(rightId);
  const identityIndex = chat.messages.findIndex(
    m => sameMessageId(m.id, message.id) || sameMessageId(m.id, tempMessageId)
  );
  if (identityIndex !== -1) return identityIndex;

  return chat.messages.findIndex(m => isStalePendingMessageMatch(m, message));
};

export const filterByStatus = (chatStatus, filterStatus) =>
  filterStatus === 'all' ? true : chatStatus === filterStatus;

const communicationThreadScopes = conversation => {
  const channels = Array.isArray(conversation.channels)
    ? conversation.channels
    : [];
  return [conversation, ...channels];
};

// One person, one status: a communication thread sits in the status tab of the thread itself (the most urgent status of its
// channels, set by the server), never in the tab of one of its channels, or a person who is open in WhatsApp and resolved in
// Telegram would be in "open" and "resolved" at once. Only the inbox is matched by any channel, like the server does.
const communicationThreadMatchesPageScope = (
  conversation,
  { status, inboxId }
) => {
  const statusMatches = status === 'all' || conversation.status === status;
  const inboxMatches = scope =>
    !inboxId || Number(scope.inbox_id) === Number(inboxId);

  return (
    statusMatches && communicationThreadScopes(conversation).some(inboxMatches)
  );
};

export const filterByInbox = (shouldFilter, inboxId, chatInboxId) => {
  const isOnInbox = Number(inboxId) === chatInboxId;
  return inboxId ? isOnInbox && shouldFilter : shouldFilter;
};

export const filterByTeam = (shouldFilter, teamId, chatTeamId) => {
  const isOnTeam = Number(teamId) === chatTeamId;
  return teamId ? isOnTeam && shouldFilter : shouldFilter;
};

export const filterByLabel = (shouldFilter, labels, chatLabels) => {
  const isOnLabel = labels.every(label => chatLabels.includes(label));
  return labels.length ? isOnLabel && shouldFilter : shouldFilter;
};

const truthyFilterValue = value =>
  value === true || value === 'true' || value === '1' || value === 1;

export const filterByUnread = (shouldFilter, unread, unreadCount = 0) => {
  return truthyFilterValue(unread)
    ? Number(unreadCount || 0) > 0 && shouldFilter
    : shouldFilter;
};

export const conversationHasCalls = conversation => {
  if (!conversation) return false;
  if (conversation.has_calls === true) return true;

  const inboxChannel =
    conversation?.meta?.channel || conversation?.channel || '';
  if (inboxChannel === 'Channel::Voice') return true;

  const channels = Array.isArray(conversation.channels)
    ? conversation.channels
    : [];
  if (channels.some(channel => channel?.channel === 'Channel::Voice')) {
    return true;
  }

  const additional = conversation.additional_attributes || {};
  if (
    additional.call_status ||
    additional.call_provider ||
    additional.call_direction
  ) {
    return true;
  }

  const messages = [
    conversation.last_non_activity_message,
    ...(Array.isArray(conversation.messages) ? conversation.messages : []),
  ].filter(Boolean);
  return messages.some(message => message?.content_type === 'voice_call');
};

export const filterByCallsOnly = (shouldFilter, callsOnly, conversation) => {
  return truthyFilterValue(callsOnly)
    ? conversationHasCalls(conversation) && shouldFilter
    : shouldFilter;
};

export const filterByUnattended = (
  shouldFilter,
  conversationType,
  firstReplyOn,
  waitingSince
) => {
  return conversationType === 'unattended'
    ? (!firstReplyOn || !!waitingSince) && shouldFilter
    : shouldFilter;
};

export const applyPageFilters = (conversation, filters) => {
  const {
    inboxId,
    status,
    labels = [],
    teamId,
    conversationType,
    unread,
    callsOnly,
    calls_only: snakeCallsOnly,
  } = filters;
  const {
    status: chatStatus,
    inbox_id: chatInboxId,
    unread_count: unreadCount,
    labels: chatLabels = [],
    meta = {},
    first_reply_created_at: firstReplyOn,
    waiting_since: waitingSince,
  } = conversation;
  const team = meta.team || {};
  const { id: chatTeamId } = team;

  const isThread = Boolean(conversation?.is_communication_thread);
  let shouldFilter = isThread
    ? communicationThreadMatchesPageScope(conversation, { status, inboxId })
    : filterByStatus(chatStatus, status);
  shouldFilter = isThread
    ? shouldFilter
    : filterByInbox(shouldFilter, inboxId, chatInboxId);
  shouldFilter = filterByTeam(shouldFilter, teamId, chatTeamId);
  shouldFilter = filterByLabel(shouldFilter, labels, chatLabels);
  shouldFilter = filterByUnread(shouldFilter, unread, unreadCount);
  shouldFilter = filterByCallsOnly(
    shouldFilter,
    callsOnly ?? snakeCallsOnly,
    conversation
  );
  shouldFilter = filterByUnattended(
    shouldFilter,
    conversationType,
    firstReplyOn,
    waitingSince
  );

  return shouldFilter;
};

/**
 * Filters conversations based on user role and permissions
 *
 * @param {Object} conversation - The conversation object to check permissions for
 * @param {string} role - The user's role (administrator, agent, etc.)
 * @param {Array<string>} permissions - List of permission strings the user has
 * @param {number|string} currentUserId - The ID of the current user
 * @returns {boolean} - Whether the user has permissions to access this conversation
 */
export const applyRoleFilter = (
  conversation,
  role,
  permissions,
  currentUserId
) => {
  // the role === "agent" check is typically not correct on it's own
  // the backend handles this by checking the custom_role_id at the user model
  // here however, the `getUserRole` returns "custom_role" if the id is present,
  // so we can check the role === "agent" directly
  if (['administrator', 'agent'].includes(role)) {
    return true;
  }

  // Check for full conversation management permission
  if (permissions.includes('conversation_manage')) {
    return true;
  }

  const conversationMeta = conversation.meta || {};
  const conversationAssignee = conversationMeta.assignee;
  const isUnassigned = !conversationAssignee;
  const isAssignedToUser = conversationAssignee?.id === currentUserId;
  const isCurrentUserParticipant = Boolean(
    conversationMeta.current_user_participant
  );

  // Check unassigned management permission
  if (permissions.includes('conversation_unassigned_manage')) {
    return isUnassigned || isAssignedToUser;
  }

  // Check participating conversation management permission
  if (permissions.includes('conversation_participating_manage')) {
    return isAssignedToUser || isCurrentUserParticipant;
  }

  return false;
};

const SORT_OPTIONS = {
  last_activity_at_asc: ['sortOnLastMessageAt', 'asc'],
  last_activity_at_desc: ['sortOnLastMessageAt', 'desc'],
  last_event_activity_at_asc: ['sortOnLastActivityAt', 'asc'],
  last_event_activity_at_desc: ['sortOnLastActivityAt', 'desc'],
  latest: ['sortOnLastMessageAt', 'desc'],
  created_at_asc: ['sortOnCreatedAt', 'asc'],
  created_at_desc: ['sortOnCreatedAt', 'desc'],
  priority_asc: ['sortOnPriority', 'asc'],
  priority_desc: ['sortOnPriority', 'desc'],
  waiting_since_asc: ['sortOnWaitingSince', 'asc'],
  waiting_since_desc: ['sortOnWaitingSince', 'desc'],
  priority_desc_created_at_asc: ['sortOnPriorityCreatedAt', 'desc'],
};
const sortAscending = (valueA, valueB) => valueA - valueB;
const sortDescending = (valueA, valueB) => valueB - valueA;

const getLastNonActivityMessage = conversation => {
  const apiMessage =
    conversation.last_non_activity_message ||
    conversation.lastNonActivityMessage;

  if (apiMessage?.created_at) {
    return apiMessage;
  }

  const messages = Array.isArray(conversation.messages)
    ? conversation.messages
    : [];

  return [...messages]
    .reverse()
    .find(
      message =>
        message.message_type !== MESSAGE_TYPE.ACTIVITY && !message.private
    );
};

const lastMessageAt = conversation => {
  return (
    getLastNonActivityMessage(conversation)?.created_at ||
    conversation.created_at
  );
};

const getSortOrderFunction = sortOrder =>
  sortOrder === 'asc' ? sortAscending : sortDescending;

const sortConfig = {
  sortOnLastMessageAt: (a, b, sortDirection) =>
    getSortOrderFunction(sortDirection)(lastMessageAt(a), lastMessageAt(b)),

  sortOnLastActivityAt: (a, b, sortDirection) =>
    getSortOrderFunction(sortDirection)(a.last_activity_at, b.last_activity_at),

  sortOnCreatedAt: (a, b, sortDirection) =>
    getSortOrderFunction(sortDirection)(a.created_at, b.created_at),

  sortOnPriority: (a, b, sortDirection) => {
    const DEFAULT_FOR_NULL = sortDirection === 'asc' ? 5 : 0;

    const p1 = CONVERSATION_PRIORITY_ORDER[a.priority] || DEFAULT_FOR_NULL;
    const p2 = CONVERSATION_PRIORITY_ORDER[b.priority] || DEFAULT_FOR_NULL;

    return getSortOrderFunction(sortDirection)(p1, p2);
  },

  sortOnPriorityCreatedAt: (a, b) => {
    const DEFAULT_FOR_NULL = 0;
    const p1 = CONVERSATION_PRIORITY_ORDER[a.priority] || DEFAULT_FOR_NULL;
    const p2 = CONVERSATION_PRIORITY_ORDER[b.priority] || DEFAULT_FOR_NULL;
    if (p1 !== p2) return p2 - p1;
    return a.created_at - b.created_at;
  },

  sortOnWaitingSince: (a, b, sortDirection) => {
    const sortFunc = getSortOrderFunction(sortDirection);
    if (!a.waiting_since || !b.waiting_since) {
      if (!a.waiting_since && !b.waiting_since) {
        return sortFunc(a.created_at, b.created_at);
      }
      return sortFunc(a.waiting_since ? 0 : 1, b.waiting_since ? 0 : 1);
    }

    return sortFunc(a.waiting_since, b.waiting_since);
  },
};

export const sortComparator = (a, b, sortKey) => {
  const [sortMethod, sortDirection] =
    SORT_OPTIONS[sortKey] || SORT_OPTIONS.last_activity_at_desc;
  return sortConfig[sortMethod](a, b, sortDirection);
};
