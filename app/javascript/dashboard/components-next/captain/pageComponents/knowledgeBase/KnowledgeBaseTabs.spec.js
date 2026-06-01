import { describe, expect, it, beforeEach, vi } from 'vitest';
import { mount } from '@vue/test-utils';

const mocks = vi.hoisted(() => ({
  route: {
    name: 'captain_assistants_responses_index',
    params: {
      accountId: '530',
      assistantId: '42',
    },
  },
  push: vi.fn(),
}));

vi.mock('vue-router', () => ({
  useRoute: () => mocks.route,
  useRouter: () => ({ push: mocks.push }),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key =>
      ({
        'CAPTAIN.KNOWLEDGE_BASE.DESCRIPTION': 'Knowledge used by the AI agent.',
        'CAPTAIN.KNOWLEDGE_BASE.TABS.FAQS': 'FAQ',
        'CAPTAIN.KNOWLEDGE_BASE.TABS.DOCUMENTS': 'Documents',
      })[key] || key,
  }),
}));

vi.mock('dashboard/components-next/tabbar/TabBar.vue', () => ({
  default: {
    name: 'TabBar',
    props: {
      tabs: { type: Array, required: true },
      initialActiveTab: { type: Number, default: 0 },
    },
    emits: ['tabChanged'],
    template: `
      <div data-testid="knowledge-tabs" :data-active-tab="initialActiveTab">
        <button
          v-for="tab in tabs"
          :key="tab.key"
          type="button"
          @click="$emit('tabChanged', tab)"
        >
          {{ tab.label }}
        </button>
      </div>
    `,
  },
}));

const { default: KnowledgeBaseTabs } = await import('./KnowledgeBaseTabs.vue');

const mountComponent = () => mount(KnowledgeBaseTabs);

describe('KnowledgeBaseTabs', () => {
  beforeEach(() => {
    mocks.push.mockReset();
    mocks.route.name = 'captain_assistants_responses_index';
    mocks.route.params = {
      accountId: '530',
      assistantId: '42',
    };
  });

  it('renders knowledge base description and FAQ/Documents tabs', () => {
    const wrapper = mountComponent();

    expect(wrapper.text()).toContain('Knowledge used by the AI agent.');
    expect(wrapper.text()).toContain('FAQ');
    expect(wrapper.text()).toContain('Documents');
    expect(
      wrapper
        .find('[data-testid="knowledge-tabs"]')
        .attributes('data-active-tab')
    ).toBe('0');
  });

  it('marks Documents active on the documents route', () => {
    mocks.route.name = 'captain_assistants_documents_index';

    const wrapper = mountComponent();

    expect(
      wrapper
        .find('[data-testid="knowledge-tabs"]')
        .attributes('data-active-tab')
    ).toBe('1');
  });

  it('routes between FAQ and Documents inside the same assistant', async () => {
    const wrapper = mountComponent();

    await wrapper.findAll('button')[1].trigger('click');

    expect(mocks.push).toHaveBeenCalledWith({
      name: 'captain_assistants_documents_index',
      params: {
        accountId: '530',
        assistantId: '42',
      },
    });
  });

  it('does not route when clicking the active tab', async () => {
    const wrapper = mountComponent();

    await wrapper.findAll('button')[0].trigger('click');

    expect(mocks.push).not.toHaveBeenCalled();
  });
});
