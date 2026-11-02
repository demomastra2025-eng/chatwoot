import { describe, it, expect, beforeEach, vi } from 'vitest';
import { ref } from 'vue';
import { mount, flushPromises } from '@vue/test-utils';
import HistoryMediaAction from '../HistoryMediaAction.vue';
import ConversationAPI from 'dashboard/api/conversations';

const context = {
  id: ref(12),
  conversationId: ref(7),
  attachments: ref([]),
  contentAttributes: ref({}),
};
const dispatch = vi.fn();

vi.mock('../../../provider.js', () => ({
  useMessageContext: () => context,
}));
vi.mock('dashboard/api/conversations', () => ({
  default: { enrichHistoryMedia: vi.fn() },
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
}));

const mountAction = () =>
  mount(HistoryMediaAction, { global: { mocks: { $store: { dispatch } } } });

describe('History media action', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    context.contentAttributes.value = {
      historyAttachment: { unavailable: true, deferred: true },
    };
    context.attachments.value = [];
  });

  it('loads only the contextual message, disables duplicate requests and updates the existing message store', async () => {
    let finish;
    ConversationAPI.enrichHistoryMedia.mockReturnValue(
      new Promise(resolve => {
        finish = resolve;
      })
    );
    const wrapper = mountAction();
    await wrapper.get('button').trigger('click');
    expect(wrapper.get('button').attributes('disabled')).toBeDefined();
    await wrapper.get('button').trigger('click');
    expect(ConversationAPI.enrichHistoryMedia).toHaveBeenCalledTimes(1);
    expect(ConversationAPI.enrichHistoryMedia).toHaveBeenCalledWith(7, 12);
    const data = { id: 12, attachments: [{ id: 1 }] };
    finish({ data });
    await flushPromises();
    expect(dispatch).toHaveBeenCalledWith('updateMessage', data);
    context.attachments.value = data.attachments;
    await flushPromises();
    expect(wrapper.find('button').exists()).toBe(false);
  });

  it('shows a controlled error and allows retry', async () => {
    ConversationAPI.enrichHistoryMedia.mockRejectedValueOnce(
      new Error('network')
    );
    const wrapper = mountAction();
    await wrapper.get('button').trigger('click');
    await flushPromises();
    expect(wrapper.get('[role="status"]').text()).toBe('HISTORY_MEDIA.ERROR');
    expect(wrapper.get('button').text()).toBe('HISTORY_MEDIA.RETRY');
    ConversationAPI.enrichHistoryMedia.mockResolvedValueOnce({
      data: { id: 12, attachments: [] },
    });
    await wrapper.get('button').trigger('click');
    await flushPromises();
    expect(wrapper.get('[role="status"]').text()).toBe(
      'HISTORY_MEDIA.UNAVAILABLE'
    );
    expect(ConversationAPI.enrichHistoryMedia).toHaveBeenCalledTimes(2);
  });

  it('supports the existing Telegram placeholder attributes', () => {
    context.contentAttributes.value = { telegramHistoryMediaIncomplete: true };
    expect(mountAction().find('button').exists()).toBe(true);
  });

  it('keeps retry available for a partially downloaded Telegram album', async () => {
    context.contentAttributes.value = { telegramHistoryMediaIncomplete: true };
    context.attachments.value = [{ id: 1 }];
    ConversationAPI.enrichHistoryMedia.mockResolvedValueOnce({
      data: {
        id: 12,
        attachments: [{ id: 1 }],
        content_attributes: { telegram_history_media_incomplete: true },
      },
    });
    const wrapper = mountAction();
    await wrapper.get('button').trigger('click');
    await flushPromises();
    expect(wrapper.get('[role="status"]').text()).toBe(
      'HISTORY_MEDIA.UNAVAILABLE'
    );
    expect(wrapper.get('button').text()).toBe('HISTORY_MEDIA.RETRY');
  });

  it('keeps the unavailable state visible after reopening a message', () => {
    context.contentAttributes.value = {
      historyAttachment: { unavailable: true, fetchState: 'unavailable' },
    };
    const wrapper = mountAction();
    expect(wrapper.get('[role="status"]').text()).toBe(
      'HISTORY_MEDIA.UNAVAILABLE'
    );
    expect(wrapper.get('button').text()).toBe('HISTORY_MEDIA.RETRY');
  });

  it('does not offer media loading on deleted or ordinary text messages', () => {
    context.contentAttributes.value.deleted = true;
    expect(mountAction().find('button').exists()).toBe(false);
    context.contentAttributes.value = {};
    expect(mountAction().find('button').exists()).toBe(false);
  });
});
