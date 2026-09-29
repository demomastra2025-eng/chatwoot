import { describe, expect, it } from 'vitest';
import { resolveOutgoingDeliveryStatus } from '../messageDeliveryStatus';

const outgoing = overrides => ({
  id: 1,
  message_type: 1,
  status: 'sent',
  private: false,
  ...overrides,
});

describe('resolveOutgoingDeliveryStatus', () => {
  it('keeps a provider message in the sending state until the provider id arrives', () => {
    expect(resolveOutgoingDeliveryStatus(outgoing(), 'Channel::Whatsapp')).toBe(
      'progress'
    );
    expect(
      resolveOutgoingDeliveryStatus(
        outgoing({ source_id: 'wamid.1' }),
        'Channel::Whatsapp'
      )
    ).toBe('sent');
  });

  it('shows delivered and read only for provider-confirmed messages', () => {
    expect(
      resolveOutgoingDeliveryStatus(
        outgoing({ status: 'delivered' }),
        'Channel::TelegramPersonal'
      )
    ).toBe('progress');
    expect(
      resolveOutgoingDeliveryStatus(
        outgoing({ status: 'delivered', source_id: 'tg-1' }),
        'Channel::TelegramPersonal'
      )
    ).toBe('delivered');
    expect(
      resolveOutgoingDeliveryStatus(
        outgoing({ status: 'read', sourceId: 'ig-1' }),
        'Channel::Instagram'
      )
    ).toBe('read');
  });

  it('uses stored states for web widget and API inboxes', () => {
    expect(
      resolveOutgoingDeliveryStatus(outgoing(), 'Channel::WebWidget')
    ).toBe('delivered');
    expect(
      resolveOutgoingDeliveryStatus(
        outgoing({ status: 'read' }),
        'Channel::WebWidget'
      )
    ).toBe('read');
    expect(resolveOutgoingDeliveryStatus(outgoing(), 'Channel::Api')).toBe(
      'sent'
    );
  });

  it('treats an email as sent only after the mail provider id is stored', () => {
    expect(resolveOutgoingDeliveryStatus(outgoing(), 'Channel::Email')).toBe(
      'progress'
    );
    expect(
      resolveOutgoingDeliveryStatus(
        outgoing({ source_id: '<mail@id>' }),
        'Channel::Email'
      )
    ).toBe('sent');
  });

  it('keeps the local pending echo as sending on every channel', () => {
    expect(
      resolveOutgoingDeliveryStatus(
        outgoing({ status: 'progress' }),
        'Channel::Voice'
      )
    ).toBe('progress');
  });

  it('does not render a status for incoming, private, failed, deleted or unknown-channel messages', () => {
    expect(
      resolveOutgoingDeliveryStatus(
        outgoing({ message_type: 0 }),
        'Channel::Whatsapp'
      )
    ).toBe('');
    expect(
      resolveOutgoingDeliveryStatus(
        outgoing({ private: true }),
        'Channel::Whatsapp'
      )
    ).toBe('');
    expect(
      resolveOutgoingDeliveryStatus(
        outgoing({ status: 'failed' }),
        'Channel::Whatsapp'
      )
    ).toBe('');
    expect(
      resolveOutgoingDeliveryStatus(
        outgoing({ content_attributes: { deleted: true } }),
        'Channel::Whatsapp'
      )
    ).toBe('');
    expect(resolveOutgoingDeliveryStatus(outgoing(), 'Channel::Voice')).toBe(
      ''
    );
    expect(resolveOutgoingDeliveryStatus(null, 'Channel::Whatsapp')).toBe('');
  });
});
