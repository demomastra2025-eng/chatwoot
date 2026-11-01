import { mount, flushPromises } from '@vue/test-utils';
import { ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import LiveChatCampaignDialog from './LiveChatCampaignDialog.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import EditLiveChatCampaignDialog from './EditLiveChatCampaignDialog.vue';
import WebsiteTriggerCampaigns from 'dashboard/routes/dashboard/settings/inbox/components/WebsiteTriggerCampaigns.vue';

const mocks = vi.hoisted(() => ({ dispatch: vi.fn(), alert: vi.fn() }));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useStoreGetters: () => ({ 'campaigns/getLiveChatCampaigns': ref([]) }),
  useMapGetter: key =>
    ref(
      key === 'inboxes/getWebsiteInboxes'
        ? [{ id: 3, name: 'Synthetic website' }]
        : { isCreating: false }
    ),
}));
vi.mock('dashboard/composables', () => ({
  useAlert: mocks.alert,
  useTrack: vi.fn(),
}));
vi.mock('dashboard/components-next/Editor/Editor.vue', () => ({
  default: {
    props: ['modelValue'],
    emits: ['update:modelValue'],
    template: `<textarea name="campaign-message" :value="modelValue" @input="$emit('update:modelValue', $event.target.value)" />`,
  },
}));

beforeEach(() => {
  mocks.dispatch.mockResolvedValue({ data: { payload: [] } });
  Object.defineProperty(HTMLDialogElement.prototype, 'showModal', {
    configurable: true,
    value: vi.fn(function showModal() {
      this.open = true;
    }),
  });
  Object.defineProperty(HTMLDialogElement.prototype, 'close', {
    configurable: true,
    value: vi.fn(function close() {
      this.open = false;
      this.dispatchEvent(new Event('close'));
    }),
  });
});

const mountDialog = async (component = LiveChatCampaignDialog, props = {}) => {
  const wrapper = mount(component, {
    props,
    global: {
      stubs: {
        TeleportWithDirection: { template: '<div><slot /></div>' },
        ComboBox: {
          props: ['modelValue', 'options'],
          emits: ['update:modelValue'],
          template: `<select :value="modelValue" @change="$emit('update:modelValue', Number($event.target.value))"><option v-for="option in options" :key="option.value" :value="option.value">{{ option.label }}</option></select>`,
        },
      },
    },
  });
  await flushPromises();
  return wrapper;
};

describe('LiveChatCampaignDialog', () => {
  it('validates inside one native form and keeps a failed campaign available for retry', async () => {
    const wrapper = await mountDialog();
    const dialog = wrapper.getComponent(Dialog);
    expect(wrapper.get('dialog').element.open).toBe(true);
    expect(wrapper.findAll('form')).toHaveLength(1);
    await wrapper.get('form').trigger('submit');
    await flushPromises();
    expect(mocks.dispatch).not.toHaveBeenCalledWith(
      'campaigns/create',
      expect.anything()
    );
    await wrapper
      .findAllComponents(Input)[0]
      .get('input')
      .setValue('Synthetic campaign');
    await wrapper.get('textarea').setValue('Synthetic welcome');
    await wrapper.get('select#inbox').setValue('3');
    await wrapper.get('input[type="url"]').setValue('https://example.test/*');
    await flushPromises();
    expect(dialog.props('disableConfirmButton')).toBe(false);
    let rejectSave;
    mocks.dispatch.mockImplementation(action =>
      action === 'campaigns/create'
        ? new Promise((_resolve, reject) => {
            rejectSave = reject;
          })
        : Promise.resolve({ data: { payload: [] } })
    );
    dialog.vm.$emit('confirm');
    dialog.vm.$emit('confirm');
    await flushPromises();
    expect(
      mocks.dispatch.mock.calls.filter(
        ([action]) => action === 'campaigns/create'
      )
    ).toHaveLength(1);
    expect(dialog.props('isLoading')).toBe(true);
    rejectSave(new Error('Synthetic failure'));
    await flushPromises();
    expect(wrapper.emitted('close')).toBeUndefined();
    expect(wrapper.get('input').element.value).toBe('Synthetic campaign');
    expect(wrapper.get('textarea').element.value).toBe('Synthetic welcome');
    mocks.dispatch.mockResolvedValue({});
    await wrapper.get('form').trigger('submit');
    await flushPromises();
    expect(mocks.dispatch).toHaveBeenLastCalledWith(
      'campaigns/create',
      expect.objectContaining({
        title: 'Synthetic campaign',
        message: 'Synthetic welcome',
        inbox_id: 3,
        trigger_rules: { url: 'https://example.test/*', time_on_page: 10 },
      })
    );
    expect(wrapper.emitted('close')).toHaveLength(1);
    wrapper.unmount();
  });

  it('cancels without creating a campaign', async () => {
    const wrapper = await mountDialog();
    wrapper.getComponent(Dialog).vm.close();
    await flushPromises();
    expect(wrapper.emitted('close')).toHaveLength(1);
    expect(mocks.dispatch).not.toHaveBeenCalledWith(
      'campaigns/create',
      expect.anything()
    );
    wrapper.unmount();
  });
  it('validates the existing edit consumer and blocks duplicate saves until retry', async () => {
    const wrapper = await mountDialog(EditLiveChatCampaignDialog, {
      selectedCampaign: {
        id: 8,
        title: 'Synthetic campaign',
        message: 'Synthetic welcome',
        inbox: { id: 3 },
        sender: null,
        enabled: true,
        trigger_only_during_business_hours: false,
        trigger_rules: { url: 'https://example.test/*', time_on_page: 10 },
      },
    });
    const dialog = wrapper.getComponent(Dialog);
    dialog.vm.open();
    await flushPromises();
    expect(wrapper.findAll('form')).toHaveLength(1);
    const title = wrapper.get('input');
    await title.setValue('');
    await wrapper.get('form').trigger('submit');
    await flushPromises();
    expect(mocks.dispatch).not.toHaveBeenCalledWith(
      'campaigns/update',
      expect.anything()
    );
    await title.setValue('Updated synthetic campaign');
    let rejectSave;
    mocks.dispatch.mockImplementation(action =>
      action === 'campaigns/update'
        ? new Promise((_resolve, reject) => {
            rejectSave = reject;
          })
        : Promise.resolve({ data: { payload: [] } })
    );
    dialog.vm.$emit('confirm');
    dialog.vm.$emit('confirm');
    await flushPromises();
    expect(
      mocks.dispatch.mock.calls.filter(
        ([action]) => action === 'campaigns/update'
      )
    ).toHaveLength(1);
    rejectSave(new Error('Synthetic failure'));
    await flushPromises();
    expect(wrapper.get('dialog').element.open).toBe(true);
    expect(title.element.value).toBe('Updated synthetic campaign');
    mocks.dispatch.mockResolvedValue({});
    await wrapper.get('form').trigger('submit');
    await flushPromises();
    expect(mocks.dispatch).toHaveBeenLastCalledWith(
      'campaigns/update',
      expect.objectContaining({ id: 8, title: 'Updated synthetic campaign' })
    );
    expect(wrapper.get('dialog').element.open).toBe(false);
    wrapper.unmount();
  });

  it('routes the existing website create consumer through validation with a locked inbox', async () => {
    const wrapper = await mountDialog(WebsiteTriggerCampaigns, {
      inbox: { id: 3 },
    });
    await wrapper.get('button').trigger('click');
    await flushPromises();
    const dialog = wrapper.findAllComponents(Dialog)[0];
    const form = wrapper.get('dialog[open] form');
    expect(form.findAll('form')).toHaveLength(0);
    await form.trigger('submit');
    await flushPromises();
    expect(mocks.dispatch).not.toHaveBeenCalledWith(
      'campaigns/create',
      expect.anything()
    );
    await form.get('input').setValue('Website synthetic campaign');
    await form.get('textarea').setValue('Synthetic welcome');
    await form.get('input[type="url"]').setValue('https://example.test/*');
    let rejectSave;
    mocks.dispatch.mockImplementation(action =>
      action === 'campaigns/create'
        ? new Promise((_resolve, reject) => {
            rejectSave = reject;
          })
        : Promise.resolve({ data: { payload: [] } })
    );
    dialog.vm.$emit('confirm');
    dialog.vm.$emit('confirm');
    await flushPromises();
    expect(
      mocks.dispatch.mock.calls.filter(
        ([action]) => action === 'campaigns/create'
      )
    ).toHaveLength(1);
    rejectSave(new Error('Synthetic failure'));
    await flushPromises();
    expect(wrapper.get('dialog[open] input').element.value).toBe(
      'Website synthetic campaign'
    );
    mocks.dispatch.mockResolvedValue({});
    await form.trigger('submit');
    await flushPromises();
    expect(mocks.dispatch).toHaveBeenLastCalledWith(
      'campaigns/create',
      expect.objectContaining({
        title: 'Website synthetic campaign',
        inbox_id: 3,
      })
    );
    expect(wrapper.find('dialog[open]').exists()).toBe(false);
    wrapper.unmount();
  });
});
