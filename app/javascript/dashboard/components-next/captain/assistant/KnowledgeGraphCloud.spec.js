import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';
import KnowledgeGraphCloud from './KnowledgeGraphCloud.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key}:${JSON.stringify(params)}` : key),
  }),
}));

describe('KnowledgeGraphCloud', () => {
  const sampleResponses = [
    {
      id: 101,
      question: 'Сколько стоит первичный прием кардиолога?',
      answer: 'Первичный прием кардиолога стоит 12 000 тг.',
      documentable: {
        id: 7,
        type: 'Captain::Document',
        name: 'Прайс клиники.pdf',
      },
    },
    {
      id: 102,
      question: 'Как подготовиться к УЗИ брюшной полости?',
      answer: 'Исследование проводится строго натощак (6-8 часов без еды).',
      documentable: null,
    },
  ];

  it('renders graph cloud nodes and read-only inspector for selected FAQ', async () => {
    const wrapper = mount(KnowledgeGraphCloud, {
      props: { responses: sampleResponses },
    });

    const nodes = wrapper.findAll('[data-testid="knowledge-graph-node"]');
    expect(nodes).toHaveLength(2);
    expect(wrapper.text()).toContain(
      'Сколько стоит первичный прием кардиолога?'
    );
    expect(wrapper.text()).toContain(
      'Первичный прием кардиолога стоит 12 000 тг.'
    );

    await nodes[1].trigger('click');
    expect(wrapper.text()).toContain(
      'Как подготовиться к УЗИ брюшной полости?'
    );
    expect(wrapper.text()).toContain('Исследование проводится строго натощак');
  });
});
