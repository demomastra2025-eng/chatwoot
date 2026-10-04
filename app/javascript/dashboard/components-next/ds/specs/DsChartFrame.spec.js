import { mount } from '@vue/test-utils';
import DsChartFrame from '../DsChartFrame.vue';

const labels = ['Mon', 'Tue', 'Wed', 'Thu'];
const answered = {
  key: 'answered',
  label: 'Answered',
  values: [212, 198, 240, 225],
};
const previous = {
  key: 'previous',
  label: 'Previous',
  values: [200, 180, 210, 205],
};
const missed = { key: 'missed', label: 'Missed', values: [18, 22, 15, 20] };

const mountLine = (props = {}, options = {}) =>
  mount(DsChartFrame, {
    props: { title: 'Calls', labels, series: [answered], ...props },
    ...options,
  });

describe('DsChartFrame', () => {
  describe('line', () => {
    it('draws a 2px accent line over three hairline grid levels', () => {
      const wrapper = mountLine();
      const line = wrapper.find('[data-test-id="ds-chart-line-0"]');
      const grid = wrapper.findAll('[data-test-id="ds-chart-grid"] line');

      expect(line.attributes('stroke-width')).toBe('2');
      expect(line.classes()).toContain('stroke-n-brand');
      expect(grid).toHaveLength(3);
      grid.forEach(gridLine => {
        expect(gridLine.attributes('stroke-width')).toBe('1');
        expect(gridLine.attributes('stroke-dasharray')).toBeUndefined();
      });
    });

    it('has no legend for a single series', () => {
      const wrapper = mountLine();
      expect(wrapper.find('[data-test-id="ds-chart-legend"]').exists()).toBe(
        false
      );
    });

    it('shows a legend for two series on one axis', () => {
      const wrapper = mountLine({ series: [answered, previous] });
      const legend = wrapper.find('[data-test-id="ds-chart-legend"]');

      expect(legend.findAll('li').map(item => item.text())).toEqual([
        'Answered',
        'Previous',
      ]);
      expect(legend.attributes('aria-label')).toBe('Legend');
      expect(
        wrapper.find('[data-test-id="ds-chart-line-1"]').classes()
      ).toContain('stroke-n-slate-9');
      expect(
        wrapper.findAll('[data-test-id="ds-chart-grid"] text')
      ).toHaveLength(3);
    });

    it('puts the secondary metric in a separate panel, never a second axis', () => {
      const wrapper = mountLine({ secondary: missed });
      const main = wrapper.find('[data-test-id="ds-chart-main"]');
      const panel = wrapper.find('[data-test-id="ds-chart-secondary"]');

      expect(panel.exists()).toBe(true);
      expect(panel.text()).toContain('Missed');
      expect(panel.findAll('path')).toHaveLength(4);
      // the main plot keeps a single set of y ticks
      expect(main.findAll('[data-test-id="ds-chart-grid"] text')).toHaveLength(
        3
      );
      expect(main.findAll('path')).toHaveLength(1);
      expect(
        wrapper.findAll('[data-test-id="ds-chart-legend"] li')
      ).toHaveLength(2);
    });

    it('shows a tooltip with every series when moving by keyboard', async () => {
      const wrapper = mountLine({ secondary: missed });
      const plot = wrapper.find('[role="group"]');

      await plot.trigger('focus');
      await plot.trigger('keydown', { key: 'ArrowLeft' });

      const tooltip = wrapper.find('[data-test-id="ds-chart-tooltip"]');
      expect(tooltip.text()).toContain('Wed');
      expect(tooltip.text()).toContain('Answered');
      expect(tooltip.text()).toContain('240');
      expect(tooltip.text()).toContain('Missed');
      expect(tooltip.text()).toContain('15');
      expect(wrapper.emitted('hover')).toEqual([[3], [2]]);

      await plot.trigger('blur');
      expect(wrapper.find('[data-test-id="ds-chart-tooltip"]').exists()).toBe(
        false
      );
    });

    it('exposes the tooltip through a scoped slot', async () => {
      const wrapper = mountLine(
        {},
        {
          slots: {
            tooltip:
              '<template #tooltip="{ label, rows }">{{ label }}={{ rows[0].value }}</template>',
          },
        }
      );

      await wrapper.find('[role="group"]').trigger('focus');
      expect(wrapper.find('[data-test-id="ds-chart-tooltip"]').text()).toBe(
        'Thu=225'
      );
    });

    it('switches to a table view of the same data', async () => {
      const wrapper = mountLine({ secondary: missed, categoryLabel: 'Day' });
      const toggle = wrapper.find('[data-test-id="ds-chart-table-toggle"]');

      expect(toggle.text()).toBe('Show as table');
      await toggle.trigger('click');

      const table = wrapper.find('[data-test-id="ds-chart-table"]');
      expect(table.findAll('th').map(th => th.text())).toEqual([
        'Day',
        'Answered',
        'Missed',
      ]);
      expect(table.findAll('tbody tr')).toHaveLength(4);
      expect(table.find('tbody tr').text()).toContain('212');
      expect(wrapper.find('[data-test-id="ds-chart-main"]').exists()).toBe(
        false
      );
      expect(toggle.text()).toBe('Show as chart');
      expect(toggle.attributes('aria-pressed')).toBe('true');
    });
  });

  describe('bars', () => {
    const funnel = {
      key: 'leads',
      label: 'Clients',
      values: [420, 318, 207, 164, 121],
    };
    const stages = ['New', 'In progress', 'Booked', 'Visited', 'Paid'];

    it('uses one accent hue, the strongest step for the earliest stage', () => {
      const wrapper = mount(DsChartFrame, {
        props: { kind: 'bars', labels: stages, series: [funnel] },
      });
      const bars = wrapper.findAll('[data-test-id="ds-chart-bar"]');

      expect(
        bars.map(bar => bar.classes().find(c => c.startsWith('bg-')))
      ).toEqual([
        'bg-n-chart-1',
        'bg-n-chart-2',
        'bg-n-chart-3',
        'bg-n-chart-4',
        'bg-n-chart-5',
      ]);
      expect(bars[0].attributes('style')).toContain('width: 100%');
      expect(wrapper.text()).toContain('29%');
      expect(wrapper.find('[data-test-id="ds-chart-legend"]').exists()).toBe(
        false
      );
    });

    it('offers a table with value and share', async () => {
      const wrapper = mount(DsChartFrame, {
        props: { kind: 'bars', labels: stages, series: [funnel] },
      });

      await wrapper
        .find('[data-test-id="ds-chart-table-toggle"]')
        .trigger('click');
      const header = wrapper.findAll('[data-test-id="ds-chart-table"] th');
      expect(header.map(th => th.text())).toEqual([
        'Stage',
        'Clients',
        'Share of the first stage',
      ]);
    });
  });

  describe('states', () => {
    it('shows empty, loading and error states', async () => {
      const empty = mount(DsChartFrame, { props: { labels: [], series: [] } });
      const loading = mount(DsChartFrame, { props: { loading: true } });
      const error = mount(DsChartFrame, {
        props: { error: true, labels, series: [answered] },
      });

      expect(empty.find('[data-state="empty"]').exists()).toBe(true);
      expect(loading.find('[data-state="loading"]').exists()).toBe(true);
      expect(error.find('[data-state="error"]').exists()).toBe(true);

      await error.find('[data-state="error"] button').trigger('click');
      expect(error.emitted('retry')).toHaveLength(1);
    });

    it('keeps the previous render dimmed while refetching', () => {
      const wrapper = mountLine({ loading: true });

      expect(wrapper.find('[data-test-id="ds-chart-main"]').exists()).toBe(
        true
      );
      expect(wrapper.find('[aria-busy="true"]').classes()).toContain(
        'opacity-60'
      );
    });
  });
});
