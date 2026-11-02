import en from 'dashboard/i18n/locale/en/generalSettings.json';
import { flushPromises, mount } from '@vue/test-utils';
import WorkspaceOutOfOfficeSettings from './WorkspaceOutOfOfficeSettings.vue';

const { dispatch, alert } = vi.hoisted(() => ({
  dispatch: vi.fn(),
  alert: vi.fn(),
}));
vi.mock('dashboard/composables', () => ({ useAlert: alert }));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
}));
const account = () => ({
  id: 10,
  settings: {
    workspace_working_hours: Array(7).fill({}),
    workspace_out_of_office: { enabled: true, message: 'Company offline' },
  },
});
const wrappers = [];
const render = props => {
  const wrapper = mount(WorkspaceOutOfOfficeSettings, {
    props: { account: account(), ...props },
  });
  wrappers.push(wrapper);
  return wrapper;
};
beforeEach(() => {
  dispatch.mockImplementation((_action, payload) =>
    Promise.resolve({
      settings: { workspace_out_of_office: payload.workspace_out_of_office },
    })
  );
});
afterEach(() => wrappers.splice(0).forEach(wrapper => wrapper.unmount()));

describe('WorkspaceOutOfOfficeSettings', () => {
  it('saves one common offline message next to the company schedule', async () => {
    const wrapper = render();
    await wrapper.get('textarea').setValue(' New reply ');
    await wrapper
      .get('[data-test="workspace-out-of-office-save"]')
      .trigger('click');
    await flushPromises();
    expect(dispatch).toHaveBeenCalledOnce();
    expect(dispatch).toHaveBeenCalledWith('accounts/update', {
      id: 10,
      workspace_out_of_office: { enabled: true, message: 'New reply' },
    });
  });

  it('cannot enable replies before the common schedule is saved', () => {
    const wrapper = render({ account: { id: 10, settings: {} } });
    expect(wrapper.get('[role="switch"]').attributes('disabled')).toBeDefined();
    expect(wrapper.text()).toContain('Save the company working hours first.');
  });

  it('can turn replies off while preserving the message', async () => {
    const wrapper = render();
    await wrapper.get('[role="switch"]').trigger('click');
    expect(wrapper.find('textarea').exists()).toBe(false);
    await wrapper
      .get('[data-test="workspace-out-of-office-save"]')
      .trigger('click');
    await flushPromises();
    expect(dispatch).toHaveBeenCalledWith('accounts/update', {
      id: 10,
      workspace_out_of_office: { enabled: false, message: 'Company offline' },
    });
  });

  it('preserves edits when another section refreshes the account', async () => {
    const wrapper = render();
    await wrapper.get('textarea').setValue('Unsaved offline text');
    await wrapper.setProps({
      account: { ...account(), name: 'Changed elsewhere' },
    });
    expect(wrapper.get('textarea').element.value).toBe('Unsaved offline text');
  });

  it('does not submit an enabled blank reply', async () => {
    const wrapper = render();
    await wrapper.get('textarea').setValue('');
    await wrapper
      .get('[data-test="workspace-out-of-office-save"]')
      .trigger('click');
    expect(dispatch).not.toHaveBeenCalled();
    expect(wrapper.text()).toContain('Add a reply message.');
  });

  it('does not report success when an older server ignores the field', async () => {
    dispatch.mockResolvedValueOnce({ settings: {} });
    const wrapper = render();
    await wrapper
      .get('[data-test="workspace-out-of-office-save"]')
      .trigger('click');
    await flushPromises();
    expect(alert).toHaveBeenCalledWith(en.GENERAL_SETTINGS.OUT_OF_OFFICE.ERROR);
    expect(wrapper.get('textarea').element.value).toBe('Company offline');
  });

  it('blocks duplicate saves and restores the form after failure', async () => {
    let reject;
    dispatch.mockImplementationOnce(
      () =>
        new Promise((_resolve, failure) => {
          reject = failure;
        })
    );
    const wrapper = render();
    const save = wrapper.get('[data-test="workspace-out-of-office-save"]');
    save.element.click();
    save.element.click();
    expect(dispatch).toHaveBeenCalledOnce();
    reject(new Error('offline'));
    await flushPromises();
    expect(save.attributes('disabled')).toBeUndefined();
    await save.trigger('click');
    await flushPromises();
    expect(dispatch).toHaveBeenCalledTimes(2);
  });

  it('keeps the controls read-only for employees', () => {
    const wrapper = render({ disabled: true });
    expect(wrapper.get('[role="switch"]').attributes('disabled')).toBeDefined();
    expect(wrapper.get('textarea').element.disabled).toBe(true);
    expect(
      wrapper.find('[data-test="workspace-out-of-office-save"]').exists()
    ).toBe(false);
  });
});
