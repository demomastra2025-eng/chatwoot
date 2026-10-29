<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'dashboard/composables/store';

import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

const props = defineProps({
  show: {
    type: Boolean,
    default: false,
  },
  inboxId: {
    type: Number,
    default: undefined,
  },
});

const emit = defineEmits(['onSend', 'cancel', 'update:show']);

const { t } = useI18n();
const store = useStore();

const MAX_CTA_LENGTH = 20;
const MAX_BODY_LENGTH = 1024;
const EMOJI_PATTERN = /\p{Extended_Pictographic}/u;

const submitError = ref('');

const form = reactive({
  flowId: '',
  body: '',
  flowCta: '',
  flowAction: 'data_exchange',
  navigateScreen: '',
});

const localShow = computed({
  get: () => props.show,
  set: value => emit('update:show', value),
});

const flowsConfig = computed(
  () => store.getters['inboxes/getWhatsAppFlowsConfig']?.(props.inboxId) || {}
);

const publishedFlows = computed(() => {
  const allFlows =
    store.getters['inboxes/getWhatsAppFlows']?.(props.inboxId) || [];
  if (!Array.isArray(allFlows)) return [];

  return allFlows.filter(
    flow => flow?.id && String(flow?.status || '').toUpperCase() === 'PUBLISHED'
  );
});

const flowOptions = computed(() =>
  publishedFlows.value.map(flow => ({
    value: String(flow.id),
    label: `${flow.name} (${flow.id})`,
  }))
);

const flowActionOptions = computed(() => [
  {
    value: 'data_exchange',
    label: t('CONVERSATION.WHATSAPP_FLOWS.MODAL.ACTION_DATA_EXCHANGE'),
  },
  {
    value: 'navigate',
    label: t('CONVERSATION.WHATSAPP_FLOWS.MODAL.ACTION_NAVIGATE'),
  },
]);

const preferredFlowId = computed(() => {
  const bookingId = String(flowsConfig.value.booking_flow_id || '');
  if (
    bookingId &&
    publishedFlows.value.some(flow => String(flow.id) === bookingId)
  ) {
    return bookingId;
  }
  return String(publishedFlows.value[0]?.id || '');
});

const resetForm = () => {
  form.flowId = preferredFlowId.value;
  form.body = t('CONVERSATION.WHATSAPP_FLOWS.MODAL.DEFAULT_BODY');
  form.flowCta = t('CONVERSATION.WHATSAPP_FLOWS.MODAL.DEFAULT_CTA');
  form.flowAction = 'data_exchange';
  form.navigateScreen = '';
  submitError.value = '';
};

watch(
  () => props.show,
  isOpen => {
    if (isOpen) {
      resetForm();
    }
  },
  { immediate: true }
);

const handleClose = () => {
  submitError.value = '';
  emit('cancel');
};

const validateForm = () => {
  if (!String(form.flowId || '').trim()) {
    return t('CONVERSATION.WHATSAPP_FLOWS.MODAL.ERRORS.FLOW_REQUIRED');
  }
  if (!form.body.trim()) {
    return t('CONVERSATION.WHATSAPP_FLOWS.MODAL.ERRORS.BODY_REQUIRED');
  }
  if (form.body.trim().length > MAX_BODY_LENGTH) {
    return t('CONVERSATION.WHATSAPP_FLOWS.MODAL.ERRORS.BODY_MAX_LENGTH');
  }
  if (!form.flowCta.trim()) {
    return t('CONVERSATION.WHATSAPP_FLOWS.MODAL.ERRORS.CTA_REQUIRED');
  }
  if (form.flowCta.trim().length > MAX_CTA_LENGTH) {
    return t('CONVERSATION.WHATSAPP_FLOWS.MODAL.ERRORS.CTA_MAX_LENGTH');
  }
  if (EMOJI_PATTERN.test(form.flowCta)) {
    return t('CONVERSATION.WHATSAPP_FLOWS.MODAL.ERRORS.CTA_NO_EMOJI');
  }
  if (form.flowAction === 'navigate' && !form.navigateScreen.trim()) {
    return t('CONVERSATION.WHATSAPP_FLOWS.MODAL.ERRORS.SCREEN_REQUIRED');
  }
  return '';
};

const handleSubmit = () => {
  const error = validateForm();
  if (error) {
    submitError.value = error;
    return;
  }

  submitError.value = '';
  const trimmedBody = form.body.trim();
  const trimmedCta = form.flowCta.trim();
  const flowPayload = {
    flow_id: String(form.flowId).trim(),
    body: trimmedBody,
    flow_cta: trimmedCta,
    flow_action: form.flowAction,
  };

  if (form.flowAction === 'navigate') {
    flowPayload.flow_action_payload = {
      screen: form.navigateScreen.trim(),
    };
  }

  emit('onSend', {
    message: trimmedBody,
    private: false,
    contentAttributes: {
      whatsapp_payload: {
        type: 'flow',
        flow: flowPayload,
      },
    },
  });
};
</script>

<template>
  <woot-modal v-model:show="localShow" @close="handleClose">
    <woot-modal-header
      :header-title="t('CONVERSATION.WHATSAPP_FLOWS.MODAL.TITLE')"
      :header-content="t('CONVERSATION.WHATSAPP_FLOWS.MODAL.SUBTITLE')"
    />

    <div class="space-y-4 px-8 pb-6 pt-2">
      <div
        v-if="!publishedFlows.length"
        class="rounded-xl bg-n-amber-9/10 p-4 text-sm text-n-amber-11"
        data-testid="no-published-flows-notice"
      >
        {{ t('CONVERSATION.WHATSAPP_FLOWS.MODAL.EMPTY_PUBLISHED') }}
      </div>

      <template v-else>
        <div class="flex flex-col gap-1">
          <label class="mb-0.5 text-sm font-medium text-n-slate-12">
            {{ t('CONVERSATION.WHATSAPP_FLOWS.MODAL.FLOW_LABEL') }}
          </label>
          <ComboBox
            v-model="form.flowId"
            :options="flowOptions"
            :placeholder="
              t('CONVERSATION.WHATSAPP_FLOWS.MODAL.FLOW_PLACEHOLDER')
            "
            input-like
          />
        </div>

        <TextArea
          v-model="form.body"
          :label="t('CONVERSATION.WHATSAPP_FLOWS.MODAL.BODY_LABEL')"
          :placeholder="t('CONVERSATION.WHATSAPP_FLOWS.MODAL.BODY_PLACEHOLDER')"
          :max-length="MAX_BODY_LENGTH"
          show-character-count
          auto-height
        />

        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
          <Input
            v-model="form.flowCta"
            :label="t('CONVERSATION.WHATSAPP_FLOWS.MODAL.CTA_LABEL')"
            :placeholder="
              t('CONVERSATION.WHATSAPP_FLOWS.MODAL.CTA_PLACEHOLDER')
            "
          />

          <div class="flex flex-col gap-1">
            <label class="mb-0.5 text-sm font-medium text-n-slate-12">
              {{ t('CONVERSATION.WHATSAPP_FLOWS.MODAL.ACTION_LABEL') }}
            </label>
            <ComboBox
              v-model="form.flowAction"
              :options="flowActionOptions"
              input-like
            />
          </div>
        </div>

        <Input
          v-if="form.flowAction === 'navigate'"
          v-model="form.navigateScreen"
          :label="t('CONVERSATION.WHATSAPP_FLOWS.MODAL.SCREEN_LABEL')"
          :placeholder="
            t('CONVERSATION.WHATSAPP_FLOWS.MODAL.SCREEN_PLACEHOLDER')
          "
        />

        <div
          v-if="submitError"
          class="rounded-xl bg-n-ruby-9/10 p-3 text-sm text-n-ruby-11"
          data-testid="whatsapp-flow-modal-error"
        >
          {{ submitError }}
        </div>
      </template>

      <div class="flex items-center justify-end gap-3 pt-2">
        <Button
          variant="faded"
          color="slate"
          :label="t('CONVERSATION.WHATSAPP_FLOWS.MODAL.CANCEL')"
          @click="handleClose"
        />
        <Button
          v-if="publishedFlows.length"
          icon="i-lucide-send"
          data-testid="send-whatsapp-flow-submit"
          :label="t('CONVERSATION.WHATSAPP_FLOWS.MODAL.SEND')"
          @click="handleSubmit"
        />
      </div>
    </div>
  </woot-modal>
</template>
