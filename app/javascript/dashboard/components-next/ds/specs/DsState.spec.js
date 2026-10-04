import { mount } from '@vue/test-utils';
import DsState from '../DsState.vue';

describe('DsState', () => {
  it('shows the default empty texts', () => {
    const wrapper = mount(DsState);

    expect(wrapper.attributes('role')).toBe('status');
    expect(wrapper.text()).toContain('No data yet');
    expect(wrapper.text()).toContain('Data will appear here');
  });

  it('shows a spinner while loading', () => {
    const wrapper = mount(DsState, { props: { state: 'loading' } });

    expect(wrapper.find('svg.animate-spin').exists()).toBe(true);
    expect(wrapper.attributes('aria-busy')).toBe('true');
    expect(wrapper.text()).toBe('Loading…');
  });

  it('shows the error as dot + word and emits retry', async () => {
    const wrapper = mount(DsState, { props: { state: 'error' } });

    expect(wrapper.attributes('role')).toBe('alert');
    expect(wrapper.find('.bg-n-status-bad').exists()).toBe(true);
    expect(wrapper.text()).toContain('Could not load the data');

    await wrapper.find('button').trigger('click');
    expect(wrapper.emitted('retry')).toHaveLength(1);
  });

  it('accepts custom texts and can drop the description', () => {
    const wrapper = mount(DsState, {
      props: { title: 'Nothing here', description: '', retryable: false },
    });

    expect(wrapper.text()).toBe('Nothing here');
  });

  it('hides retry when not retryable', () => {
    const wrapper = mount(DsState, {
      props: { state: 'error', retryable: false },
    });
    expect(wrapper.find('button').exists()).toBe(false);
  });
});
