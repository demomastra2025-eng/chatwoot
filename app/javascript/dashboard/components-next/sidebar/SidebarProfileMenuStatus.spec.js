import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import SidebarProfileMenuStatus from './SidebarProfileMenuStatus.vue';

const storeDispatch = vi.fn();
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: storeDispatch }),
  useMapGetter: getter => {
    const values = {
      getCurrentUserAvailability: 'online',
      getCurrentAccountId: 1,
      getCurrentUserAutoOffline: false,
    };
    return ref(values[getter]);
  },
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useImpersonation', () => ({
  useImpersonation: () => ({ isImpersonating: ref(false) }),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const mountComponent = () =>
  mount(SidebarProfileMenuStatus, {
    global: {
      mocks: { $t: key => key },
      stubs: {
        DropdownSection: { template: '<section><slot /></section>' },
        DropdownContainer: {
          template:
            '<div><slot name="trigger" :toggle="() => {}" /><slot /></div>',
        },
        DropdownBody: { template: '<div><slot /></div>' },
        DropdownItem: { template: '<div><slot /></div>' },
        Button: { template: '<button><slot /></button>' },
        Icon: true,
        ToggleSwitch: { template: '<button />' },
      },
    },
  });

describe('SidebarProfileMenuStatus', () => {
  it('keeps availability settings in the profile without hiding telephony status there', () => {
    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('SIDEBAR.SET_YOUR_AVAILABILITY');
    expect(wrapper.text()).toContain('SIDEBAR.SET_AUTO_OFFLINE.TEXT');
    expect(wrapper.find('[data-testid="sip-telephony-status"]').exists()).toBe(
      false
    );
  });
});
