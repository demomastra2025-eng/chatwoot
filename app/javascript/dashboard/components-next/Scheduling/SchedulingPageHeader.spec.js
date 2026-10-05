import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import SchedulingPageHeader from './SchedulingPageHeader.vue';

describe('SchedulingPageHeader', () => {
  it('renders the title prop in a heading by default', () => {
    const wrapper = mount(SchedulingPageHeader, {
      props: { title: 'Sales' },
    });

    expect(wrapper.get('h1').text()).toBe('Sales');
  });

  it('replaces the default heading with the title slot', () => {
    const wrapper = mount(SchedulingPageHeader, {
      props: { title: 'Sales' },
      slots: {
        title: '<div data-testid="pipeline-switcher">Pipeline switcher</div>',
      },
    });

    expect(wrapper.find('h1').exists()).toBe(false);
    expect(wrapper.get('[data-testid="pipeline-switcher"]').text()).toBe(
      'Pipeline switcher'
    );
  });

  it('applies the layout class props to the matching sections', () => {
    const wrapper = mount(SchedulingPageHeader, {
      props: {
        actionsClass: 'actions-extra',
        centerClass: 'center-extra',
        contentClass: 'content-extra',
        title: 'Sales',
        titleClass: 'title-extra',
      },
      slots: {
        actions: '<button type="button">Action</button>',
        center: '<span>Search</span>',
      },
    });

    expect(wrapper.find('.content-extra').exists()).toBe(true);
    expect(wrapper.find('.title-extra').exists()).toBe(true);
    expect(wrapper.find('.center-extra').text()).toBe('Search');
    expect(wrapper.find('.actions-extra').text()).toBe('Action');
  });
});
