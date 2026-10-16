<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import { useMapGetter, useStore } from 'dashboard/composables/store';

import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
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

const { t } = useI18n();
const store = useStore();
const { currentAccount } = useAccount();

const allInboxes = useMapGetter('inboxes/getAllInboxes');
const allAutomations = useMapGetter('automations/getAutomations');
const automationUIFlags = useMapGetter('automations/getUIFlags');

const selectedInboxId = ref(null);
const expandedPresetKey = ref(APPOINTMENT_REMINDER_PRESETS[0].key);
const isSyncingTemplates = ref(false);
const savingPresetKey = ref('');
const templatePackDialogRef = ref(null);
const createTemplateDialogRef = ref(null);

const browserTimezone =
  Intl.DateTimeFormat().resolvedOptions().timeZone || 'Asia/Almaty';

const createDefaultPresetDraft = preset => ({
  enabled: false,
  templateKey: '',
  dayBeforeTime: preset.relativeTimeOfDay || '15:00',
  confirmationEnabled: Boolean(preset.supportsConfirmation),
  reviewDelayHours: 1,
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

const whatsAppInboxes = computed(() =>
  (allInboxes.value || []).filter(
    inbox => inbox.channel_type === INBOX_TYPES.WHATSAPP
  )
);

const selectedInbox = computed(
  () =>
    whatsAppInboxes.value.find(
      inbox => Number(inbox.id) === Number(selectedInboxId.value)
    ) || null
);

const inboxOptions = computed(() =>
  whatsAppInboxes.value.map(inbox => ({
    value: inbox.id,
    label: inbox.name,
  }))
);

const rawTemplates = computed(() =>
  Array.isArray(selectedInbox.value?.message_templates)
    ? selectedInbox.value.message_templates
    : []
);

const makeTemplateKey = template =>
  `${String(template?.name || '').trim()}::${String(template?.language || 'ru').trim()}`;

const templateByKey = computed(() => {
  const map = new Map();
  rawTemplates.value.forEach(template => {
    if (template?.name) {
      map.set(makeTemplateKey(template), template);
    }
  });
  return map;
});

const existingTemplateNames = computed(() => [
  ...new Set(rawTemplates.value.map(item => item?.name).filter(Boolean)),
]);

const approvedTemplatesCount = computed(
  () =>
    rawTemplates.value.filter(
      item => String(item?.status || '').toUpperCase() === 'APPROVED'
    ).length
);

const pendingTemplatesCount = computed(
  () =>
    rawTemplates.value.filter(
      item => String(item?.status || '').toUpperCase() === 'PENDING'
    ).length
);

const templateSelectOptions = computed(() =>
  rawTemplates.value.map(template => {
    const status = String(template.status || 'PENDING').toUpperCase();
    const statusLabel = t(
      `SCHEDULING.REMINDERS.TEMPLATE_STATUS.${status}`,
      status
    );
    return {
      value: makeTemplateKey(template),
      label: `${template.name} (${(template.language || 'ru').toUpperCase()} · ${statusLabel})`,
    };
  })
);

const semanticFieldOptions = computed(() =>
  APPOINTMENT_SEMANTIC_VARIABLES.map(item => ({
    value: item.key,
    label: `${t(item.labelKey, item.defaultLabel)} (${item.example})`,
  }))
);

const reviewDelayOptions = computed(() => [
  { value: 0, label: t('SCHEDULING.REMINDERS.REVIEW_DELAY.IMMEDIATE') },
  { value: 1, label: t('SCHEDULING.REMINDERS.REVIEW_DELAY.HOURS_1') },
  { value: 2, label: t('SCHEDULING.REMINDERS.REVIEW_DELAY.HOURS_2') },
  { value: 3, label: t('SCHEDULING.REMINDERS.REVIEW_DELAY.HOURS_3') },
]);

const ruleByPresetKey = computed(() => {
  const map = new Map();
  (allAutomations.value || []).forEach(rule => {
    const markerKey = extractPresetKeyFromRule(rule);
    if (markerKey) {
      map.set(markerKey, rule);
    }
  });
  return map;
});

const getSelectedTemplateForPreset = presetKey => {
  const key = presetStates[presetKey]?.templateKey;
  if (!key) return null;
  return templateByKey.value.get(key) || null;
};

const getTemplateBodyVars = template => {
  if (!template) return [];
  return getTemplateParameterDefinitions(template)
    .filter(def => def.section === 'body')
    .map(def => def.key.replace(/^body\./, ''));
};

const templateSupportsQuickReplyConfirmation = template => {
  if (!template?.components) return false;
  const buttonsComp = template.components.find(
    comp => String(comp.type || '').toUpperCase() === 'BUTTONS'
  );
  const buttons = Array.isArray(buttonsComp?.buttons)
    ? buttonsComp.buttons
    : [];
  return (
    buttons.length === 1 &&
    String(buttons[0]?.type || '').toUpperCase() === 'QUICK_REPLY'
  );
};

const ensureDefaultBindingsForPreset = preset => {
  const state = presetStates[preset.key];
  const template = getSelectedTemplateForPreset(preset.key);
  const vars = getTemplateBodyVars(template);
  if (!vars.length) return;

  const updated = { ...state.variableBindings };
  vars.forEach((varKey, idx) => {
    if (!updated[varKey]) {
      const defaultSemanticKey =
        preset.defaultVariableOrder[idx] ||
        APPOINTMENT_SEMANTIC_VARIABLES[0].key;
      updated[varKey] = defaultSemanticKey;
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
    const existingRule = ruleByPresetKey.value.get(preset.key);
    const touchAction = existingRule?.actions?.find(
      act => act.action_name === 'create_touch'
    );
    const rawTouch = Array.isArray(touchAction?.action_params)
      ? touchAction.action_params[0]
      : touchAction?.action_params;

    if (existingRule && rawTouch) {
      state.enabled = Boolean(existingRule.active);
      const tplParams = rawTouch.template_params || {};
      if (tplParams.name) {
        const candidateKey = `${tplParams.name}::${tplParams.language || 'ru'}`;
        const matchedTpl =
          templateByKey.value.get(candidateKey) ||
          rawTemplates.value.find(item => item.name === tplParams.name);
        if (matchedTpl) {
          state.templateKey = makeTemplateKey(matchedTpl);
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

      const bodyParams = tplParams.processed_params?.body || {};
      const parsedBindings = {};
      Object.entries(bodyParams).forEach(([varIndex, rawRef]) => {
        const semKey = resolveSemanticKeyFromStoredParam(rawRef);
        if (semKey) {
          parsedBindings[varIndex] = semKey;
        }
      });
      state.variableBindings = parsedBindings;
    } else if (!state.templateKey) {
      const defaultMatch = rawTemplates.value.find(
        item => item.name === preset.templateName
      );
      if (defaultMatch) {
        state.templateKey = makeTemplateKey(defaultMatch);
      }
    }

    ensureDefaultBindingsForPreset(preset);
  });
};

watch(
  whatsAppInboxes,
  inboxes => {
    if (
      !inboxes.some(inbox => Number(inbox.id) === Number(selectedInboxId.value))
    ) {
      selectedInboxId.value = inboxes[0]?.id || null;
    }
  },
  { immediate: true }
);

watch(
  [rawTemplates, allAutomations],
  () => {
    hydratePresetsFromRulesAndTemplates();
  },
  { immediate: true }
);

const activePresetsCount = computed(
  () =>
    APPOINTMENT_REMINDER_PRESETS.filter(
      preset => presetStates[preset.key]?.enabled
    ).length
);

const getPresetStatusBadge = preset => {
  const state = presetStates[preset.key];
  const template = getSelectedTemplateForPreset(preset.key);
  if (!template) {
    return {
      tone: 'slate',
      label: t('SCHEDULING.REMINDERS.STATUS.NO_TEMPLATE'),
    };
  }
  const tplStatus = String(template.status || 'PENDING').toUpperCase();
  if (tplStatus !== 'APPROVED') {
    return {
      tone: tplStatus === 'REJECTED' ? 'ruby' : 'amber',
      label: t(`SCHEDULING.REMINDERS.TEMPLATE_STATUS.${tplStatus}`, tplStatus),
    };
  }
  if (state.enabled) {
    return {
      tone: 'teal',
      label: t('SCHEDULING.REMINDERS.STATUS.ACTIVE'),
    };
  }
  return {
    tone: 'slate',
    label: t('SCHEDULING.REMINDERS.STATUS.INACTIVE'),
  };
};

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

const handleTemplateSelectionChange = (preset, newTemplateKey) => {
  presetStates[preset.key].templateKey = newTemplateKey;
  ensureDefaultBindingsForPreset(preset);
};

const syncTemplatesFromMeta = async () => {
  if (!selectedInboxId.value) return;
  try {
    isSyncingTemplates.value = true;
    await store.dispatch('inboxes/syncTemplates', selectedInboxId.value);
    useAlert(t('INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_TEMPLATES_SYNC_SUCCESS'));
  } catch (error) {
    useAlert(error.message);
  } finally {
    isSyncingTemplates.value = false;
  }
};

const openTemplatePackModal = () => {
  templatePackDialogRef.value?.open();
};

const openCreateTemplateModal = () => {
  createTemplateDialogRef.value?.open();
};

const handlePackGenerated = ({ drafts }) => {
  drafts.forEach(draft => {
    const preset = APPOINTMENT_REMINDER_PRESETS.find(
      item => item.key === draft.presetKey
    );
    if (!preset) return;
    const matched = rawTemplates.value.find(item => item.name === draft.name);
    if (matched) {
      presetStates[preset.key].templateKey = makeTemplateKey(matched);
      ensureDefaultBindingsForPreset(preset);
    }
  });
};

const buildAutomationRulePayload = preset => {
  const state = presetStates[preset.key];
  const template = getSelectedTemplateForPreset(preset.key);
  if (!template) {
    throw new Error(t('SCHEDULING.REMINDERS.ERRORS.TEMPLATE_REQUIRED'));
  }

  const isApproved = String(template.status || '').toUpperCase() === 'APPROVED';

  const bodyVars = getTemplateBodyVars(template);
  const bodyProcessedParams = {};
  bodyVars.forEach(varKey => {
    const semKey =
      state.variableBindings?.[varKey] || APPOINTMENT_SEMANTIC_VARIABLES[0].key;
    bodyProcessedParams[varKey] = buildFieldReferenceForSemanticKey(semKey);
  });

  let offsetSeconds = preset.relativeOffsetSeconds;
  if (preset.supportsReviewDelay) {
    const hrs = Number(state.reviewDelayHours || 0);
    offsetSeconds = hrs <= 0 ? 60 : hrs * 3600;
  }

  const canConfirm =
    preset.supportsConfirmation &&
    state.confirmationEnabled &&
    templateSupportsQuickReplyConfirmation(template);

  return {
    name: t(`SCHEDULING.REMINDERS.PRESETS.${preset.key}.TITLE`),
    description: `${t(`SCHEDULING.REMINDERS.PRESETS.${preset.key}.DESCRIPTION`)} ${buildPresetMarker(preset.key)}`,
    event_name: preset.eventName,
    active: Boolean(state.enabled && isApproved),
    conditions: [
      {
        attribute_key: 'source',
        filter_operator: 'is_present',
        values: [],
        query_operator: null,
      },
    ],
    actions: [
      {
        action_name: 'create_touch',
        action_params: [
          {
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
            target_inbox_id: selectedInboxId.value,
            timezone: browserTimezone,
            response_action: canConfirm ? 'confirm_appointment' : '',
            response_button_index: canConfirm ? 0 : '',
            template_params: {
              name: template.name,
              language: template.language || 'ru',
              category: template.category || 'UTILITY',
              processed_params: {
                body: bodyProcessedParams,
              },
            },
          },
        ],
      },
    ],
  };
};

const savePreset = async preset => {
  if (!selectedInboxId.value) {
    useAlert(t('SCHEDULING.REMINDERS.ERRORS.INBOX_REQUIRED'));
    return;
  }

  try {
    savingPresetKey.value = preset.key;
    const payload = buildAutomationRulePayload(preset);
    const existingRule = ruleByPresetKey.value.get(preset.key);

    if (existingRule?.id) {
      await store.dispatch('automations/update', {
        id: existingRule.id,
        ...payload,
      });
    } else {
      await store.dispatch('automations/create', payload);
    }

    await store.dispatch('automations/get');
    useAlert(t('SCHEDULING.REMINDERS.SAVE_SUCCESS'));
  } catch (error) {
    useAlert(error.message || t('SCHEDULING.REMINDERS.SAVE_ERROR'));
  } finally {
    savingPresetKey.value = '';
  }
};

const handleTogglePreset = async (preset, nextEnabled) => {
  presetStates[preset.key].enabled = nextEnabled;
  const template = getSelectedTemplateForPreset(preset.key);
  if (!template) {
    expandedPresetKey.value = preset.key;
    return;
  }
  await savePreset(preset);
};

onMounted(() => {
  store.dispatch('automations/get');
});
</script>

<template>
  <div class="flex h-full min-h-0 flex-col bg-n-surface-1">
    <SchedulingPageHeader
      :title="t('SCHEDULING.REMINDERS.HEADER.TITLE')"
      :subtitle="t('SCHEDULING.REMINDERS.HEADER.SUBTITLE')"
    >
      <template #actions>
        <div class="flex flex-wrap items-center gap-2">
          <Button
            variant="faded"
            color="slate"
            size="sm"
            icon="i-lucide-refresh-cw"
            :label="t('SCHEDULING.REMINDERS.ACTIONS.SYNC_TEMPLATES')"
            :disabled="!selectedInboxId || isSyncingTemplates"
            :is-loading="isSyncingTemplates"
            @click="syncTemplatesFromMeta"
          />
          <Button
            variant="outline"
            color="slate"
            size="sm"
            icon="i-lucide-plus"
            :label="t('SCHEDULING.REMINDERS.ACTIONS.CREATE_CUSTOM_TEMPLATE')"
            :disabled="!selectedInboxId"
            @click="openCreateTemplateModal"
          />
          <Button
            data-testid="open-template-pack-btn"
            size="sm"
            icon="i-lucide-sparkles"
            :label="t('SCHEDULING.REMINDERS.ACTIONS.GENERATE_PACK')"
            :disabled="!selectedInboxId"
            @click="openTemplatePackModal"
          />
        </div>
      </template>
    </SchedulingPageHeader>

    <div class="flex-1 overflow-y-auto px-6 py-5">
      <div class="mx-auto max-w-5xl space-y-6">
        <div
          class="flex flex-col gap-4 rounded-2xl border border-n-weak bg-n-solid-2 p-4 sm:flex-row sm:items-center sm:justify-between"
        >
          <div class="flex flex-wrap items-center gap-4">
            <div class="min-w-64">
              <label class="mb-1 block text-xs font-medium text-n-slate-11">
                {{ t('SCHEDULING.REMINDERS.CHANNEL_LABEL') }}
              </label>
              <ComboBox
                v-if="whatsAppInboxes.length"
                v-model="selectedInboxId"
                :options="inboxOptions"
                input-like
              />
              <p v-else class="mb-0 text-sm text-n-ruby-11">
                {{ t('SCHEDULING.REMINDERS.NO_WHATSAPP_INBOX') }}
              </p>
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-2.5 text-xs">
            <span
              class="inline-flex items-center gap-1.5 rounded-lg bg-n-alpha-black2 px-3 py-1.5 font-medium text-n-slate-12"
            >
              <span class="i-lucide-zap size-3.5 text-n-brand" />
              {{
                t('SCHEDULING.REMINDERS.SUMMARY.ACTIVE_PRESETS', {
                  active: activePresetsCount,
                  total: APPOINTMENT_REMINDER_PRESETS.length,
                })
              }}
            </span>
            <span
              class="inline-flex items-center gap-1.5 rounded-lg bg-n-teal-9/10 px-3 py-1.5 font-medium text-n-teal-11"
            >
              <span class="i-lucide-check-circle-2 size-3.5" />
              {{
                t('SCHEDULING.REMINDERS.SUMMARY.APPROVED_TEMPLATES', {
                  count: approvedTemplatesCount,
                })
              }}
            </span>
            <span
              v-if="pendingTemplatesCount > 0"
              class="inline-flex items-center gap-1.5 rounded-lg bg-n-amber-9/10 px-3 py-1.5 font-medium text-n-amber-11"
            >
              <span class="i-lucide-clock size-3.5" />
              {{
                t('SCHEDULING.REMINDERS.SUMMARY.PENDING_TEMPLATES', {
                  count: pendingTemplatesCount,
                })
              }}
            </span>
          </div>
        </div>

        <div class="space-y-3">
          <div
            v-for="preset in APPOINTMENT_REMINDER_PRESETS"
            :key="preset.key"
            :data-testid="`reminder-preset-card-${preset.key}`"
            class="rounded-2xl border border-n-weak bg-n-solid-2 transition-colors"
          >
            <div
              class="flex cursor-pointer items-center justify-between gap-4 px-5 py-4"
              @click="
                expandedPresetKey =
                  expandedPresetKey === preset.key ? '' : preset.key
              "
            >
              <div class="flex min-w-0 items-center gap-3.5">
                <div
                  class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-n-brand/10 text-n-brand"
                >
                  <span class="size-5" :class="preset.icon" />
                </div>
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="mb-0 text-sm font-semibold text-n-slate-12">
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
                  </div>
                  <p class="mb-0 mt-0.5 text-xs text-n-slate-11">
                    {{
                      t(
                        `SCHEDULING.REMINDERS.PRESETS.${preset.key}.DESCRIPTION`
                      )
                    }}
                  </p>
                </div>
              </div>

              <div class="flex items-center gap-3" @click.stop>
                <Switch
                  :model-value="presetStates[preset.key].enabled"
                  @update:model-value="val => handleTogglePreset(preset, val)"
                />
                <button
                  type="button"
                  class="rounded-lg p-1.5 text-n-slate-11 hover:bg-n-alpha-black2 hover:text-n-slate-12"
                  @click="
                    expandedPresetKey =
                      expandedPresetKey === preset.key ? '' : preset.key
                  "
                >
                  <span
                    class="size-4 block transition-transform"
                    :class="
                      expandedPresetKey === preset.key
                        ? 'i-lucide-chevron-up'
                        : 'i-lucide-chevron-down'
                    "
                  />
                </button>
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
                    <ComboBox
                      :model-value="presetStates[preset.key].templateKey"
                      :options="templateSelectOptions"
                      :placeholder="
                        t('SCHEDULING.REMINDERS.FIELDS.TEMPLATE_PLACEHOLDER')
                      "
                      input-like
                      @update:model-value="
                        val => handleTemplateSelectionChange(preset, val)
                      "
                    />
                  </div>

                  <div
                    v-if="preset.supportsDayBeforeTime"
                    class="grid grid-cols-1 gap-4 sm:grid-cols-2"
                  >
                    <Input
                      v-model="presetStates[preset.key].dayBeforeTime"
                      type="time"
                      :label="t('SCHEDULING.REMINDERS.FIELDS.DAY_BEFORE_TIME')"
                    />

                    <div
                      class="flex flex-col justify-center rounded-xl border border-n-weak bg-n-alpha-black2 px-3.5 py-2.5"
                    >
                      <div class="flex items-center justify-between gap-2">
                        <span class="text-xs font-medium text-n-slate-12">
                          {{
                            t('SCHEDULING.REMINDERS.FIELDS.CONFIRM_VIA_BUTTON')
                          }}
                        </span>
                        <Switch
                          v-model="presetStates[preset.key].confirmationEnabled"
                          :disabled="
                            !templateSupportsQuickReplyConfirmation(
                              getSelectedTemplateForPreset(preset.key)
                            )
                          "
                        />
                      </div>
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
                    </label>
                    <ComboBox
                      v-model="presetStates[preset.key].reviewDelayHours"
                      :options="reviewDelayOptions"
                      input-like
                    />
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
                        <ComboBox
                          v-model="
                            presetStates[preset.key].variableBindings[varKey]
                          "
                          :options="semanticFieldOptions"
                          input-like
                        />
                      </div>
                    </div>
                  </div>

                  <div class="flex items-center justify-end pt-2">
                    <Button
                      size="sm"
                      :label="t('SCHEDULING.REMINDERS.ACTIONS.SAVE_PRESET')"
                      :is-loading="
                        savingPresetKey === preset.key ||
                        automationUIFlags.isCreating ||
                        automationUIFlags.isUpdating
                      "
                      :disabled="!presetStates[preset.key].templateKey"
                      @click="savePreset(preset)"
                    />
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
                      class="rounded-xl border border-dashed border-n-weak bg-white/60 dark:bg-n-solid-2/60 p-6 text-center text-xs text-n-slate-11"
                    >
                      {{ t('SCHEDULING.REMINDERS.PREVIEW.EMPTY') }}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <AppointmentTemplatePackDialog
      ref="templatePackDialogRef"
      :inbox-id="Number(selectedInboxId)"
      :existing-template-names="existingTemplateNames"
      :default-company-name="currentAccount?.name || ''"
      @generated="handlePackGenerated"
    />

    <CreateWhatsAppTemplateDialog
      v-if="selectedInboxId"
      ref="createTemplateDialogRef"
      :inbox-id="Number(selectedInboxId)"
    />
  </div>
</template>
