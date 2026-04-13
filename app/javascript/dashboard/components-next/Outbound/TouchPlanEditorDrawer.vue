<script setup>
import { computed, reactive, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import TouchPlansAPI from 'dashboard/api/touchPlans';
import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import WootMessageEditor from 'dashboard/components/widgets/WootWriter/Editor.vue';
import {
  buildTouchAnchorOptions,
  touchAnchorSupportedEntityKinds,
} from 'dashboard/components-next/Outbound/touchAnchors';
import { detectTouchTextMode } from 'dashboard/components-next/Outbound/touchTextMode';
import {
  fromDateTimeInputValue,
  toDateTimeInputValue,
} from 'dashboard/routes/dashboard/scheduling/helpers';

const props = defineProps({
  createLabel: {
    type: String,
    default: '',
  },
  createTitle: {
    type: String,
    default: '',
  },
  description: {
    type: String,
    default: '',
  },
  editTitle: {
    type: String,
    default: '',
  },
  modelValue: {
    type: Boolean,
    default: false,
  },
  saveLabel: {
    type: String,
    default: '',
  },
  touchPlan: {
    type: Object,
    default: null,
  },
});

const emit = defineEmits(['close', 'saved', 'update:modelValue']);

const { t } = useI18n();

const browserTimezone =
  Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

let nextStepId = 0;

const allocateStepId = () => {
  nextStepId += 1;
  return `touch-plan-step-${nextStepId}`;
};

const form = reactive({
  description: '',
  entityKinds: [],
  name: '',
  steps: [],
});

const ui = reactive({
  isSaving: false,
});

const drawerTitle = computed(() => {
  if (props.touchPlan?.id) {
    return (
      props.editTitle || t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.EDIT_TITLE')
    );
  }

  return (
    props.createTitle || t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.CREATE_TITLE')
  );
});

const drawerDescription = computed(() => {
  return (
    props.description || t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.DESCRIPTION')
  );
});

const drawerConfirmLabel = computed(() => {
  if (props.touchPlan?.id) {
    return props.saveLabel || t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.SAVE');
  }

  return props.createLabel || t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.CREATE');
});

const entityKindOptions = computed(() => [
  {
    description: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.CONVERSATION'),
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.CONVERSATION'),
    value: 'conversation',
  },
  {
    description: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.DEAL'),
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.DEAL'),
    value: 'deal',
  },
  {
    description: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.TASK'),
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.TASK'),
    value: 'task',
  },
  {
    description: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.APPOINTMENT'),
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.APPOINTMENT'),
    value: 'appointment',
  },
]);

const repeatModeOptions = computed(() => [
  {
    label: t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE.ONCE'),
    value: 'once',
  },
  {
    label: t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE.DAILY'),
    value: 'daily',
  },
  {
    label: t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE.WEEKLY'),
    value: 'weekly',
  },
  {
    label: t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE.WEEKDAYS'),
    value: 'weekdays',
  },
  {
    label: t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE.MONTHLY'),
    value: 'monthly',
  },
]);

const distinctAnchorOptions = entityKinds => {
  return buildTouchAnchorOptions({
    t,
    entityKinds,
    kindLabelResolver: kind => {
      const option = entityKindOptions.value.find(item => item.value === kind);
      return option?.label || kind;
    },
    prefixLabelWithKind: true,
  });
};

const stepAnchorOptions = () => {
  return distinctAnchorOptions(form.entityKinds).map(option => ({
    label: option.label,
    value: option.value,
  }));
};

const anchorSupportedEntityKinds = anchorValue => {
  return touchAnchorSupportedEntityKinds(anchorValue);
};

const stepHasCompatibilityWarning = step => {
  if (step.timingMode !== 'relative' || form.entityKinds.length <= 1) {
    return false;
  }

  const supportedKinds = anchorSupportedEntityKinds(step.relativeAnchor);
  return form.entityKinds.some(kind => !supportedKinds.includes(kind));
};

const createStep = (seed = {}) => {
  const availableAnchors = distinctAnchorOptions(form.entityKinds);

  return {
    localId: allocateStepId(),
    autoCancelOnIncoming: seed.auto_cancel_on_incoming ?? true,
    body: seed.body || '',
    instructions: seed.instructions || '',
    relativeAnchor:
      seed.relative_anchor ||
      availableAnchors[0]?.value ||
      'conversation.created_at',
    relativeOffsetMinutes: Math.round((seed.relative_offset_seconds || 0) / 60),
    repeatMode: seed.repeat_mode || 'once',
    repeatUntilAt: seed.repeat_until_at
      ? toDateTimeInputValue(seed.repeat_until_at)
      : '',
    scheduledAt: seed.scheduled_at
      ? toDateTimeInputValue(seed.scheduled_at)
      : '',
    timingMode: seed.timing_mode || 'relative',
    timezone: seed.timezone || browserTimezone,
    useAiAuthoring: seed.text_mode === 'agent',
  };
};

const validateStep = step => {
  if (
    step.useAiAuthoring
      ? !String(step.instructions || '').trim()
      : !String(step.body || '').trim()
  ) {
    return false;
  }

  if (step.timingMode === 'absolute') {
    return !!step.scheduledAt;
  }

  return !!step.relativeAnchor;
};

const canSave = computed(() => {
  return (
    !!String(form.name || '').trim() &&
    form.entityKinds.length > 0 &&
    form.steps.length > 0 &&
    form.steps.every(validateStep)
  );
});

const entityScopeSummary = computed(() => {
  return form.entityKinds.length > 0
    ? form.entityKinds
        .map(kind => {
          const option = entityKindOptions.value.find(
            item => item.value === kind
          );
          return option?.label || kind;
        })
        .join(', ')
    : t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.ENTITY_KIND_PLACEHOLDER');
});

const resetForm = () => {
  form.description = '';
  form.entityKinds = ['appointment'];
  form.name = '';
  form.steps = [createStep()];
};

const hydrateForm = () => {
  if (!props.modelValue) {
    return;
  }

  if (!props.touchPlan) {
    resetForm();
    return;
  }

  form.description = props.touchPlan.description || '';
  form.entityKinds = Array(props.touchPlan.entity_kinds || []);
  form.name = props.touchPlan.name || '';
  form.steps =
    Array(props.touchPlan.touches || []).map(step => createStep(step)) || [];

  if (!form.steps.length) {
    form.steps = [createStep()];
  }
};

const normalizeStepAnchors = () => {
  const availableAnchors = distinctAnchorOptions(form.entityKinds);
  const fallbackAnchor =
    availableAnchors[0]?.value || 'conversation.created_at';

  form.steps = form.steps.map(step => {
    const hasAnchor = availableAnchors.some(
      option => option.value === step.relativeAnchor
    );

    if (step.timingMode === 'relative' && !hasAnchor) {
      return {
        ...step,
        relativeAnchor: fallbackAnchor,
      };
    }

    return step;
  });
};

const toggleEntityKind = (entityKind, enabled) => {
  if (enabled) {
    form.entityKinds = [...new Set([...form.entityKinds, entityKind])];
  } else {
    form.entityKinds = form.entityKinds.filter(kind => kind !== entityKind);
  }

  normalizeStepAnchors();
};

const addStep = () => {
  form.steps = [...form.steps, createStep()];
};

const removeStep = localId => {
  if (form.steps.length === 1) {
    return;
  }

  form.steps = form.steps.filter(step => step.localId !== localId);
};

const updateStep = (localId, patch) => {
  form.steps = form.steps.map(step =>
    step.localId === localId ? { ...step, ...patch } : step
  );
};

const stepBodyEditorId = step => {
  return `touch-plan-body-${step.localId}`;
};
const stepInstructionsEditorId = step => {
  return `touch-plan-instructions-${step.localId}`;
};

const aiToggleButtonClass = isEnabled => {
  return isEnabled
    ? '!bg-n-violet-3 !text-n-violet-9 hover:enabled:!bg-n-violet-4 focus-visible:!bg-n-violet-4 !outline-transparent'
    : '';
};

const touchEditorClass = isAiAuthoring => {
  return [
    'touch-rich-editor w-full min-w-0 max-w-full overflow-visible rounded-2xl px-3 py-2 transition-all duration-200',
    isAiAuthoring
      ? 'bg-n-violet-3 ring-1 ring-inset ring-n-violet-6/20'
      : 'bg-n-solid-1 outline outline-1 outline-n-weak dark:outline-n-strong',
  ].join(' ');
};

const setStepRelativeTiming = (step, enabled) => {
  updateStep(step.localId, {
    timingMode: enabled ? 'relative' : 'absolute',
    relativeAnchor:
      enabled && !step.relativeAnchor
        ? stepAnchorOptions()[0]?.value || 'conversation.created_at'
        : step.relativeAnchor,
    repeatMode: enabled ? 'once' : step.repeatMode,
    repeatUntilAt: enabled ? '' : step.repeatUntilAt,
  });
};

const buildPayload = () => {
  return {
    description: String(form.description || '').trim(),
    entity_kinds: form.entityKinds,
    name: String(form.name || '').trim(),
    touches: form.steps.map(step => ({
      action_type: 'send_message',
      auto_cancel_on_incoming: step.autoCancelOnIncoming,
      body: step.useAiAuthoring ? '' : String(step.body || '').trim(),
      content_kind: 'free_text',
      instructions: step.useAiAuthoring
        ? String(step.instructions || '').trim()
        : '',
      repeat_mode: step.timingMode === 'absolute' ? step.repeatMode : 'once',
      repeat_until_at:
        step.timingMode === 'absolute' &&
        step.repeatMode !== 'once' &&
        step.repeatUntilAt
          ? fromDateTimeInputValue(step.repeatUntilAt)
          : '',
      text_mode: detectTouchTextMode({
        body: step.body,
        instructions: step.instructions,
        useAiAuthoring: step.useAiAuthoring,
      }),
      timing_mode: step.timingMode,
      timezone: step.timezone || browserTimezone,
      ...(step.timingMode === 'absolute'
        ? {
            scheduled_at: fromDateTimeInputValue(step.scheduledAt),
          }
        : {
            relative_anchor: step.relativeAnchor,
            relative_offset_seconds:
              Number(step.relativeOffsetMinutes || 0) * 60,
          }),
    })),
  };
};

const closeDrawer = () => {
  emit('update:modelValue', false);
  emit('close');
};

const saveTouchPlan = async () => {
  if (!canSave.value) {
    return;
  }

  ui.isSaving = true;

  try {
    const payload = buildPayload();
    const response = props.touchPlan?.id
      ? await TouchPlansAPI.update(props.touchPlan.id, payload)
      : await TouchPlansAPI.create(payload);

    emit('saved', response.data?.payload);
    useAlert(
      props.touchPlan?.id
        ? t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.SUCCESS.UPDATED')
        : t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.SUCCESS.CREATED')
    );
    closeDrawer();
  } catch (error) {
    useAlert(
      error?.message || t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.ERRORS.SAVE')
    );
  } finally {
    ui.isSaving = false;
  }
};

watch(
  () => [props.modelValue, props.touchPlan?.id],
  () => {
    hydrateForm();
  },
  { immediate: true }
);

watch(
  () => form.entityKinds.join('|'),
  () => {
    normalizeStepAnchors();
  }
);
</script>

<template>
  <SchedulingDrawer
    :model-value="modelValue"
    width="xl"
    :title="drawerTitle"
    :description="drawerDescription"
    :confirm-label="drawerConfirmLabel"
    :is-loading="ui.isSaving"
    :disable-confirm="!canSave || ui.isSaving"
    @update:model-value="emit('update:modelValue', $event)"
    @close="closeDrawer"
    @confirm="saveTouchPlan"
  >
    <div class="grid gap-6">
      <SchedulingFormFieldGroup :framed="false">
        <div class="grid gap-4">
          <Input
            :label="$t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.NAME')"
            :model-value="form.name"
            :placeholder="
              $t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.NAME_PLACEHOLDER')
            "
            @update:model-value="form.name = $event"
          />

          <TextArea
            :label="
              $t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.DESCRIPTION')
            "
            :model-value="form.description"
            auto-height
            :placeholder="
              $t(
                'OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.DESCRIPTION_PLACEHOLDER'
              )
            "
            @update:model-value="form.description = $event"
          />
        </div>
      </SchedulingFormFieldGroup>

      <SchedulingFormFieldGroup
        :framed="false"
        :title="$t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.ENTITY_KINDS')"
        :description="
          $t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.ENTITY_KINDS_NOTE')
        "
      >
        <div class="grid gap-3 sm:grid-cols-2">
          <label
            v-for="option in entityKindOptions"
            :key="option.value"
            class="flex items-start gap-3 rounded-2xl bg-n-alpha-black2 px-4 py-3"
          >
            <Checkbox
              :model-value="form.entityKinds.includes(option.value)"
              @update:model-value="toggleEntityKind(option.value, $event)"
            />
            <div class="min-w-0">
              <p class="mb-1 text-sm font-medium text-n-slate-12">
                {{ option.label }}
              </p>
              <p class="mb-0 text-xs leading-5 text-n-slate-11">
                {{
                  $t(
                    'OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.ENTITY_KIND_HELP'
                  )
                }}
              </p>
            </div>
          </label>
        </div>
      </SchedulingFormFieldGroup>

      <SchedulingFormFieldGroup
        :framed="false"
        :title="$t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.STEPS')"
        :description="
          $t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.STEPS_NOTE', {
            entityKinds: entityScopeSummary,
          })
        "
      >
        <div class="grid gap-4">
          <div
            v-for="(step, index) in form.steps"
            :key="step.localId"
            class="grid gap-4 rounded-2xl bg-n-alpha-black2 p-4 outline outline-1 outline-n-weak"
          >
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <p class="mb-1 text-sm font-semibold text-n-slate-12">
                  {{
                    $t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.STEP_TITLE', {
                      index: index + 1,
                    })
                  }}
                </p>
                <p class="mb-0 text-xs leading-5 text-n-slate-11">
                  {{
                    $t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.STEP_DESCRIPTION')
                  }}
                </p>
              </div>

              <Button
                v-if="form.steps.length > 1"
                size="sm"
                color="slate"
                variant="faded"
                :label="$t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.REMOVE_STEP')"
                @click="removeStep(step.localId)"
              />
            </div>

            <div class="grid gap-4">
              <div class="flex items-center justify-between gap-3">
                <p class="mb-0 text-sm font-medium text-n-slate-12">
                  {{ $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.BODY') }}
                </p>
                <Button
                  v-tooltip.top-end="
                    $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.AI_AGENT')
                  "
                  icon="i-woot-captain"
                  :variant="step.useAiAuthoring ? 'solid' : 'faded'"
                  color="slate"
                  size="sm"
                  :aria-pressed="step.useAiAuthoring"
                  :class="aiToggleButtonClass(step.useAiAuthoring)"
                  @click="
                    updateStep(step.localId, {
                      useAiAuthoring: !step.useAiAuthoring,
                    })
                  "
                />
              </div>

              <WootMessageEditor
                v-if="!step.useAiAuthoring"
                :model-value="step.body"
                :editor-id="stepBodyEditorId(step)"
                :class="touchEditorClass(false)"
                enable-variables
                enable-captain-fields
                enable-canned-responses
                canned-menu-placement="bottom"
                :canned-menu-visible-items="3"
                :placeholder="
                  $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.BODY_PLACEHOLDER')
                "
                @update:model-value="updateStep(step.localId, { body: $event })"
              />

              <WootMessageEditor
                v-else
                :model-value="step.instructions"
                :editor-id="stepInstructionsEditorId(step)"
                :class="touchEditorClass(true)"
                enable-variables
                enable-captain-fields
                enable-canned-responses
                canned-menu-placement="bottom"
                :canned-menu-visible-items="3"
                :placeholder="
                  $t(
                    'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.INSTRUCTIONS_PLACEHOLDER'
                  )
                "
                @update:model-value="
                  updateStep(step.localId, { instructions: $event })
                "
              />
            </div>

            <div class="grid gap-4">
              <div class="flex items-center justify-between gap-3">
                <p class="mb-0 text-sm font-medium text-n-slate-12">
                  {{
                    $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.SCHEDULED_AT')
                  }}
                </p>
                <label class="flex items-center gap-2 text-sm text-n-slate-11">
                  <Checkbox
                    :model-value="step.timingMode === 'relative'"
                    @update:model-value="setStepRelativeTiming(step, $event)"
                  />
                  <span>{{
                    $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_TOGGLE')
                  }}</span>
                </label>
              </div>
              <SchedulingDateTimeField
                v-if="step.timingMode === 'absolute'"
                :model-value="step.scheduledAt"
                type="datetime"
                @update:model-value="
                  updateStep(step.localId, { scheduledAt: $event })
                "
              />

              <SchedulingSelectField
                v-else
                :model-value="step.relativeAnchor"
                :options="stepAnchorOptions(step)"
                @update:model-value="
                  updateStep(step.localId, { relativeAnchor: $event })
                "
              />
            </div>

            <div
              v-if="step.timingMode === 'absolute'"
              class="grid gap-4 lg:grid-cols-2"
            >
              <div class="grid gap-1">
                <div
                  class="mb-0.5 flex items-center gap-2 text-sm font-medium text-n-slate-12"
                >
                  <span class="i-lucide-repeat-2 size-4 text-n-slate-11" />
                  <span>{{
                    $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.REPEAT_MODE')
                  }}</span>
                </div>
                <SchedulingSelectField
                  :model-value="step.repeatMode"
                  :options="repeatModeOptions"
                  @update:model-value="
                    updateStep(step.localId, { repeatMode: $event })
                  "
                />
              </div>

              <SchedulingDateTimeField
                v-if="step.repeatMode !== 'once'"
                :label="
                  $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.REPEAT_UNTIL_AT')
                "
                :model-value="step.repeatUntilAt"
                type="datetime"
                @update:model-value="
                  updateStep(step.localId, { repeatUntilAt: $event })
                "
              />
            </div>

            <Input
              v-if="step.timingMode === 'relative'"
              :label="
                $t(
                  'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_MINUTES'
                )
              "
              :model-value="String(step.relativeOffsetMinutes)"
              type="number"
              inputmode="numeric"
              @update:model-value="
                updateStep(step.localId, {
                  relativeOffsetMinutes: Number($event || 0),
                  repeatMode: 'once',
                  repeatUntilAt: '',
                })
              "
            />

            <div
              v-if="stepHasCompatibilityWarning(step)"
              class="rounded-2xl bg-n-amber-2 px-4 py-3 text-sm leading-6 text-n-amber-12"
            >
              {{
                $t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.COMPATIBILITY_WARNING')
              }}
            </div>

            <div
              class="grid grid-cols-[auto_minmax(0,1fr)] items-start gap-3 rounded-2xl bg-n-solid-1 px-4 py-3"
            >
              <Checkbox
                class="mt-0.5 shrink-0"
                :model-value="step.autoCancelOnIncoming"
                @update:model-value="
                  updateStep(step.localId, { autoCancelOnIncoming: $event })
                "
              />
              <div class="min-w-0">
                <p class="mb-1 text-sm font-medium text-n-slate-12">
                  {{ $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.AUTO_CANCEL') }}
                </p>
                <p class="mb-0 text-xs leading-5 text-n-slate-11">
                  {{
                    $t(
                      'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.AUTO_CANCEL_DESCRIPTION'
                    )
                  }}
                </p>
              </div>
            </div>
          </div>

          <div>
            <Button
              size="sm"
              slate
              :label="$t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.ADD_STEP')"
              @click="addStep"
            />
          </div>
        </div>
      </SchedulingFormFieldGroup>
    </div>

    <template #footer>
      <div class="flex items-center justify-between w-full gap-3">
        <Button
          size="sm"
          color="slate"
          variant="faded"
          :label="$t('SCHEDULING.GENERAL.CANCEL')"
          @click="closeDrawer"
        />
        <Button
          size="sm"
          :is-loading="ui.isSaving"
          :disabled="!canSave || ui.isSaving"
          :label="drawerConfirmLabel"
          @click="saveTouchPlan"
        />
      </div>
    </template>
  </SchedulingDrawer>
</template>

<style scoped>
.touch-rich-editor :deep(.ProseMirror-menubar-wrapper),
.touch-rich-editor :deep(.ProseMirror),
.touch-rich-editor :deep(.ProseMirror-menubar) {
  min-width: 0;
  width: 100%;
  max-width: 100%;
}

.touch-rich-editor {
  overflow: visible;
}

.touch-rich-editor :deep(.mention--box),
.touch-rich-editor :deep(.copilot-editor-menu) {
  z-index: 70;
}
</style>
