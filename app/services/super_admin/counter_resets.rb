# frozen_string_literal: true

# The counters of an account that the super admin can set back to zero: the answers of the AI, the tokens of the AI and the
# e-mails of today. They count by themselves until somebody resets them, so a reset is a gift of quota paid by the platform:
# the card asks first (shared/_confirm_action) and every reset is an entry of the audit log that says what the number was.
#
#   resets = SuperAdmin::CounterResets.new(account)
#   resets.current(:responses) # => 1240, the number the card shows
#   resets.last(:responses)    # => Last(at: Time, by: "Айдар"), or nil when nobody has reset it
#
# `KINDS` maps the short name of a counter to the action of the audit log it leaves.
class SuperAdmin::CounterResets
  KINDS = {
    responses: 'reset_captain_responses_usage',
    tokens: 'reset_captain_tokens_usage',
    emails: 'reset_email_usage'
  }.freeze
  # at: when the counter was last reset (Time); by: the name of the super admin (nil when the person is gone)
  Last = Struct.new(:at, :by, keyword_init: true)

  def initialize(account)
    @account = account
  end

  def self.action_for(kind)
    KINDS.fetch(kind.to_sym)
  end

  # The number the counter holds now, read the way the card reads it
  def current(kind)
    case kind.to_sym
    when :responses then @account.custom_attributes.to_h['captain_responses_usage'].to_i.clamp(0..)
    when :tokens then @account.custom_attributes.to_h['captain_tokens_usage'].to_i.clamp(0..)
    when :emails then @account.emails_sent_today.to_i
    else raise ArgumentError, "unknown counter: #{kind}"
    end
  end

  def last(kind)
    latest[kind.to_sym]
  end

  private

  # One read for the three counters: the newest entry of each
  def latest
    @latest ||= begin
      audits = Audited::Audit.where(auditable_type: 'Account', auditable_id: @account.id, action: KINDS.values)
                             .order(id: :desc).limit(30).includes(:user).to_a
      KINDS.each_with_object({}) do |(kind, action), found|
        audit = audits.find { |candidate| candidate.action == action }
        found[kind] = Last.new(at: audit.created_at, by: person(audit)) if audit
      end
    end
  end

  def person(audit)
    user = audit.user
    return user.name.presence || user.email if user.respond_to?(:name)

    audit.username.presence
  end
end
