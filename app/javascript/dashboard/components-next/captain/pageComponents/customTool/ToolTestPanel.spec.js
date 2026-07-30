import { config, flushPromises, shallowMount } from '@vue/test-utils';
import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest';

import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import ToolTestPanel from './ToolTestPanel.vue';

const mocks = vi.hoisted(() => ({
  dispatch: vi.fn(),
  alert: vi.fn(),
  confirm: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, values) => (values ? `${key}:${JSON.stringify(values)}` : key),
  }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
  useMapGetter: () => ({
    value: {
      previewingTool: false,
      testingTool: false,
    },
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: (...args) => mocks.alert(...args),
}));

const customTool = {
  title: 'Search contacts',
  group_name: 'CRM',
  description: 'Searches contacts',
  endpoint_url: 'https://api.example.com/contacts',
  http_method: 'GET',
  request_template: '',
  response_template: '',
  auth_type: 'none',
  auth_config: {},
  allow_file_artifacts: true,
  request_body_type: 'json',
  http_options: {},
  param_schema: [],
};

const previousConfirmModalStub = config.global.stubs['woot-confirm-modal'];
config.global.stubs['woot-confirm-modal'] = {
  props: ['description'],
  template: '<div />',
  methods: {
    showConfirmation() {
      return mocks.confirm(this.description);
    },
  },
};

afterAll(() => {
  if (previousConfirmModalStub) {
    config.global.stubs['woot-confirm-modal'] = previousConfirmModalStub;
  } else {
    delete config.global.stubs['woot-confirm-modal'];
  }
});

describe('ToolTestPanel', () => {
  beforeEach(() => {
    mocks.dispatch.mockReset();
    mocks.alert.mockReset();
    mocks.confirm.mockReset();
    mocks.dispatch.mockResolvedValue({
      preview: { url: customTool.endpoint_url, body: null },
      response: { successful: true, status: 200, body: '{}' },
    });
  });

  it('dispatches a real test request for an unsaved custom-tool draft', async () => {
    const validateBeforeRun = vi.fn().mockResolvedValue(true);
    const wrapper = shallowMount(ToolTestPanel, {
      props: {
        customTool,
        validateBeforeRun,
      },
    });

    const buttons = wrapper.findAllComponents(Button);
    await buttons[1].trigger('click');
    await flushPromises();

    expect(validateBeforeRun).toHaveBeenCalledOnce();
    expect(mocks.dispatch).toHaveBeenCalledWith('captainCustomTools/testTool', {
      customTool,
      testPayload: {
        agent_params: {},
        context_values: {},
      },
    });
  });

  it('includes the selected request body type in an unsaved draft test', async () => {
    const formUrlencodedTool = {
      ...customTool,
      http_method: 'POST',
      request_body_type: 'form_urlencoded',
      request_template: '{"name":"{{ name }}"}',
    };
    const wrapper = shallowMount(ToolTestPanel, {
      props: {
        customTool: formUrlencodedTool,
        validateBeforeRun: vi.fn().mockResolvedValue(true),
      },
    });

    const buttons = wrapper.findAllComponents(Button);
    await buttons[1].trigger('click');
    await flushPromises();

    expect(mocks.dispatch).toHaveBeenCalledWith('captainCustomTools/testTool', {
      customTool: formUrlencodedTool,
      testPayload: {
        agent_params: {},
        context_values: {},
      },
    });
  });

  it('runs the real request before create and reuses an unchanged successful test', async () => {
    const validateBeforeRun = vi.fn().mockResolvedValue(true);
    const wrapper = shallowMount(ToolTestPanel, {
      props: {
        customTool,
        validateBeforeRun,
      },
    });

    const firstResult = await wrapper.vm.runTestForCreate();
    const secondResult = await wrapper.vm.runTestForCreate();

    expect(firstResult.response.successful).toBe(true);
    expect(secondResult.response.successful).toBe(true);
    expect(mocks.dispatch).toHaveBeenCalledOnce();
  });

  it('invalidates a successful test when advanced HTTP options change', async () => {
    const wrapper = shallowMount(ToolTestPanel, {
      props: {
        customTool,
        validateBeforeRun: vi.fn().mockResolvedValue(true),
      },
    });

    await wrapper.vm.runTestForCreate();
    const httpOptions = {
      timeout: { open_seconds: 5, read_seconds: 45 },
    };
    await wrapper.setProps({
      customTool: { ...customTool, http_options: httpOptions },
    });
    await wrapper.vm.runTestForCreate();

    expect(mocks.dispatch).toHaveBeenCalledTimes(2);
    expect(mocks.dispatch).toHaveBeenLastCalledWith(
      'captainCustomTools/testTool',
      expect.objectContaining({
        customTool: expect.objectContaining({ http_options: httpOptions }),
      })
    );
  });

  it('requires explicit confirmation before a mutating multi-request test', async () => {
    const confirmModalStub = {
      props: ['description'],
      template: '<div />',
      methods: {
        showConfirmation() {
          return mocks.confirm(this.description);
        },
      },
    };
    const wrapper = shallowMount(ToolTestPanel, {
      props: {
        customTool: {
          ...customTool,
          http_method: 'POST',
          http_options: {
            retry: { enabled: true, max_attempts: 3 },
            redirects: { enabled: true, max_redirects: 2 },
            idempotency: { enabled: true },
          },
        },
        validateBeforeRun: vi.fn().mockResolvedValue(true),
      },
      global: {
        stubs: {
          'woot-confirm-modal': confirmModalStub,
        },
      },
    });
    mocks.confirm.mockResolvedValueOnce(false);

    const cancelledResult = await wrapper.vm.runTestForCreate();

    expect(cancelledResult).toBeNull();
    expect(mocks.dispatch).not.toHaveBeenCalled();
    expect(mocks.confirm).toHaveBeenCalledWith(
      expect.stringContaining(
        '"logicalRequests":1,"attempts":3,"redirectHops":3,"requests":9'
      )
    );

    mocks.confirm.mockResolvedValueOnce(true);
    const confirmedResult = await wrapper.vm.runTestForCreate();

    expect(confirmedResult.response.successful).toBe(true);
    expect(mocks.dispatch).toHaveBeenCalledOnce();
  });

  it('rejects invalid boolean sample values before sending a request', async () => {
    const validateBeforeRun = vi.fn().mockResolvedValue(true);
    const wrapper = shallowMount(ToolTestPanel, {
      props: {
        customTool: {
          ...customTool,
          param_schema: [
            {
              name: 'include_archived',
              type: 'boolean',
              description: 'Whether archived contacts should be included',
              source: 'agent',
            },
          ],
        },
        validateBeforeRun,
      },
    });
    await wrapper
      .findComponent(Input)
      .vm.$emit('update:modelValue', 'not-a-boolean');

    const buttons = wrapper.findAllComponents(Button);
    await buttons[1].trigger('click');
    await flushPromises();

    expect(mocks.dispatch).not.toHaveBeenCalled();
    expect(mocks.alert).toHaveBeenCalledWith(
      'CAPTAIN.CUSTOM_TOOLS.FORM.TEST_PANEL.INPUT.ERRORS.FIX_ERRORS'
    );
  });
});
