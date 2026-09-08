import { shallowMount } from '@vue/test-utils';
import { ref } from 'vue';
import { describe, expect, it, vi } from 'vitest';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: ref('en'),
    t: key => key,
  }),
}));

import CrmDealBoard from './CrmDealBoard.vue';

const stages = [
  { color: '#2563eb', id: 1, name: 'New', pipelineId: 10 },
  { color: '#16a34a', id: 2, name: 'Won', pipelineId: 10 },
];

const mountBoard = (props = {}, stubs = {}) =>
  shallowMount(CrmDealBoard, {
    props: {
      hasMore: false,
      stages,
      ...props,
    },
    global: {
      stubs: {
        Draggable: true,
        ...stubs,
      },
    },
  });

describe('CrmDealBoard', () => {
  it('keeps every stage column stretched under a sticky header', () => {
    const wrapper = mountBoard();
    const columns = wrapper.findAll('.crm-deal-board-column');
    const headers = wrapper.findAll('header');

    expect(columns).toHaveLength(2);
    expect(
      columns.every(column => column.classes().includes('self-stretch'))
    ).toBe(true);
    expect(headers).toHaveLength(2);
    expect(headers.every(header => header.classes().includes('sticky'))).toBe(
      true
    );
    expect(
      columns.every(column => column.classes().includes('w-[18rem]'))
    ).toBe(true);
    expect(wrapper.findAll('.crm-deal-board-stage-color')).toHaveLength(2);
  });

  it('does not render quick-create buttons above stages', () => {
    const wrapper = mountBoard({ canManage: true });

    expect(wrapper.find('.crm-deal-board-add-button').exists()).toBe(false);
  });

  it('exposes a native button for opening a deal with the keyboard', async () => {
    const wrapper = mountBoard(
      {
        deals: [{ id: 1, stageId: 1, title: 'First deal' }],
      },
      {
        Draggable: {
          props: ['list'],
          template:
            '<div><slot v-for="element in list" name="item" :element="element" /></div>',
        },
      }
    );

    const openButton = wrapper.find('[data-test="open-deal"]');
    expect(openButton.element.tagName).toBe('BUTTON');

    await openButton.trigger('click');

    expect(wrapper.emitted('selectDeal')).toEqual([
      [{ id: 1, stageId: 1, title: 'First deal' }],
    ]);
  });

  it('truncates long company names and renders the owner as read-only text', () => {
    const wrapper = mountBoard(
      {
        deals: [
          {
            id: 1,
            ownerId: 7,
            primaryContact: {
              name: 'A company name that is much wider than the card',
            },
            stageId: 1,
            title: 'First deal',
          },
        ],
        owners: [{ label: 'Alex Owner', value: 7 }],
      },
      {
        Draggable: {
          props: ['list'],
          template:
            '<div><slot v-for="element in list" name="item" :element="element" /></div>',
        },
      }
    );

    const openButton = wrapper.find('[data-test="open-deal"]');
    const company = openButton.find('p');

    expect(openButton.classes()).toContain('overflow-hidden');
    expect(company.classes()).toContain('truncate');
    expect(company.text()).toContain('A company name');
    expect(wrapper.text()).toContain('Alex Owner');
    expect(wrapper.emitted('changeOwner')).toBeUndefined();
  });

  it('renders the canonical next action returned by the deal API', () => {
    const wrapper = mountBoard(
      {
        deals: [
          {
            id: 1,
            nextAction: {
              kind: 'task',
              state: 'overdue',
              task: { title: 'Call customer' },
            },
            stageId: 1,
            title: 'First deal',
          },
        ],
      },
      {
        Draggable: {
          props: ['list'],
          template:
            '<div><slot v-for="element in list" name="item" :element="element" /></div>',
        },
      }
    );

    expect(wrapper.text()).toContain('CRM.DEALS.NEXT_ACTION.OVERDUE');
  });

  it('loads the next page near the vertical scroll boundary without a button', async () => {
    const wrapper = mountBoard({ hasMore: true });
    const scrollContainer = wrapper.element;

    Object.defineProperties(scrollContainer, {
      clientHeight: { configurable: true, value: 500 },
      scrollHeight: { configurable: true, value: 1000 },
      scrollTop: { configurable: true, value: 250 },
    });

    await wrapper.trigger('scroll');

    expect(wrapper.emitted('loadMore')).toHaveLength(1);
    expect(wrapper.find('button').exists()).toBe(false);
  });

  it('does not request another page while a page is loading', async () => {
    const wrapper = mountBoard({ hasMore: true, isLoadingMore: true });
    const scrollContainer = wrapper.element;

    Object.defineProperties(scrollContainer, {
      clientHeight: { configurable: true, value: 500 },
      scrollHeight: { configurable: true, value: 1000 },
      scrollTop: { configurable: true, value: 250 },
    });

    await wrapper.trigger('scroll');

    expect(wrapper.emitted('loadMore')).toBeUndefined();
  });

  it('does not load another page during horizontal-only scrolling', async () => {
    const wrapper = mountBoard({ hasMore: true });
    const scrollContainer = wrapper.element;

    Object.defineProperties(scrollContainer, {
      clientHeight: { configurable: true, value: 500 },
      scrollHeight: { configurable: true, value: 700 },
      scrollTop: { configurable: true, value: 0 },
    });

    await wrapper.trigger('scroll');

    expect(wrapper.emitted('loadMore')).toBeUndefined();
  });

  it('loads another page when the initial cards do not overflow vertically', async () => {
    const wrapper = mountBoard({
      deals: [{ id: 1, stageId: 1, title: 'First deal' }],
      hasMore: true,
    });
    const scrollContainer = wrapper.element;

    Object.defineProperties(scrollContainer, {
      clientHeight: { configurable: true, value: 800 },
      scrollHeight: { configurable: true, value: 600 },
    });

    await wrapper.vm.$nextTick();

    expect(wrapper.emitted('loadMore')).toHaveLength(1);

    await wrapper.setProps({
      deals: [{ id: 2, stageId: 1, title: 'Replacement deal' }],
    });
    await wrapper.vm.$nextTick();

    expect(wrapper.emitted('loadMore')).toHaveLength(2);
  });

  it('shows a manual retry after an automatic load failure without retrying in a loop', async () => {
    const wrapper = mountBoard({
      deals: [{ id: 1, stageId: 1, title: 'First deal' }],
      hasMore: true,
      loadMoreFailed: true,
    });
    const scrollContainer = wrapper.element;

    Object.defineProperties(scrollContainer, {
      clientHeight: { configurable: true, value: 800 },
      scrollHeight: { configurable: true, value: 600 },
    });
    await wrapper.vm.$nextTick();

    expect(wrapper.emitted('loadMore')).toBeUndefined();

    const retryButton = wrapper.find('button');
    expect(retryButton.text()).toBe('Retry loading');
    await retryButton.trigger('click');

    expect(wrapper.emitted('loadMore')).toHaveLength(1);
  });
});
