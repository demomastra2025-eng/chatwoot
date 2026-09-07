import { flushPromises, shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import CrmTaskCatalogSettings from './CrmTaskCatalogSettings.vue';

const { store, alert } = vi.hoisted(() => ({
  store: {
    taskTypes: [
      {
        id: 7,
        name: 'Calls',
        active: true,
        outcomes: [{ id: 11, name: 'Answered', active: true }],
      },
    ],
    ui: { isSavingTaskCatalog: false },
    saveTaskType: vi.fn(),
    saveTaskOutcome: vi.fn(),
  },
  alert: vi.fn(),
}));
vi.mock('dashboard/stores/crm/references', () => ({
  useCrmReferencesStore: () => store,
}));
vi.mock('dashboard/composables', () => ({ useAlert: alert }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const DialogStub = {
  data: () => ({ opened: false }),
  methods: {
    open() {
      this.opened = true;
    },
    close() {
      this.opened = false;
    },
  },
  template: '<section v-if="opened"><slot /></section>',
};
const openOutcome = async () => {
  const wrapper = shallowMount(CrmTaskCatalogSettings, {
    props: { canManage: true },
    global: { stubs: { Dialog: DialogStub } },
  });
  await wrapper.get('article button').trigger('click');
  return { wrapper, dialog: wrapper.findAllComponents(Dialog)[1] };
};

describe('outcome form saving', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    store.saveTaskOutcome.mockResolvedValue({ id: 11 });
  });

  it('keeps an active toggle local and saves it with the other fields in one request', async () => {
    const { dialog } = await openOutcome();
    const active = dialog.findAllComponents(Switch)[2];
    active.vm.$emit('update:modelValue', false);
    dialog.findComponent(Input).vm.$emit('update:modelValue', 'Renamed');
    await flushPromises();
    expect(store.saveTaskOutcome).not.toHaveBeenCalled();
    dialog.vm.$emit('confirm');
    await flushPromises();
    expect(store.saveTaskOutcome).toHaveBeenCalledTimes(1);
    expect(store.saveTaskOutcome).toHaveBeenCalledWith(
      expect.objectContaining({
        id: 11,
        active: false,
        name: 'Renamed',
        task_type_id: 7,
      })
    );
    expect(dialog.vm.opened).toBe(false);
  });

  it('does not save a cancelled toggle and restores the persisted value on reopen', async () => {
    const { wrapper, dialog } = await openOutcome();
    dialog.findAllComponents(Switch)[2].vm.$emit('update:modelValue', false);
    dialog.vm.close();
    await wrapper.get('article button').trigger('click');
    expect(dialog.findAllComponents(Switch)[2].props('modelValue')).toBe(true);
    expect(store.saveTaskOutcome).not.toHaveBeenCalled();
  });

  it('keeps the draft open after a failed save', async () => {
    const { dialog } = await openOutcome();
    store.saveTaskOutcome.mockRejectedValueOnce(new Error('Save failed'));
    dialog.findAllComponents(Switch)[2].vm.$emit('update:modelValue', false);
    dialog.vm.$emit('confirm');
    await flushPromises();
    expect(dialog.vm.opened).toBe(true);
    expect(dialog.findAllComponents(Switch)[2].props('modelValue')).toBe(false);
    expect(alert).toHaveBeenCalled();
  });
});
