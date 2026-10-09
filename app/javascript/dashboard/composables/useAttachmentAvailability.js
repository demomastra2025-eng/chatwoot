import { computed, reactive, unref } from 'vue';
import { useRoute } from 'vue-router';
import { useStore } from 'vuex';

const ATTACHMENT_CHECK_TTL_MS = 5 * 60 * 1000;
const MAX_ATTACHMENT_CHECKS = 200;
const MAX_CONFIRMED_PURGED_ATTACHMENTS = 500;

const attachmentChecks = new Map();
const confirmedPurgedAttachments = reactive(new Set());

const isPurgedPayload = attachment =>
  attachment?.filePurged === true || attachment?.file_purged === true;

const attachmentKey = (accountId, conversationId, attachmentId) =>
  [accountId || '', conversationId, attachmentId].join(':');

const pruneAttachmentChecks = timestamp => {
  for (const [key, check] of attachmentChecks) {
    if (timestamp - check.checkedAt >= ATTACHMENT_CHECK_TTL_MS) {
      attachmentChecks.delete(key);
    }
  }
};

const rememberConfirmedPurge = (attachmentId, identity) => {
  const key = attachmentKey(
    identity.accountId,
    identity.selectedChatId,
    attachmentId
  );
  confirmedPurgedAttachments.add(key);

  if (confirmedPurgedAttachments.size > MAX_CONFIRMED_PURGED_ATTACHMENTS) {
    const oldestId = confirmedPurgedAttachments.values().next().value;
    confirmedPurgedAttachments.delete(oldestId);
  }
};

export const isAttachmentConfirmedPurged = (attachmentOrId, identity = {}) => {
  const attachment =
    typeof attachmentOrId === 'object' ? attachmentOrId : null;
  const attachmentId = attachment ? attachment.id : attachmentOrId;
  const accountId =
    identity.accountId ?? attachment?.accountId ?? attachment?.account_id;
  const conversationId =
    identity.conversationId ??
    identity.selectedChatId ??
    attachment?.conversationId ??
    attachment?.conversation_id;

  if (
    attachmentId === undefined ||
    attachmentId === null ||
    accountId === undefined ||
    accountId === null ||
    conversationId === undefined ||
    conversationId === null
  ) {
    return false;
  }

  return confirmedPurgedAttachments.has(
    attachmentKey(accountId, conversationId, attachmentId)
  );
};

export const createAttachmentAvailability = ({
  attachment,
  dispatch,
  getIdentity,
  now = Date.now,
}) => {
  const isPurged = computed(() => {
    const currentAttachment = unref(attachment);
    const identity = getIdentity();
    return (
      isPurgedPayload(currentAttachment) ||
      isAttachmentConfirmedPurged(currentAttachment, {
        accountId: identity?.accountId,
        conversationId: identity?.selectedChatId,
      })
    );
  });

  const refreshAfterMediaFailure = async () => {
    const currentAttachment = unref(attachment);
    if (!currentAttachment?.id || isPurgedPayload(currentAttachment)) {
      return isPurged.value;
    }

    const identity = getIdentity();
    if (!identity?.selectedChatId || !identity?.routeFullPath) return false;

    const currentTime = now();
    pruneAttachmentChecks(currentTime);

    const checkKey = attachmentKey(
      identity.accountId,
      identity.selectedChatId,
      currentAttachment.id
    );
    const existingCheck = attachmentChecks.get(checkKey);
    if (existingCheck) {
      if (existingCheck.promise) await existingCheck.promise;
      return isPurged.value;
    }

    if (attachmentChecks.size >= MAX_ATTACHMENT_CHECKS) {
      const oldestKey = attachmentChecks.keys().next().value;
      attachmentChecks.delete(oldestKey);
    }

    const requestIdentity = { ...identity };
    const check = { checkedAt: currentTime, promise: null };
    attachmentChecks.set(checkKey, check);
    check.promise = Promise.resolve()
      .then(() =>
        dispatch('fetchAllAttachments', {
          conversationId: identity.selectedChatId,
          isCommunicationThread: Boolean(identity.isCommunicationThread),
          expectedRouteFullPath: identity.routeFullPath,
          expectedAccountId: identity.accountId,
          expectedSelectedChatId: identity.selectedChatId,
          expectedSelectedChatType: identity.selectedChatType,
        })
      )
      .then(attachments => {
        const latestIdentity = getIdentity();
        if (
          latestIdentity?.routeFullPath !== requestIdentity.routeFullPath ||
          String(latestIdentity?.accountId) !==
            String(requestIdentity.accountId) ||
          String(latestIdentity?.selectedChatId) !==
            String(requestIdentity.selectedChatId) ||
          latestIdentity?.selectedChatType !== requestIdentity.selectedChatType
        ) {
          attachmentChecks.delete(checkKey);
          return;
        }

        const refreshedAttachment = Array.isArray(attachments)
          ? attachments.find(
              item => String(item?.id) === String(currentAttachment.id)
            )
          : null;
        if (isPurgedPayload(refreshedAttachment)) {
          rememberConfirmedPurge(currentAttachment.id, requestIdentity);
        }
      })
      .catch(() => {})
      .finally(() => {
        check.promise = null;
      });

    await check.promise;
    return isPurged.value;
  };

  return { isPurged, refreshAfterMediaFailure };
};

export const useAttachmentAvailability = attachment => {
  const store = useStore();
  const route = useRoute();
  const selectedChat = computed(() => store.getters.getSelectedChat || {});

  return createAttachmentAvailability({
    attachment,
    dispatch: store.dispatch.bind(store),
    getIdentity: () => {
      const chat = selectedChat.value || {};
      return {
        accountId: route.params?.accountId,
        routeFullPath: route.fullPath,
        selectedChatId: chat.id,
        selectedChatType: store.state.conversations?.selectedChatType,
        isCommunicationThread: Boolean(chat.is_communication_thread),
      };
    },
  });
};
