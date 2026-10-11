import { describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';
import DocumentForm from './DocumentForm.vue';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: vi.fn() }),
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
const mountForm = () =>
  mount(DocumentForm, {
    global: {
      stubs: {
        Input: {
          props: ['modelValue', 'label'],
          emits: ['update:modelValue'],
          template:
            '<input :data-label="label" :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
        },
        ComboBox: {
          props: ['modelValue', 'options'],
          emits: ['update:modelValue'],
          template:
            '<select :value="modelValue" @change="$emit(\'update:modelValue\', $event.target.value)"><option v-for="option in options" :key="option.value" :value="option.value">{{ option.label }}</option></select>',
        },
        Switch: true,
        Button: { props: ['type'], template: '<button :type="type" />' },
      },
    },
  });

describe('document access selection', () => {
  it('creates one material for multiple agents and general materials for all agents', async () => {
    const wrapper = mountForm();
    await wrapper
      .get('[data-label="CAPTAIN.DOCUMENTS.FORM.URL.LABEL"]')
      .setValue('https://example.com/info');
    await wrapper.get('#documentVisibility').setValue('personal');
    await wrapper.get('input[value="2"]').setValue(true);
    await wrapper.get('input[value="4"]').setValue(true);
    await wrapper.get('form').trigger('submit');
    await flushPromises();
    expect(wrapper.emitted('submit')[0][0].document).toEqual(
      expect.objectContaining({
        visibility: 'personal',
        assistant_id: null,
        allowed_assistant_ids: [2, 4],
      })
    );
    await wrapper.get('#documentVisibility').setValue('general');
    await wrapper.get('form').trigger('submit');
    await flushPromises();
    expect(wrapper.emitted('submit')[1][0].document).toEqual(
      expect.objectContaining({
        visibility: 'general',
        assistant_id: null,
        allowed_assistant_ids: [],
      })
    );
  });

  it('includes the selected access grant array in a file upload', async () => {
    const wrapper = mountForm();
    await wrapper.get('#documentType').setValue('file_upload');
    const file = new File(['Material'], 'info.pdf', {
      type: 'application/pdf',
    });
    const input = wrapper.get('input[type="file"]');
    Object.defineProperty(input.element, 'files', { value: [file] });
    await input.trigger('change');
    await wrapper.get('#documentVisibility').setValue('personal');
    await wrapper.get('input[value="2"]').setValue(true);
    await wrapper.get('input[value="4"]').setValue(true);
    await wrapper.get('form').trigger('submit');
    await flushPromises();
    const data = wrapper.emitted('submit')[0][0];
    expect(data.get('document[assistant_id]')).toBe('');
    expect(data.get('document[visibility]')).toBe('personal');
    expect(
      data.getAll('document[allowed_assistant_ids][]').filter(Boolean)
    ).toEqual(['2', '4']);
    expect(data.get('document[pdf_file]').name).toBe('info.pdf');
  });
});
