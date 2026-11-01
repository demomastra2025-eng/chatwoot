import { mount } from '@vue/test-utils';
import en from 'dashboard/i18n/locale/en/general.json';
import ru from 'dashboard/i18n/locale/ru/general.json';
import kk from 'dashboard/i18n/locale/kk/general.json';
import PaginationFooter from './pagination/PaginationFooter.vue';
import Pagination from '../components/table/Pagination.vue';
import SidebarActionsHeader from './SidebarActionsHeader.vue';
import CalendarAction from '../components/ui/DatePicker/components/CalendarAction.vue';
import Label from '../components/ui/Label.vue';

describe('shared icon action names', () => {
  it.each(['en', 'ru', 'kk'])(
    'names and preserves pagination actions in %s',
    async locale => {
      const messages = { en, ru, kk };
      const wrapper = mount(PaginationFooter, {
        props: { currentPage: 2, totalItems: 48 },
        global: {
          mocks: {
            $t: key =>
              key
                .split('.')
                .reduce((value, part) => value[part], messages[locale]),
          },
        },
      });
      const buttons = wrapper.findAll('button');
      expect(buttons.map(button => button.attributes('aria-label'))).toEqual(
        Object.values(messages[locale].GENERAL.PAGINATION)
      );
      await buttons[2].trigger('click');
      expect(wrapper.emitted('update:currentPage')).toEqual([[3]]);
      wrapper.unmount();
    }
  );

  it('keeps the four table navigation names distinct and their table API calls', async () => {
    const table = {
      getState: () => ({ pagination: { pageIndex: 1, pageSize: 10 } }),
      getPageCount: () => 4,
      getRowCount: () => 40,
      getCanPreviousPage: () => true,
      getCanNextPage: () => true,
      setPageIndex: vi.fn(),
      previousPage: vi.fn(),
      nextPage: vi.fn(),
    };
    const wrapper = mount(Pagination, { props: { table } });
    const buttons = wrapper.findAll('button[aria-label]');
    expect(buttons.map(button => button.attributes('aria-label'))).toEqual(
      Object.values(en.GENERAL.PAGINATION)
    );
    await Promise.all(buttons.map(button => button.trigger('click')));
    expect(table.setPageIndex.mock.calls).toEqual([[0], [3]]);
    expect(table.previousPage).toHaveBeenCalledOnce();
    expect(table.nextPage).toHaveBeenCalledOnce();
    wrapper.unmount();
  });

  it('names header actions and emits the original keys and close event', async () => {
    const wrapper = mount(SidebarActionsHeader, {
      props: {
        title: 'Contact',
        buttons: [
          { key: 'edit', icon: 'i-lucide-pencil', tooltip: 'Edit contact' },
        ],
      },
    });
    const buttons = wrapper.findAll('button');
    expect(buttons.map(button => button.attributes('aria-label'))).toEqual([
      'Edit contact',
      'Close',
    ]);
    await buttons[0].trigger('click');
    await buttons[1].trigger('click');
    expect(wrapper.emitted('click')).toEqual([['edit']]);
    expect(wrapper.emitted('close')).toHaveLength(1);
    wrapper.unmount();
  });

  it('names calendar navigation and label removal without changing event values', async () => {
    const calendar = mount(CalendarAction, { props: { calendarType: 'end' } });
    const buttons = calendar.findAll('button');
    expect(buttons.map(button => button.attributes('aria-label'))).toEqual(
      Object.values(en.GENERAL.CALENDAR)
    );
    await buttons[0].trigger('click');
    await buttons[1].trigger('click');
    expect(calendar.emitted('prev')).toEqual([['end']]);
    expect(calendar.emitted('next')).toEqual([['end']]);
    const label = mount(Label, {
      props: { title: 'Follow up', showClose: true },
      global: { stubs: { FluentIcon: true } },
    });
    expect(label.get('button').attributes('aria-label')).toBe(
      'Remove Follow up'
    );
    await label.get('button').trigger('click');
    expect(label.emitted('remove')).toEqual([['Follow up']]);
    calendar.unmount();
    label.unmount();
  });
});
