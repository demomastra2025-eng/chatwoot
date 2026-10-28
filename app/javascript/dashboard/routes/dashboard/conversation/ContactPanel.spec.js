import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia } from 'pinia';
import { flushPromises, shallowMount } from '@vue/test-utils';
import ContactPanel from './ContactPanel.vue';

const mocks = vi.hoisted(() => ({
  dispatch: vi.fn(),
  toggle: vi.fn(),
  update: vi.fn(),
  openSections: {},
  sidebarItems: [
    { name: 'conversation_actions' },
    { name: 'macros' },
    { name: 'contact_attributes' },
    { name: 'contact_notes' },
    { name: 'shared_files' },
  ],
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
            'contacts/getContact': id => ({ id, name: 'Patient' }),
            'attributes/getAttributes': [],
            'attributes/getUIFlags': { isFetching: false },
          })[name]
      ),
  };
});
vi.mock('dashboard/composables/useUISettings', async () => {
  const { ref } = await import('vue');
  return {
    useUISettings: () => ({
      updateUISettings: mocks.update,
      toggleSidebarUIState: mocks.toggle,
      isContactSidebarItemOpen: key => mocks.openSections[key] ?? true,
      conversationSidebarItemsOrder: ref(mocks.sidebarItems),
    }),
  };
});
vi.mock('dashboard/composables/useConversationSidepanelAvailability', () => ({
  useConversationSidepanelAvailability: () => ({ closePanel: vi.fn() }),
}));

const stubs = {
  Draggable: {
    props: ['list'],
    template:
      '<div><slot v-for="element in list" name="item" :element="element" /></div>',
  },
  AccordionItem: {
    name: 'AccordionItem',
    props: ['title', 'isOpen'],
    emits: ['toggle'],
    template: '<div><slot /></div>',
  },
  ContactInfo: {
    name: 'ContactInfo',
    props: ['contact'],
    template:
      '<div><slot name="patient-summary" /><slot name="after-channels" /></div>',
  },
  ConversationAction: { name: 'ConversationAction', template: '<div />' },
  SchedulingPatientDetails: {
    name: 'SchedulingPatientDetails',
    props: { patient: Object, summary: Boolean },
    template: '<div />',
  },
  SchedulingConversationPatientSelector: {
    name: 'SchedulingConversationPatientSelector',
    props: ['showChips', 'showAddButton'],
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
  MacrosList: { name: 'MacrosList', template: '<div />' },
  SharedFiles: { name: 'SharedFiles', template: '<div />' },
  'woot-feature-toggle': { template: '<div><slot /></div>' },
};
const mountPanel = async props => {
  const wrapper = shallowMount(ContactPanel, {
    props: { conversationId: 123, ...props },
    global: { plugins: [createPinia()], mocks: { $t: key => key }, stubs },
  });
  await flushPromises();
  return wrapper;
};

beforeEach(() => {
  vi.clearAllMocks();
  Object.keys(mocks.openSections).forEach(
    key => delete mocks.openSections[key]
  );
  delete chat.is_draft;
});

describe('ContactPanel modules from PROD base 8f576715f', () => {
  it('keeps Macros, Attributes, Notes, Attachments separate and in the saved order', async () => {
    const wrapper = await mountPanel();
    expect(
      wrapper
        .findAllComponents({ name: 'AccordionItem' })
        .map(item => item.props('title'))
    ).toEqual([
      'CONVERSATION_SIDEBAR.ACCORDION.MACROS',
      'CONVERSATION_SIDEBAR.ACCORDION.CONTACT_ATTRIBUTES',
      'CONVERSATION_SIDEBAR.ACCORDION.CONTACT_NOTES',
      'CONVERSATION_SIDEBAR.ACCORDION.SHARED_FILES',
    ]);
    expect(wrapper.findComponent({ name: 'ConversationAction' }).exists()).toBe(
      true
    );
    wrapper
      .findAllComponents({ name: 'AccordionItem' })[0]
      .vm.$emit('toggle', false);
    expect(mocks.toggle).toHaveBeenCalledWith('is_macro_open', false);
  });

  it('keeps person modules but hides conversation modules for a draft', async () => {
    chat.is_draft = true;
    const wrapper = await mountPanel({ conversationId: '' });
    expect(
      wrapper
        .findAllComponents({ name: 'AccordionItem' })
        .map(item => item.props('title'))
    ).toEqual([
      'CONVERSATION_SIDEBAR.ACCORDION.CONTACT_ATTRIBUTES',
      'CONVERSATION_SIDEBAR.ACCORDION.CONTACT_NOTES',
    ]);
    expect(wrapper.findComponent({ name: 'ConversationAction' }).exists()).toBe(
      false
    );
    expect(
      wrapper.findComponent({ name: 'CustomAttributes' }).props('contactId')
    ).toBe(42);
    expect(
      wrapper.findComponent({ name: 'ContactNotes' }).props('contactId')
    ).toBe(42);
    expect(wrapper.findComponent({ name: 'SharedFiles' }).exists()).toBe(false);
    expect(wrapper.findComponent({ name: 'MacrosList' }).exists()).toBe(false);
  });

  it('loads attachments only when the original saved section is open', async () => {
    mocks.openSections.is_shared_files_open = false;
    const wrapper = await mountPanel();
    const attachments = wrapper.findAllComponents({ name: 'AccordionItem' })[3];
    expect(attachments.props('isOpen')).toBe(false);
    expect(wrapper.findComponent({ name: 'SharedFiles' }).exists()).toBe(false);
    attachments.vm.$emit('toggle', true);
    expect(mocks.toggle).toHaveBeenCalledWith('is_shared_files_open', true);
  });
});

describe('ContactPanel patient context', () => {
  const patient = { id: 84, full_name: 'Patient' };
  const common = {
    patientContextEnabled: true,
    patientContextKey: '1:9:conversation:123',
    selectedPatient: patient,
  };

  it('keeps the contact profile visible without patient context', async () => {
    const wrapper = await mountPanel();
    expect(
      wrapper.findComponent({ name: 'ContactInfo' }).props('contact').id
    ).toBe(42);
    expect(
      wrapper.findComponent({ name: 'SchedulingPatientDetails' }).exists()
    ).toBe(false);
    expect(
      wrapper
        .findComponent({ name: 'SchedulingConversationPatientSelector' })
        .exists()
    ).toBe(false);
  });

  it('uses contact details when no patient is available', async () => {
    const wrapper = await mountPanel({
      patientContextEnabled: true,
      patientContextKey: common.patientContextKey,
      patientEntry: { loaded: true, patients: [] },
    });
    expect(
      wrapper.findComponent({ name: 'SchedulingPatientDetails' }).exists()
    ).toBe(false);
    expect(
      wrapper.findComponent({ name: 'CustomAttributes' }).props('contactId')
    ).toBe(42);
    expect(
      wrapper.findComponent({ name: 'ContactNotes' }).props('contactId')
    ).toBe(42);
  });

  it('shows one patient summary below the name without tabs', async () => {
    const wrapper = await mountPanel({
      ...common,
      patientEntry: { loaded: true, patients: [patient] },
    });
    expect(
      wrapper
        .findComponent({ name: 'SchedulingPatientDetails' })
        .props('summary')
    ).toBe(true);
    expect(
      wrapper
        .findComponent({ name: 'SchedulingConversationPatientSelector' })
        .props('showChips')
    ).toBe(false);
  });

  it('shows tabs for two people and uses selected patient for notes and attributes', async () => {
    const wrapper = await mountPanel({
      ...common,
      patientEntry: { loaded: true, patients: [patient, { id: 85 }] },
    });
    expect(
      wrapper
        .findComponent({ name: 'SchedulingConversationPatientSelector' })
        .props('showChips')
    ).toBe(true);
    expect(
      wrapper
        .findComponent({ name: 'SchedulingConversationPatientSelector' })
        .props('showAddButton')
    ).toBe(false);
    expect(
      wrapper.findComponent({ name: 'CustomAttributes' }).props('contactId')
    ).toBe(84);
    expect(
      wrapper.findComponent({ name: 'ContactNotes' }).props('contactId')
    ).toBe(84);
    expect(mocks.dispatch).toHaveBeenCalledWith('contacts/show', { id: 84 });
    await wrapper.setProps({ selectedPatient: { id: 85 } });
    expect(
      wrapper.findComponent({ name: 'ContactNotes' }).props('contactId')
    ).toBe(85);
  });
});
