<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import BaseBubble from 'next/message/bubbles/Base.vue';
import FormattedContent from './FormattedContent.vue';
import HistoryMediaAction from './HistoryMediaAction.vue';
import AttachmentChips from 'next/message/chips/AttachmentChips.vue';
import CaptainToolExecutionGroup from 'dashboard/components-next/message/CaptainToolExecutionGroup.vue';
import TranslationToggle from 'dashboard/components-next/message/TranslationToggle.vue';
import { MESSAGE_TYPES } from '../../constants';
import { useMessageContext } from '../../provider.js';
import { useTranslations } from 'dashboard/composables/useTranslations';
import {
  resolveWhatsappTemplateButtons,
  whatsappTemplateButtonIcon,
} from '../../helpers/whatsappTemplateButtons';

const INTERNAL_FLOW_RESPONSE_KEYS = new Set([
  'flow_token',
  'booking_grant',
  'onelink_flow_kind',
  '_invalid_json',
  'resource_id',
  'service_id',
  'slot_key',
  'starts_at',
  'ends_at',
  'duration_min',
  'booking_date',
  'medelement_cabinet_code',
]);

const BOOKING_SUMMARY_KEYS = new Set([
  'resource_name',
  'service_name',
  'slot_label',
]);

const toSnakeKey = key =>
  String(key || '')
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .toLowerCase();

const humanizeFieldKey = snakeKey => {
  const words = String(snakeKey || '')
    .replace(/_/g, ' ')
    .trim();
  if (!words) return '';
  return words.charAt(0).toUpperCase() + words.slice(1);
};

const {
  content,
  attachments,
  contentAttributes,
  messageType,
  additionalAttributes,
  templateButtons,
} = useMessageContext();
const { t } = useI18n();

const { hasTranslations, translationContent } =
  useTranslations(contentAttributes);

const renderOriginal = ref(false);

const renderContent = computed(() => {
  if (renderOriginal.value) {
    return content.value;
  }

  if (hasTranslations.value) {
    return translationContent.value;
  }

  return content.value;
});

const isTemplate = computed(() => {
  return messageType.value === MESSAGE_TYPES.TEMPLATE;
});

const resolvedTemplateButtons = computed(
  () =>
    templateButtons?.value ??
    resolveWhatsappTemplateButtons({
      additionalAttributes: additionalAttributes?.value,
    })
);

const outgoingFlowCta = computed(() => {
  const attrs = contentAttributes.value || {};
  const waPayload = attrs.whatsappPayload || attrs.whatsapp_payload;
  if (!waPayload || String(waPayload.type || '').toLowerCase() !== 'flow') {
    return '';
  }

  const flow = waPayload.flow || {};
  return String(flow.flowCta || flow.flow_cta || '').trim();
});

const flowBooking = computed(() => {
  const attrs = contentAttributes.value || {};
  const raw = attrs.whatsappFlowBooking || attrs.whatsapp_flow_booking;
  if (!raw || typeof raw !== 'object') return null;

  const status = String(raw.status || '').toLowerCase();
  if (!['booked', 'failed'].includes(status)) return null;

  const serviceName = String(raw.serviceName || raw.service_name || '').trim();
  const resourceName = String(
    raw.resourceName || raw.resource_name || ''
  ).trim();
  const slotLabel = String(raw.slotLabel || raw.slot_label || '').trim();
  const summary = [serviceName, resourceName, slotLabel]
    .filter(Boolean)
    .join(' • ');
  const errorMessage = String(
    raw.errorMessage || raw.error_message || raw.error || ''
  ).trim();

  return {
    status,
    summary,
    errorMessage,
  };
});

const getFlowFieldLabel = snakeKey => {
  switch (snakeKey) {
    case 'client_last_name':
      return t('CONVERSATION.WHATSAPP_FLOWS.FIELDS.CLIENT_LAST_NAME');
    case 'client_first_name':
      return t('CONVERSATION.WHATSAPP_FLOWS.FIELDS.CLIENT_FIRST_NAME');
    case 'client_middle_name':
      return t('CONVERSATION.WHATSAPP_FLOWS.FIELDS.CLIENT_MIDDLE_NAME');
    case 'client_phone':
      return t('CONVERSATION.WHATSAPP_FLOWS.FIELDS.CLIENT_PHONE');
    case 'client_birth_date':
      return t('CONVERSATION.WHATSAPP_FLOWS.FIELDS.CLIENT_BIRTH_DATE');
    case 'client_iin':
      return t('CONVERSATION.WHATSAPP_FLOWS.FIELDS.CLIENT_IIN');
    case 'medelement_cabinet_code':
      return t('CONVERSATION.WHATSAPP_FLOWS.FIELDS.CABINET');
    case 'notes':
      return t('CONVERSATION.WHATSAPP_FLOWS.FIELDS.NOTES');
    case 'service_name':
      return t('CONVERSATION.WHATSAPP_FLOWS.FIELDS.SERVICE');
    case 'resource_name':
      return t('CONVERSATION.WHATSAPP_FLOWS.FIELDS.SPECIALIST');
    case 'slot_label':
      return t('CONVERSATION.WHATSAPP_FLOWS.FIELDS.SLOT');
    default:
      return humanizeFieldKey(snakeKey);
  }
};

const formatFlowFieldValue = rawVal => {
  if (rawVal === null || rawVal === undefined) return '';
  if (Array.isArray(rawVal)) {
    return rawVal
      .map(item => String(item ?? '').trim())
      .filter(Boolean)
      .join(', ');
  }
  if (typeof rawVal === 'object') {
    return JSON.stringify(rawVal);
  }
  return String(rawVal).trim();
};

const flowResponseEntries = computed(() => {
  const attrs = contentAttributes.value || {};
  const raw = attrs.whatsappFlowResponse || attrs.whatsapp_flow_response;
  const data = raw?.response;
  if (!data || typeof data !== 'object' || Array.isArray(data)) return [];
  const invalidJsonFlag = '_invalid_json';
  if (data[invalidJsonFlag] || data.invalidJson) return [];

  const hasBookingCard = Boolean(flowBooking.value);

  return Object.entries(data)
    .map(([rawKey, rawVal]) => {
      const snakeKey = toSnakeKey(rawKey);
      if (INTERNAL_FLOW_RESPONSE_KEYS.has(snakeKey)) return null;
      if (hasBookingCard && BOOKING_SUMMARY_KEYS.has(snakeKey)) return null;

      const value = formatFlowFieldValue(rawVal);
      if (!value) return null;

      return {
        key: snakeKey,
        label: getFlowFieldLabel(snakeKey),
        value,
      };
    })
    .filter(Boolean);
});

const isEmpty = computed(() => {
  return (
    !content.value &&
    !attachments.value?.length &&
    !resolvedTemplateButtons.value.length &&
    !outgoingFlowCta.value &&
    !flowBooking.value &&
    !flowResponseEntries.value.length
  );
});

const telegramForwardedFrom = computed(() => {
  return contentAttributes.value?.telegramForwardedFrom || null;
});

const hasBodyContent = computed(() =>
  Boolean(
    renderContent.value ||
      attachments.value?.length ||
      telegramForwardedFrom.value ||
      flowBooking.value ||
      flowResponseEntries.value.length ||
      (isTemplate.value && contentAttributes.value?.submittedEmail)
  )
);

const telegramForwardedSource = computed(() => {
  const forwarded = telegramForwardedFrom.value;

  if (!forwarded) {
    return '';
  }

  if (forwarded.fromName) {
    return forwarded.fromName;
  }

  if (forwarded.postAuthor) {
    return forwarded.postAuthor;
  }

  if (forwarded.fromId?.type && forwarded.fromId?.id) {
    return `${forwarded.fromId.type} ${forwarded.fromId.id}`;
  }

  if (forwarded.savedFromPeer?.type && forwarded.savedFromPeer?.id) {
    return `${forwarded.savedFromPeer.type} ${forwarded.savedFromPeer.id}`;
  }

  return t('CONVERSATION.TELEGRAM.UNKNOWN_SOURCE');
});

const handleSeeOriginal = () => {
  renderOriginal.value = !renderOriginal.value;
};
</script>

<template>
  <BaseBubble class="px-4 py-3" data-bubble-name="text">
    <div class="gap-3 flex flex-col">
      <div
        v-if="telegramForwardedFrom"
        class="text-xs text-n-slate-11 border-l-2 border-n-alpha-4 pl-2"
      >
        {{
          $t('CONVERSATION.TELEGRAM.FORWARDED_FROM', {
            source: telegramForwardedSource,
          })
        }}
      </div>
      <span v-if="isEmpty" class="text-n-slate-11">
        {{ $t('CONVERSATION.NO_CONTENT') }}
      </span>
      <FormattedContent v-if="renderContent" :content="renderContent" />
      <TranslationToggle
        v-if="hasTranslations"
        class="-mt-3"
        :showing-original="renderOriginal"
        @toggle="handleSeeOriginal"
      />
      <AttachmentChips :attachments="attachments" class="gap-2" />
      <HistoryMediaAction />
      <div
        v-if="flowBooking"
        data-testid="whatsapp-flow-booking"
        class="rounded-lg px-3 py-2 text-xs space-y-1"
        :class="
          flowBooking.status === 'booked'
            ? 'bg-n-teal-9/10 text-n-teal-11'
            : 'bg-n-ruby-9/10 text-n-ruby-11'
        "
      >
        <div class="flex items-center gap-1.5 font-medium">
          <span
            class="size-3.5 shrink-0"
            :class="
              flowBooking.status === 'booked'
                ? 'i-lucide-calendar-check'
                : 'i-lucide-alert-circle'
            "
          />
          <span>
            {{
              flowBooking.status === 'booked'
                ? $t('CONVERSATION.WHATSAPP_FLOWS.BOOKING_CONFIRMED')
                : $t('CONVERSATION.WHATSAPP_FLOWS.BOOKING_FAILED')
            }}
          </span>
        </div>
        <p
          v-if="flowBooking.summary"
          data-testid="whatsapp-flow-booking-summary"
          class="mb-0 break-words opacity-90"
        >
          {{ flowBooking.summary }}
        </p>
        <p
          v-if="flowBooking.status === 'failed' && flowBooking.errorMessage"
          data-testid="whatsapp-flow-booking-error"
          class="mb-0 break-words opacity-90"
        >
          {{ flowBooking.errorMessage }}
        </p>
      </div>
      <div
        v-if="flowResponseEntries.length"
        data-testid="whatsapp-flow-response"
        class="rounded-lg bg-n-alpha-black2 px-3 py-2 text-xs space-y-1 select-text"
      >
        <div
          v-for="entry in flowResponseEntries"
          :key="entry.key"
          data-testid="whatsapp-flow-response-row"
          class="flex items-baseline justify-between gap-3"
        >
          <span class="text-n-slate-11 shrink-0">{{ entry.label }}</span>
          <span class="font-medium text-n-slate-12 text-right break-words">
            {{ entry.value }}
          </span>
        </div>
      </div>
      <template v-if="isTemplate">
        <div
          v-if="contentAttributes.submittedEmail"
          class="px-2 py-1 rounded-lg bg-n-alpha-3"
        >
          {{ contentAttributes.submittedEmail }}
        </div>
      </template>
      <CaptainToolExecutionGroup
        :additional-attributes="additionalAttributes"
      />
    </div>
    <div
      v-if="outgoingFlowCta && !resolvedTemplateButtons.length"
      data-testid="whatsapp-flow-cta"
      class="-mx-4 -mb-3 flex h-9 items-center justify-center gap-1.5 px-3 text-xs font-medium leading-4 text-n-blue-11 select-text"
      :class="hasBodyContent ? 'mt-3 border-t border-n-alpha-3' : '-mt-3'"
    >
      <span class="i-lucide-workflow size-3.5 shrink-0" />
      <span class="truncate leading-4">{{ outgoingFlowCta }}</span>
    </div>
    <div
      v-if="resolvedTemplateButtons.length"
      data-testid="whatsapp-template-buttons"
      class="-mx-4 -mb-3 flex flex-col divide-y divide-n-alpha-3"
      :class="hasBodyContent ? 'mt-3 border-t border-n-alpha-3' : '-mt-3'"
    >
      <div
        v-for="(btn, idx) in resolvedTemplateButtons"
        :key="`${btn.type}-${idx}-${btn.text}`"
        data-testid="whatsapp-template-button"
        class="flex h-9 items-center justify-center gap-1.5 px-3 text-xs font-medium leading-4 text-n-blue-11 select-text"
      >
        <span
          :class="whatsappTemplateButtonIcon(btn.type)"
          class="size-3.5 shrink-0"
        />
        <span class="truncate leading-4">{{ btn.text }}</span>
      </div>
    </div>
  </BaseBubble>
</template>

<style>
p:last-child {
  margin-bottom: 0;
}
</style>
