<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import {
  APPOINTMENT_AUTOMATION_EVENTS,
  splitMultiEventRules,
} from './appointmentAutomation';

const props = defineProps({
  pipeline: { type: Object, required: true },
  pipelines: { type: Array, default: () => [] },
  selectedPipelineId: { type: [String, Number], default: '' },
  canManage: { type: Boolean, default: false },
  saving: { type: Boolean, default: false },
  medelementInstalled: { type: Boolean, default: false },
});
const emit = defineEmits(['update:selectedPipelineId']);
const draft = defineModel({ type: Object, required: true });

const pipelineOptions = computed(() =>
  props.pipelines.map(item => ({
    value: String(item.id),
    label: item.name,
  }))
);
const { t } = useI18n();
const translate = key => {
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  return t(`CRM.APPOINTMENT_AUTOMATION.${key}`);
};
const choices = keys =>
  keys.map(value => ({ value, label: translate(value.toUpperCase()) }));
const cardinalities = computed(() => choices(['request', 'appointment']));

const autoCreateDescription = computed(() =>
  [
    t('CRM.APPOINTMENT_AUTOMATION.AUTO_CREATE_DEALS_HELP'),
    t('CRM.APPOINTMENT_AUTOMATION.PROSPECTIVE_HELP'),
  ].join(' ')
);
const activeStages = computed(() =>
  (props.pipeline.stages || []).filter(stage => stage.active !== false)
);
const stages = computed(() =>
  activeStages.value.map(stage => ({ value: stage.id, label: stage.name }))
);
const stageOptions = computed(() => [
  { value: '', label: t('CRM.APPOINTMENT_AUTOMATION.NO_STAGE_CHANGE') },
  ...stages.value,
]);
const stageFor = rule =>
  rule &&
  activeStages.value.find(stage => String(stage.id) === String(rule.stage_id));

const eventForRule = rule =>
  APPOINTMENT_AUTOMATION_EVENTS.find(event =>
    (rule?.conditions || []).some(condition =>
      event.matchConditions.includes(condition)
    )
  );
const rulePriority = rule => eventForRule(rule)?.priority ?? 99;
const ruleForEvent = event => {
  const rules = draft.value.rules || [];
  return (
    rules.find(rule => (rule.conditions || []).includes(event.key)) ||
    rules.find(rule =>
      (rule.conditions || []).some(condition =>
        event.matchConditions.includes(condition)
      )
    )
  );
};
const stageIdForEvent = event => ruleForEvent(event)?.stage_id ?? '';

const syncAttendedSuccessMode = () => {
  const attendedRule = ruleForEvent(
    APPOINTMENT_AUTOMATION_EVENTS.find(event => event.key === 'attended')
  );
  if (!attendedRule) {
    draft.value.success_mode = 'manual';
    return;
  }
  draft.value.success_mode =
    stageFor(attendedRule)?.outcome === 'won' ? 'any_attended' : 'manual';
};

const setEventStage = (event, nextStageId) => {
  const rules = splitMultiEventRules(draft.value.rules || []);
  draft.value.rules = rules;
  const existingIndex = rules.findIndex(rule =>
    (rule.conditions || []).some(condition =>
      event.matchConditions.includes(condition)
    )
  );
  if (nextStageId === '' || nextStageId === null || nextStageId === undefined) {
    if (existingIndex >= 0) {
      rules.splice(existingIndex, 1);
    }
    if (event.key === 'attended') syncAttendedSuccessMode();
    return;
  }

  const targetStage = stageFor({ stage_id: nextStageId });
  if (existingIndex >= 0) {
    rules[existingIndex].stage_id = nextStageId;
    if (targetStage?.outcome !== 'lost') {
      rules[existingIndex].closing_reasons = [];
    }
  } else {
    rules.push({
      stage_id: nextStageId,
      scope: event.defaultScope,
      conditions: [...event.saveConditions],
      closing_reasons: [],
    });
    rules.sort((left, right) => rulePriority(left) - rulePriority(right));
  }

  if (event.key === 'attended') syncAttendedSuccessMode();
};

const toggleReason = (rule, value, checked) => {
  if (!rule) return;
  rule.closing_reasons = checked
    ? [...(rule.closing_reasons || []), value]
    : (rule.closing_reasons || []).filter(reason => reason !== value);
};

const pauseOnManualMove = computed({
  get: () => draft.value.manual_stage_change === 'pause',
  set: paused => {
    draft.value.manual_stage_change = paused ? 'pause' : 'continue';
  },
});

const valid = computed(
  () =>
    !draft.value.enabled ||
    draft.value.rules?.every(rule => stageFor(rule) && rule.conditions.length)
);

const buildPayload = () => {
  if (!valid.value) return null;
  const attendedRule = (draft.value.rules || []).find(rule =>
    (rule.conditions || []).includes('attended')
  );
  const resolvedSuccessMode =
    stageFor(attendedRule)?.outcome === 'won'
      ? 'any_attended'
      : draft.value.success_mode || 'manual';

  return {
    ...JSON.parse(JSON.stringify(draft.value)),
    success_mode: resolvedSuccessMode,
    rules: (draft.value.rules || []).map(rule => ({
      stage_id: rule.stage_id,
      scope: rule.scope,
      conditions: [...rule.conditions],
      closing_reasons:
        stageFor(rule)?.outcome === 'lost' ? [...rule.closing_reasons] : [],
    })),
  };
};
defineExpose({ buildPayload });
</script>

<template>
  <section
    class="flex min-w-0 flex-col gap-4"
    data-testid="crm-appointment-automation-settings"
  >
    <h3 class="m-0 text-heading-2 text-n-slate-12">
      {{ $t('CRM.APPOINTMENT_AUTOMATION.TITLE') }}
    </h3>
    <SchedulingSelectField
      v-if="pipelineOptions.length"
      :model-value="String(selectedPipelineId || pipeline?.id || '')"
      :label="$t('CRM.APPOINTMENT_AUTOMATION.PIPELINE_LABEL')"
      :options="pipelineOptions"
      :disabled="!canManage || saving"
      data-testid="appointment-automation-pipeline-select"
      @update:model-value="emit('update:selectedPipelineId', $event)"
    />
    <SettingsToggleSection
      v-model="draft.auto_create_deals"
      :header="$t('CRM.APPOINTMENT_AUTOMATION.AUTO_CREATE_DEALS')"
      :description="autoCreateDescription"
      :disabled="!canManage || saving"
      data-testid="appointment-auto-create-deals"
    >
      <template v-if="draft.auto_create_deals" #editor>
        <div class="flex flex-col gap-4 pt-2">
          <div class="flex flex-col gap-1">
            <label
              class="flex items-center justify-between gap-3 py-1 text-heading-3 text-n-slate-12"
            >
              <span>{{
                $t('CRM.APPOINTMENT_AUTOMATION.CALENDAR_SOURCE')
              }}</span>
              <Switch
                v-model="draft.auto_create_from_calendar"
                :disabled="!canManage || saving"
              />
            </label>
            <label
              v-if="medelementInstalled"
              class="flex items-center justify-between gap-3 py-1 text-heading-3 text-n-slate-12"
            >
              <span>{{ $t('CRM.APPOINTMENT_AUTOMATION.ME_SOURCE') }}</span>
              <Switch
                v-model="draft.auto_create_from_medelement"
                :disabled="!canManage || saving"
              />
            </label>
            <p
              v-if="
                draft.auto_create_from_calendar ||
                (medelementInstalled && draft.auto_create_from_medelement)
              "
              class="m-0 text-label-small text-n-slate-11"
            >
              {{
                $t('CRM.APPOINTMENT_AUTOMATION.TARGET_HELP', {
                  pipeline: pipeline.name,
                })
              }}
            </p>
          </div>
          <SchedulingSelectField
            v-model="draft.cardinality"
            :label="$t('CRM.APPOINTMENT_AUTOMATION.CARDINALITY')"
            :options="cardinalities"
            :disabled="!canManage || saving"
          />
        </div>
      </template>
    </SettingsToggleSection>
    <SettingsToggleSection
      v-model="draft.enabled"
      :header="$t('CRM.APPOINTMENT_AUTOMATION.ENABLED')"
      :description="$t('CRM.APPOINTMENT_AUTOMATION.ENABLED_HELP')"
      :disabled="!canManage || saving"
      data-testid="appointment-stage-automation"
    >
      <template v-if="draft.enabled && activeStages.length" #editor>
        <div class="flex flex-col gap-4 pt-2">
          <div
            class="flex flex-col divide-y divide-n-weak border-y border-n-weak"
          >
            <fieldset
              v-for="event in APPOINTMENT_AUTOMATION_EVENTS"
              :key="event.key"
              :disabled="!canManage || saving"
              :data-testid="`appointment-event-row-${event.key}`"
              class="grid min-w-0 gap-2 py-3 md:grid-cols-[minmax(0,1.25fr)_minmax(0,1fr)] md:items-start md:gap-4"
            >
              <div class="flex flex-col gap-0.5">
                <span class="text-heading-3 text-n-slate-12">
                  {{ translate(`EVENT_${event.key.toUpperCase()}_TITLE`) }}
                </span>
                <span class="text-label-small text-n-slate-11">
                  {{ translate(`EVENT_${event.key.toUpperCase()}_HELP`) }}
                </span>
              </div>
              <SchedulingSelectField
                :model-value="stageIdForEvent(event)"
                :label="$t('CRM.APPOINTMENT_AUTOMATION.STAGE')"
                :options="stageOptions"
                :disabled="!canManage || saving"
                :data-testid="`appointment-event-stage-${event.key}`"
                @update:model-value="setEventStage(event, $event)"
              />
              <div
                v-if="
                  stageFor(ruleForEvent(event))?.outcome === 'lost' &&
                  stageFor(ruleForEvent(event))?.closingReasonOptions?.length
                "
                class="flex flex-col gap-1.5 pt-1 md:col-span-2"
              >
                <span class="text-heading-3 text-n-slate-12">{{
                  $t('CRM.APPOINTMENT_AUTOMATION.CLOSING_REASONS')
                }}</span>
                <div class="flex flex-wrap gap-3">
                  <label
                    v-for="reason in stageFor(ruleForEvent(event))
                      .closingReasonOptions"
                    :key="reason"
                    class="flex items-center gap-2 text-sm font-normal text-n-slate-12"
                  >
                    <input
                      type="checkbox"
                      :checked="
                        ruleForEvent(event)?.closing_reasons?.includes(reason)
                      "
                      @change="
                        toggleReason(
                          ruleForEvent(event),
                          reason,
                          $event.target.checked
                        )
                      "
                    />
                    <span>{{ reason }}</span>
                  </label>
                </div>
              </div>
            </fieldset>
          </div>
          <div class="flex flex-col gap-1">
            <label
              class="flex items-center justify-between gap-3 py-1 text-heading-3 text-n-slate-12"
            >
              <span>{{
                $t('CRM.APPOINTMENT_AUTOMATION.PAUSE_ON_MANUAL_MOVE')
              }}</span>
              <Switch
                v-model="pauseOnManualMove"
                :disabled="!canManage || saving"
                data-testid="appointment-pause-on-manual-move"
              />
            </label>
            <p class="m-0 text-label-small text-n-slate-11">
              {{ $t('CRM.APPOINTMENT_AUTOMATION.PAUSE_ON_MANUAL_MOVE_HELP') }}
            </p>
          </div>
        </div>
      </template>
    </SettingsToggleSection>
  </section>
</template>
