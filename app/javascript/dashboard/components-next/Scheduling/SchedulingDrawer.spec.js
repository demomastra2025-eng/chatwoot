import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import SchedulingDrawer from './SchedulingDrawer.vue';

const mountDrawer = props =>
  mount(SchedulingDrawer, {
    props: {
      modelValue: true,
      title: 'Appointment',
      ...props,
    },
    global: {
      stubs: {
        Button: true,
        OnClickOutside: {
          template: '<div><slot /></div>',
        },
        Teleport: true,
        Transition: false,
      },
    },
    slots: {
      default: '<div data-testid="drawer-content">Content</div>',
      footer: '<div data-testid="drawer-footer">Footer</div>',
    },
  });

describe('SchedulingDrawer', () => {
  it('keeps the default right-side drawer layout', () => {
    const wrapper = mountDrawer();

    expect(wrapper.html()).toContain('flex justify-end');
    expect(wrapper.find('[data-testid="drawer-content"]').exists()).toBe(true);
  });

  it('supports centered modal layout and custom body/content classes', () => {
    const wrapper = mountDrawer({
      bodyClass: '!overflow-hidden',
      contentClass: 'flex h-full min-h-0 p-0',
      panelClass: '!max-w-[min(96rem,calc(100vw-1.5rem))]',
      placement: 'center',
    });

    expect(wrapper.html()).toContain('items-center justify-center');
    expect(wrapper.html()).toContain('!overflow-hidden');
    expect(wrapper.html()).toContain('flex h-full min-h-0 p-0');
    expect(wrapper.html()).toContain('!max-w-[min(96rem,calc(100vw-1.5rem))]');
  });
});
