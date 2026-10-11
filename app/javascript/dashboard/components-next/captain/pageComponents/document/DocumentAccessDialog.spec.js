import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';
import DocumentAccessDialog from './DocumentAccessDialog.vue';

const mocks = vi.hoisted(() => ({
  dispatch: vi.fn(),
  alert: vi.fn(),
  close: vi.fn(),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables', () => ({ useAlert: mocks.alert }));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: key =>
    ref(
      key === 'captainAssistants/getRecords'
        ? [
            { id: 2, name: 'Sales' },
            { id: 4, name: 'Support' },
          ]
        : {}
    ),
}));
const mountDialog = (document = {}) =>
  mount(DocumentAccessDialog, {
    props: {
      document: {
        id: 12,
        visibility: 'personal',
        restricted_to_assistants: true,
        allowed_assistant_ids: [2],
        ...document,
      },
    },
    global: {
      stubs: {
        Dialog: {
          emits: ['confirm'],
          setup(_props, { expose }) {
            expose({ close: mocks.close });
          },
          template:
            '<div><slot /><button data-test="save" @click="$emit(\'confirm\')" /></div>',
        },
        Select: {
          props: ['modelValue', 'options'],
          emits: ['update:modelValue'],
          template:
            '<select :value="modelValue" @change="$emit(\'update:modelValue\', $event.target.value)"><option v-for="option in options" :key="option.value" :value="option.value">{{ option.label }}</option></select>',
        },
      },
    },
  });

describe('existing document access', () => {
  beforeEach(() => {
    mocks.dispatch.mockReset();
    mocks.dispatch.mockResolvedValue({});
    mocks.close.mockReset();
  });
  it('updates grants only after the access dialog Save action', async () => {
    const wrapper = mountDialog();
    await wrapper.get('input[value="4"]').setValue(true);
    expect(mocks.dispatch).not.toHaveBeenCalledWith(
      'captainDocuments/update',
      expect.anything()
    );
    await wrapper.get('[data-test="save"]').trigger('click');
    await flushPromises();
    expect(mocks.dispatch).toHaveBeenCalledWith('captainDocuments/update', {
      id: 12,
      document: {
        visibility: 'personal',
        assistant_id: null,
        allowed_assistant_ids: [2, 4],
      },
    });
  });

  it('keeps a legacy private owner when Save is pressed without an access change', async () => {
    const document = {
      visibility: 'personal',
      assistant: { id: 2, name: 'Sales' },
      restricted_to_assistants: false,
      allowed_assistant_ids: [2],
    };
    const wrapper = mountDialog(document);

    expect(wrapper.get('select').element.value).toBe('personal');
    expect(wrapper.get('input[value="2"]').element.checked).toBe(true);
    await wrapper.get('[data-test="save"]').trigger('click');
    await flushPromises();

    expect(mocks.dispatch).not.toHaveBeenCalledWith(
      'captainDocuments/update',
      expect.anything()
    );
    expect(mocks.close).toHaveBeenCalledOnce();
    expect(document).toMatchObject({
      visibility: 'personal',
      assistant: { id: 2 },
      restricted_to_assistants: false,
      allowed_assistant_ids: [2],
    });
  });

  it('changes access explicitly while retaining a legacy owner in the selected agent list', async () => {
    const wrapper = mountDialog({
      assistant: { id: 2, name: 'Sales' },
      restricted_to_assistants: false,
    });
    await wrapper.get('input[value="4"]').setValue(true);
    await wrapper.get('[data-test="save"]').trigger('click');
    await flushPromises();

    expect(mocks.dispatch).toHaveBeenCalledWith('captainDocuments/update', {
      id: 12,
      document: {
        visibility: 'personal',
        assistant_id: null,
        allowed_assistant_ids: [2, 4],
      },
    });
  });

  it('clears a legacy private owner only after explicitly choosing shared access', async () => {
    const wrapper = mountDialog({
      assistant: { id: 2, name: 'Sales' },
      restricted_to_assistants: false,
    });
    await wrapper.get('select').setValue('general');
    await wrapper.get('[data-test="save"]').trigger('click');
    await flushPromises();

    expect(mocks.dispatch).toHaveBeenCalledWith('captainDocuments/update', {
      id: 12,
      document: {
        visibility: 'general',
        assistant_id: null,
        allowed_assistant_ids: [],
      },
    });
  });
});
