import { flushPromises, mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';
import { createMemoryHistory, createRouter } from 'vue-router';
import CrmConversationLink from './CrmConversationLink.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (_key, { id } = {}) =>
      id ? `Conversation #${id}` : 'Linked conversation',
  }),
}));

const mountLink = async (props = {}) => {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      {
        path: '/app/accounts/:accountId/tasks',
        component: { template: '<div />' },
      },
      {
        path: '/app/accounts/:accountId/conversations/:conversation_id',
        name: 'inbox_conversation',
        component: { template: '<div />' },
      },
    ],
  });
  await router.push('/app/accounts/74/tasks');
  const wrapper = mount(CrmConversationLink, {
    props: { accountId: 74, displayId: 12, ...props },
    global: { plugins: [router] },
  });
  return { wrapper, router };
};

describe('CRM conversation navigation', () => {
  it('navigates in-app with the account and display ID, never the database ID', async () => {
    const { wrapper, router } = await mountLink();
    const button = wrapper.get('button');
    expect(button.attributes('type')).toBe('button');
    expect(button.attributes('disabled')).toBeUndefined();
    expect(button.text()).toBe('Conversation #12');
    await button.trigger('click');
    await flushPromises();
    expect(router.currentRoute.value.fullPath).toBe(
      '/app/accounts/74/conversations/12'
    );
  });

  it.each([null, '', 0, -1, 'missing', 'https://example.com', 1.2])(
    'keeps text without navigation when display ID is %s',
    async displayId => {
      const { wrapper, router } = await mountLink({ displayId });
      expect(wrapper.find('button').exists()).toBe(false);
      expect(wrapper.find('a').exists()).toBe(false);
      expect(router.currentRoute.value.fullPath).toBe('/app/accounts/74/tasks');
    }
  );

  it('does not link a reference from another account', async () => {
    const { wrapper } = await mountLink({ accountId: 75 });
    expect(wrapper.find('button').exists()).toBe(false);
    expect(wrapper.text()).toBe('Conversation #12');
  });

  it('removes the action when its association is no longer present', async () => {
    const { wrapper } = await mountLink();
    await wrapper.setProps({ displayId: null });
    expect(wrapper.find('button').exists()).toBe(false);
    expect(wrapper.text()).toBe('Linked conversation');
  });
});
