import { conversationMatchesLocalSearch } from '../conversationSearch';

describe('conversationMatchesLocalSearch', () => {
  const conversation = {
    id: 42,
    display_id: 4201,
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

  it('returns false when nothing matches', () => {
    expect(
      conversationMatchesLocalSearch(conversation, contact, 'missing-value')
    ).toBe(false);
  });
});
