import en from 'dashboard/i18n/locale/en/generalSettings.json';
import { ref } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';
import WorkspaceGreetingSettings from './WorkspaceGreetingSettings.vue';

const { dispatch, alert } = vi.hoisted(() => ({
  dispatch: vi.fn(),
  alert: vi.fn(),
}));
const inboxes = ref([]);
vi.mock('dashboard/composables', () => ({ useAlert: alert }));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
  useMapGetter: () => inboxes,
}));
const account = () => ({
  id: 10,
  settings: {
    workspace_greeting: {
      enabled: true,
      message: 'Company message',
      excluded_inbox_ids: [2],
    },
  },
});
const wrappers = [];
const render = props => {
  const wrapper = mount(WorkspaceGreetingSettings, {
    props: { account: account(), ...props },
  });
  wrappers.push(wrapper);
  return wrapper;
};
beforeEach(() => {
  inboxes.value = [
    {
      id: 1,
      name: 'Channel A',
      channel_type: 'Channel::Whatsapp',
      greeting_enabled: false,
      greeting_message: 'Retired A',
    },
    {
      id: 2,
      name: 'Channel B',
      channel_type: 'Channel::Instagram',
      greeting_enabled: true,
      greeting_message: 'Retired B',
    },
    { id: 3, name: 'Voice', channel_type: 'Channel::Voice' },
    { id: 4, name: 'Email', channel_type: 'Channel::Email' },
  ];
  dispatch.mockImplementation((_action, payload) =>
    Promise.resolve({
      id: payload.id,
      settings: { workspace_greeting: payload.workspace_greeting },
    })
  );
});
afterEach(() => wrappers.splice(0).forEach(wrapper => wrapper.unmount()));

describe('WorkspaceGreetingSettings', () => {
  it('reads only the canonical company message and excludes voice/email from selection', () => {
    const wrapper = render();
    expect(wrapper.get('textarea').element.value).toBe('Company message');
    expect(wrapper.text()).not.toContain('Retired A');
    expect(wrapper.text()).toContain('Channel A');
    expect(wrapper.find('#workspace-greeting-inbox-3').exists()).toBe(false);
    expect(wrapper.find('#workspace-greeting-inbox-4').exists()).toBe(false);
    expect(wrapper.get('#workspace-greeting-inbox-1').element.checked).toBe(
      true
    );
    expect(wrapper.get('#workspace-greeting-inbox-2').element.checked).toBe(
      false
    );
  });

  it('saves once on the account without fanout to channels', async () => {
    const wrapper = render();
    await wrapper.get('textarea').setValue(' Updated common greeting ');
    await wrapper.get('[data-test="workspace-greeting-save"]').trigger('click');
    await flushPromises();
    expect(dispatch).toHaveBeenCalledTimes(1);
    expect(dispatch).toHaveBeenCalledWith('accounts/update', {
      id: 10,
      workspace_greeting: {
        enabled: true,
        message: 'Updated common greeting',
        excluded_inbox_ids: [2],
      },
    });
  });

  it('inherits new text channels while preserving unsaved text and exclusions', async () => {
    const wrapper = render();
    await wrapper.get('textarea').setValue('Unsaved edit');
    inboxes.value.push({
      id: 5,
      name: 'New channel',
      channel_type: 'Channel::Whatsapp',
    });
    await flushPromises();
    expect(wrapper.get('#workspace-greeting-inbox-5').element.checked).toBe(
      true
    );
    expect(wrapper.get('#workspace-greeting-inbox-2').element.checked).toBe(
      false
    );
    expect(wrapper.get('textarea').element.value).toBe('Unsaved edit');
  });

  it('preserves edits when saving another section replaces the account record', async () => {
    const wrapper = render();
    await wrapper.get('textarea').setValue('Unsaved greeting');
    await wrapper.setProps({
      account: { ...account(), name: 'Updated elsewhere' },
    });
    expect(wrapper.get('textarea').element.value).toBe('Unsaved greeting');
  });

  it('does not dispatch an enabled blank greeting', async () => {
    const wrapper = render();
    await wrapper.get('textarea').setValue(' ');
    await wrapper.get('[data-test="workspace-greeting-save"]').trigger('click');
    expect(dispatch).not.toHaveBeenCalled();
    expect(wrapper.text()).toContain('Add a greeting message.');
  });

  it('reports failure if the server ignores the requested setting', async () => {
    dispatch.mockResolvedValueOnce({ settings: {} });
    const wrapper = render();
    await wrapper.get('[data-test="workspace-greeting-save"]').trigger('click');
    await flushPromises();
    expect(alert).toHaveBeenCalledWith(
      en.GENERAL_SETTINGS.CONVERSATIONS.GREETING_UPDATE_ERROR
    );
    expect(wrapper.get('textarea').element.value).toBe('Company message');
  });

  it('blocks duplicate clicks synchronously and permits retry after a failure', async () => {
    let reject;
    dispatch.mockImplementationOnce(
      () =>
        new Promise((_resolve, failure) => {
          reject = failure;
        })
    );
    const wrapper = render();
    const save = wrapper.get('[data-test="workspace-greeting-save"]');
    save.element.click();
    save.element.click();
    expect(dispatch).toHaveBeenCalledTimes(1);
    reject(new Error('network'));
    await flushPromises();
    expect(save.attributes('disabled')).toBeUndefined();
    await save.trigger('click');
    await flushPromises();
    expect(dispatch).toHaveBeenCalledTimes(2);
  });

  it('keeps read-only controls disabled and hides save', () => {
    const wrapper = render({ disabled: true });
    expect(wrapper.find('[data-test="workspace-greeting-save"]').exists()).toBe(
      false
    );
    expect(wrapper.get('[role="switch"]').attributes('disabled')).toBeDefined();
    expect(wrapper.get('textarea').element.disabled).toBe(true);
  });

  it('does not replace the next account form with a late response', async () => {
    let resolve;
    dispatch.mockImplementationOnce(
      () =>
        new Promise(success => {
          resolve = success;
        })
    );
    const wrapper = render();
    await wrapper.get('[data-test="workspace-greeting-save"]').trigger('click');
    await wrapper.setProps({
      account: {
        id: 11,
        settings: {
          workspace_greeting: {
            enabled: true,
            message: 'Account B',
            excluded_inbox_ids: [],
          },
        },
      },
    });
    resolve({
      settings: {
        workspace_greeting: {
          enabled: true,
          message: 'Late account A',
          excluded_inbox_ids: [],
        },
      },
    });
    await flushPromises();
    expect(wrapper.get('textarea').element.value).toBe('Account B');
    expect(alert).not.toHaveBeenCalled();
  });
});
