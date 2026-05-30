import { h } from 'vue';
import { shallowMount } from '@vue/test-utils';
import { useRoute, useRouter } from 'vue-router';
import { useMapGetter } from 'dashboard/composables/store';
import SettingsTabsWrapper from './SettingsTabsWrapper.vue';

vi.mock('vue-router', () => ({
  useRoute: vi.fn(),
  useRouter: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: vi.fn(),
}));

const childComponent = { template: '<div data-test="child-view" />' };

const RouterViewStub = {
  setup(_, { slots }) {
    return () => h('div', slots.default?.({ Component: childComponent }));
  },
};

const TabBarStub = {
  props: ['tabs', 'initialActiveTab'],
  emits: ['tabChanged'],
  template: `
    <div data-test="tab-bar" :data-active="initialActiveTab">
      <button
        v-for="tab in tabs"
        :key="tab.routeName"
        :data-test="'tab-' + tab.routeName"
        @click="$emit('tabChanged', tab)"
      >
        {{ tab.label }}
      </button>
    </div>
  `,
};

const mountComponent = ({
  routeName = 'a',
  featureEnabled = () => true,
  tabs = [
    { labelKey: 'TAB.A', routeName: 'a', activeOn: ['a'] },
    { labelKey: 'TAB.B', routeName: 'b', activeOn: ['b', 'b_edit'] },
  ],
} = {}) => {
  const routerPush = vi.fn();

  useRoute.mockReturnValue({
    name: routeName,
    params: { accountId: '1', ignored: '2' },
    fullPath: `/settings/${routeName}`,
  });
  useRouter.mockReturnValue({ push: routerPush });
  useMapGetter.mockImplementation(key => {
    if (key === 'getCurrentAccountId') {
      return { value: 1 };
    }

    return { value: featureEnabled };
  });

  const wrapper = shallowMount(SettingsTabsWrapper, {
    props: { tabs, keepAlive: false },
    global: {
      stubs: {
        RouterView: RouterViewStub,
        TabBar: TabBarStub,
      },
    },
  });

  return { wrapper, routerPush };
};

describe('SettingsTabsWrapper', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('marks the tab active from nested route names and switches by account route', async () => {
    const { wrapper, routerPush } = mountComponent({ routeName: 'b_edit' });

    expect(
      wrapper.find('[data-test="tab-bar"]').attributes('data-active')
    ).toBe('1');

    await wrapper.find('[data-test="tab-a"]').trigger('click');

    expect(routerPush).toHaveBeenCalledWith({
      name: 'a',
      params: { accountId: '1' },
    });
  });

  it('hides feature-gated tabs when the account does not have the feature', () => {
    const { wrapper } = mountComponent({
      tabs: [
        { labelKey: 'TAB.A', routeName: 'a' },
        { labelKey: 'TAB.B', routeName: 'b', featureFlag: 'hidden_feature' },
      ],
      featureEnabled: (_accountId, featureFlag) =>
        featureFlag !== 'hidden_feature',
    });

    expect(wrapper.find('[data-test="tab-bar"]').exists()).toBe(false);
    expect(wrapper.find('[data-test="tab-b"]').exists()).toBe(false);
    expect(wrapper.find('[data-test="tab-a"]').exists()).toBe(false);
  });
});
