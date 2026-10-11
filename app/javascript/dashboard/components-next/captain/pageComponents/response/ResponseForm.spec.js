import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';
import ResponseForm from './ResponseForm.vue';

const mocks = vi.hoisted(() => ({ dispatch: vi.fn() }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: key =>
    ref(
      key === 'captainAssistants/getRecords'
        ? [
            { id: 2, name: 'Sales', usage_mode: 'external_agent' },
            { id: 4, name: 'Support', usage_mode: 'external_agent' },
            { id: 9, name: 'Internal', usage_mode: 'internal_assistant' },
          ]
        : {}
    ),
}));
const wrapperFor = (props = {}) =>
  mount(ResponseForm, {
    props: { mode: 'create', ...props },
    global: {
      stubs: {
        Input: {
          props: ['modelValue'],
          emits: ['update:modelValue'],
          template:
            '<input :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
        },
        Editor: {
          props: ['modelValue'],
          emits: ['update:modelValue'],
          template:
            '<textarea :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
        },
        ComboBox: {
          props: ['modelValue', 'options'],
          emits: ['update:modelValue'],
          template:
            '<select :value="modelValue" @change="$emit(\'update:modelValue\', $event.target.value)"><option v-for="option in options" :key="option.value" :value="option.value">{{ option.label }}</option></select>',
        },
        Button: { props: ['type'], template: '<button :type="type" />' },
      },
    },
  });
const submit = async wrapper => {
  await wrapper.get('form').trigger('submit');
  await flushPromises();
};

describe('shared response agent access', () => {
  beforeEach(() => mocks.dispatch.mockReset());

  it('creates one answer available to several selected agents', async () => {
    const wrapper = wrapperFor();
    await wrapper.get('input').setValue('Opening hours?');
    await wrapper.get('textarea').setValue('We are open daily.');
    await wrapper.get('select').setValue('personal');
    expect(
      wrapper
        .findAll('input[type="checkbox"]')
        .map(input => input.element.value)
    ).toEqual(['2', '4']);
    await wrapper.get('input[value="2"]').setValue(true);
    await wrapper.get('input[value="4"]').setValue(true);
    expect(wrapper.emitted('submit')).toBeUndefined();
    await submit(wrapper);
    expect(wrapper.emitted('submit')[0]).toEqual([
      {
        question: 'Opening hours?',
        answer: 'We are open daily.',
        visibility: 'personal',
        assistant_id: null,
        allowed_assistant_ids: [2, 4],
      },
    ]);
  });

  it('requires at least one agent for selected materials', async () => {
    const wrapper = wrapperFor();
    await wrapper.get('input').setValue('Question');
    await wrapper.get('textarea').setValue('Answer');
    await wrapper.get('select').setValue('personal');
    await submit(wrapper);
    expect(wrapper.emitted('submit')).toBeUndefined();
    expect(wrapper.text()).toContain(
      'CAPTAIN.KNOWLEDGE_VISIBILITY.ASSISTANT_REQUIRED'
    );
  });

  it('round trips selected agents on edit and clears grants when sharing with all', async () => {
    const wrapper = wrapperFor({
      mode: 'edit',
      response: {
        question: 'Question',
        answer: 'Answer',
        visibility: 'personal',
        restricted_to_assistants: true,
        allowed_assistant_ids: [2, 4],
      },
    });
    expect(wrapper.get('input[value="2"]').element.checked).toBe(true);
    expect(wrapper.get('input[value="4"]').element.checked).toBe(true);
    await wrapper.get('select').setValue('general');
    await submit(wrapper);
    expect(wrapper.emitted('submit')[0][0]).toEqual({
      question: 'Question',
      answer: 'Answer',
      visibility: 'general',
      assistant_id: null,
      allowed_assistant_ids: [],
    });
  });

  it('keeps a legacy private owner when only the answer is edited', async () => {
    const response = {
      question: 'Question',
      answer: 'Answer',
      visibility: 'personal',
      assistant: { id: 2, name: 'Sales' },
      restricted_to_assistants: false,
      allowed_assistant_ids: [2],
    };
    const wrapper = wrapperFor({ mode: 'edit', response });

    expect(wrapper.get('select').element.value).toBe('personal');
    expect(wrapper.get('input[value="2"]').element.checked).toBe(true);
    await wrapper.get('textarea').setValue('Updated answer');
    await submit(wrapper);

    const payload = wrapper.emitted('submit')[0][0];
    expect(payload).toEqual({ question: 'Question', answer: 'Updated answer' });
    expect({ ...response, ...payload }).toMatchObject({
      visibility: 'personal',
      assistant: { id: 2 },
      allowed_assistant_ids: [2],
      restricted_to_assistants: false,
    });
  });

  it('keeps inherited source access on an answer-only edit', async () => {
    const response = {
      question: 'Question',
      answer: 'Answer',
      visibility: 'general',
      assistant: null,
      restricted_to_assistants: false,
      allowed_assistant_ids: [2, 4],
      documentable: { id: 12, type: 'Captain::Document', name: 'Manual' },
    };
    const wrapper = wrapperFor({ mode: 'edit', response });

    expect(wrapper.get('select').element.value).toBe('personal');
    expect(wrapper.get('input[value="2"]').element.checked).toBe(true);
    expect(wrapper.get('input[value="4"]').element.checked).toBe(true);
    await wrapper.get('textarea').setValue('Updated answer');
    await submit(wrapper);

    const payload = wrapper.emitted('submit')[0][0];
    expect(payload).toEqual({ question: 'Question', answer: 'Updated answer' });
    expect({ ...response, ...payload }).toMatchObject({
      visibility: 'general',
      restricted_to_assistants: false,
      allowed_assistant_ids: [2, 4],
    });
  });

  it('writes an explicit selected access change for a generated answer', async () => {
    const wrapper = wrapperFor({
      mode: 'edit',
      response: {
        question: 'Question',
        answer: 'Answer',
        visibility: 'general',
        restricted_to_assistants: false,
        allowed_assistant_ids: [2, 4],
        documentable: { id: 12, type: 'Captain::Document' },
      },
    });
    await wrapper.get('input[value="4"]').setValue(false);
    await submit(wrapper);

    expect(wrapper.emitted('submit')[0][0]).toEqual({
      question: 'Question',
      answer: 'Answer',
      visibility: 'personal',
      assistant_id: null,
      allowed_assistant_ids: [2],
    });
  });

  it('does not rewrite access when the same agents are selected again in a different order', async () => {
    const wrapper = wrapperFor({
      mode: 'edit',
      response: {
        question: 'Question',
        answer: 'Answer',
        visibility: 'personal',
        restricted_to_assistants: false,
        allowed_assistant_ids: [2, 4],
      },
    });
    await wrapper.get('input[value="2"]').setValue(false);
    await wrapper.get('input[value="2"]').setValue(true);
    await submit(wrapper);

    expect(wrapper.emitted('submit')[0][0]).toEqual({
      question: 'Question',
      answer: 'Answer',
    });
  });

  it('allows content-only edits to legacy workspace-owned personal answers', async () => {
    const wrapper = wrapperFor({
      mode: 'edit',
      response: {
        question: 'Question',
        answer: 'Answer',
        visibility: 'personal',
        assistant: null,
        restricted_to_assistants: false,
        allowed_assistant_ids: [],
      },
    });
    await wrapper.get('textarea').setValue('Updated answer');
    await submit(wrapper);

    expect(wrapper.emitted('submit')[0][0]).toEqual({
      question: 'Question',
      answer: 'Updated answer',
    });
  });
});
