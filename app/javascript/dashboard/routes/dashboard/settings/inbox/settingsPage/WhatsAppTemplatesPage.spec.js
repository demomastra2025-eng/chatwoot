import { flushPromises, shallowMount } from '@vue/test-utils';

import Switch from 'dashboard/components-next/switch/Switch.vue';
import WhatsAppTemplatesPage from './WhatsAppTemplatesPage.vue';

const { dispatch, useAlertMock } = vi.hoisted(() => ({
  dispatch: vi.fn(),
  useAlertMock: vi.fn(),
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: useAlertMock,
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
}));

const template = (name, extra = {}) => ({
  name,
  language: 'en_US',
  status: 'APPROVED',
  category: 'UTILITY',
  components: [{ type: 'BODY', text: `${name} body` }],
  ...extra,
});

const inbox = {
  id: 7,
  csat_config: {},
  message_templates: [
    template('agent_reply'),
    template('automation_only', { visible_in_conversation_picker: false }),
  ],
};

const mountComponent = (inboxProp = inbox) =>
  shallowMount(WhatsAppTemplatesPage, {
    props: { inbox: inboxProp, embedded: true },
    global: {
      stubs: {
        Button: true,
        CreateWhatsAppTemplateDialog: true,
        Dialog: true,
        Input: true,
      },
    },
  });

const switchFor = (wrapper, templateName) => {
  const card = wrapper
    .findAll('.rounded-2xl')
    .find(node => node.text().includes(templateName));
  return card.findComponent(Switch);
};

describe('WhatsAppTemplatesPage', () => {
  beforeEach(() => {
    dispatch.mockReset();
    useAlertMock.mockReset();
  });

  it('shows whether each template is offered in conversations', () => {
    const wrapper = mountComponent();

    expect(switchFor(wrapper, 'agent_reply').props('modelValue')).toBe(true);
    expect(switchFor(wrapper, 'automation_only').props('modelValue')).toBe(
      false
    );
  });

  it('hides a template from the conversation picker', async () => {
    dispatch.mockResolvedValue({});
    const wrapper = mountComponent();

    switchFor(wrapper, 'agent_reply').vm.$emit('update:modelValue', false);
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith(
      'inboxes/updateWhatsAppTemplateVisibility',
      { inboxId: 7, templateName: 'agent_reply', visible: false }
    );
  });

  it('disables the switch while the change is saving', async () => {
    let resolveUpdate;
    dispatch.mockReturnValue(
      new Promise(resolve => {
        resolveUpdate = resolve;
      })
    );
    const wrapper = mountComponent();

    switchFor(wrapper, 'automation_only').vm.$emit('update:modelValue', true);
    await wrapper.vm.$nextTick();

    expect(switchFor(wrapper, 'automation_only').props('disabled')).toBe(true);
    expect(switchFor(wrapper, 'agent_reply').props('disabled')).toBe(false);

    resolveUpdate({});
    await flushPromises();

    expect(switchFor(wrapper, 'automation_only').props('disabled')).toBe(false);
  });

  it('shows the API error when the change fails', async () => {
    dispatch.mockRejectedValue(new Error('WhatsApp template not found'));
    const wrapper = mountComponent();

    switchFor(wrapper, 'agent_reply').vm.$emit('update:modelValue', false);
    await flushPromises();

    expect(useAlertMock).toHaveBeenCalledWith('WhatsApp template not found');
    expect(switchFor(wrapper, 'agent_reply').props('modelValue')).toBe(true);
  });
});
