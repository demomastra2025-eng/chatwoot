# Synthetic family-number fixtures for the shared patient card specs (owner model 2026-09-29).
module SharedPhoneHelpers
  FAMILY_PHONE = '+77000000009'.freeze

  def shared_phone_cloud_inbox(account)
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false,
                              phone_number: "+1555#{SecureRandom.random_number(10**7).to_s.rjust(7, '0')}").inbox
  end

  def shared_phone_chat(account, contact, inbox, source_id)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: source_id)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: contact, message_type: :incoming)
    [contact_inbox, conversation]
  end

  # options: phone, via, code, medelement_phone (nil to leave it unknown), name
  def shared_phone_card(account, owner, **options)
    phone = options.fetch(:phone, FAMILY_PHONE)
    create(:contact, account: account, name: options.fetch(:name, 'Son'), custom_attributes: {
      'medelement_patient_code' => options.fetch(:code, 'son-1'), Contacts::SharedPhone::CARD_KEY => true, 'secondary_phones' => [phone],
      Contacts::SharedPhone::SHARED_PHONE_KEY => phone, Contacts::SharedPhone::SHARED_OWNER_KEY => owner&.id,
      Contacts::SharedPhone::SHARED_VIA_KEY => options.fetch(:via, Contacts::SharedPhone::VIA_OWNER_PRIMARY),
      Contacts::SharedPhone::MEDELEMENT_PHONE_KEY => options.fetch(:medelement_phone, phone)
    }.compact)
  end

  # The shared-number capabilities ship switched off (Contacts::SharedPhoneSwitches). Specs of the switched-on
  # behaviour turn them on explicitly; after the example the rows are removed (also for non-transactional specs) and the
  # GlobalConfig cache (Redis, outside the test transaction) is cleared so no other example sees them on.
  def enable_shared_phone_switches!(*keys)
    set_shared_phone_switches!(keys.presence || Contacts::SharedPhoneSwitches::KEYS, true)
  end

  def disable_shared_phone_switches!(*keys)
    set_shared_phone_switches!(keys.presence || Contacts::SharedPhoneSwitches::KEYS, false)
  end

  def set_shared_phone_switches!(keys, value)
    keys.each { |key| InstallationConfig.find_or_initialize_by(name: key).update!(value: value, locked: false) }
    GlobalConfig.clear_cache
    @shared_phone_switches_changed = true
  end
end

RSpec.configure do |config|
  config.include SharedPhoneHelpers
  config.after do
    next unless @shared_phone_switches_changed

    InstallationConfig.where(name: Contacts::SharedPhoneSwitches::KEYS).delete_all
    GlobalConfig.clear_cache
  end
end
