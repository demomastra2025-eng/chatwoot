import { shallowMount } from '@vue/test-utils';

import WorkspaceWorkingHours from './WorkspaceWorkingHours.vue';

const dispatch = vi.fn();
const useAlert = vi.fn();

vi.mock('dashboard/composables', () => ({
  useAlert: message => useAlert(message),
}));

const account = {
  id: 1,
  settings: {
    workspace_working_hours_enabled: true,
    workspace_timezone: 'Asia/Almaty',
    workspace_working_hours: [
      { day_of_week: 0, closed_all_day: true, open_all_day: false },
      ...Array.from({ length: 5 }, (_, index) => ({
        day_of_week: index + 1,
        closed_all_day: false,
        open_hour: 9,
        open_minutes: 0,
        close_hour: 17,
        close_minutes: 0,
        open_all_day: false,
      })),
      { day_of_week: 6, closed_all_day: true, open_all_day: false },
    ],
    workspace_breaks: [
      {
        days: [1, 2, 3, 4, 5],
        start_time: '13:00',
        end_time: '14:00',
        title: 'Lunch',
      },
    ],
    workspace_days_off: [
      { date: '2026-12-16', title: 'Independence Day', recurring_yearly: true },
    ],
  },
};

const mountComponent = (locale = 'ru') =>
  shallowMount(WorkspaceWorkingHours, {
    props: { account },
    global: {
      mocks: {
        $i18n: { locale },
        $t: key => key,
        $store: {
          dispatch,
          getters: { 'accounts/getUIFlags': { isUpdating: false } },
        },
      },
      stubs: {
        SectionLayout: true,
        SettingsFieldSection: true,
        ComboBox: true,
        NextButton: true,
        Checkbox: true,
        BusinessDay: true,
      },
    },
  });

describe('WorkspaceWorkingHours', () => {
  beforeEach(() => {
    dispatch.mockReset();
    dispatch.mockImplementation((_action, { id: _id, ...settings }) =>
      Promise.resolve({
        ...account,
        settings: { ...account.settings, ...settings },
      })
    );
    useAlert.mockReset();
  });

  it('hydrates and saves the Workspace schedule', async () => {
    const wrapper = mountComponent();

    expect(wrapper.vm.timezone).toBe('Asia/Almaty');
    expect(wrapper.vm.breaks).toHaveLength(1);
    expect(wrapper.vm.daysOff).toHaveLength(1);

    await wrapper.vm.save();

    expect(dispatch).toHaveBeenCalledWith(
      'accounts/update',
      expect.objectContaining({
        id: 1,
        workspace_timezone: 'Asia/Almaty',
        workspace_working_hours: expect.arrayContaining([
          expect.objectContaining({ day_of_week: 1, open_hour: 9 }),
        ]),
        workspace_breaks: [
          expect.objectContaining({ start_time: '13:00', end_time: '14:00' }),
        ],
        workspace_days_off: [
          expect.objectContaining({
            date: '2026-12-16',
            recurring_yearly: true,
          }),
        ],
      })
    );
    expect(useAlert).toHaveBeenCalledWith('Время работы Workspace обновлено.');
  });

  it('uses component-loaded working-hours messages for supported locales', () => {
    expect(mountComponent('ru').vm.workingHoursMessages.BREAKS.TITLE).toBe(
      'Перерывы'
    );
    expect(mountComponent('en').vm.workingHoursMessages.DAYS_OFF.TITLE).toBe(
      'Days off and holidays'
    );
    expect(mountComponent('kk').vm.workingHoursMessages.BREAKS.ADD).toBe(
      'Үзіліс қосу'
    );
  });

  it('reports an error when an old API silently omits the requested settings', async () => {
    dispatch.mockResolvedValue({
      ...account,
      settings: { workspace_timezone: 'Asia/Almaty' },
    });
    const wrapper = mountComponent();

    await wrapper.vm.save();

    expect(useAlert).toHaveBeenCalledWith(
      'Не удалось обновить время работы Workspace.'
    );
    expect(useAlert).not.toHaveBeenCalledWith(
      'Время работы Workspace обновлено.'
    );
  });
});
