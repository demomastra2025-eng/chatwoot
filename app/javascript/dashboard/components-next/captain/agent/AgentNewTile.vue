<script setup>
import { useI18n } from 'vue-i18n';

import Icon from 'dashboard/components-next/icon/Icon.vue';

const emit = defineEmits(['click']);

const { t } = useI18n();
</script>

<template>
  <button
    type="button"
    class="flex min-h-36 w-full flex-col items-center justify-center gap-2 rounded-xl px-5 py-4 text-center outline-dashed outline-1 -outline-offset-1 outline-n-weak transition-colors hover:bg-n-alpha-1 hover:outline-n-brand focus-visible:outline-n-brand"
    data-testid="agent-new-tile"
    @click="emit('click')"
  >
    <Icon icon="i-lucide-plus" class="size-6 text-n-brand" />
    <span class="text-heading-3 text-n-slate-12">
      {{ t('CAPTAIN.GALLERY.NEW_TILE') }}
    </span>
  </button>
</template>
