import { conversationMatchesLocalSearch } from '../conversationSearch';

describe('conversationMatchesLocalSearch', () => {
  const conversation = {
    id: 42,
    display_id: 4201,
    messages: [
      { id: 100, content: 'Customer wants a refund for invoice A-42' },
      {
        id: 101,
        content_attributes: { email: { subject: 'Delivery follow up' } },
      },
    ],
    last_non_activity_message: {
      id: 102,
      content: 'Last public preview from loaded chat list',
    },
    meta: {
      sender: {
        id: 7,
        name: 'Fallback Sender',
        phone_number: '+77770001122',
        identifier: 'telegram-777',
        email: 'fallback@example.com',
        additional_attributes: {
          social_profiles: {
            instagram: 'fallback.ig',
          },
        },
      },
    },
  };

  const contact = {
    id: 7,
    name: 'Ada Lovelace',
    phone_number: '+77001234567',
    identifier: 'tg_ada',
    email: 'ada@example.com',
    additional_attributes: {
      social_profiles: {
        instagram: 'ada.bot',
        telegram: 'ada_support',
      },
    },
  };

  it('matches by contact name', () => {
    expect(conversationMatchesLocalSearch(conversation, contact, 'ada')).toBe(
      true
    );
  });

  it('matches by phone number', () => {
    expect(
      conversationMatchesLocalSearch(conversation, contact, '1234567')
    ).toBe(true);
  });

  it('matches by identifier', () => {
    expect(
      conversationMatchesLocalSearch(conversation, contact, 'tg_ada')
    ).toBe(true);
  });

  it('matches by social profile usernames', () => {
    expect(
      conversationMatchesLocalSearch(conversation, contact, 'ada.bot')
    ).toBe(true);
  });

  it('falls back to sender fields when the contact is not loaded', () => {
    expect(
      conversationMatchesLocalSearch(conversation, {}, 'telegram-777')
    ).toBe(true);
  });

  it('matches by conversation identifier', () => {
    expect(conversationMatchesLocalSearch(conversation, contact, '4201')).toBe(
      true
    );
  });

  it('matches by loaded message text', () => {
    expect(
      conversationMatchesLocalSearch(conversation, contact, 'refund')
    ).toBe(true);
  });

  it('matches by loaded email subject text', () => {
    expect(
      conversationMatchesLocalSearch(conversation, contact, 'delivery')
    ).toBe(true);
  });

  it('matches by last message preview text', () => {
    expect(
      conversationMatchesLocalSearch(conversation, contact, 'preview')
    ).toBe(true);
  });

  it('returns false when nothing matches', () => {
    expect(
      conversationMatchesLocalSearch(conversation, contact, 'missing-value')
    ).toBe(false);
  });
});
