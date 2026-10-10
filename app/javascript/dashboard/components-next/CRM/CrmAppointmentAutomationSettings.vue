<script setup>
import { computed, onBeforeUnmount, reactive, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import { formatCrmErrorMessage } from 'dashboard/stores/crm/shared';
import CrmPipelinesAPI from 'dashboard/api/crm/pipelines';

const props = defineProps({
  pipeline: { type: Object, required: true },
  canManage: { type: Boolean, default: false },
});
const { t } = useI18n();
const route = useRoute();
const accountId = computed(() => String(route?.params?.accountId || ''));
let generation = 0;
const references = useCrmReferencesStore();
const saving = ref(false);
const error = ref('');
const baseline = ref('');
const draft = reactive({});
const translate = key => {
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  return t(`CRM.APPOINTMENT_AUTOMATION.${key}`);
};
const choices = keys => keys.map(value => ({ value, label: translate(value.toUpperCase()) }));
const cardinalities = computed(() => choices(['request', 'appointment']));
const successModes = computed(() => choices(['manual', 'any_attended', 'selected_attended', 'all_required_attended']));
const scopes = computed(() => choices(['any', 'all', 'selected', 'nearest']));
const conditions = computed(() => choices(['provider_confirmed', 'patient_confirmed', 'scheduled', 'attended', 'cancelled', 'no_show', 'today', 'tomorrow', 'past', 'future']));
const manualModes = computed(() => choices(['continue', 'pause']));
const activeStages = computed(() => (props.pipeline.stages || []).filter(stage => stage.active !== false));
const stages = computed(() => activeStages.value.map(stage => ({ value: stage.id, label: stage.name })));
const dirty = computed(() => JSON.stringify(draft) !== baseline.value);
const valid = computed(() => draft.rules?.every(rule => rule.stage_id && rule.conditions.length));

watch([accountId, () => props.pipeline], ([, pipeline]) => {
  generation += 1;
  const config = pipeline.appointmentAutomation || {};
  Object.assign(draft, {
    enabled: config.enabled === true,
    cardinality: config.cardinality || 'request',
    auto_create_from_calendar: config.autoCreateFromCalendar === true,
    auto_create_from_medelement: config.autoCreateFromMedelement === true,
    manual_stage_change: config.manualStageChange || 'continue',
    success_mode: config.successMode || 'manual',
    rules: (config.rules || []).map(rule => ({
      stage_id: rule.stageId,
      scope: rule.scope || 'any',
      conditions: [...(rule.conditions || [])],
      closing_reasons: [...(rule.closingReasons || [])],
      transition_reason: rule.transitionReason || '',
    })),
  });
  baseline.value = JSON.stringify(draft);
  error.value = '';
  saving.value = false;
}, { immediate: true });
onBeforeUnmount(() => { generation += 1; });

const addRule = () => draft.rules.push({ stage_id: stages.value[0]?.value || null, scope: 'any', conditions: ['provider_confirmed'], closing_reasons: [], transition_reason: '' });
const moveRule = (index, offset) => {
  const target = index + offset;
  if (target < 0 || target >= draft.rules.length) return;
  const [rule] = draft.rules.splice(index, 1);
  draft.rules.splice(target, 0, rule);
};
const stageFor = rule => activeStages.value.find(stage => Number(stage.id) === Number(rule.stage_id));
const toggleCondition = (rule, value, checked) => {
  rule.conditions = checked ? [...rule.conditions, value] : rule.conditions.filter(condition => condition !== value);
};
const toggleReason = (rule, value, checked) => {
  rule.closing_reasons = checked ? [...rule.closing_reasons, value] : rule.closing_reasons.filter(reason => reason !== value);
};
const save = async () => {
  if (!props.canManage || !valid.value || saving.value) return;
  const pipelineId = props.pipeline.id;
  const request = generation;
  const account = accountId.value;
  saving.value = true;
  error.value = '';
  try {
    await CrmPipelinesAPI.update(pipelineId, { appointment_automation: JSON.parse(JSON.stringify(draft)) });
    if (request !== generation || account !== accountId.value) return;
    await references.loadPipelines({ include_inactive_stages: true });
  } catch (failure) {
    if (request === generation && account === accountId.value) error.value = formatCrmErrorMessage(failure, t);
  } finally {
    if (request === generation) saving.value = false;
  }
};
</script>

<template>
  <section class="grid gap-3 px-5 py-4" data-testid="crm-appointment-automation-settings">
    <h3 class="m-0 text-sm font-semibold text-n-slate-12">{{ $t('CRM.APPOINTMENT_AUTOMATION.TITLE') }}</h3>
    <SchedulingSelectField v-model="draft.cardinality" :label="$t('CRM.APPOINTMENT_AUTOMATION.CARDINALITY')" :options="cardinalities" :disabled="!canManage || saving" />
    <p class="m-0 text-xs leading-5 text-n-slate-10">{{ $t('CRM.APPOINTMENT_AUTOMATION.PROSPECTIVE_HELP') }}</p>
    <label class="flex items-center justify-between gap-3 text-sm text-n-slate-11">
      <span>{{ $t('CRM.APPOINTMENT_AUTOMATION.CALENDAR_SOURCE') }}</span>
      <Switch v-model="draft.auto_create_from_calendar" :disabled="!canManage || saving" />
    </label>
    <label class="flex items-center justify-between gap-3 text-sm text-n-slate-11">
      <span>{{ $t('CRM.APPOINTMENT_AUTOMATION.ME_SOURCE') }}</span>
      <Switch v-model="draft.auto_create_from_medelement" :disabled="!canManage || saving" />
    </label>
    <p v-if="draft.auto_create_from_calendar || draft.auto_create_from_medelement" class="m-0 text-xs leading-5 text-n-slate-10">{{ $t('CRM.APPOINTMENT_AUTOMATION.TARGET_HELP', { pipeline: pipeline.name }) }}</p>
    <label class="flex items-center justify-between gap-3 text-sm text-n-slate-11">
      <span>{{ $t('CRM.APPOINTMENT_AUTOMATION.ENABLED') }}</span>
      <Switch v-model="draft.enabled" :disabled="!canManage || saving" />
    </label>
    <details v-if="draft.enabled" class="grid gap-3">
      <summary class="cursor-pointer text-sm font-medium text-n-slate-12">{{ $t('CRM.APPOINTMENT_AUTOMATION.RULES_TITLE') }}</summary>
      <div class="mt-3 grid gap-3">
        <SchedulingSelectField v-model="draft.success_mode" :label="$t('CRM.APPOINTMENT_AUTOMATION.SUCCESS_LABEL')" :options="successModes" :disabled="!canManage || saving" />
        <p class="m-0 text-xs leading-5 text-n-slate-10">{{ $t('CRM.APPOINTMENT_AUTOMATION.PLAN_HELP') }}</p>
        <SchedulingSelectField v-model="draft.manual_stage_change" :label="$t('CRM.APPOINTMENT_AUTOMATION.MANUAL_LABEL')" :options="manualModes" :disabled="!canManage || saving" />
        <p class="m-0 text-xs leading-5 text-n-slate-10">{{ $t('CRM.APPOINTMENT_AUTOMATION.RULES_HELP') }}</p>
        <fieldset v-for="(rule, index) in draft.rules" :key="index" :disabled="!canManage || saving" class="grid min-w-0 gap-3 rounded-lg border border-n-weak p-3">
          <div class="flex items-center justify-between gap-1">
            <span class="text-xs font-semibold text-n-slate-12">{{ $t('CRM.APPOINTMENT_AUTOMATION.RULE_NUMBER', { number: index + 1 }) }}</span>
            <div class="flex gap-1">
              <Button icon="i-lucide-arrow-up" size="xs" color="slate" variant="ghost" :aria-label="$t('CRM.APPOINTMENT_AUTOMATION.MOVE_UP')" :disabled="!canManage || index === 0 || saving" @click="moveRule(index, -1)" />
              <Button icon="i-lucide-arrow-down" size="xs" color="slate" variant="ghost" :aria-label="$t('CRM.APPOINTMENT_AUTOMATION.MOVE_DOWN')" :disabled="!canManage || index === draft.rules.length - 1 || saving" @click="moveRule(index, 1)" />
              <Button icon="i-lucide-trash-2" size="xs" color="slate" variant="ghost" :aria-label="$t('CRM.APPOINTMENT_AUTOMATION.REMOVE')" :disabled="!canManage || saving" @click="draft.rules.splice(index, 1)" />
            </div>
          </div>
          <SchedulingSelectField v-model="rule.stage_id" :label="$t('CRM.APPOINTMENT_AUTOMATION.STAGE')" :options="stages" :disabled="!canManage || saving" />
          <SchedulingSelectField v-model="rule.scope" :label="$t('CRM.APPOINTMENT_AUTOMATION.SCOPE')" :options="scopes" :disabled="!canManage || saving" />
          <label v-for="condition in conditions" :key="condition.value" class="flex items-center gap-2 text-xs text-n-slate-11">
            <input type="checkbox" :checked="rule.conditions.includes(condition.value)" @change="toggleCondition(rule, condition.value, $event.target.checked)" />
            <span>{{ condition.label }}</span>
          </label>
          <template v-if="stageFor(rule)?.closingReasonOptions?.length">
            <span class="text-xs font-medium text-n-slate-12">{{ $t('CRM.APPOINTMENT_AUTOMATION.CLOSING_REASONS') }}</span>
            <label v-for="reason in stageFor(rule).closingReasonOptions" :key="reason" class="flex items-center gap-2 text-xs text-n-slate-11">
              <input type="checkbox" :checked="rule.closing_reasons.includes(reason)" @change="toggleReason(rule, reason, $event.target.checked)" />
              <span>{{ reason }}</span>
            </label>
          </template>
          <SchedulingSelectField v-if="stageFor(rule)?.transitionReasonOptions?.length" v-model="rule.transition_reason" :label="$t('CRM.APPOINTMENT_AUTOMATION.TRANSITION_REASON')" :options="stageFor(rule).transitionReasonOptions.map(value => ({ value, label: value }))" :disabled="!canManage || saving" />
          <Input v-else-if="stageFor(rule)?.transitionReasonRequired" v-model="rule.transition_reason" :label="$t('CRM.APPOINTMENT_AUTOMATION.TRANSITION_REASON')" :disabled="!canManage || saving" />
        </fieldset>
        <Button size="sm" color="slate" variant="faded" icon="i-lucide-plus" :label="$t('CRM.APPOINTMENT_AUTOMATION.ADD_RULE')" :disabled="!canManage || saving || draft.rules.length >= 50" @click="addRule" />
      </div>
    </details>
    <p v-if="error" role="alert" class="m-0 text-xs text-n-ruby-10">{{ error }}</p>
    <Button v-if="canManage" size="sm" :label="$t('CRM.GENERAL.SAVE')" :is-loading="saving" :disabled="saving || !dirty || !valid" @click="save" />
  </section>
</template>
