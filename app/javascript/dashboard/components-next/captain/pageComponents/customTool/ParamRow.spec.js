import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import ParamRow from './ParamRow.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

const buildWrapper = props =>
  shallowMount(ParamRow, {
    props: {
      name: 'customer_id',
      type: 'string',
      description: '',
      required: false,
      source: 'agent',
      contextPath: '',
      fixedValue: '',
      requestLocation: 'template',
      requestKey: '',
      allParamNames: ['customer_id'],
      contextFieldOptions: [],
      ...props,
    },
  });

describe('ParamRow', () => {
  it('requires descriptions for agent-provided parameters', () => {
    const wrapper = buildWrapper();

    expect(wrapper.vm.validate()).toBe(false);
  });

  it('allows system-context parameters without descriptions', () => {
    const wrapper = buildWrapper({
      source: 'context',
      contextPath: 'contact.id',
    });

    expect(wrapper.vm.validate()).toBe(true);
  });

  it('allows fixed parameters without descriptions', () => {
    const wrapper = buildWrapper({
      source: 'fixed',
      fixedValue: 'tenant-42',
    });

    expect(wrapper.vm.validate()).toBe(true);
  });
});
