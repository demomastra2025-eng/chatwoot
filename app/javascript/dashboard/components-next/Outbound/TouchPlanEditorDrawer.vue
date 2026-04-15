<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import TouchPlansAPI from 'dashboard/api/touchPlans';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingDrawer from 'dashboard/components-next/Scheduling/SchedulingDrawer.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingRelativeOffsetInput from 'dashboard/components-next/Scheduling/SchedulingRelativeOffsetInput.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import WhatsAppTemplateParser from 'dashboard/components-next/whatsapp/WhatsAppTemplateParser.vue';
import WootMessageEditor from 'dashboard/components/widgets/WootWriter/Editor.vue';
import {
  TOUCH_CREATED_AT_ANCHOR,
  buildTouchAnchorOptions,
  touchAnchorSupportedEntityKinds,
} from 'dashboard/components-next/Outbound/touchAnchors';
import {
  COMPONENT_TYPES,
  extractTemplateVariables,
  findComponentByType,
  MEDIA_FORMATS,
} from 'dashboard/helper/templateHelper';
import {
  normalizeRelativeOffset,
  resolveTouchTimingState,
  toRelativeOffsetSeconds,
  TOUCH_TIMING_STATES,
} from 'dashboard/components-next/Outbound/touchTiming';
import { detectTouchTextMode } from 'dashboard/components-next/Outbound/touchTextMode';
import {
  getInboxIconByType,
  getInboxSource,
  INBOX_TYPES,
  TWILIO_CHANNEL_MEDIUM,
} from 'dashboard/helper/inbox';
import {
  getTemplateBodyPreview,
  groupWhatsAppTemplates,
} from 'dashboard/helper/whatsappTemplateLibrary';
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

const STEP_ENTITY_KIND_ICONS = {
  appointment: 'i-lucide-calendar-clock',
  conversation: 'i-lucide-message-circle',
  deal: 'i-lucide-briefcase',
  task: 'i-lucide-list-todo',
};

const { t } = useI18n();
const store = useStore();
const getAllInboxes = useMapGetter('inboxes/getAllInboxes');
const getFilteredWhatsAppTemplates = useMapGetter(
  'inboxes/getFilteredWhatsAppTemplates'
);

const browserTimezone =
  Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

let nextStepId = 0;

const allocateStepId = () => {
  nextStepId += 1;
  return `touch-plan-step-${nextStepId}`;
};

const cloneTemplateParams = value => JSON.parse(JSON.stringify(value || {}));
const normalizeNumericId = value => {
  const numericValue = Number(value);
  return Number.isFinite(numericValue) && numericValue > 0
    ? numericValue
    : null;
};
const friendlyTemplateName = templateName =>
  String(templateName || '')
    .replace(/_/g, ' ')
    .replace(/\b\w/g, letter => letter.toUpperCase());

const form = reactive({
  deliveryInboxId: '',
  description: '',
  name: '',
  steps: [],
});

const ui = reactive({
  isSaving: false,
});

const templateParserRefs = ref({});

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
    icon: STEP_ENTITY_KIND_ICONS.conversation,
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.CONVERSATION'),
    value: 'conversation',
  },
  {
    description: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.DEAL'),
    icon: STEP_ENTITY_KIND_ICONS.deal,
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.DEAL'),
    value: 'deal',
  },
  {
    description: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.TASK'),
    icon: STEP_ENTITY_KIND_ICONS.task,
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.TASK'),
    value: 'task',
  },
  {
    description: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.APPOINTMENT'),
    icon: STEP_ENTITY_KIND_ICONS.appointment,
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

const relativeOffsetUnitOptions = computed(() => [
  {
    label: t(
      'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_UNITS.MINUTES'
    ),
    value: 'minutes',
  },
  {
    label: t(
      'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_UNITS.HOURS'
    ),
    value: 'hours',
  },
  {
    label: t(
      'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_UNITS.DAYS'
    ),
    value: 'days',
  },
]);

const timingModeTabs = computed(() => [
  {
    id: TOUCH_TIMING_STATES.ABSOLUTE,
    label: t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.ABSOLUTE_MODE'),
  },
  {
    id: TOUCH_TIMING_STATES.AFTER,
    label: t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.RELATIVE_AFTER'),
  },
  {
    id: TOUCH_TIMING_STATES.BEFORE,
    label: t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.RELATIVE_BEFORE'),
  },
]);

const inboxesList = computed(() => getAllInboxes.value || []);
const resolvedDeliveryInboxId = computed(() =>
  normalizeNumericId(form.deliveryInboxId)
);
const selectedDeliveryInbox = computed(() => {
  return (
    inboxesList.value.find(
      inbox => Number(inbox.id) === Number(resolvedDeliveryInboxId.value)
    ) || null
  );
});
const selectedDeliveryChannelType = computed(
  () => selectedDeliveryInbox.value?.channel_type || ''
);
const selectedDeliveryInboxMedium = computed(
  () => selectedDeliveryInbox.value?.medium || ''
);
const isWhatsAppTemplateCapable = computed(() => {
  if (!selectedDeliveryInbox.value) {
    return false;
  }

  return (
    selectedDeliveryChannelType.value === INBOX_TYPES.WHATSAPP ||
    (selectedDeliveryChannelType.value === INBOX_TYPES.TWILIO &&
      selectedDeliveryInboxMedium.value === TWILIO_CHANNEL_MEDIUM.WHATSAPP)
  );
});
const requiresTemplateOnly = computed(() => {
  return (
    selectedDeliveryChannelType.value === INBOX_TYPES.WHATSAPP ||
    (selectedDeliveryChannelType.value === INBOX_TYPES.TWILIO &&
      selectedDeliveryInboxMedium.value === TWILIO_CHANNEL_MEDIUM.WHATSAPP)
  );
});

const deliveryInboxOptions = computed(() => [
  {
    icon: 'i-lucide-route',
    label: t(
      'OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.DELIVERY_CHANNEL_AUTO'
    ),
    value: '',
  },
  ...inboxesList.value.map(inbox => {
    const source = getInboxSource(
      inbox.channel_type,
      inbox.phone_number,
      inbox
    );

    return {
      icon: getInboxIconByType(inbox.channel_type, inbox.medium, 'line'),
      label: source ? `${inbox.name} · ${source}` : inbox.name,
      value: Number(inbox.id),
    };
  }),
]);

const templateGroups = computed(() => {
  if (!resolvedDeliveryInboxId.value) {
    return [];
  }

  return groupWhatsAppTemplates(
    getFilteredWhatsAppTemplates.value(resolvedDeliveryInboxId.value) || []
  );
});

const templateOptions = computed(() =>
  templateGroups.value.map(templateGroup => ({
    label: friendlyTemplateName(templateGroup.name),
    value: templateGroup.name,
  }))
);

const entityKindLabel = entityKind => {
  return (
    entityKindOptions.value.find(option => option.value === entityKind)
      ?.label || entityKind
  );
};

const entityKindIcon = entityKind => {
  return (
    entityKindOptions.value.find(option => option.value === entityKind)?.icon ||
    'i-lucide-box'
  );
};

const selectedTemplateGroup = step => {
  if (!step.templateName) {
    return null;
  }

  return (
    templateGroups.value.find(group => group.name === step.templateName) || null
  );
};

const templateLanguageOptions = step => {
  return (
    selectedTemplateGroup(step)?.variants.map(template => ({
      label: template.language,
      value: template.language,
    })) || []
  );
};

const selectedTemplate = step => {
  const group = selectedTemplateGroup(step);
  if (!group || !step.templateLanguage) {
    return null;
  }

  return (
    group.variants.find(
      template => template.language === step.templateLanguage
    ) || null
  );
};

const stepContentModeTabs = computed(() => {
  const tabs = [];

  if (!requiresTemplateOnly.value) {
    tabs.push({
      id: 'free_text',
      label: t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.FREE_TEXT_TAB'),
    });
  }

  if (isWhatsAppTemplateCapable.value) {
    tabs.push({
      id: 'channel_template',
      label: t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.WHATSAPP_TEMPLATE_TAB'),
    });
  }

  return tabs;
});

const defaultEntityKind = () => {
  return (
    props.touchPlan?.entity_kinds?.[0] ||
    form.steps[0]?.entityKind ||
    'conversation'
  );
};

const inferStepEntityKind = seed => {
  if (seed.entityKind) {
    return seed.entityKind;
  }

  const supportedKinds = touchAnchorSupportedEntityKinds(seed.relative_anchor);
  const preferredKinds = Array(props.touchPlan?.entity_kinds || []);
  return (
    preferredKinds.find(kind => supportedKinds.includes(kind)) ||
    supportedKinds[0] ||
    defaultEntityKind()
  );
};

const createStep = (seed = {}) => {
  const entityKind = inferStepEntityKind(seed);
  const availableAnchors = buildTouchAnchorOptions({
    t,
    entityKinds: entityKind,
    includeTouchCreatedAt: true,
  });
  const normalizedRelativeOffset = normalizeRelativeOffset(
    seed.relative_offset_seconds
  );

  return {
    autoCancelOnIncoming: seed.auto_cancel_on_incoming ?? true,
    body: seed.content_kind === 'channel_template' ? '' : seed.body || '',
    contentKind: seed.content_kind || 'free_text',
    entityKind,
    instructions: seed.instructions || '',
    localId: allocateStepId(),
    relativeAnchor:
      seed.relative_anchor ||
      availableAnchors[0]?.value ||
      TOUCH_CREATED_AT_ANCHOR,
    relativeOffsetDirection: normalizedRelativeOffset.direction,
    relativeOffsetUnit: normalizedRelativeOffset.unit,
    relativeOffsetValue: normalizedRelativeOffset.value,
    repeatMode: seed.repeat_mode || 'once',
    repeatUntilAt: seed.repeat_until_at
      ? toDateTimeInputValue(seed.repeat_until_at)
      : '',
    scheduledAt: seed.scheduled_at
      ? toDateTimeInputValue(seed.scheduled_at)
      : '',
    templateLanguage:
      seed.template_params?.language ||
      seed.template_params?.language_code ||
      '',
    templateName: seed.template_params?.name || '',
    templateParams: cloneTemplateParams(
      seed.template_params?.processed_params || {}
    ),
    timingMode: seed.timing_mode || 'relative',
    timezone: seed.timezone || browserTimezone,
    useAiAuthoring:
      seed.content_kind === 'channel_template'
        ? false
        : seed.text_mode === 'agent',
  };
};

const stepAnchorOptions = step => {
  return buildTouchAnchorOptions({
    t,
    entityKinds: step.entityKind,
    includeTouchCreatedAt: true,
  }).map(option => ({
    label: option.label,
    value: option.value,
  }));
};

const stepSupportedEntityKinds = step => {
  return step.entityKind ? [step.entityKind] : [];
};

const derivedEntityKinds = computed(() => {
  if (!form.steps.length) {
    return [];
  }

  const supportedKinds = new Set();

  form.steps.forEach(step => {
    stepSupportedEntityKinds(step).forEach(entityKind => {
      supportedKinds.add(entityKind);
    });
  });

  return entityKindOptions.value
    .map(option => option.value)
    .filter(entityKind => supportedKinds.has(entityKind));
});

const derivedEntityKindsSummary = computed(() => {
  if (!derivedEntityKinds.value.length) {
    return t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.ENTITY_KIND_EMPTY');
  }

  return derivedEntityKinds.value.map(entityKindLabel).join(', ');
});

const templateParserRefForStep = step => {
  return templateParserRefs.value[step.localId] || null;
};

const setTemplateParserRef = (localId, componentRef) => {
  if (!componentRef) {
    delete templateParserRefs.value[localId];
    return;
  }

  templateParserRefs.value[localId] = componentRef;
};

function templateHasRequiredParams(template, templateParams = {}) {
  const bodyText =
    findComponentByType(template, COMPONENT_TYPES.BODY)?.text || '';
  const headerComponent = findComponentByType(template, COMPONENT_TYPES.HEADER);
  const headerText =
    headerComponent?.format === 'TEXT' ? headerComponent.text || '' : '';
  const bodyVariables = extractTemplateVariables(bodyText);
  const headerVariables = extractTemplateVariables(headerText);
  const hasMediaHeader = headerComponent
    ? MEDIA_FORMATS.includes(headerComponent.format)
    : false;

  if (hasMediaHeader && !templateParams?.header?.media_url) {
    return false;
  }

  if (bodyVariables.length) {
    if (!templateParams?.body) {
      return false;
    }

    const hasEmptyBodyVariable = Object.values(templateParams.body).some(
      value => !value
    );
    if (hasEmptyBodyVariable) {
      return false;
    }
  }

  if (headerVariables.length) {
    const hasEmptyHeaderVariable = headerVariables.some(
      variable => !templateParams?.header?.[variable]
    );
    if (hasEmptyHeaderVariable) {
      return false;
    }
  }

  if (templateParams.buttons?.length) {
    const hasEmptyButtonParameter = templateParams.buttons.some(
      button => !button.parameter
    );
    if (hasEmptyButtonParameter) {
      return false;
    }
  }

  return true;
}

function templateParamsForStep(step) {
  if (step.contentKind !== 'channel_template') {
    return {};
  }

  const parserRef = templateParserRefForStep(step);
  if (parserRef?.processedParams) {
    return cloneTemplateParams(parserRef.processedParams);
  }

  return cloneTemplateParams(step.templateParams);
}

const stepHasRequiredTemplateParams = step => {
  if (step.contentKind !== 'channel_template') {
    return true;
  }

  const template = selectedTemplate(step);
  const parserRef = templateParserRefForStep(step);
  if (!parserRef) {
    return (
      !!template &&
      templateHasRequiredParams(template, templateParamsForStep(step))
    );
  }

  return !!template && parserRef.isFormInvalid === false;
};

const templateBodyForStep = step => {
  if (step.contentKind !== 'channel_template') {
    return '';
  }

  const parserRef = templateParserRefForStep(step);
  if (parserRef?.rawRenderedTemplate) {
    return String(parserRef.rawRenderedTemplate || '').trim();
  }

  return String(getTemplateBodyPreview(selectedTemplate(step)) || '').trim();
};

const validateStep = step => {
  if (!step.entityKind) {
    return false;
  }

  let hasContent = false;

  if (step.contentKind === 'channel_template') {
    hasContent = stepHasRequiredTemplateParams(step);
  } else if (step.useAiAuthoring) {
    hasContent = !!String(step.instructions || '').trim();
  } else {
    hasContent = !!String(step.body || '').trim();
  }

  if (!hasContent) {
    return false;
  }

  if (
    step.contentKind === 'channel_template' &&
    (!resolvedDeliveryInboxId.value || !isWhatsAppTemplateCapable.value)
  ) {
    return false;
  }

  if (step.timingMode === 'absolute') {
    return !!step.scheduledAt;
  }

  return !!step.relativeAnchor && Number(step.relativeOffsetValue || 0) >= 1;
};

const canSave = computed(() => {
  return (
    !!String(form.name || '').trim() &&
    derivedEntityKinds.value.length > 0 &&
    form.steps.length > 0 &&
    form.steps.every(validateStep)
  );
});

const resetForm = () => {
  form.deliveryInboxId = '';
  form.description = '';
  form.name = '';
  form.steps = [createStep()];
  templateParserRefs.value = {};
};

const deriveTouchPlanInboxId = touchPlan => {
  const inboxIds = [
    ...new Set(
      Array(touchPlan?.touches || [])
        .map(step => normalizeNumericId(step.target_inbox_id))
        .filter(Boolean)
    ),
  ];

  return inboxIds.length === 1 ? String(inboxIds[0]) : '';
};

const hydrateForm = () => {
  if (!props.modelValue) {
    return;
  }

  templateParserRefs.value = {};

  if (!props.touchPlan) {
    resetForm();
    return;
  }

  form.deliveryInboxId = deriveTouchPlanInboxId(props.touchPlan);
  form.description = props.touchPlan.description || '';
  form.name = props.touchPlan.name || '';
  form.steps =
    Array(props.touchPlan.touches || []).map(step => createStep(step)) || [];

  if (!form.steps.length) {
    form.steps = [createStep()];
  }
};

const normalizeStepAnchorForEntityKind = step => {
  const availableAnchors = stepAnchorOptions(step);
  const hasAnchor = availableAnchors.some(
    option => option.value === step.relativeAnchor
  );

  if (step.timingMode === 'relative' && !hasAnchor) {
    return {
      ...step,
      relativeAnchor: availableAnchors[0]?.value || TOUCH_CREATED_AT_ANCHOR,
    };
  }

  return step;
};

const updateStep = (localId, patch) => {
  form.steps = form.steps.map(step => {
    if (step.localId !== localId) {
      return step;
    }

    return normalizeStepAnchorForEntityKind({
      ...step,
      ...patch,
    });
  });
};

const addStep = () => {
  form.steps = [...form.steps, createStep({ entityKind: defaultEntityKind() })];
};

const removeStep = localId => {
  if (form.steps.length === 1) {
    return;
  }

  form.steps = form.steps.filter(step => step.localId !== localId);
  delete templateParserRefs.value[localId];
};

const stepBodyEditorId = step => {
  return `touch-plan-body-${step.localId}`;
};

const stepInstructionsEditorId = step => {
  return `touch-plan-instructions-${step.localId}`;
};

const stepContentTabId = step => {
  return `touch-plan-content-kind-${step.localId}`;
};

const stepTimingTabId = step => {
  return `touch-plan-timing-mode-${step.localId}`;
};

const activeContentTabIndex = step => {
  const tabIndex = stepContentModeTabs.value.findIndex(
    tab => tab.id === step.contentKind
  );

  return tabIndex === -1 ? 0 : tabIndex;
};

const activeTimingTabIndex = step => {
  const activeState = resolveTouchTimingState({
    relativeOffsetSeconds: toRelativeOffsetSeconds({
      direction: step.relativeOffsetDirection,
      unit: step.relativeOffsetUnit,
      value: step.relativeOffsetValue,
    }),
    timingMode: step.timingMode,
  });
  const tabIndex = timingModeTabs.value.findIndex(
    tab => tab.id === activeState
  );

  return tabIndex === -1 ? 0 : tabIndex;
};

function setStepContentKind(step, contentKind) {
  updateStep(step.localId, {
    contentKind,
    templateLanguage:
      contentKind === 'channel_template' ? step.templateLanguage : '',
    templateName: contentKind === 'channel_template' ? step.templateName : '',
    templateParams:
      contentKind === 'channel_template' ? step.templateParams : {},
    useAiAuthoring:
      contentKind === 'channel_template' ? false : step.useAiAuthoring,
  });
}

const handleContentTabChanged = (step, tab) => {
  setStepContentKind(step, tab.id);
};

const setStepTimingState = (step, timingState) => {
  if (timingState === TOUCH_TIMING_STATES.ABSOLUTE) {
    updateStep(step.localId, {
      timingMode: TOUCH_TIMING_STATES.ABSOLUTE,
    });
    return;
  }

  updateStep(step.localId, {
    relativeOffsetDirection: timingState,
    repeatMode: 'once',
    repeatUntilAt: '',
    timingMode: 'relative',
  });
};

const handleTimingTabChanged = (step, tab) => {
  setStepTimingState(step, tab.id);
};

const ensureTemplateLanguageForStep = step => {
  const variants = selectedTemplateGroup(step)?.variants || [];
  const hasSelectedLanguage = variants.some(
    template => template.language === step.templateLanguage
  );

  if (variants.length === 1) {
    updateStep(step.localId, { templateLanguage: variants[0].language });
    return;
  }

  if (!hasSelectedLanguage) {
    updateStep(step.localId, { templateLanguage: '' });
  }
};

const handleTemplateNameChange = (step, templateName) => {
  updateStep(step.localId, {
    templateLanguage: '',
    templateName,
    templateParams: {},
  });
  const updatedStep = form.steps.find(item => item.localId === step.localId);
  if (updatedStep) {
    ensureTemplateLanguageForStep(updatedStep);
  }
};

const handleTemplateLanguageChange = (step, templateLanguage) => {
  updateStep(step.localId, {
    templateLanguage,
    templateParams: {},
  });
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

const buildStepBody = step => {
  if (step.contentKind === 'channel_template') {
    return templateBodyForStep(step);
  }

  if (step.useAiAuthoring) {
    return '';
  }

  return String(step.body || '').trim();
};

const buildStepInstructions = step => {
  if (step.contentKind === 'channel_template' || !step.useAiAuthoring) {
    return '';
  }

  return String(step.instructions || '').trim();
};

const buildStepTemplateParams = step => {
  if (step.contentKind !== 'channel_template') {
    return {};
  }

  return {
    name: selectedTemplate(step)?.name || step.templateName,
    namespace: selectedTemplate(step)?.namespace || '',
    category: selectedTemplate(step)?.category || 'UTILITY',
    language: selectedTemplate(step)?.language || step.templateLanguage,
    processed_params: templateParamsForStep(step),
  };
};

const buildPayload = () => {
  return {
    description: String(form.description || '').trim(),
    entity_kinds: derivedEntityKinds.value,
    name: String(form.name || '').trim(),
    touches: form.steps.map(step => ({
      ...(resolvedDeliveryInboxId.value
        ? { target_inbox_id: resolvedDeliveryInboxId.value }
        : {}),
      action_type: 'send_message',
      auto_cancel_on_incoming: step.autoCancelOnIncoming,
      body: buildStepBody(step),
      content_kind: step.contentKind,
      instructions: buildStepInstructions(step),
      repeat_mode: step.timingMode === 'absolute' ? step.repeatMode : 'once',
      repeat_until_at:
        step.timingMode === 'absolute' &&
        step.repeatMode !== 'once' &&
        step.repeatUntilAt
          ? fromDateTimeInputValue(step.repeatUntilAt)
          : '',
      template_params: buildStepTemplateParams(step),
      text_mode:
        step.contentKind === 'channel_template'
          ? 'static'
          : detectTouchTextMode({
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
            relative_offset_seconds: toRelativeOffsetSeconds({
              direction: step.relativeOffsetDirection,
              unit: step.relativeOffsetUnit,
              value: step.relativeOffsetValue,
            }),
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
  async () => {
    if (props.modelValue && inboxesList.value.length === 0) {
      await store.dispatch('inboxes/get');
    }

    hydrateForm();
  },
  { immediate: true }
);

watch(
  () => requiresTemplateOnly.value,
  value => {
    if (!value) {
      return;
    }

    form.steps = form.steps.map(step => ({
      ...step,
      contentKind: 'channel_template',
      useAiAuthoring: false,
    }));
  },
  { immediate: true }
);

watch(
  () => isWhatsAppTemplateCapable.value,
  value => {
    if (value) {
      return;
    }

    form.steps = form.steps.map(step =>
      step.contentKind === 'channel_template'
        ? {
            ...step,
            contentKind: 'free_text',
            templateLanguage: '',
            templateName: '',
            templateParams: {},
          }
        : step
    );
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

          <div class="grid gap-1">
            <label
              for="touch-plan-delivery-channel"
              class="mb-0.5 text-sm font-medium text-n-slate-12"
            >
              {{
                $t(
                  'OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.DELIVERY_CHANNEL'
                )
              }}
            </label>
            <ComboBox
              id="touch-plan-delivery-channel"
              :model-value="form.deliveryInboxId"
              :options="deliveryInboxOptions"
              :placeholder="
                $t(
                  'OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.DELIVERY_CHANNEL_PLACEHOLDER'
                )
              "
              input-like
              @update:model-value="form.deliveryInboxId = $event"
            />
            <p class="mb-0 text-xs leading-5 text-n-slate-11">
              {{
                $t(
                  'OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.DELIVERY_CHANNEL_NOTE'
                )
              }}
            </p>
          </div>
        </div>
      </SchedulingFormFieldGroup>

      <SchedulingFormFieldGroup
        :framed="false"
        :title="$t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.ENTITY_KINDS')"
        :description="
          $t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.ENTITY_KINDS_NOTE')
        "
      >
        <div class="grid gap-3">
          <div class="flex flex-wrap gap-2">
            <span
              v-for="entityKind in derivedEntityKinds"
              :key="entityKind"
              class="inline-flex items-center gap-2 rounded-full bg-n-alpha-black2 px-3 py-1.5 text-sm text-n-slate-12"
            >
              <span
                class="size-4 text-n-slate-11"
                :class="entityKindIcon(entityKind)"
              />
              <span>{{ entityKindLabel(entityKind) }}</span>
            </span>
          </div>

          <p
            v-if="!derivedEntityKinds.length"
            class="rounded-2xl bg-n-ruby-2 px-4 py-3 text-sm leading-6 text-n-ruby-12"
          >
            {{
              $t(
                'OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.ENTITY_KIND_EMPTY'
              )
            }}
          </p>
          <p v-else class="mb-0 text-xs leading-5 text-n-slate-11">
            {{
              $t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.STEPS_NOTE', {
                entityKinds: derivedEntityKindsSummary,
              })
            }}
          </p>
        </div>
      </SchedulingFormFieldGroup>

      <SchedulingFormFieldGroup
        :framed="false"
        :title="$t('OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.STEPS')"
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
              <div class="grid gap-1">
                <label
                  :for="`touch-plan-entity-kind-${step.localId}`"
                  class="mb-0.5 text-sm font-medium text-n-slate-12"
                >
                  {{
                    $t(
                      'OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.ENTITY_KIND'
                    )
                  }}
                </label>
                <ComboBox
                  :id="`touch-plan-entity-kind-${step.localId}`"
                  :model-value="step.entityKind"
                  :options="entityKindOptions"
                  :placeholder="
                    $t(
                      'OUTBOUND_WORKSPACE.TOUCH_PLAN_EDITOR.FIELDS.ENTITY_KIND_PLACEHOLDER'
                    )
                  "
                  input-like
                  @update:model-value="
                    updateStep(step.localId, {
                      entityKind: $event,
                    })
                  "
                />
              </div>
            </div>

            <template v-if="stepContentModeTabs.length > 1">
              <div class="rounded-2xl bg-n-surface-1 p-1">
                <TabBar
                  :key="stepContentTabId(step)"
                  :tabs="stepContentModeTabs"
                  :initial-active-tab="activeContentTabIndex(step)"
                  @tab-changed="handleContentTabChanged(step, $event)"
                />
              </div>
            </template>

            <template v-if="step.contentKind === 'channel_template'">
              <div v-if="templateGroups.length" class="grid gap-4">
                <div class="grid gap-1">
                  <label
                    :for="`touch-plan-template-name-${step.localId}`"
                    class="mb-0.5 text-sm font-medium text-n-slate-12"
                  >
                    {{ $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE') }}
                  </label>
                  <ComboBox
                    :id="`touch-plan-template-name-${step.localId}`"
                    :model-value="step.templateName"
                    :options="templateOptions"
                    :placeholder="
                      $t(
                        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_PLACEHOLDER'
                      )
                    "
                    input-like
                    @update:model-value="handleTemplateNameChange(step, $event)"
                  />
                </div>

                <div v-if="selectedTemplateGroup(step)" class="grid gap-1">
                  <label
                    :for="`touch-plan-template-language-${step.localId}`"
                    class="mb-0.5 text-sm font-medium text-n-slate-12"
                  >
                    {{
                      $t(
                        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_LANGUAGE'
                      )
                    }}
                  </label>
                  <ComboBox
                    :id="`touch-plan-template-language-${step.localId}`"
                    :model-value="step.templateLanguage"
                    :options="templateLanguageOptions(step)"
                    :placeholder="
                      $t(
                        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_LANGUAGE_PLACEHOLDER'
                      )
                    "
                    input-like
                    @update:model-value="
                      handleTemplateLanguageChange(step, $event)
                    "
                  />
                </div>

                <WhatsAppTemplateParser
                  v-if="selectedTemplate(step)"
                  :ref="
                    refValue => setTemplateParserRef(step.localId, refValue)
                  "
                  :template="selectedTemplate(step)"
                  :initial-processed-params="step.templateParams"
                />
              </div>

              <div
                v-else
                class="rounded-2xl bg-n-alpha-black2 px-4 py-4 text-sm text-n-slate-11"
              >
                <p class="mb-1 font-medium text-n-slate-12">
                  {{
                    $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_EMPTY')
                  }}
                </p>
                <p class="mb-0 leading-6">
                  {{
                    $t(
                      'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_EMPTY_DESCRIPTION'
                    )
                  }}
                </p>
              </div>
            </template>

            <div v-else class="grid gap-4">
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
              </div>

              <div class="rounded-2xl bg-n-surface-1 p-1">
                <TabBar
                  :key="stepTimingTabId(step)"
                  :tabs="timingModeTabs"
                  :initial-active-tab="activeTimingTabIndex(step)"
                  @tab-changed="handleTimingTabChanged(step, $event)"
                />
              </div>

              <SchedulingDateTimeField
                v-if="step.timingMode === 'absolute'"
                :model-value="step.scheduledAt"
                type="datetime"
                @update:model-value="
                  updateStep(step.localId, { scheduledAt: $event })
                "
              />

              <div v-else class="grid gap-4">
                <SchedulingRelativeOffsetInput
                  :amount="step.relativeOffsetValue"
                  :unit="step.relativeOffsetUnit"
                  :label="
                    $t(
                      'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_VALUE'
                    )
                  "
                  :unit-options="relativeOffsetUnitOptions"
                  min="1"
                  @update:amount="
                    updateStep(step.localId, {
                      relativeOffsetValue: Math.max(1, Number($event || 0)),
                      repeatMode: 'once',
                      repeatUntilAt: '',
                    })
                  "
                  @update:unit="
                    updateStep(step.localId, {
                      relativeOffsetUnit: $event,
                    })
                  "
                />

                <SchedulingSelectField
                  :id="`touch-plan-timing-anchor-${step.localId}`"
                  :label="
                    $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_ANCHOR')
                  "
                  :model-value="step.relativeAnchor"
                  :options="stepAnchorOptions(step)"
                  @update:model-value="
                    updateStep(step.localId, { relativeAnchor: $event })
                  "
                />
              </div>
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

            <div
              class="grid grid-cols-[auto_minmax(0,1fr)] items-start gap-3 rounded-2xl bg-n-solid-1 px-4 py-3"
            >
              <Checkbox
                class="mt-0.5 shrink-0"
                :model-value="step.autoCancelOnIncoming"
                @update:model-value="
                  updateStep(step.localId, {
                    autoCancelOnIncoming: $event,
                  })
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
