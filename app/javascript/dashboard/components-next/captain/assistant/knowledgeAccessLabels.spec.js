import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import DocumentCard from './DocumentCard.vue';
import ResponseCard from './ResponseCard.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, values) => (values ? `${key} ${JSON.stringify(values)}` : key),
  }),
}));
vi.mock('dashboard/composables/usePolicy', () => ({
  usePolicy: () => ({ checkPermissions: () => true }),
}));
vi.mock('shared/helpers/timeHelper', () => ({ dynamicTime: () => 'today' }));

const mountCard = (component, props) =>
  mount(component, {
    props: { id: 1, createdAt: 1700000000, showMenu: false, ...props },
    global: {
      directives: { 'on-clickaway': {} },
      stubs: {
        CardLayout: { template: '<div><slot /></div>' },
        Checkbox: true,
        DropdownMenu: true,
        Button: true,
        Icon: true,
        Policy: { template: '<div><slot /></div>' },
      },
    },
  });

describe('knowledge access labels', () => {
  const cards = [
    {
      name: 'document',
      component: DocumentCard,
      props: { name: 'Manual', externalLink: 'https://example.com/manual' },
    },
    {
      name: 'answer',
      component: ResponseCard,
      props: { question: 'Question', answer: 'Answer', updatedAt: 1700000000 },
    },
  ];

  it.each(cards)('labels a legacy owned $name as selected access', card => {
    const wrapper = mountCard(card.component, {
      ...card.props,
      visibility: 'personal',
      assistant: { id: 2, name: 'Sales' },
      allowedAssistantIds: [2],
      restrictedToAssistants: false,
    });

    expect(wrapper.text()).toContain(
      'CAPTAIN.KNOWLEDGE_VISIBILITY.OPTIONS.PERSONAL'
    );
    expect(wrapper.text()).not.toContain(
      'CAPTAIN.KNOWLEDGE_VISIBILITY.OPTIONS.GENERAL'
    );
    expect(wrapper.text()).toContain(
      'CAPTAIN.KNOWLEDGE_VISIBILITY.ASSISTANT_BADGE {"name":"Sales"}'
    );
  });

  it.each(cards)('labels an explicitly shared $name as shared access', card => {
    const wrapper = mountCard(card.component, {
      ...card.props,
      visibility: 'general',
      assistant: { id: 2, name: 'Sales' },
      allowedAssistantIds: [],
      restrictedToAssistants: false,
    });

    expect(wrapper.text()).toContain(
      'CAPTAIN.KNOWLEDGE_VISIBILITY.OPTIONS.GENERAL'
    );
    expect(wrapper.text()).not.toContain(
      'CAPTAIN.KNOWLEDGE_VISIBILITY.OPTIONS.PERSONAL'
    );
    expect(wrapper.text()).not.toContain(
      'CAPTAIN.KNOWLEDGE_VISIBILITY.ASSISTANT_BADGE'
    );
  });

  it('shows inherited source access and the effective agents rather than a different legacy owner', () => {
    const wrapper = mountCard(ResponseCard, {
      question: 'Question',
      answer: 'Answer',
      updatedAt: 1700000000,
      visibility: 'general',
      assistant: { id: 2, name: 'Sales' },
      documentable: { id: 12, type: 'Captain::Document', name: 'Manual' },
      allowedAssistantIds: [4],
      restrictedToAssistants: false,
    });

    expect(wrapper.text()).toContain(
      'CAPTAIN.KNOWLEDGE_VISIBILITY.OPTIONS.PERSONAL'
    );
    expect(wrapper.text()).toContain(
      'CAPTAIN.KNOWLEDGE_VISIBILITY.AGENT_COUNT {"count":1}'
    );
    expect(wrapper.text()).not.toContain(
      'CAPTAIN.KNOWLEDGE_VISIBILITY.OPTIONS.GENERAL'
    );
    expect(wrapper.text()).not.toContain('Sales');
  });
});
