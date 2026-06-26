import { INBOX_TYPES } from 'dashboard/helper/inbox.js';

export const TOUCH_CONTENT_KINDS = {
  FREE_TEXT: 'free_text',
  CHANNEL_TEMPLATE: 'channel_template',
};

export const isWhatsAppTemplateCapableChannel = ({
  channelType,
  channel_type: channelTypeSnake,
} = {}) => {
  const normalizedChannelType = channelType || channelTypeSnake || '';

  return normalizedChannelType === INBOX_TYPES.WHATSAPP;
};

export const buildTouchContentModeTabs = ({
  t = key => key,
  supportsFreeText = true,
  supportsWhatsAppTemplates = false,
} = {}) => {
  const tabs = [];

  if (supportsFreeText) {
    tabs.push({
      id: TOUCH_CONTENT_KINDS.FREE_TEXT,
      label: t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.FREE_TEXT_TAB'),
    });
  }

  if (supportsWhatsAppTemplates) {
    tabs.push({
      id: TOUCH_CONTENT_KINDS.CHANNEL_TEMPLATE,
      label: t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.FIELDS.WHATSAPP_TEMPLATE_TAB'),
    });
  }

  return tabs;
};

export const normalizeTouchContentKindForCapabilities = ({
  contentKind,
  supportsWhatsAppTemplates = false,
} = {}) => {
  if (
    contentKind === TOUCH_CONTENT_KINDS.CHANNEL_TEMPLATE &&
    !supportsWhatsAppTemplates
  ) {
    return TOUCH_CONTENT_KINDS.FREE_TEXT;
  }

  return contentKind || TOUCH_CONTENT_KINDS.FREE_TEXT;
};
