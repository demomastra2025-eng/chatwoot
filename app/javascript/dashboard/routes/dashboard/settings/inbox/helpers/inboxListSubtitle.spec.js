import ru from 'dashboard/i18n/locale/ru';
import { getInboxListSubtitle } from './inboxListSubtitle';

const t = key => key.split('.').reduce((node, part) => node?.[part], ru) ?? key;

const subtitleText = inbox => getInboxListSubtitle(inbox, t)?.text;

describe('#getInboxListSubtitle', () => {
  it('returns nothing for a missing inbox', () => {
    expect(getInboxListSubtitle(null, t)).toBeNull();
  });

  it('shows the phone number for phone based channels', () => {
    [
      'Channel::Whatsapp',
      'Channel::WhatsappWeb',
      'Channel::Sms',
      'Channel::TwilioSms',
      'Channel::TelegramPersonal',
    ].forEach(channelType => {
      expect(
        subtitleText({
          channel_type: channelType,
          phone_number: '+77001234567',
        })
      ).toBe('+77001234567');
    });
  });

  it('cleans up the phone number from Twilio and WhatsApp Web', () => {
    expect(
      subtitleText({
        channel_type: 'Channel::TwilioSms',
        phone_number: 'whatsapp:+77001234567',
      })
    ).toBe('+77001234567');
    expect(
      subtitleText({
        channel_type: 'Channel::WhatsappWeb',
        additional_attributes: { evolution: { number: '77001234567' } },
      })
    ).toBe('+77001234567');
  });

  it('shows the number and a readable provider name for voice channels', () => {
    const voice = (provider, extra = {}) => ({
      channel_type: 'Channel::Voice',
      phone_number: '+77271234567',
      provider,
      ...extra,
    });

    expect(subtitleText(voice('sipuni'))).toBe('+77271234567 · Sipuni');
    expect(subtitleText(voice('binotel'))).toBe('+77271234567 · Binotel');
    expect(subtitleText(voice('beeline'))).toBe('+77271234567 · Билайн');
    expect(subtitleText(voice('twilio'))).toBe('+77271234567 · Twilio');
    expect(subtitleText(voice('asterisk_analog'))).toBe(
      '+77271234567 · Asterisk аналоговый'
    );
    expect(subtitleText(voice('wazo'))).toBe(
      '+77271234567 · Другой SIP-провайдер'
    );
    expect(
      subtitleText(
        voice('wazo', { provider_config: { carrier_kind: 'kcell' } })
      )
    ).toBe('+77271234567 · Kcell / Activ');
  });

  it('falls back to a humanized provider name and works without a number', () => {
    expect(
      subtitleText({ channel_type: 'Channel::Voice', provider: 'new_sip' })
    ).toBe('New Sip');
  });

  it('shows the bot username with @ for a Telegram bot', () => {
    expect(
      subtitleText({ channel_type: 'Channel::Telegram', bot_name: 'shop_bot' })
    ).toBe('@shop_bot');
    expect(
      subtitleText({ channel_type: 'Channel::Telegram', bot_name: '@shop_bot' })
    ).toBe('@shop_bot');
  });

  it('shows only the domain for a website widget', () => {
    expect(
      subtitleText({
        channel_type: 'Channel::WebWidget',
        website_url: 'https://www.example.com/contacts?utm=1',
      })
    ).toBe('example.com');
    expect(
      subtitleText({
        channel_type: 'Channel::WebWidget',
        website_url: 'shop.example.kz',
      })
    ).toBe('shop.example.kz');
  });

  it('shows the email address for an email channel', () => {
    expect(
      subtitleText({
        channel_type: 'Channel::Email',
        email: 'info@example.com',
      })
    ).toBe('info@example.com');
  });

  it('shows the Instagram account name when the inbox is named after it', () => {
    expect(
      subtitleText({ channel_type: 'Channel::Instagram', name: 'my.shop' })
    ).toBe('@my.shop');
    expect(
      getInboxListSubtitle(
        { channel_type: 'Channel::Instagram', name: 'Main shop account' },
        t
      )
    ).toBeNull();
  });

  it('shows the account name for WeChat and the page address for VK', () => {
    expect(
      subtitleText({ channel_type: 'Channel::Weixin', display_name: 'Aigerim' })
    ).toBe('Aigerim');
    expect(
      subtitleText({ channel_type: 'Channel::VkCommunity', group_id: 123 })
    ).toBe('vk.com/club123');
  });

  it('shows nothing technical for API channels and nothing when there is no data', () => {
    expect(
      getInboxListSubtitle(
        {
          channel_type: 'Channel::Api',
          webhook_url: 'https://hooks.example.com/chat',
        },
        t
      )
    ).toBeNull();
    expect(
      getInboxListSubtitle({ channel_type: 'Channel::Email' }, t)
    ).toBeNull();
  });
});
