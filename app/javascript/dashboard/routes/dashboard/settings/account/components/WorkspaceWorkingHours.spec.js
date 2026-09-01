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
  },
};

const mountComponent = () =>
  shallowMount(WorkspaceWorkingHours, {
    props: { account },
    global: {
      mocks: {
        $t: key => key,
        $store: {
          dispatch,
          getters: { 'accounts/getUIFlags': { isUpdating: false } },
        },
      },
      stubs: {
        SectionLayout: true,
        SettingsToggleSection: true,
        SettingsFieldSection: true,
        ComboBox: true,
        NextButton: true,
        BusinessDay: true,
      },
    },
  });

describe('WorkspaceWorkingHours', () => {
  beforeEach(() => {
    dispatch.mockReset();
    dispatch.mockResolvedValue();
    useAlert.mockReset();
  });

  it('hydrates and saves the Workspace schedule', async () => {
    const wrapper = mountComponent();

    expect(wrapper.vm.enabled).toBe(true);
    expect(wrapper.vm.timezone).toBe('Asia/Almaty');

    await wrapper.vm.save();

    expect(dispatch).toHaveBeenCalledWith(
      'accounts/update',
      expect.objectContaining({
        id: 1,
        workspace_working_hours_enabled: true,
        workspace_timezone: 'Asia/Almaty',
        workspace_working_hours: expect.arrayContaining([
          expect.objectContaining({ day_of_week: 1, open_hour: 9 }),
        ]),
      })
    );
    expect(useAlert).toHaveBeenCalledWith(
      'GENERAL_SETTINGS.WORKING_HOURS.UPDATE_SUCCESS'
    );
  });
});
