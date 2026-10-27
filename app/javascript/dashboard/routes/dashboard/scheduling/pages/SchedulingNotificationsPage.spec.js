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
  it('shows six off cards, channel, template counts and the pack wizard on first run', async () => {
    const wrapper = await mountPage();
    expect(
      wrapper.findAll('[data-testid^="reminder-preset-card-"]')
    ).toHaveLength(6);
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.FIRST_RUN');
    expect(wrapper.text()).toContain('WhatsApp Clinic');
    expect(wrapper.text()).toContain('SCHEDULING.NOTIFICATIONS.TEMPLATE_PACK');
    expect(
      wrapper.findAll('[data-testid^="reminder-preset-card-"] input:disabled')
    ).toHaveLength(6);
  });

  it('recognizes a preset by marker after its send time changes', async () => {
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

  it('previews example appointment values and a quick reply button', async () => {
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
    await wrapper
      .find('[data-testid="reminder-preset-card-appointment_created"] button')
      .trigger('click');
    await wrapper
      .findAll('button')
      .find(button => button.text() === '3. SCHEDULING.NOTIFICATIONS.STEPS.3')
      .trigger('click');
    expect(
      wrapper.find('[data-testid="calendar-notification-editor"]').text()
    ).toContain('Анна');
    expect(
      wrapper.find('[data-testid="calendar-notification-editor"]').text()
    ).toContain('Подтверждаю');
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

  it('reviews and adopts only the selected legacy rule', async () => {
    mocks.rules = [
      rule({ id: 2, description: '', calendar_managed: false }),
      rule({ id: 3, description: '', calendar_managed: false }),
    ];
    const wrapper = await mountPage();
    await wrapper
      .findAll('button')
      .find(button => button.text() === 'SCHEDULING.NOTIFICATIONS.REVIEW_ADOPT')
      .trigger('click');
    expect(wrapper.find('[data-testid="adoption-review"]').exists()).toBe(true);
    await wrapper
      .find('[data-testid="adoption-review"] button')
      .trigger('click');
    await flushPromises();
    expect(AutomationAPI.adoptCalendarNotification).toHaveBeenCalledTimes(1);
    expect(AutomationAPI.adoptCalendarNotification).toHaveBeenCalledWith(2);
  });

  it('keeps untouched custom conditions and saves the preset marker when switched off', async () => {
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
    await wrapper
      .find('[data-testid="reminder-preset-card-appointment_created"] button')
      .trigger('click');
    await wrapper
      .findAll('button')
      .find(button => button.text() === '4. SCHEDULING.NOTIFICATIONS.STEPS.4')
      .trigger('click');
    await wrapper
      .findAll('button')
      .find(button => button.text() === 'SCHEDULING.NOTIFICATIONS.SAVE_OFF')
      .trigger('click');
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

  it('blocks saving a condition with an empty value', async () => {
    const wrapper = await mountPage();
    await wrapper
      .find('[data-testid="reminder-preset-card-appointment_created"] button')
      .trigger('click');
    await wrapper
      .findAll('button')
      .find(button => button.text() === '2. SCHEDULING.NOTIFICATIONS.STEPS.2')
      .trigger('click');
    await wrapper
      .findAll('button')
      .find(
        button => button.text() === 'SCHEDULING.NOTIFICATIONS.ADD_CONDITION'
      )
      .trigger('click');
    await wrapper
      .findAll('button')
      .find(button => button.text() === '3. SCHEDULING.NOTIFICATIONS.STEPS.3')
      .trigger('click');
    await wrapper
      .find('[data-testid="calendar-notification-editor"]')
      .findAll('select')[2]
      .setValue('visit_notice::ru');
    await wrapper
      .findAll('button')
      .find(button => button.text() === '4. SCHEDULING.NOTIFICATIONS.STEPS.4')
      .trigger('click');
    await wrapper
      .findAll('button')
      .find(button => button.text() === 'SCHEDULING.NOTIFICATIONS.SAVE_OFF')
      .trigger('click');
    expect(AutomationAPI.create).not.toHaveBeenCalled();
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.NOTIFICATIONS.REQUIRED'
    );
  });

  it('requires an exact clock time for day-based sends', async () => {
    const wrapper = await mountPage();
    await wrapper
      .find(
        '[data-testid="reminder-preset-card-appointment_day_before"] button'
      )
      .trigger('click');
    await wrapper
      .find('[data-testid="calendar-notification-editor"] input[type="time"]')
      .setValue('');
    await wrapper
      .findAll('button')
      .find(button => button.text() === '4. SCHEDULING.NOTIFICATIONS.STEPS.4')
      .trigger('click');
    await wrapper
      .findAll('button')
      .find(button => button.text() === 'SCHEDULING.NOTIFICATIONS.SAVE_OFF')
      .trigger('click');
    expect(AutomationAPI.create).not.toHaveBeenCalled();
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.NOTIFICATIONS.REQUIRED'
    );
  });

  it('saves ИЛИ between condition rows', async () => {
    mocks.rules = [
      rule({
        conditions: [
          {
            attribute_key: 'source',
            filter_operator: 'equal_to',
            values: ['manual'],
            query_operator: 'AND',
          },
          {
            attribute_key: 'status',
            filter_operator: 'equal_to',
            values: ['scheduled'],
            query_operator: null,
          },
        ],
      }),
    ];
    const wrapper = await mountPage();
    await wrapper
      .find('[data-testid="reminder-preset-card-appointment_created"] button')
      .trigger('click');
    await wrapper
      .findAll('button')
      .find(button => button.text() === '2. SCHEDULING.NOTIFICATIONS.STEPS.2')
      .trigger('click');
    await wrapper
      .find(
        '[data-testid="calendar-notification-editor"] select[class*="ml-2"]'
      )
      .setValue('OR');
    await wrapper
      .findAll('button')
      .find(button => button.text() === '4. SCHEDULING.NOTIFICATIONS.STEPS.4')
      .trigger('click');
    await wrapper
      .findAll('button')
      .find(button => button.text() === 'SCHEDULING.NOTIFICATIONS.SAVE_OFF')
      .trigger('click');
    await flushPromises();
    expect(AutomationAPI.update).toHaveBeenCalledWith(
      1,
      expect.objectContaining({
        conditions: expect.arrayContaining([
          expect.objectContaining({
            attribute_key: 'source',
            query_operator: 'OR',
          }),
        ]),
      })
    );
  });
});
