import { mount, flushPromises } from '@vue/test-utils';
import KaspiPay from './KaspiPay.vue';
import KaspiPayAPI from 'dashboard/api/integrations/kaspiPay';

const mockDispatch = vi.fn();

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mockDispatch }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/api/integrations/kaspiPay', () => ({
  default: {
    getStatus: vi.fn(),
    getPayments: vi.fn(),
    sendOtp: vi.fn(),
    verifyOtp: vi.fn(),
    checkSession: vi.fn(),
    updateSettings: vi.fn(),
    disconnect: vi.fn(),
  },
}));

const InputStub = {
  props: ['modelValue'],
  emits: ['update:modelValue'],
  template:
    '<input :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
};

describe('KaspiPay.vue settings page', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  const mountPage = () =>
    mount(KaspiPay, {
      global: {
        mocks: {
          $t: key => key,
          $route: { params: { accountId: '1' } },
        },
        stubs: {
          SettingsLayout: {
            template: '<div><slot name="header" /><slot name="body" /></div>',
          },
          BaseSettingsHeader: { template: '<div />' },
          Input: InputStub,
          Switch: { template: '<input type="checkbox" />' },
          Dialog: {
            template: '<div><slot /></div>',
            methods: { open: vi.fn(), close: vi.fn() },
          },
          Button: {
            props: ['label'],
            emits: ['click'],
            template: '<button @click="$emit(\'click\')">{{ label }}</button>',
          },
        },
      },
    });

  it('completes 2-step SMS cashier onboarding and displays connected organization', async () => {
    KaspiPayAPI.getStatus.mockResolvedValue({
      data: {
        connected: false,
        session_status: 'disconnected',
        organizations: [],
      },
    });
    KaspiPayAPI.getPayments.mockResolvedValue({ data: { payload: [] } });
    KaspiPayAPI.sendOtp.mockResolvedValue({
      data: { process_id: 'proc_99', phone_masked: '+7 701 *** ** 88' },
    });
    KaspiPayAPI.verifyOtp.mockResolvedValue({
      data: {
        connected: true,
        session_status: 'active',
        organization_name: 'ТОО Клиника Улыбка',
        organization_bin: '220140055667',
        cashier_phone_masked: '+7 701 *** ** 88',
        organizations: [],
      },
    });

    const wrapper = mountPage();
    await flushPromises();

    expect(wrapper.find('[data-test="kaspi-auth-card"]').exists()).toBe(true);

    await wrapper
      .find('[data-test="kaspi-cashier-phone-input"]')
      .setValue('+7 701 444 55 88');
    await wrapper.find('[data-test="kaspi-send-otp-btn"]').trigger('click');
    await flushPromises();

    expect(KaspiPayAPI.sendOtp).toHaveBeenCalledWith(
      expect.objectContaining({ phoneNumber: '+7 701 444 55 88' })
    );

    await wrapper.find('[data-test="kaspi-otp-input"]').setValue('5511');
    await wrapper.find('[data-test="kaspi-verify-otp-btn"]').trigger('click');
    await flushPromises();

    expect(KaspiPayAPI.verifyOtp).toHaveBeenCalledWith({
      processId: 'proc_99',
      otp: '5511',
    });
    expect(mockDispatch).toHaveBeenCalledWith('integrations/get');
    expect(wrapper.find('[data-test="kaspi-connected-card"]').exists()).toBe(
      true
    );
    expect(wrapper.text()).toContain('ТОО Клиника Улыбка');
  });
});
