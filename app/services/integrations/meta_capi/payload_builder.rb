# frozen_string_literal: true

require 'digest'

class Integrations::MetaCapi::PayloadBuilder
  DEFAULT_CURRENCY = 'KZT'

  def initialize(account:, hook:, record: nil)
    @account = account
    @hook = hook
    @record = record
  end

  def build_deal_event(event_name:, event_id:)
    deal = @record
    contact = deal.primary_contact || deal.contacts.first
    conversation = deal.originating_conversation
    referral = resolve_referral(contact: contact, conversation: conversation, thread: deal.originating_communication_thread)
    messaging_ctx = resolve_messaging_context(referral: referral, conversation: conversation)

    build_envelope(
      event_name: event_name,
      event_id: event_id,
      messaging_ctx: messaging_ctx,
      user_data: build_user_data(contact: contact, referral: referral, messaging_ctx: messaging_ctx),
      custom_data: build_deal_custom_data(deal, messaging_ctx)
    )
  end

  def build_appointment_event(event_name:, event_id:)
    appointment = @record
    contact = appointment.contact
    conversation = appointment.conversation
    referral = resolve_referral(contact: contact, conversation: conversation, thread: nil)
    messaging_ctx = resolve_messaging_context(referral: referral, conversation: conversation)

    build_envelope(
      event_name: event_name,
      event_id: event_id,
      messaging_ctx: messaging_ctx,
      user_data: build_user_data(contact: contact, referral: referral, messaging_ctx: messaging_ctx),
      custom_data: build_appointment_custom_data(appointment, messaging_ctx)
    )
  end

  def build_test_event
    {
      event_name: 'Lead',
      event_time: Time.current.to_i,
      event_id: "onelink_test_#{@account.id}_#{Time.current.to_i}",
      action_source: 'system_generated',
      user_data: {
        external_id: [sha256("account_#{@account.id}")],
        ph: [sha256('77000000000')]
      },
      custom_data: {
        currency: default_currency,
        value: 0.0,
        event_source: 'crm',
        lead_event_source: 'OneLink CRM'
      }
    }
  end

  private

  def build_envelope(event_name:, event_id:, messaging_ctx:, user_data:, custom_data:)
    payload = {
      event_name: event_name,
      event_time: Time.current.to_i,
      event_id: event_id,
      action_source: messaging_ctx[:active] ? 'business_messaging' : 'system_generated',
      user_data: user_data,
      custom_data: custom_data
    }
    payload[:messaging_channel] = messaging_ctx[:channel] if messaging_ctx[:active]
    payload
  end

  def resolve_referral(contact:, conversation:, thread:)
    find_ctwa_referral(conversation_id: conversation&.id) ||
      find_ctwa_referral(communication_thread_id: thread&.id) ||
      find_ctwa_referral(contact_id: contact&.id)
  end

  def find_ctwa_referral(filters)
    clean_filters = filters.compact
    return nil if clean_filters.empty?

    MetaAdReferral.where(account_id: @account.id)
                  .where(clean_filters)
                  .where.not(ctwa_clid: [nil, ''])
                  .order(received_at: :desc)
                  .first
  end

  def resolve_messaging_context(referral:, conversation:)
    ctwa_clid = extract_ctwa_clid(referral, conversation)
    return { active: false } if ctwa_clid.blank?

    build_active_messaging_context(ctwa_clid, conversation)
  end

  def extract_ctwa_clid(referral, conversation)
    referral&.ctwa_clid.presence || conversation&.additional_attributes&.dig('meta_ad_referral', 'ctwa_clid').presence
  end

  def build_active_messaging_context(ctwa_clid, conversation)
    waba_id = configured_waba_id(conversation)
    return { active: true, channel: 'whatsapp', ctwa_clid: ctwa_clid, waba_id: waba_id } if waba_id.present?

    page_id = configured_page_id(conversation)
    return { active: true, channel: 'instagram', ctwa_clid: ctwa_clid, page_id: page_id } if page_id.present?

    { active: false, ctwa_clid: ctwa_clid }
  end

  def configured_waba_id(conversation)
    explicit = @hook&.settings&.dig('whatsapp_business_account_id').to_s.strip
    return explicit if explicit.present?

    inbox_waba_id(conversation&.inbox&.channel) || fallback_account_waba_id
  end

  def inbox_waba_id(channel)
    return nil unless channel.is_a?(Channel::Whatsapp) && channel.provider_config.is_a?(Hash)

    channel.provider_config['business_account_id'].to_s.strip.presence
  end

  def fallback_account_waba_id
    Channel::Whatsapp.where(account_id: @account.id).find_each do |ch|
      waba = inbox_waba_id(ch)
      return waba if waba.present?
    end
    nil
  end

  def configured_page_id(conversation)
    explicit = @hook&.settings&.dig('page_id').to_s.strip
    return explicit if explicit.present?

    channel = conversation&.inbox&.channel
    channel.page_id.to_s.strip.presence if channel.respond_to?(:page_id)
  end

  def build_user_data(contact:, referral:, messaging_ctx:)
    data = {}
    if messaging_ctx[:ctwa_clid].present?
      data[:ctwa_clid] = messaging_ctx[:ctwa_clid]
      data[:whatsapp_business_account_id] = messaging_ctx[:waba_id] if messaging_ctx[:waba_id].present?
      data[:page_id] = messaging_ctx[:page_id] if messaging_ctx[:page_id].present?
    end
    append_contact_hashes!(data, contact, referral) if contact.present?
    data[:external_id] ||= [sha256("account_#{@account.id}")]
    data
  end

  def append_contact_hashes!(data, contact, referral)
    append_identity_hashes!(data, contact)
    data[:external_id] = [sha256("contact_#{contact.id}")]
    lead_id = contact.additional_attributes&.dig('meta_lead_id').presence || referral&.source_id.presence
    data[:lead_id] = lead_id.to_i if lead_id.to_s.match?(/\A\d+\z/)
  end

  def append_identity_hashes!(data, contact)
    digits = contact.phone_number.to_s.gsub(/\D/, '')
    data[:ph] = [sha256(digits)] if digits.length >= 7
    email = contact.email.to_s.strip.downcase
    data[:em] = [sha256(email)] if email.present?
    first_name = contact.name.to_s.strip.split(/\s+/).first.to_s.downcase
    data[:fn] = [sha256(first_name)] if first_name.present?
  end

  def build_deal_custom_data(deal, messaging_ctx)
    data = {
      currency: deal.currency.presence || default_currency,
      value: (deal.amount_minor.to_i / 100.0).round(2),
      content_name: deal.title.to_s.truncate(120),
      order_id: "deal_#{deal.id}"
    }
    append_crm_source!(data) unless messaging_ctx[:active]
    data
  end

  def build_appointment_custom_data(appointment, messaging_ctx)
    paid_total = appointment.prepaid_amount.to_i + appointment.settlement_amount.to_i
    amount = (paid_total.positive? ? paid_total : appointment.service_amount.to_i).to_f.round(2)
    data = {
      currency: default_currency,
      value: amount,
      content_name: appointment.service&.name.presence || "Appointment ##{appointment.id}",
      order_id: "appointment_#{appointment.id}"
    }
    append_crm_source!(data) unless messaging_ctx[:active]
    data
  end

  def append_crm_source!(data)
    data[:event_source] = 'crm'
    data[:lead_event_source] = 'OneLink CRM'
  end

  def default_currency
    @hook&.settings&.dig('default_currency').to_s.strip.upcase.presence || DEFAULT_CURRENCY
  end

  def sha256(value)
    Digest::SHA256.hexdigest(value.to_s)
  end
end
