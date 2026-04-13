class Twitter::WebhooksBaseService
  private

  def profile_id
    payload[:for_user_id]
  end

  def additional_contact_attributes(user)
    {
      screen_name: user['screen_name'],
      social_profiles: { twitter: user['screen_name'] }.compact,
      social_twitter_user_name: user['screen_name'],
      location: user['location'],
      url: user['url'],
      description: user['description'],
      followers_count: user['followers_count'],
      friends_count: user['friends_count'],
      profile_image_url: user['profile_image_url'].presence || user['profile_image_url_https'].presence
    }
  end

  def set_inbox
    twitter_profile = ::Channel::TwitterProfile.find_by(profile_id: profile_id)
    @inbox = ::Inbox.find_by!(channel: twitter_profile)
  end

  def find_or_create_contact(user)
    @contact_inbox = @inbox.contact_inboxes.where(source_id: user['id']).first
    @contact = @contact_inbox.contact if @contact_inbox
    if @contact
      sync_channel_profile(user)
      return
    end

    @contact_inbox = @inbox.channel.create_contact_inbox(
      user['id'], user['name'], additional_contact_attributes(user)
    )
    @contact = @contact_inbox.contact
    sync_channel_profile(user)
    Avatar::AvatarFromUrlJob.perform_later(@contact, user['profile_image_url']) if user['profile_image_url']
  end

  def sync_channel_profile(user)
    Contacts::ChannelProfileUpsertService.new(
      contact_inbox: @contact_inbox,
      provider: 'twitter_profile',
      profile_attributes: {
        display_name: user['name'],
        username: user['screen_name'],
        avatar_url: user['profile_image_url'].presence || user['profile_image_url_https'].presence,
        profile_data: additional_contact_attributes(user)
      }
    ).perform
  end
end
