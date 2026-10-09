import { describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';
import { shallowMount } from '@vue/test-utils';

import AttachmentChips from './AttachmentChips.vue';
import AudioChip from './Audio.vue';
import FileChip from './File.vue';
import { createAttachmentAvailability } from 'dashboard/composables/useAttachmentAvailability';

vi.mock('../provider.js', () => ({
  useMessageContext: () => ({
    orientation: { value: 'left' },
    conversationId: { value: 7 },
  }),
}));
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '3' } }),
}));

const createWrapper = attachments =>
  shallowMount(AttachmentChips, {
    props: { attachments },
    global: {
      mocks: { $t: key => key },
    },
  });

describe('AttachmentChips', () => {
  it('shows a note and keeps the transcript of a file purged by an administrator', () => {
    const wrapper = createWrapper([
      {
        id: 1,
        fileType: 'audio',
        dataUrl: '',
        filePurged: true,
        transcribedText: 'Voice message words',
      },
    ]);

    const purged = wrapper.find('[data-attachment-purged]');
    expect(purged.exists()).toBe(true);
    expect(purged.text()).toContain('CONVERSATION.ATTACHMENT_FILE_PURGED');
    expect(purged.text()).toContain('Voice message words');
    expect(wrapper.findComponent(AudioChip).exists()).toBe(false);
  });

  it('shows parsed document text of a purged file', () => {
    const wrapper = createWrapper([
      { id: 2, fileType: 'file', filePurged: true, parsedText: 'Invoice text' },
    ]);

    expect(wrapper.find('[data-attachment-purged]').text()).toContain(
      'Invoice text'
    );
  });

  it('keeps rendering regular attachments as chips', () => {
    const wrapper = createWrapper([
      { id: 3, fileType: 'file', dataUrl: 'https://example.test/a.pdf' },
    ]);

    expect(wrapper.find('[data-attachment-purged]').exists()).toBe(false);
    expect(wrapper.findAllComponents(FileChip)).toHaveLength(1);
  });

  it('removes a stale file link from the open message when a refresh confirms purge', async () => {
    const attachment = {
      id: 81006,
      fileType: 'file',
      dataUrl: 'https://media.example.test/previously-valid.pdf',
    };
    const wrapper = createWrapper([attachment]);
    const availability = createAttachmentAvailability({
      attachment: ref(attachment),
      dispatch: vi
        .fn()
        .mockResolvedValue([
          { id: attachment.id, file_purged: true, data_url: '', thumb_url: '' },
        ]),
      getIdentity: () => ({
        accountId: '3',
        routeFullPath: '/app/accounts/3/conversations/7',
        selectedChatId: 7,
        selectedChatType: 'conversation',
        isCommunicationThread: false,
      }),
    });

    await availability.refreshAfterMediaFailure();

    expect(wrapper.findComponent(FileChip).exists()).toBe(false);
    expect(wrapper.find('[data-attachment-purged]').exists()).toBe(true);
    expect(wrapper.text()).not.toContain(attachment.dataUrl);
  });
});
