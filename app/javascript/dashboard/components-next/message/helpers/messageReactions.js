export function extractNormalizedReactions({
  contentAttributes = {},
  currentUserId = null,
  t = k => k,
} = {}) {
  const attrs = contentAttributes || {};
  const whatsappReactions =
    attrs.whatsappReactions || attrs.whatsapp_reactions || {};
  const telegramReactions =
    attrs.telegramReactions || attrs.telegram_reactions || {};
  const agentReactions =
    attrs.agentReactions || attrs.agent_reactions || {};

  const grouped = new Map();

  const ensureGroup = (key, labelEmoji) => {
    if (!grouped.has(key)) {
      grouped.set(key, {
        key,
        emoji: labelEmoji,
        count: 0,
        reactedByMe: false,
        actors: [],
        interactive: true,
      });
    }
    return grouped.get(key);
  };

  const hasTelegramResults =
    Array.isArray(telegramReactions?.results) &&
    telegramReactions.results.length > 0;
  const hasWhatsappReactions =
    whatsappReactions &&
    typeof whatsappReactions === 'object' &&
    Object.keys(whatsappReactions).length > 0;

  if (hasTelegramResults) {
    telegramReactions.results.forEach(item => {
      const reaction = item?.reaction || {};
      const count = Number(item?.count || 0);
      if (count <= 0) return;

      if (reaction.emoji) {
        const group = ensureGroup(reaction.emoji, reaction.emoji);
        group.count += count;
        if (item.chosen) {
          group.reactedByMe = true;
        }
      } else if (reaction.type === 'custom_emoji') {
        const label = t('CONVERSATION.TELEGRAM.CUSTOM_EMOJI');
        const group = ensureGroup(`custom:${reaction.custom_emoji_id || label}`, '✨');
        group.label = label;
        group.count += count;
        group.interactive = false;
      } else if (reaction.type === 'paid') {
        const label = t('CONVERSATION.TELEGRAM.PAID_REACTION');
        const group = ensureGroup('paid', '⭐');
        group.label = label;
        group.count += count;
        group.interactive = false;
      } else {
        const label = t('CONVERSATION.TELEGRAM.REACTION');
        const group = ensureGroup('telegram_reaction', '👍');
        group.label = label;
        group.count += count;
        group.interactive = false;
      }
    });
  } else if (hasWhatsappReactions) {
    Object.entries(whatsappReactions).forEach(([actorId, data]) => {
      const emoji = data?.emoji;
      if (!emoji) return;

      const group = ensureGroup(emoji, emoji);
      group.count += 1;
      const reactionUserId = data?.userId ?? data?.user_id;
      const reactionUserName = data?.userName ?? data?.user_name;
      if (
        actorId === 'business' ||
        (currentUserId && Number(reactionUserId) === Number(currentUserId))
      ) {
        group.reactedByMe = true;
      }
      if (reactionUserName) {
        group.actors.push(reactionUserName);
      }
    });
  } else if (agentReactions && typeof agentReactions === 'object') {
    Object.entries(agentReactions).forEach(([actorKey, data]) => {
      const emoji = data?.emoji;
      if (!emoji) return;

      const group = ensureGroup(emoji, emoji);
      group.count += 1;
      const reactionUserId = data?.userId ?? data?.user_id;
      const reactionUserName = data?.userName ?? data?.user_name;
      if (
        (currentUserId && Number(reactionUserId) === Number(currentUserId)) ||
        actorKey === `user:${currentUserId}` ||
        actorKey === 'agent'
      ) {
        group.reactedByMe = true;
      }
      if (reactionUserName) {
        group.actors.push(reactionUserName);
      }
    });
  }

  return Array.from(grouped.values());
}

export function getCurrentUserReactionEmoji(contentAttributes = {}, currentUserId = null) {
  const attrs = contentAttributes || {};
  const agentReactions = attrs.agentReactions || attrs.agent_reactions || {};
  if (currentUserId && agentReactions[`user:${currentUserId}`]?.emoji) {
    return agentReactions[`user:${currentUserId}`].emoji;
  }

  const whatsappReactions =
    attrs.whatsappReactions || attrs.whatsapp_reactions || {};
  if (whatsappReactions?.business?.emoji) {
    return whatsappReactions.business.emoji;
  }

  const telegramReactions =
    attrs.telegramReactions || attrs.telegram_reactions || {};
  if (Array.isArray(telegramReactions?.results)) {
    const chosen = telegramReactions.results.find(item => item?.chosen);
    if (chosen?.reaction?.emoji) {
      return chosen.reaction.emoji;
    }
  }

  return '';
}
