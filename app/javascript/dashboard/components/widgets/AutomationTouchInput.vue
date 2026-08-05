<script>
import { mapGetters } from 'vuex';
import { uploadFile } from 'dashboard/helper/uploadHelper';
import { useAlert } from 'dashboard/composables';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
import SchedulingDateTimeField from 'dashboard/components-next/Scheduling/SchedulingDateTimeField.vue';
import SchedulingFormFieldGroup from 'dashboard/components-next/Scheduling/SchedulingFormFieldGroup.vue';
import SchedulingRelativeOffsetInput from 'dashboard/components-next/Scheduling/SchedulingRelativeOffsetInput.vue';
import SchedulingSelectField from 'dashboard/components-next/Scheduling/SchedulingSelectField.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import TouchMessageComposer from 'dashboard/components-next/Outbound/TouchMessageComposer.vue';
import {
  TOUCH_CREATED_AT_ANCHOR,
  buildTouchAnchorOptions,
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
  getTemplateBodyPreview,
  groupWhatsAppTemplates,
} from 'dashboard/helper/whatsappTemplateLibrary';
import {
  buildTouchContentModeTabs,
  isWhatsAppTemplateCapableChannel,
} from 'dashboard/components-next/Outbound/touchContentModes';
import {
  fromDateTimeInputValue,
  toDateTimeInputValue,
} from 'dashboard/routes/dashboard/scheduling/helpers';

const BROWSER_TIMEZONE =
  Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

const DEFAULT_TOUCH_PARAMS = {
  action_type: 'send_message',
  attachments: [],
  body: '',
  content_kind: 'free_text',
  instructions: '',
  relative_anchor: TOUCH_CREATED_AT_ANCHOR,
  relative_offset_seconds: 60,
  relative_time_mode: RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME,
  relative_time_of_day: '',
  manual_schedule_override: false,
  repeat_mode: 'once',
  repeat_until_at: '',
  scheduled_at: '',
  target_inbox_id: '',
  template_params: {},
  text_mode: 'static',
  timing_mode: 'relative',
  timezone: BROWSER_TIMEZONE,
  auto_cancel_on_incoming: false,
  post_delivery_action: '',
  response_action: '',
  response_button_index: '',
};

const normalizeLegacyParams = raw => {
  if (
    !raw ||
    raw.timing_mode ||
    raw.scheduled_at ||
    raw.relative_offset_seconds
  ) {
    return raw || {};
  }

  if (raw.delay_minutes === undefined || raw.delay_minutes === null) {
    return raw || {};
  }

  const delayMinutes = Number(raw.delay_minutes || 0);
  return {
    ...raw,
    timing_mode: 'relative',
    relative_anchor: TOUCH_CREATED_AT_ANCHOR,
    relative_offset_seconds: Number.isFinite(delayMinutes)
      ? Math.max(0, delayMinutes) * 60
      : 0,
  };
};

const clone = value => JSON.parse(JSON.stringify(value || {}));
const normalizeArray = value => (Array.isArray(value) ? value : []);
const normalizeAttachmentId = attachment => {
  if (typeof attachment === 'string') return attachment;
  return (
    attachment?.blobId ||
    attachment?.blob_id ||
    attachment?.signed_id ||
    attachment?.signedId ||
    null
  );
};

export default {
  components: {
    Checkbox,
    TouchMessageComposer,
    SchedulingDateTimeField,
    SchedulingFormFieldGroup,
    SchedulingRelativeOffsetInput,
    SchedulingSelectField,
    TabBar,
  },
  props: {
    eventName: {
      type: String,
      default: '',
    },
    modelValue: {
      type: [Array, Object],
      default: () => ({}),
    },
  },
  emits: ['update:modelValue', 'input'],
  data() {
    return {
      isUploadingAttachment: false,
      isDraggingAttachment: false,
      localAttachmentDetails: {},
    };
  },
  computed: {
    ...mapGetters({
      allInboxes: 'inboxes/getAllInboxes',
      cannedMessages: 'getCannedResponses',
      getFilteredWhatsAppTemplates: 'inboxes/getFilteredWhatsAppTemplates',
    }),
    entityKey() {
      if (this.eventName?.startsWith('appointment_')) return 'appointment';
      if (this.eventName?.startsWith('deal_')) return 'deal';
      if (this.eventName?.startsWith('task_')) return 'task';
      return 'conversation';
    },
    availableVariablePrefixes() {
      if (this.entityKey === 'conversation') {
        return ['conversation', 'contact', 'agent', 'inbox'];
      }

      return ['contact', 'agent'];
    },
    availableFieldScopes() {
      const scopesByEntity = {
        appointment: ['contact', 'appointment'],
        conversation: ['contact', 'conversation'],
        deal: ['contact', 'deal'],
        task: ['contact', 'task'],
      };

      return scopesByEntity[this.entityKey] || scopesByEntity.conversation;
    },
    normalizedValue() {
      const raw = Array.isArray(this.modelValue)
        ? this.modelValue[0]
        : this.modelValue;
      const normalizedRaw = normalizeLegacyParams(raw);
      const value = {
        ...DEFAULT_TOUCH_PARAMS,
        ...normalizedRaw,
        attachments: normalizeArray(normalizedRaw?.attachments),
        template_params: clone(normalizedRaw?.template_params || {}),
        timezone: normalizedRaw?.timezone || BROWSER_TIMEZONE,
      };
      const relativeTime = normalizeRelativeTimeForUnit({
        relativeTimeMode: value.relative_time_mode,
        relativeTimeOfDay: value.relative_time_of_day,
        unit: normalizeRelativeOffset(value.relative_offset_seconds).unit,
      });
      const availableAnchorValues = this.relativeAnchorOptions.map(
        option => option.value
      );
      const relativeAnchor = value.relative_anchor || TOUCH_CREATED_AT_ANCHOR;

      return {
        ...value,
        action_type: 'send_message',
        relative_anchor: availableAnchorValues.includes(relativeAnchor)
          ? relativeAnchor
          : TOUCH_CREATED_AT_ANCHOR,
        relative_time_mode: relativeTime.relativeTimeMode,
        relative_time_of_day: relativeTime.relativeTimeOfDay,
      };
    },
    contentKind: {
      get() {
        return this.normalizedValue.content_kind;
      },
      set(value) {
        this.emitValue({ content_kind: value });
      },
    },
    useAiAuthoring: {
      get() {
        return this.normalizedValue.text_mode === 'agent';
      },
      set(value) {
        this.emitValue({ text_mode: value ? 'agent' : 'static' });
      },
    },
    body: {
      get() {
        return this.normalizedValue.body;
      },
      set(value) {
        this.emitValue({ body: value });
      },
    },
    instructions: {
      get() {
        return this.normalizedValue.instructions;
      },
      set(value) {
        this.emitValue({ instructions: value, text_mode: 'agent' });
      },
    },
    attachments: {
      get() {
        return this.normalizedValue.attachments;
      },
      set(value) {
        this.emitValue({
          attachments: normalizeArray(value)
            .map(normalizeAttachmentId)
            .filter(Boolean),
        });
      },
    },
    touchAttachments() {
      return this.attachments
        .map(attachment => {
          const blobId = normalizeAttachmentId(attachment);
          if (!blobId) return null;

          const details = this.localAttachmentDetails[blobId] || {};
          return {
            blobId,
            fileName:
              details.fileName ||
              attachment?.fileName ||
              attachment?.filename ||
              attachment?.name ||
              this.$t(
                'OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.FILE_FALLBACK'
              ),
            fileSize:
              details.fileSize || attachment?.fileSize || attachment?.size,
            contentType:
              details.contentType ||
              attachment?.contentType ||
              attachment?.content_type ||
              '',
          };
        })
        .filter(Boolean);
    },
    timingMode: {
      get() {
        return this.normalizedValue.timing_mode;
      },
      set(value) {
        this.emitValue({ timing_mode: value });
      },
    },
    scheduledAtPickerValue: {
      get() {
        return toDateTimeInputValue(this.normalizedValue.scheduled_at);
      },
      set(value) {
        this.emitValue({ scheduled_at: fromDateTimeInputValue(value) });
      },
    },
    repeatUntilAtPickerValue: {
      get() {
        return toDateTimeInputValue(this.normalizedValue.repeat_until_at);
      },
      set(value) {
        this.emitValue({
          repeat_until_at: fromDateTimeInputValue(value) || '',
        });
      },
    },
    relativeAnchor: {
      get() {
        return this.normalizedValue.relative_anchor || TOUCH_CREATED_AT_ANCHOR;
      },
      set(value) {
        this.emitValue({ relative_anchor: value, timing_mode: 'relative' });
      },
    },
    relativeOffset() {
      return normalizeRelativeOffset(
        this.normalizedValue.relative_offset_seconds
      );
    },
    relativeOffsetDirection: {
      get() {
        return this.relativeOffset.direction;
      },
      set(value) {
        this.updateRelativeOffset({ direction: value });
      },
    },
    relativeOffsetUnit: {
      get() {
        return this.relativeOffset.unit;
      },
      set(value) {
        this.updateRelativeOffset({ unit: value });
      },
    },
    relativeOffsetValue: {
      get() {
        return this.relativeOffset.value;
      },
      set(value) {
        this.updateRelativeOffset({ value: Math.max(1, Number(value || 0)) });
      },
    },
    canUseFixedRelativeTime() {
      return canUseFixedRelativeTimeForUnit(this.relativeOffsetUnit);
    },
    useFixedRelativeTime: {
      get() {
        return (
          this.canUseFixedRelativeTime &&
          this.normalizedValue.relative_time_mode ===
            RELATIVE_TIME_MODES.FIXED_TIME_OF_DAY
        );
      },
      set(value) {
        if (!this.canUseFixedRelativeTime) {
          this.emitValue({
            relative_time_mode: RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME,
            relative_time_of_day: '',
          });
          return;
        }

        this.emitValue({
          relative_time_mode: value
            ? RELATIVE_TIME_MODES.FIXED_TIME_OF_DAY
            : RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME,
          relative_time_of_day: value
            ? this.relativeTimeOfDay || DEFAULT_RELATIVE_TIME_OF_DAY
            : '',
        });
      },
    },
    relativeTimeOfDay: {
      get() {
        return this.normalizedValue.relative_time_of_day || '';
      },
      set(value) {
        if (!this.canUseFixedRelativeTime) {
          this.emitValue({
            relative_time_mode: RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME,
            relative_time_of_day: '',
          });
          return;
        }

        this.emitValue({
          relative_time_mode: RELATIVE_TIME_MODES.FIXED_TIME_OF_DAY,
          relative_time_of_day: value || DEFAULT_RELATIVE_TIME_OF_DAY,
        });
      },
    },
    repeatMode: {
      get() {
        return this.normalizedValue.repeat_mode;
      },
      set(value) {
        this.emitValue({
          repeat_mode: value,
          ...(value === 'once'
            ? {}
            : {
                post_delivery_action: '',
                response_action: '',
                response_button_index: '',
              }),
        });
      },
    },
    timezone: {
      get() {
        return this.normalizedValue.timezone;
      },
      set(value) {
        this.emitValue({ timezone: value || BROWSER_TIMEZONE });
      },
    },
    autoCancelOnIncoming: {
      get() {
        return this.normalizedValue.auto_cancel_on_incoming;
      },
      set(value) {
        this.emitValue({ auto_cancel_on_incoming: value });
      },
    },
    resolveConversationAfterDelivery: {
      get() {
        return (
          this.normalizedValue.post_delivery_action === 'resolve_conversation'
        );
      },
      set(value) {
        this.emitValue({
          post_delivery_action: value ? 'resolve_conversation' : '',
          ...(value ? { repeat_mode: 'once', repeat_until_at: '' } : {}),
        });
      },
    },
    confirmAppointmentOnReply: {
      get() {
        return this.normalizedValue.response_action === 'confirm_appointment';
      },
      set(value) {
        this.emitValue({
          response_action: value ? 'confirm_appointment' : '',
          response_button_index: value ? 0 : '',
          ...(value ? { repeat_mode: 'once', repeat_until_at: '' } : {}),
        });
      },
    },
    targetInboxId: {
      get() {
        return this.normalizedValue.target_inbox_id || '';
      },
      set(value) {
        const targetInboxId = value ? Number(value) : '';
        const payload = { target_inbox_id: targetInboxId };

        if (this.isChannelTemplate) {
          payload.template_params = {};
          payload.body = '';
          payload.response_action = '';
          payload.response_button_index = '';
        }

        this.emitValue(payload);
      },
    },
    freeTextTemplateOptions() {
      return (this.cannedMessages || [])
        .filter(template => template?.short_code && template?.content)
        .map(template => ({
          value: template.id || template.short_code,
          label: template.short_code || template.name || `#${template.id}`,
          content: template.content || '',
        }));
    },
    whatsAppInboxOptions() {
      return (this.allInboxes || [])
        .filter(inbox => {
          const channelType = inbox.channelType || inbox.channel_type;
          const medium = inbox.medium || inbox.channel?.medium || '';
          return isWhatsAppTemplateCapableChannel({ channelType, medium });
        })
        .map(inbox => ({
          label: inbox.name || inbox.channelName || `#${inbox.id}`,
          value: Number(inbox.id),
        }));
    },
    deliveryInboxOptions() {
      return (this.allInboxes || []).map(inbox => ({
        label: inbox.name || inbox.channelName || `#${inbox.id}`,
        value: Number(inbox.id),
      }));
    },
    selectedTargetInbox() {
      if (!this.targetInboxId) return null;

      return (
        (this.allInboxes || []).find(
          inbox => Number(inbox.id) === Number(this.targetInboxId)
        ) || null
      );
    },
    isOfficialWhatsAppCloudTarget() {
      return (
        (this.selectedTargetInbox?.channelType ||
          this.selectedTargetInbox?.channel_type) === 'Channel::Whatsapp' &&
        this.selectedTargetInbox?.provider === 'whatsapp_cloud'
      );
    },
    targetInboxSupportsTemplates() {
      const channelType =
        this.selectedTargetInbox?.channelType ||
        this.selectedTargetInbox?.channel_type;
      const medium =
        this.selectedTargetInbox?.medium ||
        this.selectedTargetInbox?.channel?.medium ||
        '';

      return isWhatsAppTemplateCapableChannel({ channelType, medium });
    },
    templateGroups() {
      if (!this.targetInboxId || !this.getFilteredWhatsAppTemplates) {
        return [];
      }

      return groupWhatsAppTemplates(
        this.getFilteredWhatsAppTemplates(Number(this.targetInboxId)) || []
      );
    },
    templateOptions() {
      return this.templateGroups.map(group => ({
        label: this.friendlyTemplateName(group.name),
        value: group.name,
      }));
    },
    selectedTemplateGroup() {
      return (
        this.templateGroups.find(group => group.name === this.templateName) ||
        null
      );
    },
    templateLanguageOptions() {
      return (
        this.selectedTemplateGroup?.variants.map(template => ({
          label: template.language,
          value: template.language,
        })) || []
      );
    },
    selectedTemplate() {
      if (!this.selectedTemplateGroup || !this.templateLanguage) {
        return null;
      }

      return (
        this.selectedTemplateGroup.variants.find(
          template => template.language === this.templateLanguage
        ) || null
      );
    },
    selectedTemplateButtons() {
      const buttonComponent = (this.selectedTemplate?.components || []).find(
        component => component?.type?.toUpperCase() === 'BUTTONS'
      );

      return buttonComponent?.buttons || [];
    },
    canConfigureAppointmentConfirmation() {
      const [onlyButton] = this.selectedTemplateButtons;
      return (
        this.entityKey === 'appointment' &&
        this.isChannelTemplate &&
        this.isOfficialWhatsAppCloudTarget &&
        this.selectedTemplateButtons.length === 1 &&
        onlyButton?.type?.toUpperCase() === 'QUICK_REPLY'
      );
    },
    hasTemplateCatalog() {
      return this.whatsAppInboxOptions.length > 0;
    },
    hasSelectedInboxTemplates() {
      return this.templateGroups.length > 0;
    },
    templateName: {
      get() {
        return this.normalizedValue.template_params?.name || '';
      },
      set(value) {
        this.selectTemplateName(value);
      },
    },
    templateLanguage: {
      get() {
        return (
          this.normalizedValue.template_params?.language ||
          this.normalizedValue.template_params?.language_code ||
          ''
        );
      },
      set(value) {
        this.selectTemplateLanguage(value);
      },
    },
    isSendMessageTouch() {
      return true;
    },
    isChannelTemplate() {
      return this.contentKind === 'channel_template';
    },
    isAbsoluteTiming() {
      return this.timingMode === 'absolute';
    },
    isRecurring() {
      return this.repeatMode !== 'once';
    },
    contentModeTabs() {
      return buildTouchContentModeTabs({
        t: this.$t,
        supportsFreeText: true,
        supportsWhatsAppTemplates: this.hasTemplateCatalog,
      });
    },
    activeContentTabIndex() {
      const index = this.contentModeTabs.findIndex(
        tab => tab.id === this.contentKind
      );
      return index === -1 ? 0 : index;
    },
    timingModeTabs() {
      return [
        {
          id: TOUCH_TIMING_STATES.ABSOLUTE,
          label: this.$t(
            'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.ABSOLUTE_MODE'
          ),
        },
        {
          id: TOUCH_TIMING_STATES.AFTER,
          label: this.$t(
            'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_AFTER'
          ),
        },
        {
          id: TOUCH_TIMING_STATES.BEFORE,
          label: this.$t(
            'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_BEFORE'
          ),
        },
      ];
    },
    activeTimingTabIndex() {
      const activeState = resolveTouchTimingState({
        relativeOffsetSeconds: toRelativeOffsetSeconds({
          direction: this.relativeOffsetDirection,
          unit: this.relativeOffsetUnit,
          value: this.relativeOffsetValue,
        }),
        timingMode: this.timingMode,
      });
      const index = this.timingModeTabs.findIndex(
        tab => tab.id === activeState
      );
      return index === -1 ? 0 : index;
    },
    relativeOffsetInputLabel() {
      return this.relativeOffsetDirection === TOUCH_TIMING_STATES.BEFORE
        ? this.$t(
            'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_BEFORE_EVENT'
          )
        : this.$t(
            'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_AFTER_EVENT'
          );
    },
    relativeOffsetUnitOptions() {
      return [
        {
          label: this.$t(
            'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_UNITS.MINUTES'
          ),
          value: 'minutes',
        },
        {
          label: this.$t(
            'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_UNITS.HOURS'
          ),
          value: 'hours',
        },
        {
          label: this.$t(
            'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_UNITS.DAYS'
          ),
          value: 'days',
        },
      ];
    },
    relativeAnchorOptions() {
      return buildTouchAnchorOptions({
        t: this.$t,
        entityKinds: this.entityKey,
        includeTouchCreatedAt: true,
      });
    },
    repeatModeOptions() {
      return [
        {
          label: this.$t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE.ONCE'),
          value: 'once',
        },
        {
          label: this.$t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE.DAILY'),
          value: 'daily',
        },
        {
          label: this.$t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE.WEEKLY'),
          value: 'weekly',
        },
        {
          label: this.$t(
            'OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE.WEEKDAYS'
          ),
          value: 'weekdays',
        },
        {
          label: this.$t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE.MONTHLY'),
          value: 'monthly',
        },
      ];
    },
    repeatModeDescription() {
      switch (this.repeatMode) {
        case 'daily':
          return this.$t(
            'OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE_HELP.DAILY'
          );
        case 'weekly':
          return this.$t(
            'OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE_HELP.WEEKLY'
          );
        case 'monthly':
          return this.$t(
            'OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE_HELP.MONTHLY'
          );
        case 'weekdays':
          return this.$t(
            'OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE_HELP.WEEKDAYS'
          );
        case 'once':
        default:
          return this.$t(
            'OUTBOUND_WORKSPACE.TOUCH_EDITOR.REPEAT_MODE_HELP.ONCE'
          );
      }
    },
    relativeOffsetNote() {
      return this.$t(
        'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_NOTE'
      );
    },
    bodyEditorId() {
      return `automation-touch-editor-body-${this.eventName || 'rule'}`;
    },
    instructionsEditorId() {
      return `automation-touch-editor-instructions-${this.eventName || 'rule'}`;
    },
  },
  mounted() {
    this.$store.dispatch('getCannedResponse', { searchKey: '' });
  },
  methods: {
    cleanPayload(payload) {
      const cleaned = {
        ...payload,
        action_type: 'send_message',
        attachments: normalizeArray(payload.attachments)
          .map(normalizeAttachmentId)
          .filter(Boolean),
        template_params: clone(payload.template_params || {}),
        timezone: payload.timezone || BROWSER_TIMEZONE,
      };

      delete cleaned.delay_minutes;

      if (cleaned.action_type !== 'send_message') {
        cleaned.content_kind = 'free_text';
        cleaned.body = '';
        cleaned.instructions = '';
        cleaned.template_params = {};
        cleaned.text_mode = 'static';
        cleaned.attachments = [];
      } else if (cleaned.content_kind === 'channel_template') {
        cleaned.instructions = '';
        cleaned.text_mode = 'static';
        cleaned.attachments = [];
      } else if (cleaned.text_mode === 'agent') {
        cleaned.body = '';
        cleaned.template_params = {};
      } else {
        cleaned.instructions = '';
        cleaned.template_params = {};
        cleaned.text_mode = detectTouchTextMode({
          actionType: cleaned.action_type,
          body: cleaned.body,
        });
      }

      if (cleaned.timing_mode === 'absolute') {
        cleaned.relative_anchor = '';
        cleaned.relative_offset_seconds = 0;
        cleaned.relative_time_mode = RELATIVE_TIME_MODES.INHERIT_ANCHOR_TIME;
        cleaned.relative_time_of_day = '';
      } else {
        cleaned.timing_mode = 'relative';
        cleaned.scheduled_at = '';
        cleaned.repeat_mode = 'once';
        cleaned.repeat_until_at = '';
        cleaned.relative_anchor =
          cleaned.relative_anchor || TOUCH_CREATED_AT_ANCHOR;
        cleaned.relative_offset_seconds = cleaned.relative_offset_seconds || 60;
        const relativeTime = normalizeRelativeTimeForUnit({
          relativeTimeMode: cleaned.relative_time_mode,
          relativeTimeOfDay: cleaned.relative_time_of_day,
          unit: normalizeRelativeOffset(cleaned.relative_offset_seconds).unit,
        });
        cleaned.relative_time_mode = relativeTime.relativeTimeMode;
        cleaned.relative_time_of_day = relativeTime.relativeTimeOfDay;
      }

      if (cleaned.repeat_mode === 'once') {
        cleaned.repeat_until_at = '';
      }

      if (
        this.entityKey !== 'conversation' ||
        cleaned.repeat_mode !== 'once' ||
        !cleaned.post_delivery_action
      ) {
        delete cleaned.post_delivery_action;
      }

      const responseButtonIndex = Number(cleaned.response_button_index);
      const validAppointmentResponse =
        this.entityKey === 'appointment' &&
        this.canConfigureAppointmentConfirmation &&
        cleaned.content_kind === 'channel_template' &&
        cleaned.repeat_mode === 'once' &&
        cleaned.response_action === 'confirm_appointment' &&
        responseButtonIndex === 0;

      if (validAppointmentResponse) {
        cleaned.response_button_index = responseButtonIndex;
      } else {
        delete cleaned.response_action;
        delete cleaned.response_button_index;
      }

      return cleaned;
    },
    emitValue(partial) {
      const payload = this.cleanPayload({
        ...this.normalizedValue,
        ...partial,
      });

      this.$emit('update:modelValue', payload);
      this.$emit('input', payload);
    },
    emitTemplateParams(partial, extraPayload = {}) {
      this.emitValue({
        ...extraPayload,
        content_kind: 'channel_template',
        target_inbox_id:
          this.targetInboxId || extraPayload.target_inbox_id || '',
        template_params: {
          ...this.normalizedValue.template_params,
          ...partial,
        },
      });
    },
    friendlyTemplateName(templateName) {
      return String(templateName || '')
        .replace(/_/g, ' ')
        .replace(/\b\w/g, letter => letter.toUpperCase());
    },
    templateParamsFor(template, processedParams = {}) {
      return {
        name: template?.name || this.templateName,
        namespace: template?.namespace || '',
        category: template?.category || 'UTILITY',
        language: template?.language || this.templateLanguage,
        processed_params: clone(processedParams),
      };
    },
    selectTemplateName(templateName) {
      const group = this.templateGroups.find(
        templateGroup => templateGroup.name === templateName
      );
      const template = group?.variants.length === 1 ? group.variants[0] : null;

      this.emitTemplateParams(
        {
          name: templateName,
          namespace: template?.namespace || '',
          category: template?.category || group?.category || 'UTILITY',
          language: template?.language || '',
          processed_params: {},
        },
        {
          body: template ? getTemplateBodyPreview(template) : '',
          target_inbox_id: this.targetInboxId,
          response_action: '',
          response_button_index: '',
        }
      );
    },
    selectTemplateLanguage(language) {
      const template =
        this.selectedTemplateGroup?.variants.find(
          variant => variant.language === language
        ) || null;

      this.emitTemplateParams(this.templateParamsFor(template, {}), {
        body: template ? getTemplateBodyPreview(template) : '',
        target_inbox_id: this.targetInboxId,
        response_action: '',
        response_button_index: '',
      });
    },
    handleTemplateStateChange(payload) {
      if (!this.isChannelTemplate || !this.selectedTemplate) return;

      this.emitTemplateParams(
        this.templateParamsFor(
          this.selectedTemplate,
          payload?.processedParams || {}
        ),
        {
          body:
            payload?.rawRenderedTemplate ||
            getTemplateBodyPreview(this.selectedTemplate),
          target_inbox_id: this.targetInboxId,
        }
      );
    },
    handleContentTabChanged(tab) {
      if (tab.id === 'channel_template' && !this.targetInboxSupportsTemplates) {
        const [onlyWhatsAppInbox] = this.whatsAppInboxOptions;
        this.emitValue({
          content_kind: tab.id,
          target_inbox_id:
            this.whatsAppInboxOptions.length === 1
              ? onlyWhatsAppInbox.value
              : '',
          template_params: {},
          body: '',
        });
        return;
      }

      this.contentKind = tab.id;
    },
    setTimingState(state) {
      if (state === TOUCH_TIMING_STATES.ABSOLUTE) {
        this.emitValue({ timing_mode: TOUCH_TIMING_STATES.ABSOLUTE });
        return;
      }

      this.emitValue({
        timing_mode: 'relative',
        repeat_mode: 'once',
        repeat_until_at: '',
        relative_offset_seconds: toRelativeOffsetSeconds({
          direction: state,
          unit: this.relativeOffsetUnit,
          value: this.relativeOffsetValue,
        }),
      });
    },
    handleTimingTabChanged(tab) {
      this.setTimingState(tab.id);
    },
    updateRelativeOffset(partial) {
      this.emitValue({
        timing_mode: 'relative',
        relative_offset_seconds: toRelativeOffsetSeconds({
          direction: this.relativeOffset.direction,
          unit: this.relativeOffset.unit,
          value: this.relativeOffset.value,
          ...partial,
        }),
      });
    },
    setAttachmentDragState(value) {
      if (this.isUploadingAttachment) return;
      this.isDraggingAttachment = value;
    },
    async uploadAttachmentFiles(filesInput) {
      const files = Array.from(filesInput || []);
      if (files.length === 0) return;

      this.isUploadingAttachment = true;
      try {
        const uploadedIds = (
          await Promise.all(
            files.map(async file => {
              const result = await uploadFile(file);
              if (!result?.blobId) return null;

              this.localAttachmentDetails = {
                ...this.localAttachmentDetails,
                [result.blobId]: {
                  fileName: file.name,
                  fileSize: file.size,
                  contentType: file.type,
                },
              };
              return result.blobId;
            })
          )
        ).filter(Boolean);

        this.attachments = [...this.attachments, ...uploadedIds];
      } catch (error) {
        useAlert(
          error?.response?.data?.error ||
            error?.message ||
            this.$t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.ATTACHMENTS.UPLOAD_ERROR')
        );
      } finally {
        this.isUploadingAttachment = false;
        this.isDraggingAttachment = false;
      }
    },
    removeAttachment(blobId) {
      this.attachments = this.attachments.filter(
        attachment => normalizeAttachmentId(attachment) !== blobId
      );
    },
  },
};
</script>

<template>
  <div
    class="grid gap-5 rounded-2xl bg-n-solid-1 p-4 outline outline-1 outline-n-weak"
  >
    <SchedulingFormFieldGroup :framed="false">
      <div class="grid gap-4">
        <SchedulingSelectField
          v-if="isSendMessageTouch && !isChannelTemplate"
          :label="$t('AUTOMATION.ACTION.TOUCH_EDITOR.TARGET_INBOX_LABEL')"
          :model-value="targetInboxId"
          :options="deliveryInboxOptions"
          :empty-state="$t('AUTOMATION.ACTION.TOUCH_EDITOR.TARGET_INBOX_EMPTY')"
          :message="$t('AUTOMATION.ACTION.TOUCH_EDITOR.TARGET_INBOX_NOTE')"
          @update:model-value="targetInboxId = $event"
        />

        <TouchMessageComposer
          v-if="isSendMessageTouch"
          :active-content-tab-index="activeContentTabIndex"
          allow-ai-authoring
          :attachments="touchAttachments"
          :available-field-scopes="availableFieldScopes"
          :available-variable-prefixes="availableVariablePrefixes"
          :body="body"
          :body-editor-id="bodyEditorId"
          :content-kind="contentKind"
          :content-mode-tabs="contentModeTabs"
          :free-text-template-options="freeTextTemplateOptions"
          :instructions="instructions"
          :instructions-editor-id="instructionsEditorId"
          :is-dragging-attachment="isDraggingAttachment"
          :is-uploading-attachment="isUploadingAttachment"
          :selected-template="selectedTemplate"
          :selected-template-group="selectedTemplateGroup"
          :template-empty-description="
            targetInboxId
              ? $t(
                  'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_EMPTY_DESCRIPTION'
                )
              : $t('AUTOMATION.ACTION.TOUCH_EDITOR.WHATSAPP_INBOX_NOTE')
          "
          :template-empty-title="
            !hasTemplateCatalog
              ? $t('AUTOMATION.ACTION.TOUCH_EDITOR.WHATSAPP_INBOX_EMPTY')
              : $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.TEMPLATE_EMPTY')
          "
          :template-language="templateLanguage"
          :template-language-options="templateLanguageOptions"
          :template-name="templateName"
          :template-options="templateOptions"
          :template-params="
            normalizedValue.template_params?.processed_params || {}
          "
          :use-ai-authoring="useAiAuthoring"
          @attachment-files="uploadAttachmentFiles"
          @content-tab-change="handleContentTabChanged"
          @remove-attachment="removeAttachment"
          @set-attachment-dragging="setAttachmentDragState"
          @template-state-change="handleTemplateStateChange"
          @update:body="body = $event"
          @update:instructions="instructions = $event"
          @update:template-language="templateLanguage = $event"
          @update:template-name="templateName = $event"
          @update:use-ai-authoring="useAiAuthoring = $event"
        >
          <template #template-controls-before>
            <SchedulingSelectField
              :label="$t('AUTOMATION.ACTION.TOUCH_EDITOR.WHATSAPP_INBOX_LABEL')"
              :model-value="targetInboxId"
              :options="whatsAppInboxOptions"
              :empty-state="
                $t('AUTOMATION.ACTION.TOUCH_EDITOR.WHATSAPP_INBOX_EMPTY')
              "
              :message="
                $t('AUTOMATION.ACTION.TOUCH_EDITOR.WHATSAPP_INBOX_NOTE')
              "
              @update:model-value="targetInboxId = $event"
            />
          </template>
        </TouchMessageComposer>

        <div
          v-if="canConfigureAppointmentConfirmation"
          class="grid gap-3 rounded-2xl bg-n-alpha-black2 px-4 py-3"
        >
          <label
            class="grid grid-cols-[auto_minmax(0,1fr)] items-start gap-3 text-sm"
          >
            <Checkbox
              class="mt-0.5 shrink-0"
              :model-value="confirmAppointmentOnReply"
              @update:model-value="confirmAppointmentOnReply = $event"
            />
            <span class="min-w-0">
              <span class="block font-medium text-n-slate-12">
                {{
                  $t(
                    'AUTOMATION.ACTION.TOUCH_EDITOR.APPOINTMENT_CONFIRMATION_LABEL'
                  )
                }}
              </span>
              <span class="mt-1 block text-xs leading-5 text-n-slate-10">
                {{
                  $t(
                    'AUTOMATION.ACTION.TOUCH_EDITOR.APPOINTMENT_CONFIRMATION_DESCRIPTION'
                  )
                }}
              </span>
            </span>
          </label>
        </div>
      </div>
    </SchedulingFormFieldGroup>

    <SchedulingFormFieldGroup :framed="false">
      <div class="grid gap-4">
        <div class="rounded-2xl bg-n-surface-1 p-1">
          <TabBar
            :key="`automation-touch-timing-${activeTimingTabIndex}`"
            :tabs="timingModeTabs"
            :initial-active-tab="activeTimingTabIndex"
            @tab-changed="handleTimingTabChanged"
          />
        </div>

        <SchedulingDateTimeField
          v-if="isAbsoluteTiming"
          :label="$t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.SCHEDULED_AT')"
          :model-value="scheduledAtPickerValue"
          type="datetime"
          @update:model-value="scheduledAtPickerValue = $event"
        />

        <template v-else>
          <div
            class="grid gap-3"
            :class="
              canUseFixedRelativeTime
                ? 'md:grid-cols-[minmax(0,1fr)_minmax(12rem,14rem)] md:items-end'
                : ''
            "
          >
            <SchedulingRelativeOffsetInput
              v-model:amount="relativeOffsetValue"
              v-model:unit="relativeOffsetUnit"
              :label="relativeOffsetInputLabel"
              :unit-options="relativeOffsetUnitOptions"
              min="1"
            />

            <div v-if="canUseFixedRelativeTime" class="grid gap-1">
              <label
                class="mb-0.5 flex items-center gap-2 text-sm font-medium text-n-slate-12"
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
                :model-value="relativeTimeOfDay"
                type="time"
                :placeholder="
                  $t(
                    'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_TIME_OF_DAY'
                  )
                "
                @update:model-value="relativeTimeOfDay = $event"
              />
            </div>
          </div>

          <SchedulingSelectField
            :label="
              $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_ANCHOR')
            "
            :model-value="relativeAnchor"
            :options="relativeAnchorOptions"
            class="touch-relative-anchor-select"
            @update:model-value="relativeAnchor = $event"
          />

          <p class="-mt-2 mb-0 text-xs leading-5 text-n-slate-11">
            {{ relativeOffsetNote }}
          </p>
        </template>

        <template v-if="isAbsoluteTiming">
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
              :model-value="repeatMode"
              :options="repeatModeOptions"
              @update:model-value="repeatMode = $event"
            />
          </div>

          <p class="-mt-2 mb-0 text-xs leading-5 text-n-slate-11">
            {{ repeatModeDescription }}
          </p>

          <SchedulingDateTimeField
            v-if="isRecurring"
            :label="
              $t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.REPEAT_UNTIL_AT')
            "
            :model-value="repeatUntilAtPickerValue"
            type="datetime"
            @update:model-value="repeatUntilAtPickerValue = $event"
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
          :model-value="autoCancelOnIncoming"
          @update:model-value="autoCancelOnIncoming = $event"
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

    <SchedulingFormFieldGroup
      v-if="entityKey === 'conversation'"
      :framed="false"
    >
      <div
        class="grid grid-cols-[auto_minmax(0,1fr)] items-start gap-3 rounded-2xl bg-n-alpha-black2 px-4 py-3"
      >
        <Checkbox
          class="mt-0.5 shrink-0"
          :model-value="resolveConversationAfterDelivery"
          @update:model-value="resolveConversationAfterDelivery = $event"
        />
        <div class="min-w-0">
          <p class="mb-1 text-sm font-medium text-n-slate-12">
            {{
              $t('AUTOMATION.ACTION.TOUCH_EDITOR.POST_DELIVERY_RESOLVE_LABEL')
            }}
          </p>
          <p class="mb-0 text-xs leading-5 text-n-slate-10">
            {{
              $t('AUTOMATION.ACTION.TOUCH_EDITOR.POST_DELIVERY_RESOLVE_NOTE')
            }}
          </p>
        </div>
      </div>
    </SchedulingFormFieldGroup>
  </div>
</template>

<style scoped>
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
