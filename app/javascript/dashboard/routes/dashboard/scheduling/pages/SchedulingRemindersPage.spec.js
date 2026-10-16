import { describe, it, expect, vi, beforeEach } from 'vitest';
import { mount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import SchedulingRemindersPage from './SchedulingRemindersPage.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => {
      if (params && typeof params === 'object') {
        return `${key}:${JSON.stringify(params)}`;
      }
      return key;
    },
  }),
}));

const mockAlert = vi.fn();
vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => mockAlert(...args),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    currentAccount: { value: { id: 1, name: 'Universal Studio' } },
  }),
}));

describe('SchedulingRemindersPage', () => {
  let store;
  let createAutomationAction;
  let updateAutomationAction;
  let getAutomationsAction;

  const sampleTemplates = [
    {
      name: 'booking_reminder_1d',
      language: 'ru',
      category: 'UTILITY',
      status: 'APPROVED',
      components: [
        {
          type: 'BODY',
          text: 'Здравствуйте, {{1}}! Напоминаем о записи {{2}} в {{3}} к специалисту {{4}} ({{5}}).',
        },
        {
          type: 'BUTTONS',
          buttons: [{ type: 'QUICK_REPLY', text: 'Подтверждаю запись' }],
        },
      ],
    },
  ];

  beforeEach(() => {
    mockAlert.mockReset();
    createAutomationAction = vi.fn().mockResolvedValue({});
    updateAutomationAction = vi.fn().mockResolvedValue({});
    getAutomationsAction = vi.fn().mockResolvedValue([]);

    store = createStore({
      modules: {
        inboxes: {
          namespaced: true,
          getters: {
            getAllInboxes: () => [
              {
                id: 42,
                name: 'Main WhatsApp Cloud',
                channel_type: 'Channel::Whatsapp',
                provider: 'whatsapp_cloud',
                message_templates: sampleTemplates,
              },
            ],
          },
          actions: {
            syncTemplates: vi.fn().mockResolvedValue({}),
            createWhatsAppTemplate: vi.fn().mockResolvedValue({}),
          },
        },
        automations: {
          namespaced: true,
          getters: {
            getAutomations: () => [],
            getUIFlags: () => ({
              isFetching: false,
              isCreating: false,
              isUpdating: false,
            }),
          },
          actions: {
            get: getAutomationsAction,
            create: createAutomationAction,
            update: updateAutomationAction,
          },
        },
      },
    });
  });

  const mountPage = () =>
    mount(SchedulingRemindersPage, {
      global: {
        plugins: [store],
        stubs: {
          SchedulingPageHeader: {
            props: ['title', 'subtitle'],
            template: '<div><h1>{{ title }}</h1><slot name="actions" /></div>',
          },
          AppointmentTemplatePackDialog: {
            template: '<div data-testid="pack-dialog-stub" />',
          },
          CreateWhatsAppTemplateDialog: {
            template: '<div data-testid="create-dialog-stub" />',
          },
        },
      },
    });

  it('renders all 6 universal appointment reminder scenario cards', async () => {
    const wrapper = mountPage();
    await flushPromises();

    expect(getAutomationsAction).toHaveBeenCalled();
    expect(
      wrapper
        .find('[data-testid="reminder-preset-card-appointment_created"]')
        .exists()
    ).toBe(true);
    expect(
      wrapper
        .find('[data-testid="reminder-preset-card-appointment_rescheduled"]')
        .exists()
    ).toBe(true);
    expect(
      wrapper
        .find('[data-testid="reminder-preset-card-appointment_cancelled"]')
        .exists()
    ).toBe(true);
    expect(
      wrapper
        .find('[data-testid="reminder-preset-card-appointment_day_before"]')
        .exists()
    ).toBe(true);
    expect(
      wrapper
        .find(
          '[data-testid="reminder-preset-card-appointment_two_hours_before"]'
        )
        .exists()
    ).toBe(true);
    expect(
      wrapper
        .find('[data-testid="reminder-preset-card-appointment_review_request"]')
        .exists()
    ).toBe(true);
  });

  it('auto-binds booking_reminder_1d template and creates an AutomationRule with confirm_appointment action when toggled on', async () => {
    const wrapper = mountPage();
    await flushPromises();

    const dayBeforeCard = wrapper.find(
      '[data-testid="reminder-preset-card-appointment_day_before"]'
    );
    const toggleBtn = dayBeforeCard.find('button[role="switch"]');
    await toggleBtn.trigger('click');
    await flushPromises();

    expect(createAutomationAction).toHaveBeenCalledTimes(1);
    const payload = createAutomationAction.mock.calls[0][1];

    expect(payload.event_name).toBe('appointment_created');
    expect(payload.active).toBe(true);
    expect(payload.description).toContain(
      '[scheduling_preset:appointment_day_before]'
    );
    expect(payload.conditions).toEqual([
      {
        attribute_key: 'source',
        filter_operator: 'is_present',
        values: [],
        query_operator: null,
      },
    ]);

    const touchParams = payload.actions[0].action_params[0];
    expect(touchParams.content_kind).toBe('channel_template');
    expect(touchParams.relative_anchor).toBe('appointment.starts_at');
    expect(touchParams.relative_offset_seconds).toBe(-86400);
    expect(touchParams.relative_time_mode).toBe('fixed_time_of_day');
    expect(touchParams.relative_time_of_day).toBe('15:00');
    expect(touchParams.response_action).toBe('confirm_appointment');
    expect(touchParams.response_button_index).toBe(0);
    expect(touchParams.template_params.name).toBe('booking_reminder_1d');
    expect(touchParams.template_params.processed_params.body).toEqual({
      1: '[Имя клиента](field://appointment.client_name)',
      2: '[Дата записи](field://appointment.start_date)',
      3: '[Время записи](field://appointment.start_time)',
      4: '[Специалист](field://appointment.resource_name)',
      5: '[Услуга](field://appointment.service_name_snapshot)',
    });
  });
});
