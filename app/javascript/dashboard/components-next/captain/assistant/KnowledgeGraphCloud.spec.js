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

  const sampleDoctors = [
    {
      id: 11,
      name: 'Ахметов Серик Болатович',
      specialty: 'Кардиолог',
      slot_duration_min: 30,
      active: true,
    },
  ];

  const sampleServices = [
    {
      id: 21,
      name: 'ЭКГ с расшифровкой',
      category: 'Кардиология',
      base_price: 5500,
      duration_min: 20,
      active: true,
      prices: [],
    },
  ];

  const sampleServiceStats = [
    {
      id: 301,
      resource_id: 11,
      service_id: 21,
      receptions_count: 42,
      median_duration_min: 20,
      status: 'confirmed',
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

  it('renders doctors, services, and doctor-service links in the graph', async () => {
    const wrapper = mount(KnowledgeGraphCloud, {
      props: {
        responses: sampleResponses,
        doctors: sampleDoctors,
        services: sampleServices,
        serviceStats: sampleServiceStats,
      },
    });

    const nodes = wrapper.findAll('[data-testid="knowledge-graph-node"]');
    expect(nodes).toHaveLength(4);
    expect(wrapper.text()).toContain('Ахметов Серик Болатович');
    expect(wrapper.text()).toContain('ЭКГ с расшифровкой');
    expect(
      wrapper.find('[data-testid="knowledge-clinic-links-chip"]').exists()
    ).toBe(true);
  });
});
