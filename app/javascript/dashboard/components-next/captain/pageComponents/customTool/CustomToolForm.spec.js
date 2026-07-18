import { defineComponent, h } from 'vue';
import { flushPromises, shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import Input from 'dashboard/components-next/input/Input.vue';
import CustomToolForm from './CustomToolForm.vue';

const mocks = vi.hoisted(() => ({
  alert: vi.fn(),
  runTestForCreate: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ({
    value: {
      creatingItem: false,
      updatingItem: false,
    },
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => mocks.alert(...args),
}));

vi.mock('dashboard/api/captain/contextFields', () => ({
  default: {
    get: vi.fn().mockResolvedValue({ data: [] }),
  },
}));

const ToolTestPanelStub = defineComponent({
  name: 'ToolTestPanel',
  setup(_, { expose }) {
    expose({
      runTestForCreate: (...args) => mocks.runTestForCreate(...args),
    });
    return () => h('div');
  },
});

const buildWrapper = () =>
  shallowMount(CustomToolForm, {
    props: {
      mode: 'create',
    },
    global: {
      stubs: {
        ToolTestPanel: ToolTestPanelStub,
      },
    },
  });

const fillRequiredFields = async wrapper => {
  const inputs = wrapper.findAllComponents(Input);
  await inputs[0].vm.$emit('update:modelValue', 'Search contacts');
  await inputs[2].vm.$emit(
    'update:modelValue',
    'https://api.example.com/contacts'
  );
};

describe('CustomToolForm create flow', () => {
  beforeEach(() => {
    mocks.alert.mockReset();
    mocks.runTestForCreate.mockReset();
  });

  it('runs the real request before emitting create submit', async () => {
    mocks.runTestForCreate.mockResolvedValue({
      response: { successful: true, status: 200 },
    });
    const wrapper = buildWrapper();
    await fillRequiredFields(wrapper);

    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(mocks.runTestForCreate).toHaveBeenCalledOnce();
    expect(wrapper.emitted('submit')).toHaveLength(1);
  });

  it('does not create the tool when the real test request fails', async () => {
    mocks.runTestForCreate.mockResolvedValue({
      response: { successful: false, status: 422 },
    });
    const wrapper = buildWrapper();
    await fillRequiredFields(wrapper);

    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(mocks.runTestForCreate).toHaveBeenCalledOnce();
    expect(wrapper.emitted('submit')).toBeUndefined();
    expect(mocks.alert).toHaveBeenCalledWith(
      'CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.TEST.REQUIRED_SUCCESS'
    );
  });
});
