import { shallowMount } from '@vue/test-utils';
import AgentMessage from '../AgentMessage.vue';
import UserMessage from '../UserMessage.vue';
import MessageReplyButton from '../MessageReplyButton.vue';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';

describe('widget message reply action', () => {
  const wrappers = [];
  const message = {
    id: 42,
    content: 'Example message',
    content_type: 'text',
    content_attributes: {},
    attachments: [],
    sender: { available_name: 'Demo agent', avatar_url: '' },
    created_at: 1700000000,
    status: 'sent',
  };

  beforeEach(() => {
    window.chatwootWebChannel = { enabledFeatures: [] };
  });

  afterEach(() => {
    wrappers.forEach(wrapper => wrapper.unmount());
    wrappers.length = 0;
    delete window.chatwootWebChannel;
    vi.restoreAllMocks();
  });

  const renderMessage = (component, props = {}) => {
    const wrapper = shallowMount(component, {
      attachTo: document.body,
      props: { message: { ...message, ...props } },
      global: {
        stubs: { MessageReplyButton: false },
        mocks: {
          $t: key => key,
          $store: { getters: { 'appConfig/getWidgetColor': '#1864ab' } },
        },
      },
    });
    wrappers.push(wrapper);
    return wrapper;
  };

  it.each([
    ['agent', AgentMessage],
    ['user', UserMessage],
  ])(
    'focuses and activates the native reply button for a %s message',
    async (_, component) => {
      const emit = vi.spyOn(emitter, 'emit');
      const wrapper = renderMessage(component);
      const button = wrapper.getComponent(MessageReplyButton).get('button');

      button.element.focus();
      expect(document.activeElement).toBe(button.element);
      expect(button.attributes('aria-label')).toBe(
        'COMPONENTS.MESSAGE_BUBBLE.REPLY'
      );
      expect(button.attributes('type')).toBe('button');
      await button.trigger('click');
      expect(emit).toHaveBeenCalledWith(
        BUS_EVENTS.TOGGLE_REPLY_TO_MESSAGE,
        expect.objectContaining({ id: message.id })
      );
    }
  );

  it.each(['in_progress', 'failed'])(
    'keeps reply unavailable for a user message with %s status',
    status => {
      const wrapper = renderMessage(UserMessage, { status });
      expect(wrapper.findComponent(MessageReplyButton).exists()).toBe(false);
    }
  );
});
