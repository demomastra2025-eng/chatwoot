<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { debounce } from '@chatwoot/utils';
import camelcaseKeys from 'camelcase-keys';

import ContactAPI from 'dashboard/api/contacts';
import TouchesAPI from 'dashboard/api/touches';
import { uploadFile } from 'dashboard/helper/uploadHelper';
import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import Button from 'dashboard/components-next/button/Button.vue';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import ContactSelector from 'dashboard/components-next/NewConversation/components/ContactSelector.vue';
import InboxSelector from 'dashboard/components-next/NewConversation/components/InboxSelector.vue';
import {
  buildContactableInboxesList,
  createContactSearcher,
  createNewContact,
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
import WhatsAppTemplateParser from 'dashboard/components-next/whatsapp/WhatsAppTemplateParser.vue';
import WootMessageEditor from 'dashboard/components/widgets/WootWriter/Editor.vue';
import {
  TOUCH_CREATED_AT_ANCHOR,
  buildTouchAnchorOptions,
  touchAnchorEntityKindForRemindableType,
} from 'dashboard/components-next/Outbound/touchAnchors';
import {
  normalizeRelativeOffset,
  resolveTouchTimingState,
  toRelativeOffsetSeconds,
  TOUCH_TIMING_STATES,
} from 'dashboard/components-next/Outbound/touchTiming';
import { detectTouchTextMode } from 'dashboard/components-next/Outbound/touchTextMode';
import { groupWhatsAppTemplates } from 'dashboard/helper/whatsappTemplateLibrary';
import { INBOX_TYPES, TWILIO_CHANNEL_MEDIUM } from 'dashboard/helper/inbox.js';
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

const { t } = useI18n();
const currentAccountId = useMapGetter('getCurrentAccountId');
const getAllInboxes = useMapGetter('inboxes/getAllInboxes');
const getFilteredWhatsAppTemplates = useMapGetter(
  'inboxes/getFilteredWhatsAppTemplates'
);
const templateParserRef = ref(null);
const searchContacts = createContactSearcher();
const contacts = ref([]);
const isCreatingTargetContact = ref(false);
const isSearchingContacts = ref(false);
const isFetchingTargetInboxes = ref(false);
const selectedContact = ref(null);
const showContactsDropdown = ref(false);
const showInboxesDropdown = ref(false);
const targetInbox = ref(null);
const attachmentFileInput = ref(null);
const touchAttachments = ref([]);

const cloneTemplateParams = value => JSON.parse(JSON.stringify(value || {}));
const friendlyTemplateName = templateName =>
  String(templateName || '')
    .replace(/_/g, ' ')
    .replace(/\b\w/g, letter => letter.toUpperCase());

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
const contactableInboxesList = computed(() => {
  return buildContactableInboxesList(selectedContact.value?.contactInboxes);
});
const selectedContactId = computed(() => {
  const numericId = Number(selectedContact.value?.id);
  return Number.isFinite(numericId) && numericId > 0 ? numericId : null;
});

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
const resolvedInboxMedium = computed(() => resolvedInbox.value?.medium || '');
const requiresTemplateOnly = computed(
  () =>
    resolvedChannelType.value === INBOX_TYPES.WHATSAPP ||
    (resolvedChannelType.value === INBOX_TYPES.TWILIO &&
      resolvedInboxMedium.value === TWILIO_CHANNEL_MEDIUM.WHATSAPP)
);
const isWhatsAppTemplateCapable = computed(() => {
  if (!resolvedInbox.value) {
    return false;
  }

  return (
    resolvedChannelType.value === INBOX_TYPES.WHATSAPP ||
    (resolvedChannelType.value === INBOX_TYPES.TWILIO &&
      resolvedInboxMedium.value === TWILIO_CHANNEL_MEDIUM.WHATSAPP)
  );
});
const templateGroups = computed(() => {
  if (!resolvedInboxId.value) {
    return [];
  }

  return groupWhatsAppTemplates(
    getFilteredWhatsAppTemplates.value(resolvedInboxId.value) || []
  );
});
const contentModeTabs = computed(() => {
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
const canConfigureRepeat = computed(() => showAbsoluteTimingEditor.value);
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
    !!selectedTemplate.value && templateParserRef.value?.isFormInvalid === false
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

const formatAttachmentSize = size => {
  const byteSize = Number(size || 0);
  if (!Number.isFinite(byteSize) || byteSize <= 0) return '';
  if (byteSize < 1024 * 1024) return `${Math.ceil(byteSize / 1024)} KB`;
  return `${(byteSize / (1024 * 1024)).toFixed(1)} MB`;
};

const openAttachmentPicker = () => {
  attachmentFileInput.value?.click();
};

const removeAttachment = blobId => {
  touchAttachments.value = touchAttachments.value.filter(
    attachment => attachment.blobId !== blobId
  );
};

const handleAttachmentUpload = async event => {
  const files = Array.from(event.target.files || []);
  event.target.value = '';

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
  }
};

const setContentKind = kind => {
  form.contentKind = kind;

  if (kind === 'channel_template') {
    form.useAiAuthoring = false;
  }
};

const handleContentTabChanged = tab => {
  setContentKind(tab.id);
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
  showContactsDropdown.value = false;
  showInboxesDropdown.value = false;
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

const onContactSearch = debounce(
  async query => {
    isSearchingContacts.value = true;
    contacts.value = [];

    try {
      const results = await searchContacts(query);
      if (results === null) {
        return;
      }

      contacts.value = results;
    } catch {
      useAlert(t('COMPOSE_NEW_CONVERSATION.CONTACT_SEARCH.ERROR_MESSAGE'));
    } finally {
      isSearchingContacts.value = false;
    }
  },
  400,
  false
);

const handleContactSearch = value => {
  showContactsDropdown.value = value.trim().length > 1;
  onContactSearch(value);
};

const handleDropdownUpdate = (type, value) => {
  if (type === 'contacts') {
    showContactsDropdown.value = value;
  }
};

const clearSelectedContact = () => {
  clearTargetSelection();
};

const handleTargetInboxAction = inbox => {
  targetInbox.value = inbox;
  showInboxesDropdown.value = false;
};

const setSelectedContactOption = async ({ value, action, ...rest }) => {
  let contact = rest;

  if (action === 'create') {
    isCreatingTargetContact.value = true;
    try {
      contact = await createNewContact(value);
    } finally {
      isCreatingTargetContact.value = false;
    }
  }

  selectedContact.value = await prepareContactWithInboxes(contact);
  contacts.value = [];
  showContactsDropdown.value = false;
  showInboxesDropdown.value = true;
  resetTargetInbox();
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
  hydrateAttachments([]);
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
          relative_anchor: form.relativeAnchor,
          relative_offset_seconds: toRelativeOffsetSeconds({
            direction: form.relativeOffsetDirection,
            unit: form.relativeOffsetUnit,
            value: form.relativeOffsetValue,
          }),
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
  () => form.timingMode,
  value => {
    if (value !== 'absolute') {
      form.repeatMode = 'once';
      form.repeatUntilAt = '';
    }
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
  () => requiresTemplateOnly.value,
  value => {
    if (value) {
      setContentKind('channel_template');
    }
  },
  { immediate: true }
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

watch(
  () =>
    JSON.stringify({
      processedParams: templateParserRef.value?.processedParams || {},
      rawRenderedTemplate: templateParserRef.value?.rawRenderedTemplate || '',
    }),
  payload => {
    if (form.contentKind !== 'channel_template' || !templateParserRef.value) {
      return;
    }

    const parsedPayload = JSON.parse(payload || '{}');
    form.templateParams = cloneTemplateParams(parsedPayload.processedParams);
    form.templateBody = String(parsedPayload.rawRenderedTemplate || '');
  }
);
</script>

<template>
  <TouchEditorShell
    :model-value="modelValue"
    :display-mode="displayMode"
    :close-on-outside="false"
    width="md"
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
        v-if="!isSidebarMode && !isTargetSelectionMode"
        class="rounded-2xl bg-n-brand/5 px-4 py-4 outline outline-1 outline-n-brand/10"
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
        <div class="grid gap-1 rounded-2xl bg-n-alpha-black2 py-1">
          <ContactSelector
            :contacts="contacts"
            :selected-contact="selectedContact"
            :show-contacts-dropdown="showContactsDropdown"
            :is-loading="isSearchingContacts"
            :is-creating-contact="isCreatingTargetContact"
            :contactable-inboxes-list="contactableInboxesList"
            :show-inboxes-dropdown="showInboxesDropdown"
            @search-contacts="handleContactSearch"
            @set-selected-contact="setSelectedContactOption"
            @clear-selected-contact="clearSelectedContact"
            @update-dropdown="handleDropdownUpdate"
          />

          <InboxSelector
            :target-inbox="targetInbox"
            :selected-contact="selectedContact"
            :show-inboxes-dropdown="showInboxesDropdown"
            :contactable-inboxes-list="contactableInboxesList"
            :is-fetching-inboxes="isFetchingTargetInboxes"
            @update-inbox="handleTargetInboxAction"
            @toggle-dropdown="showInboxesDropdown = $event"
            @handle-inbox-action="handleTargetInboxAction"
          />
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

          <template v-if="form.actionType === 'send_message'">
            <div
              v-if="contentModeTabs.length > 1"
              class="rounded-2xl bg-n-alpha-black2 p-1"
            >
              <TabBar
                :key="contentModeTabId"
                :tabs="contentModeTabs"
                :initial-active-tab="activeContentTabIndex"
                @tab-changed="handleContentTabChanged"
              />
            </div>

            <template v-if="form.contentKind === 'channel_template'">
              <div v-if="templateGroups.length" class="grid gap-4">
                <div class="flex flex-col gap-1">
                  <label
                    for="touch-template-name"
                    class="mb-0.5 text-sm font-medium text-n-slate-12"
                  >
                    {{ $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE') }}
                  </label>
                  <ComboBox
                    id="touch-template-name"
                    v-model="form.templateName"
                    :options="templateOptions"
                    :placeholder="
                      $t(
                        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_PLACEHOLDER'
                      )
                    "
                    class="[&>div>button]:bg-n-alpha-black2 [&>div>button:not(.focused)]:dark:outline-n-weak [&>div>button:not(.focused)]:hover:!outline-n-slate-6"
                  />
                </div>

                <div v-if="selectedTemplateGroup" class="flex flex-col gap-1">
                  <label
                    for="touch-template-language"
                    class="mb-0.5 text-sm font-medium text-n-slate-12"
                  >
                    {{
                      $t(
                        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_LANGUAGE'
                      )
                    }}
                  </label>
                  <ComboBox
                    id="touch-template-language"
                    v-model="form.templateLanguage"
                    :options="templateLanguageOptions"
                    :placeholder="
                      $t(
                        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_LANGUAGE_PLACEHOLDER'
                      )
                    "
                    class="[&>div>button]:bg-n-alpha-black2 [&>div>button:not(.focused)]:dark:outline-n-weak [&>div>button:not(.focused)]:hover:!outline-n-slate-6"
                  />
                </div>

                <WhatsAppTemplateParser
                  v-if="selectedTemplate"
                  ref="templateParserRef"
                  :template="selectedTemplate"
                  :initial-processed-params="form.templateParams"
                />
              </div>

              <div
                v-else
                class="rounded-2xl border border-dashed border-n-weak bg-n-solid-1 px-4 py-5"
              >
                <p class="mb-1 text-sm font-medium text-n-slate-12">
                  {{
                    $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_EMPTY')
                  }}
                </p>
                <p class="mb-0 text-sm text-n-slate-11">
                  {{
                    $t(
                      'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_EMPTY_DESCRIPTION'
                    )
                  }}
                </p>
              </div>
            </template>

            <template v-else>
              <div class="flex items-center justify-between gap-3">
                <p class="mb-0 text-sm font-medium text-n-slate-12">
                  {{ $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.BODY') }}
                </p>
                <Button
                  v-tooltip.top-end="
                    $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.AI_AGENT')
                  "
                  icon="i-woot-captain"
                  :variant="form.useAiAuthoring ? 'solid' : 'faded'"
                  color="slate"
                  size="sm"
                  :aria-pressed="form.useAiAuthoring"
                  :class="aiToggleButtonClass(form.useAiAuthoring)"
                  @click="form.useAiAuthoring = !form.useAiAuthoring"
                />
              </div>

              <WootMessageEditor
                v-if="!form.useAiAuthoring"
                :model-value="form.body"
                :editor-id="bodyEditorId"
                class="touch-editor-large"
                :class="[touchEditorClass(false)]"
                :channel-type="resolvedChannelType"
                :conversation-id="Number(resolvedConversationId) || null"
                :medium="resolvedInboxMedium"
                enable-variables
                enable-captain-fields
                enable-canned-responses
                canned-menu-placement="bottom"
                :canned-menu-visible-items="3"
                :placeholder="
                  $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.BODY_PLACEHOLDER')
                "
                @update:model-value="form.body = $event"
              />

              <WootMessageEditor
                v-else
                :model-value="form.instructions"
                :editor-id="instructionsEditorId"
                class="touch-editor-large"
                :class="[touchEditorClass(true)]"
                :channel-type="resolvedChannelType"
                :conversation-id="Number(resolvedConversationId) || null"
                :medium="resolvedInboxMedium"
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
                @update:model-value="form.instructions = $event"
              />
            </template>

            <div class="grid gap-3 rounded-2xl bg-n-alpha-black2 px-4 py-3">
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="mb-1 text-sm font-medium text-n-slate-12">
                    {{
                      $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.TITLE')
                    }}
                  </p>
                  <p class="mb-0 text-xs leading-5 text-n-slate-10">
                    {{
                      $t(
                        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.DESCRIPTION'
                      )
                    }}
                  </p>
                </div>
                <Button
                  icon="i-lucide-paperclip"
                  size="sm"
                  color="slate"
                  variant="faded"
                  :is-loading="ui.isUploadingAttachment"
                  :disabled="ui.isUploadingAttachment"
                  :label="
                    ui.isUploadingAttachment
                      ? $t(
                          'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.UPLOADING'
                        )
                      : $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.ADD')
                  "
                  @click="openAttachmentPicker"
                />
              </div>

              <input
                ref="attachmentFileInput"
                type="file"
                multiple
                class="hidden"
                @change="handleAttachmentUpload"
              />

              <div v-if="touchAttachments.length" class="grid gap-2">
                <div
                  v-for="attachment in touchAttachments"
                  :key="attachment.blobId"
                  class="flex items-center gap-3 rounded-xl bg-n-solid-1 px-3 py-2 outline outline-1 outline-n-weak"
                >
                  <span class="i-lucide-file size-4 shrink-0 text-n-slate-11" />
                  <div class="min-w-0 flex-1">
                    <p
                      class="mb-0 truncate text-sm font-medium text-n-slate-12"
                    >
                      {{ attachment.fileName }}
                    </p>
                    <p
                      v-if="
                        formatAttachmentSize(attachment.fileSize) ||
                        attachment.contentType
                      "
                      class="mb-0 truncate text-xs text-n-slate-10"
                    >
                      {{
                        formatAttachmentSize(attachment.fileSize) ||
                        attachment.contentType
                      }}
                    </p>
                  </div>
                  <Button
                    icon="i-lucide-x"
                    size="xs"
                    color="slate"
                    variant="ghost"
                    :aria-label="
                      $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.REMOVE')
                    "
                    @click="removeAttachment(attachment.blobId)"
                  />
                </div>
              </div>
            </div>
          </template>
        </div>
      </SchedulingFormFieldGroup>

      <SchedulingFormFieldGroup :framed="false">
        <div class="grid gap-4">
          <div class="rounded-2xl bg-n-surface-1 p-1">
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
            <SchedulingRelativeOffsetInput
              v-model:amount="form.relativeOffsetValue"
              v-model:unit="form.relativeOffsetUnit"
              :label="
                $t(
                  'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_VALUE'
                )
              "
              :unit-options="relativeOffsetUnitOptions"
              min="1"
              @update:amount="
                form.relativeOffsetValue = Math.max(1, Number($event || 0))
              "
            />

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
          class="grid grid-cols-[auto_minmax(0,1fr)] items-start gap-3 rounded-2xl bg-n-alpha-black2 px-4 py-3"
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
.touch-editor-large {
  min-height: 13rem;
}

.touch-rich-editor :deep(.ProseMirror-menubar-wrapper),
.touch-rich-editor :deep(.ProseMirror),
.touch-rich-editor :deep(.ProseMirror-menubar) {
  min-width: 0;
  width: 100%;
  max-width: 100%;
}

.touch-editor-large :deep(.ProseMirror) {
  min-height: 8.5rem;
}

.touch-rich-editor {
  overflow: visible;
}

.touch-rich-editor :deep(.mention--box),
.touch-rich-editor :deep(.copilot-editor-menu) {
  z-index: 70;
}

.touch-relative-anchor-select :deep(button) {
  height: auto !important;
  min-height: 2.75rem;
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
