import { ref } from 'vue';
import { mount, flushPromises } from '@vue/test-utils';
import KaspiPayPanel from './KaspiPayPanel.vue';
import KaspiPayAPI from 'dashboard/api/integrations/kaspiPay';

const mockIsAdmin = ref(false);

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: vi.fn() }),
  useMapGetter: () => ref([{ id: 'kaspi_pay', enabled: true }]),
  useFunctionGetter: () => ref({ id: 'kaspi_pay', enabled: true }),
}));

vi.mock('dashboard/composables/useAdmin', () => ({
  useAdmin: () => ({ isAdmin: mockIsAdmin }),
}));

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    isContactSidebarItemOpen: () => true,
    toggleSidebarUIState: vi.fn(),
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/api/integrations/kaspiPay', () => ({
  default: {
    getPayments: vi.fn(),
    refreshPayment: vi.fn(),
    cancelPayment: vi.fn(),
    refundPayment: vi.fn(),
  },
}));

describe('KaspiPayPanel.vue', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockIsAdmin.value = false;
  });

  const mountPanel = () =>
    mount(KaspiPayPanel, {
      props: {
        conversationId: 77,
        contact: { id: 5, phone_number: '+77019991122' },
      },
      global: {
        mocks: { $t: key => key },
        stubs: {
          AccordionItem: { template: '<div><slot /></div>' },
          KaspiPayModal: {
            template: '<div />',
            methods: { open: vi.fn() },
          },
          Dialog: {
            template: '<div><slot /></div>',
            methods: { open: vi.fn(), close: vi.fn() },
          },
          Input: { template: '<input />' },
          Button: {
            props: ['label'],
            emits: ['click'],
            template: '<button @click="$emit(\'click\')">{{ label }}</button>',
          },
        },
      },
    });

  it('hides refund action for regular agents and shows it only to administrators', async () => {
    KaspiPayAPI.getPayments.mockResolvedValue({
      data: {
        meta: { connected: true, session_status: 'active' },
        payload: [
          {
            id: 10,
            payment_type: 'qr',
            qr_operation_id: '777',
            amount: 10000,
            refundable_amount: 10000,
            status: 'paid',
          },
        ],
      },
    });

    const agentWrapper = mountPanel();
    await flushPromises();
    expect(agentWrapper.find('[data-test="kaspi-refund-btn"]').exists()).toBe(
      false
    );
    agentWrapper.unmount();

    mockIsAdmin.value = true;
    const adminWrapper = mountPanel();
    await flushPromises();
    expect(adminWrapper.find('[data-test="kaspi-refund-btn"]').exists()).toBe(
      true
    );
    adminWrapper.unmount();
  });
});
