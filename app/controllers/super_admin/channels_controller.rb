# The platform switch of every channel: which channels clinics see in the operator app and can connect.
# Saved in InstallationConfig CHANNEL_VISIBILITY (Channels::PlatformVisibility); a single clinic can still be given
# an exception on its own card (Accounts::ChannelOverrides). Channels that are already connected keep working.
#
# The form posts the switches (`channels[key]`) and the state each one had when the page was drawn (`previous[key]`).
# Only the switches that moved are saved, so a page that was drawn before somebody else moved a switch does not move
# it back: two administrators cannot silently undo each other.
class SuperAdmin::ChannelsController < SuperAdmin::ApplicationController
  # What a malformed value (an array or a string where the form sends a map) is parsed as
  MALFORMED = Object.new.freeze

  def show
    load_page
  end

  def update
    requested = submitted_map(:channels)
    expected = submitted_map(:previous)
    return render_malformed if [requested, expected].include?(MALFORMED)

    changes = Channels::PlatformVisibility.update!(requested, expected: expected, actor: current_super_admin, request: request)
    notice_key = changes.any? ? :saved : :unchanged
    redirect_to super_admin_channels_path, notice: I18n.t("super_admin.channels.flashes.#{notice_key}")
  rescue Channels::PlatformVisibility::InvalidSettings
    redirect_to super_admin_channels_path, alert: I18n.t('super_admin.channels.flashes.invalid')
  end

  private

  def load_page
    @rows = channel_rows
    @updated_at = Channels::PlatformVisibility.updated_at
  end

  # nil when the param is absent, a Hash, or MALFORMED for anything that is not a map
  def submitted_map(name)
    raw = params[name]
    return if raw.nil?

    raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : MALFORMED
  end

  def render_malformed
    load_page
    flash.now[:alert] = I18n.t('super_admin.channels.flashes.malformed')
    render :show, status: :unprocessable_content
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
