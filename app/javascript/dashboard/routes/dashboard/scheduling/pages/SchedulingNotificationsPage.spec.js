import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';
import { ref } from 'vue';
import SchedulingNotificationsPage from './SchedulingNotificationsPage.vue';
import AutomationAPI from 'dashboard/api/automation';
import ResourcesAPI from 'dashboard/api/scheduling/resources';
import ServicesAPI from 'dashboard/api/scheduling/services';
import CabinetsAPI from 'dashboard/api/scheduling/cabinets';
import CrmFieldDefinitionsAPI from 'dashboard/api/crm/fieldDefinitions';
import { fetchAppointmentFieldFill } from 'dashboard/helper/appointmentFieldFill';
import { buildFieldReferenceForSemanticKey } from 'dashboard/helper/appointmentTemplatePresets';

const mocks = vi.hoisted(() => ({
  dispatch: vi.fn().mockResolvedValue(undefined),
  rules: [],
  inboxes: [],
  alert: vi.fn(),
}));
vi.mock('vue-i18n', async importOriginal => ({
  ...(await importOriginal()),
  useI18n: () => ({ t: key => key }),
}));
vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRoute: () => ({ query: {} }),
}));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: key =>
    ref(key === 'automations/getAutomations' ? mocks.rules : mocks.inboxes),
}));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    currentAccount: ref({
      id: 1,
      name: 'Test Clinic',
      workspace_working_hours_timezone: 'Asia/Almaty',
      settings: {
        client_languages: ['ru', 'kk'],
        bilingual_templates_enabled: false,
      },
    }),
  }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: mocks.alert }));
vi.mock('dashboard/api/automation', () => ({
  default: {
    update: vi.fn(),
    create: vi.fn(),
    adoptCalendarNotification: vi.fn(),
  },
}));
vi.mock('dashboard/api/scheduling/resources', () => ({
  default: { get: vi.fn().mockResolvedValue({ data: { payload: [] } }) },
}));
vi.mock('dashboard/api/scheduling/services', () => ({
  default: { get: vi.fn().mockResolvedValue({ data: { payload: [] } }) },
}));
vi.mock('dashboard/api/scheduling/cabinets', () => ({
  default: { get: vi.fn().mockResolvedValue({ data: { payload: [] } }) },
}));
vi.mock('dashboard/api/crm/fieldDefinitions', () => ({
  default: { get: vi.fn().mockResolvedValue({ data: { payload: [] } }) },
}));
vi.mock('dashboard/helper/appointmentFieldFill', async importOriginal => ({
  ...(await importOriginal()),
  fetchAppointmentFieldFill: vi.fn().mockResolvedValue([]),
}));

const rule = overrides => ({
  id: 1,
  name: 'Запись создана',
  event_name: 'appointment_created',
  active: false,
  calendar_managed: true,
  description: '[scheduling_preset:appointment_created]',
  conditions: [
    {
      attribute_key: 'source',
      filter_operator: 'equal_to',
      values: ['manual'],
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
          template_params: { name: 'visit_notice', language: 'ru' },
          target_inbox_id: 3,
          relative_anchor: 'touch.created_at',
          relative_offset_seconds: 0,
        },
      ],
    },
  ],
  ...overrides,
});
const mountPage = async () => {
  const wrapper = shallowMount(SchedulingNotificationsPage, {
    global: { stubs: { RouterLink: true } },
  });
  await flushPromises();
  return wrapper;
};

beforeEach(() => {
  vi.clearAllMocks();
  mocks.rules = [];
  mocks.inboxes = [
    {
      id: 3,
      name: 'WhatsApp Clinic',
      channel_type: 'Channel::Whatsapp',
      message_templates: [
        {
          name: 'visit_notice',
          language: 'ru',
          status: 'APPROVED',
          components: [{ type: 'BODY', text: 'Здравствуйте' }],
        },
      ],
    },
  ];
  mocks.dispatch.mockResolvedValue(undefined);
  ResourcesAPI.get.mockResolvedValue({ data: { payload: [] } });
  ServicesAPI.get.mockResolvedValue({ data: { payload: [] } });
  CabinetsAPI.get.mockResolvedValue({ data: { payload: [] } });
  CrmFieldDefinitionsAPI.get.mockResolvedValue({ data: { payload: [] } });
  AutomationAPI.update.mockResolvedValue({ data: {} });
  AutomationAPI.adoptCalendarNotification.mockResolvedValue({ data: {} });
  fetchAppointmentFieldFill.mockResolvedValue([]);
});

describe('SchedulingNotificationsPage', () => {
  it('shows six collapsed accordion preset cards with toggle switches, channel, template counts and the pack wizard on first run', async () => {
    const wrapper = await mountPage();
    expect(
      wrapper.findAll('[data-testid^="reminder-preset-card-"]')
    ).toHaveLength(6);
    expect(
      wrapper.find('[data-testid="preset-whatsapp-preview-text"]').exists()
    ).toBe(false);
    expect(wrapper.find('[data-testid="preset-setup-btn"]').exists()).toBe(
      false
    );
    expect(
      wrapper.find('[data-testid="calendar-notification-editor"]').exists()
    ).toBe(false);
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.FIRST_RUN');
    expect(wrapper.text()).toContain('WhatsApp Clinic');
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.TEMPLATE_PACK');
    expect(
      wrapper.findAll('[data-testid^="reminder-preset-card-"] input:disabled')
    ).toHaveLength(6);
  });

  it('auto-selects the first WhatsApp inbox when multiple WhatsApp inboxes exist', async () => {
    mocks.inboxes = [
      {
        id: 5236,
        name: 'WhatsApp Primary',
        channel_type: 'Channel::Whatsapp',
        message_templates: [
          {
            name: 'visit_notice',
            language: 'ru',
            status: 'APPROVED',
            components: [{ type: 'BODY', text: 'Здравствуйте' }],
          },
        ],
      },
      {
        id: 5237,
        name: 'WhatsApp Secondary',
        channel_type: 'Channel::Whatsapp',
        message_templates: [],
      },
    ];
    const wrapper = await mountPage();
    const channelSelect = wrapper.find('select');
    expect(channelSelect.element.value).toBe('5236');
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.APPROVED: 1');
  });

  it('recognizes a preset by marker after its send time changes and renders inline WhatsApp preview when expanded', async () => {
    mocks.rules = [
      rule({
        actions: [
          {
            action_name: 'create_touch',
            action_params: [
              {
                action_type: 'send_message',
                content_kind: 'channel_template',
                template_params: { name: 'visit_notice', language: 'ru' },
                target_inbox_id: 3,
                relative_anchor: 'touch.created_at',
                relative_offset_seconds: 7200,
              },
            ],
          },
        ],
      }),
    ];
    const wrapper = await mountPage();
    const card = wrapper.find(
      '[data-testid="reminder-preset-card-appointment_created"]'
    );
    expect(card.text()).toContain('visit_notice');
    expect(
      card.find('[data-testid="preset-whatsapp-preview-text"]').exists()
    ).toBe(false);
    await card.find('.cursor-pointer').trigger('click');
    expect(
      card.find('[data-testid="preset-whatsapp-preview-text"]').text()
    ).toContain('Здравствуйте');
    expect(
      wrapper.findAll('[data-testid^="reminder-preset-card-"]')
    ).toHaveLength(6);
    expect(wrapper.text()).not.toContain('SCHEDULING.NOTIFICATIONS.FIRST_RUN');
  });

  it('keeps duplicate and unknown-marked rules in Другие правила', async () => {
    mocks.rules = [
      rule({ id: 1, name: 'Основное правило' }),
      rule({ id: 2, name: 'Дополнительное правило' }),
      rule({
        id: 3,
        name: 'Неизвестный маркер',
        description: '[scheduling_preset:later]',
      }),
    ];
    const wrapper = await mountPage();
    expect(wrapper.text()).toContain('Дополнительное правило');
    expect(wrapper.text()).toContain('Неизвестный маркер');
  });

  it('keeps a preset off while its template is on Meta review', async () => {
    mocks.inboxes[0].message_templates[0].status = 'PENDING';
    mocks.rules = [rule({ active: false })];
    const wrapper = await mountPage();
    const card = wrapper.find(
      '[data-testid="reminder-preset-card-appointment_created"]'
    );
    expect(card.text()).toContain(
      'SCHEDULING.NOTIFICATIONS.TEMPLATE_STATUS.PENDING'
    );
    expect(
      card.find('input[type="checkbox"]').attributes('disabled')
    ).toBeDefined();
  });

  it('previews example appointment values and a quick reply button inside the expanded preset card', async () => {
    mocks.inboxes[0].message_templates[0].components = [
      { type: 'BODY', text: 'Здравствуйте, {{1}}' },
      {
        type: 'BUTTONS',
        buttons: [{ type: 'QUICK_REPLY', text: 'Подтверждаю' }],
      },
    ];
    mocks.rules = [
      rule({
        actions: [
          {
            action_name: 'create_touch',
            action_params: [
              {
                action_type: 'send_message',
                content_kind: 'channel_template',
                target_inbox_id: 3,
                template_params: {
                  name: 'visit_notice',
                  language: 'ru',
                  processed_params: {
                    body: {
                      1: buildFieldReferenceForSemanticKey('client_name'),
                    },
                  },
                },
                relative_anchor: 'touch.created_at',
                relative_offset_seconds: 0,
              },
            ],
          },
        ],
      }),
    ];
    const wrapper = await mountPage();
    const card = wrapper.find(
      '[data-testid="reminder-preset-card-appointment_created"]'
    );
    await card.find('.cursor-pointer').trigger('click');
    expect(
      card.find('[data-testid="preset-whatsapp-preview-text"]').text()
    ).toContain('Анна');
    expect(card.text()).toContain('Подтверждаю');
  });

  it('keeps the switch off when a field is missing in future appointments', async () => {
    mocks.rules = [
      rule({
        actions: [
          {
            action_name: 'create_touch',
            action_params: [
              {
                action_type: 'send_message',
                content_kind: 'channel_template',
                template_params: {
                  name: 'visit_notice',
                  language: 'ru',
                  processed_params: {
                    body: { 1: '(Имя, field://appointment.client_name)' },
                  },
                },
                target_inbox_id: 3,
                relative_anchor: 'touch.created_at',
                relative_offset_seconds: 0,
              },
            ],
          },
        ],
      }),
    ];
    fetchAppointmentFieldFill.mockResolvedValue([
      { field_id: 'appointment.client_name', blocking: true, share: 0.3 },
    ]);
    const wrapper = await mountPage();
    await wrapper
      .find(
        '[data-testid="reminder-preset-card-appointment_created"] input[type="checkbox"]'
      )
      .trigger('change');
    await flushPromises();
    expect(AutomationAPI.update).not.toHaveBeenCalled();
    expect(mocks.alert).toHaveBeenCalled();
  });

  it('leaves the switch off when activation fails', async () => {
    mocks.rules = [rule({ active: false })];
    AutomationAPI.update.mockRejectedValue(new Error('network'));
    const wrapper = await mountPage();
    const toggle = wrapper.find(
      '[data-testid="reminder-preset-card-appointment_created"] input[type="checkbox"]'
    );
    await toggle.trigger('change');
    await flushPromises();
    expect(toggle.element.checked).toBe(false);
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.NOTIFICATIONS.SAVE_ERROR'
    );
  });

  it('allows toggling rules in Другие правила directly without a review-and-adopt prompt', async () => {
    mocks.rules = [rule({ id: 2, description: '', calendar_managed: false })];
    const wrapper = await mountPage();
    expect(wrapper.find('[data-testid="adoption-review"]').exists()).toBe(
      false
    );
    expect(wrapper.text()).not.toContain(
      'SCHEDULING.NOTIFICATIONS.REVIEW_ADOPT'
    );
    const otherCard = wrapper.find('[data-testid="other-rule-card-2"]');
    expect(otherCard.exists()).toBe(true);
    await otherCard.find('input[type="checkbox"]').trigger('change');
    await flushPromises();
    expect(AutomationAPI.update).toHaveBeenCalledWith(2, {
      active: true,
      calendar_managed: true,
      calendar_context: true,
    });
  });

  it('creates and enables a preset rule directly when toggled on with an APPROVED preset template', async () => {
    mocks.inboxes[0].message_templates.push({
      name: 'booking_created_notice',
      language: 'ru',
      status: 'APPROVED',
      category: 'UTILITY',
      components: [
        {
          type: 'BODY',
          text: 'Здравствуйте, {{1}}! Запись {{2}} в {{3}}, специалист {{4}}.',
        },
      ],
    });
    AutomationAPI.create.mockResolvedValue({ data: {} });
    const wrapper = await mountPage();
    const toggle = wrapper.find(
      '[data-testid="reminder-preset-card-appointment_created"] input[type="checkbox"]'
    );
    expect(toggle.attributes('disabled')).toBeUndefined();
    await toggle.trigger('change');
    await flushPromises();
    expect(AutomationAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({
        active: true,
        calendar_managed: true,
        event_name: 'appointment_created',
      })
    );
  });

  it('keeps untouched custom conditions and saves the preset marker when saved inline', async () => {
    const conditions = [
      {
        attribute_key: 'source',
        filter_operator: 'equal_to',
        values: ['manual'],
        query_operator: 'OR',
      },
      {
        attribute_key: 'custom_visit_type',
        filter_operator: 'equal_to',
        values: ['first'],
        query_operator: 'AND',
      },
      {
        attribute_key: 'status',
        filter_operator: 'equal_to',
        values: ['scheduled', 'confirmed'],
        query_operator: null,
      },
    ];
    mocks.rules = [rule({ conditions })];
    const wrapper = await mountPage();
    const card = wrapper.find(
      '[data-testid="reminder-preset-card-appointment_created"]'
    );
    await card.find('.cursor-pointer').trigger('click');
    await card.find('[data-testid="save-inline-preset-btn"]').trigger('click');
    await flushPromises();
    expect(AutomationAPI.update).toHaveBeenCalledWith(
      1,
      expect.objectContaining({
        conditions,
        active: false,
        description: '[scheduling_preset:appointment_created]',
      })
    );
  });

  it('displays, saves and clears min_minutes_before_appointment on preset and other rule cards', async () => {
    mocks.rules = [
      rule({ id: 1, min_minutes_before_appointment: 60 }),
      rule({
        id: 58,
        name: 'Вы записаны (Intermedical)',
        description: '',
        min_minutes_before_appointment: 60,
      }),
    ];
    const wrapper = await mountPage();

    const presetCard = wrapper.find(
      '[data-testid="reminder-preset-card-appointment_created"]'
    );
    expect(
      presetCard
        .find('[data-testid="preset-min-minutes-badge"]')
        .attributes('data-min-minutes')
    ).toBe('60');

    await presetCard.find('.cursor-pointer').trigger('click');
    const presetInput = presetCard.find(
      '[data-testid="preset-min-minutes-input"]'
    );
    expect(presetInput.element.value).toBe('60');
    await presetInput.setValue('90');
    await presetCard
      .find('[data-testid="save-inline-preset-btn"]')
      .trigger('click');
    await flushPromises();
    expect(AutomationAPI.update).toHaveBeenCalledWith(
      1,
      expect.objectContaining({ min_minutes_before_appointment: 90 })
    );

    const otherCard = wrapper.find('[data-testid="other-rule-card-58"]');
    expect(
      otherCard
        .find('[data-testid="other-rule-min-minutes-badge"]')
        .attributes('data-min-minutes')
    ).toBe('60');
    const otherInput = otherCard.find(
      '[data-testid="other-rule-min-minutes-input"]'
    );
    await otherInput.setValue('');
    await otherCard
      .find('[data-testid="save-other-rule-min-minutes-btn"]')
      .trigger('click');
    await flushPromises();
    expect(AutomationAPI.update).toHaveBeenCalledWith(58, {
      min_minutes_before_appointment: null,
      calendar_context: true,
    });
  });

  it('rejects non-positive min_minutes_before_appointment input with a validation alert', async () => {
    mocks.rules = [rule({ id: 1 })];
    const wrapper = await mountPage();
    const presetCard = wrapper.find(
      '[data-testid="reminder-preset-card-appointment_created"]'
    );
    await presetCard.find('.cursor-pointer').trigger('click');
    await presetCard
      .find('[data-testid="preset-min-minutes-input"]')
      .setValue('0');
    await presetCard
      .find('[data-testid="save-inline-preset-btn"]')
      .trigger('click');
    await flushPromises();

    expect(AutomationAPI.update).not.toHaveBeenCalled();
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.NOTIFICATIONS.MIN_MINUTES_BEFORE_INVALID'
    );
  });

  it('updates min_minutes_before_appointment on custom calendar_managed=false rules without forcing calendar_managed and hides it on cancellation rules', async () => {
    mocks.rules = [
      rule({
        id: 58,
        name: 'Custom booking rule',
        description: '',
        calendar_managed: false,
        event_name: 'appointment_created',
      }),
      rule({
        id: 59,
        name: 'Custom cancellation rule',
        description: '',
        calendar_managed: false,
        event_name: 'appointment_cancelled',
        min_minutes_before_appointment: 60,
      }),
    ];
    const wrapper = await mountPage();

    const customBookingCard = wrapper.find(
      '[data-testid="other-rule-card-58"]'
    );
    await customBookingCard
      .find('[data-testid="other-rule-min-minutes-input"]')
      .setValue('75');
    await customBookingCard
      .find('[data-testid="save-other-rule-min-minutes-btn"]')
      .trigger('click');
    await flushPromises();

    expect(AutomationAPI.update).toHaveBeenCalledWith(58, {
      min_minutes_before_appointment: 75,
      calendar_context: true,
    });

    const customCancelCard = wrapper.find('[data-testid="other-rule-card-59"]');
    expect(
      customCancelCard
        .find('[data-testid="other-rule-min-minutes-input"]')
        .exists()
    ).toBe(false);
  });
});
