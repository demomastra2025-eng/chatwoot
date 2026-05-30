import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import AddLabel from './AddLabel.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

const labelMenuItems = [
  {
    label: 'VIP',
    value: 1,
    thumbnail: { name: 'VIP', color: '#F59E0B' },
    isSelected: false,
  },
];

const mountComponent = props =>
  mount(AddLabel, {
    props: {
      labelMenuItems,
      allowManagement: true,
      ...props,
    },
    global: {
      directives: {
        'on-clickaway': {},
        onClickaway: {},
      },
    },
  });

describe('AddLabel', () => {
  it('renders label edit action as a visible touch target', async () => {
    const wrapper = mountComponent();

    await wrapper.find('button').trigger('click');

    const editButton = wrapper.find(
      'button[aria-label="LABEL_MGMT.FORM.EDIT"]'
    );
    expect(editButton.exists()).toBe(true);
    expect(editButton.classes()).toContain('size-8');
    expect(editButton.classes()).toContain('text-n-slate-11');
    expect(editButton.classes()).not.toContain('md:opacity-0');

    const editIcon = editButton.find('span');
    expect(editIcon.classes()).toContain('i-ph-pencil-simple');
    expect(editIcon.classes()).toContain('size-5');
  });

  it('emits editLabel when the management action is clicked', async () => {
    const wrapper = mountComponent();

    await wrapper.find('button').trigger('click');
    await wrapper
      .find('button[aria-label="LABEL_MGMT.FORM.EDIT"]')
      .trigger('click');

    expect(wrapper.emitted('editLabel')?.[0]).toEqual([labelMenuItems[0]]);
  });
});
