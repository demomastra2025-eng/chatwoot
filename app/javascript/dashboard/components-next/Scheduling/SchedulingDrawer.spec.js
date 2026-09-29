import { mount } from '@vue/test-utils';
import { nextTick } from 'vue';
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

  it('renders without the OnClickOutside component and closes from outside', async () => {
    const wrapper = mountDrawer();

    expect(wrapper.findComponent({ name: 'OnClickOutside' }).exists()).toBe(
      false
    );

    document.body.dispatchEvent(new Event('pointerdown', { bubbles: true }));
    document.body.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await nextTick();

    expect(wrapper.emitted('update:modelValue')).toContainEqual([false]);
  });

  describe('outside clicks', () => {
    const clickElement = element => {
      element.dispatchEvent(new Event('pointerdown', { bubbles: true }));
      element.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    };

    const mountAttachedDrawer = props =>
      mount(SchedulingDrawer, {
        attachTo: document.body,
        props: { modelValue: true, title: 'Task', ...props },
        global: {
          stubs: { Button: true, Teleport: true, Transition: false },
        },
        slots: { default: '<input data-testid="drawer-input" />' },
      });

    const drawerElements = wrapper => {
      const panel = wrapper.find('[role="dialog"]').element;
      const backdrop = panel.parentElement;
      return { backdrop, overlay: backdrop.parentElement, panel };
    };

    it('keeps the drawer open when the dimmed backdrop next to the panel is clicked', async () => {
      const wrapper = mountAttachedDrawer();
      await nextTick();
      const { backdrop, panel } = drawerElements(wrapper);

      expect(backdrop.className).toContain('flex h-full w-full');
      clickElement(backdrop);
      clickElement(panel);
      clickElement(wrapper.find('[data-testid="drawer-input"]').element);
      await nextTick();

      expect(wrapper.emitted('update:modelValue')).toBeUndefined();
      wrapper.unmount();
    });

    it('closes when the click lands past the backdrop on the overlay edge', async () => {
      const wrapper = mountAttachedDrawer();
      await nextTick();

      clickElement(drawerElements(wrapper).overlay);
      await nextTick();

      expect(wrapper.emitted('update:modelValue')).toEqual([[false]]);
      expect(wrapper.emitted('close')).toHaveLength(1);
      wrapper.unmount();
    });

    it('stays open on outside clicks when closeOnOutside is false', async () => {
      const wrapper = mountAttachedDrawer({ closeOnOutside: false });
      await nextTick();

      clickElement(drawerElements(wrapper).overlay);
      clickElement(document.body);
      await nextTick();

      expect(wrapper.emitted('update:modelValue')).toBeUndefined();
      wrapper.unmount();
    });

    it('does not let a backdrop press take focus out of the dialog', async () => {
      const wrapper = mountAttachedDrawer();
      await nextTick();
      const { backdrop, panel } = drawerElements(wrapper);
      const pressElement = element => {
        const event = new MouseEvent('mousedown', {
          bubbles: true,
          cancelable: true,
        });
        element.dispatchEvent(event);
        return event.defaultPrevented;
      };

      expect(document.activeElement).toBe(panel);
      expect(pressElement(backdrop)).toBe(true);
      expect(
        pressElement(wrapper.find('[data-testid="drawer-input"]').element)
      ).toBe(false);

      await wrapper.find('[role="dialog"]').trigger('keydown', {
        key: 'Escape',
      });
      expect(wrapper.emitted('update:modelValue')).toEqual([[false]]);
      wrapper.unmount();
    });
  });

  it('moves focus into the dialog, traps it, and restores the trigger', async () => {
    const trigger = document.createElement('button');
    document.body.appendChild(trigger);
    trigger.focus();

    const wrapper = mount(SchedulingDrawer, {
      attachTo: document.body,
      props: {
        modelValue: false,
        title: 'Appointment',
      },
      global: {
        stubs: {
          Button: true,
          Teleport: true,
          Transition: false,
        },
      },
      slots: {
        default: '<input data-testid="drawer-input" />',
      },
    });

    await wrapper.setProps({ modelValue: true });
    await nextTick();

    const dialog = wrapper.find('[role="dialog"]');
    const input = wrapper.find('[data-testid="drawer-input"]');
    input.element.getClientRects = () => [{}];
    expect(dialog.attributes('aria-modal')).toBe('true');
    expect(document.activeElement).toBe(dialog.element);

    await dialog.trigger('keydown', { key: 'Tab' });
    expect(document.activeElement).toBe(input.element);

    await wrapper.setProps({ modelValue: false });
    await nextTick();
    expect(document.activeElement).toBe(trigger);

    wrapper.unmount();
    trigger.remove();
  });

  it('skips hidden and aria-disabled controls while trapping focus', async () => {
    const wrapper = mount(SchedulingDrawer, {
      attachTo: document.body,
      props: { modelValue: true, title: 'Appointment' },
      global: {
        stubs: { Button: true, Teleport: true, Transition: false },
      },
      slots: {
        default: `
          <div hidden><button data-testid="hidden-control">Hidden</button></div>
          <button data-testid="disabled-control" aria-disabled="true">Disabled</button>
          <button data-testid="visible-control">Visible</button>
        `,
      },
    });
    await nextTick();

    const dialog = wrapper.find('[role="dialog"]');
    wrapper.findAll('button').forEach(button => {
      button.element.getClientRects = () => [{}];
    });
    await dialog.trigger('keydown', { key: 'Tab' });

    expect(document.activeElement).toBe(
      wrapper.find('[data-testid="visible-control"]').element
    );
    wrapper.unmount();
  });

  it('restores the opener when the drawer unmounts during close', async () => {
    const trigger = document.createElement('button');
    document.body.appendChild(trigger);
    trigger.focus();
    const wrapper = mount(SchedulingDrawer, {
      attachTo: document.body,
      props: { modelValue: true, title: 'Appointment' },
      global: {
        stubs: { Button: true, Teleport: true, Transition: false },
      },
    });
    await nextTick();

    wrapper.setProps({ modelValue: false });
    wrapper.unmount();

    expect(document.activeElement).toBe(trigger);
    trigger.remove();
  });

  it('closes only the drawer whose panel receives Escape', async () => {
    const mountOpenDrawer = () =>
      mount(SchedulingDrawer, {
        attachTo: document.body,
        props: { modelValue: true, title: 'Appointment' },
        global: {
          stubs: { Button: true, Teleport: true, Transition: false },
        },
      });
    const parentDrawer = mountOpenDrawer();
    const childDrawer = mountOpenDrawer();
    await nextTick();

    await childDrawer.find('[role="dialog"]').trigger('keydown', {
      key: 'Escape',
    });

    expect(childDrawer.emitted('update:modelValue')).toEqual([[false]]);
    expect(parentDrawer.emitted('update:modelValue')).toBeUndefined();
    childDrawer.unmount();
    parentDrawer.unmount();
  });
});
