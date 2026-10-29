import { mount, flushPromises } from '@vue/test-utils';
import KaspiPayModal from './KaspiPayModal.vue';
import KaspiPayAPI from 'dashboard/api/integrations/kaspiPay';

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/api/integrations/kaspiPay', () => ({
  default: {
    createPayment: vi.fn(),
    getPayment: vi.fn(),
    refreshPayment: vi.fn(),
  },
}));

const DialogStub = {
  template:
    '<div><slot /><button data-test="dialog-confirm" @click="$emit(\'confirm\')">ok</button></div>',
  methods: {
    open: vi.fn(),
    close: vi.fn(),
  },
};

const InputStub = {
  props: ['modelValue'],
  emits: ['update:modelValue'],
  template:
    '<input :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
};

describe('KaspiPayModal.vue', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  const mountModal = (props = {}) =>
    mount(KaspiPayModal, {
      props: {
        conversationId: 12,
        contactId: 7,
        defaultPhone: '+77015556677',
        ...props,
      },
      global: {
        mocks: { $t: key => key },
        stubs: {
          Dialog: DialogStub,
          Input: InputStub,
          Button: { template: '<button><slot /></button>' },
          Switch: {
            props: ['modelValue'],
            template: '<input type="checkbox" :checked="modelValue" />',
          },
        },
      },
    });

  it('creates a QR payment and renders a scannable Unified QR image', async () => {
    KaspiPayAPI.createPayment.mockResolvedValue({
      data: {
        id: 101,
        payment_type: 'qr',
        status: 'pending',
        amount: 15000,
        pay_url: 'https://pay.kaspi.kz/pay/12345',
        unified_qr_url: 'https://qr.kaspi.kz/12345',
      },
    });

    const wrapper = mountModal();
    wrapper.vm.open();
    await flushPromises();

    await wrapper.find('[data-test="kaspi-amount-input"]').setValue('15000');
    await wrapper.find('[data-test="dialog-confirm"]').trigger('click');
    await flushPromises();

    expect(KaspiPayAPI.createPayment).toHaveBeenCalledWith(
      expect.objectContaining({
        payment_type: 'qr',
        amount: 15000,
        conversation_id: 12,
        send_to_conversation: true,
      })
    );
    expect(wrapper.find('[data-test="kaspi-qr-image"]').exists()).toBe(true);
    expect(
      wrapper.find('[data-test="kaspi-qr-image"]').attributes('src')
    ).toContain('data:image/svg+xml;utf8,');
    wrapper.unmount();
  });

  it('creates a remote phone invoice when switched to invoice mode', async () => {
    KaspiPayAPI.createPayment.mockResolvedValue({
      data: {
        id: 102,
        payment_type: 'invoice',
        status: 'pending',
        amount: 8500,
      },
    });

    const wrapper = mountModal();
    wrapper.vm.open({ paymentType: 'invoice' });
    await flushPromises();

    await wrapper.find('[data-test="kaspi-amount-input"]').setValue('8500');
    await wrapper.find('[data-test="dialog-confirm"]').trigger('click');
    await flushPromises();

    expect(KaspiPayAPI.createPayment).toHaveBeenCalledWith(
      expect.objectContaining({
        payment_type: 'invoice',
        amount: 8500,
        payer_phone: '+77015556677',
      })
    );
    wrapper.unmount();
  });
});
