import { flushPromises, mount } from '@vue/test-utils';
import { computed } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const testState = vi.hoisted(() => ({
  integration: {
    id: 'kaspi_pay',
    name: 'Kaspi Pay',
    description: 'Kaspi Pay',
    enabled: false,
    hooks: [],
  },
  dispatch: vi.fn(() => Promise.resolve()),
  alert: vi.fn(),
  api: {
    initKaspiPayAuth: vi.fn(),
    sendKaspiPayPhone: vi.fn(),
    sendKaspiPayPassword: vi.fn(),
    verifyKaspiPayOtp: vi.fn(),
  },
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: testState.dispatch }),
  useFunctionGetter: () => computed(() => testState.integration),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: testState.alert,
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/api/integrations', () => ({
  default: testState.api,
  normalizeKaspiPayCashierPhone: value => {
    const digits = String(value || '').replace(/\D/g, '');
    return digits.length === 11 && ['7', '8'].includes(digits[0])
      ? digits.slice(1)
      : digits;
  },
}));

import KaspiPay from './KaspiPay.vue';

const IntegrationStub = {
  template: '<div><slot name="action" /><slot /></div>',
};

const InputStub = {
  inheritAttrs: false,
  props: ['modelValue', 'label', 'type', 'disabled'],
  emits: ['update:modelValue', 'input'],
  template: `
    <label>
      <span>{{ label }}</span>
      <input
        v-bind="$attrs"
        :type="type || 'text'"
        :value="modelValue"
        :disabled="disabled"
        @input="$emit('update:modelValue', $event.target.value); $emit('input', $event)"
      />
    </label>
  `,
};

const ButtonStub = {
  props: ['label', 'disabled'],
  emits: ['click'],
  template:
    '<button type="button" :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
};

const mountComponent = async () => {
  const wrapper = mount(KaspiPay, {
    global: {
      mocks: { $t: key => key },
      stubs: {
        Integration: IntegrationStub,
        Input: InputStub,
        Button: ButtonStub,
        Spinner: true,
      },
    },
  });
  await flushPromises();
  return wrapper;
};

const submitPhone = async wrapper => {
  await wrapper.get('input[type="tel"]').setValue('+7 701 211 40 00');
  await wrapper.get('button').trigger('click');
  await flushPromises();
};

describe('KaspiPay authentication', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    testState.integration.enabled = false;
    testState.api.initKaspiPayAuth.mockResolvedValue({
      data: { process_id: 'flow-1', next_step: 'phone' },
    });
  });

  it('shows the password step and then advances to OTP without retaining the password', async () => {
    testState.api.sendKaspiPayPhone.mockResolvedValue({
      data: { success: true, process_id: 'flow-1', next_step: 'password' },
    });
    testState.api.sendKaspiPayPassword.mockResolvedValue({
      data: { success: true, process_id: 'flow-1', next_step: 'otp' },
    });
    const wrapper = await mountComponent();

    await submitPhone(wrapper);
    const passwordInput = wrapper.get('input[type="password"]');
    await passwordInput.setValue('cashier-password');
    await wrapper.get('button').trigger('click');
    await flushPromises();

    expect(testState.api.sendKaspiPayPassword).toHaveBeenCalledWith({
      processId: 'flow-1',
      password: 'cashier-password',
    });
    expect(wrapper.find('input[type="password"]').exists()).toBe(false);
    expect(wrapper.find('input[autocomplete="one-time-code"]').exists()).toBe(
      true
    );
  });

  it('keeps supporting the direct phone-to-OTP flow', async () => {
    testState.api.sendKaspiPayPhone.mockResolvedValue({
      data: { success: true, process_id: 'flow-1', next_step: 'otp' },
    });
    const wrapper = await mountComponent();

    await submitPhone(wrapper);

    expect(wrapper.find('input[type="password"]').exists()).toBe(false);
    expect(wrapper.find('input[autocomplete="one-time-code"]').exists()).toBe(
      true
    );
  });

  it('clears a rejected password and keeps the password step available for retry', async () => {
    testState.api.sendKaspiPayPhone.mockResolvedValue({
      data: { success: true, process_id: 'flow-1', next_step: 'password' },
    });
    testState.api.sendKaspiPayPassword.mockResolvedValue({
      data: {
        success: false,
        process_id: 'flow-1',
        next_step: 'password',
        description: 'Incorrect password',
      },
    });
    const wrapper = await mountComponent();

    await submitPhone(wrapper);
    await wrapper.get('input[type="password"]').setValue('wrong-password');
    await wrapper.get('button').trigger('click');
    await flushPromises();

    expect(wrapper.get('input[type="password"]').element.value).toBe('');
    expect(wrapper.text()).toContain('Incorrect password');
  });

  it('returns to the phone step when the account-bound auth flow expires', async () => {
    testState.api.sendKaspiPayPhone.mockResolvedValue({
      data: { success: true, process_id: 'flow-1', next_step: 'password' },
    });
    testState.api.sendKaspiPayPassword.mockRejectedValue({
      response: {
        data: {
          code: 'AUTH_FLOW_EXPIRED',
          error: 'Authentication expired',
        },
      },
    });
    const wrapper = await mountComponent();

    await submitPhone(wrapper);
    await wrapper.get('input[type="password"]').setValue('cashier-password');
    await wrapper.get('button').trigger('click');
    await flushPromises();

    expect(wrapper.find('input[type="password"]').exists()).toBe(false);
    expect(
      wrapper.get('input[type="tel"]').attributes('disabled')
    ).toBeUndefined();
    expect(wrapper.text()).toContain('Authentication expired');
  });
});
