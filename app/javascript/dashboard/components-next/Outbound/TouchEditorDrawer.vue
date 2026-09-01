<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { debounce } from '@chatwoot/utils';
import camelcaseKeys from 'camelcase-keys';

import ContactAPI from 'dashboard/api/contacts';
import TouchesAPI from 'dashboard/api/touches';
import { uploadFile } from 'dashboard/helper/uploadHelper';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import {
  buildContactableInboxesList,
  createContactSearcher,
  fetchContactableInboxes,
  mergeInboxDetails,
  processContactableInboxes,
} from 'dashboard/components-next/NewConversation/helpers/composeConversationHelper';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingRelativeOffsetInput from 'dashboard/components-next/Scheduling/SchedulingRelativeOffsetInput.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import TouchEditorShell from 'dashboard/components-next/Outbound/TouchEditorShell.vue';
import TouchMessageComposer from 'dashboard/components-next/Outbound/TouchMessageComposer.vue';
import {
  TOUCH_CREATED_AT_ANCHOR,
  buildTouchAnchorOptions,
  touchAnchorEntityKindForRemindableType,
} from 'dashboard/components-next/Outbound/touchAnchors';
import {
  normalizeRelativeOffset,
  normalizeRelativeTimeForUnit,
  resolveTouchTimingState,
  toRelativeOffsetSeconds,
  DEFAULT_RELATIVE_TIME_OF_DAY,
  RELATIVE_TIME_MODES,
  TOUCH_TIMING_STATES,
  canUseFixedRelativeTimeForUnit,
} from 'dashboard/components-next/Outbound/touchTiming';
import { detectTouchTextMode } from 'dashboard/components-next/Outbound/touchTextMode';
import {
  buildTouchContentModeTabs,
  isWhatsAppTemplateCapableChannel,
} from 'dashboard/components-next/Outbound/touchContentModes';
import { groupWhatsAppTemplates } from 'dashboard/helper/whatsappTemplateLibrary';
import {
  toDateTimeInputValue,
  fromDateTimeInputValue,
} from 'dashboard/routes/dashboard/scheduling/helpers';

const props = defineProps({
  conversationId: {
    type: [Number, String],
    default: '',
  },
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
  displayMode: {
    type: String,
    default: 'drawer',
  },
  modelValue: {
    type: Boolean,
    default: false,
  },
  saveLabel: {
    type: String,
    default: '',
  },
  showAllTouchesAction: {
    type: Boolean,
    default: false,
  },
  successCreatedMessage: {
    type: String,
    default: '',
  },
  successUpdatedMessage: {
    type: String,
    default: '',
  },
  selectionMode: {
    type: String,
    default: 'entity',
  },
  initialBody: {
    type: String,
    default: '',
  },
  initialAttachments: {
    type: Array,
    default: () => [],
  },
  inboxId: {
    type: [Number, String],
    default: '',
  },
  remindableId: {
    type: [Number, String],
    default: '',
  },
  remindableType: {
    type: String,
    default: '',
  },
  touch: {
    type: Object,
    default: null,
  },
});

const emit = defineEmits(['close', 'saved', 'update:modelValue', 'viewAll']);

const SUPPORTED_OUTBOUND_CHANNEL_TYPES = [
  'Channel::TwitterProfile',
  'Channel::TwilioSms',
  'Channel::Line',
  'Channel::Telegram',
  'Channel::TelegramPersonal',

  'Channel::Weixin',
  'Channel::Whatsapp',
  'Channel::WhatsappWeb',
  'Channel::VkCommunity',
  'Channel::Sms',
  'Channel::Instagram',
  'Channel::Tiktok',
  'Channel::Email',
  'Channel::WebWidget',
  'Channel::Api',
  'Channel::FacebookPage',
];

const { t } = useI18n();
const store = useStore();
const currentAccountId = useMapGetter('getCurrentAccountId');
const cannedResponses = useMapGetter('getCannedResponses');
const getAllInboxes = useMapGetter('inboxes/getAllInboxes');
const getFilteredWhatsAppTemplates = useMapGetter(
  'inboxes/getFilteredWhatsAppTemplates'
);
const messageComposerRef = ref(null);
const searchContacts = createContactSearcher();
const contacts = ref([]);
const isSearchingContacts = ref(false);
const isFetchingTargetInboxes = ref(false);
const selectedContact = ref(null);
const targetInbox = ref(null);
const touchAttachments = ref([]);

const cloneTemplateParams = value => JSON.parse(JSON.stringify(value || {}));
const friendlyTemplateName = templateName =>
  String(templateName || '')
    .replace(/_/g, ' ')
    .replace(/\b\w/g, letter => letter.toUpperCase());
const buildFreeTextTemplateOption = template => ({
  value: template.id || template.short_code,
  label: template.short_code || template.name || `#${template.id}`,
  content: template.content || '',
});

const form = reactive({
  actionType: 'send_message',
  autoCancelOnIncoming: false,
  body: '',
  contentKind: 'free_text',
  conversationId: '',
  instructions: '',
  remindableId: '',
  remindableType: 'Conversation',
  relativeAnchor: '',
  relativeOffsetDirection: TOUCH_TIMING_STATES.AFTER,
  relativeOffsetUnit: 'minutes',
  relativeOffsetValue: 1,
  relativeTimeMode: RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME,
  relativeTimeOfDay: '',
  manualScheduleOverride: false,
  repeatMode: 'once',
  repeatUntilAt: '',
  scheduledAt: '',
  templateBody: '',
  templateLanguage: '',
  templateName: '',
  templateParams: {},
  timingMode: 'relative',
  timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC',
  useAiAuthoring: false,
});

const ui = reactive({
  isSaving: false,
  isUploadingAttachment: false,
  isDraggingAttachment: false,
});

const drawerCreateLabel = computed(() => {
  return props.createLabel || t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.CREATE');
});
const isSidebarMode = computed(() => props.displayMode === 'sidebar');
const isTargetSelectionMode = computed(() => props.selectionMode === 'target');
const drawerDescription = computed(() => {
  if (isSidebarMode.value || isTargetSelectionMode.value) {
    return '';
  }

  return props.description || t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.DESCRIPTION');
});
const drawerTitle = computed(() => {
  if (props.touch?.id) {
    return props.editTitle || t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.EDIT_TITLE');
  }

  return props.createTitle || t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.CREATE_TITLE');
});
const drawerSaveLabel = computed(() => {
  return props.saveLabel || t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.SAVE');
});
const successCreatedMessage = computed(() => {
  return (
    props.successCreatedMessage ||
    t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.SUCCESS.CREATED')
  );
});
const successUpdatedMessage = computed(() => {
  return (
    props.successUpdatedMessage ||
    t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.SUCCESS.UPDATED')
  );
});
const inboxesList = computed(() => getAllInboxes.value || []);
const freeTextTemplateOptions = computed(() =>
  (cannedResponses.value || [])
    .filter(template => template?.short_code && template?.content)
    .map(buildFreeTextTemplateOption)
);
const contactableInboxesList = computed(() => {
  return buildContactableInboxesList(selectedContact.value?.contactInboxes);
});
const selectedContactId = computed(() => {
  const numericId = Number(selectedContact.value?.id);
  return Number.isFinite(numericId) && numericId > 0 ? numericId : null;
});
const selectedTargetContactIds = computed(() =>
  selectedContactId.value ? [selectedContactId.value] : []
);
const contactAvatarSrc = contact =>
  contact?.thumbnail?.src ||
  (typeof contact?.thumbnail === 'string' ? contact.thumbnail : '') ||
  contact?.avatarUrl ||
  contact?.avatar_url ||
  contact?.avatar ||
  contact?.imageUrl ||
  contact?.image_url ||
  '';
const buildTargetContactOption = contact => {
  if (!contact?.id) return null;

  const primaryLabel =
    contact.name ||
    contact.phoneNumber ||
    contact.phone_number ||
    contact.email ||
    contact.identifier ||
    t('CRM.GENERAL.EMPTY_VALUE');
  const secondaryLabel = contact.name
    ? contact.phoneNumber ||
      contact.phone_number ||
      contact.email ||
      contact.identifier
    : '';

  return {
    contact,
    label: [primaryLabel, secondaryLabel].filter(Boolean).join(' · '),
    thumbnail: {
      name: primaryLabel,
      src: contactAvatarSrc(contact),
    },
    value: Number(contact.id),
  };
};
const dedupeTargetOptions = options => {
  const optionMap = new Map();
  options.filter(Boolean).forEach(option => {
    optionMap.set(Number(option.value), option);
  });
  return Array.from(optionMap.values());
};
const targetContactOptions = computed(() => {
  const selectedOption = selectedContact.value
    ? [buildTargetContactOption(selectedContact.value)]
    : [];
  return dedupeTargetOptions([
    ...selectedOption,
    ...contacts.value.map(buildTargetContactOption),
  ]);
});
const targetInboxOptions = computed(() =>
  contactableInboxesList.value.map(inbox => ({
    ...inbox,
    value: inbox.id,
  }))
);

const resolvedRemindableType = computed(() => {
  if (isTargetSelectionMode.value) {
    return props.touch?.remindable?.type || '';
  }

  return (
    props.touch?.remindable?.type ||
    props.remindableType ||
    form.remindableType ||
    ''
  );
});
const resolvedRemindableId = computed(() => {
  if (isTargetSelectionMode.value) {
    return props.touch?.remindable?.id || '';
  }

  return (
    props.touch?.remindable?.id || props.remindableId || form.remindableId || ''
  );
});
const resolvedConversationId = computed(() => {
  return (
    props.touch?.conversation_id ||
    props.conversationId ||
    form.conversationId ||
    ''
  );
});
const resolvedInboxId = computed(() => {
  const rawInboxId = isTargetSelectionMode.value
    ? targetInbox.value?.id
    : props.touch?.target?.inbox_id ||
      props.touch?.target?.inboxId ||
      props.inboxId;
  const numericInboxId = Number(rawInboxId);

  return Number.isFinite(numericInboxId) && numericInboxId > 0
    ? numericInboxId
    : null;
});
const resolvedInbox = computed(() => {
  return (
    inboxesList.value.find(
      inbox => Number(inbox.id) === Number(resolvedInboxId.value)
    ) || null
  );
});
const resolvedChannelType = computed(
  () =>
    resolvedInbox.value?.channel_type || resolvedInbox.value?.channelType || ''
);
const isOutboundChannelSupported = computed(() => {
  if (!resolvedChannelType.value) return true;
  return SUPPORTED_OUTBOUND_CHANNEL_TYPES.includes(resolvedChannelType.value);
});
const unsupportedChannelWarning = computed(() =>
  isOutboundChannelSupported.value
    ? ''
    : t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.UNSUPPORTED_CHANNEL_WARNING')
);
const resolvedInboxMedium = computed(() => resolvedInbox.value?.medium || '');
const isWhatsAppTemplateCapable = computed(() =>
  isWhatsAppTemplateCapableChannel({
    channelType: resolvedChannelType.value,
    medium: resolvedInboxMedium.value,
  })
);
const templateGroups = computed(() => {
  if (!resolvedInboxId.value) {
    return [];
  }

  return groupWhatsAppTemplates(
    getFilteredWhatsAppTemplates.value(resolvedInboxId.value) || []
  );
});
const contentModeTabs = computed(() =>
  buildTouchContentModeTabs({
    t,
    supportsFreeText: true,
    supportsWhatsAppTemplates: isWhatsAppTemplateCapable.value,
  })
);
const activeContentTabIndex = computed(() => {
  const tabIndex = contentModeTabs.value.findIndex(
    tab => tab.id === form.contentKind
  );

  return tabIndex === -1 ? 0 : tabIndex;
});
const showRecordSelector = computed(() => {
  if (isTargetSelectionMode.value) {
    return false;
  }

  return !props.touch && !(props.remindableType && props.remindableId);
});
const showActionTypeField = computed(() => {
  if (isTargetSelectionMode.value) {
    return false;
  }

  return !(isSidebarMode.value && !props.touch);
});
const canRunAiWakeup = computed(() => {
  return !!(
    resolvedConversationId.value ||
    props.touch?.target?.conversation_id ||
    (resolvedRemindableType.value === 'Conversation' &&
      resolvedRemindableId.value)
  );
});
const entityLabel = computed(() => {
  switch (resolvedRemindableType.value) {
    case 'Scheduling::Appointment':
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.APPOINTMENT');
    case 'Crm::Deal':
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.DEAL');
    case 'Crm::Task':
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.TASK');
    case 'Conversation':
    default:
      return t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.CONVERSATION');
  }
});
const resolvedEntityKind = computed(() =>
  touchAnchorEntityKindForRemindableType(resolvedRemindableType.value)
);
const availableVariablePrefixes = computed(() => {
  if (isTargetSelectionMode.value && !resolvedRemindableType.value) {
    return ['contact', 'agent', 'inbox'];
  }

  if (resolvedEntityKind.value === 'conversation') {
    return ['conversation', 'contact', 'agent', 'inbox'];
  }

  return ['contact', 'agent'];
});
const availableFieldScopes = computed(() => {
  if (isTargetSelectionMode.value && !resolvedRemindableType.value) {
    return ['contact'];
  }

  const scopesByEntity = {
    appointment: ['contact', 'appointment'],
    conversation: ['contact', 'conversation'],
    deal: ['contact', 'deal'],
    task: ['contact', 'task'],
  };

  return (
    scopesByEntity[resolvedEntityKind.value] || scopesByEntity.conversation
  );
});
const entityTypeOptions = computed(() => {
  return [
    {
      label: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.CONVERSATION'),
      value: 'Conversation',
    },
    {
      label: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.DEAL'),
      value: 'Crm::Deal',
    },
    {
      label: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.TASK'),
      value: 'Crm::Task',
    },
    {
      label: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_KINDS.APPOINTMENT'),
      value: 'Scheduling::Appointment',
    },
  ];
});
const repeatModeDescription = computed(() => {
  switch (form.repeatMode) {
    case 'daily':
      return t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE_HELP.DAILY');
    case 'weekly':
      return t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE_HELP.WEEKLY');
    case 'monthly':
      return t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE_HELP.MONTHLY');
    case 'weekdays':
      return t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE_HELP.WEEKDAYS');
    case 'once':
    default:
      return t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE_HELP.ONCE');
  }
});
const relativeOffsetNote = computed(() => {
  return t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_NOTE');
});
const relativeOffsetInputLabel = computed(() => {
  return form.relativeOffsetDirection === TOUCH_TIMING_STATES.BEFORE
    ? t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_BEFORE_EVENT')
    : t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_AFTER_EVENT');
});
const timingModeTabs = computed(() => {
  return [
    {
      id: TOUCH_TIMING_STATES.ABSOLUTE,
      label: t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.ABSOLUTE_MODE'),
    },
    {
      id: TOUCH_TIMING_STATES.AFTER,
      label: t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_AFTER'),
    },
    {
      id: TOUCH_TIMING_STATES.BEFORE,
      label: t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_BEFORE'),
    },
  ];
});
const showAbsoluteTimingEditor = computed(
  () => form.timingMode === TOUCH_TIMING_STATES.ABSOLUTE
);
const showRelativeTimingEditor = computed(
  () => !showAbsoluteTimingEditor.value
);
const canUseFixedRelativeTime = computed(() =>
  canUseFixedRelativeTimeForUnit(form.relativeOffsetUnit)
);
const useFixedRelativeTime = computed({
  get: () =>
    canUseFixedRelativeTime.value &&
    form.relativeTimeMode === RELATIVE_TIME_MODES.FIXED_TIME_OF_DAY,
  set: value => {
    if (!canUseFixedRelativeTime.value) {
      form.relativeTimeMode = RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME;
      form.relativeTimeOfDay = '';
      return;
    }

    form.relativeTimeMode = value
      ? RELATIVE_TIME_MODES.FIXED_TIME_OF_DAY
      : RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME;
    form.relativeTimeOfDay = value
      ? form.relativeTimeOfDay || DEFAULT_RELATIVE_TIME_OF_DAY
      : '';
  },
});
const canConfigureRepeat = computed(() => showAbsoluteTimingEditor.value);
const relativeSchedulePayload = () => {
  const relativeTimeMode = canUseFixedRelativeTime.value
    ? form.relativeTimeMode
    : RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME;
  const relativeTimeOfDay =
    canUseFixedRelativeTime.value &&
    form.relativeTimeMode === RELATIVE_TIME_MODES.FIXED_TIME_OF_DAY
      ? form.relativeTimeOfDay || DEFAULT_RELATIVE_TIME_OF_DAY
      : '';

  return {
    relative_anchor: form.relativeAnchor,
    relative_offset_seconds: toRelativeOffsetSeconds({
      direction: form.relativeOffsetDirection,
      unit: form.relativeOffsetUnit,
      value: form.relativeOffsetValue,
    }),
    relative_time_mode: relativeTimeMode,
    relative_time_of_day: relativeTimeOfDay,
  };
};
const relativeScheduleChanged = relativePayload => {
  if (!props.touch?.id || props.touch.timing_mode !== 'relative') {
    return true;
  }

  return (
    relativePayload.relative_anchor !==
      (props.touch.relative_anchor || TOUCH_CREATED_AT_ANCHOR) ||
    relativePayload.relative_offset_seconds !==
      Number(props.touch.relative_offset_seconds || 0) ||
    relativePayload.relative_time_mode !==
      (props.touch.relative_time_mode ||
        RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME) ||
    relativePayload.relative_time_of_day !==
      (props.touch.relative_time_of_day || '')
  );
};
const relativeOffsetUnitOptions = computed(() => {
  return [
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
  ];
});
const activeTimingTabIndex = computed(() => {
  const activeState = resolveTouchTimingState({
    relativeOffsetSeconds: toRelativeOffsetSeconds({
      direction: form.relativeOffsetDirection,
      unit: form.relativeOffsetUnit,
      value: form.relativeOffsetValue,
    }),
    timingMode: form.timingMode,
  });

  const tabIndex = timingModeTabs.value.findIndex(
    tab => tab.id === activeState
  );
  return tabIndex === -1 ? 0 : tabIndex;
});
const selectedTemplateGroup = computed(() => {
  if (!form.templateName) {
    return null;
  }

  return (
    templateGroups.value.find(group => group.name === form.templateName) || null
  );
});
const templateOptions = computed(() =>
  templateGroups.value.map(templateGroup => ({
    value: templateGroup.name,
    label: friendlyTemplateName(templateGroup.name),
  }))
);
const templateLanguageOptions = computed(() => {
  return (
    selectedTemplateGroup.value?.variants.map(template => ({
      value: template.language,
      label: template.language,
    })) || []
  );
});
const selectedTemplate = computed(() => {
  if (!selectedTemplateGroup.value || !form.templateLanguage) {
    return null;
  }

  return (
    selectedTemplateGroup.value.variants.find(
      template => template.language === form.templateLanguage
    ) || null
  );
});
const hasRequiredTemplateParams = computed(() => {
  if (form.contentKind !== 'channel_template') {
    return true;
  }

  return (
    !!selectedTemplate.value &&
    messageComposerRef.value?.isTemplateReady?.() === true
  );
});
const canSave = computed(() => {
  const hasEntityContext = isTargetSelectionMode.value
    ? true
    : !!resolvedRemindableType.value && !!resolvedRemindableId.value;
  let hasContent = false;

  if (form.actionType === 'ai_agent_wakeup') {
    hasContent = true;
  } else if (form.contentKind === 'channel_template') {
    hasContent =
      !!selectedTemplate.value &&
      hasRequiredTemplateParams.value &&
      !!String(form.templateBody || '').trim();
  } else if (form.useAiAuthoring) {
    hasContent = !!String(form.instructions || '').trim();
  } else {
    hasContent = !!String(form.body || '').trim();
  }

  const hasTargetRoute = isTargetSelectionMode.value
    ? !!selectedContactId.value && !!resolvedInboxId.value
    : true;

  return (
    hasEntityContext &&
    hasTargetRoute &&
    hasContent &&
    !ui.isUploadingAttachment &&
    (form.actionType !== 'ai_agent_wakeup' || canRunAiWakeup.value) &&
    (showAbsoluteTimingEditor.value
      ? !!form.scheduledAt
      : !!form.relativeAnchor && Number(form.relativeOffsetValue || 0) >= 1)
  );
});

const actionTypeOptions = computed(() => {
  const options = [
    {
      label: t('OUTBOUND_WORKSPACE.TOUCHES.ACTION_TYPES.SEND_MESSAGE'),
      icon: 'i-lucide-timer-reset',
      value: 'send_message',
    },
  ];

  if (canRunAiWakeup.value) {
    options.push({
      label: t('OUTBOUND_WORKSPACE.TOUCHES.ACTION_TYPES.AI_AGENT_WAKEUP'),
      icon: 'i-woot-captain',
      value: 'ai_agent_wakeup',
    });
  }

  return options;
});

const bodyEditorId = computed(() => {
  return `touch-editor-body-${props.touch?.id || resolvedRemindableId.value || 'new'}`;
});
const instructionsEditorId = computed(() => {
  return `touch-editor-instructions-${props.touch?.id || resolvedRemindableId.value || 'new'}`;
});
const contentModeTabId = computed(() => {
  return `touch-editor-content-kind-${props.touch?.id || resolvedRemindableId.value || 'new'}`;
});

const normalizeAttachment = attachment => {
  const blobId =
    attachment?.blobId ||
    attachment?.blob_id ||
    attachment?.signed_id ||
    attachment?.signedId ||
    (typeof attachment === 'string' ? attachment : null);

  if (!blobId) return null;

  return {
    blobId,
    fileName:
      attachment?.fileName ||
      attachment?.filename ||
      attachment?.name ||
      t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.FILE_FALLBACK'),
    fileSize: attachment?.fileSize || attachment?.size || null,
    contentType: attachment?.contentType || attachment?.content_type || '',
    fileUrl: attachment?.fileUrl || attachment?.file_url || '',
  };
};

const hydrateAttachments = attachments => {
  touchAttachments.value = Array(attachments || [])
    .map(normalizeAttachment)
    .filter(Boolean);
};

const attachmentIds = computed(() =>
  touchAttachments.value.map(attachment => attachment.blobId).filter(Boolean)
);

const setAttachmentDragState = value => {
  if (ui.isUploadingAttachment) return;
  ui.isDraggingAttachment = value;
};

const removeAttachment = blobId => {
  touchAttachments.value = touchAttachments.value.filter(
    attachment => attachment.blobId !== blobId
  );
};

const uploadAttachmentFiles = async filesInput => {
  const files = Array.from(filesInput || []);

  if (files.length === 0) return;

  ui.isUploadingAttachment = true;

  try {
    const uploadedAttachments = (
      await Promise.all(
        files.map(async file => {
          const result = await uploadFile(file, currentAccountId.value);

          if (!result?.blobId) return null;

          return {
            blobId: result.blobId,
            fileName: file.name,
            fileSize: file.size,
            contentType: file.type,
            fileUrl: result.fileUrl,
          };
        })
      )
    ).filter(Boolean);

    touchAttachments.value = [
      ...touchAttachments.value,
      ...uploadedAttachments,
    ];
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        error?.message ||
        t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.UPLOAD_ERROR')
    );
  } finally {
    ui.isUploadingAttachment = false;
    ui.isDraggingAttachment = false;
  }
};

const setContentKind = kind => {
  form.contentKind = kind;

  if (kind === 'channel_template') {
    form.useAiAuthoring = false;
    return;
  }

  form.templateBody = '';
  form.templateLanguage = '';
  form.templateName = '';
  form.templateParams = {};
};

const handleContentTabChanged = tab => {
  setContentKind(tab.id);
};

const handleTemplateStateChange = payload => {
  if (form.contentKind !== 'channel_template') {
    return;
  }

  form.templateParams = cloneTemplateParams(payload?.processedParams);
  form.templateBody = String(payload?.rawRenderedTemplate || '');
};

const setTimingState = state => {
  if (state === TOUCH_TIMING_STATES.ABSOLUTE) {
    form.timingMode = TOUCH_TIMING_STATES.ABSOLUTE;
    return;
  }

  form.timingMode = 'relative';
  form.relativeOffsetDirection = state;
  form.repeatMode = 'once';
  form.repeatUntilAt = '';
};

const handleTimingTabChanged = tab => {
  setTimingState(tab.id);
};

const repeatModeOptions = computed(() => {
  return [
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
  ];
});

const relativeAnchorOptions = computed(() => {
  if (isTargetSelectionMode.value && !resolvedRemindableType.value) {
    return buildTouchAnchorOptions({
      t,
      entityKinds: [],
      includeTouchCreatedAt: true,
    });
  }

  return buildTouchAnchorOptions({
    t,
    entityKinds: touchAnchorEntityKindForRemindableType(
      resolvedRemindableType.value
    ),
    includeTouchCreatedAt: true,
  });
});

const prepareContactWithInboxes = async contact => {
  if (!contact?.id) {
    return null;
  }

  let contactInboxes = contact.contactInboxes || [];

  if (contactInboxes.length === 0) {
    isFetchingTargetInboxes.value = true;
    try {
      contactInboxes = await fetchContactableInboxes(contact.id);
    } finally {
      isFetchingTargetInboxes.value = false;
    }
  } else {
    contactInboxes = processContactableInboxes(contactInboxes);
  }

  return {
    ...contact,
    contactInboxes: mergeInboxDetails(contactInboxes, inboxesList.value),
  };
};

const loadContact = async contactId => {
  if (!contactId) {
    return null;
  }

  const {
    data: { payload },
  } = await ContactAPI.show(contactId);

  return camelcaseKeys(payload, { deep: true });
};

const clearTargetSelection = () => {
  contacts.value = [];
  selectedContact.value = null;
  targetInbox.value = null;
};

const resetTargetInbox = () => {
  targetInbox.value = null;
  form.contentKind = 'free_text';
  form.templateBody = '';
  form.templateLanguage = '';
  form.templateName = '';
  form.templateParams = {};
};

const syncTargetInboxFromContact = inboxId => {
  if (!inboxId) {
    resetTargetInbox();
    return;
  }

  const matchingInbox =
    contactableInboxesList.value.find(
      inbox => Number(inbox.id) === Number(inboxId)
    ) || null;

  targetInbox.value = matchingInbox;
};

const loadTargetContacts = async (query = '') => {
  const trimmedQuery = typeof query === 'string' ? query.trim() : '';
  isSearchingContacts.value = true;
  contacts.value = [];

  try {
    if (trimmedQuery) {
      const results = await searchContacts(trimmedQuery, {
        skipMinLength: true,
      });
      if (results === null) return;
      contacts.value = results;
      return;
    }

    const {
      data: { payload = [] },
    } = await ContactAPI.get(1);
    contacts.value = camelcaseKeys(payload || [], { deep: true });
  } catch {
    useAlert(t('COMPOSE_NEW_CONVERSATION.CONTACT_SEARCH.ERROR_MESSAGE'));
  } finally {
    isSearchingContacts.value = false;
  }
};

const debouncedLoadTargetContacts = debounce(loadTargetContacts, 300, false);

const handleTargetContactIdsUpdate = async values => {
  const selectedValues = Array.isArray(values) ? values : [];
  const contactId = Number(selectedValues.at(-1));

  if (!Number.isFinite(contactId) || contactId <= 0) {
    clearTargetSelection();
    return;
  }

  const option = targetContactOptions.value.find(
    item => Number(item.value) === contactId
  );
  const contact = option?.contact || (await loadContact(contactId));

  selectedContact.value = await prepareContactWithInboxes(contact);
  contacts.value = [];
  resetTargetInbox();
};

const handleTargetInboxValueUpdate = inboxId => {
  const selectedInbox =
    contactableInboxesList.value.find(
      inbox => Number(inbox.id) === Number(inboxId)
    ) || null;
  targetInbox.value = selectedInbox;
};

const hydrateTargetSelection = async () => {
  if (!isTargetSelectionMode.value) {
    return;
  }

  clearTargetSelection();

  const touchTarget = props.touch?.target || {};
  const targetContactId = Number(
    touchTarget.contact_id || touchTarget.contactId
  );

  if (!Number.isFinite(targetContactId) || targetContactId <= 0) {
    return;
  }

  try {
    const baseContactSource =
      touchTarget.contact ||
      touchTarget.contact_data ||
      (await loadContact(targetContactId));
    const baseContact = camelcaseKeys(baseContactSource, { deep: true });

    selectedContact.value = await prepareContactWithInboxes(baseContact);
    syncTargetInboxFromContact(touchTarget.inbox_id || touchTarget.inboxId);
  } catch {
    clearTargetSelection();
  }
};

const resetForm = () => {
  form.actionType = 'send_message';
  form.autoCancelOnIncoming = false;
  form.body = props.initialBody || '';
  form.contentKind = 'free_text';
  form.conversationId = props.conversationId || '';
  form.instructions = '';
  form.remindableId = isTargetSelectionMode.value
    ? ''
    : props.remindableId || '';
  form.remindableType = isTargetSelectionMode.value
    ? ''
    : props.remindableType || 'Conversation';
  form.relativeAnchor = TOUCH_CREATED_AT_ANCHOR;
  form.relativeOffsetDirection = TOUCH_TIMING_STATES.AFTER;
  form.relativeOffsetUnit = 'minutes';
  form.relativeOffsetValue = 1;
  form.relativeTimeMode = RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME;
  form.relativeTimeOfDay = '';
  form.manualScheduleOverride = false;
  form.repeatMode = 'once';
  form.repeatUntilAt = '';
  form.scheduledAt = '';
  form.templateBody = '';
  form.templateLanguage = '';
  form.templateName = '';
  form.templateParams = {};
  form.timingMode = 'relative';
  form.timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  form.useAiAuthoring = false;
  hydrateAttachments(props.initialAttachments);
  clearTargetSelection();
};

const hydrateForm = () => {
  if (!props.modelValue) return;

  if (!props.touch) {
    resetForm();
    if (isTargetSelectionMode.value) {
      hydrateTargetSelection();
    }
    return;
  }

  form.autoCancelOnIncoming = props.touch.auto_cancel_on_incoming ?? false;
  form.actionType = props.touch.action_type || 'send_message';
  form.body =
    props.touch.content_kind === 'channel_template'
      ? ''
      : props.touch.body || '';
  form.contentKind = props.touch.content_kind || 'free_text';
  form.conversationId =
    props.touch.conversation_id || props.conversationId || '';
  form.instructions = props.touch.instructions || '';
  form.remindableId = isTargetSelectionMode.value
    ? ''
    : props.touch.remindable?.id || props.remindableId || '';
  form.remindableType = isTargetSelectionMode.value
    ? ''
    : props.touch.remindable?.type || props.remindableType || 'Conversation';
  form.relativeAnchor = props.touch.relative_anchor || TOUCH_CREATED_AT_ANCHOR;
  const normalizedRelativeOffset = normalizeRelativeOffset(
    props.touch.relative_offset_seconds
  );
  form.relativeOffsetDirection = normalizedRelativeOffset.direction;
  form.relativeOffsetUnit = normalizedRelativeOffset.unit;
  form.relativeOffsetValue = normalizedRelativeOffset.value;
  const relativeTime = normalizeRelativeTimeForUnit({
    relativeTimeMode:
      props.touch.relative_time_mode || RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME,
    relativeTimeOfDay: props.touch.relative_time_of_day,
    unit: normalizedRelativeOffset.unit,
  });
  form.relativeTimeMode = relativeTime.relativeTimeMode;
  form.relativeTimeOfDay = relativeTime.relativeTimeOfDay;
  form.manualScheduleOverride = props.touch.manual_schedule_override ?? false;
  form.repeatMode = props.touch.repeat_mode || 'once';
  form.repeatUntilAt = toDateTimeInputValue(props.touch.repeat_until_at);
  form.scheduledAt = toDateTimeInputValue(props.touch.scheduled_at);
  form.templateBody =
    props.touch.content_kind === 'channel_template'
      ? props.touch.body || ''
      : '';
  form.templateLanguage =
    props.touch.template_params?.language ||
    props.touch.template_params?.language_code ||
    '';
  form.templateName = props.touch.template_params?.name || '';
  form.templateParams = cloneTemplateParams(
    props.touch.template_params?.processed_params || {}
  );
  form.timingMode = props.touch.timing_mode || 'absolute';
  form.timezone = props.touch.timezone || form.timezone;
  form.useAiAuthoring = props.touch.text_mode === 'agent';
  hydrateAttachments(props.touch.attachments);
  hydrateTargetSelection();
};

const loadFreeTextTemplates = () => {
  store.dispatch('getCannedResponse', { searchKey: '' });
};

const closeDrawer = () => {
  emit('update:modelValue', false);
  emit('close');
};

const buildPayload = () => {
  let body = '';
  if (form.actionType === 'send_message') {
    if (form.contentKind === 'channel_template') {
      body = String(form.templateBody || '').trim();
    } else if (!form.useAiAuthoring) {
      body = form.body.trim();
    }
  }

  const relativePayload = showRelativeTimingEditor.value
    ? relativeSchedulePayload()
    : null;
  const shouldPreserveManualSchedule =
    form.manualScheduleOverride &&
    relativePayload &&
    !relativeScheduleChanged(relativePayload);

  return {
    action_type: form.actionType,
    attachments: form.actionType === 'send_message' ? attachmentIds.value : [],
    auto_cancel_on_incoming: form.autoCancelOnIncoming,
    body,
    content_kind: form.contentKind,
    ...(resolvedConversationId.value
      ? { conversation_id: resolvedConversationId.value }
      : {}),
    instructions:
      form.actionType === 'send_message' &&
      form.contentKind !== 'channel_template' &&
      form.useAiAuthoring
        ? form.instructions.trim()
        : '',
    ...(isTargetSelectionMode.value
      ? {
          remindable_id: null,
          remindable_type: null,
        }
      : {
          remindable_id: resolvedRemindableId.value,
          remindable_type: resolvedRemindableType.value,
        }),
    repeat_mode: form.timingMode === 'absolute' ? form.repeatMode : 'once',
    repeat_until_at:
      form.timingMode === 'absolute' &&
      form.repeatMode !== 'once' &&
      form.repeatUntilAt
        ? fromDateTimeInputValue(form.repeatUntilAt)
        : '',
    text_mode:
      form.contentKind === 'channel_template'
        ? 'static'
        : detectTouchTextMode({
            actionType: form.actionType,
            body: form.body,
            instructions: form.instructions,
            useAiAuthoring: form.useAiAuthoring,
          }),
    template_params:
      form.contentKind === 'channel_template'
        ? {
            name: selectedTemplate.value?.name || form.templateName,
            namespace: selectedTemplate.value?.namespace || '',
            category: selectedTemplate.value?.category || 'UTILITY',
            language: selectedTemplate.value?.language || form.templateLanguage,
            processed_params: cloneTemplateParams(form.templateParams),
          }
        : {},
    ...(resolvedInboxId.value
      ? { target_inbox_id: resolvedInboxId.value }
      : {}),
    ...(isTargetSelectionMode.value
      ? {
          target_contact_id: selectedContactId.value,
          target_contact_inbox_id: null,
          target_conversation_id: null,
        }
      : {}),
    timezone: form.timezone,
    timing_mode: form.timingMode,
    ...(form.timingMode === 'absolute'
      ? {
          scheduled_at: fromDateTimeInputValue(form.scheduledAt),
        }
      : {
          ...relativePayload,
          manual_schedule_override: shouldPreserveManualSchedule,
        }),
  };
};

const saveTouch = async () => {
  if (!canSave.value) return;

  ui.isSaving = true;

  try {
    const payload = buildPayload();
    const response = props.touch?.id
      ? await TouchesAPI.update(props.touch.id, payload)
      : await TouchesAPI.create(payload);

    emit('saved', response.data?.payload);
    useAlert(
      props.touch?.id
        ? successUpdatedMessage.value
        : successCreatedMessage.value
    );
    closeDrawer();
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        error?.message ||
        t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ERRORS.SAVE')
    );
  } finally {
    ui.isSaving = false;
  }
};

watch(
  () => [
    props.modelValue,
    props.initialBody,
    props.initialAttachments,
    props.touch?.id,
    props.remindableId,
    props.remindableType,
    props.conversationId,
    props.inboxId,
  ],
  () => {
    hydrateForm();
  },
  { immediate: true }
);

watch(
  () => props.modelValue,
  value => {
    if (value) {
      loadFreeTextTemplates();
    }
  },
  { immediate: true }
);

watch(
  () => resolvedRemindableType.value,
  () => {
    const availableAnchors = relativeAnchorOptions.value.map(
      option => option.value
    );

    if (!availableAnchors.includes(form.relativeAnchor)) {
      form.relativeAnchor = availableAnchors.includes(TOUCH_CREATED_AT_ANCHOR)
        ? TOUCH_CREATED_AT_ANCHOR
        : availableAnchors[0] || '';
    }
  }
);

watch(
  () => form.relativeOffsetValue,
  value => {
    if (!showRelativeTimingEditor.value) {
      return;
    }

    const normalizedValue = Number(value || 0);
    if (normalizedValue >= 1) {
      return;
    }

    form.relativeOffsetValue = 1;
  }
);

watch(
  () => form.relativeOffsetUnit,
  unit => {
    if (canUseFixedRelativeTimeForUnit(unit)) {
      return;
    }

    form.relativeTimeMode = RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME;
    form.relativeTimeOfDay = '';
  }
);

watch(
  () => form.timingMode,
  value => {
    if (value !== 'absolute') {
      form.repeatMode = 'once';
      form.repeatUntilAt = '';
      return;
    }

    form.relativeTimeMode = RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME;
    form.relativeTimeOfDay = '';
  }
);

watch(
  () => selectedContact.value?.id,
  (currentId, previousId) => {
    if (
      !isTargetSelectionMode.value ||
      !currentId ||
      currentId === previousId
    ) {
      return;
    }

    const hasMatchingInbox = contactableInboxesList.value.some(
      inbox => Number(inbox.id) === Number(targetInbox.value?.id)
    );

    if (!hasMatchingInbox) {
      resetTargetInbox();
    }
  }
);

watch(
  () => contactableInboxesList.value.map(inbox => Number(inbox.id)).join('|'),
  () => {
    if (!isTargetSelectionMode.value) {
      return;
    }

    const hasMatchingInbox = contactableInboxesList.value.some(
      inbox => Number(inbox.id) === Number(targetInbox.value?.id)
    );

    if (!hasMatchingInbox && targetInbox.value) {
      resetTargetInbox();
    }
  }
);

watch(
  () => isWhatsAppTemplateCapable.value,
  value => {
    if (!value && form.contentKind === 'channel_template') {
      setContentKind('free_text');
    }
  }
);

watch(
  () => contentModeTabs.value.map(tab => tab.id).join('|'),
  () => {
    if (contentModeTabs.value.length === 0) {
      return;
    }

    const hasCurrentTab = contentModeTabs.value.some(
      tab => tab.id === form.contentKind
    );
    if (!hasCurrentTab) {
      setContentKind(contentModeTabs.value[0].id);
    }
  }
);

watch(
  () => form.templateName,
  (templateName, previousTemplateName) => {
    if (!templateName) {
      form.templateLanguage = '';
      form.templateParams = {};
      form.templateBody = '';
      return;
    }

    const variants = selectedTemplateGroup.value?.variants || [];
    const hasSelectedLanguage = variants.some(
      template => template.language === form.templateLanguage
    );

    if (variants.length === 1) {
      form.templateLanguage = variants[0].language;
    } else if (!hasSelectedLanguage) {
      form.templateLanguage = '';
    }

    if (previousTemplateName && previousTemplateName !== templateName) {
      form.templateParams = {};
      form.templateBody = '';
    }
  }
);

watch(
  () => form.templateLanguage,
  (templateLanguage, previousTemplateLanguage) => {
    if (templateLanguage) {
      if (
        previousTemplateLanguage &&
        previousTemplateLanguage !== templateLanguage
      ) {
        form.templateParams = {};
        form.templateBody = '';
      }

      return;
    }

    form.templateParams = {};
    form.templateBody = '';
  }
);
</script>

<template>
  <TouchEditorShell
    :model-value="modelValue"
    :display-mode="displayMode"
    :close-on-outside="false"
    width="md"
    panel-class="sm:!rounded-2xl"
    :title="drawerTitle"
    :description="drawerDescription"
    :confirm-label="touch?.id ? drawerSaveLabel : drawerCreateLabel"
    :is-loading="ui.isSaving || ui.isUploadingAttachment"
    :disable-confirm="!canSave || ui.isSaving || ui.isUploadingAttachment"
    @update:model-value="emit('update:modelValue', $event)"
    @close="closeDrawer"
    @confirm="saveTouch"
  >
    <div class="grid gap-5">
      <div
        v-if="unsupportedChannelWarning"
        class="rounded-xl bg-n-amber-2 px-4 py-3 outline outline-1 outline-n-amber-6"
      >
        <p class="mb-0 text-sm leading-6 text-n-amber-12">
          {{ unsupportedChannelWarning }}
        </p>
      </div>

      <div
        v-if="!isSidebarMode && !isTargetSelectionMode"
        class="rounded-xl bg-n-brand/5 px-4 py-4 outline outline-1 outline-n-brand/10"
      >
        <p class="mb-1 text-sm font-semibold text-n-slate-12">
          {{
            $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.CONTEXT_TITLE', {
              entity: entityLabel,
            })
          }}
        </p>
        <p class="mb-0 text-sm leading-6 text-n-slate-11">
          {{ $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ROUTING_NOTE') }}
        </p>
      </div>

      <SchedulingFormFieldGroup v-if="isTargetSelectionMode" :framed="false">
        <div class="touch-target-section">
          <div class="touch-target-row touch-target-row--start">
            <label class="touch-target-label" for="touch-target-contact">
              {{ $t('COMPOSE_NEW_CONVERSATION.FORM.CONTACT_SELECTOR.LABEL') }}
            </label>
            <TagMultiSelectComboBox
              id="touch-target-contact"
              class="touch-target-control touch-target-contact-control"
              :aria-label="
                $t('COMPOSE_NEW_CONVERSATION.FORM.CONTACT_SELECTOR.LABEL')
              "
              :model-value="selectedTargetContactIds"
              :options="targetContactOptions"
              :placeholder="$t('NEW_CONVERSATION.FORM.TO.LABEL')"
              use-api-results
              dropdown-placement="auto"
              :search-placeholder="
                $t('CRM.DEALS.FORM.CONTACTS_SEARCH_PLACEHOLDER')
              "
              :empty-state="$t('CRM.DEALS.FORM.CONTACTS_EMPTY_STATE')"
              :message="
                isSearchingContacts
                  ? $t('CONTACT_PANEL.SIDEBAR.MERGE.IS_SEARCHING')
                  : ''
              "
              @open="loadTargetContacts('')"
              @search="debouncedLoadTargetContacts"
              @update:model-value="handleTargetContactIdsUpdate"
            />
          </div>

          <div class="touch-target-row">
            <label class="touch-target-label" for="touch-target-inbox">
              {{ $t('COMPOSE_NEW_CONVERSATION.FORM.INBOX_SELECTOR.LABEL') }}
            </label>
            <SchedulingSelectField
              id="touch-target-inbox"
              class="touch-target-control touch-target-select-control"
              :aria-label="
                $t('COMPOSE_NEW_CONVERSATION.FORM.INBOX_SELECTOR.LABEL')
              "
              :disabled="!selectedContact || isFetchingTargetInboxes"
              :model-value="targetInbox?.id || ''"
              :options="targetInboxOptions"
              :placeholder="$t('NEW_CONVERSATION.FORM.INBOX.PLACEHOLDER')"
              dropdown-placement="auto"
              @update:model-value="handleTargetInboxValueUpdate"
            />
          </div>
        </div>
      </SchedulingFormFieldGroup>

      <SchedulingFormFieldGroup v-if="showRecordSelector" :framed="false">
        <div class="grid gap-4">
          <SchedulingSelectField
            :label="$t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.ENTITY_TYPE')"
            :model-value="form.remindableType"
            :options="entityTypeOptions"
            @update:model-value="form.remindableType = $event"
          />

          <Input
            :label="$t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.ENTITY_ID')"
            :model-value="String(form.remindableId || '')"
            type="number"
            inputmode="numeric"
            :placeholder="
              $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.ENTITY_ID_PLACEHOLDER')
            "
            @update:model-value="form.remindableId = $event"
          />

          <p class="-mt-2 mb-0 text-xs leading-5 text-n-slate-11">
            {{ $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.ENTITY_NOTE') }}
          </p>
        </div>
      </SchedulingFormFieldGroup>

      <SchedulingFormFieldGroup :framed="false">
        <div class="grid gap-4">
          <SchedulingSelectField
            v-if="showActionTypeField"
            :label="$t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.ACTION_TYPE')"
            :model-value="form.actionType"
            :options="actionTypeOptions"
            @update:model-value="form.actionType = $event"
          />

          <TouchMessageComposer
            v-if="form.actionType === 'send_message'"
            ref="messageComposerRef"
            :active-content-tab-index="activeContentTabIndex"
            allow-ai-authoring
            :attachments="touchAttachments"
            :available-field-scopes="availableFieldScopes"
            :available-variable-prefixes="availableVariablePrefixes"
            :body="form.body"
            :body-editor-id="bodyEditorId"
            :channel-type="resolvedChannelType"
            :content-kind="form.contentKind"
            :content-mode-tab-id="contentModeTabId"
            :content-mode-tabs="contentModeTabs"
            :conversation-id="Number(resolvedConversationId) || null"
            :free-text-template-options="freeTextTemplateOptions"
            :instructions="form.instructions"
            :instructions-editor-id="instructionsEditorId"
            :is-dragging-attachment="ui.isDraggingAttachment"
            :is-uploading-attachment="ui.isUploadingAttachment"
            :medium="resolvedInboxMedium"
            :selected-template="selectedTemplate"
            :selected-template-group="selectedTemplateGroup"
            :template-language="form.templateLanguage"
            :template-language-options="templateLanguageOptions"
            :template-name="form.templateName"
            :template-options="templateOptions"
            :template-params="form.templateParams"
            :use-ai-authoring="form.useAiAuthoring"
            @attachment-files="uploadAttachmentFiles"
            @content-tab-change="handleContentTabChanged"
            @remove-attachment="removeAttachment"
            @set-attachment-dragging="setAttachmentDragState"
            @template-state-change="handleTemplateStateChange"
            @update:body="form.body = $event"
            @update:instructions="form.instructions = $event"
            @update:template-language="form.templateLanguage = $event"
            @update:template-name="form.templateName = $event"
            @update:use-ai-authoring="form.useAiAuthoring = $event"
          />
        </div>
      </SchedulingFormFieldGroup>

      <SchedulingFormFieldGroup :framed="false">
        <div class="grid gap-4">
          <div class="rounded-xl bg-n-surface-1 p-1">
            <TabBar
              :key="`touch-timing-mode-${activeTimingTabIndex}`"
              :tabs="timingModeTabs"
              :initial-active-tab="activeTimingTabIndex"
              @tab-changed="handleTimingTabChanged"
            />
          </div>

          <SchedulingDateTimeField
            v-if="showAbsoluteTimingEditor"
            :label="$t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.SCHEDULED_AT')"
            :model-value="form.scheduledAt"
            type="datetime"
            @update:model-value="form.scheduledAt = $event"
          />

          <template v-else>
            <div
              class="grid gap-3"
              :class="
                canUseFixedRelativeTime
                  ? 'md:grid-cols-[minmax(0,1fr)_minmax(12rem,14rem)] md:items-start'
                  : ''
              "
            >
              <SchedulingRelativeOffsetInput
                v-model:amount="form.relativeOffsetValue"
                v-model:unit="form.relativeOffsetUnit"
                :label="relativeOffsetInputLabel"
                :unit-options="relativeOffsetUnitOptions"
                min="1"
                @update:amount="
                  form.relativeOffsetValue = Math.max(1, Number($event || 0))
                "
              />

              <div
                v-if="canUseFixedRelativeTime"
                class="grid"
                :class="
                  useFixedRelativeTime ? 'gap-1' : 'gap-2 md:pt-[1.625rem]'
                "
              >
                <label
                  class="flex items-center gap-2 text-sm font-medium text-n-slate-12"
                  :class="useFixedRelativeTime ? 'mb-0.5' : 'min-h-10'"
                >
                  <Checkbox
                    class="shrink-0"
                    :model-value="useFixedRelativeTime"
                    @update:model-value="useFixedRelativeTime = $event"
                  />
                  <span>{{
                    $t(
                      'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_FIXED_TIME'
                    )
                  }}</span>
                </label>

                <SchedulingDateTimeField
                  v-if="useFixedRelativeTime"
                  :model-value="form.relativeTimeOfDay"
                  type="time"
                  :placeholder="
                    $t(
                      'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_TIME_OF_DAY'
                    )
                  "
                  @update:model-value="form.relativeTimeOfDay = $event"
                />
              </div>
            </div>

            <SchedulingSelectField
              :label="
                $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_ANCHOR')
              "
              :model-value="form.relativeAnchor"
              :options="relativeAnchorOptions"
              class="touch-relative-anchor-select"
              @update:model-value="form.relativeAnchor = $event"
            />

            <p class="-mt-2 mb-0 text-xs leading-5 text-n-slate-11">
              {{ relativeOffsetNote }}
            </p>
          </template>

          <template v-if="canConfigureRepeat">
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
                :model-value="form.repeatMode"
                :options="repeatModeOptions"
                @update:model-value="form.repeatMode = $event"
              />
            </div>

            <p class="-mt-2 mb-0 text-xs leading-5 text-n-slate-11">
              {{ repeatModeDescription }}
            </p>

            <SchedulingDateTimeField
              v-if="form.repeatMode !== 'once'"
              :label="
                $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.REPEAT_UNTIL_AT')
              "
              :model-value="form.repeatUntilAt"
              type="datetime"
              @update:model-value="form.repeatUntilAt = $event"
            />
          </template>
        </div>
      </SchedulingFormFieldGroup>

      <SchedulingFormFieldGroup :framed="false">
        <div
          class="grid grid-cols-[auto_minmax(0,1fr)] items-start gap-3 rounded-xl border border-n-weak bg-transparent px-4 py-3"
        >
          <Checkbox
            class="mt-0.5 shrink-0"
            :model-value="form.autoCancelOnIncoming"
            @update:model-value="form.autoCancelOnIncoming = $event"
          />
          <div class="min-w-0">
            <p class="mb-1 text-sm font-medium text-n-slate-12">
              {{ $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.AUTO_CANCEL') }}
            </p>
            <p class="mb-0 text-xs leading-5 text-n-slate-10">
              {{
                $t(
                  'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.AUTO_CANCEL_DESCRIPTION'
                )
              }}
            </p>
          </div>
        </div>
      </SchedulingFormFieldGroup>
    </div>

    <template #footer>
      <div class="flex items-center justify-between w-full gap-3">
        <div class="flex items-center gap-2">
          <Button
            size="sm"
            color="slate"
            variant="faded"
            :label="$t('SCHEDULING.GENERAL.CANCEL')"
            @click="closeDrawer"
          />
          <Button
            v-if="showAllTouchesAction"
            size="sm"
            color="slate"
            variant="outline"
            :label="$t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.VIEW_ALL')"
            @click="emit('viewAll')"
          />
        </div>
        <Button
          size="sm"
          :is-loading="ui.isSaving || ui.isUploadingAttachment"
          :disabled="!canSave || ui.isSaving || ui.isUploadingAttachment"
          :label="touch?.id ? drawerSaveLabel : drawerCreateLabel"
          @click="saveTouch"
        />
      </div>
    </template>
  </TouchEditorShell>
</template>

<style scoped>
.touch-target-section {
  @apply grid gap-2 rounded-xl border border-n-weak bg-n-solid-1 p-3 shadow-sm;
}

.touch-target-row {
  display: grid;
  gap: 0.375rem;
  min-width: 0;
}

.touch-target-label {
  @apply mb-0 min-w-0 text-[13px] font-medium leading-4 text-n-slate-12;
}

.touch-target-control,
.touch-target-section :deep(.touch-target-control) {
  min-width: 0;
  width: 100%;
}

.touch-target-section :deep(.touch-target-contact-control button),
.touch-target-section :deep(.touch-target-select-control button) {
  @apply border border-n-weak bg-n-alpha-black2 text-sm font-normal text-n-slate-12 shadow-none outline outline-1 outline-transparent transition-colors duration-150 !important;
  border-radius: 0.375rem !important;
}

.touch-target-section :deep(.touch-target-contact-control button) {
  height: auto !important;
  min-height: 2rem !important;
}

.touch-target-section :deep(.touch-target-select-control button) {
  height: 2rem !important;
}

.touch-target-section :deep(.touch-target-contact-control button),
.touch-target-section :deep(.touch-target-select-control button) {
  @apply justify-start py-1 !important;
}

.touch-target-section :deep(.touch-target-contact-control button:hover),
.touch-target-section :deep(.touch-target-select-control button:hover) {
  @apply border-n-slate-6 bg-n-alpha-black2 outline-transparent !important;
}

.touch-target-section :deep(.touch-target-contact-control button:focus),
.touch-target-section
  :deep(.touch-target-contact-control button[data-state='open']),
.touch-target-section :deep(.touch-target-select-control button:focus),
.touch-target-section
  :deep(.touch-target-select-control button[data-state='open']) {
  @apply border-n-weak bg-n-alpha-black2 outline-n-brand !important;
}

.touch-target-section :deep(.touch-target-contact-control button > div) {
  @apply max-w-[75%] rounded-md border border-n-blue-4/40 bg-n-blue-3/60 px-1.5 py-0.5 text-n-blue-11 !important;
}

.touch-target-section :deep(.touch-target-contact-control button > div span) {
  @apply text-n-blue-11 !important;
}

.touch-relative-anchor-select :deep(button) {
  height: auto !important;
  min-height: 2.75rem;
}

@media (min-width: 768px) {
  .touch-target-row {
    align-items: center;
    grid-template-columns: minmax(4.5rem, 5.5rem) minmax(0, 1fr);
  }

  .touch-target-row--start {
    align-items: start;
  }

  .touch-target-row--start > .touch-target-label {
    padding-top: 0.5rem;
  }

  .touch-target-label {
    @apply text-left;
  }
}

.touch-relative-anchor-select :deep(button > span) {
  align-items: flex-start;
}

.touch-relative-anchor-select :deep(button > span > span:last-child) {
  white-space: normal !important;
  overflow: visible !important;
  text-overflow: clip !important;
  word-break: break-word;
  line-height: 1.25rem;
}
</style>
