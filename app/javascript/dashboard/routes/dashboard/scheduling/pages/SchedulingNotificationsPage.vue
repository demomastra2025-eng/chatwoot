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
import CabinetsAPI from 'dashboard/api/scheduling/cabinets';
import CrmFieldDefinitionsAPI from 'dashboard/api/crm/fieldDefinitions';
import SchedulingPageHeader from 'dashboard/components-next/Scheduling/SchedulingPageHeader.vue';
import AppointmentTemplatePackDialog from 'dashboard/components-next/Scheduling/AppointmentTemplatePackDialog.vue';
import CreateWhatsAppTemplateDialog from 'dashboard/routes/dashboard/settings/inbox/settingsPage/components/CreateWhatsAppTemplateDialog.vue';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import {
  getTemplateBodyPreview,
  getTemplateParameterDefinitions,
} from 'dashboard/helper/whatsappTemplateLibrary';
import {
  APPOINTMENT_REMINDER_PRESETS,
  APPOINTMENT_SEMANTIC_VARIABLES,
  buildFieldReferenceForSemanticKey,
  buildPresetMarker,
  extractPresetKeyFromRule,
  findSemanticVariableByFieldId,
} from 'dashboard/helper/appointmentTemplatePresets';
import { extractSingleTemplateFieldReference } from 'dashboard/helper/templateFieldReferences';
import {
  appointmentFieldIds,
  blockingFieldStats,
  fetchAppointmentFieldFill,
} from 'dashboard/helper/appointmentFieldFill';
import {
  APPOINTMENT_NOTIFICATION_EVENTS,
  eventKeyForRule,
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
const cabinets = ref([]);
const customFields = ref([]);
const selectedInboxId = ref('');
const templatePackDialogRef = ref(null);
const createTemplateDialogRef = ref(null);
const reviewingRule = ref(null);
const adopting = ref(false);
const syncing = ref(false);
const step = ref(1);
const generatedPackDrafts = ref([]);
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
const whatsAppInboxes = computed(() =>
  (inboxes.value || []).filter(
    item => (item.channel_type || item.channelType) === INBOX_TYPES.WHATSAPP
  )
);
const pageInbox = computed(() =>
  whatsAppInboxes.value.find(
    item => String(item.id) === String(selectedInboxId.value)
  )
);
const pageTemplates = computed(
  () =>
    pageInbox.value?.message_templates ||
    pageInbox.value?.messageTemplates ||
    []
);
const presetTemplate = preset =>
  pageTemplates.value.find(item => item.name === preset.templateName);
const presetTemplateStatus = preset => {
  const template = presetTemplate(preset);
  return template
    ? L(`TEMPLATE_STATUS.${String(template.status || 'PENDING').toUpperCase()}`)
    : L('NO_TEMPLATE');
};
const templateCount = status =>
  pageTemplates.value.filter(
    item => String(item.status).toUpperCase() === status
  ).length;
const presetRule = preset =>
  notificationRules.value.find(
    rule => extractPresetKeyFromRule(rule) === preset.key
  );
const otherRules = computed(() => {
  const featuredIds = new Set(
    APPOINTMENT_REMINDER_PRESETS.map(preset => presetRule(preset)?.id).filter(
      Boolean
    )
  );
  return notificationRules.value.filter(rule => !featuredIds.has(rule.id));
});
const templateForParams = params => {
  const inbox = whatsAppInboxes.value.find(
    item => String(item.id) === String(params?.target_inbox_id)
  );
  return (inbox?.message_templates || inbox?.messageTemplates || []).find(
    item =>
      item.name === params?.template_params?.name &&
      (item.language || 'ru') === (params?.template_params?.language || 'ru')
  );
};
const ruleTemplate = rule => templateForParams(touchParams(rule));
const reviewTouches = computed(() =>
  (reviewingRule.value?.actions || []).flatMap(action => {
    const params = Array.isArray(action.action_params)
      ? action.action_params
      : [action.action_params];
    return params.map(item => ({
      action_name: action.action_name,
      action_params: item,
    }));
  })
);
const reviewChannel = params =>
  (inboxes.value || []).find(
    item => String(item.id) === String(params?.target_inbox_id)
  )?.name || L('NO_CHANNEL');
const reviewTemplateStatus = params => {
  const template = templateForParams(params);
  return template
    ? L(`TEMPLATE_STATUS.${String(template.status || 'PENDING').toUpperCase()}`)
    : L('NO_TEMPLATE');
};
const templateStatus = rule => {
  const template = ruleTemplate(rule);
  return template
    ? L(`TEMPLATE_STATUS.${String(template.status || 'PENDING').toUpperCase()}`)
    : L('NO_TEMPLATE');
};
const canEnable = rule =>
  rule &&
  rule.calendar_managed &&
  (touchParams(rule).content_kind === 'free_text' ||
    (touchParams(rule).body && !touchParams(rule).content_kind) ||
    String(ruleTemplate(rule)?.status).toUpperCase() === 'APPROVED');
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
const templateButtons = computed(
  () =>
    selectedTemplate.value?.components?.find(
      item => String(item.type).toUpperCase() === 'BUTTONS'
    )?.buttons || []
);
const hasConfirmButton = computed(() => {
  const buttons = templateButtons.value;
  return (
    buttons.length === 1 &&
    String(buttons[0].type).toUpperCase() === 'QUICK_REPLY'
  );
});
const standardConditionFields = [
  'service_id',
  'resource_id',
  'medelement_cabinet_code',
  'status',
  'source',
  'appointment_source',
  'lead_time_minutes',
  'appointment_type',
  'payment_status',
];
const conditionFields = computed(() => [
  ...standardConditionFields,
  ...customFields.value.filter(item => item.active).map(item => item.key),
]);
const fieldLabel = field =>
  customFields.value.find(item => item.key === field)?.label ||
  L(`FIELDS.${field.toUpperCase()}`);
const operatorsFor = field => {
  const definition = customFields.value.find(item => item.key === field);
  const base = ['equal_to', 'not_equal_to'];
  if (
    field === 'source' ||
    ['text', 'textarea', 'url'].includes(definition?.field_type)
  )
    return [
      ...base,
      'contains',
      'does_not_contain',
      'starts_with',
      'is_present',
      'is_not_present',
    ];
  if (
    field === 'lead_time_minutes' ||
    ['number', 'currency', 'percent', 'date', 'datetime'].includes(
      definition?.field_type
    )
  )
    return [
      ...base,
      'is_greater_than',
      'is_less_than',
      'is_present',
      'is_not_present',
    ];
  return definition ? [...base, 'is_present', 'is_not_present'] : base;
};
const noValueOperator = operator =>
  ['is_present', 'is_not_present'].includes(operator);
const conditionOptions = computed(() => ({
  service_id: services.value.map(item => ({
    value: String(item.id),
    label: item.name,
  })),
  resource_id: resources.value.map(item => ({
    value: String(item.id),
    label: item.name,
  })),
  medelement_cabinet_code: cabinets.value.map(item => ({
    value: item.code,
    label: item.name || item.number || item.code,
  })),
  status: ['scheduled', 'confirmed', 'completed', 'cancelled', 'no_show'].map(
    value => ({
      value,
      label: L(`STATUS.${value.toUpperCase()}`),
    })
  ),
  source: ['manual', 'medelement', 'captain'].map(value => ({
    value,
    label: t(`SCHEDULING.APPOINTMENT_SOURCE.${value}`),
  })),
  appointment_source: ['onelink', 'medelement'].map(value => ({
    value,
    label: L(`BOOKING_SOURCE.${value.toUpperCase()}`),
  })),
  appointment_type: ['primary', 'secondary', 'other'].map(value => ({
    value,
    label: t(`SCHEDULING.APPOINTMENT_TYPE.${value}`),
  })),
  payment_status: ['awaiting_payment', 'prepaid', 'paid', 'cancelled'].map(
    value => ({ value, label: t(`SCHEDULING.PAYMENT_STATUS.${value}`) })
  ),
  ...Object.fromEntries(
    customFields.value
      .filter(item =>
        ['select', 'multiselect', 'checkbox'].includes(item.field_type)
      )
      .map(item => [
        item.key,
        item.field_type === 'checkbox'
          ? [
              { value: 'true', label: L('YES') },
              { value: 'false', label: L('NO') },
            ]
          : (item.options || []).map(option => ({
              value: String(option.value || option),
              label: String(option.label || option.value || option),
            })),
      ])
  ),
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
const unitInWords = (amount, unit) => {
  const category = new Intl.PluralRules('ru').select(amount);
  return L(`UNIT_WORDS.${unit}.${category.toUpperCase()}`);
};
const summary = rule => {
  const params = touchParams(rule);
  if (
    !params.relative_anchor ||
    params.relative_offset_seconds === null ||
    params.relative_offset_seconds === undefined ||
    !Number.isFinite(Number(params.relative_offset_seconds))
  )
    return L('SEND_PLAN_INVALID');
  const amount = Math.abs(Number(params.relative_offset_seconds || 0));
  let timing = 'AT_TIME';
  if (amount === 0 && params.relative_anchor === 'touch.created_at')
    timing = 'IMMEDIATE';
  if (Number(params.relative_offset_seconds) < 0) timing = 'BEFORE';
  if (Number(params.relative_offset_seconds) > 0) timing = 'AFTER';
  const parts = timeParts(amount);
  const interval = amount
    ? ` ${parts.amount} ${unitInWords(parts.amount, parts.label)}`
    : '';
  let anchor = L('RULE_EVENT');
  if (params.relative_anchor === 'appointment.starts_at')
    anchor = L('VISIT_START');
  if (params.relative_anchor === 'appointment.ends_at') anchor = L('VISIT_END');
  let context = '';
  if (timing === 'BEFORE') context = ` ${L('BEFORE_ANCHOR')} ${anchor}`;
  if (timing === 'AFTER') context = ` ${L('AFTER_ANCHOR')} ${anchor}`;
  if (timing === 'AT_TIME') context = ` ${anchor}`;
  return `${L(`TIMING.${timing}`)}${interval}${context}${params.relative_time_of_day ? ` · ${params.relative_time_of_day}` : ''}`;
};
const visibleConditions = rule =>
  (rule?.conditions || []).filter(
    item =>
      !(
        item.attribute_key === 'source' && item.filter_operator === 'is_present'
      )
  );
const conditionText = condition => {
  const field = fieldLabel(condition.attribute_key);
  const operator = L(
    `OPERATORS.${String(condition.filter_operator).toUpperCase()}`
  );
  const values = Array(condition.values || []).map(
    value =>
      conditionOptions.value[condition.attribute_key]?.find(
        option => String(option.value) === String(value)
      )?.label || value
  );
  return `${field} ${operator} ${values.join(', ')}`.trim();
};
const conditionsSummaryText = rule =>
  visibleConditions(rule).map(conditionText).join(' · ') || L('NO_CONDITIONS');
const newDraft = (rule = null, preset = null) => {
  if (rule && !rule.calendar_managed) {
    reviewingRule.value = rule;
    return;
  }
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
  const packDraft = generatedPackDrafts.value.find(
    item => item.presetKey === preset?.key
  );
  if (!rule && packDraft?.semanticKeyMap)
    Object.assign(bindings, packDraft.semanticKeyMap);
  const matchingPresetTemplate = pageTemplates.value.find(
    item => item.name === (packDraft?.name || preset?.templateName)
  );
  let templateKey = '';
  if (params.template_params?.name)
    templateKey = `${params.template_params.name}::${params.template_params.language || 'ru'}`;
  else if (matchingPresetTemplate)
    templateKey = `${matchingPresetTemplate.name}::${matchingPresetTemplate.language || 'ru'}`;
  Object.assign(draft, {
    id: rule?.id || null,
    presetKey: preset?.key || extractPresetKeyFromRule(rule) || '',
    name:
      rule?.name ||
      (preset ? t(`SCHEDULING.REMINDERS.PRESETS.${preset.key}.TITLE`) : ''),
    description: rule?.description || '',
    eventKey,
    timing,
    amount: parts.amount,
    unit: parts.unit,
    exactTime: params.relative_time_of_day || preset?.relativeTimeOfDay || '',
    inboxId: params.target_inbox_id || selectedInboxId.value || '',
    contentKind:
      params.content_kind || (preset ? 'channel_template' : 'free_text'),
    body: params.body || '',
    templateKey,
    bindings,
    confirm: params.response_action === 'confirm_appointment',
    conditions: (rule?.conditions || [])
      .filter(
        item =>
          conditionFields.value.includes(item.attribute_key) &&
          !(
            item.attribute_key === 'source' &&
            item.filter_operator === 'is_present'
          )
      )
      .map(item => ({
        field: item.attribute_key,
        value: item.values?.[0] || '',
        operator: item.filter_operator,
        queryOperator: item.query_operator || 'AND',
        original: item,
      })),
    originalRule: rule,
  });
  editing.value = true;
  step.value = 1;
};
const save = async active => {
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
  if (
    ['before', 'after'].includes(draft.timing) &&
    Number(draft.unit) === 86400 &&
    !/^([01]\d|2[0-3]):[0-5]\d$/.test(draft.exactTime || '')
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
    draft.conditions.some(
      item =>
        !item.field ||
        (!noValueOperator(item.operator) && !String(item.value || '').trim())
    )
  ) {
    useAlert(L('REQUIRED'));
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
  const fixedTime =
    ['before', 'after'].includes(draft.timing) && Number(draft.unit) === 86400;
  const params = {
    ...touchParams(draft.originalRule),
    action_type: 'send_message',
    content_kind: draft.contentKind,
    timing_mode: 'relative',
    ...schedule,
    target_inbox_id: Number(draft.inboxId),
    timezone: currentAccount.value?.workspace_working_hours_timezone || 'UTC',
    repeat_mode: 'once',
    relative_time_mode: fixedTime ? 'fixed_time_of_day' : 'inherit_anchor_time',
    relative_time_of_day: fixedTime ? draft.exactTime : '',
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
      String(item.value) === String(item.original.values?.[0] || '') &&
      (item.queryOperator === item.original.query_operator ||
        (item.queryOperator === 'AND' && !item.original.query_operator));
    if (unchanged) return item.original;
    return {
      attribute_key: item.field,
      filter_operator: item.operator || 'equal_to',
      values: noValueOperator(item.operator) ? [] : [String(item.value)],
      query_operator: item.queryOperator || 'AND',
    };
  };
  const originalConditions = draft.originalRule?.conditions || [];
  const conditions = originalConditions.flatMap(original => {
    const edited = draft.conditions.find(item => item.original === original);
    if (edited) return [conditionPayload(edited)];
    return conditionFields.value.includes(original.attribute_key)
      ? []
      : [original];
  });
  conditions.push(
    ...draft.conditions.filter(item => !item.original).map(conditionPayload)
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
    description: draft.presetKey
      ? `${draft.description.replace(/\[scheduling_preset:[a-z0-9_]+\]/gi, '').trim()} ${buildPresetMarker(draft.presetKey)}`.trim()
      : draft.description,
    event_name: event.eventName,
    active,
    conditions,
    actions,
    calendar_managed: true,
    calendar_context: true,
  };
  saving.value = true;
  try {
    if (active) {
      const ids = appointmentFieldIds([JSON.stringify(params.template_params)]);
      const stats = await fetchAppointmentFieldFill(
        currentAccount.value?.id,
        ids
      );
      const blocked = blockingFieldStats(stats, ids);
      if (blocked.length) {
        useAlert(
          t('SCHEDULING.REMINDERS.ERRORS.FIELD_EMPTY_WARNING', {
            share: Math.round(blocked[0].share * 100),
          })
        );
        return;
      }
    }
    if (draft.id) await AutomationAPI.update(draft.id, payload);
    else await AutomationAPI.create(payload);
    await store.dispatch('automations/get');
    editing.value = false;
    useAlert(L('SAVED'));
  } catch {
    useAlert(L('SAVE_ERROR'));
  } finally {
    saving.value = false;
  }
};
const toggle = async rule => {
  if (!rule?.calendar_managed || (!rule.active && !canEnable(rule))) return;
  try {
    if (!rule.active) {
      const ids = appointmentFieldIds([
        JSON.stringify(touchParams(rule).template_params),
      ]);
      const blocked = blockingFieldStats(
        await fetchAppointmentFieldFill(currentAccount.value?.id, ids),
        ids
      );
      if (blocked.length) {
        useAlert(
          t('SCHEDULING.REMINDERS.ERRORS.FIELD_EMPTY_WARNING', {
            share: Math.round(blocked[0].share * 100),
          })
        );
        return;
      }
    }
    await AutomationAPI.update(rule.id, {
      active: !rule.active,
      calendar_context: true,
    });
    await store.dispatch('automations/get');
  } catch {
    useAlert(L('SAVE_ERROR'));
  }
};
const syncTemplates = async () => {
  if (!selectedInboxId.value) return;
  syncing.value = true;
  try {
    await store.dispatch('inboxes/syncTemplates', selectedInboxId.value);
  } catch {
    useAlert(L('SAVE_ERROR'));
  } finally {
    syncing.value = false;
  }
};
const handlePackGenerated = async ({ drafts }) => {
  generatedPackDrafts.value = drafts || [];
  await syncTemplates();
};
const adopt = async () => {
  if (!reviewingRule.value || adopting.value) return;
  adopting.value = true;
  try {
    await AutomationAPI.adoptCalendarNotification(reviewingRule.value.id);
    await store.dispatch('automations/get');
    reviewingRule.value = null;
    useAlert(L('ADOPTED'));
  } catch (error) {
    const code = error?.response?.data?.errors?.[0];
    useAlert(
      code &&
        [
          'ALREADY_MANAGED',
          'APPOINTMENT_EVENT_REQUIRED',
          'MESSAGE_ACTION_REQUIRED',
          'WHATSAPP_REQUIRED',
          'SEND_PLAN_REQUIRED',
          'MESSAGE_TEXT_REQUIRED',
          'APPROVED_TEMPLATE_REQUIRED',
          'INVALID_RULE',
        ].includes(code)
        ? L(`ADOPTION_ERRORS.${code}`)
        : L('ADOPTION_FAILED')
    );
  } finally {
    adopting.value = false;
  }
};
const preview = computed(() => {
  if (!selectedTemplate.value) return '';
  let body = getTemplateBodyPreview(selectedTemplate.value);
  templateVars.value.forEach(key => {
    const semantic = APPOINTMENT_SEMANTIC_VARIABLES.find(
      item => item.key === draft.bindings[key]
    );
    body = body.replaceAll(`{{${key}}}`, semantic?.example || `{{${key}}}`);
  });
  return body;
});
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
    CabinetsAPI.get()
      .then(response => {
        cabinets.value = response.data.payload || [];
      })
      .catch(() => {}),
    CrmFieldDefinitionsAPI.get({ entity_kind: 'appointment' })
      .then(response => {
        customFields.value = response.data.payload || [];
      })
      .catch(() => {}),
  ]);
  if (whatsAppInboxes.value.length === 1)
    selectedInboxId.value = whatsAppInboxes.value[0].id;
  const selected = notificationRules.value.find(
    rule => String(rule.id) === String(route.query.rule)
  );
  if (selected) newDraft(selected);
});
</script>

<template>
  <div class="flex h-full min-h-0 flex-col bg-n-surface-1">
    <SchedulingPageHeader :title="L('TITLE')" :subtitle="L('SUBTITLE')" />
    <div class="flex-1 overflow-y-auto p-3 sm:p-6">
      <div class="mx-auto max-w-5xl space-y-5">
        <section
          class="flex flex-wrap items-end gap-3 rounded-xl border border-n-weak bg-n-solid-2 p-4"
        >
          <label class="min-w-48 flex-1 text-sm text-n-slate-12">
            {{ L('CHANNEL') }}
            <select
              v-model="selectedInboxId"
              class="mt-1 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
            >
              <option value="">{{ L('CHOOSE') }}</option>
              <option
                v-for="inbox in whatsAppInboxes"
                :key="inbox.id"
                :value="inbox.id"
              >
                {{ inbox.name }}
              </option>
            </select>
          </label>
          <p class="m-0 text-sm text-n-slate-11">
            {{ L('RULE_COUNT') }}: {{ notificationRules.length }}
          </p>
          <p class="m-0 text-sm text-n-teal-11">
            {{ L('APPROVED') }}: {{ templateCount('APPROVED') }}
          </p>
          <p class="m-0 text-sm text-n-amber-11">
            {{ L('PENDING') }}: {{ templateCount('PENDING') }}
          </p>
          <p class="m-0 text-sm text-n-ruby-11">
            {{ L('REJECTED') }}: {{ templateCount('REJECTED') }}
          </p>
        </section>
        <div
          v-if="!whatsAppInboxes.length"
          class="rounded-xl border border-n-weak bg-n-solid-2 p-4 text-sm"
        >
          {{ L('CONNECT_CHANNEL') }}
          <RouterLink
            :to="{
              name: 'settings_inbox_list',
              params: { accountId: currentAccount?.id },
            }"
            class="text-n-brand"
          >
            {{ L('CONNECT') }}
          </RouterLink>
        </div>
        <div class="flex flex-wrap gap-2">
          <button
            type="button"
            class="rounded-lg bg-n-brand px-3 py-2 text-white"
            :disabled="!selectedInboxId"
            @click="templatePackDialogRef?.open()"
          >
            {{ L('TEMPLATE_PACK') }}
          </button>
          <button
            type="button"
            class="rounded-lg border border-n-weak px-3 py-2 text-n-slate-12"
            :disabled="!selectedInboxId"
            @click="createTemplateDialogRef?.open()"
          >
            {{ L('NEW_TEMPLATE') }}
          </button>
          <button
            type="button"
            class="rounded-lg border border-n-weak px-3 py-2 text-n-slate-12"
            :disabled="!selectedInboxId || syncing"
            @click="syncTemplates"
          >
            {{ L('SYNC_META') }}
          </button>
          <button
            type="button"
            class="rounded-lg border border-n-weak px-3 py-2 text-n-slate-12"
            @click="newDraft()"
          >
            {{ L('ADD') }}
          </button>
        </div>
        <p v-if="!notificationRules.length" class="text-sm text-n-slate-11">
          {{ L('FIRST_RUN') }}
        </p>
        <section>
          <h2 class="mb-3 text-base font-semibold text-n-slate-12">
            {{ L('PRESETS') }}
          </h2>
          <div class="grid gap-3 sm:grid-cols-2">
            <article
              v-for="preset in APPOINTMENT_REMINDER_PRESETS"
              :key="preset.key"
              :data-testid="`reminder-preset-card-${preset.key}`"
              class="rounded-xl border border-n-weak bg-n-solid-2 p-4"
            >
              <div class="flex items-start justify-between gap-2">
                <h3 class="m-0 font-semibold text-n-slate-12">
                  {{ t(`SCHEDULING.REMINDERS.PRESETS.${preset.key}.TITLE`) }}
                </h3>
                <input
                  type="checkbox"
                  :aria-label="
                    t(`SCHEDULING.REMINDERS.PRESETS.${preset.key}.TITLE`)
                  "
                  :checked="Boolean(presetRule(preset)?.active)"
                  :disabled="
                    !presetRule(preset) ||
                    (!presetRule(preset)?.active &&
                      !canEnable(presetRule(preset)))
                  "
                  @change="toggle(presetRule(preset))"
                />
              </div>
              <p class="mb-2 mt-1 text-sm text-n-slate-11">
                {{
                  presetRule(preset)
                    ? summary(presetRule(preset))
                    : t(
                        `SCHEDULING.REMINDERS.PRESETS.${preset.key}.DESCRIPTION`
                      )
                }}
              </p>
              <p class="mb-2 text-sm text-n-slate-11">
                {{
                  presetRule(preset)
                    ? touchParams(presetRule(preset)).template_params?.name ||
                      L('NO_TEMPLATE')
                    : presetTemplate(preset)?.name || L('NO_TEMPLATE')
                }}
                ·
                {{
                  presetRule(preset)
                    ? templateStatus(presetRule(preset))
                    : presetTemplateStatus(preset)
                }}
              </p>
              <p class="mb-3 text-sm text-n-slate-11">
                {{ L('CONDITIONS') }}:
                {{ conditionsSummaryText(presetRule(preset)) }}
              </p>
              <button
                type="button"
                class="text-n-brand"
                @click="newDraft(presetRule(preset) || null, preset)"
              >
                {{
                  presetRule(preset) && !presetRule(preset).calendar_managed
                    ? L('REVIEW_ADOPT')
                    : L('SET_UP')
                }}
              </button>
            </article>
          </div>
        </section>
        <section>
          <h2 class="mb-3 text-base font-semibold text-n-slate-12">
            {{ L('OTHER_RULES') }}
          </h2>
          <article
            v-for="rule in otherRules"
            :key="rule.id"
            class="mb-2 flex flex-wrap items-center gap-3 rounded-xl border border-n-weak bg-n-solid-2 p-4"
          >
            <div class="min-w-48 flex-1">
              <p class="m-0 font-semibold text-n-slate-12">{{ rule.name }}</p>
              <p class="m-0 text-sm text-n-slate-11">
                {{ eventLabel(eventKeyForRule(rule)) }} · {{ summary(rule) }} ·
                {{
                  touchParams(rule).template_params?.name ||
                  touchParams(rule).body ||
                  L('NO_CONTENT')
                }}
                · {{ L('CONDITIONS') }}: {{ conditionsSummaryText(rule) }}
              </p>
            </div>
            <template v-if="rule.calendar_managed">
              <input
                type="checkbox"
                :aria-label="rule.name"
                :checked="rule.active"
                :disabled="!rule.active && !canEnable(rule)"
                @change="toggle(rule)"
              />
              <button
                type="button"
                class="text-n-brand"
                @click="newDraft(rule)"
              >
                {{ L('SET_UP') }}
              </button>
            </template>
            <button
              v-else-if="firstTouch(rule)"
              type="button"
              class="text-n-brand"
              @click="reviewingRule = rule"
            >
              {{ L('REVIEW_ADOPT') }}
            </button>
            <span v-else class="text-sm text-n-slate-11">{{
              L('MANAGE_IN_AUTOMATIONS')
            }}</span>
          </article>
        </section>
        <section
          v-if="reviewingRule"
          class="rounded-xl border border-n-amber-8 bg-n-solid-2 p-4"
          data-testid="adoption-review"
        >
          <h2 class="mb-2 font-semibold">
            {{ L('REVIEW_ADOPT') }}: {{ reviewingRule.name }}
          </h2>
          <p class="text-sm">
            {{ L('CONDITIONS') }}:
            {{
              (reviewingRule.conditions || []).map(conditionText).join(' · ') ||
              L('NO_CONDITIONS')
            }}
          </p>
          <div
            v-for="(action, index) in reviewTouches"
            :key="index"
            class="mb-3 rounded-lg border border-n-weak p-3 text-sm"
          >
            <p class="m-0">
              {{ L('ACTION') }} {{ index + 1 }} · {{ L('CHANNEL') }}:
              {{ reviewChannel(action.action_params) }}
            </p>
            <p class="m-0">
              {{ L('CONTENT') }}:
              {{
                action.action_params?.template_params?.name ||
                action.action_params?.body ||
                L('NO_CONTENT')
              }}
              ·
              {{
                action.action_params?.content_kind === 'channel_template'
                  ? reviewTemplateStatus(action.action_params)
                  : L('TEXT')
              }}
            </p>
            <p class="m-0">
              {{ L('TIMING_LABEL') }}: {{ summary({ actions: [action] }) }}
            </p>
          </div>
          <button
            type="button"
            class="mr-3 rounded-lg bg-n-brand px-3 py-2 text-white"
            :disabled="adopting"
            @click="adopt"
          >
            {{ L('ADOPT') }}
          </button>
          <button type="button" @click="reviewingRule = null">
            {{ L('CANCEL') }}
          </button>
        </section>
        <section
          v-if="editing"
          role="dialog"
          aria-modal="true"
          :aria-label="draft.id ? L('EDIT') : L('ADD')"
          class="fixed inset-y-0 right-0 z-50 w-full max-w-xl overflow-y-auto border-l border-n-weak bg-n-surface-1 p-4 shadow-xl"
          data-testid="calendar-notification-editor"
        >
          <h2 class="mb-3 text-base font-semibold">
            {{ draft.id ? L('EDIT') : L('ADD') }}
          </h2>
          <div class="mb-4 flex flex-wrap gap-2 text-sm">
            <button
              v-for="index in [1, 2, 3, 4]"
              :key="index"
              type="button"
              class="rounded-lg border border-n-weak px-3 py-1"
              :class="
                step === index ? 'bg-n-brand text-white' : 'text-n-slate-12'
              "
              @click="step = index"
            >
              {{ index }}. {{ L(`STEPS.${index}`) }}
            </button>
          </div>
          <div v-if="step === 1" class="grid gap-3 sm:grid-cols-2">
            <label class="text-sm"
              >{{ L('NAME')
              }}<input
                v-model="draft.name"
                class="mt-1 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
            /></label>
            <label class="text-sm"
              >{{ L('EVENT')
              }}<select
                v-model="draft.eventKey"
                class="mt-1 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
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
            <label class="text-sm"
              >{{ L('TIMING_LABEL')
              }}<select
                v-model="draft.timing"
                class="mt-1 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
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
            <template v-if="['before', 'after'].includes(draft.timing)">
              <label class="text-sm"
                >{{ L('AMOUNT')
                }}<input
                  v-model.number="draft.amount"
                  type="number"
                  min="1"
                  class="mt-1 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
              /></label>
              <label class="text-sm"
                >{{ L('UNIT')
                }}<select
                  v-model.number="draft.unit"
                  class="mt-1 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
                >
                  <option :value="60">{{ L('MINUTES') }}</option>
                  <option :value="3600">{{ L('HOURS') }}</option>
                  <option :value="86400">{{ L('DAYS') }}</option>
                </select></label
              >
              <template v-if="draft.unit === 86400">
                <label class="text-sm"
                  >{{ L('EXACT_TIME')
                  }}<input
                    v-model="draft.exactTime"
                    type="time"
                    class="mt-1 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
                /></label>
              </template>
            </template>
          </div>
          <div v-else-if="step === 2" class="space-y-3">
            <div
              v-for="(condition, index) in draft.conditions"
              :key="index"
              class="grid gap-2 sm:grid-cols-[1fr_1fr_1fr_auto]"
            >
              <select
                v-model="condition.field"
                :aria-label="L('FIELD')"
                class="rounded-lg border border-n-weak bg-n-surface-1 p-2"
                @change="
                  condition.operator = operatorsFor(condition.field)[0];
                  condition.value = '';
                "
              >
                <option
                  v-for="field in conditionFields"
                  :key="field"
                  :value="field"
                >
                  {{ fieldLabel(field) }}
                </option>
              </select>
              <select
                v-model="condition.operator"
                :aria-label="L('OPERATOR')"
                class="rounded-lg border border-n-weak bg-n-surface-1 p-2"
              >
                <option
                  v-for="operator in operatorsFor(condition.field)"
                  :key="operator"
                  :value="operator"
                >
                  {{ L(`OPERATORS.${operator.toUpperCase()}`) }}
                </option>
              </select>
              <select
                v-if="
                  !noValueOperator(condition.operator) &&
                  conditionOptions[condition.field]?.length
                "
                v-model="condition.value"
                :aria-label="L('VALUE')"
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
                v-else-if="!noValueOperator(condition.operator)"
                v-model="condition.value"
                :aria-label="L('VALUE')"
                class="rounded-lg border border-n-weak bg-n-surface-1 p-2"
              />
              <span v-else />
              <button
                type="button"
                :aria-label="L('REMOVE')"
                class="text-n-ruby-11"
                @click="draft.conditions.splice(index, 1)"
              >
                <span class="i-lucide-x" />
              </button>
              <template v-if="index < draft.conditions.length - 1">
                <label class="text-sm"
                  >{{ L('JOIN')
                  }}<select
                    v-model="condition.queryOperator"
                    class="ml-2 rounded-lg border border-n-weak bg-n-surface-1 p-1"
                  >
                    <option value="AND">{{ L('AND') }}</option>
                    <option value="OR">{{ L('OR') }}</option>
                  </select></label
                >
              </template>
            </div>
            <button
              type="button"
              class="text-n-brand"
              @click="
                draft.conditions.push({
                  field: 'service_id',
                  operator: 'equal_to',
                  value: '',
                  queryOperator: 'AND',
                })
              "
            >
              {{ L('ADD_CONDITION') }}
            </button>
          </div>
          <div v-else-if="step === 3" class="space-y-3">
            <label class="block text-sm"
              >{{ L('CHANNEL')
              }}<select
                v-model="draft.inboxId"
                class="mt-1 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
              >
                <option value="">{{ L('CHOOSE') }}</option>
                <option
                  v-for="inbox in whatsAppInboxes"
                  :key="inbox.id"
                  :value="inbox.id"
                >
                  {{ inbox.name }}
                </option>
              </select></label
            >
            <label class="block text-sm"
              >{{ L('CONTENT')
              }}<select
                v-model="draft.contentKind"
                class="mt-1 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
              >
                <option value="channel_template">{{ L('TEMPLATE') }}</option>
                <option value="free_text">{{ L('TEXT') }}</option>
              </select></label
            >
            <textarea
              v-if="draft.contentKind === 'free_text'"
              v-model="draft.body"
              :aria-label="L('TEXT')"
              rows="3"
              class="w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
            />
            <template v-else>
              <label class="block text-sm"
                >{{ L('TEMPLATE')
                }}<select
                  v-model="draft.templateKey"
                  class="mt-1 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
                >
                  <option value="">{{ L('CHOOSE') }}</option>
                  <option
                    v-for="template in templates"
                    :key="`${template.name}::${template.language}`"
                    :value="`${template.name}::${template.language || 'ru'}`"
                  >
                    {{ template.name }} ({{ template.language || 'ru' }} ·
                    {{
                      L(
                        `TEMPLATE_STATUS.${String(template.status || 'PENDING').toUpperCase()}`
                      )
                    }})
                  </option>
                </select></label
              >
              <label
                v-for="key in templateVars"
                :key="key"
                class="block text-sm"
                >{{ key
                }}<select
                  v-model="draft.bindings[key]"
                  class="mt-1 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2"
                >
                  <option value="">{{ L('CHOOSE') }}</option>
                  <option
                    v-for="field in APPOINTMENT_SEMANTIC_VARIABLES"
                    :key="field.key"
                    :value="field.key"
                  >
                    {{ t(field.labelKey) }} — {{ field.example }}
                  </option>
                </select></label
              >
              <p
                class="whitespace-pre-line rounded-lg border border-n-weak bg-n-surface-1 p-3 text-sm"
              >
                {{ preview || L('NO_TEMPLATE') }}
              </p>
              <div v-if="templateButtons.length" class="flex flex-wrap gap-2">
                <span
                  v-for="(button, index) in templateButtons"
                  :key="index"
                  class="rounded-lg border border-n-weak bg-n-surface-1 px-3 py-1 text-sm text-n-brand"
                  >{{ button.text }}</span
                >
              </div>
              <label class="flex items-center gap-2 text-sm"
                ><input
                  v-model="draft.confirm"
                  type="checkbox"
                  :disabled="!hasConfirmButton"
                />{{ L('CONFIRM') }}</label
              >
            </template>
          </div>
          <div v-else class="space-y-3 text-sm">
            <p>
              {{ L('SUMMARY_TO') }}
              {{ selectedInbox?.name || L('NO_CHANNEL') }},
              {{
                summary({
                  actions: [
                    {
                      action_name: 'create_touch',
                      action_params: [
                        {
                          ...touchParams(draft.originalRule),
                          ...scheduleFor(
                            draft.eventKey,
                            draft.timing,
                            draft.amount,
                            draft.unit
                          ),
                        },
                      ],
                    },
                  ],
                })
              }}, {{ selectedTemplate?.name || draft.body || L('NO_CONTENT') }}.
            </p>
            <p>{{ L('CONDITIONS') }}: {{ draft.conditions.length }}</p>
            <button
              type="button"
              class="mr-2 rounded-lg border border-n-weak px-3 py-2"
              :disabled="saving"
              @click="save(false)"
            >
              {{ L('SAVE_OFF') }}
            </button>
            <button
              type="button"
              class="rounded-lg bg-n-brand px-3 py-2 text-white"
              :disabled="saving"
              @click="save(true)"
            >
              {{ L('SAVE_ON') }}
            </button>
          </div>
          <div class="mt-5 flex gap-3">
            <button v-if="step > 1" type="button" @click="step -= 1">
              {{ L('BACK') }}</button
            ><button
              v-if="step < 4"
              type="button"
              class="text-n-brand"
              @click="step += 1"
            >
              {{ L('NEXT') }}</button
            ><button type="button" @click="editing = false">
              {{ L('CANCEL') }}
            </button>
          </div>
        </section>
      </div>
    </div>
    <AppointmentTemplatePackDialog
      ref="templatePackDialogRef"
      :inbox-id="Number(selectedInboxId) || null"
      :existing-template-names="pageTemplates.map(item => item.name)"
      :default-company-name="currentAccount?.name || ''"
      @generated="handlePackGenerated"
    />
    <CreateWhatsAppTemplateDialog
      v-if="selectedInboxId"
      ref="createTemplateDialogRef"
      :inbox-id="Number(selectedInboxId)"
      @created="syncTemplates"
    />
  </div>
</template>
