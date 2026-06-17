<script setup>
import { computed, ref, useAttrs } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { useAlert } from 'dashboard/composables';
import { frontendURL, conversationUrl } from 'dashboard/helper/URLHelper';
import { useCallsStore } from 'dashboard/stores/calls';
import WebphoneClient from 'dashboard/api/channel/voice/webphoneClient';

import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const props = defineProps({
  phone: { type: String, default: '' },
  contactId: { type: [String, Number], required: true },
  label: { type: String, default: '' },
  icon: { type: [String, Object, Function], default: '' },
  size: { type: String, default: 'sm' },
  tooltipLabel: { type: String, default: '' },
  inboxId: { type: [String, Number], default: null },
  disabled: { type: Boolean, default: false },
});

defineOptions({ inheritAttrs: false });
const attrs = useAttrs();
const route = useRoute();
const router = useRouter();
const store = useStore();

const { t } = useI18n();

const dialogRef = ref(null);
const isPreparingCall = ref(false);

const inboxesList = useMapGetter('inboxes/getInboxes');
const contactsUiFlags = useMapGetter('contacts/getUIFlags');

const voiceInboxes = computed(() =>
  (inboxesList.value || []).filter(
    inbox => inbox.channel_type === INBOX_TYPES.VOICE
  )
);
const candidateVoiceInboxes = computed(() => {
  if (!props.inboxId) return voiceInboxes.value;

  const selectedInbox = voiceInboxes.value.find(
    inbox => String(inbox.id) === String(props.inboxId)
  );

  return [
    selectedInbox || {
      id: props.inboxId,
      channel_type: INBOX_TYPES.VOICE,
    },
  ];
});
const hasVoiceInboxes = computed(() => candidateVoiceInboxes.value.length > 0);

// Unified behavior: hide when no phone
const shouldRender = computed(() => hasVoiceInboxes.value && !!props.phone);

const isInitiatingCall = computed(() => {
  return contactsUiFlags.value?.isInitiatingCall || false;
});
const isCallButtonBusy = computed(
  () => props.disabled || isPreparingCall.value || isInitiatingCall.value
);

const navigateToConversation = conversationId => {
  const accountId = route.params.accountId;
  if (conversationId && accountId) {
    if (
      String(route.params?.conversation_id || route.params?.conversationId) ===
      String(conversationId)
    ) {
      return;
    }

    const path = frontendURL(
      conversationUrl({
        accountId,
        id: conversationId,
      })
    );
    router.push({ path });
  }
};

const isFonosterInbox = inbox => inbox?.provider === 'fonoster';

const prepareFonosterWebphone = async inbox => {
  if (!isFonosterInbox(inbox)) return true;

  const microphonePrewarm = WebphoneClient.prewarmMicrophone('fonoster').catch(
    error => ({
      provider: 'fonoster',
      prewarmed: false,
      reason: error?.name || 'microphone_unavailable',
    })
  );
  try {
    const session = await WebphoneClient.initializeDevice(inbox.id);
    const microphone = await microphonePrewarm;
    const browserJoinSupported =
      session?.browserJoinSupported ?? session?.browser_join_supported;
    if (browserJoinSupported === false) {
      WebphoneClient.stopMicrophonePrewarm('fonoster');
      return true;
    }

    const ready =
      session?.provider === 'fonoster' &&
      session?.callingSupported !== false &&
      session?.registered !== false &&
      microphone?.prewarmed !== false;
    if (!ready) WebphoneClient.stopMicrophonePrewarm('fonoster');
    return ready;
  } catch (error) {
    WebphoneClient.stopMicrophonePrewarm('fonoster');
    // eslint-disable-next-line no-console
    console.warn('Failed to prepare Fonoster webphone:', error);
    return false;
  }
};

const startCall = async inbox => {
  if (isCallButtonBusy.value) return;

  isPreparingCall.value = true;
  try {
    const webphoneReady = await prepareFonosterWebphone(inbox);
    if (!webphoneReady) {
      useAlert(t('CONVERSATION.VOICE_WIDGET.BROWSER_CALLING_UNAVAILABLE'));
      return;
    }

    const response = await store.dispatch('contacts/initiateCall', {
      contactId: props.contactId,
      inboxId: inbox.id,
    });
    const { call_sid: callSid, conversation_id: conversationId } = response;
    const browserJoinSupported =
      response?.browser_join_supported ?? response?.browserJoinSupported;

    // Add call to store immediately so widget shows
    const callsStore = useCallsStore();
    callsStore.addCall({
      callSid,
      status: 'created',
      callEvent: 'created',
      conversationId,
      inboxId: inbox.id,
      provider: inbox.provider,
      callDirection: 'outbound',
      browserJoinSupported,
    });

    useAlert(t('CONTACT_PANEL.CALL_INITIATED'));
    navigateToConversation(response?.conversation_id);
  } catch (error) {
    if (isFonosterInbox(inbox)) {
      WebphoneClient.stopMicrophonePrewarm('fonoster');
    }
    const apiError = error?.message;
    useAlert(apiError || t('CONTACT_PANEL.CALL_FAILED'));
  } finally {
    isPreparingCall.value = false;
  }
};

const onClick = async () => {
  if (isCallButtonBusy.value) return;

  if (candidateVoiceInboxes.value.length > 1) {
    dialogRef.value?.open();
    return;
  }
  const [inbox] = candidateVoiceInboxes.value;
  await startCall(inbox);
};

const onPickInbox = async inbox => {
  dialogRef.value?.close();
  await startCall(inbox);
};
</script>

<template>
  <span class="contents">
    <Button
      v-if="shouldRender"
      v-tooltip.top-end="tooltipLabel || null"
      v-bind="attrs"
      :disabled="isCallButtonBusy"
      :is-loading="isCallButtonBusy"
      :label="label"
      :icon="icon"
      :size="size"
      @click="onClick"
    />

    <Dialog
      v-if="shouldRender && candidateVoiceInboxes.length > 1"
      ref="dialogRef"
      :title="$t('CONTACT_PANEL.VOICE_INBOX_PICKER.TITLE')"
      show-cancel-button
      :show-confirm-button="false"
      width="md"
    >
      <div class="flex flex-col gap-2">
        <button
          v-for="inbox in candidateVoiceInboxes"
          :key="inbox.id"
          type="button"
          class="flex items-center justify-between w-full px-4 py-2 text-left rounded-lg hover:bg-n-alpha-2"
          @click="onPickInbox(inbox)"
        >
          <div class="flex items-center gap-2">
            <span class="i-ri-phone-fill text-n-slate-10" />
            <div class="flex flex-col">
              <span class="text-sm text-n-slate-12">{{ inbox.name }}</span>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <span
              class="rounded-md bg-n-alpha-2 px-2 py-1 text-[11px] font-medium uppercase tracking-wide text-n-slate-11"
            >
              {{ inbox.provider }}
            </span>
            <span v-if="inbox.phone_number" class="text-xs text-n-slate-10">
              {{ inbox.phone_number }}
            </span>
          </div>
        </button>
      </div>
    </Dialog>
  </span>
</template>
