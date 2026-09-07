import { shallowMount } from '@vue/test-utils';

import CrmPageSkeleton from './CrmPageSkeleton.vue';

const mountComponent = props =>
  shallowMount(CrmPageSkeleton, {
    props,
  });

describe('CrmPageSkeleton', () => {
  it.each(['board', 'calendar', 'list'])(
    'renders the %s presentation placeholder',
    presentation => {
      const wrapper = mountComponent({ presentation });

      expect(
        wrapper.get('[data-test="crm-page-skeleton"]').attributes()
      ).toMatchObject({
        'aria-hidden': 'true',
        'data-presentation': presentation,
      });
    }
  );

  it('bounds the number of board columns', () => {
    const wrapper = mountComponent({ columnCount: 20, presentation: 'board' });

    expect(wrapper.findAll('section')).toHaveLength(6);
  });
});
