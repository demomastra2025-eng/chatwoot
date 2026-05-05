import { describe, expect, it } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import AutomationTouchInput from './AutomationTouchInput.vue';

const mountComponent = props =>
  shallowMount(AutomationTouchInput, {
    props: {
      eventName: 'message_created',
      modelValue: {},
      ...props,
    },
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        WootMessageEditor: true,
        NextInput: true,
        NextSwitch: true,
      },
    },
  });

describe('AutomationTouchInput', () => {
  it('defaults new automation touches to not auto-cancel unless explicitly enabled', () => {
    const wrapper = mountComponent();

    expect(wrapper.vm.normalizedValue.auto_cancel_on_incoming).toBe(false);
    expect(wrapper.vm.autoCancelOnIncoming).toBe(false);
  });

  it('preserves an explicit auto-cancel choice from existing action params', () => {
    const wrapper = mountComponent({
      modelValue: [
        { body: 'Follow up', delay_minutes: 15, auto_cancel_on_incoming: true },
      ],
    });

    expect(wrapper.vm.normalizedValue.auto_cancel_on_incoming).toBe(true);
  });
});
