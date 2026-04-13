<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  hasEntityContext: {
    type: Boolean,
    default: false,
  },
  isMutating: {
    type: Boolean,
    default: false,
  },
  touchPlan: {
    type: Object,
    required: true,
  },
});

const emit = defineEmits(['apply', 'archive', 'edit']);

const { t } = useI18n();

const entityKindLabel = kind => {
  switch (kind) {
    case 'appointment':
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.APPOINTMENT');
    case 'conversation':
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.CONVERSATION');
    case 'deal':
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.DEAL');
    case 'task':
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.TASK');
    default:
      return null;
  }
};

const statusText = computed(() => {
  return props.touchPlan.archived
    ? t('OUTBOUND_WORKSPACE.TOUCHES.PLANS.ARCHIVED')
    : t('OUTBOUND_WORKSPACE.TOUCHES.PLANS.ACTIVE');
});

const statusClass = computed(() => {
  return props.touchPlan.archived
    ? 'bg-n-alpha-2 text-n-slate-11'
    : 'bg-n-teal-9/10 text-n-teal-11';
});

const entityKindsText = computed(() => {
  return (props.touchPlan.entity_kinds || [])
    .map(kind => entityKindLabel(kind))
    .filter(Boolean)
    .join(', ');
});

const stepsCountText = computed(() =>
  t('OUTBOUND_WORKSPACE.TOUCH_PLANS.STEPS_COUNT', {
    count: (props.touchPlan.touches || []).length,
  })
);

const previewText = computed(() => {
  if (props.touchPlan.description) {
    return props.touchPlan.description;
  }

  const previews = (props.touchPlan.touches || []).slice(0, 2).map(step => {
    return (
      step.body ||
      step.instructions ||
      t('OUTBOUND_WORKSPACE.TOUCHES.NO_CONTENT')
    );
  });

  return (
    previews.join(' · ') || t('OUTBOUND_WORKSPACE.TOUCHES.PLANS.NO_DESCRIPTION')
  );
});
</script>

<template>
  <CardLayout layout="row">
    <div class="flex min-w-0 flex-1 flex-col items-start justify-between gap-2">
      <div class="flex w-full items-start justify-between gap-3">
        <span class="line-clamp-1 text-base font-medium text-n-slate-12">
          {{ touchPlan.name }}
        </span>
        <span
          class="inline-flex h-6 shrink-0 items-center rounded-md px-2 py-0.5 text-xs font-medium"
          :class="statusClass"
        >
          {{ statusText }}
        </span>
      </div>

      <p class="mb-0 line-clamp-2 text-sm text-n-slate-11">
        {{ previewText }}
      </p>

      <div class="flex min-h-5 flex-wrap items-center gap-2 text-xs">
        <span
          class="inline-flex items-center rounded-md bg-n-alpha-2 px-2 py-0.5 text-n-slate-11"
        >
          {{ stepsCountText }}
        </span>
        <span v-if="entityKindsText" class="text-n-slate-11">
          {{ entityKindsText }}
        </span>
      </div>

      <div
        class="flex min-h-5 flex-wrap items-center gap-2 text-xs text-n-slate-11"
      >
        <span class="font-medium">
          {{ $t('OUTBOUND_WORKSPACE.TOUCHES.PLANS.ENTITY_SCOPE_NOTE') }}
        </span>
        <span>{{ entityKindsText || '—' }}</span>
      </div>
    </div>

    <div class="flex shrink-0 flex-wrap items-center justify-end gap-2 pl-2">
      <Button
        v-if="hasEntityContext && !touchPlan.archived"
        variant="faded"
        size="sm"
        color="blue"
        icon="i-lucide-play"
        :is-loading="isMutating"
        :disabled="isMutating"
        :title="$t('OUTBOUND_WORKSPACE.TOUCHES.PLANS.APPLY')"
        @click="emit('apply', touchPlan)"
      />
      <Button
        v-if="!touchPlan.archived"
        variant="faded"
        size="sm"
        color="slate"
        icon="i-lucide-sliders-horizontal"
        :disabled="isMutating"
        :title="$t('OUTBOUND_WORKSPACE.TOUCHES.PLANS.EDIT')"
        @click="emit('edit', touchPlan)"
      />
      <Button
        v-if="!touchPlan.archived"
        variant="faded"
        size="sm"
        color="ruby"
        icon="i-lucide-archive"
        :is-loading="isMutating"
        :disabled="isMutating"
        :title="$t('OUTBOUND_WORKSPACE.TOUCHES.PLANS.ARCHIVE')"
        @click="emit('archive', touchPlan)"
      />
    </div>
  </CardLayout>
</template>
