import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import CrmCustomFieldDescriptionHint from '../CrmCustomFieldDescriptionHint.vue';

describe('CrmCustomFieldDescriptionHint', () => {
  it('renders an unobtrusive accessible description hint', () => {
    const wrapper = mount(CrmCustomFieldDescriptionHint, {
      props: {
        description: 'Shown on hover',
        label: 'Customer tier',
      },
    });

    const button = wrapper.get('button');

    expect(button.attributes('type')).toBe('button');
    expect(button.attributes('aria-label')).toBe(
      'Customer tier: Shown on hover'
    );
    expect(button.classes()).toContain('opacity-50');
    expect(wrapper.get('.i-lucide-circle-question-mark')).toBeTruthy();
    expect(wrapper.text()).not.toContain('Shown on hover');
  });
});
