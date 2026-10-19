# frozen_string_literal: true

# What the edit form of an account was drawn from, as one short token per section of the form. The form posts the tokens
# back (`form_state[main]`, `form_state[limits]`, `form_state[features]`); a section whose token no longer matches the
# account was changed by somebody else (or by another page: the plan of the card writes limits and functions together)
# while the form was open, and saving it would put the old values back. The controller leaves such a section out of the
# save and says so. The organization has its own guard (SuperAdmin::OrganizationLinks `expected_holder`).
#
#   SuperAdmin::AccountFormState.tokens_for(account)                 # => { 'main' => 'a1b2...', 'limits' => ..., 'features' => ... }
#   SuperAdmin::AccountFormState.stale_sections(account, params[:form_state]) # => ['limits'] ([] when nothing is stale)
class SuperAdmin::AccountFormState
  SECTIONS = %w[main limits features].freeze
  TOKEN_LENGTH = 16

  # The tokens to put into the form: the ones the page was first drawn with when the form comes back with errors (the
  # operator is still working on the state they saw), otherwise the ones of the saved account.
  def self.tokens_for(account, submitted = nil)
    submitted_tokens(submitted) || new(Account.find_by(id: account.id) || account).tokens
  end

  # The sections the account has left since the form was drawn. A request without tokens (a script, an old page) is
  # not checked; tokens that cannot be read count as stale everywhere, so nothing is written on their word.
  def self.stale_sections(account, submitted)
    return [] if submitted.nil?

    drawn = submitted_tokens(submitted)
    return SECTIONS.dup if drawn.nil?

    current = new(account).tokens
    SECTIONS.reject { |section| drawn[section] == current[section] }
  end

  # { 'main' => token, ... } when the value holds a token for every section; nil otherwise
  def self.submitted_tokens(value)
    value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    return unless value.is_a?(Hash)

    tokens = SECTIONS.to_h { |section| [section, value[section] || value[section.to_sym]] }
    tokens if tokens.values.all? { |token| token.is_a?(String) && token.length <= TOKEN_LENGTH }
  end

  def initialize(account)
    @account = account
  end

  def tokens
    SECTIONS.to_h { |section| [section, digest(state_of(section))] }
  end

  private

  def digest(state)
    Digest::SHA256.hexdigest(JSON.generate(state))[0, TOKEN_LENGTH]
  end

  def state_of(section)
    case section
    when 'main' then [@account.name, @account.locale, @account.status.to_s]
    when 'limits' then [sorted(@account.limits), excluded_user_ids]
    else @account.selected_feature_flags.map(&:to_s).sort
    end
  end

  def sorted(hash)
    hash.to_h.sort_by { |key, _| key.to_s }.to_h
  end

  def excluded_user_ids
    Array(@account.custom_attributes.to_h[Enterprise::Account::LIMIT_COUNTER_EXCLUDED_USER_IDS_KEY]).map(&:to_i).sort
  end
end
