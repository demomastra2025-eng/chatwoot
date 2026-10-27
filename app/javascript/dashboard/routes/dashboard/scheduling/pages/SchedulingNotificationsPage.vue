<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import AutomationAPI from 'dashboard/api/automation';
import ResourcesAPI from 'dashboard/api/scheduling/resources';
import ServicesAPI from 'dashboard/api/scheduling/services';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import { getTemplateParameterDefinitions } from 'dashboard/helper/whatsappTemplateLibrary';
import {
  APPOINTMENT_SEMANTIC_VARIABLES,
  buildFieldReferenceForSemanticKey,
  findSemanticVariableByFieldId,
} from 'dashboard/helper/appointmentTemplatePresets';
import { extractSingleTemplateFieldReference } from 'dashboard/helper/templateFieldReferences';
import {
  APPOINTMENT_NOTIFICATION_EVENTS,
  eventKeyForRule,
  presetRows,
  scheduleFor,
  touchParams,
} from '../calendarNotificationRules';

const { t } = useI18n();
const route = useRoute();
const store = useStore();
const { currentAccount } = useAccount();
const allRules = useMapGetter('automations/getAutomations');
const inboxes = useMapGetter('inboxes/getInboxes');
const resources = ref([]);
const services = ref([]);
const editing = ref(false);
const saving = ref(false);
const draft = reactive({});
const L = key => t(`SCHEDULING.NOTIFICATIONS.${key}`);
const eventLabel = key => L(`EVENTS.${key.toUpperCase()}`);
const notificationRules = computed(() =>
  (allRules.value || []).filter(rule =>
    APPOINTMENT_NOTIFICATION_EVENTS.some(
      event => event.eventName === rule.event_name
    )
  )
);
const missingPresets = computed(() => presetRows(notificationRules.value));
const selectedInbox = computed(() =>
  (inboxes.value || []).find(item => String(item.id) === String(draft.inboxId))
);
const templates = computed(
  () =>
    selectedInbox.value?.message_templates ||
    selectedInbox.value?.messageTemplates ||
    []
);
const selectedTemplate = computed(() =>
  templates.value.find(
    item => `${item.name}::${item.language || 'ru'}` === draft.templateKey
  )
);
const templateVars = computed(() =>
  selectedTemplate.value
    ? getTemplateParameterDefinitions(selectedTemplate.value)
        .filter(item => item.section === 'body')
        .map(item => item.key.replace(/^body\./, ''))
    : []
);
const hasConfirmButton = computed(() => {
  const buttons =
    selectedTemplate.value?.components?.find(
      item => String(item.type).toUpperCase() === 'BUTTONS'
    )?.buttons || [];
  return (
    buttons.length === 1 &&
    String(buttons[0].type).toUpperCase() === 'QUICK_REPLY'
  );
});
const conditionFields = [
  'service_id',
  'resource_id',
  'medelement_cabinet_code',
  'status',
  'source',
];
const conditionOptions = computed(() => ({
  service_id: services.value.map(item => ({
    value: String(item.id),
    label: item.name,
  })),
  resource_id: resources.value.map(item => ({
    value: String(item.id),
    label: item.name,
  })),
  medelement_cabinet_code: [],
  status: ['scheduled', 'confirmed', 'completed', 'cancelled', 'no_show'].map(
    value => ({
      value,
      label: L(`STATUS.${value.toUpperCase()}`),
    })
  ),
  source: ['manual', 'medelement', 'captain'].map(value => ({
    value,
    label: value,
  })),
}));
const firstTouch = rule =>
  rule?.actions?.find(item => item.action_name === 'create_touch');
const timeParts = seconds => {
  if (seconds && seconds % 86400 === 0)
    return { amount: seconds / 86400, unit: 86400, label: 'DAYS' };
  if (seconds && seconds % 3600 === 0)
    return { amount: seconds / 3600, unit: 3600, label: 'HOURS' };
  return { amount: seconds / 60, unit: 60, label: 'MINUTES' };
};
const summary = rule => {
  const params = touchParams(rule);
  const amount = Math.abs(Number(params.relative_offset_seconds || 0));
  let timing = 'AT_TIME';
  if (amount === 0 && params.relative_anchor === 'touch.created_at')
    timing = 'IMMEDIATE';
  if (Number(params.relative_offset_seconds) < 0) timing = 'BEFORE';
  if (Number(params.relative_offset_seconds) > 0) timing = 'AFTER';
  const parts = timeParts(amount);
  const interval = amount ? ` ${parts.amount} ${L(parts.label)}` : '';
  return `${L(`TIMING.${timing}`)}${interval}${params.relative_time_of_day ? ` · ${params.relative_time_of_day}` : ''}`;
};
const conditionSummary = rule =>
  (rule.conditions || []).filter(
    item =>
      !(
        item.attribute_key === 'source' && item.filter_operator === 'is_present'
      )
  ).length;
const newDraft = (rule = null, preset = null) => {
  const params = touchParams(rule);
  let eventKey = 'created';
  if (rule) eventKey = eventKeyForRule(rule);
  else if (
    preset?.eventName === 'appointment_created' &&
    preset.relativeAnchor === 'appointment.starts_at'
  )
    eventKey = 'started';
  else if (preset)
    eventKey =
      APPOINTMENT_NOTIFICATION_EVENTS.find(
        item => item.eventName === preset.eventName
      )?.key || 'created';
  const offset = Number(
    params.relative_offset_seconds ?? preset?.relativeOffsetSeconds ?? 0
  );
  const anchor =
    params.relative_anchor || preset?.relativeAnchor || 'touch.created_at';
  const seconds = Math.abs(offset);
  let timing = anchor === 'touch.created_at' ? 'immediate' : 'at_time';
  if (offset < 0) timing = 'before';
  if (offset > 0) timing = 'after';
  const parts = timeParts(seconds);
  const bindings = Object.fromEntries(
    Object.entries(params.template_params?.processed_params?.body || {}).map(
      ([key, value]) => {
        const field = extractSingleTemplateFieldReference(value);
        return [key, findSemanticVariableByFieldId(field?.fieldId)?.key || ''];
      }
    )
  );
  const presetTemplate = templates.value.find(
    item => item.name === preset?.templateName
  );
  let templateKey = '';
  if (params.template_params?.name)
    templateKey = `${params.template_params.name}::${params.template_params.language || 'ru'}`;
  else if (presetTemplate)
    templateKey = `${presetTemplate.name}::${presetTemplate.language || 'ru'}`;
  Object.assign(draft, {
    id: rule?.id || null,
    presetKey: preset?.key || '',
    name:
      rule?.name ||
      (preset ? t(`SCHEDULING.REMINDERS.PRESETS.${preset.key}.TITLE`) : ''),
    description: rule?.description || '',
    eventKey,
    timing,
    amount: parts.amount,
    unit: parts.unit,
    exactTime: params.relative_time_of_day || preset?.relativeTimeOfDay || '',
    inboxId: params.target_inbox_id || inboxes.value?.[0]?.id || '',
    contentKind:
      params.content_kind || (preset ? 'channel_template' : 'free_text'),
    body: params.body || '',
    templateKey,
    bindings,
    confirm: params.response_action === 'confirm_appointment',
    conditions: (rule?.conditions || [])
      .filter(
        item =>
          conditionFields.includes(item.attribute_key) &&
          !(
            item.attribute_key === 'source' &&
            item.filter_operator === 'is_present'
          )
      )
      .map(item => ({
        field: item.attribute_key,
        value: item.values?.[0] || '',
        operator: item.filter_operator,
        original: item,
      })),
    originalRule: rule,
  });
  editing.value = true;
};
const save = async () => {
  if (!draft.name.trim() || !draft.inboxId) {
    useAlert(L('REQUIRED'));
    return;
  }
  if (
    ['before', 'after'].includes(draft.timing) &&
    (!Number.isInteger(Number(draft.amount)) || Number(draft.amount) < 1)
  ) {
    useAlert(L('REQUIRED'));
    return;
  }
  if (draft.contentKind === 'free_text' && !draft.body.trim()) {
    useAlert(L('REQUIRED'));
    return;
  }
  if (
    draft.contentKind === 'channel_template' &&
    (!selectedTemplate.value ||
      String(selectedTemplate.value.status).toUpperCase() !== 'APPROVED')
  ) {
    useAlert(L('APPROVED_TEMPLATE_REQUIRED'));
    return;
  }
  if (draft.confirm && !hasConfirmButton.value) {
    useAlert(L('CONFIRM_TEMPLATE_REQUIRED'));
    return;
  }
  if (
    templateVars.value.some(key => !draft.bindings[key]) &&
    draft.contentKind === 'channel_template'
  ) {
    useAlert(L('BINDINGS_REQUIRED'));
    return;
  }
  const schedule = scheduleFor(
    draft.eventKey,
    draft.timing,
    draft.amount,
    draft.unit
  );
  const event = APPOINTMENT_NOTIFICATION_EVENTS.find(
    item => item.key === draft.eventKey
  );
  const params = {
    ...touchParams(draft.originalRule),
    action_type: 'send_message',
    content_kind: draft.contentKind,
    timing_mode: 'relative',
    ...schedule,
    target_inbox_id: Number(draft.inboxId),
    timezone: currentAccount.value?.workspace_working_hours_timezone || 'UTC',
    repeat_mode: 'once',
    relative_time_mode:
      draft.exactTime && draft.unit === 86400
        ? 'fixed_time_of_day'
        : 'inherit_anchor_time',
    relative_time_of_day:
      draft.exactTime && draft.unit === 86400 ? draft.exactTime : '',
    response_action: draft.confirm ? 'confirm_appointment' : '',
    response_button_index: draft.confirm ? 0 : '',
  };
  if (draft.contentKind === 'free_text') {
    params.body = draft.body;
    params.template_params = {};
  } else {
    params.body = '';
    params.template_params = {
      name: selectedTemplate.value.name,
      language: selectedTemplate.value.language || 'ru',
      category: selectedTemplate.value.category || 'UTILITY',
      processed_params: {
        body: Object.fromEntries(
          templateVars.value.map(key => [
            key,
            buildFieldReferenceForSemanticKey(draft.bindings[key]),
          ])
        ),
      },
    };
  }
  const conditionPayload = item => {
    const unchanged =
      item.original &&
      item.field === item.original.attribute_key &&
      item.operator === item.original.filter_operator &&
      String(item.value) === String(item.original.values?.[0]);
    if (unchanged) return item.original;
    return {
      attribute_key: item.field,
      filter_operator: item.operator || 'equal_to',
      values: [String(item.value)],
      query_operator: item.original ? item.original.query_operator : 'AND',
    };
  };
  const originalConditions = draft.originalRule?.conditions || [];
  const conditions = originalConditions.flatMap(original => {
    const edited = draft.conditions.find(item => item.original === original);
    if (edited) return edited.value ? [conditionPayload(edited)] : [];
    return conditionFields.includes(original.attribute_key) ? [] : [original];
  });
  conditions.push(
    ...draft.conditions
      .filter(item => !item.original && item.value)
      .map(conditionPayload)
  );
  if (!conditions.length)
    conditions.push({
      attribute_key: 'source',
      filter_operator: 'is_present',
      values: [],
      query_operator: null,
    });
  const originalAction = firstTouch(draft.originalRule);
  const trailingParams = Array.isArray(originalAction?.action_params)
    ? originalAction.action_params.slice(1)
    : [];
  const actions = draft.originalRule?.actions?.length
    ? draft.originalRule.actions.map(item =>
        item === originalAction
          ? { ...item, action_params: [params, ...trailingParams] }
          : item
      )
    : [{ action_name: 'create_touch', action_params: [params] }];
  const payload = {
    name: draft.name.trim(),
    description: draft.description,
    event_name: event.eventName,
    active: draft.originalRule?.active ?? false,
    conditions,
    actions,
    calendar_managed: true,
    calendar_context: true,
  };
  saving.value = true;
  try {
    if (draft.id) await AutomationAPI.update(draft.id, payload);
    else await AutomationAPI.create(payload);
    await store.dispatch('automations/get');
    editing.value = false;
    useAlert(L('SAVED'));
  } catch (error) {
    useAlert(error?.response?.data?.errors?.[0]?.message || L('SAVE_ERROR'));
  } finally {
    saving.value = false;
  }
};
const toggle = async rule => {
  try {
    await AutomationAPI.update(rule.id, {
      active: !rule.active,
      calendar_context: true,
    });
    await store.dispatch('automations/get');
  } catch {
    useAlert(L('SAVE_ERROR'));
  }
};
onMounted(async () => {
  await Promise.all([
    store.dispatch('automations/get'),
    store.dispatch('inboxes/get'),
    ResourcesAPI.get()
      .then(response => {
        resources.value = response.data.payload || [];
      })
      .catch(() => {}),
    ServicesAPI.get()
      .then(response => {
        services.value = response.data.payload || [];
      })
      .catch(() => {}),
  ]);
  const selected = notificationRules.value.find(
    rule => String(rule.id) === String(route.query.rule)
  );
  if (selected) newDraft(selected);
});
</script>

<template>
  <div class="flex h-full min-h-0 flex-col bg-n-surface-1">
    <SchedulingPageHeader :title="L('TITLE')" :subtitle="L('SUBTITLE')" />
    <div class="flex-1 overflow-y-auto p-4 sm:p-6">
      <div class="mx-auto max-w-5xl space-y-3">
        <button
          type="button"
          class="rounded-lg bg-n-brand px-4 py-2 text-white"
          @click="newDraft()"
        >
          {{ L('ADD') }}
        </button>
        <div
          v-for="rule in notificationRules"
          :key="rule.id"
          class="flex flex-wrap items-center gap-3 rounded-xl border border-n-weak bg-n-solid-2 p-4"
        >
          <div class="min-w-0 flex-1">
            <p class="m-0 font-semibold text-n-slate-12">{{ rule.name }}</p>
            <p class="m-0 text-sm text-n-slate-11">
              {{ eventLabel(eventKeyForRule(rule)) }} · {{ summary(rule) }} ·
              {{
                touchParams(rule).template_params?.name ||
                touchParams(rule).body ||
                L('NO_CONTENT')
              }}
              · {{ L('CONDITIONS') }}: {{ conditionSummary(rule) }}
            </p>
          </div>
          <span v-if="!rule.calendar_managed" class="text-sm text-n-amber-11">{{
            L(firstTouch(rule) ? 'ADOPTION_REQUIRED' : 'MANAGE_IN_AUTOMATIONS')
          }}</span>
          <template v-else>
            <button type="button" class="text-n-brand" @click="newDraft(rule)">
              {{ L('EDIT') }}
            </button>
            <button type="button" class="text-n-brand" @click="toggle(rule)">
              {{ rule.active ? L('DISABLE') : L('ENABLE') }}
            </button>
          </template>
        </div>
        <h2 class="text-base font-semibold text-n-slate-12">
          {{ L('PRESETS') }}
        </h2>
        <div
          v-for="preset in missingPresets"
          :key="preset.key"
          class="flex items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-solid-2 p-4"
        >
          <span>{{
            t(`SCHEDULING.REMINDERS.PRESETS.${preset.key}.TITLE`)
          }}</span>
          <button
            type="button"
            class="text-n-brand"
            @click="newDraft(null, preset)"
          >
            {{ L('SET_UP') }}
          </button>
        </div>
        <section
          v-if="editing"
          class="space-y-4 rounded-xl border border-n-weak bg-n-solid-2 p-4"
          data-testid="calendar-notification-editor"
        >
          <h2 class="text-base font-semibold">
            {{ draft.id ? L('EDIT') : L('ADD') }}
          </h2>
          <label class="block"
            >{{ L('NAME')
            }}<input
              v-model="draft.name"
              class="w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
          /></label>
          <div class="grid gap-3 sm:grid-cols-2">
            <label
              >{{ L('EVENT')
              }}<select
                v-model="draft.eventKey"
                class="w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
              >
                <option
                  v-for="event in APPOINTMENT_NOTIFICATION_EVENTS"
                  :key="event.key"
                  :value="event.key"
                >
                  {{ eventLabel(event.key) }}
                </option>
              </select></label
            >
            <label
              >{{ L('TIMING_LABEL')
              }}<select
                v-model="draft.timing"
                class="w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
              >
                <option
                  v-for="key in ['immediate', 'at_time', 'before', 'after']"
                  :key="key"
                  :value="key"
                >
                  {{ L(`TIMING.${key.toUpperCase()}`) }}
                </option>
              </select></label
            >
            <template
              v-if="draft.timing === 'before' || draft.timing === 'after'"
            >
              <label
                >{{ L('AMOUNT')
                }}<input
                  v-model.number="draft.amount"
                  type="number"
                  min="1"
                  class="w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
              /></label>
              <label
                >{{ L('UNIT')
                }}<select
                  v-model.number="draft.unit"
                  class="w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
                >
                  <option :value="60">{{ L('MINUTES') }}</option>
                  <option :value="3600">{{ L('HOURS') }}</option>
                  <option :value="86400">{{ L('DAYS') }}</option>
                </select></label
              >
              <label v-if="draft.unit === 86400"
                >{{ L('EXACT_TIME')
                }}<input
                  v-model="draft.exactTime"
                  type="time"
                  class="w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
              /></label>
            </template>
            <label
              >{{ L('CHANNEL')
              }}<select
                v-model="draft.inboxId"
                class="w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
              >
                <option
                  v-for="inbox in inboxes"
                  :key="inbox.id"
                  :value="inbox.id"
                >
                  {{ inbox.name }}
                </option>
              </select></label
            >
            <label
              >{{ L('CONTENT')
              }}<select
                v-model="draft.contentKind"
                class="w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
              >
                <option value="free_text">{{ L('TEXT') }}</option>
                <option value="channel_template">{{ L('TEMPLATE') }}</option>
              </select></label
            >
          </div>
          <label v-if="draft.contentKind === 'free_text'" class="block">
            {{ L('TEXT') }}
            <textarea
              v-model="draft.body"
              rows="4"
              class="w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
            />
          </label>
          <template v-else>
            <label class="block"
              >{{ L('TEMPLATE')
              }}<select
                v-model="draft.templateKey"
                class="w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
              >
                <option value="">{{ L('CHOOSE') }}</option>
                <option
                  v-for="template in templates"
                  :key="`${template.name}::${template.language}`"
                  :value="`${template.name}::${template.language || 'ru'}`"
                >
                  {{ template.name }} ({{ template.language }})
                </option>
              </select></label
            >
            <label v-for="key in templateVars" :key="key" class="block">
              {{ key }}
              <select
                v-model="draft.bindings[key]"
                class="w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
              >
                <option value="">{{ L('CHOOSE') }}</option>
                <option
                  v-for="field in APPOINTMENT_SEMANTIC_VARIABLES"
                  :key="field.key"
                  :value="field.key"
                >
                  {{ field.fieldTitle }}
                </option>
              </select></label
            >
            <label class="flex items-center gap-2"
              ><input
                v-model="draft.confirm"
                type="checkbox"
                :disabled="!hasConfirmButton"
              />{{ L('CONFIRM') }}</label
            >
          </template>
          <div class="space-y-2">
            <h3 class="font-semibold">{{ L('CONDITIONS') }}</h3>
            <div
              v-for="(condition, index) in draft.conditions"
              :key="index"
              class="flex flex-wrap gap-2"
            >
              <select
                v-model="condition.field"
                class="rounded-lg border border-n-weak bg-n-surface-1 p-2"
              >
                <option
                  v-for="field in conditionFields"
                  :key="field"
                  :value="field"
                >
                  {{ L(`FIELDS.${field.toUpperCase()}`) }}
                </option>
              </select>
              <select
                v-model="condition.operator"
                class="rounded-lg border border-n-weak bg-n-surface-1 p-2"
              >
                <option value="equal_to">{{ L('IS') }}</option>
                <option value="not_equal_to">{{ L('IS_NOT') }}</option>
              </select>
              <select
                v-if="conditionOptions[condition.field]?.length"
                v-model="condition.value"
                class="rounded-lg border border-n-weak bg-n-surface-1 p-2"
              >
                <option value="">{{ L('CHOOSE') }}</option>
                <option
                  v-for="option in conditionOptions[condition.field]"
                  :key="option.value"
                  :value="option.value"
                >
                  {{ option.label }}
                </option>
              </select>
              <input
                v-else
                v-model="condition.value"
                class="rounded-lg border border-n-weak bg-n-surface-1 p-2"
                :aria-label="L(`FIELDS.${condition.field.toUpperCase()}`)"
              />
              <button
                type="button"
                class="text-n-ruby-11"
                @click="draft.conditions.splice(index, 1)"
              >
                {{ L('REMOVE') }}
              </button>
            </div>
            <button
              type="button"
              class="text-n-brand"
              @click="
                draft.conditions.push({
                  field: 'service_id',
                  operator: 'equal_to',
                  value: '',
                })
              "
            >
              {{ L('ADD_CONDITION') }}
            </button>
          </div>
          <div class="flex gap-3">
            <button
              type="button"
              class="rounded-lg bg-n-brand px-4 py-2 text-white"
              :disabled="saving"
              @click="save"
            >
              {{ L('SAVE') }}</button
            ><button type="button" @click="editing = false">
              {{ L('CANCEL') }}
            </button>
          </div>
        </section>
      </div>
    </div>
  </div>
</template>
