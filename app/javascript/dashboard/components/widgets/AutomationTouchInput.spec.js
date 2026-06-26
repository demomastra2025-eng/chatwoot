import { describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import AutomationTouchInput from './AutomationTouchInput.vue';

const whatsappTemplates = [
  {
    name: 'welcome_message',
    namespace: 'ns_en',
    language: 'en',
    category: 'UTILITY',
    status: 'APPROVED',
    components: [{ type: 'BODY', text: 'Hello {{1}}' }],
  },
  {
    name: 'welcome_message',
    namespace: 'ns_ru',
    language: 'ru',
    category: 'MARKETING',
    status: 'APPROVED',
    components: [{ type: 'BODY', text: 'Здравствуйте {{1}}' }],
  },
];

const defaultStoreGetters = {
  'inboxes/getAllInboxes': [
    { id: 7, name: 'Official WhatsApp', channelType: 'Channel::Whatsapp' },
    {
      id: 8,
      name: 'Twilio WhatsApp',
      channelType: 'Channel::TwilioSms',
      medium: 'whatsapp',
    },
    { id: 9, name: 'TestakhanBot', channelType: 'Channel::Telegram' },
  ],
  'inboxes/getFilteredWhatsAppTemplates': inboxId =>
    Number(inboxId) === 7 ? whatsappTemplates : [],
  getCannedResponses: [
    { id: 1, short_code: 'visit_reminder', content: 'We are waiting for you' },
  ],
};

const mountComponent = ({ storeGetters = {}, ...props } = {}) =>
  shallowMount(AutomationTouchInput, {
    props: {
      eventName: 'message_created',
      modelValue: {},
      ...props,
    },
    global: {
      mocks: {
        $store: {
          dispatch: vi.fn(),
          getters: { ...defaultStoreGetters, ...storeGetters },
        },
        $t: key => key,
      },
      directives: {
        tooltip: () => {},
      },
      stubs: {
        NextButton: true,
        Checkbox: true,
        ComboBox: true,
        Input: true,
        SchedulingDateTimeField: true,
        SchedulingFormFieldGroup: true,
        SchedulingRelativeOffsetInput: true,
        SchedulingSelectField: true,
        TabBar: true,
        WhatsAppTemplateParser: true,
        WootMessageEditor: true,
      },
    },
  });

const applyLastPayload = async wrapper => {
  const payload = wrapper.emitted('update:modelValue').at(-1)[0];
  await wrapper.setProps({ modelValue: payload });
  return payload;
};

describe('AutomationTouchInput', () => {
  it('defaults new automation touches to full relative touch params and no auto-cancel unless explicitly enabled', () => {
    const wrapper = mountComponent();

    expect(wrapper.vm.normalizedValue.action_type).toBe('send_message');
    expect(wrapper.vm.normalizedValue.timing_mode).toBe('relative');
    expect(wrapper.vm.normalizedValue.relative_anchor).toBe('touch.created_at');
    expect(wrapper.vm.normalizedValue.relative_time_mode).toBe(
      'inherit_anchor_time'
    );
    expect(wrapper.vm.normalizedValue.relative_time_of_day).toBe('');
    expect(wrapper.vm.normalizedValue.auto_cancel_on_incoming).toBe(false);
    expect(wrapper.vm.autoCancelOnIncoming).toBe(false);
    expect(wrapper.vm.contentModeTabs.map(tab => tab.id)).toEqual([
      'free_text',
      'channel_template',
    ]);
  });

  it('hides the descriptive header and touch type selector while forcing message touches', () => {
    const wrapper = mountComponent({
      modelValue: {
        action_type: 'ai_agent_wakeup',
        body: 'Follow up',
      },
    });

    expect(wrapper.vm.normalizedValue.action_type).toBe('send_message');
    expect(wrapper.vm.isSendMessageTouch).toBe(true);
    expect(wrapper.html()).not.toContain(
      'AUTOMATION.ACTION.TOUCH_EDITOR.TITLE'
    );
    expect(wrapper.html()).not.toContain(
      'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.ACTION_TYPE'
    );
  });

  it('shows the free text tab from canned responses and limits WhatsApp templates to WhatsApp Cloud inboxes', () => {
    const wrapper = mountComponent();

    expect(wrapper.vm.freeTextTemplateOptions).toEqual([
      {
        value: 1,
        label: 'visit_reminder',
        content: 'We are waiting for you',
      },
    ]);
    expect(wrapper.vm.deliveryInboxOptions).toEqual([
      { label: 'Official WhatsApp', value: 7 },
      { label: 'Twilio WhatsApp', value: 8 },
      { label: 'TestakhanBot', value: 9 },
    ]);
    expect(wrapper.vm.whatsAppInboxOptions).toEqual([
      { label: 'Official WhatsApp', value: 7 },
    ]);
  });

  it('keeps free text available when templates exist but there are no canned responses', () => {
    const wrapper = mountComponent({
      storeGetters: {
        getCannedResponses: [],
      },
    });

    expect(wrapper.vm.freeTextTemplateOptions).toEqual([]);
    expect(wrapper.vm.contentModeTabs.map(tab => tab.id)).toEqual([
      'free_text',
      'channel_template',
    ]);
  });

  it('preserves free-text content when selecting an explicit sending channel', () => {
    const wrapper = mountComponent({
      eventName: 'appointment_created',
      modelValue: {
        body: 'Ваш визит запланирован',
        timing_mode: 'relative',
        relative_anchor: 'touch.created_at',
        relative_offset_seconds: 60,
      },
    });

    wrapper.vm.targetInboxId = 9;

    const payload = wrapper.emitted('update:modelValue').at(-1)[0];
    expect(payload).toMatchObject({
      body: 'Ваш визит запланирован',
      content_kind: 'free_text',
      target_inbox_id: 9,
      timing_mode: 'relative',
      relative_anchor: 'touch.created_at',
      relative_offset_seconds: 60,
    });
  });

  it('converts legacy delay_minutes params into relative timing for editing', () => {
    const wrapper = mountComponent({
      modelValue: [
        { body: 'Follow up', delay_minutes: 15, auto_cancel_on_incoming: true },
      ],
    });

    expect(wrapper.vm.normalizedValue.auto_cancel_on_incoming).toBe(true);
    expect(wrapper.vm.normalizedValue.timing_mode).toBe('relative');
    expect(wrapper.vm.normalizedValue.relative_anchor).toBe('touch.created_at');
    expect(wrapper.vm.normalizedValue.relative_offset_seconds).toBe(900);
  });

  it('emits AI-authored relative touch params', async () => {
    const wrapper = mountComponent();

    wrapper.vm.useAiAuthoring = true;
    await applyLastPayload(wrapper);
    wrapper.vm.instructions = 'Generate a contextual follow-up';
    await applyLastPayload(wrapper);
    wrapper.vm.relativeOffsetUnit = 'hours';
    await applyLastPayload(wrapper);
    wrapper.vm.relativeOffsetValue = 2;

    const payload = wrapper.emitted('update:modelValue').at(-1)[0];
    expect(payload).toMatchObject({
      action_type: 'send_message',
      content_kind: 'free_text',
      text_mode: 'agent',
      instructions: 'Generate a contextual follow-up',
      timing_mode: 'relative',
      relative_anchor: 'touch.created_at',
      relative_offset_seconds: 7200,
      repeat_mode: 'once',
    });
    expect(payload).not.toHaveProperty('delay_minutes');
  });

  it('emits relative touch params with a fixed time of day override', async () => {
    const wrapper = mountComponent();

    expect(wrapper.vm.relativeOffsetInputLabel).toBe(
      'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_AFTER_EVENT'
    );

    wrapper.vm.relativeOffsetDirection = 'before';
    await applyLastPayload(wrapper);

    expect(wrapper.vm.relativeOffsetInputLabel).toBe(
      'OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.RELATIVE_OFFSET_BEFORE_EVENT'
    );

    expect(wrapper.vm.canUseFixedRelativeTime).toBe(false);
    wrapper.vm.relativeOffsetUnit = 'days';
    await applyLastPayload(wrapper);
    expect(wrapper.vm.canUseFixedRelativeTime).toBe(true);

    wrapper.vm.useFixedRelativeTime = true;
    await applyLastPayload(wrapper);
    wrapper.vm.relativeTimeOfDay = '09:30';

    const payload = wrapper.emitted('update:modelValue').at(-1)[0];
    expect(payload).toMatchObject({
      timing_mode: 'relative',
      relative_time_mode: 'fixed_time_of_day',
      relative_time_of_day: '09:30',
      scheduled_at: '',
      repeat_mode: 'once',
    });
  });

  it('keeps recurring params only for absolute touches', async () => {
    const wrapper = mountComponent();

    wrapper.vm.timingMode = 'absolute';
    await applyLastPayload(wrapper);
    wrapper.vm.repeatMode = 'daily';

    let payload = wrapper.emitted('update:modelValue').at(-1)[0];
    expect(payload).toMatchObject({
      timing_mode: 'absolute',
      repeat_mode: 'daily',
    });

    await wrapper.setProps({ modelValue: payload });
    wrapper.vm.timingMode = 'relative';

    payload = wrapper.emitted('update:modelValue').at(-1)[0];
    expect(payload).toMatchObject({
      timing_mode: 'relative',
      repeat_mode: 'once',
      repeat_until_at: '',
    });
  });

  it('lets automation pick an exact WhatsApp template and inbox ahead of trigger execution', async () => {
    const wrapper = mountComponent({
      modelValue: {
        content_kind: 'channel_template',
        target_inbox_id: 7,
        template_params: {},
      },
    });

    expect(wrapper.vm.whatsAppInboxOptions).toEqual([
      { label: 'Official WhatsApp', value: 7 },
    ]);
    expect(wrapper.vm.templateOptions).toEqual([
      { label: 'Welcome Message', value: 'welcome_message' },
    ]);

    wrapper.vm.templateName = 'welcome_message';
    await applyLastPayload(wrapper);
    wrapper.vm.templateLanguage = 'ru';

    const payload = wrapper.emitted('update:modelValue').at(-1)[0];
    expect(payload).toMatchObject({
      content_kind: 'channel_template',
      target_inbox_id: 7,
      body: 'Здравствуйте {{1}}',
      text_mode: 'static',
      template_params: {
        name: 'welcome_message',
        namespace: 'ns_ru',
        category: 'MARKETING',
        language: 'ru',
        processed_params: {},
      },
    });
  });

  it('limits variables, field scopes, and relative anchors to the automation entity context', () => {
    const cases = [
      {
        eventName: 'conversation_updated',
        variables: ['conversation', 'contact', 'agent', 'inbox'],
        fields: ['contact', 'conversation'],
        anchors: [
          'touch.created_at',
          'conversation.created_at',
          'conversation.last_activity_at',
          'conversation.last_incoming_message_at',
          'conversation.last_outgoing_message_at',
          'conversation.waiting_since',
        ],
      },
      {
        eventName: 'appointment_updated',
        variables: ['contact', 'agent'],
        fields: ['contact', 'appointment'],
        anchors: [
          'touch.created_at',
          'appointment.created_at',
          'appointment.starts_at',
          'appointment.ends_at',
        ],
      },
      {
        eventName: 'deal_updated',
        variables: ['contact', 'agent'],
        fields: ['contact', 'deal'],
        anchors: [
          'touch.created_at',
          'deal.created_at',
          'deal.expected_close_on',
        ],
      },
      {
        eventName: 'task_updated',
        variables: ['contact', 'agent'],
        fields: ['contact', 'task'],
        anchors: ['touch.created_at', 'task.created_at', 'task.due_at'],
      },
    ];

    cases.forEach(({ eventName, variables, fields, anchors }) => {
      const wrapper = mountComponent({ eventName });

      expect(wrapper.vm.availableVariablePrefixes).toEqual(variables);
      expect(wrapper.vm.availableFieldScopes).toEqual(fields);
      expect(
        wrapper.vm.relativeAnchorOptions.map(option => option.value)
      ).toEqual(anchors);
      expect(wrapper.vm.availableFieldScopes).toContain('contact');
    });
  });

  it('normalizes a stale relative anchor when the automation event context changes', () => {
    const wrapper = mountComponent({
      eventName: 'deal_updated',
      modelValue: {
        body: 'Follow up',
        timing_mode: 'relative',
        relative_anchor: 'appointment.starts_at',
        relative_offset_seconds: 3600,
      },
    });

    expect(wrapper.vm.normalizedValue.relative_anchor).toBe('touch.created_at');
    expect(
      wrapper.vm.relativeAnchorOptions.map(option => option.value)
    ).not.toContain('appointment.starts_at');
  });
});
