import { describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import AttachmentChips from './AttachmentChips.vue';
import AudioChip from './Audio.vue';
import FileChip from './File.vue';

vi.mock('../provider.js', () => ({
  useMessageContext: () => ({ orientation: { value: 'left' } }),
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
});
