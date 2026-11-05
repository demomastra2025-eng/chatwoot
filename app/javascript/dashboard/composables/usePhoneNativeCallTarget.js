import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import ContactAPI from 'dashboard/api/contacts';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { useWhatsappCallInitiation } from './useWhatsappCallInitiation';

// Only existing, account-visible conversations may identify a native peer.
// Never resolve a typed number through Telegram RPC or create a new contact.
export const isPrivatePhoneConversation = (conversation, inboxId) => {
  if (String(conversation.inbox_id) !== String(inboxId)) return false;
  const attrs = conversation.additional_attributes || {};
  if (attrs.is_group === true) return false;
  if (['group', 'supergroup', 'channel'].includes(attrs.chat_type))
    return false;
  const peer =
    conversation.meta?.contact_inbox?.source_id ||
    conversation.contact_inbox?.source_id ||
    attrs.chat_id ||
    attrs.peer_user_id;
  return /^\d+$/.test(String(peer || '')) && Number(peer) > 0;
};

export const usePhoneNativeCallTarget = ({ inbox, accountId, busy }) => {
  const { t } = useI18n();
  const targets = ref([]);
  const targetId = ref('');
  const targetLoading = ref(false);
  const lookupFailed = ref(false);
  let requestId = 0;
  const target = computed(() =>
    targets.value.find(item => item.value === targetId.value)
  );
  const telegram = computed(
    () => inbox.value?.channel_type === INBOX_TYPES.TELEGRAM_PERSONAL
  );
  const {
    canInitiateWhatsappCall,
    initiateWhatsappCall,
    isInitiatingWhatsappCall,
  } = useWhatsappCallInitiation({
    conversationId: computed(() => target.value?.conversation.id),
    conversation: computed(() => target.value?.conversation),
    inboxId: computed(() => inbox.value?.id),
    contact: computed(() => target.value?.contact),
    callingEnabled: computed(
      () =>
        inbox.value?.calling_enabled === true ||
        inbox.value?.provider_config?.calling_enabled === true
    ),
  });
  const reset = () => {
    requestId += 1;
    targets.value = [];
    targetId.value = '';
    targetLoading.value = false;
    lookupFailed.value = false;
  };
  watch([accountId, () => inbox.value?.id], reset, { flush: 'sync' });
  const searchTargets = async query => {
    reset();
    if (!inbox.value?.id || !String(query).trim()) return;
    const currentRequest = requestId;
    const inboxId = inbox.value.id;
    const isTelegram = telegram.value;
    targetLoading.value = true;
    try {
      const { data } = await ContactAPI.search(
        encodeURIComponent(query.trim())
      );
      if (currentRequest !== requestId) return;
      const contacts = data?.payload || [];
      const results = await Promise.all(
        contacts.map(async contact => {
          const response = await ContactAPI.getConversations(
            contact.id,
            inboxId
          );
          return (response.data?.payload || [])
            .filter(conversation =>
              isTelegram
                ? isPrivatePhoneConversation(conversation, inboxId)
                : String(conversation.inbox_id) === String(inboxId)
            )
            .map(conversation => ({
              value: conversation.id,
              label: `${contact.name || contact.phone_number} · #${conversation.id}`,
              contact,
              conversation,
            }));
        })
      );
      if (currentRequest === requestId) targets.value = results.flat();
    } catch {
      if (currentRequest === requestId) lookupFailed.value = true;
    } finally {
      if (currentRequest === requestId) targetLoading.value = false;
    }
  };
  const targetReason = computed(() => {
    if (busy.value || isInitiatingWhatsappCall.value)
      return t('PHONE_WIDGET.NATIVE_BUSY');
    if (telegram.value && inbox.value?.connection_state !== 'connected')
      return t('PHONE_WIDGET.NATIVE_OFFLINE');
    if (targetLoading.value) return t('PHONE_WIDGET.NATIVE_LOADING');
    if (lookupFailed.value) return t('PHONE_WIDGET.NATIVE_LOOKUP_FAILED');
    if (!target.value || !canInitiateWhatsappCall.value)
      return t('PHONE_WIDGET.NATIVE_NO_PEER');
    return '';
  });
  const initiateCall = () => {
    if (targetReason.value) return undefined;
    return initiateWhatsappCall();
  };
  return {
    targetOptions: targets,
    targetId,
    targetLoading,
    targetReason,
    searchTargets,
    initiateCall,
    isInitiatingCall: isInitiatingWhatsappCall,
  };
};
