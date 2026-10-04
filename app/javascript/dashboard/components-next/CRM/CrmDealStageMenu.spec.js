import { shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { useI18n } from 'vue-i18n';

import CrmDealStageMenu from './CrmDealStageMenu.vue';

vi.mock('vue-i18n');

const stages = [{ id: 1, name: 'Qualification', color: '#2563eb' }];

const mountMenu = (displayVariant = 'dot') =>
  shallowMount(CrmDealStageMenu, {
    global: {
      stubs: {
        Button: { template: '<button><slot /></button>' },
        OnClickOutside: { template: '<div><slot /></div>' },
        Teleport: true,
      },
    },
    props: {
      displayVariant,
      modelValue: 1,
      stages,
    },
  });

describe('CrmDealStageMenu', () => {
  beforeEach(() => {
    useI18n.mockReturnValue({ t: vi.fn(key => key) });
  });

  it('keeps the dot presentation as the default', () => {
    const wrapper = mountMenu();

    expect(wrapper.find('.rounded-full').exists()).toBe(true);
    expect(wrapper.get('button').attributes('style')).toBe(undefined);
  });

  it('renders a rectangular color strip without a dot in list mode', () => {
    const wrapper = mountMenu('list');
    const button = wrapper.get('button');

    expect(wrapper.find('.rounded-full').exists()).toBe(false);
    expect(button.attributes('class')).toContain('!rounded-md');
    expect(button.attributes('style')).toContain(
      'background-color: rgb(193, 224, 253)'
    );
    expect(button.attributes('style')).toContain(
      'border-left-color: color-mix(in srgb, rgb(193, 224, 253) 70%, rgb(100, 116, 139))'
    );
  });
});
