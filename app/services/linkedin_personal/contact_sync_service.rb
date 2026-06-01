class LinkedinPersonal::ContactSyncService
  pattr_initialize [:inbox!, :params!]

  def perform
    return if profile_urn.blank?

    @contact_inbox = ContactInboxWithContactBuilder.new(
      inbox: inbox,
      source_id: profile_urn,
      contact_attributes: contact_attributes,
      skip_runtime_events: true
    ).perform

    @contact = @contact_inbox.contact
    sync_existing_contact!
    sync_channel_profile!
    @contact_inbox.reload
  end

  private

  def contact_attributes
    {
      name: display_name,
      identifier: contact_identifier,
      additional_attributes: additional_attributes
    }.compact
  end

  def sync_existing_contact!
    current_attributes = (@contact.additional_attributes || {}).deep_stringify_keys
    merged_attributes = current_attributes.merge(additional_attributes.deep_stringify_keys)
    merged_attributes['channel_profiles'] = merged_channel_profiles(current_attributes)

    updates = {}
    updates[:additional_attributes] = merged_attributes if merged_attributes != current_attributes
    updates[:identifier] = contact_identifier if @contact.identifier.blank? && contact_identifier.present?
    updates[:name] = display_name if should_replace_contact_name?
    updates[:last_activity_at] = latest_activity_at if latest_activity_at.present? &&
                                                       (@contact.last_activity_at.blank? || latest_activity_at > @contact.last_activity_at)
    return if updates.blank?

    @contact.skip_runtime_events = true
    @contact.update!(updates)
  end

  def sync_channel_profile!
    profile_data = linkedin_channel_profile
    Contacts::ChannelProfileUpsertService.new(
      contact_inbox: @contact_inbox,
      provider: 'linkedin_personal',
      profile_attributes: profile_data.merge(
        display_name: display_name,
        profile_data: profile_data
      )
    ).perform
  end

  def merged_channel_profiles(current_attributes)
    channel_profiles = (current_attributes['channel_profiles'] || {}).deep_stringify_keys
    linkedin_profiles = (channel_profiles['linkedin_personal'] || {}).deep_stringify_keys
    linkedin_profiles[contact_identifier] = linkedin_channel_profile
    channel_profiles.merge('linkedin_personal' => linkedin_profiles)
  end

  def additional_attributes
    {
      provider: 'linkedin_personal',
      social_linkedin_profile_urn: profile_urn,
      social_linkedin_public_identifier: public_identifier,
      linkedin_headline: params[:headline],
      linkedin_profile_url: params[:profile_url],
      first_name: params[:first_name],
      last_name: params[:last_name],
      sync_source: params[:sync_source],
      last_message_at: latest_activity_at&.iso8601,
      unread_count: params[:unread_count]
    }.compact
  end

  def linkedin_channel_profile
    {
      identifier: contact_identifier,
      source_id: profile_urn,
      inbox_id: inbox.id,
      profile_urn: profile_urn,
      public_identifier: public_identifier,
      first_name: params[:first_name],
      last_name: params[:last_name],
      headline: params[:headline],
      profile_url: params[:profile_url],
      sync_source: params[:sync_source],
      last_message_at: latest_activity_at&.iso8601,
      unread_count: params[:unread_count]
    }.compact.deep_stringify_keys
  end

  def should_replace_contact_name?
    @contact.name.blank? || @contact.name == profile_urn
  end

  def display_name
    [
      [params[:first_name], params[:last_name]].compact.join(' ').strip.presence,
      params[:name].presence,
      public_identifier,
      profile_urn
    ].compact.first.to_s.truncate(100)
  end

  def contact_identifier
    "linkedin_personal:#{profile_urn}"
  end

  def profile_urn
    params[:profile_urn].presence || params[:sender_urn].presence || params[:participant_urn].presence
  end

  def public_identifier
    params[:public_identifier].presence || params[:profile_url].to_s.split('/in/').last.to_s.split('/').first.presence
  end

  def latest_activity_at
    return @latest_activity_at if defined?(@latest_activity_at)

    value = params[:last_message_at].presence || params[:message_created_at].presence || params[:external_created_at].presence
    @latest_activity_at = value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError, TypeError
    @latest_activity_at = nil
  end
end
