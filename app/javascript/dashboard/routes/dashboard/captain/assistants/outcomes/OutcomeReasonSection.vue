<script setup>
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import { isSystemReason } from './reasonOrder';

// One card with an editable outcome reason list. The handoff and the
// completion lists are both rendered by this component, so they cannot drift
// apart in markup, spacing or behaviour of the system ("Other") reason.
const props = defineProps({
  type: { type: String, required: true },
  icon: { type: String, required: true },
  title: { type: String, required: true },
  description: { type: String, required: true },
  // Optional subheading above the list. Leave it empty when the card title
  // already names the list.
  reasonsTitle: { type: String, default: '' },
  showReasons: { type: Boolean, default: true },
  maxReasons: { type: Number, default: 20 },
});

const emit = defineEmits(['add', 'remove']);

// Reasons are already ordered by the owner of the list (see reasonOrder.js).
const reasons = defineModel('reasons', { type: Array, default: () => [] });

const { t } = useI18n();
</script>

<template>
  <section
    :data-testid="`outcome-section-${type}`"
    class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
  >
    <div class="flex items-start justify-between gap-4">
      <div class="flex min-w-0 gap-3">
        <span :class="icon" class="mt-0.5 size-5 shrink-0 text-n-slate-11" />
        <div>
          <h4 class="text-sm font-medium text-n-slate-12">
            {{ title }}
          </h4>
          <p class="mt-1 text-sm text-n-slate-11">
            {{ description }}
          </p>
        </div>
      </div>
      <slot name="action" />
    </div>

    <div v-if="showReasons" class="mt-5 flex flex-col gap-3">
      <div
        data-testid="outcome-reasons-header"
        class="flex items-center justify-end gap-3"
      >
        <h5
          v-if="reasonsTitle"
          class="mr-auto min-w-0 text-sm font-medium text-n-slate-12"
        >
          {{ reasonsTitle }}
        </h5>
        <Button
          sm
          slate
          faded
          icon="i-lucide-plus"
          :label="t('CAPTAIN.ASSISTANTS.OUTCOMES.ADD')"
          :disabled="reasons.length >= props.maxReasons"
          :data-testid="`outcome-add-${type}`"
          @click="emit('add')"
        />
      </div>

      <div
        v-for="reason in reasons"
        :key="reason.id"
        data-testid="outcome-reason-row"
        :data-reason-id="reason.id"
        class="flex items-center gap-2 rounded-lg border border-n-weak bg-n-alpha-1 px-3 py-2"
      >
        <span class="size-1.5 shrink-0 rounded-full bg-n-slate-8" />
        <input
          v-model="reason.label"
          :aria-label="reasonsTitle || title"
          maxlength="255"
          class="min-w-0 flex-1 border-0 bg-transparent p-0 text-sm text-n-slate-12 outline-none"
          :placeholder="t('CAPTAIN.ASSISTANTS.OUTCOMES.PLACEHOLDER')"
        />
        <Switch
          v-model="reason.active"
          :disabled="isSystemReason(reason)"
          :aria-label="t('CAPTAIN.ASSISTANTS.OUTCOMES.ACTIVE')"
        />
        <button
          v-if="!isSystemReason(reason)"
          type="button"
          data-testid="outcome-remove"
          class="flex size-7 shrink-0 items-center justify-center rounded-md text-n-slate-10 hover:bg-n-alpha-2 hover:text-n-slate-12"
          :aria-label="t('CAPTAIN.ASSISTANTS.OUTCOMES.REMOVE')"
          @click="emit('remove', reason.id)"
        >
          <span class="i-lucide-trash-2 size-4" />
        </button>
      </div>
    </div>
  </section>
</template>
