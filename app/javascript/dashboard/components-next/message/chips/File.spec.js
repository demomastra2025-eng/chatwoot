import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('@chatwoot/utils', () => ({
  downloadFile: vi.fn(),
  getFileInfo: vi.fn(() => ({
    base: 'invoice',
    type: 'pdf',
    name: 'invoice.pdf',
  })),
}));
vi.mock('dashboard/composables/useAttachmentAvailability', async () => {
  const { ref } = await import('vue');
  return {
    useAttachmentAvailability: () => ({
      isPurged: ref(false),
      refreshAfterMediaFailure: vi.fn(),
    }),
  };
});

import FileChip from './File.vue';

describe('File chip', () => {
  it('renders details from a replacement attachment prop', async () => {
    const initialAttachment = {
      id: 1,
      fileType: 'file',
      dataUrl: 'https://example.test/old.pdf',
      parsedText: 'Old parsed text',
    };
    const wrapper = mount(FileChip, {
      props: { attachment: initialAttachment },
      global: {
        stubs: { FileIcon: true, Icon: true },
        directives: { tooltip: {} },
      },
    });

    expect(wrapper.text()).toContain('Old parsed text');

    await wrapper.setProps({
      attachment: {
        ...initialAttachment,
        id: 2,
        dataUrl: 'https://example.test/new.pdf',
        parsedText: 'Updated parsed text',
      },
    });

    expect(wrapper.text()).toContain('Updated parsed text');
    expect(wrapper.text()).not.toContain('Old parsed text');
  });
});
