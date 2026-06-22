import { flushPromises, mount } from '@vue/test-utils';

import FonosterRoutingForm from './FonosterRoutingForm.vue';

const alertMock = vi.hoisted(() => vi.fn());
const dispatchMock = vi.hoisted(() => vi.fn());
const updateNumberRouteMock = vi.hoisted(() => vi.fn());

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: alertMock,
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({
    dispatch: dispatchMock,
  }),
}));

vi.mock('dashboard/api/channel/voice/voiceAPIClient', () => ({
  default: {
    updateNumberRoute: updateNumberRouteMock,
  },
}));

const SelectStub = {
  props: ['modelValue', 'options', 'disabled'],
  emits: ['update:modelValue'],
  template: `
    <select
      :value="modelValue"
      :disabled="disabled"
      @change="$emit('update:modelValue', $event.target.value)"
    >
      <option
        v-for="option in options"
        :key="option.value"
        :value="option.value"
      >
        {{ option.label }}
      </option>
    </select>
  `,
};

const InputStub = {
  props: ['modelValue', 'label', 'disabled'],
  emits: ['update:modelValue'],
  template: `
    <label>
      {{ label }}
      <input
        :value="modelValue"
        :disabled="disabled"
        @input="$emit('update:modelValue', $event.target.value)"
      />
    </label>
  `,
};

const ButtonStub = {
  props: ['disabled', 'label'],
  template: '<button type="submit" :disabled="disabled">{{ label }}</button>',
};

const buildWrapper = inbox =>
  mount(FonosterRoutingForm, {
    props: { inbox },
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        Select: SelectStub,
        Input: InputStub,
        Button: ButtonStub,
      },
    },
  });

describe('FonosterRoutingForm', () => {
  beforeEach(() => {
    alertMock.mockReset();
    dispatchMock.mockReset();
    updateNumberRouteMock.mockReset();
    dispatchMock.mockResolvedValue({});
    updateNumberRouteMock.mockResolvedValue({ payload: {} });
  });

  it('clears stale operator target fields when saving broadcast operator distribution', async () => {
    const wrapper = buildWrapper({
      telephony: {
        number_ref: 'number-ref',
        app_ref: 'runtime-app-ref',
        routing_policy: {
          mode: 'operator',
          operator_agent_ref: 'stale-agent-ref',
          operator_agent_aor: 'sip:stale-target@example.test',
          operator_distribution_mode: 'broadcast',
          fallback_mode: 'reject',
        },
      },
    });

    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(updateNumberRouteMock).toHaveBeenCalledWith('number-ref', {
      mode: 'operator',
      app_ref: 'runtime-app-ref',
      ai_app_ref: null,
      operator_agent_ref: null,
      operator_agent_aor: null,
      operator_distribution_mode: 'broadcast',
      fallback_mode: 'reject',
      fallback_message: null,
    });
    expect(dispatchMock).toHaveBeenCalledWith('inboxes/get');
  });
});
