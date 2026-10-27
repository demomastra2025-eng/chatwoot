import { flushPromises, shallowMount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const openPersonDialog = vi.hoisted(() => vi.fn());
const searchContacts = vi.hoisted(() => vi.fn());
const createNewContact = vi.hoisted(() => vi.fn());

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('@vueuse/core', () => ({
  useWindowSize: () => ({ width: { value: 1440 } }),
}));

vi.mock('@chatwoot/utils', () => ({
  // no waiting in the spec: the search runs at once
  debounce: fn => fn,
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));

vi.mock('dashboard/composables/useOpenPersonDialog', () => ({
  useOpenPersonDialog: () => ({ openPersonDialog }),
}));

vi.mock(
  'dashboard/components-next/NewConversation/helpers/composeConversationHelper',
  () => ({
    createContactSearcher: () => searchContacts,
    createNewContact,
  })
);

import ComposeConversation from './ComposeConversation.vue';

const ContactSelectorStub = {
  props: ['contacts', 'isCreatingContact'],
  emits: ['searchContacts', 'setSelectedContact'],
  template: '<div data-test="contact-selector" />',
};

const mountPicker = (props = {}) =>
  shallowMount(ComposeConversation, {
    props,
    global: {
      directives: { 'on-click-outside': {} },
      stubs: { ContactSelector: ContactSelectorStub },
    },
    slots: {
      trigger: `<template #trigger="{ toggle }"><button data-test="trigger" @click="toggle" /></template>`,
    },
  });

describe('ComposeConversation (the picker of «Новое сообщение»)', () => {
  beforeEach(() => {
    openPersonDialog.mockReset();
    searchContacts.mockReset();
    createNewContact.mockReset();
  });

  it('is closed until its trigger is pressed', async () => {
    const wrapper = mountPicker();

    expect(wrapper.find('[data-test="contact-selector"]').exists()).toBe(false);

    await wrapper.find('[data-test="trigger"]').trigger('click');

    expect(wrapper.find('[data-test="contact-selector"]').exists()).toBe(true);
  });

  it('finds the contacts of a query', async () => {
    searchContacts.mockResolvedValue([{ id: 7, name: 'Aigul' }]);
    const wrapper = mountPicker();
    await wrapper.find('[data-test="trigger"]').trigger('click');

    wrapper
      .findComponent(ContactSelectorStub)
      .vm.$emit('searchContacts', 'Aig');
    await flushPromises();

    expect(searchContacts).toHaveBeenCalledWith('Aig');
    expect(
      wrapper.findComponent(ContactSelectorStub).props('contacts')
    ).toEqual([{ id: 7, name: 'Aigul' }]);
  });

  it('opens the dialog of the chosen person and closes; it creates no conversation', async () => {
    const wrapper = mountPicker();
    await wrapper.find('[data-test="trigger"]').trigger('click');

    wrapper.findComponent(ContactSelectorStub).vm.$emit('setSelectedContact', {
      id: 7,
      name: 'Aigul',
      action: 'contact',
    });
    await flushPromises();

    expect(openPersonDialog).toHaveBeenCalledWith(7);
    expect(wrapper.find('[data-test="contact-selector"]').exists()).toBe(false);
    expect(wrapper.emitted('close')).toHaveLength(1);
  });

  it('creates a contact from a typed number and opens their dialog', async () => {
    createNewContact.mockResolvedValue({ id: 11, name: '77011234567' });
    const wrapper = mountPicker();
    await wrapper.find('[data-test="trigger"]').trigger('click');

    wrapper.findComponent(ContactSelectorStub).vm.$emit('setSelectedContact', {
      value: '+77011234567',
      action: 'create',
    });
    await flushPromises();

    expect(createNewContact).toHaveBeenCalledWith('+77011234567');
    expect(openPersonDialog).toHaveBeenCalledWith(11);
  });

  it('stays open when the contact could not be created', async () => {
    createNewContact.mockRejectedValue(new Error('no'));
    const wrapper = mountPicker();
    await wrapper.find('[data-test="trigger"]').trigger('click');

    wrapper.findComponent(ContactSelectorStub).vm.$emit('setSelectedContact', {
      value: 'x@example.com',
      action: 'create',
    });
    await flushPromises();

    expect(openPersonDialog).not.toHaveBeenCalled();
    expect(wrapper.find('[data-test="contact-selector"]').exists()).toBe(true);
  });
});
