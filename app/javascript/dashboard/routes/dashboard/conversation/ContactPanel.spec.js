import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia } from 'pinia';
import { flushPromises, shallowMount } from '@vue/test-utils';
import ContactPanel from './ContactPanel.vue';

const mocks = vi.hoisted(() => ({
  dispatch: vi.fn(),
  sidebarItems: [{ name: 'contact_attributes' }, { name: 'contact_notes' }],
}));
const chat = {
  id: 123,
  meta: { sender: { id: 42 }, channel: 'Channel::Whatsapp' },
};

vi.mock('dashboard/composables/store', async () => {
  const { computed } = await import('vue');
  return {
    useStore: () => ({ dispatch: mocks.dispatch }),
    useMapGetter: name =>
      computed(
        () =>
          ({
            getSelectedChat: chat,
            'contacts/getContact': id => ({
              id,
              name: 'Chat owner',
              additional_attributes: {},
            }),
            'conversationMetadata/getConversationMetadata': () => ({
              additional_attributes: {},
            }),
          })[name]
      ),
    useFunctionGetter: () => computed(() => ({ enabled: false })),
  };
});
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ isCloudFeatureEnabled: () => false }),
}));
vi.mock('dashboard/composables/useUISettings', async () => {
  const { ref: createRef } = await import('vue');
  return {
    useUISettings: () => ({
      updateUISettings: vi.fn(),
      toggleSidebarUIState: vi.fn(),
      isContactSidebarItemOpen: () => true,
      conversationSidebarItemsOrder: createRef(mocks.sidebarItems),
    }),
  };
});

describe('ContactPanel selected patient details', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('uses the patient for clinical attributes and notes while preserving shared chat history', async () => {
    const wrapper = shallowMount(ContactPanel, {
      props: {
        conversationId: 123,
        patientContextEnabled: true,
        selectedPatient: { id: 84, full_name: 'Patient' },
        patientContextKey: '1:9:conversation:123',
      },
      global: {
        plugins: [createPinia()],
        mocks: { $t: key => key },
        stubs: {
          Draggable: {
            props: ['list'],
            template:
              '<div><slot v-for="element in list" name="item" :element="element" /></div>',
          },
          AccordionItem: { template: '<div><slot /></div>' },
          ContactInfo: {
            name: 'ContactInfo',
            props: ['contact'],
            template: '<div><slot /></div>',
          },
          SchedulingPatientDetails: {
            name: 'SchedulingPatientDetails',
            props: ['patient'],
            template: '<div />',
          },
          CustomAttributes: {
            name: 'CustomAttributes',
            props: ['contactId'],
            template: '<div />',
          },
          ContactNotes: {
            name: 'ContactNotes',
            props: ['contactId'],
            template: '<div />',
          },
          ContactConversations: {
            name: 'ContactConversations',
            props: ['contactId', 'conversationId'],
            template: '<div />',
          },
        },
      },
    });
    await flushPromises();
    expect(
      wrapper.findComponent({ name: 'ContactInfo' }).props('contact').id
    ).toBe(42);
    expect(
      wrapper
        .findComponent({ name: 'SchedulingPatientDetails' })
        .props('patient').id
    ).toBe(84);
    expect(
      wrapper.findComponent({ name: 'CustomAttributes' }).props('contactId')
    ).toBe(84);
    expect(
      wrapper.findComponent({ name: 'ContactNotes' }).props('contactId')
    ).toBe(84);
    expect(mocks.dispatch).toHaveBeenCalledWith('contacts/show', { id: 42 });
    expect(mocks.dispatch).toHaveBeenCalledWith('contacts/show', { id: 84 });
    await wrapper.setProps({
      selectedPatient: { id: 85, full_name: 'Other Patient' },
    });
    expect(
      wrapper.findComponent({ name: 'ContactNotes' }).props('contactId')
    ).toBe(85);
    expect(mocks.dispatch).toHaveBeenCalledWith('contacts/show', { id: 85 });
    expect(chat.meta.sender.id).toBe(42);
    expect(mocks.dispatch).not.toHaveBeenCalledWith(
      'integrations/get',
      'linear'
    );
  });

  it('keeps the contact profile visible without patient context', async () => {
    const wrapper = shallowMount(ContactPanel, {
      props: { conversationId: 123 },
      global: { mocks: { $t: key => key } },
    });
    expect(wrapper.findComponent({ name: 'ContactInfo' }).exists()).toBe(true);
    expect(
      wrapper.findComponent({ name: 'SchedulingPatientDetails' }).exists()
    ).toBe(false);
  });
});

describe('ContactPanel for a person who has no dialog yet', () => {
  const ALL_ITEMS = [
    { name: 'conversation_actions' },
    { name: 'contact_attributes' },
    { name: 'macros' },
    { name: 'contact_notes' },
    { name: 'shared_files' },
  ];
  const itemStubs = {
    Draggable: {
      props: ['list'],
      template:
        '<div><slot v-for="element in list" name="item" :element="element" /></div>',
    },
    AccordionItem: { template: '<div><slot /></div>' },
    ConversationAction: { name: 'ConversationAction', template: '<div />' },
    MacrosList: { name: 'MacrosList', template: '<div />' },
    SharedFiles: { name: 'SharedFiles', template: '<div />' },
    CustomAttributes: { name: 'CustomAttributes', template: '<div />' },
    ContactNotes: { name: 'ContactNotes', template: '<div />' },
    'woot-feature-toggle': { template: '<div><slot /></div>' },
  };
  const mountPanel = async draft => {
    mocks.sidebarItems.splice(0, mocks.sidebarItems.length, ...ALL_ITEMS);
    if (draft) {
      Object.assign(chat, { id: 'draft-42', is_draft: true });
    } else {
      delete chat.is_draft;
      chat.id = 123;
    }
    const wrapper = shallowMount(ContactPanel, {
      props: { conversationId: draft ? '' : 123 },
      global: {
        plugins: [createPinia()],
        mocks: { $t: key => key },
        stubs: itemStubs,
      },
    });
    await flushPromises();
    return wrapper;
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    mocks.sidebarItems.splice(
      0,
      mocks.sidebarItems.length,
      { name: 'contact_attributes' },
      { name: 'contact_notes' }
    );
    delete chat.is_draft;
    chat.id = 123;
  });

  it('keeps what belongs to the person: attributes and notes', async () => {
    const wrapper = await mountPanel(true);

    expect(wrapper.findComponent({ name: 'CustomAttributes' }).exists()).toBe(
      true
    );
    expect(wrapper.findComponent({ name: 'ContactNotes' }).exists()).toBe(true);
  });

  it('drops what belongs to a conversation: its actions, macros and shared files', async () => {
    const wrapper = await mountPanel(true);

    expect(wrapper.findComponent({ name: 'ConversationAction' }).exists()).toBe(
      false
    );
    expect(wrapper.findComponent({ name: 'MacrosList' }).exists()).toBe(false);
    expect(wrapper.findComponent({ name: 'SharedFiles' }).exists()).toBe(false);
  });

  it('shows all of them for a dialog that exists', async () => {
    const wrapper = await mountPanel(false);

    expect(wrapper.findComponent({ name: 'ConversationAction' }).exists()).toBe(
      true
    );
    expect(wrapper.findComponent({ name: 'MacrosList' }).exists()).toBe(true);
    expect(wrapper.findComponent({ name: 'SharedFiles' }).exists()).toBe(true);
  });
});
