<script setup>
import { computed } from 'vue';
import { useToggle } from '@vueuse/core';
import { useI18n } from 'vue-i18n';
import { dynamicTime } from 'shared/helpers/timeHelper';
import { usePolicy } from 'dashboard/composables/usePolicy';
import {
  documentLinkIcon,
  formatDocumentLink,
} from 'shared/helpers/documentHelper';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  id: {
    type: Number,
    required: true,
  },
  name: {
    type: String,
    default: '',
  },
  assistant: {
    type: Object,
    default: () => ({}),
  },
  externalLink: {
    type: String,
    required: true,
  },
  displayUrl: {
    type: String,
    default: '',
  },
  sourceMode: {
    type: String,
    default: 'legacy_url',
  },
  syncStatus: {
    type: String,
    default: 'processing',
  },
  refreshMode: {
    type: String,
    default: 'full',
  },
  pagesProcessed: {
    type: Number,
    default: 0,
  },
  pagesTotal: {
    type: Number,
    default: null,
  },
  failedUrlsCount: {
    type: Number,
    default: 0,
  },
  lastError: {
    type: String,
    default: '',
  },
  lastSyncedAt: {
    type: Number,
    default: null,
  },
  createdAt: {
    type: Number,
    required: true,
  },
});

const emit = defineEmits(['action']);
const { checkPermissions } = usePolicy();
const { t } = useI18n();

const [showActionsDropdown, toggleDropdown] = useToggle();

const menuItems = computed(() => {
  const allOptions = [
    {
      label: t('CAPTAIN.DOCUMENTS.OPTIONS.VIEW_RELATED_RESPONSES'),
      value: 'viewRelatedQuestions',
      action: 'viewRelatedQuestions',
      icon: 'i-ph-tree-view-duotone',
    },
  ];

  if (checkPermissions(['administrator'])) {
    allOptions.push({
      label: t('CAPTAIN.DOCUMENTS.OPTIONS.RESYNC_DOCUMENT'),
      value: 'resync',
      action: 'resync',
      icon: 'i-lucide-refresh-cw',
    });
    if (!['pdf_upload', 'file_upload'].includes(props.sourceMode)) {
      allOptions.push({
        label: t('CAPTAIN.DOCUMENTS.OPTIONS.REFRESH_CHANGED_ONLY'),
        value: 'refreshChangedOnly',
        action: 'refreshChangedOnly',
        icon: 'i-lucide-scan-search',
      });
    }
    if (props.failedUrlsCount > 0) {
      allOptions.push({
        label: t('CAPTAIN.DOCUMENTS.OPTIONS.RETRY_FAILED'),
        value: 'retryFailed',
        action: 'retryFailed',
        icon: 'i-lucide-rotate-cw',
      });
    }
    allOptions.push({
      label: t('CAPTAIN.DOCUMENTS.OPTIONS.DELETE_DOCUMENT'),
      value: 'delete',
      action: 'delete',
      icon: 'i-lucide-trash',
    });
  }

  return allOptions;
});

const createdAt = computed(() => dynamicTime(props.createdAt));
const syncedAt = computed(() =>
  props.lastSyncedAt ? dynamicTime(props.lastSyncedAt) : ''
);

const rawLinkSource = computed(() =>
  ['pdf_upload', 'file_upload'].includes(props.sourceMode)
    ? props.externalLink
    : props.displayUrl || props.externalLink
);
const displayLink = computed(() => formatDocumentLink(rawLinkSource.value));
const linkIcon = computed(() => documentLinkIcon(rawLinkSource.value));

const statusConfig = computed(() => {
  const map = {
    queued: {
      label: t('CAPTAIN.DOCUMENTS.STATUS.QUEUED'),
      className: 'bg-n-amber-9/10 text-n-amber-11',
    },
    processing: {
      label: t('CAPTAIN.DOCUMENTS.STATUS.PROCESSING'),
      className: 'bg-n-brand/10 text-n-brand',
    },
    completed: {
      label: t('CAPTAIN.DOCUMENTS.STATUS.COMPLETED'),
      className: 'bg-n-teal-9/10 text-n-teal-11',
    },
    failed: {
      label: t('CAPTAIN.DOCUMENTS.STATUS.FAILED'),
      className: 'bg-n-ruby-9/10 text-n-ruby-11',
    },
  };

  return map[props.syncStatus] || map.processing;
});

const sourceModeLabel = computed(() =>
  t(`CAPTAIN.DOCUMENTS.SOURCE_MODE.${props.sourceMode.toUpperCase()}`)
);

const progressLabel = computed(() => {
  if (!props.pagesTotal) return '';

  return `${props.pagesProcessed}/${props.pagesTotal}`;
});

const handleAction = ({ action, value }) => {
  toggleDropdown(false);
  emit('action', { action, value, id: props.id });
};
</script>

<template>
  <CardLayout>
    <div class="flex w-full items-start justify-between gap-4">
      <div class="min-w-0">
        <div class="flex flex-wrap items-center gap-2">
          <span class="line-clamp-1 text-base text-n-slate-12">
            {{ name }}
          </span>
          <span
            class="rounded-full px-2 py-1 text-xs font-medium"
            :class="statusConfig.className"
          >
            {{ statusConfig.label }}
          </span>
          <span
            class="rounded-full bg-n-alpha-2 px-2 py-1 text-xs font-medium text-n-slate-11"
          >
            {{ sourceModeLabel }}
          </span>
        </div>
        <div class="mt-2 flex flex-wrap items-center gap-3 text-sm text-n-slate-11">
          <span class="flex items-center gap-1 truncate">
            <i class="i-woot-captain" />
            {{ assistant?.name || '' }}
          </span>
          <span class="flex min-w-0 flex-1 items-center gap-1 truncate">
            <i :class="linkIcon" class="shrink-0" />
            <span class="truncate">{{ displayLink }}</span>
          </span>
        </div>
      </div>

      <div class="flex items-center gap-2">
        <div
          v-on-clickaway="() => toggleDropdown(false)"
          class="relative flex items-center group"
        >
          <Button
            icon="i-lucide-ellipsis-vertical"
            color="slate"
            size="xs"
            class="rounded-md group-hover:bg-n-alpha-2"
            @click="toggleDropdown()"
          />
          <DropdownMenu
            v-if="showActionsDropdown"
            :menu-items="menuItems"
            class="top-full mt-1 ltr:right-0 rtl:left-0 xl:ltr:right-0 xl:rtl:left-0"
            @action="handleAction($event)"
          />
        </div>
      </div>
    </div>

    <div class="mt-4 flex flex-wrap items-center gap-3 text-sm text-n-slate-11">
      <span class="rounded-full bg-n-alpha-2 px-2 py-1">
        {{ t('CAPTAIN.DOCUMENTS.META.CREATED_AT', { time: createdAt }) }}
      </span>
      <span v-if="progressLabel" class="rounded-full bg-n-alpha-2 px-2 py-1">
        {{ t('CAPTAIN.DOCUMENTS.META.PROGRESS', { value: progressLabel }) }}
      </span>
      <span
        v-if="failedUrlsCount"
        class="rounded-full bg-n-ruby-9/10 px-2 py-1 text-n-ruby-11"
      >
        {{ t('CAPTAIN.DOCUMENTS.META.FAILED_URLS', { count: failedUrlsCount }) }}
      </span>
      <span
        v-if="syncedAt"
        class="rounded-full bg-n-alpha-2 px-2 py-1"
      >
        {{ t('CAPTAIN.DOCUMENTS.META.SYNCED_AT', { time: syncedAt }) }}
      </span>
    </div>

    <p
      v-if="lastError"
      class="mt-3 mb-0 rounded-lg bg-n-ruby-9/10 px-3 py-2 text-sm text-n-ruby-11"
    >
      {{ lastError }}
    </p>
  </CardLayout>
</template>
