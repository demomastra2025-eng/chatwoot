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

  it('allows editing template body, button text, inserting semantic variables, resetting, and bumping existing template name in AppointmentTemplatePackDialog', async () => {
    mountPage({ locale: 'ru', stubPackDialog: false });
    await flushPromises();

    const openBtn = wrapper.find('[data-testid="open-template-pack-btn"]');
    await openBtn.trigger('click');
    await flushPromises();

    const bodyArea = document.body.querySelector(
      '[data-testid="pack-template-body-input"] textarea'
    );
    expect(bodyArea).not.toBeNull();

    // Edit active template (appointment_created -> booking_created_notice)
    bodyArea.value =
      'Кастомный шаблон для {{имя клиента}} на {{дата записи}} в {{время записи}} к специалисту {{специалист}}.';
    bodyArea.dispatchEvent(new Event('input', { bubbles: true }));
    await flushPromises();

    // Insert semantic variable via chip click
    const chips = document.body.querySelectorAll(
      '[data-testid="pack-variable-chip"]'
    );
    expect(chips.length).toBeGreaterThan(0);
    // Find the phone chip and click it
    const phoneChip = Array.from(chips).find(el =>
      el.textContent.includes('{{телефон клиента}}')
    );
    expect(phoneChip).toBeDefined();
    phoneChip.click();
    await flushPromises();

    expect(bodyArea.value).toContain('{{телефон клиента}}');

    // Live preview renders substituted sample values
    const livePreview = document.body.querySelector(
      '[data-testid="pack-template-live-preview"]'
    );
    expect(livePreview).not.toBeNull();
    expect(livePreview.textContent).toContain('Кастомный шаблон для Анна');
    expect(livePreview.textContent).toContain('+7 701 000 00 00');

    // Reset button is shown and restores preset text when clicked
    const resetBtn = document.body.querySelector(
      '[data-testid="reset-active-template-btn"]'
    );
    expect(resetBtn).not.toBeNull();
    resetBtn.click();
    await flushPromises();
    expect(bodyArea.value).not.toContain('Кастомный шаблон');

    // Apply custom edit again to booking_created_notice
    bodyArea.value =
      'Здравствуйте, {{имя клиента}}! Ждем вас {{дата записи}} в {{время записи}} у {{специалист}}.';
    bodyArea.dispatchEvent(new Event('input', { bubbles: true }));
    await flushPromises();

    // Switch to existing template (appointment_day_before -> booking_reminder_1d)
    const dayBeforeTab = document.body.querySelector(
      '[data-testid="pack-tab-appointment_day_before"]'
    );
    expect(dayBeforeTab).not.toBeNull();
    dayBeforeTab.click();
    await flushPromises();

    // Bump existing template name so it gets created as booking_reminder_1d_v2
    const bumpBtn = document.body.querySelector(
      '[data-testid="bump-template-name-btn"]'
    );
    expect(bumpBtn).not.toBeNull();
    bumpBtn.click();
    await flushPromises();

    const nameInput = document.body.querySelector(
      '[data-testid="pack-template-name-input"] input'
    );
    expect(nameInput.value).toBe('booking_reminder_1d_v2');

    // Edit confirmation button text on booking_reminder_1d_v2
    const btnTextInput = document.body.querySelector(
      '[data-testid="pack-template-button-text-input"] input'
    );
    expect(btnTextInput).not.toBeNull();
    btnTextInput.value = 'Да, приду обязательно';
    btnTextInput.dispatchEvent(new Event('input', { bubbles: true }));
    await flushPromises();

    // Submit the pack (now all 6 templates should be created because booking_reminder_1d was bumped to v2)
    const submitBtn = document.body.querySelector(
      '[data-testid="submit-template-pack-btn"]'
    );
    submitBtn.click();
    await flushPromises();

    expect(createWhatsAppTemplateAction).toHaveBeenCalledTimes(6);

    const createdCalls = createWhatsAppTemplateAction.mock.calls.map(
      call => call[1].template
    );
    const createdNotice = createdCalls.find(
      t => t.name === 'booking_created_notice'
    );
    expect(createdNotice).toBeDefined();
    expect(createdNotice.body_text).toBe(
      'Здравствуйте, {{1}}! Ждем вас {{2}} в {{3}} у {{4}}.'
    );

    const bumpedReminder = createdCalls.find(
      t => t.name === 'booking_reminder_1d_v2'
    );
    expect(bumpedReminder).toBeDefined();
    expect(bumpedReminder.buttons[0].text).toBe('Да, приду обязательно');
  });
});
