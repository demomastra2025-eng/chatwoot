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

// How long the end of a call is remembered so that a snapshot that was asked
// for before the call ended cannot bring its line back.
const ENDED_CALL_MEMORY_MS = 10 * 60 * 1000;

export const useCallOperatorActivityStore = defineStore(
  'callOperatorActivity',
  {
    state: () => ({
      // call id -> { callId, conversationId, communicationThreadId,
      // operatorUserId, operatorName, state, receivedAt }
      entries: {},
      // call id -> when the realtime event that ended the call arrived
      endedCalls: {},
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
        if (entry.state === OPERATOR_ACTIVITY_STATES.ENDED) {
          this.rememberEndedCall(entry.callId, now);
        }
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

      rememberEndedCall(callId, now = Date.now()) {
        const kept = Object.entries(this.endedCalls).filter(
          ([, endedAt]) => now - endedAt < ENDED_CALL_MEMORY_MS
        );
        this.endedCalls = {
          ...Object.fromEntries(kept),
          [String(callId)]: now,
        };
      },

      // Fills in a chat with what the server says is on right now (page opened,
      // connection came back). The answer describes the moment the request was
      // made: whatever a realtime event decided since then (requestedAt) wins,
      // a line it created, updated or ended, so a late answer can neither bring
      // an ended call back nor erase a call that has just started. Without
      // requestedAt the answer replaces everything known about the chat.
      syncChat(
        chat,
        items,
        currentUserId,
        now = Date.now(),
        { requestedAt = Infinity } = {}
      ) {
        this.entries = Object.fromEntries(
          Object.entries(this.entries).filter(
            ([, entry]) =>
              !activityMatchesChat(entry, chat) ||
              entry.receivedAt >= requestedAt
          )
        );
        (items || []).forEach(item => {
          const callId = String(item?.call_id ?? item?.callId);
          const endedAt = this.endedCalls[callId];
          if (isPresent(endedAt) && endedAt >= requestedAt) return;
          if (this.entries[callId]) return;

          this.applyActivity(item, currentUserId, now);
        });
      },

      pruneStale(now = Date.now()) {
        const kept = Object.entries(this.entries).filter(([, entry]) =>
          isFresh(entry, now)
        );
        if (kept.length !== Object.keys(this.entries).length) {
          this.entries = Object.fromEntries(kept);
        }
        const rememberedEnds = Object.entries(this.endedCalls).filter(
          ([, endedAt]) => now - endedAt < ENDED_CALL_MEMORY_MS
        );
        if (rememberedEnds.length !== Object.keys(this.endedCalls).length) {
          this.endedCalls = Object.fromEntries(rememberedEnds);
        }
      },

      clear() {
        this.entries = {};
        this.endedCalls = {};
      },
    },
  }
);
