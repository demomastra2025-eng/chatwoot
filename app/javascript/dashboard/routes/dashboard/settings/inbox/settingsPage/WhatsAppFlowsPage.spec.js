import { flushPromises, shallowMount } from '@vue/test-utils';
import WhatsAppFlowsPage from './WhatsAppFlowsPage.vue';

const { dispatch, useAlertMock, translations, uiLocale } = vi.hoisted(() => ({
  dispatch: vi.fn(),
  useAlertMock: vi.fn(),
  translations: {},
  uiLocale: { value: 'ru' },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) =>
      (translations[key] ?? key).replace(
        /\{(\w+)\}/g,
        (_match, name) => params[name] ?? ''
      ),
    locale: uiLocale,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: useAlertMock,
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
}));

const ButtonStub = {
  props: ['label', 'isLoading', 'title'],
  emits: ['click'],
  template:
    '<button :disabled="isLoading" :title="title" @click="$emit(\'click\')">{{ label }}</button>',
};

const InputStub = {
  props: ['modelValue', 'label', 'placeholder', 'type', 'size'],
  emits: ['update:modelValue'],
  template:
    '<input :type="type || \'text\'" :value="modelValue" :placeholder="placeholder" @input="$emit(\'update:modelValue\', $event.target.value)" />',
};

const DialogStub = {
  props: ['title', 'description', 'confirmButtonLabel'],
  emits: ['confirm', 'close'],
  setup(_props, { expose }) {
    expose({ open: vi.fn(), close: vi.fn() });
    return {};
  },
  template:
    '<div data-test="remove-dialog"><span>{{ title }}</span><button data-test="confirm-remove" @click="$emit(\'confirm\')">{{ confirmButtonLabel }}</button></div>',
};

const buildInbox = (flowsOverrides = {}) => ({
  id: 12,
  provider_config: {
    whatsapp_flows: {
      encryption_status: 'configured',
      booking_flow_id: 'flow_booking_1',
      flows: [
        {
          id: 'flow_booking_1',
          name: 'Онлайн-запись (RU)',
          status: 'PUBLISHED',
          categories: ['APPOINTMENT_BOOKING'],
          kind: 'booking',
        },
        {
          id: 'flow_draft_2',
          name: 'Черновик опроса',
          status: 'DRAFT',
          categories: ['SURVEY'],
          validation_errors: [{ message: 'Missing footer component' }],
        },
      ],
      ...flowsOverrides,
    },
  },
});

const mountComponent = (inboxProp = buildInbox()) =>
  shallowMount(WhatsAppFlowsPage, {
    props: { inbox: inboxProp, embedded: true },
    global: {
      stubs: {
        Button: ButtonStub,
        ComboBox: true,
        Dialog: DialogStub,
        Input: InputStub,
        SettingsFieldSection: true,
        Switch: true,
      },
    },
  });

describe('WhatsAppFlowsPage', () => {
  beforeEach(() => {
    dispatch.mockReset();
    useAlertMock.mockReset();
    uiLocale.value = 'ru';
  });

  it('displays encryption status and dispatches setupWhatsAppFlowsEncryption', async () => {
    dispatch.mockResolvedValue({});
    const wrapper = mountComponent(
      buildInbox({ encryption_status: 'not_configured', flows: [] })
    );

    expect(wrapper.find('[data-test="encryption-status-badge"]').text()).toBe(
      'INBOX_MGMT.WHATSAPP_FLOWS.ENCRYPTION.STATUS_NOT_CONFIGURED'
    );

    await wrapper
      .find('[data-test="setup-encryption-button"]')
      .trigger('click');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith(
      'inboxes/setupWhatsAppFlowsEncryption',
      { inboxId: 12, rotateKeys: false }
    );
    expect(useAlertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.WHATSAPP_FLOWS.ENCRYPTION.SETUP_SUCCESS'
    );
  });

  it('dispatches provisionWhatsAppBookingFlow with custom labels', async () => {
    dispatch.mockResolvedValue({});
    const wrapper = mountComponent();
    const bookingCard = wrapper.find(
      '[data-test="whatsapp-flows-booking-card"]'
    );
    const inputs = bookingCard.findAll('input');

    await inputs[0].setValue(' Запись в салон ');
    await inputs[1].setValue(' Подтвердить ');
    await inputs[2].setValue(' Мастер ');
    await inputs[3].setValue(' Процедура ');

    await wrapper
      .find('[data-test="provision-booking-flow-button"]')
      .trigger('click');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith(
      'inboxes/provisionWhatsAppBookingFlow',
      {
        inboxId: 12,
        whatsappFlow: {
          locale: 'ru',
          publish: true,
          name: 'Запись в салон',
          confirm_cta: 'Подтвердить',
          specialist_label: 'Мастер',
          service_label: 'Процедура',
        },
      }
    );
  });

  it('dispatches syncWhatsAppFlows and filters Flow cards by search query', async () => {
    dispatch.mockResolvedValue({});
    const wrapper = mountComponent();

    expect(wrapper.findAll('[data-test="whatsapp-flow-card"]')).toHaveLength(2);
    expect(wrapper.find('[data-test="flow-booking-badge"]').exists()).toBe(
      true
    );
    expect(
      wrapper.find('[data-test="flow-validation-errors"]').text()
    ).toContain('Missing footer component');

    await wrapper.find('[data-test="sync-flows-button"]').trigger('click');
    await flushPromises();
    expect(dispatch).toHaveBeenCalledWith('inboxes/syncWhatsAppFlows', 12);

    const searchInput = wrapper
      .find('[data-test="whatsapp-flows-toolbar"]')
      .find('input');
    await searchInput.setValue('опроса');
    expect(wrapper.findAll('[data-test="whatsapp-flow-card"]')).toHaveLength(1);
    expect(wrapper.find('[data-test="whatsapp-flow-card"]').text()).toContain(
      'Черновик опроса'
    );
  });

  it('publishes a DRAFT Flow and deletes or deprecates Flows via confirmation dialog', async () => {
    dispatch.mockResolvedValue({});
    const wrapper = mountComponent();

    const cards = wrapper.findAll('[data-test="whatsapp-flow-card"]');
    const publishedCard = cards[0];
    const draftCard = cards[1];

    expect(
      publishedCard.find('[data-test="publish-flow-button"]').exists()
    ).toBe(false);
    await draftCard.find('[data-test="publish-flow-button"]').trigger('click');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('inboxes/publishWhatsAppFlow', {
      inboxId: 12,
      flowId: 'flow_draft_2',
    });

    // Deprecate published flow
    await publishedCard
      .find('[data-test="remove-flow-button"]')
      .trigger('click');
    expect(wrapper.find('[data-test="remove-dialog"]').text()).toContain(
      'INBOX_MGMT.WHATSAPP_FLOWS.DEPRECATE_TITLE'
    );
    await wrapper.find('[data-test="confirm-remove"]').trigger('click');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith('inboxes/deleteWhatsAppFlow', {
      inboxId: 12,
      flowId: 'flow_booking_1',
    });
    expect(useAlertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.WHATSAPP_FLOWS.DEPRECATE_SUCCESS'
    );
  });

  it('shows draft warning when immediate publish falls back to DRAFT and supports key rotation', async () => {
    dispatch.mockResolvedValue({
      provider_config: {
        whatsapp_flows: {
          booking_flow_id: 'flow_unpub_1',
          flows: [
            {
              id: 'flow_unpub_1',
              name: 'Онлайн-запись',
              status: 'DRAFT',
              last_publish_error: 'Endpoint ping failed',
            },
          ],
        },
      },
    });

    const wrapper = mountComponent();
    await wrapper
      .find('[data-test="provision-booking-flow-button"]')
      .trigger('click');
    await flushPromises();

    expect(useAlertMock).toHaveBeenCalledWith(
      'INBOX_MGMT.WHATSAPP_FLOWS.BOOKING.PROVISION_DRAFT_WARNING'
    );

    await wrapper
      .find('[data-test="rotate-encryption-keys-button"]')
      .trigger('click');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith(
      'inboxes/setupWhatsAppFlowsEncryption',
      { inboxId: 12, rotateKeys: true }
    );
  });
});
