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
    t: (key, params) => (params?.title ? `${params.title} (copy)` : key),
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

const TextAreaStub = defineComponent({
  name: 'TextArea',
  props: {
    modelValue: { type: String, default: '' },
    label: { type: String, default: '' },
  },
  setup(props, { slots }) {
    return () =>
      h('div', { 'data-label': props.label }, [
        slots.default?.(),
        h('textarea', { value: props.modelValue }),
      ]);
  },
});

const buildWrapper = (props = {}) =>
  shallowMount(CustomToolForm, {
    props: {
      mode: 'create',
      ...props,
    },
    global: {
      stubs: {
        ToolTestPanel: ToolTestPanelStub,
        TextArea: TextAreaStub,
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
    expect(wrapper.emitted('submit')[0][0]).toMatchObject({
      request_body_type: 'json',
    });
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

  it('prefills a duplicate and creates it as a new tool', async () => {
    mocks.runTestForCreate.mockResolvedValue({
      response: { successful: true, status: 200 },
    });
    const wrapper = buildWrapper({
      mode: 'duplicate',
      tool: {
        id: 42,
        title: 'CRM lookup',
        description: 'Lookup contact',
        endpoint_url: 'https://api.example.com/contacts',
        http_method: 'POST',
        request_body_type: 'form_urlencoded',
        request_template: '{"phone":"{{ phone }}"}',
        auth_type: 'none',
        auth_config: {},
        param_schema: [],
      },
    });

    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(mocks.runTestForCreate).toHaveBeenCalledOnce();
    expect(wrapper.emitted('submit')[0][0]).toMatchObject({
      title: 'CRM lookup (copy)',
      request_body_type: 'form_urlencoded',
      request_template: '{"phone":"{{ phone }}"}',
    });
  });

  it('inserts template parameters as safely serialized JSON values', async () => {
    const wrapper = buildWrapper({
      mode: 'edit',
      tool: {
        id: 42,
        title: 'Create lead',
        endpoint_url: 'https://api.example.com/leads',
        http_method: 'POST',
        request_body_type: 'json',
        request_template: '',
        auth_type: 'none',
        auth_config: {},
        param_schema: [
          {
            name: 'customer_name',
            type: 'string',
            description: 'Customer name',
            source: 'agent',
            request_location: 'template',
          },
          {
            name: 'tenant_id',
            type: 'string',
            source: 'fixed',
            fixed_value: 'tenant-42',
            request_location: 'header',
            request_key: 'X-Tenant-ID',
          },
        ],
      },
    });

    await wrapper
      .find(
        'button[title="CAPTAIN.CUSTOM_TOOLS.FORM.REQUEST_TEMPLATE.PARAM_UNUSED"]'
      )
      .trigger('click');

    const requestTemplate = wrapper.find(
      '[data-label="CAPTAIN.CUSTOM_TOOLS.FORM.REQUEST_TEMPLATE.LABEL"] textarea'
    );
    expect(requestTemplate.element.value).toBe(`{
  "customer_name": {{ customer_name | json_value }}
}`);
    expect(requestTemplate.element.value).not.toContain('tenant_id');
  });
});
