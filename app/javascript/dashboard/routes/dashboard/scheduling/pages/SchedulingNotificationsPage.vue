<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
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
  findSemanticVariableByToken,
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
  touchParams,
} from '../calendarNotificationRules';

const { t } = useI18n();
const store = useStore();
const { currentAccount } = useAccount();
const allRules = useMapGetter('automations/getAutomations');
const inboxes = useMapGetter('inboxes/getInboxes');
const resources = ref([]);
const services = ref([]);
const cabinets = ref([]);
const customFields = ref([]);
const selectedInboxId = ref('');
const expandedPresetKey = ref('');
const templatePackDialogRef = ref(null);
const createTemplateDialogRef = ref(null);
const syncing = ref(false);
const savingPresetKey = ref('');
const savingOtherRuleId = ref(null);
const otherRuleMinMinutesDrafts = reactive({});

const PRE_VISIT_MIN_LEAD_EVENTS = [
  'appointment_created',
  'appointment_rescheduled',
  'appointment_updated',
];
const MIN_MINUTES_MAX = 43200;

const parsePositiveMinMinutes = raw => {
  if (raw === null || raw === undefined || String(raw).trim() === '') {
    return { empty: true, valid: true, value: null };
  }
  const trimmed = String(raw).trim();
  if (!/^\d+$/.test(trimmed)) {
    return { empty: false, valid: false, value: null };
  }
  const num = Number(trimmed);
  if (!Number.isInteger(num) || num < 1 || num > MIN_MINUTES_MAX) {
    return { empty: false, valid: false, value: null };
  }
  return { empty: false, valid: true, value: num };
};

const ruleMinMinutes = rule => {
  if (!rule) return null;
  const raw =
    rule.min_minutes_before_appointment ??
    touchParams(rule)?.min_minutes_before_appointment ??
    touchParams(rule)?.metadata?.min_minutes_before_appointment ??
    null;
  const parsed = parsePositiveMinMinutes(raw);
  return parsed.valid && !parsed.empty ? parsed.value : null;
};

const supportsMinMinutesBefore = eventName =>
  PRE_VISIT_MIN_LEAD_EVENTS.includes(eventName);

const createDefaultPresetDraft = preset => ({
  enabled: false,
  templateKey: '',
  dayBeforeTime: preset.relativeTimeOfDay || '15:00',
  confirmationEnabled: Boolean(preset.supportsConfirmation),
  reviewDelayHours: 1,
  minMinutesBeforeAppointment: '',
  variableBindings: {},
});

const presetStates = reactive(
  Object.fromEntries(
    APPOINTMENT_REMINDER_PRESETS.map(preset => [
      preset.key,
      createDefaultPresetDraft(preset),
    ])
  )
);

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
const makeTemplateKey = template =>
  `${String(template?.name || '').trim()}::${String(template?.language || 'ru').trim()}`;

const templateByKey = computed(() => {
  const map = new Map();
  pageTemplates.value.forEach(template => {
    if (template?.name) {
      map.set(makeTemplateKey(template), template);
    }
  });
  return map;
});

const presetTemplate = preset =>
  pageTemplates.value.find(item => item.name === preset.templateName);

const presetRule = preset =>
  notificationRules.value.find(
    rule =>
      extractPresetKeyFromRule(rule) === preset.key &&
      (!selectedInboxId.value ||
        String(touchParams(rule)?.target_inbox_id) ===
          String(selectedInboxId.value))
  ) ||
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

const getSelectedTemplateForPreset = presetKey => {
  const key = presetStates[presetKey]?.templateKey;
  if (key && templateByKey.value.has(key)) {
    return templateByKey.value.get(key);
  }
  const preset = APPOINTMENT_REMINDER_PRESETS.find(p => p.key === presetKey);
  const rule = preset ? presetRule(preset) : null;
  if (rule) {
    return ruleTemplate(rule) || presetTemplate(preset) || null;
  }
  return preset ? presetTemplate(preset) || null : null;
};

const presetTemplateStatus = preset => {
  const template =
    getSelectedTemplateForPreset(preset.key) || presetTemplate(preset);
  return template
    ? L(`TEMPLATE_STATUS.${String(template.status || 'PENDING').toUpperCase()}`)
    : L('NO_TEMPLATE');
};

const templateCount = status =>
  pageTemplates.value.filter(
    item => String(item.status).toUpperCase() === status
  ).length;

const templateStatus = rule => {
  const template = ruleTemplate(rule);
  return template
    ? L(`TEMPLATE_STATUS.${String(template.status || 'PENDING').toUpperCase()}`)
    : L('NO_TEMPLATE');
};

const getPresetStatusBadge = preset => {
  const rule = presetRule(preset);
  const template = rule
    ? ruleTemplate(rule)
    : getSelectedTemplateForPreset(preset.key);
  if (!template && !(rule && touchParams(rule).content_kind === 'free_text')) {
    return {
      tone: 'slate',
      label: L('NO_TEMPLATE'),
    };
  }
  if (template) {
    const tplStatus = String(template.status || 'PENDING').toUpperCase();
    if (tplStatus !== 'APPROVED') {
      return {
        tone: tplStatus === 'REJECTED' ? 'ruby' : 'amber',
        label: L(`TEMPLATE_STATUS.${tplStatus}`),
      };
    }
  }
  if (rule?.active) {
    return {
      tone: 'teal',
      label: L('ENABLED'),
    };
  }
  return {
    tone: 'slate',
    label: L('DISABLED'),
  };
};

const getTemplateBodyVars = template => {
  if (!template) return [];
  return getTemplateParameterDefinitions(template)
    .filter(def => def.section === 'body')
    .map(def => def.key.replace(/^body\./, ''));
};

const ensureDefaultBindingsForPreset = preset => {
  const state = presetStates[preset.key];
  const template = getSelectedTemplateForPreset(preset.key);
  const vars = getTemplateBodyVars(template);
  if (!vars.length) return;

  const updated = { ...state.variableBindings };
  vars.forEach((varKey, idx) => {
    if (!updated[varKey]) {
      const defaultSemanticKey = preset.defaultVariableOrder[idx];
      if (defaultSemanticKey) updated[varKey] = defaultSemanticKey;
    }
  });
  state.variableBindings = updated;
};

const resolveSemanticKeyFromStoredParam = rawVal => {
  const fieldRef = extractSingleTemplateFieldReference(rawVal);
  if (fieldRef?.fieldId) {
    const byField = findSemanticVariableByFieldId(fieldRef.fieldId);
    if (byField) return byField.key;
  }
  const byToken = findSemanticVariableByToken(rawVal);
  return byToken?.key || '';
};

const hydratePresetsFromRulesAndTemplates = () => {
  APPOINTMENT_REMINDER_PRESETS.forEach(preset => {
    const state = presetStates[preset.key];
    const existingRule = presetRule(preset);
    const rawTouch = existingRule ? touchParams(existingRule) : null;

    if (existingRule && rawTouch) {
      state.enabled = Boolean(existingRule.active);
      const tplParams = rawTouch.template_params || {};
      if (tplParams.name) {
        const candidateKey = `${tplParams.name}::${tplParams.language || 'ru'}`;
        const matchedTpl =
          templateByKey.value.get(candidateKey) ||
          pageTemplates.value.find(item => item.name === tplParams.name);
        if (matchedTpl) {
          state.templateKey = makeTemplateKey(matchedTpl);
        } else {
          state.templateKey = candidateKey;
        }
      }

      if (preset.supportsDayBeforeTime && rawTouch.relative_time_of_day) {
        state.dayBeforeTime = rawTouch.relative_time_of_day;
      }

      if (preset.supportsConfirmation) {
        state.confirmationEnabled =
          rawTouch.response_action === 'confirm_appointment';
      }

      if (preset.supportsReviewDelay) {
        const offsetSec = Number(rawTouch.relative_offset_seconds || 3600);
        if (offsetSec <= 120) state.reviewDelayHours = 0;
        else if (offsetSec <= 3600) state.reviewDelayHours = 1;
        else if (offsetSec <= 7200) state.reviewDelayHours = 2;
        else state.reviewDelayHours = 3;
      }

      const existingMin = ruleMinMinutes(existingRule);
      state.minMinutesBeforeAppointment = existingMin
        ? String(existingMin)
        : '';

      const bodyParams = tplParams.processed_params?.body || {};
      const parsedBindings = {};
      Object.entries(bodyParams).forEach(([varIndex, rawRef]) => {
        const semKey = resolveSemanticKeyFromStoredParam(rawRef);
        if (semKey) {
          parsedBindings[varIndex] = semKey;
        }
      });
      state.variableBindings = parsedBindings;
    } else {
      state.enabled = false;
      state.minMinutesBeforeAppointment = '';
      if (!state.templateKey || !templateByKey.value.has(state.templateKey)) {
        const defaultMatch = presetTemplate(preset);
        state.templateKey = defaultMatch ? makeTemplateKey(defaultMatch) : '';
      }
    }

    ensureDefaultBindingsForPreset(preset);
  });

  notificationRules.value.forEach(rule => {
    const minVal = ruleMinMinutes(rule);
    otherRuleMinMinutesDrafts[rule.id] = minVal ? String(minVal) : '';
  });
};

watch(
  [selectedInboxId, pageTemplates, notificationRules],
  () => {
    hydratePresetsFromRulesAndTemplates();
  },
  { immediate: true }
);

const renderLiveTemplatePreview = preset => {
  const template = getSelectedTemplateForPreset(preset.key);
  if (!template) return '';
  let text = getTemplateBodyPreview(template);
  const state = presetStates[preset.key];
  const vars = getTemplateBodyVars(template);

  vars.forEach(varKey => {
    const semKey = state.variableBindings?.[varKey];
    const semObj = findSemanticVariableByToken(semKey);
    const exampleValue = semObj?.example || `{{${varKey}}}`;
    text = text.replaceAll(`{{${varKey}}}`, exampleValue);
  });

  return text;
};

const getTemplateButtonsForPreview = preset => {
  const template = getSelectedTemplateForPreset(preset.key);
  if (!template?.components) return [];
  const comp = template.components.find(
    c => String(c.type || '').toUpperCase() === 'BUTTONS'
  );
  return Array.isArray(comp?.buttons) ? comp.buttons : [];
};

const handleInlineTemplateChange = (preset, nextKey) => {
  presetStates[preset.key].templateKey = nextKey;
  expandedPresetKey.value = preset.key;
  ensureDefaultBindingsForPreset(preset);
};

const canEnable = rule =>
  Boolean(
    rule &&
      (touchParams(rule).content_kind === 'free_text' ||
        (touchParams(rule).body && !touchParams(rule).content_kind) ||
        String(ruleTemplate(rule)?.status).toUpperCase() === 'APPROVED')
  );

const canTogglePreset = preset => {
  const existingRule = presetRule(preset);
  if (existingRule) {
    return existingRule.active || canEnable(existingRule);
  }
  const template = getSelectedTemplateForPreset(preset.key);
  if (
    !selectedInboxId.value ||
    !template ||
    String(template.status || '').toUpperCase() !== 'APPROVED'
  ) {
    return false;
  }
  const vars = getTemplateBodyVars(template);
  const state = presetStates[preset.key];
  return vars.every(k => Boolean(state.variableBindings?.[k]));
};

const fieldLabel = field =>
  customFields.value.find(item => item.key === field)?.label ||
  L(`FIELDS.${field.toUpperCase()}`);
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

const saveInlinePreset = async (preset, { forceActive = null } = {}) => {
  const state = presetStates[preset.key];
  const template = getSelectedTemplateForPreset(preset.key);
  if (!selectedInboxId.value || !template) {
    useAlert(L('REQUIRED'));
    return;
  }
  const vars = getTemplateBodyVars(template);
  if (vars.some(k => !state.variableBindings?.[k])) {
    useAlert(L('BINDINGS_REQUIRED'));
    return;
  }

  const existingRule = presetRule(preset);
  const parsedMinMinutes = supportsMinMinutesBefore(preset.eventName)
    ? parsePositiveMinMinutes(state.minMinutesBeforeAppointment)
    : { empty: true, valid: true, value: null };
  if (!parsedMinMinutes.valid) {
    useAlert(L('MIN_MINUTES_BEFORE_INVALID'));
    return;
  }
  const isApproved = String(template.status || '').toUpperCase() === 'APPROVED';
  const nextActive =
    forceActive !== null
      ? Boolean(forceActive && isApproved)
      : Boolean(existingRule?.active && isApproved);
  const bodyProcessed = Object.fromEntries(
    vars.map(k => [
      k,
      buildFieldReferenceForSemanticKey(state.variableBindings[k]),
    ])
  );
  const reviewDelaySeconds =
    Number(state.reviewDelayHours || 0) <= 0
      ? 60
      : Number(state.reviewDelayHours) * 3600;
  const offsetSeconds = preset.supportsReviewDelay
    ? reviewDelaySeconds
    : preset.relativeOffsetSeconds;

  const params = {
    ...(existingRule ? touchParams(existingRule) : {}),
    action_type: 'send_message',
    content_kind: 'channel_template',
    timing_mode: 'relative',
    relative_anchor: preset.relativeAnchor,
    relative_offset_seconds: offsetSeconds,
    relative_time_mode: preset.supportsDayBeforeTime
      ? 'fixed_time_of_day'
      : 'inherit_anchor_time',
    relative_time_of_day: preset.supportsDayBeforeTime
      ? state.dayBeforeTime || '15:00'
      : '',
    repeat_mode: 'once',
    target_inbox_id: Number(selectedInboxId.value),
    timezone:
      currentAccount.value?.workspace_working_hours_timezone || 'Asia/Almaty',
    response_action:
      preset.supportsConfirmation && state.confirmationEnabled
        ? 'confirm_appointment'
        : '',
    response_button_index:
      preset.supportsConfirmation && state.confirmationEnabled ? 0 : '',
    template_params: {
      name: template.name,
      language: template.language || 'ru',
      category: template.category || 'UTILITY',
      processed_params: {
        body: bodyProcessed,
      },
    },
  };
  if (parsedMinMinutes.value) {
    params.min_minutes_before_appointment = parsedMinMinutes.value;
  } else {
    delete params.min_minutes_before_appointment;
  }

  const payload = {
    name:
      existingRule?.name ||
      t(`SCHEDULING.REMINDERS.PRESETS.${preset.key}.TITLE`),
    description:
      `${(existingRule?.description || '').replace(/\[scheduling_preset:[a-z0-9_]+\]/gi, '').trim()} ${buildPresetMarker(preset.key)}`.trim(),
    event_name: preset.eventName,
    active: nextActive,
    min_minutes_before_appointment: parsedMinMinutes.value,
    conditions: existingRule?.conditions?.length
      ? existingRule.conditions
      : [
          {
            attribute_key: 'source',
            filter_operator: 'is_present',
            values: [],
            query_operator: null,
          },
        ],
    actions: [{ action_name: 'create_touch', action_params: [params] }],
    calendar_managed: true,
    calendar_context: true,
  };

  savingPresetKey.value = preset.key;
  try {
    if (existingRule?.id) {
      await AutomationAPI.update(existingRule.id, payload);
    } else {
      await AutomationAPI.create(payload);
    }
    await store.dispatch('automations/get');
    useAlert(L('SAVED'));
  } catch {
    useAlert(L('SAVE_ERROR'));
  } finally {
    savingPresetKey.value = '';
  }
};

const saveOtherRuleMinMinutes = async rule => {
  if (!rule?.id) return;
  const parsed = parsePositiveMinMinutes(otherRuleMinMinutesDrafts[rule.id]);
  if (!parsed.valid) {
    useAlert(L('MIN_MINUTES_BEFORE_INVALID'));
    return;
  }
  savingOtherRuleId.value = rule.id;
  try {
    await AutomationAPI.update(rule.id, {
      min_minutes_before_appointment: parsed.value,
      calendar_context: true,
    });
    await store.dispatch('automations/get');
    useAlert(L('SAVED'));
  } catch {
    useAlert(L('SAVE_ERROR'));
  } finally {
    savingOtherRuleId.value = null;
  }
};

const toggle = async (rule, event = null) => {
  if (!rule || (!rule.active && !canEnable(rule))) {
    if (event?.target) event.target.checked = Boolean(rule?.active);
    return;
  }
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
        if (event?.target) event.target.checked = Boolean(rule.active);
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
      calendar_managed: true,
      calendar_context: true,
    });
    await store.dispatch('automations/get');
  } catch {
    if (event?.target) event.target.checked = Boolean(rule.active);
    useAlert(L('SAVE_ERROR'));
  }
};

const handlePresetToggle = async (preset, event = null) => {
  const existingRule = presetRule(preset);
  if (existingRule) {
    await toggle(existingRule, event);
    return;
  }
  if (!canTogglePreset(preset)) {
    if (event?.target) event.target.checked = false;
    return;
  }
  await saveInlinePreset(preset, { forceActive: true });
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

const handlePackGenerated = async () => {
  await syncTemplates();
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
  if (!selectedInboxId.value && whatsAppInboxes.value.length >= 1) {
    selectedInboxId.value = String(whatsAppInboxes.value[0].id);
  }
});
</script>

<template>
  <div class="flex h-full min-h-0 flex-col bg-n-surface-1">
    <SchedulingPageHeader :title="L('TITLE')" :subtitle="L('SUBTITLE')" />
    <div class="flex-1 overflow-y-auto p-3 sm:p-6">
      <div class="mx-auto max-w-5xl space-y-5">
        <section
          class="flex flex-wrap items-end gap-3 rounded-2xl border border-n-weak bg-n-solid-2 p-4"
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
                :value="String(inbox.id)"
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
            data-testid="open-template-pack-btn"
            class="inline-flex items-center gap-1.5 rounded-lg bg-n-brand px-3.5 py-2 text-sm font-medium text-white"
            :disabled="!selectedInboxId"
            @click="templatePackDialogRef?.open()"
          >
            <span class="i-lucide-sparkles size-4" />
            <span>{{ L('TEMPLATE_PACK') }}</span>
          </button>
          <button
            type="button"
            class="rounded-lg border border-n-weak px-3 py-2 text-sm text-n-slate-12"
            :disabled="!selectedInboxId"
            @click="createTemplateDialogRef?.open()"
          >
            {{ L('NEW_TEMPLATE') }}
          </button>
          <button
            type="button"
            class="rounded-lg border border-n-weak px-3 py-2 text-sm text-n-slate-12"
            :disabled="!selectedInboxId || syncing"
            @click="syncTemplates"
          >
            {{ L('SYNC_META') }}
          </button>
        </div>

        <p v-if="!notificationRules.length" class="text-sm text-n-slate-11">
          {{ L('FIRST_RUN') }}
        </p>

        <section>
          <h2 class="mb-3 text-base font-semibold text-n-slate-12">
            {{ L('PRESETS') }}
          </h2>
          <div class="space-y-3">
            <article
              v-for="preset in APPOINTMENT_REMINDER_PRESETS"
              :key="preset.key"
              :data-testid="`reminder-preset-card-${preset.key}`"
              class="rounded-2xl border border-n-weak bg-n-solid-2 transition-colors"
            >
              <div
                class="flex cursor-pointer flex-wrap items-center justify-between gap-4 px-5 py-4"
                @click="
                  expandedPresetKey =
                    expandedPresetKey === preset.key ? '' : preset.key
                "
              >
                <div class="flex min-w-0 flex-1 items-start gap-3.5">
                  <div
                    class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-n-brand/10 text-n-brand"
                  >
                    <span class="size-5" :class="preset.icon" />
                  </div>
                  <div class="min-w-0 flex-1">
                    <div class="flex flex-wrap items-center gap-2">
                      <h3 class="m-0 text-sm font-semibold text-n-slate-12">
                        {{
                          t(`SCHEDULING.REMINDERS.PRESETS.${preset.key}.TITLE`)
                        }}
                      </h3>
                      <span
                        class="rounded-md px-2 py-0.5 text-[11px] font-medium"
                        :class="{
                          'bg-n-teal-9/15 text-n-teal-11':
                            getPresetStatusBadge(preset).tone === 'teal',
                          'bg-n-amber-9/15 text-n-amber-11':
                            getPresetStatusBadge(preset).tone === 'amber',
                          'bg-n-ruby-9/15 text-n-ruby-11':
                            getPresetStatusBadge(preset).tone === 'ruby',
                          'bg-n-alpha-black2 text-n-slate-11':
                            getPresetStatusBadge(preset).tone === 'slate',
                        }"
                      >
                        {{ getPresetStatusBadge(preset).label }}
                      </span>
                      <span
                        v-if="ruleMinMinutes(presetRule(preset))"
                        data-testid="preset-min-minutes-badge"
                        :data-min-minutes="ruleMinMinutes(presetRule(preset))"
                        class="rounded-md bg-n-alpha-black2 px-2 py-0.5 text-[11px] font-medium text-n-slate-11"
                      >
                        {{
                          t(
                            'SCHEDULING.NOTIFICATIONS.MIN_MINUTES_BEFORE_SUMMARY',
                            { minutes: ruleMinMinutes(presetRule(preset)) }
                          )
                        }}
                      </span>
                    </div>

                    <p class="mb-1 mt-1 text-xs text-n-slate-11">
                      {{
                        presetRule(preset)
                          ? summary(presetRule(preset))
                          : t(
                              `SCHEDULING.REMINDERS.PRESETS.${preset.key}.DESCRIPTION`
                            )
                      }}
                    </p>

                    <p class="m-0 text-xs text-n-slate-11">
                      {{
                        presetRule(preset)
                          ? touchParams(presetRule(preset)).template_params
                              ?.name || L('NO_TEMPLATE')
                          : getSelectedTemplateForPreset(preset.key)?.name ||
                            presetTemplate(preset)?.name ||
                            L('NO_TEMPLATE')
                      }}
                      ·
                      {{
                        presetRule(preset)
                          ? templateStatus(presetRule(preset))
                          : presetTemplateStatus(preset)
                      }}
                      · {{ L('CONDITIONS') }}:
                      {{ conditionsSummaryText(presetRule(preset)) }}
                    </p>
                  </div>
                </div>

                <div class="flex items-center gap-3" @click.stop>
                  <label
                    class="relative inline-flex cursor-pointer items-center"
                  >
                    <input
                      type="checkbox"
                      role="switch"
                      class="peer sr-only"
                      :aria-label="
                        t(`SCHEDULING.REMINDERS.PRESETS.${preset.key}.TITLE`)
                      "
                      :checked="Boolean(presetRule(preset)?.active)"
                      :disabled="!canTogglePreset(preset)"
                      @change="handlePresetToggle(preset, $event)"
                    />
                    <span
                      class="h-5 w-9 rounded-full bg-n-slate-6 transition-colors after:absolute after:left-[2px] after:top-[2px] after:size-4 after:rounded-full after:bg-white after:transition-transform peer-checked:bg-n-brand peer-checked:after:translate-x-4 peer-disabled:cursor-not-allowed peer-disabled:opacity-50"
                    />
                  </label>

                  <span
                    class="size-4 block text-n-slate-11 transition-transform"
                    :class="
                      expandedPresetKey === preset.key
                        ? 'i-lucide-chevron-up'
                        : 'i-lucide-chevron-down'
                    "
                    @click="
                      expandedPresetKey =
                        expandedPresetKey === preset.key ? '' : preset.key
                    "
                  />
                </div>
              </div>

              <div
                v-if="expandedPresetKey === preset.key"
                class="border-t border-n-weak px-5 py-5"
              >
                <div class="grid grid-cols-1 gap-6 lg:grid-cols-12">
                  <div class="space-y-4 lg:col-span-7">
                    <div class="space-y-1.5">
                      <label class="block text-xs font-medium text-n-slate-12">
                        {{ t('SCHEDULING.REMINDERS.FIELDS.TEMPLATE') }}
                      </label>
                      <select
                        :value="presetStates[preset.key].templateKey"
                        class="w-full rounded-lg border border-n-weak bg-n-surface-1 p-2 text-sm text-n-slate-12"
                        @change="
                          e =>
                            handleInlineTemplateChange(preset, e.target.value)
                        "
                      >
                        <option value="">{{ L('CHOOSE') }}</option>
                        <option
                          v-for="tpl in pageTemplates"
                          :key="makeTemplateKey(tpl)"
                          :value="makeTemplateKey(tpl)"
                        >
                          {{ tpl.name }} ({{
                            (tpl.language || 'ru').toUpperCase()
                          }}
                          ·
                          {{
                            L(
                              `TEMPLATE_STATUS.${String(tpl.status || 'PENDING').toUpperCase()}`
                            )
                          }})
                        </option>
                      </select>
                    </div>

                    <div
                      v-if="preset.supportsDayBeforeTime"
                      class="grid grid-cols-1 gap-4 sm:grid-cols-2"
                    >
                      <label class="block text-xs font-medium text-n-slate-12">
                        {{ t('SCHEDULING.REMINDERS.FIELDS.DAY_BEFORE_TIME') }}
                        <input
                          v-model="presetStates[preset.key].dayBeforeTime"
                          type="time"
                          data-testid="preset-day-before-time-input"
                          class="mt-1 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2 text-sm text-n-slate-12"
                        />
                      </label>

                      <div
                        v-if="preset.supportsConfirmation"
                        class="flex flex-col justify-center rounded-xl border border-n-weak bg-n-alpha-black2 px-3.5 py-2.5"
                      >
                        <label
                          class="flex cursor-pointer items-center justify-between gap-2"
                        >
                          <span class="text-xs font-medium text-n-slate-12">
                            {{
                              t(
                                'SCHEDULING.REMINDERS.FIELDS.CONFIRM_VIA_BUTTON'
                              )
                            }}
                          </span>
                          <input
                            v-model="
                              presetStates[preset.key].confirmationEnabled
                            "
                            type="checkbox"
                            data-testid="preset-confirmation-checkbox"
                            class="rounded border-n-weak text-n-brand"
                          />
                        </label>
                        <p class="mb-0 mt-1 text-[11px] text-n-slate-11">
                          {{
                            t(
                              'SCHEDULING.REMINDERS.FIELDS.CONFIRM_VIA_BUTTON_HINT'
                            )
                          }}
                        </p>
                      </div>
                    </div>

                    <div v-if="preset.supportsReviewDelay" class="space-y-1.5">
                      <label class="block text-xs font-medium text-n-slate-12">
                        {{ t('SCHEDULING.REMINDERS.FIELDS.REVIEW_DELAY') }}
                        <select
                          v-model.number="
                            presetStates[preset.key].reviewDelayHours
                          "
                          data-testid="preset-review-delay-select"
                          class="mt-1 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2 text-sm text-n-slate-12"
                        >
                          <option :value="0">
                            {{
                              t('SCHEDULING.REMINDERS.REVIEW_DELAY.IMMEDIATE')
                            }}
                          </option>
                          <option :value="1">
                            {{ t('SCHEDULING.REMINDERS.REVIEW_DELAY.HOURS_1') }}
                          </option>
                          <option :value="2">
                            {{ t('SCHEDULING.REMINDERS.REVIEW_DELAY.HOURS_2') }}
                          </option>
                          <option :value="3">
                            {{ t('SCHEDULING.REMINDERS.REVIEW_DELAY.HOURS_3') }}
                          </option>
                        </select>
                      </label>
                    </div>

                    <div
                      v-if="supportsMinMinutesBefore(preset.eventName)"
                      class="space-y-1.5"
                    >
                      <label class="block text-xs font-medium text-n-slate-12">
                        {{
                          t(
                            'SCHEDULING.REMINDERS.FIELDS.MIN_MINUTES_BEFORE_APPOINTMENT'
                          )
                        }}
                        <input
                          v-model="
                            presetStates[preset.key].minMinutesBeforeAppointment
                          "
                          type="number"
                          min="1"
                          max="43200"
                          step="1"
                          data-testid="preset-min-minutes-input"
                          :placeholder="L('MIN_MINUTES_BEFORE_PLACEHOLDER')"
                          class="mt-1 w-full rounded-lg border border-n-weak bg-n-surface-1 p-2 text-sm text-n-slate-12"
                        />
                      </label>
                      <p class="m-0 text-[11px] text-n-slate-11">
                        {{
                          t(
                            'SCHEDULING.REMINDERS.FIELDS.MIN_MINUTES_BEFORE_APPOINTMENT_HINT'
                          )
                        }}
                      </p>
                    </div>

                    <div
                      v-if="
                        getTemplateBodyVars(
                          getSelectedTemplateForPreset(preset.key)
                        ).length
                      "
                      class="space-y-2.5 rounded-xl border border-n-weak bg-n-alpha-black2 p-3.5"
                    >
                      <p class="mb-0 text-xs font-medium text-n-slate-12">
                        {{ t('SCHEDULING.REMINDERS.FIELDS.VARIABLE_BINDINGS') }}
                      </p>
                      <div class="grid grid-cols-1 gap-2.5 sm:grid-cols-2">
                        <div
                          v-for="varKey in getTemplateBodyVars(
                            getSelectedTemplateForPreset(preset.key)
                          )"
                          :key="`${preset.key}-var-${varKey}`"
                          class="flex flex-col gap-1"
                        >
                          <span class="font-mono text-[11px] text-n-slate-11">
                            {{ `\{\{${varKey}\}\}` }}
                          </span>
                          <select
                            v-model="
                              presetStates[preset.key].variableBindings[varKey]
                            "
                            class="rounded-lg border border-n-weak bg-n-surface-1 p-1.5 text-xs text-n-slate-12"
                          >
                            <option value="">{{ L('CHOOSE') }}</option>
                            <option
                              v-for="field in APPOINTMENT_SEMANTIC_VARIABLES"
                              :key="field.key"
                              :value="field.key"
                            >
                              {{ t(field.labelKey, field.defaultLabel) }} —
                              {{ field.example }}
                            </option>
                          </select>
                        </div>
                      </div>
                    </div>

                    <div class="flex items-center justify-end gap-2 pt-1">
                      <span
                        role="button"
                        tabindex="0"
                        data-testid="save-inline-preset-btn"
                        class="cursor-pointer rounded-lg bg-n-brand px-3 py-1.5 text-xs font-medium text-white"
                        @click="saveInlinePreset(preset)"
                      >
                        {{ t('SCHEDULING.REMINDERS.ACTIONS.SAVE_PRESET') }}
                      </span>
                    </div>
                  </div>

                  <div class="lg:col-span-5">
                    <div
                      class="rounded-2xl border border-n-weak bg-[#efeae2] dark:bg-n-solid-3 p-4"
                    >
                      <p
                        class="mb-2.5 text-xs font-medium uppercase tracking-wide text-n-slate-11"
                      >
                        {{ t('SCHEDULING.REMINDERS.PREVIEW.TITLE') }}
                      </p>

                      <div
                        v-if="getSelectedTemplateForPreset(preset.key)"
                        class="rounded-2xl rounded-tl-sm bg-white dark:bg-n-solid-2 p-3.5 shadow-sm"
                      >
                        <p
                          data-testid="preset-whatsapp-preview-text"
                          class="mb-0 whitespace-pre-line text-sm leading-relaxed text-n-slate-12"
                        >
                          {{ renderLiveTemplatePreview(preset) }}
                        </p>

                        <div
                          v-if="getTemplateButtonsForPreview(preset).length"
                          class="mt-3 flex flex-col gap-1.5 border-t border-n-weak pt-2"
                        >
                          <div
                            v-for="(btn, bIdx) in getTemplateButtonsForPreview(
                              preset
                            )"
                            :key="bIdx"
                            class="flex items-center justify-center gap-1.5 rounded-lg bg-n-alpha-black2 py-1.5 text-xs font-medium text-n-brand"
                          >
                            <span
                              :class="
                                String(btn.type || '').toUpperCase() === 'URL'
                                  ? 'i-lucide-external-link size-3.5'
                                  : 'i-lucide-reply size-3.5'
                              "
                            />
                            <span>{{ btn.text }}</span>
                          </div>
                        </div>
                      </div>

                      <div
                        v-else
                        role="button"
                        tabindex="0"
                        class="w-full cursor-pointer rounded-xl border border-dashed border-n-weak bg-white/60 dark:bg-n-solid-2/60 p-6 text-center text-xs text-n-slate-11 transition-colors hover:border-n-brand/60 hover:text-n-brand"
                        @click="templatePackDialogRef?.open()"
                      >
                        {{ t('SCHEDULING.REMINDERS.PREVIEW.EMPTY') }}
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </article>
          </div>
        </section>

        <section v-if="otherRules.length">
          <h2 class="mb-3 text-base font-semibold text-n-slate-12">
            {{ L('OTHER_RULES') }}
          </h2>
          <article
            v-for="rule in otherRules"
            :key="rule.id"
            :data-testid="`other-rule-card-${rule.id}`"
            class="mb-2 flex flex-wrap items-center gap-3 rounded-xl border border-n-weak bg-n-solid-2 p-4"
          >
            <div class="min-w-48 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <p class="m-0 font-semibold text-n-slate-12">{{ rule.name }}</p>
                <span
                  v-if="ruleMinMinutes(rule)"
                  data-testid="other-rule-min-minutes-badge"
                  :data-min-minutes="ruleMinMinutes(rule)"
                  class="rounded-md bg-n-alpha-black2 px-2 py-0.5 text-[11px] font-medium text-n-slate-11"
                >
                  {{
                    t('SCHEDULING.NOTIFICATIONS.MIN_MINUTES_BEFORE_SUMMARY', {
                      minutes: ruleMinMinutes(rule),
                    })
                  }}
                </span>
              </div>
              <p class="m-0 text-sm text-n-slate-11">
                {{ eventLabel(eventKeyForRule(rule)) }} · {{ summary(rule) }} ·
                {{
                  touchParams(rule).template_params?.name ||
                  touchParams(rule).body ||
                  L('NO_CONTENT')
                }}
                · {{ L('CONDITIONS') }}: {{ conditionsSummaryText(rule) }}
              </p>
              <div
                v-if="
                  (rule.calendar_managed || firstTouch(rule)) &&
                  supportsMinMinutesBefore(rule.event_name)
                "
                class="mt-2.5 flex flex-wrap items-center gap-2"
              >
                <label class="flex items-center gap-2 text-xs text-n-slate-11">
                  <span>{{ L('MIN_MINUTES_BEFORE_LABEL') }}</span>
                  <input
                    v-model="otherRuleMinMinutesDrafts[rule.id]"
                    type="number"
                    min="1"
                    max="43200"
                    step="1"
                    data-testid="other-rule-min-minutes-input"
                    :placeholder="L('MIN_MINUTES_BEFORE_PLACEHOLDER')"
                    class="w-24 rounded-lg border border-n-weak bg-n-surface-1 px-2 py-1 text-xs text-n-slate-12"
                  />
                </label>
                <button
                  type="button"
                  data-testid="save-other-rule-min-minutes-btn"
                  class="rounded-lg border border-n-weak px-2.5 py-1 text-xs font-medium text-n-slate-12 hover:border-n-brand hover:text-n-brand"
                  :disabled="savingOtherRuleId === rule.id"
                  @click="saveOtherRuleMinMinutes(rule)"
                >
                  {{ L('SAVE') }}
                </button>
              </div>
            </div>
            <template v-if="rule.calendar_managed || firstTouch(rule)">
              <label class="relative inline-flex cursor-pointer items-center">
                <input
                  type="checkbox"
                  role="switch"
                  class="peer sr-only"
                  :aria-label="rule.name"
                  :checked="rule.active"
                  :disabled="!rule.active && !canEnable(rule)"
                  @change="toggle(rule, $event)"
                />
                <span
                  class="h-5 w-9 rounded-full bg-n-slate-6 transition-colors after:absolute after:left-[2px] after:top-[2px] after:size-4 after:rounded-full after:bg-white after:transition-transform peer-checked:bg-n-brand peer-checked:after:translate-x-4 peer-disabled:cursor-not-allowed peer-disabled:opacity-50"
                />
              </label>
            </template>
            <span v-else class="text-sm text-n-slate-11">{{
              L('MANAGE_IN_AUTOMATIONS')
            }}</span>
          </article>
        </section>
      </div>
    </div>
    <AppointmentTemplatePackDialog
      ref="templatePackDialogRef"
      :inbox-id="Number(selectedInboxId) || null"
      :existing-template-names="pageTemplates.map(item => item.name)"
      :existing-templates="pageTemplates"
      :default-company-name="currentAccount?.name || ''"
      :account-client-languages="
        currentAccount?.settings?.client_languages || ['ru', 'kk']
      "
      :default-bilingual="
        Boolean(currentAccount?.settings?.bilingual_templates_enabled)
      "
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
