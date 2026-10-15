# frozen_string_literal: true

# Opens and closes channels the way the operator does, for specs that create inboxes of channels the platform hides by
# default (api, sms, line, weixin, vk_community, tiktok, twitter).
module ChannelVisibilityHelpers
  # An exception on ONE clinic's card: the channels are shown to that clinic whatever the platform says
  def show_channels_for(account, *keys)
    set_channel_overrides(account, keys, Channels::Catalog::SHOWN)
  end

  # An exception on ONE clinic's card: the channels are hidden from that clinic whatever the platform says
  def hide_channels_for(account, *keys)
    set_channel_overrides(account, keys, Channels::Catalog::HIDDEN)
  end

  # The platform switch of the channels ({ 'api' => 'shown' })
  def change_platform_channel_visibility(states)
    Channels::PlatformVisibility.update!(states)
  end

  private

  def set_channel_overrides(account, keys, state)
    Accounts::ChannelOverrides.new(account: account).apply(keys.flatten.index_with { state })
  end
end
