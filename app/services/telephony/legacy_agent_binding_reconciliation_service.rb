# frozen_string_literal: true

class Telephony::LegacyAgentBindingReconciliationService
  DISABLED_REASON = 'superseded_by_native_sip_profiles'
  MANAGED_ONLY_DISABLED_REASON = 'managed_voice_inboxes_do_not_use_legacy_bindings'
  DISABLED_BY = 'telephony_legacy_agent_binding_reconciliation'
  ACTIVE_SIP_PROFILE_STATUSES = ['active'].freeze

  def initialize(account: nil, inbox: nil, user: nil, dry_run: false)
    @account = account
    @inbox = inbox
    @user = user
    @dry_run = ActiveModel::Type::Boolean.new.cast(dry_run)
  end

  def perform
    result = empty_result

    binding_scope.find_each do |binding|
      decision = reconciliation_decision(binding)
      result[:checked] += 1

      if decision[:disable]
        result[:disabled] += 1
        result[:binding_ids] << binding.id
        disable_binding!(binding, decision) unless dry_run
      else
        result[:skipped] += 1
        result[:skip_reasons][decision[:reason]] += 1
      end
    end

    result[:dry_run] = dry_run
    result
  end

  private

  attr_reader :account, :inbox, :user, :dry_run

  def empty_result
    {
      checked: 0,
      disabled: 0,
      skipped: 0,
      binding_ids: [],
      skip_reasons: Hash.new(0)
    }
  end

  def binding_scope
    scope = Telephony::AgentBinding.where(provider: 'fonoster', enabled: true).includes(:account, :user)
    scope = scope.where(account_id: account.id) if account.present?
    scope = scope.where(user_id: user.id) if user.present?
    scope = scope.where(user_id: inbox.members.select(:id)) if inbox.present? && inbox.inbox_members.exists?
    scope
  end

  def reconciliation_decision(binding)
    return skip(:active_call_session) if active_call_session?(binding)

    profiles = active_sip_profiles_for(binding)
    eligible_inboxes = eligible_voice_inboxes_for(binding)
    legacy_inbox_ids = eligible_inboxes.reject { |candidate| managed_voice_inbox?(candidate) }.map(&:id).uniq
    managed_inbox_ids = eligible_inboxes.select { |candidate| managed_voice_inbox?(candidate) }.map(&:id).uniq
    if legacy_inbox_ids.blank? && managed_inbox_ids.present?
      return disable(
        profiles,
        legacy_inbox_ids,
        disabled_reason: MANAGED_ONLY_DISABLED_REASON,
        managed_inbox_ids: managed_inbox_ids
      )
    end

    return skip(:no_active_sip_profile) if profiles.blank?
    return disable(profiles, legacy_inbox_ids) if legacy_inbox_ids.blank?

    covered_inbox_ids = profiles.where(inbox_id: legacy_inbox_ids).distinct.pluck(:inbox_id)
    missing_inbox_ids = legacy_inbox_ids - covered_inbox_ids
    return skip(:unprofiled_voice_inbox, missing_inbox_ids: missing_inbox_ids) if missing_inbox_ids.present?

    disable(profiles, legacy_inbox_ids)
  end

  def active_sip_profiles_for(binding)
    binding.account.telephony_sip_profiles.where(
      user_id: binding.user_id,
      enabled: true,
      status: ACTIVE_SIP_PROFILE_STATUSES
    )
  end

  def active_call_session?(binding)
    Telephony::CallSession.active.exists?(agent_binding_id: binding.id)
  end

  def eligible_voice_inboxes_for(binding)
    inboxes = binding.account.inboxes.active.includes(:channel, :inbox_members, :telephony_number_binding).where(channel_type: 'Channel::Voice')

    inboxes.select do |candidate|
      members = candidate.inbox_members.to_a
      candidate.channel&.provider == 'fonoster' &&
        (members.blank? || members.any? { |member| member.user_id == binding.user_id })
    end
  end

  def managed_voice_inbox?(candidate)
    number_binding = if candidate.respond_to?(:telephony_number_binding)
                       candidate.telephony_number_binding
                     else
                       Telephony::NumberBinding.find_by(account_id: candidate.account_id, inbox_id: candidate.id)
                     end

    number_binding&.managed?
  end

  def disable(profiles, inbox_ids, disabled_reason: DISABLED_REASON, managed_inbox_ids: [])
    {
      disable: true,
      disabled_reason: disabled_reason,
      sip_profile_ids: profiles.distinct.pluck(:id),
      inbox_ids: inbox_ids,
      managed_inbox_ids: managed_inbox_ids
    }
  end

  def skip(reason, metadata = {})
    { disable: false, reason: reason }.merge(metadata)
  end

  def disable_binding!(binding, decision)
    metadata = binding.metadata.to_h.deep_stringify_keys
    metadata['disabled_reason'] = decision[:disabled_reason] || DISABLED_REASON
    metadata['disabled_by'] = DISABLED_BY
    metadata['disabled_at'] = Time.current.iso8601
    metadata['superseded_by_sip_profile_ids'] = decision[:sip_profile_ids]
    metadata['superseded_for_inbox_ids'] = decision[:inbox_ids]
    metadata['managed_voice_inbox_ids'] = decision[:managed_inbox_ids] if decision[:managed_inbox_ids].present?
    metadata['previous_registration_state'] ||= metadata['registration_state']
    metadata['previous_presence'] ||= metadata['presence']
    metadata['registration_state'] = 'offline'
    metadata['presence'] = 'offline'
    metadata['registered'] = false
    metadata['available'] = false

    binding.update!(enabled: false, metadata: metadata)
  end
end
