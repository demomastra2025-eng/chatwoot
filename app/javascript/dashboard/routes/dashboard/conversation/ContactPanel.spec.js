import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia } from 'pinia';
import { flushPromises, shallowMount } from '@vue/test-utils';
import ContactPanel from './ContactPanel.vue';

const mocks = vi.hoisted(() => ({ dispatch: vi.fn() }));
const chat = { id: 123, meta: { sender: { id: 42 }, channel: 'Channel::Whatsapp' } };

vi.mock('dashboard/composables/store', async () => {
  const { computed } = await import('vue');
  return {
    useStore: () => ({ dispatch: mocks.dispatch }),
    useMapGetter: name => computed(() => ({
      getSelectedChat: chat,
      'contacts/getContact': id => ({ id, name: 'Chat owner', additional_attributes: {} }),
      'conversationMetadata/getConversationMetadata': () => ({ additional_attributes: {} }),
    })[name]),
    useFunctionGetter: () => computed(() => ({ enabled: false })),
  };
});
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ isCloudFeatureEnabled: () => false }),
}));
vi.mock('dashboard/composables/useUISettings', async () => {
  const { ref: createRef } = await import('vue');
  return { useUISettings: () => ({
    updateUISettings: vi.fn(), toggleSidebarUIState: vi.fn(),
    isContactSidebarItemOpen: () => true,
    conversationSidebarItemsOrder: createRef([
      { name: 'contact_attributes' }, { name: 'contact_notes' }, { name: 'previous_conversation' },
    ]),
  }) };
});

describe('ContactPanel selected patient details', () => {
  beforeEach(() => { vi.clearAllMocks(); });

  it('uses the patient for clinical attributes and notes while preserving shared chat history', async () => {
    const wrapper = shallowMount(ContactPanel, {
      props: { conversationId: 123, patientContextEnabled: true,
        selectedPatient: { id: 84, full_name: 'Patient' }, patientContextKey: '1:9:conversation:123' },
      global: {
        plugins: [createPinia()],
        mocks: { $t: key => key },
        stubs: {
          Draggable: { props: ['list'], template: '<div><slot v-for="element in list" name="item" :element="element" /></div>' },
          AccordionItem: { template: '<div><slot /></div>' },
          SchedulingPatientDetails: { name: 'SchedulingPatientDetails', props: ['patient'], template: '<div />' },
          CustomAttributes: { name: 'CustomAttributes', props: ['contactId'], template: '<div />' },
          ContactNotes: { name: 'ContactNotes', props: ['contactId'], template: '<div />' },
          ContactConversations: { name: 'ContactConversations', props: ['contactId', 'conversationId'], template: '<div />' },
        },
      },
    });
    await flushPromises();
    expect(wrapper.findComponent({ name: 'SchedulingPatientDetails' }).props('patient').id).toBe(84);
    expect(wrapper.findComponent({ name: 'CustomAttributes' }).props('contactId')).toBe(84);
    expect(wrapper.findComponent({ name: 'ContactNotes' }).props('contactId')).toBe(84);
    expect(wrapper.findComponent({ name: 'ContactConversations' }).props('contactId')).toBe(42);
    expect(mocks.dispatch).toHaveBeenCalledWith('contacts/show', { id: 42 });
    expect(mocks.dispatch).toHaveBeenCalledWith('contacts/show', { id: 84 });
    await wrapper.setProps({ selectedPatient: { id: 85, full_name: 'Other Patient' } });
    expect(wrapper.findComponent({ name: 'ContactNotes' }).props('contactId')).toBe(85);
    expect(mocks.dispatch).toHaveBeenCalledWith('contacts/show', { id: 85 });
    expect(wrapper.findComponent({ name: 'ContactConversations' }).props('contactId')).toBe(42);
    expect(chat.meta.sender.id).toBe(42);
  });
});
