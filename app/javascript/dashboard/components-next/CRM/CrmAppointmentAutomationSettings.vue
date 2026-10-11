<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';

const props = defineProps({
  pipeline: { type: Object, required: true },
  canManage: { type: Boolean, default: false },
  saving: { type: Boolean, default: false },
  medelementInstalled: { type: Boolean, default: false },
});
const draft = defineModel({ type: Object, required: true });
const { t } = useI18n();
const translate = key => {
  // eslint-disable-next-line @intlify/vue-i18n/no-dynamic-keys
  return t(`CRM.APPOINTMENT_AUTOMATION.${key}`);
};
const choices = keys =>
  keys.map(value => ({ value, label: translate(value.toUpperCase()) }));
const cardinalities = computed(() => choices(['request', 'appointment']));
const successModes = computed(() =>
  choices([
    'manual',
    'any_attended',
    'selected_attended',
    'all_required_attended',
  ])
);
const scopes = computed(() => choices(['any', 'all', 'selected', 'nearest']));
const conditions = computed(() =>
  choices([
    'provider_confirmed',
    'patient_confirmed',
    'scheduled',
    'attended',
    'cancelled',
    'no_show',
    'today',
    'tomorrow',
    'past',
    'future',
  ])
);
const manualModes = computed(() => choices(['continue', 'pause']));
// The prospective note stays visible whether creation is on or off, so it is
// part of the toggle description instead of a loose line under the block.
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
const stageFor = rule =>
  activeStages.value.find(stage => String(stage.id) === String(rule.stage_id));
const valid = computed(
  () =>
    !draft.value.enabled ||
    draft.value.rules?.every(rule => stageFor(rule) && rule.conditions.length)
);

const addRule = () =>
  draft.value.rules.push({
    stage_id: stages.value[0]?.value || null,
    scope: 'any',
    conditions: ['provider_confirmed'],
    closing_reasons: [],
  });
const moveRule = (index, offset) => {
  const target = index + offset;
  if (target < 0 || target >= draft.value.rules.length) return;
  const [rule] = draft.value.rules.splice(index, 1);
  draft.value.rules.splice(target, 0, rule);
};
const toggleCondition = (rule, value, checked) => {
  rule.conditions = checked
    ? [...rule.conditions, value]
    : rule.conditions.filter(condition => condition !== value);
};
const toggleReason = (rule, value, checked) => {
  rule.closing_reasons = checked
    ? [...rule.closing_reasons, value]
    : rule.closing_reasons.filter(reason => reason !== value);
};
const buildPayload = () =>
  valid.value
    ? {
        ...JSON.parse(JSON.stringify(draft.value)),
        rules: draft.value.rules.map(rule => ({
          stage_id: rule.stage_id,
          scope: rule.scope,
          conditions: [...rule.conditions],
          closing_reasons:
            stageFor(rule)?.outcome === 'lost' ? [...rule.closing_reasons] : [],
        })),
      }
    : null;
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
    <SettingsToggleSection
      v-model="draft.auto_create_deals"
      :header="$t('CRM.APPOINTMENT_AUTOMATION.AUTO_CREATE_DEALS')"
      :description="autoCreateDescription"
      :disabled="!canManage || saving"
      data-testid="appointment-auto-create-deals"
    >
      <template v-if="draft.auto_create_deals" #editor>
        <div class="flex flex-col gap-4 pt-2">
          <SchedulingSelectField
            v-model="draft.cardinality"
            :label="$t('CRM.APPOINTMENT_AUTOMATION.CARDINALITY')"
            :options="cardinalities"
            :disabled="!canManage || saving"
          />
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
        </div>
      </template>
    </SettingsToggleSection>
    <SettingsToggleSection
      v-model="draft.enabled"
      :header="$t('CRM.APPOINTMENT_AUTOMATION.ENABLED')"
      :disabled="!canManage || saving"
    >
      <template v-if="draft.enabled" #editor>
        <details>
          <summary class="cursor-pointer py-1 text-heading-3 text-n-slate-12">
            {{ $t('CRM.APPOINTMENT_AUTOMATION.RULES_TITLE') }}
          </summary>
          <div class="mt-3 flex flex-col gap-4">
            <div class="flex flex-col gap-1">
              <SchedulingSelectField
                v-model="draft.success_mode"
                :label="$t('CRM.APPOINTMENT_AUTOMATION.SUCCESS_LABEL')"
                :options="successModes"
                :disabled="!canManage || saving"
              />
              <p class="m-0 text-label-small text-n-slate-11">
                {{ $t('CRM.APPOINTMENT_AUTOMATION.PLAN_HELP') }}
              </p>
            </div>
            <div class="flex flex-col gap-1">
              <SchedulingSelectField
                v-model="draft.manual_stage_change"
                :label="$t('CRM.APPOINTMENT_AUTOMATION.MANUAL_LABEL')"
                :options="manualModes"
                :disabled="!canManage || saving"
              />
              <p class="m-0 text-label-small text-n-slate-11">
                {{ $t('CRM.APPOINTMENT_AUTOMATION.RULES_HELP') }}
              </p>
            </div>
            <div
              v-if="draft.rules.length"
              class="flex flex-col divide-y divide-n-weak border-y border-n-weak"
            >
              <fieldset
                v-for="(rule, index) in draft.rules"
                :key="index"
                :disabled="!canManage || saving"
                class="grid min-w-0 gap-3 py-3"
              >
                <div class="flex items-center justify-between gap-1">
                  <span class="text-heading-3 text-n-slate-12">{{
                    $t('CRM.APPOINTMENT_AUTOMATION.RULE_NUMBER', {
                      number: index + 1,
                    })
                  }}</span>
                  <div class="flex gap-1">
                    <Button
                      icon="i-lucide-arrow-up"
                      size="xs"
                      color="slate"
                      variant="ghost"
                      :aria-label="$t('CRM.APPOINTMENT_AUTOMATION.MOVE_UP')"
                      :disabled="!canManage || index === 0 || saving"
                      @click="moveRule(index, -1)"
                    />
                    <Button
                      icon="i-lucide-arrow-down"
                      size="xs"
                      color="slate"
                      variant="ghost"
                      :aria-label="$t('CRM.APPOINTMENT_AUTOMATION.MOVE_DOWN')"
                      :disabled="
                        !canManage || index === draft.rules.length - 1 || saving
                      "
                      @click="moveRule(index, 1)"
                    />
                    <Button
                      icon="i-lucide-trash-2"
                      size="xs"
                      color="slate"
                      variant="ghost"
                      :aria-label="$t('CRM.APPOINTMENT_AUTOMATION.REMOVE')"
                      :disabled="!canManage || saving"
                      @click="draft.rules.splice(index, 1)"
                    />
                  </div>
                </div>
                <SchedulingSelectField
                  v-model="rule.stage_id"
                  :label="$t('CRM.APPOINTMENT_AUTOMATION.STAGE')"
                  :options="stages"
                  :disabled="!canManage || saving"
                />
                <SchedulingSelectField
                  v-model="rule.scope"
                  :label="$t('CRM.APPOINTMENT_AUTOMATION.SCOPE')"
                  :options="scopes"
                  :disabled="!canManage || saving"
                />
                <label
                  v-for="condition in conditions"
                  :key="condition.value"
                  class="flex items-center gap-2 text-sm font-normal text-n-slate-12"
                >
                  <input
                    type="checkbox"
                    :checked="rule.conditions.includes(condition.value)"
                    @change="
                      toggleCondition(
                        rule,
                        condition.value,
                        $event.target.checked
                      )
                    "
                  />
                  <span>{{ condition.label }}</span>
                </label>
                <template
                  v-if="
                    stageFor(rule)?.outcome === 'lost' &&
                    stageFor(rule)?.closingReasonOptions?.length
                  "
                >
                  <span class="text-heading-3 text-n-slate-12">{{
                    $t('CRM.APPOINTMENT_AUTOMATION.CLOSING_REASONS')
                  }}</span>
                  <label
                    v-for="reason in stageFor(rule).closingReasonOptions"
                    :key="reason"
                    class="flex items-center gap-2 text-sm font-normal text-n-slate-12"
                  >
                    <input
                      type="checkbox"
                      :checked="rule.closing_reasons.includes(reason)"
                      @change="
                        toggleReason(rule, reason, $event.target.checked)
                      "
                    />
                    <span>{{ reason }}</span>
                  </label>
                </template>
              </fieldset>
            </div>
            <Button
              size="sm"
              color="slate"
              variant="faded"
              icon="i-lucide-plus"
              :label="$t('CRM.APPOINTMENT_AUTOMATION.ADD_RULE')"
              :disabled="!canManage || saving || draft.rules.length >= 50"
              @click="addRule"
            />
          </div>
        </details>
      </template>
    </SettingsToggleSection>
  </section>
</template>
