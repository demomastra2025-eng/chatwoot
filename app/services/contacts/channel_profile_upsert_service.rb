class Contacts::ChannelProfileUpsertService
  pattr_initialize [:contact_inbox!, :profile_attributes, :provider]

  def perform
    return if contact_inbox.blank?

    profile = ContactChannelProfile.find_or_initialize_by(contact_inbox: contact_inbox)
    profile.assign_attributes(profile_attributes_for(profile))
    profile.save!
    profile
  end

  private

  def attributes
    @attributes ||= (profile_attributes || {}).with_indifferent_access
  end

  def profile_attributes_for(profile)
    context_attributes.merge(
      channel_profile_attributes(profile),
      profile_data: merged_profile_data(profile),
      last_synced_at: Time.current
    ).compact
  end

  def context_attributes
    {
      account: contact_inbox.inbox.account,
      contact: contact_inbox.contact,
      inbox: contact_inbox.inbox,
      channel_type: contact_inbox.inbox.channel_type,
      provider: provider_name,
      source_id: contact_inbox.source_id
    }
  end

  def channel_profile_attributes(profile)
    {
      identifier: preferred_identifier(profile),
      display_name: preferred_display_name(profile),
      avatar_url: preferred_avatar_url(profile),
      username: preferred_username(profile),
      phone_number: preferred_phone_number(profile),
      email: preferred_email(profile)
    }
  end

  def preferred_identifier(profile)
    attributes[:identifier].presence || profile_data[:identifier].presence || profile.identifier
  end

  def preferred_display_name(profile)
    attributes[:display_name].presence || attributes[:name].presence || profile_data[:display_name].presence || profile_data[:name].presence ||
      profile.display_name
  end

  def preferred_avatar_url(profile)
    candidate = attributes[:avatar_url].presence || attributes[:profile_photo_url].presence || attributes[:profile_pic_url].presence ||
                profile_data[:avatar_url].presence || profile_data[:profile_photo_url].presence || profile_data[:profile_pic_url].presence ||
                profile.stored_avatar_url

    ContactChannelProfile.persistable_avatar_url(provider: provider_name, avatar_url: candidate)
  end

  def preferred_username(profile)
    attributes[:username].presence || profile_data[:username].presence || profile.username
  end

  def preferred_phone_number(profile)
    normalized_phone_number || profile.phone_number
  end

  def preferred_email(profile)
    attributes[:email].presence || profile_data[:email].presence || profile.email
  end

  def provider_name
    fallback_provider = contact_inbox.inbox.channel_type.demodulize.underscore
    (provider.presence || attributes[:provider].presence || profile_data[:provider].presence || fallback_provider).to_s
  end

  def merged_profile_data(profile)
    merged_data = (profile.profile_data || {}).deep_stringify_keys.deep_merge(profile_data.deep_stringify_keys)
    ContactChannelProfile.sanitize_profile_data(provider: provider_name, profile_data: merged_data)
  end

  def profile_data
    @profile_data ||= begin
      data = {}
      data.merge!(attributes[:additional_attributes].to_h) if attributes[:additional_attributes].present?
      data.merge!(attributes[:profile_data].to_h) if attributes[:profile_data].present?
      data.merge!(attributes.except(:custom_attributes, :additional_attributes, :profile_data).to_h)
      data.compact.with_indifferent_access
    end
  end

  def normalized_phone_number
    value = attributes[:phone_number].presence || profile_data[:phone_number].presence
    return if value.blank?

    Contacts::PhoneNumberNormalizer.normalize(value) || value
  end
end
