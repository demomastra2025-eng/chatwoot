import { mount } from '@vue/test-utils';
import DsCard from '../DsCard.vue';

describe('DsCard', () => {
  it('renders the title, subtitle, actions and body', () => {
    const wrapper = mount(DsCard, {
      props: { title: 'Calls', subtitle: 'per day' },
      slots: { default: '<p>Body</p>', actions: '<button>Act</button>' },
    });

    expect(wrapper.find('h3').text()).toBe('Calls');
    expect(wrapper.text()).toContain('per day');
    expect(wrapper.find('header button').text()).toBe('Act');
    expect(wrapper.text()).toContain('Body');
  });

  it('uses the card radius, a hairline border and no shadow', () => {
    const wrapper = mount(DsCard, { slots: { default: 'x' } });
    const classes = wrapper.classes();

    expect(classes).toContain('rounded-ds-card');
    expect(classes).toContain('border-n-weak');
    expect(classes).toContain('bg-n-solid-2');
    expect(classes.some(name => name.startsWith('shadow'))).toBe(false);
    expect(wrapper.find('header').exists()).toBe(false);
  });

  it('lets the body span edge to edge when not padded', () => {
    const padded = mount(DsCard, { props: { title: 'A' } });
    const flush = mount(DsCard, { props: { title: 'A', padded: false } });

    expect(padded.find('header + div').classes()).toContain('px-5');
    expect(flush.find('header + div').classes()).not.toContain('px-5');
  });

  it('renders as the requested element', () => {
    const wrapper = mount(DsCard, { props: { as: 'figure' } });
    expect(wrapper.element.tagName).toBe('FIGURE');
  });
});
