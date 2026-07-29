import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';

import ToolsDropdown from './ToolsDropdown.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('dashboard/components-next/TeleportWithDirection.vue', () => ({
  default: defineComponent({
    name: 'TeleportWithDirection',
    setup(_props, { slots }) {
      return () => h('div', slots.default?.());
    },
  }),
}));

const items = [
  {
    id: 'contact.name',
    title: 'Contact name',
    description: 'Contact full name',
  },
];

const mountDropdown = (props = {}) =>
  mount(ToolsDropdown, {
    props: {
      items,
      ...props,
    },
  });

let showModalMock;
let closeMock;
let scrollIntoViewMock;

beforeEach(() => {
  showModalMock = vi.fn(function showModal() {
    this.setAttribute('open', '');
  });
  closeMock = vi.fn(function close() {
    this.removeAttribute('open');
  });
  scrollIntoViewMock = vi.fn();
  Object.defineProperty(window.HTMLDialogElement.prototype, 'showModal', {
    configurable: true,
    value: showModalMock,
  });
  Object.defineProperty(window.HTMLDialogElement.prototype, 'close', {
    configurable: true,
    value: closeMock,
  });
  Object.defineProperty(window.Element.prototype, 'scrollIntoView', {
    configurable: true,
    value: scrollIntoViewMock,
  });
});

afterEach(() => {
  delete window.HTMLDialogElement.prototype.showModal;
  delete window.HTMLDialogElement.prototype.close;
  delete window.Element.prototype.scrollIntoView;
});

describe('ToolsDropdown', () => {
  it('opens overlay mode as a native modal dialog in the browser top layer', async () => {
    const wrapper = mountDropdown({ overlay: true });

    await flushPromises();

    expect(wrapper.find('dialog').exists()).toBe(true);
    expect(showModalMock).toHaveBeenCalledOnce();
    expect(wrapper.find('dialog').attributes('open')).toBeDefined();
  });

  it('closes the native dialog and emits close on cancel', async () => {
    const wrapper = mountDropdown({ overlay: true });
    await flushPromises();

    await wrapper.find('dialog').trigger('cancel');

    expect(closeMock).toHaveBeenCalledOnce();
    expect(wrapper.emitted('close')).toHaveLength(1);
  });

  it('closes the native dialog when the overlay surface is clicked', async () => {
    const wrapper = mountDropdown({ overlay: true });
    await flushPromises();

    await wrapper
      .find('[data-test-id="tools-dropdown-overlay"]')
      .trigger('click');

    expect(closeMock).toHaveBeenCalledOnce();
    expect(wrapper.emitted('close')).toHaveLength(1);
  });

  it('keeps inline mode out of the native dialog top layer', async () => {
    const wrapper = mountDropdown();
    await flushPromises();

    expect(wrapper.find('dialog').exists()).toBe(false);
    expect(showModalMock).not.toHaveBeenCalled();
  });
});
