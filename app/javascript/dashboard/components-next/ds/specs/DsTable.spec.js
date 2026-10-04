import { mount } from '@vue/test-utils';
import DsTable from '../DsTable.vue';

const columns = [
  { key: 'name', label: 'Account' },
  { key: 'calls', label: 'Calls', numeric: true },
  { key: 'state', label: 'State' },
];
const rows = [
  { id: 1, name: 'Clinic One', calls: 1840, state: 'ok' },
  { id: 2, name: 'Clinic Two', calls: 402, state: 'warn' },
];

describe('DsTable', () => {
  it('renders headers and rows with thin row lines', () => {
    const wrapper = mount(DsTable, {
      props: { columns, rows, caption: 'Accounts' },
    });

    expect(wrapper.find('caption').text()).toBe('Accounts');
    expect(wrapper.findAll('th').map(th => th.text())).toEqual([
      'Account',
      'Calls',
      'State',
    ]);
    expect(wrapper.findAll('tbody tr')).toHaveLength(2);
    const cell = wrapper.find('tbody td');
    expect(cell.classes()).toEqual(
      expect.arrayContaining(['border-b', 'border-n-weak'])
    );
  });

  it('aligns numeric columns to the end with tabular figures', () => {
    const wrapper = mount(DsTable, { props: { columns, rows } });
    const numericHeader = wrapper.findAll('th')[1];
    const numericCell = wrapper.findAll('tbody tr')[0].findAll('td')[1];

    expect(numericHeader.classes()).toContain('text-end');
    expect(numericCell.classes()).toEqual(
      expect.arrayContaining(['text-end', 'tabular-nums'])
    );
  });

  it('renders cell slots with the row and value', () => {
    const wrapper = mount(DsTable, {
      props: { columns, rows },
      slots: {
        'cell-state':
          '<template #cell-state="{ row, value }">{{ row.name }}:{{ value }}</template>',
      },
    });

    expect(wrapper.findAll('tbody tr')[1].findAll('td')[2].text()).toBe(
      'Clinic Two:warn'
    );
  });

  it('shows an empty state without rows', () => {
    const wrapper = mount(DsTable, { props: { columns, rows: [] } });

    expect(wrapper.find('tbody').exists()).toBe(false);
    expect(wrapper.find('[data-state="empty"]').text()).toContain('No data');
  });
});
