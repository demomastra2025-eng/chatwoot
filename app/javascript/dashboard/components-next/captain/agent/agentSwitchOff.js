import { voiceInboxesForAgent } from './agentVoice';

// What the admin is told before an agent is switched off. Every agent has the
// same switch; the warning only says what the switch-off changes: the agent
// answers the calls of a number, or it is the last one that is on (then the AI
// stops replying and suggesting replies).
export const isAgentActive = agent => agent?.active !== false;

export const enabledAgentsCount = agents =>
  (agents || []).filter(isAgentActive).length;

const numberLabel = inbox =>
  inbox?.phone_number || inbox?.name || `#${inbox?.id}`;

// Returns { key, params }[] of the confirmation texts that apply, in order.
export const switchOffWarnings = ({ agent, agents, inboxes }) => {
  const warnings = [];
  const numbers = voiceInboxesForAgent(agent, inboxes).map(numberLabel);
  if (numbers.length) {
    warnings.push({
      key: 'CAPTAIN.GALLERY.CONFIRM_DISABLE_VOICE',
      params: { numbers: numbers.join(', ') },
    });
  }
  if (isAgentActive(agent) && enabledAgentsCount(agents) <= 1) {
    warnings.push({ key: 'CAPTAIN.GALLERY.CONFIRM_DISABLE_LAST', params: {} });
  }
  return warnings;
};
