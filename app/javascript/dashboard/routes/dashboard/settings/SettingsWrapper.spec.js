import { h, reactive } from 'vue';
import { shallowMount } from '@vue/test-utils';
import { useRoute } from 'vue-router';
import SettingsWrapper from './SettingsWrapper.vue';

vi.mock('vue-router', () => ({ useRoute: vi.fn() }));

const RouterViewStub = {
  setup(_, { slots }) {
    return () => h('div', slots.default?.({ Component: 'span' }));
  },
};

describe('SettingsWrapper', () => {
  it('uses the route width and keeps the existing default', async () => {
    const route = reactive({ fullPath: '/settings', meta: {} });
    useRoute.mockReturnValue(route);
    const wrapper = shallowMount(SettingsWrapper, {
      props: { keepAlive: false },
      global: { stubs: { RouterView: RouterViewStub } },
    });
    const content = () => wrapper.find('.mx-auto');

    expect(content().classes()).toContain('max-w-5xl');
    route.meta.pageWidth = 'default';
    await wrapper.vm.$nextTick();
    expect(content().classes()).toContain('max-w-5xl');
    route.meta.pageWidth = 'form';
    await wrapper.vm.$nextTick();
    expect(content().classes()).toContain('max-w-3xl');
    route.meta.pageWidth = 'full';
    await wrapper.vm.$nextTick();
    expect(content().classes()).toContain('max-w-none');
    expect(wrapper.classes()).toEqual(
      expect.arrayContaining(['px-6', 'pt-4', 'pb-8'])
    );
  });
});
