import { describe, expect, it } from 'vitest';

import {
  buildTouchContentModeTabs,
  isWhatsAppTemplateCapableChannel,
  normalizeTouchContentKindForCapabilities,
} from './touchContentModes';

const t = key => key;

describe('touchContentModes', () => {
  it('shows free text and WhatsApp template tabs together for official WhatsApp Cloud surfaces', () => {
    const supportsWhatsAppTemplates = isWhatsAppTemplateCapableChannel({
      channelType: 'Channel::Whatsapp',
    });

    expect(supportsWhatsAppTemplates).toBe(true);
    expect(
      buildTouchContentModeTabs({ t, supportsWhatsAppTemplates }).map(
        tab => tab.id
      )
    ).toEqual(['free_text', 'channel_template']);
  });

  it('does not expose WhatsApp Cloud templates for Twilio WhatsApp channels', () => {
    expect(
      isWhatsAppTemplateCapableChannel({
        channelType: 'Channel::TwilioSms',
        medium: 'whatsapp',
      })
    ).toBe(false);
    expect(
      buildTouchContentModeTabs({
        t,
        supportsFreeText: true,
        supportsWhatsAppTemplates: false,
      }).map(tab => tab.id)
    ).toEqual(['free_text']);
  });

  it('shows only WhatsApp tab when no free text templates are available', () => {
    expect(
      buildTouchContentModeTabs({
        t,
        supportsFreeText: false,
        supportsWhatsAppTemplates: true,
      }).map(tab => tab.id)
    ).toEqual(['channel_template']);
  });

  it('keeps channel template payload mode only while the selected inbox supports templates', () => {
    expect(
      normalizeTouchContentKindForCapabilities({
        contentKind: 'channel_template',
        supportsWhatsAppTemplates: true,
      })
    ).toBe('channel_template');

    expect(
      normalizeTouchContentKindForCapabilities({
        contentKind: 'channel_template',
        supportsWhatsAppTemplates: false,
      })
    ).toBe('free_text');
  });
});
