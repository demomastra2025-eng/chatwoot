# frozen_string_literal: true

# The time zones a new account is offered: a short list of the places the platform's clients are in, Astana first. The value
# is the name of the zone (Asia/Almaty is Astana and Almaty: Kazakhstan has a single zone, UTC+5, since 2024-03-01); the
# offset in the label is read from the zone itself, so it follows the real rules and nobody types it.
#
# The zone of an account is its `reporting_timezone` (the day boundaries of the reports and the CRM) and its
# `workspace_timezone` (working hours); a new account gets the same zone in both.
class SuperAdmin::AccountTimezones
  # The key of the name in the locale (super_admin.onboarding.timezones) => the name of the zone
  ZONES = {
    'astana' => 'Asia/Almaty',
    'moscow' => 'Europe/Moscow',
    'tashkent' => 'Asia/Tashkent',
    'bishkek' => 'Asia/Bishkek',
    'baku' => 'Asia/Baku',
    'tbilisi' => 'Asia/Tbilisi',
    'yerevan' => 'Asia/Yerevan',
    'minsk' => 'Europe/Minsk',
    'kyiv' => 'Europe/Kiev',
    'istanbul' => 'Europe/Istanbul',
    'dubai' => 'Asia/Dubai'
  }.freeze
  DEFAULT = ZONES.fetch('astana')

  class << self
    # [["Астана, Алматы (UTC+5)", "Asia/Almaty"], ...] in the order of ZONES
    def options
      ZONES.map { |key, zone| [label(key, zone), zone] }
    end

    def identifiers
      ZONES.values
    end

    def known?(zone)
      identifiers.include?(zone)
    end

    # The label of a stored zone; a zone outside the list is shown as it is stored
    def label_for(zone)
      key = ZONES.key(zone)
      key ? label(key, zone) : zone.to_s
    end

    private

    def label(key, zone)
      "#{I18n.t("super_admin.onboarding.timezones.#{key}")} (#{offset(zone)})"
    end

    # «UTC+5», «UTC+5:30»
    def offset(zone)
      seconds = ActiveSupport::TimeZone[zone].now.utc_offset
      hours, minutes = seconds.abs.divmod(3600)
      minutes /= 60
      sign = seconds.negative? ? '-' : '+'
      minutes.zero? ? "UTC#{sign}#{hours}" : "UTC#{sign}#{hours}:#{format('%02d', minutes)}"
    end
  end
end
