<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { getInboxIconByType } from 'dashboard/helper/inbox';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';

const props = defineProps({
  selectedTouch: {
    type: Object,
    default: null,
  },
});

const { locale, t } = useI18n();
const dialogRef = ref(null);

const open = () => dialogRef.value?.open();
const close = () => dialogRef.value?.close();

const fallbackValue = computed(() =>
  t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.UNAVAILABLE')
);

const formatDate = value => {
  if (!value) return fallbackValue.value;

  return new Intl.DateTimeFormat(locale.value || 'en', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(value));
};

const statusText = computed(() => {
  switch (props.selectedTouch?.status) {
    case 'pending':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.PENDING');
    case 'processing':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.PROCESSING');
    case 'completed':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.COMPLETED');
    case 'cancelled':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.CANCELLED');
    case 'failed':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.FAILED');
    case 'draft':
    default:
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.DRAFT');
  }
});

const routeText = computed(() => {
  return props.selectedTouch?.target?.inbox_id
    ? t('OUTBOUND_WORKSPACE.TOUCHES.ROUTE.READY')
    : t('OUTBOUND_WORKSPACE.TOUCHES.ROUTE.PENDING');
});

const previewText = computed(() => {
  if (props.selectedTouch?.body) return props.selectedTouch.body;
  if (props.selectedTouch?.instructions) {
    return t('OUTBOUND_WORKSPACE.TOUCHES.AGENT_PREVIEW');
  }

  return t('OUTBOUND_WORKSPACE.TOUCHES.NO_CONTENT');
});

const inbox = computed(() => props.selectedTouch?.target?.inbox || null);
const inboxName = computed(() => inbox.value?.name || fallbackValue.value);
const inboxIcon = computed(() => {
  if (!inbox.value) return '';

  return getInboxIconByType(inbox.value.channel_type, inbox.value.medium);
});

const recipientValue = computed(() => {
  const contact = props.selectedTouch?.target?.contact;

  if (!contact) return fallbackValue.value;

  if (contact.name) return contact.name;
  if (contact.phone_number) return contact.phone_number;
  if (contact.email) return contact.email;
  if (contact.id) return `#${contact.id}`;

  return fallbackValue.value;
});

const stats = computed(() => [
  {
    key: 'status',
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.STATS.STATUS'),
    value: statusText.value,
  },
  {
    key: 'attempts',
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.STATS.ATTEMPTS'),
    value: String(props.selectedTouch?.attempts_count || 0),
  },
  {
    key: 'channel',
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.STATS.CHANNEL'),
    value: inboxName.value,
  },
  {
    key: 'recipient',
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.STATS.RECIPIENT'),
    value: recipientValue.value,
  },
  {
    key: 'scheduledAt',
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.STATS.SCHEDULED_AT'),
    value: formatDate(props.selectedTouch?.scheduled_at),
  },
  {
    key: 'route',
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.STATS.ROUTE'),
    value: routeText.value,
  },
]);

const timeline = computed(() =>
  [
    {
      key: 'created',
      label: t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.TIMELINE.CREATED'),
      value: props.selectedTouch?.created_at,
    },
    {
      key: 'planned',
      label: t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.TIMELINE.PLANNED'),
      value: props.selectedTouch?.scheduled_at,
    },
    {
      key: 'processing',
      label: t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.TIMELINE.PROCESSING'),
      value: props.selectedTouch?.processing_started_at,
    },
    {
      key: 'completed',
      label: t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.TIMELINE.COMPLETED'),
      value: props.selectedTouch?.completed_at,
    },
    {
      key: 'cancelled',
      label: t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.TIMELINE.CANCELLED'),
      value: props.selectedTouch?.cancelled_at,
    },
  ].filter(item => item.value)
);

defineExpose({ open, close });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="xl"
    :title="$t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.TITLE')"
    :description="$t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.DESCRIPTION')"
    :show-confirm-button="false"
  >
    <div class="grid gap-5">
      <div class="grid gap-1">
        <div class="text-sm font-medium text-n-slate-12">
          {{ previewText }}
        </div>
        <div class="flex items-center gap-2 text-xs text-n-slate-11">
          <Icon
            v-if="inboxIcon"
            :icon="inboxIcon"
            class="size-3 shrink-0 text-n-slate-12"
          />
          <span>{{ inboxName }}</span>
        </div>
      </div>

      <div class="grid gap-3 md:grid-cols-2">
        <div
          v-for="stat in stats"
          :key="stat.key"
          class="rounded-2xl bg-n-solid-2 px-4 py-3 outline outline-1 outline-n-container"
        >
          <div
            class="mb-1 text-xs font-medium uppercase tracking-wide text-n-slate-10"
          >
            {{ stat.label }}
          </div>
          <div class="text-sm font-medium text-n-slate-12">
            {{ stat.value || fallbackValue }}
          </div>
        </div>
      </div>

      <div class="grid gap-3">
        <div class="text-sm font-semibold text-n-slate-12">
          {{ $t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.SECTIONS.TIMELINE') }}
        </div>
        <div class="grid gap-2">
          <div
            v-for="item in timeline"
            :key="item.key"
            class="flex items-center justify-between gap-3 rounded-xl bg-n-alpha-1 px-4 py-3"
          >
            <span class="text-sm text-n-slate-11">
              {{ item.label }}
            </span>
            <span class="text-sm font-medium text-n-slate-12">
              {{ formatDate(item.value) }}
            </span>
          </div>
        </div>
      </div>

      <div
        v-if="selectedTouch?.last_error"
        class="rounded-2xl bg-n-ruby-3 px-4 py-3 text-sm text-n-ruby-11"
      >
        <div class="mb-1 text-xs font-medium uppercase tracking-wide">
          {{ $t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.ERROR') }}
        </div>
        <div>{{ selectedTouch.last_error }}</div>
      </div>
    </div>

    <template #footer>
      <div class="flex w-full justify-end">
        <Button
          size="sm"
          variant="faded"
          color="slate"
          :label="$t('OUTBOUND_WORKSPACE.TOUCHES.ANALYTICS.CLOSE')"
          @click="close"
        />
      </div>
    </template>
  </Dialog>
</template>
