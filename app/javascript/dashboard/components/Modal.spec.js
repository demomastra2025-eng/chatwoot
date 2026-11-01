import { flushPromises, mount } from '@vue/test-utils';
import { h, nextTick } from 'vue';
import Modal from './Modal.vue';
import ComboBox from '../components-next/combobox/ComboBox.vue';
import TagMultiSelectComboBox from '../components-next/combobox/TagMultiSelectComboBox.vue';
import SchedulingColorPicker from '../components-next/Scheduling/SchedulingColorPicker.vue';

describe('legacy Modal focus and semantics', () => {
  let wrapper;
  afterEach(() => {
    wrapper?.unmount();
    document.body.innerHTML = '';
  });

  const openModal = async (props = {}, attrs = {}) => {
    const trigger = document.createElement('button');
    document.body.append(trigger);
    trigger.focus();
    wrapper = mount(Modal, {
      attachTo: document.body,
      attrs,
      props: { show: false, showCloseButton: false, ...props },
      slots: {
        default:
          '<h2>Update contact</h2><input autofocus /><button>Save</button>',
      },
    });
    await wrapper.setProps({ show: true });
    await nextTick();
    return trigger;
  };

  it('names the dialog from its heading, focuses inside and wraps Tab in both directions', async () => {
    await openModal();
    const dialog = wrapper.get('[role="dialog"]');
    expect(dialog.attributes('aria-modal')).toBe('true');
    expect(
      wrapper.get(`[id="${dialog.attributes('aria-labelledby')}"]`).text()
    ).toBe('Update contact');
    expect(document.activeElement).toBe(wrapper.get('input').element);
    await wrapper
      .get('input')
      .trigger('keydown', { key: 'Tab', shiftKey: true });
    expect(document.activeElement).toBe(wrapper.get('button').element);
    await wrapper.get('button').trigger('keydown', { key: 'Tab' });
    expect(document.activeElement).toBe(wrapper.get('input').element);
  });

  it('restores the opener after Escape and keeps the existing close callback', async () => {
    const onClose = vi.fn();
    const trigger = await openModal({ onClose });
    await wrapper.get('input').trigger('keydown', { key: 'Escape' });
    await nextTick();
    expect(wrapper.emitted('update:show')).toEqual([[false]]);
    expect(wrapper.emitted('close')).toHaveLength(1);
    expect(onClose).toHaveBeenCalled();
    expect(document.activeElement).toBe(trigger);
  });

  it('places explicit naming attributes on the dialog and preserves overlay classes', async () => {
    await openModal(
      {},
      { 'aria-label': 'Keyboard shortcuts', class: 'consumer-class' }
    );
    expect(wrapper.get('[role="dialog"]').attributes('aria-label')).toBe(
      'Keyboard shortcuts'
    );
    expect(wrapper.get('.modal-mask').attributes('aria-label')).toBeUndefined();
    expect(wrapper.get('.modal-mask').classes()).toContain('consumer-class');
    await wrapper.setProps({ 'aria-label': 'Переключения' });
    expect(wrapper.get('[role="dialog"]').attributes('aria-label')).toBe(
      'Переключения'
    );
  });

  it('returns focus on parent-driven close and traps an empty dialog', async () => {
    const trigger = await openModal();
    await wrapper.setProps({ show: false });
    expect(document.activeElement).toBe(trigger);
    wrapper.unmount();
    wrapper = mount(Modal, {
      attachTo: document.body,
      props: { show: true, showCloseButton: false },
      attrs: { 'aria-label': 'Loading' },
    });
    await nextTick();
    const dialog = wrapper.get('[role="dialog"]');
    expect(document.activeElement).toBe(dialog.element);
    await dialog.trigger('keydown', { key: 'Tab' });
    expect(document.activeElement).toBe(dialog.element);
  });

  it.each([ComboBox, TagMultiSelectComboBox])(
    'keeps a teleported combobox search inside the modal focus scope',
    async component => {
      wrapper = mount(Modal, {
        attachTo: document.body,
        props: { show: true, showCloseButton: false },
        attrs: { 'aria-label': 'Choose an option' },
        slots: {
          default: () =>
            h(component, {
              options: [{ value: 'one', label: 'First option' }],
            }),
        },
        global: {
          stubs: { OnClickOutside: { template: '<div><slot /></div>' } },
        },
      });
      await nextTick();
      await wrapper.get('button').trigger('click');
      await nextTick();
      const search = document.querySelector(
        '.dashboard-combobox-dropdown input'
      );
      expect(search).not.toBeNull();
      expect(wrapper.get('[role="dialog"]').element.contains(search)).toBe(
        true
      );
      search.focus();
      expect(document.activeElement).toBe(search);
    }
  );

  it('keeps a Reka color popover and its selection inside the modal focus scope', async () => {
    wrapper = mount(Modal, {
      attachTo: document.body,
      props: { show: true, showCloseButton: false },
      attrs: { 'aria-label': 'Choose color' },
      slots: {
        default: () =>
          h(SchedulingColorPicker, {
            compact: true,
            triggerLabel: 'Color',
            palette: ['#2563EB'],
          }),
      },
    });
    await nextTick();
    await wrapper.get('button[aria-label="Color"]').trigger('click');
    await flushPromises();
    const paletteButton = document.querySelector(
      'button[aria-label="#2563EB"]'
    );
    expect(paletteButton).not.toBeNull();
    expect(
      wrapper.get('[data-legacy-modal]').element.contains(paletteButton)
    ).toBe(true);
    paletteButton.focus();
    expect(document.activeElement).toBe(paletteButton);
    paletteButton.click();
    await flushPromises();
    expect(
      wrapper.findComponent(SchedulingColorPicker).emitted('update:modelValue')
    ).toEqual([['#2563EB']]);
  });

  it('closes only the innermost legacy modal on Escape', async () => {
    const childClose = vi.fn();
    wrapper = mount(Modal, {
      attachTo: document.body,
      props: { show: true, showCloseButton: false },
      attrs: { 'aria-label': 'Parent' },
      slots: {
        default: () =>
          h(
            Modal,
            {
              show: true,
              showCloseButton: false,
              'aria-label': 'Child',
              onClose: childClose,
            },
            { default: () => h('button', 'Child action') }
          ),
      },
    });
    await nextTick();
    await wrapper
      .get('[aria-label="Child"] button')
      .trigger('keydown', { key: 'Escape' });
    await nextTick();
    expect(childClose).toHaveBeenCalled();
    expect(wrapper.emitted('close')).toBeUndefined();
  });

  it('skips hidden ancestors and disabled fieldsets when wrapping focus', async () => {
    wrapper = mount(Modal, {
      attachTo: document.body,
      props: { show: true, showCloseButton: false },
      attrs: { 'aria-label': 'Form' },
      slots: {
        default: `<div style="display:none"><button>Hidden by parent</button></div>
        <fieldset disabled><input /></fieldset>
        <button data-test="first">First</button>
        <div hidden><button>Hidden</button></div>
        <div inert><button>Inert</button></div>
        <div aria-hidden="true"><button>Screen reader hidden</button></div>
        <button data-test="last">Last</button>`,
      },
    });
    await nextTick();
    const first = wrapper.get('[data-test="first"]');
    const last = wrapper.get('[data-test="last"]');
    expect(document.activeElement).toBe(first.element);
    await first.trigger('keydown', { key: 'Tab', shiftKey: true });
    expect(document.activeElement).toBe(last.element);
    await last.trigger('keydown', { key: 'Tab' });
    expect(document.activeElement).toBe(first.element);
  });
});
