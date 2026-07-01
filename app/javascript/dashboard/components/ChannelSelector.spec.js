import { mount } from '@vue/test-utils';

import ChannelSelector from './ChannelSelector.vue';

describe('ChannelSelector', () => {
  const mountSelector = props =>
    mount(ChannelSelector, {
      props: {
        title: 'Sipuni',
        description: 'Provider',
        icon: 'i-test-provider',
        ...props,
      },
      global: {
        stubs: {
          Icon: {
            props: ['icon'],
            template: '<span data-test-id="channel-selector-icon" />',
          },
        },
      },
    });

  it('renders an image instead of the icon when imageUrl is present', () => {
    const wrapper = mountSelector({
      imageUrl: '/integrations/channels/badges/sipuni.png',
    });
    const image = wrapper.find('img');

    expect(image.exists()).toBe(true);
    expect(image.attributes('src')).toBe(
      '/integrations/channels/badges/sipuni.png'
    );
    expect(
      wrapper.find('[data-test-id="channel-selector-icon"]').exists()
    ).toBe(false);
  });
});
