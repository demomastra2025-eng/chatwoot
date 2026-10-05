import { cleanSearchText, phoneMatchesQuery } from './phoneSearch';

// Exotic spaces and invisible marks of copied text are removed and "ё" is "е", so that "Семён" finds "Семен".
const normalizeSearchValue = value =>
  cleanSearchText(value).toLowerCase().replace(/ё/g, 'е');

const compactValues = values =>
  values.flatMap(value => {
    if (Array.isArray(value)) {
      return compactValues(value);
    }

    return value ? [value] : [];
  });

const resolveAdditionalAttributes = entity =>
  entity?.additional_attributes || entity?.additionalAttributes || {};

const resolveSocialProfiles = entity => {
  const additionalAttributes = resolveAdditionalAttributes(entity);
  return (
    additionalAttributes.social_profiles ||
    additionalAttributes.socialProfiles ||
    {}
  );
};

const resolveMessageSearchTerms = message => {
  const contentAttributes =
    message?.content_attributes || message?.contentAttributes || {};
  const emailAttributes = contentAttributes.email || {};

  return compactValues([
    message?.content,
    message?.processed_message_content,
    message?.processedMessageContent,
    contentAttributes.text,
    contentAttributes.text_content,
    contentAttributes.textContent,
    contentAttributes.transcribed_text,
    contentAttributes.transcribedText,
    emailAttributes.subject,
    emailAttributes.text_content,
    emailAttributes.textContent,
  ]);
};

const resolveConversationSearchTerms = (conversation = {}, contact = {}) => {
  const sender = conversation?.meta?.sender || {};
  const contactAdditionalAttributes = resolveAdditionalAttributes(contact);
  const senderAdditionalAttributes = resolveAdditionalAttributes(sender);
  const messages = Array.isArray(conversation.messages)
    ? conversation.messages
    : [];
  const lastMessages = [
    conversation.last_non_activity_message,
    conversation.lastNonActivityMessage,
    conversation.message,
  ].filter(Boolean);

  return compactValues([
    contact.name,
    sender.name,
    contact.identifier,
    sender.identifier,
    contact.phone_number,
    contact.phoneNumber,
    sender.phone_number,
    sender.phoneNumber,
    contact.email,
    sender.email,
    conversation.id,
    conversation.id ? `#${conversation.id}` : '',
    conversation.display_id,
    conversation.displayId,
    conversation.display_id ? `#${conversation.display_id}` : '',
    conversation.displayId ? `#${conversation.displayId}` : '',
    Object.values(resolveSocialProfiles(contact)),
    Object.values(resolveSocialProfiles(sender)),
    contactAdditionalAttributes.social_telegram_user_name,
    contactAdditionalAttributes.socialTelegramUserName,
    senderAdditionalAttributes.social_telegram_user_name,
    senderAdditionalAttributes.socialTelegramUserName,
    contactAdditionalAttributes.screen_name,
    contactAdditionalAttributes.screenName,
    senderAdditionalAttributes.screen_name,
    senderAdditionalAttributes.screenName,
    messages.map(resolveMessageSearchTerms),
    lastMessages.map(resolveMessageSearchTerms),
  ]);
};

const resolveConversationPhones = (conversation = {}, contact = {}) => {
  const sender = conversation?.meta?.sender || {};

  return compactValues([
    contact.phone_number,
    contact.phoneNumber,
    sender.phone_number,
    sender.phoneNumber,
  ]);
};

export const conversationMatchesLocalSearch = (
  conversation = {},
  contact = {},
  query = ''
) => {
  const normalizedQuery = normalizeSearchValue(query);

  if (!normalizedQuery) {
    return true;
  }

  const matchesText = resolveConversationSearchTerms(
    conversation,
    contact
  ).some(value => normalizeSearchValue(value).includes(normalizedQuery));

  // A phone number typed in any format (8 707 ..., +7 (707) ...) is also matched by its digits.
  return (
    matchesText ||
    resolveConversationPhones(conversation, contact).some(phone =>
      phoneMatchesQuery(phone, query)
    )
  );
};
