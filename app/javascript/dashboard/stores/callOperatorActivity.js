import { defineStore } from 'pinia';

export const OPERATOR_ACTIVITY_STATES = {
  CALLING: 'calling',
  TALKING: 'talking',
  ENDED: 'ended',
};

// A line the server never ended is a lost event, not a live call. An outbound
// call cannot ring for long; a talking line outlives the longest allowed call
// (240 minutes) only when its end was missed.
const MAX_AGE_MS = {
  [OPERATOR_ACTIVITY_STATES.CALLING]: 3 * 60 * 1000,
  [OPERATOR_ACTIVITY_STATES.TALKING]: 250 * 60 * 1000,
};

const isPresent = value =>
  value !== undefined && value !== null && value !== '';
const sameId = (left, right) =>
  isPresent(left) && isPresent(right) && String(left) === String(right);

const normalizeActivity = (data, now) => ({
  callId: data?.call_id ?? data?.callId,
  conversationId: data?.conversation_id ?? data?.conversationId,
  communicationThreadId:
    data?.communication_thread_id ?? data?.communicationThreadId,
  operatorUserId: data?.operator_user_id ?? data?.operatorUserId,
  operatorName: data?.operator_name ?? data?.operatorName,
  state: data?.state,
  receivedAt: now,
});

const chatConversationIds = chat => {
  if (!chat) return [];
  if (!chat.is_communication_thread) return [chat.id];

  return [
    ...(chat.conversation_ids || []),
    ...(chat.channels || []).map(channel => channel.conversation_id),
  ].filter(isPresent);
};

// Whether the line is about the open chat: the conversation itself, or a
// communication thread that holds it (and the thread view of one).
export const activityMatchesChat = (entry, chat) => {
  if (!chat) return false;
  if (
    chat.is_communication_thread &&
    sameId(entry.communicationThreadId, chat.id)
  ) {
    return true;
  }
  if (chatConversationIds(chat).some(id => sameId(entry.conversationId, id))) {
    return true;
  }

  return (
    !chat.is_communication_thread &&
    sameId(entry.communicationThreadId, chat.communication_thread_id)
  );
};

const isFresh = (entry, now) =>
  now - entry.receivedAt < (MAX_AGE_MS[entry.state] || 0);

export const useCallOperatorActivityStore = defineStore(
  'callOperatorActivity',
  {
    state: () => ({
      // call id -> { callId, conversationId, communicationThreadId,
      // operatorUserId, operatorName, state, receivedAt }
      entries: {},
    }),

    getters: {
      // The lines of the open chat: one per operator (the latest), never the
      // employee's own call.
      forChat:
        state =>
        (chat, currentUserId, now = Date.now()) => {
          const latestByOperator = {};
          Object.values(state.entries)
            .filter(
              entry =>
                !sameId(entry.operatorUserId, currentUserId) &&
                isFresh(entry, now) &&
                activityMatchesChat(entry, chat)
            )
            .forEach(entry => {
              const key = String(entry.operatorUserId);
              if (
                !latestByOperator[key] ||
                latestByOperator[key].receivedAt <= entry.receivedAt
              ) {
                latestByOperator[key] = entry;
              }
            });

          return Object.values(latestByOperator).sort(
            (left, right) => left.receivedAt - right.receivedAt
          );
        },
    },

    actions: {
      applyActivity(data, currentUserId, now = Date.now()) {
        const entry = normalizeActivity(data, now);
        if (!isPresent(entry.callId)) return;

        const { [String(entry.callId)]: removed, ...rest } = this.entries;
        const isLive =
          entry.state === OPERATOR_ACTIVITY_STATES.CALLING ||
          entry.state === OPERATOR_ACTIVITY_STATES.TALKING;
        // The employee's own call needs no line; an unknown state or a call
        // that ended removes the line.
        if (!isLive || sameId(entry.operatorUserId, currentUserId)) {
          this.entries = rest;
          return;
        }

        this.entries = { ...rest, [String(entry.callId)]: entry };
      },

      // Replaces what is known about a chat with what the server says is on
      // right now (page opened, connection came back).
      syncChat(chat, items, currentUserId, now = Date.now()) {
        this.entries = Object.fromEntries(
          Object.entries(this.entries).filter(
            ([, entry]) => !activityMatchesChat(entry, chat)
          )
        );
        (items || []).forEach(item =>
          this.applyActivity(item, currentUserId, now)
        );
      },

      pruneStale(now = Date.now()) {
        const kept = Object.entries(this.entries).filter(([, entry]) =>
          isFresh(entry, now)
        );
        if (kept.length !== Object.keys(this.entries).length) {
          this.entries = Object.fromEntries(kept);
        }
      },

      clear() {
        this.entries = {};
      },
    },
  }
);
