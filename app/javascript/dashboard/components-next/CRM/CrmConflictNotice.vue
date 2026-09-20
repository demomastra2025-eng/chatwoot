<script setup>
import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';

defineProps({
  isReloading: {
    type: Boolean,
    default: false,
  },
  isRetrying: {
    type: Boolean,
    default: false,
  },
  reloadFailed: {
    type: Boolean,
    default: false,
  },
  retryReady: {
    type: Boolean,
    default: false,
  },
});

defineEmits(['reload', 'retry']);
</script>

<template>
  <section
    role="alert"
    data-test="crm-conflict-notice"
    class="grid gap-3 rounded-xl border border-n-amber-6 bg-n-amber-2 p-3 text-sm text-n-slate-12"
  >
    <div class="flex items-start gap-2">
      <Icon
        icon="i-lucide-triangle-alert"
        class="mt-0.5 size-4 shrink-0 text-n-amber-11"
      />
      <div class="grid gap-1">
        <strong>{{ $t('CRM.CONFLICT.TITLE') }}</strong>
        <p class="mb-0 text-n-slate-11">
          {{ $t('CRM.CONFLICT.DESCRIPTION') }}
        </p>
        <p class="mb-0 font-medium text-n-slate-12">
          {{ $t('CRM.CONFLICT.DRAFT_PRESERVED') }}
        </p>
        <p v-if="reloadFailed" class="mb-0 text-n-ruby-11">
          {{ $t('CRM.CONFLICT.RELOAD_FAILED') }}
        </p>
      </div>
    </div>

    <div class="flex flex-wrap justify-end gap-2">
      <Button
        size="sm"
        color="slate"
        variant="faded"
        icon="i-lucide-refresh-cw"
        :is-loading="isReloading"
        :disabled="isRetrying"
        :label="$t('CRM.CONFLICT.RELOAD_ACTION')"
        @click="$emit('reload')"
      />
      <Button
        size="sm"
        icon="i-lucide-save"
        :is-loading="isRetrying"
        :disabled="!retryReady || isReloading"
        :label="$t('CRM.CONFLICT.RETRY_ACTION')"
        @click="$emit('retry')"
      />
    </div>
  </section>
</template>
