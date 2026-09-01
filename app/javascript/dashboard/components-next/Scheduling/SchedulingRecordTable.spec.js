import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import SchedulingRecordTable from './SchedulingRecordTable.vue';

const mountTable = (options = {}) =>
  mount(SchedulingRecordTable, {
    props: {
      columns: [
        { key: 'select', label: '', width: '24px' },
        {
          key: 'title',
          label: 'Deal name',
          sortable: true,
          width: '1fr',
        },
      ],
      rows: [{ id: 1, title: 'First deal' }],
    },
    global: {
      mocks: {
        $t: key => key,
      },
    },
    ...options,
  });

describe('SchedulingRecordTable', () => {
  it('renders custom header and cell slots for selection controls', () => {
    const wrapper = mountTable({
      slots: {
        'cell-select': '<input class="row-checkbox" type="checkbox" />',
        'header-select': '<input class="header-checkbox" type="checkbox" />',
      },
    });

    expect(wrapper.find('.header-checkbox').exists()).toBe(true);
    expect(wrapper.find('.row-checkbox').exists()).toBe(true);
    expect(wrapper.text()).toContain('First deal');
  });

  it('keeps column sorting available with custom header slot support', async () => {
    const wrapper = mountTable();

    await wrapper.find('button').trigger('click');

    expect(wrapper.emitted('sort')).toEqual([
      [{ direction: 'asc', key: 'title' }],
    ]);
  });
});
