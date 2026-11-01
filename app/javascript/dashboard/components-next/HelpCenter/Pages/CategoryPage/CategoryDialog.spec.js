import { mount, flushPromises } from '@vue/test-utils';
import { ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import CategoryDialog from './CategoryDialog.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';

const mocks = vi.hoisted(() => ({ dispatch: vi.fn(), alert: vi.fn() }));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: () => ref(false),
  useStoreGetters: () => ({
    'categories/uiFlags': ref(() => ({ isUpdating: false })),
  }),
}));
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { portalSlug: 'synthetic', locale: 'en' } }),
}));
vi.mock('dashboard/composables', () => ({
  useAlert: mocks.alert,
  useTrack: vi.fn(),
}));

beforeEach(() => {
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

const mountDialog = async () => {
  const wrapper = mount(CategoryDialog, {
    props: {
      mode: 'create',
      activeLocaleCode: 'en',
      activeLocaleName: 'English',
      portalName: 'Synthetic portal',
    },
    global: {
      stubs: { TeleportWithDirection: { template: '<div><slot /></div>' } },
    },
  });
  await flushPromises();
  return wrapper;
};

describe('CategoryDialog', () => {
  it('opens a single native form, validates, preserves failed values and closes after one successful save', async () => {
    const wrapper = await mountDialog();
    const dialog = wrapper.getComponent(Dialog);
    expect(wrapper.get('dialog').element.open).toBe(true);
    expect(wrapper.findAll('form')).toHaveLength(1);
    expect(dialog.props('disableConfirmButton')).toBe(true);
    await wrapper.get('form').trigger('submit');
    await flushPromises();
    expect(mocks.dispatch).not.toHaveBeenCalled();
    await wrapper
      .findAllComponents(Input)[0]
      .get('input')
      .setValue('Synthetic category');
    await flushPromises();
    expect(dialog.props('disableConfirmButton')).toBe(false);
    let rejectSave;
    mocks.dispatch.mockImplementationOnce(
      () =>
        new Promise((_resolve, reject) => {
          rejectSave = reject;
        })
    );
    dialog.vm.$emit('confirm');
    dialog.vm.$emit('confirm');
    await flushPromises();
    expect(mocks.dispatch).toHaveBeenCalledTimes(1);
    expect(dialog.props('isLoading')).toBe(true);
    rejectSave(new Error('Synthetic failure'));
    await flushPromises();
    expect(wrapper.emitted('close')).toBeUndefined();
    expect(wrapper.get('input').element.value).toBe('Synthetic category');
    mocks.dispatch.mockResolvedValueOnce({});
    await wrapper.get('form').trigger('submit');
    await flushPromises();
    expect(mocks.dispatch).toHaveBeenLastCalledWith('categories/create', {
      portalSlug: 'synthetic',
      categoryObj: {
        name: 'Synthetic category',
        slug: 'synthetic-category',
        icon: '',
        description: '',
        locale: 'en',
      },
    });
    expect(wrapper.emitted('close')).toHaveLength(1);
    expect(wrapper.get('dialog').element.open).toBe(false);
    wrapper.unmount();
  });

  it('cancels without creating a category', async () => {
    const wrapper = await mountDialog();
    wrapper.getComponent(Dialog).vm.close();
    await flushPromises();
    expect(wrapper.emitted('close')).toHaveLength(1);
    expect(mocks.dispatch).not.toHaveBeenCalled();
    wrapper.unmount();
  });
});
