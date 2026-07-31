const crypto = require('node:crypto');

class RuntimeSelector {
  constructor({
    enabled = false,
    providers = [],
    accountIds = [],
    channelIds = [],
    percentage = 0
  } = {}) {
    this.enabled = enabled === true;
    this.providers = normalizeList(providers);
    this.accountIds = normalizeList(accountIds);
    this.channelIds = normalizeList(channelIds);
    this.percentage = clampPercentage(percentage);
  }

  select(payload = {}) {
    if (!this.enabled) return 'legacy';
    if (this.providers.length === 0 || this.accountIds.length === 0 || this.channelIds.length === 0) return 'legacy';
    if (!isExplicitAiRoute(payload)) return 'legacy';
    if (isJanusSip(payload) && !isVoiceAgentProfile(payload.sip_profile || payload.sipProfile)) return 'legacy';
    if (!matches(this.providers, payload.provider)) return 'legacy';
    if (!matches(this.accountIds, payload.account_id || payload.accountId)) return 'legacy';
    if (!matches(this.channelIds, payload.inbox_id || payload.inboxId)) return 'legacy';
    if (!percentageMatches(this.percentage, payload.call_ref || payload.callRef)) return 'legacy';
    return 'pipecat';
  }
}

function isExplicitAiRoute(payload = {}) {
  const action = String(payload.routing?.action || payload.route_decision?.action || '')
    .trim()
    .toLowerCase();
  return action === 'ai' || action === 'ai_accept';
}

function isJanusSip(payload = {}) {
  return String(payload.transport || '').trim().toLowerCase() === 'janus_sip';
}

function isVoiceAgentProfile(profile = {}) {
  return profile?.voice_agent === true &&
    String(profile?.profile_kind || '').trim().toLowerCase() === 'voice_agent';
}

function assertAiRoute(payload = {}) {
  if (isExplicitAiRoute(payload)) return true;

  const action = String(payload.routing?.action || payload.route_decision?.action || '').trim();

  const error = new Error(action
    ? 'Only AI routes are accepted by the AI Voice runtime'
    : 'An explicit AI routing action is required');
  error.code = action ? 'non_ai_route_not_supported' : 'ai_route_required';
  error.statusCode = 422;
  throw error;
}

function percentageMatches(percentage, callRef) {
  if (percentage <= 0) return false;
  if (percentage >= 100) return true;
  const digest = crypto.createHash('sha256').update(String(callRef || '')).digest();
  return digest.readUInt32BE(0) % 100 < percentage;
}

function matches(allowlist, value) {
  return allowlist.length === 0 || allowlist.includes(String(value ?? '').trim().toLowerCase());
}

function normalizeList(values) {
  const source = Array.isArray(values) ? values : String(values || '').split(',');
  return source.map(value => String(value).trim().toLowerCase()).filter(Boolean);
}

function clampPercentage(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return 0;
  return Math.max(0, Math.min(100, parsed));
}

module.exports = { RuntimeSelector, assertAiRoute, percentageMatches };
