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

  describe('a phone number typed in any format', () => {
    it('matches the phone of the contact', () => {
      [
        '87001234567',
        '+77001234567',
        '7 700 123 45 67',
        '+7 (700) 123-45-67',
        '8-700-123-45-67',
        '700 123 45 67',
        '\u200E+7\u00A0700\u00A0123\u00A045\u00A067\u200F',
      ].forEach(query => {
        expect(
          conversationMatchesLocalSearch(conversation, contact, query)
        ).toBe(true);
      });
    });

    it('matches the phone of the sender when the contact is not loaded', () => {
      expect(
        conversationMatchesLocalSearch(conversation, {}, '8 777 000 11 22')
      ).toBe(true);
    });

    it('does not match a different number or a short input of digits', () => {
      expect(
        conversationMatchesLocalSearch(conversation, contact, '8 701 234 56 78')
      ).toBe(false);
      expect(
        conversationMatchesLocalSearch(conversation, contact, '+7 70')
      ).toBe(false);
    });

    it('keeps matching text that contains digits', () => {
      expect(
        conversationMatchesLocalSearch(conversation, contact, 'invoice A-42')
      ).toBe(true);
    });
  });

  describe('what the server list search does not know about the loaded conversations', () => {
    const profileContact = {
      id: 8,
      name: 'Без имени',
      additional_attributes: {
        social_telegram_user_name: 'ada_telegram',
        screen_name: 'ada_screen',
      },
      channel_profiles: [
        {
          username: 'ada_channel_login',
          display_name: 'Ада в мессенджере',
          phone_number: '+77075550101',
          email: 'ada@channel.example',
        },
      ],
    };
    const voiceConversation = {
      id: 9,
      messages: [
        {
          id: 1,
          content_attributes: {
            transcribed_text: 'расшифровка голоса про справку',
          },
        },
      ],
    };

    it('matches by the Telegram user name and the screen name', () => {
      expect(
        conversationMatchesLocalSearch({}, profileContact, 'ada_telegram')
      ).toBe(true);
      expect(
        conversationMatchesLocalSearch({}, profileContact, 'ada_screen')
      ).toBe(true);
    });

    it('matches by the channel profile of the contact: user name, display name, e-mail and phone number', () => {
      [
        'ada_channel_login',
        'в мессенджере',
        'ada@channel',
        '8 707 555 01 01',
      ].forEach(query => {
        expect(conversationMatchesLocalSearch({}, profileContact, query)).toBe(
          true
        );
      });
    });

    it('matches by the transcribed text of a voice message', () => {
      expect(
        conversationMatchesLocalSearch(voiceConversation, {}, 'про справку')
      ).toBe(true);
    });

    it('survives a contact without channel profiles', () => {
      expect(
        conversationMatchesLocalSearch({}, { channel_profiles: null }, 'x')
      ).toBe(false);
    });
  });

  describe('text copied from somewhere else', () => {
    it('matches names with е and ё interchanged', () => {
      const yo = { name: 'Семён Киселёв' };

      ['семен киселев', 'Семён Киселёв', 'СЕМЕН', 'киселёв'].forEach(query => {
        expect(conversationMatchesLocalSearch({}, yo, query)).toBe(true);
      });
    });

    it('matches names typed with a non-breaking space or invisible marks', () => {
      const ivan = { name: 'Иван Иванов' };

      [
        'Иван\u00A0Иванов',
        '\u200EИван Иванов\u200F',
        'Иван\u2009Иванов',
      ].forEach(query => {
        expect(conversationMatchesLocalSearch({}, ivan, query)).toBe(true);
      });
    });
  });
});
