import { shallowMount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import CrmDealFilterChips from './CrmDealFilterChips.vue';

describe('CrmDealFilterChips', () => {
  it('removes only the selected filter or requests a full reset', async () => {
    const wrapper = shallowMount(CrmDealFilterChips, {
      props: {
        chips: [
          { key: 'ownerId', label: 'Ответственный: Иван' },
          { key: 'stageId', label: 'Этап: Новый' },
        ],
      },
      global: { mocks: { $t: key => key } },
    });

    const buttons = wrapper.findAll('[data-test="active-deal-filters"] button');
    expect(buttons).toHaveLength(3);
    await buttons[0].trigger('click');
    expect(wrapper.emitted('remove')).toEqual([['ownerId']]);
    expect(wrapper.emitted('reset')).toBeUndefined();

    await wrapper.find('[data-test="reset-deal-filters"]').trigger('click');
    expect(wrapper.emitted('reset')).toHaveLength(1);
  });
});
