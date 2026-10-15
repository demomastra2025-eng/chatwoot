# The platform switch of every channel: which channels clinics see in the operator app and can connect.
# Saved in InstallationConfig CHANNEL_VISIBILITY (Channels::PlatformVisibility); a single clinic can still be given
# an exception on its own card (Accounts::ChannelOverrides). Channels that are already connected keep working.
class SuperAdmin::ChannelsController < SuperAdmin::ApplicationController
  def show
    @rows = channel_rows
    @updated_at = Channels::PlatformVisibility.updated_at
  end

  def update
    changes = Channels::PlatformVisibility.update!(submitted_states, actor: current_super_admin, request: request)
    notice_key = changes.any? ? :saved : :unchanged
    redirect_to super_admin_channels_path, notice: I18n.t("super_admin.channels.flashes.#{notice_key}")
  rescue Channels::PlatformVisibility::InvalidSettings
    redirect_to super_admin_channels_path, alert: I18n.t('super_admin.channels.flashes.invalid')
  end

  private

  def submitted_states
    raw = params[:channels]
    raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
  end

  # One row per catalog channel: the entry, whether the platform shows it, how many inboxes exist, how many clinics have
  # an exception of their own.
  def channel_rows
    settings = Channels::PlatformVisibility.settings
    inboxes = Channels::Stats.inbox_counts
    overrides = Channels::Stats.override_counts
    Channels::Catalog.entries.map do |entry|
      {
        entry: entry,
        shown: Channels::PlatformVisibility.shown?(entry.key, settings: settings),
        inboxes: inboxes[entry.key],
        overrides: overrides[entry.key]
      }
    end
  end
end
