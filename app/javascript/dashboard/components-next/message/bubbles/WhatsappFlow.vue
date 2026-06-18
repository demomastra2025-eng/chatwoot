<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import BaseBubble from 'next/message/bubbles/Base.vue';
import { useMessageContext } from '../provider.js';

const { content, contentAttributes } = useMessageContext();
const { t } = useI18n();

const attrs = computed(() => contentAttributes.value || {});
const data = computed(() => attrs.value.data || {});

const attributeValue = (...keys) => {
  const key = keys.find(
    candidate =>
      attrs.value[candidate] !== undefined && attrs.value[candidate] !== null
  );
  return key ? attrs.value[key] : undefined;
};

const dataValue = (...keys) => {
  const key = keys.find(
    candidate =>
      data.value[candidate] !== undefined && data.value[candidate] !== null
  );
  return key ? data.value[key] : undefined;
};

const isFlowReply = computed(
  () =>
    attributeValue('interactiveReplyType', 'interactive_reply_type') ===
    'nfm_reply'
);

const title = computed(() => {
  if (isFlowReply.value) {
    return (
      attributeValue('flowReplyName', 'flow_reply_name') ||
      t('WHATSAPP_FLOWS.BUBBLE.REPLY_TITLE')
    );
  }

  return (
    dataValue('displayTitle', 'display_title') ||
    dataValue('flowName', 'flow_name') ||
    dataValue('flowId', 'flow_id') ||
    t('WHATSAPP_FLOWS.BUBBLE.OUTGOING_TITLE')
  );
});

const ctaLabel = computed(() => dataValue('flowCta', 'flow_cta'));
const providerFlowId = computed(() => dataValue('flowId', 'flow_id'));
const response = computed(
  () => attributeValue('flowResponse', 'flow_response') || {}
);

const responseEntries = computed(() => {
  if (!response.value || typeof response.value !== 'object') return [];

  return Object.entries(response.value).filter(([key]) => key !== 'flow_token');
});
</script>

<template>
  <BaseBubble class="px-4 py-3" data-bubble-name="whatsapp-flow">
    <div class="flex flex-col gap-3">
      <div class="flex items-start gap-3">
        <span
          class="i-lucide-workflow mt-0.5 size-5 flex-shrink-0 text-n-brand"
        />
        <div class="min-w-0 flex-1">
          <p
            class="text-xs font-medium uppercase tracking-wide text-n-slate-11"
          >
            {{
              isFlowReply
                ? $t('WHATSAPP_FLOWS.BUBBLE.REPLY_BADGE')
                : $t('WHATSAPP_FLOWS.BUBBLE.OUTGOING_BADGE')
            }}
          </p>
          <p class="truncate text-sm font-semibold text-n-slate-12">
            {{ title }}
          </p>
          <p v-if="providerFlowId" class="truncate text-xs text-n-slate-11">
            {{ providerFlowId }}
          </p>
        </div>
      </div>

      <p v-if="content" class="whitespace-pre-wrap text-sm text-n-slate-12">
        {{ content }}
      </p>

      <div
        v-if="ctaLabel && !isFlowReply"
        class="inline-flex w-fit items-center gap-1 rounded-lg border border-n-weak bg-n-alpha-2 px-3 py-1.5 text-sm font-medium text-n-brand"
      >
        <span>{{ ctaLabel }}</span>
        <span class="i-lucide-arrow-up-right size-3" />
      </div>

      <div
        v-if="responseEntries.length"
        class="rounded-lg bg-n-alpha-2 p-3 text-sm"
      >
        <p class="mb-2 text-xs font-medium text-n-slate-11">
          {{ $t('WHATSAPP_FLOWS.BUBBLE.RESPONSE') }}
        </p>
        <dl class="grid gap-2">
          <div
            v-for="[key, value] in responseEntries"
            :key="key"
            class="grid gap-1 sm:grid-cols-[8rem_minmax(0,1fr)]"
          >
            <dt class="truncate text-xs text-n-slate-11">{{ key }}</dt>
            <dd class="break-words text-xs text-n-slate-12">
              {{ value }}
            </dd>
          </div>
        </dl>
      </div>
    </div>
  </BaseBubble>
</template>
