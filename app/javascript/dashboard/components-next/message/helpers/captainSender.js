import { SENDER_TYPES } from '../constants';

// Push payloads use `captain_assistant`; raw message JSON may carry the
// polymorphic class name in sender_type.
const CAPTAIN_SENDER_TYPES = [
  SENDER_TYPES.CAPTAIN_ASSISTANT,
  'Captain::Assistant',
];

const normalizeType = value => (typeof value === 'string' ? value.trim() : '');

const normalizeText = value => {
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number') return String(value);
  return '';
};

/**
 * Whether a message was sent by a Captain AI agent.
 * The sender payload type wins over the message sender type.
 * @param {Object|null} sender - Message sender payload
 * @param {string|null} senderType - Message sender type
 * @returns {boolean}
 */
export const isCaptainAssistantSender = (sender, senderType) => {
  const type = normalizeType(sender?.type) || normalizeType(senderType);
  return CAPTAIN_SENDER_TYPES.includes(type);
};

const rawContributorList = attributes => {
  if (!attributes || typeof attributes !== 'object') return [];

  const list =
    attributes.councilContributors ?? attributes.council_contributors;
  return Array.isArray(list) ? list : [];
};

const normalizeContributor = entry => {
  if (!entry || typeof entry !== 'object') return null;

  const name = normalizeText(entry.name);
  if (!name) return null;

  const avatarUrl = entry.avatarUrl || entry.avatar_url || '';

  return {
    id: entry.id ?? null,
    name,
    avatarUrl: typeof avatarUrl === 'string' ? avatarUrl : '',
  };
};

const contributorKey = contributor =>
  contributor.id === null || contributor.id === undefined
    ? `name:${contributor.name}`
    : `id:${contributor.id}`;

/**
 * Agents that took part in a council reply, read from content attributes
 * first and additional attributes second. Accepts camelCase and snake_case
 * payloads, drops entries without a name and removes duplicate ids.
 * @param {{contentAttributes?: Object, additionalAttributes?: Object}} message
 * @returns {{id: (number|string|null), name: string, avatarUrl: string}[]}
 */
export const councilContributors = ({
  contentAttributes,
  additionalAttributes,
} = {}) => {
  const fromContent = rawContributorList(contentAttributes);
  const list = fromContent.length
    ? fromContent
    : rawContributorList(additionalAttributes);

  const seen = new Set();
  return list.reduce((result, entry) => {
    const contributor = normalizeContributor(entry);
    if (!contributor) return result;

    const key = contributorKey(contributor);
    if (seen.has(key)) return result;

    seen.add(key);
    result.push(contributor);
    return result;
  }, []);
};

/**
 * Names of the council members for the caption.
 * @param {{name: string}[]} contributors
 * @returns {string}
 */
export const councilCaption = contributors =>
  (Array.isArray(contributors) ? contributors : [])
    .map(contributor => normalizeText(contributor?.name))
    .filter(Boolean)
    .join(', ');
