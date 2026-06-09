import { describe, expect, it } from 'vitest';

import MessagesView from './MessagesView.vue';

describe('MessagesView', () => {
  it('does not show the messaging-window banner for voice conversations', () => {
    expect(
      MessagesView.computed.shouldShowReplyWindowBanner.call({
        currentChat: { can_reply: false },
        isAVoiceChannel: true,
        hasCommunicationThreadReplyableChannel: false,
      })
    ).toBe(false);
  });

  it('does not show the messaging-window banner for replyable communication threads', () => {
    expect(
      MessagesView.computed.hasCommunicationThreadReplyableChannel.call({
        currentChat: {
          is_communication_thread: true,
          can_reply: false,
          channels: [
            {
              inbox_id: 4674,
              channel: 'Channel::Voice',
              can_reply: false,
              disabled: false,
            },
          ],
        },
      })
    ).toBe(true);

    expect(
      MessagesView.computed.shouldShowReplyWindowBanner.call({
        currentChat: {
          is_communication_thread: true,
          can_reply: false,
          channels: [
            {
              inbox_id: 4674,
              channel: 'Channel::Voice',
              can_reply: false,
              disabled: false,
            },
          ],
        },
        isAVoiceChannel: false,
        hasCommunicationThreadReplyableChannel: true,
      })
    ).toBe(false);
  });

  it('shows the messaging-window banner for restricted non-voice conversations', () => {
    expect(
      MessagesView.computed.shouldShowReplyWindowBanner.call({
        currentChat: { can_reply: false },
        isAVoiceChannel: false,
        hasCommunicationThreadReplyableChannel: false,
      })
    ).toBe(true);
  });
});
