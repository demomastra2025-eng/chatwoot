import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { mount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import { createI18n } from 'vue-i18n';
import ruScheduling from 'dashboard/i18n/locale/ru/scheduling.json';
import kkScheduling from 'dashboard/i18n/locale/kk/scheduling.json';
import enScheduling from 'dashboard/i18n/locale/en/scheduling.json';
import SchedulingRemindersPage from './SchedulingRemindersPage.vue';
import AppointmentTemplatePackDialog from 'dashboard/components-next/Scheduling/AppointmentTemplatePackDialog.vue';

const mockAlert = vi.fn();
vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => mockAlert(...args),
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    currentAccount: { value: { id: 1, name: 'Universal Studio' } },
  }),
}));

const createTestI18n = (locale = 'ru') =>
  createI18n({
    legacy: false,
    locale,
    messages: {
      ru: {
        ...ruScheduling,
        DIALOG: {
          BUTTONS: {
            CANCEL: 'Отмена',
            CONFIRM: 'Подтвердить',
            CLOSE: 'Закрыть',
          },
        },
      },
      kk: {
        ...kkScheduling,
        DIALOG: {
          BUTTONS: {
            CANCEL: 'Бас тарту',
            CONFIRM: 'Растау',
            CLOSE: 'Жабу',
          },
        },
      },
      en: {
        ...enScheduling,
        DIALOG: {
          BUTTONS: {
            CANCEL: 'Cancel',
            CONFIRM: 'Confirm',
            CLOSE: 'Close',
          },
        },
      },
    },
  });

describe('SchedulingRemindersPage', () => {
  let store;
  let wrapper;
  let inboxTemplates;
  let createAutomationAction;
  let updateAutomationAction;
  let getAutomationsAction;
  let createWhatsAppTemplateAction;

  beforeEach(() => {
    mockAlert.mockReset();

    if (typeof HTMLDialogElement !== 'undefined') {
      HTMLDialogElement.prototype.showModal =
        HTMLDialogElement.prototype.showModal ||
        function showModalPolyfill() {
          this.open = true;
          this.setAttribute('open', '');
        };
      HTMLDialogElement.prototype.close =
        HTMLDialogElement.prototype.close ||
        function closePolyfill() {
          this.open = false;
          this.removeAttribute('open');
        };
    }

    inboxTemplates = [
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

    createAutomationAction = vi.fn().mockResolvedValue({});
    updateAutomationAction = vi.fn().mockResolvedValue({});
    getAutomationsAction = vi.fn().mockResolvedValue([]);
    createWhatsAppTemplateAction = vi
      .fn()
      .mockImplementation(async (_ctx, { template }) => {
        const created = {
          name: template.name,
          language: template.language || 'ru',
          category: template.category || 'UTILITY',
          status: 'PENDING',
          components: [
            {
              type: 'BODY',
              text: template.body_text,
            },
          ],
        };
        inboxTemplates.push(created);
        return created;
      });

    store = createStore({
      modules: {
        accounts: {
          namespaced: true,
          getters: {
            isRTL: () => false,
          },
        },
        inboxes: {
          namespaced: true,
          getters: {
            getInboxes: () => [
              {
                id: 42,
                name: 'Main WhatsApp Cloud',
                channel_type: 'Channel::Whatsapp',
                provider: 'whatsapp_cloud',
                message_templates: inboxTemplates,
              },
            ],
            getAllInboxes: () => [],
          },
          actions: {
            get: vi.fn().mockResolvedValue([]),
            syncTemplates: vi.fn().mockResolvedValue({}),
            createWhatsAppTemplate: createWhatsAppTemplateAction,
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

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    document.body.innerHTML = '';
  });

  const mountPage = ({ locale = 'ru', stubPackDialog = true } = {}) => {
    wrapper = mount(SchedulingRemindersPage, {
      global: {
        plugins: [store, createTestI18n(locale)],
        stubs: {
          SchedulingPageHeader: {
            props: ['title', 'subtitle'],
            template: '<div><h1>{{ title }}</h1><slot name="actions" /></div>',
          },
          ...(stubPackDialog
            ? {
                AppointmentTemplatePackDialog: {
                  template: '<div data-testid="pack-dialog-stub" />',
                },
              }
            : {}),
          CreateWhatsAppTemplateDialog: {
            template: '<div data-testid="create-dialog-stub" />',
          },
        },
      },
    });
    return wrapper;
  };

  it('renders all 6 universal appointment reminder scenario cards', async () => {
    mountPage();
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
    mountPage();
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

  it.each(['ru', 'kk', 'en'])(
    'opens AppointmentTemplatePackDialog without vue-i18n nested placeholder errors in %s locale and submits missing templates',
    async locale => {
      mountPage({ locale, stubPackDialog: false });
      await flushPromises();

      const openBtn = wrapper.find('[data-testid="open-template-pack-btn"]');
      expect(openBtn.exists()).toBe(true);
      await openBtn.trigger('click');
      await flushPromises();

      const dialogComponent = wrapper.findComponent(
        AppointmentTemplatePackDialog
      );
      expect(dialogComponent.exists()).toBe(true);
      expect(document.body.innerHTML).toContain('{{имя клиента}}');

      const submitBtn = document.body.querySelector(
        '[data-testid="submit-template-pack-btn"]'
      );
      expect(submitBtn).not.toBeNull();
      submitBtn.click();
      await flushPromises();

      // 5 new templates created (booking_reminder_1d already existed)
      expect(createWhatsAppTemplateAction).toHaveBeenCalledTimes(5);
    }
  );
});
