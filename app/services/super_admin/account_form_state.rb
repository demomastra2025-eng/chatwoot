# frozen_string_literal: true

# What the edit form of an account was drawn from, as one short token per section of the form. The form posts the tokens
# back (`form_state[main]`, `form_state[limits]`, `form_state[features]`, `form_state[ai]`); a section whose token no longer matches the
# account was changed by somebody else (or by another page: the plan of the card writes limits and functions together)
# while the form was open, and saving it would put the old values back. The controller leaves such a section out of the
# save and says so. The organization has its own guard (SuperAdmin::OrganizationLinks `expected_holder`).
#
#   SuperAdmin::AccountFormState.tokens_for(account)                 # => { 'main' => 'a1b2...', 'limits' => ..., 'features' => ..., 'ai' => ... }
#   SuperAdmin::AccountFormState.stale_sections(account, params[:form_state]) # => ['limits'] ([] when nothing is stale)
class SuperAdmin::AccountFormState
  SECTIONS = %w[main limits features ai].freeze
  # Sections added after forms were already open. A page drawn before has no token of such a section and no field of it either,
  # so a request without that token is not checked for it.
  LATER_SECTIONS = %w[ai].freeze
  TOKEN_LENGTH = 16

  # The tokens to put into the form: the ones the page was first drawn with when the form comes back with errors (the
  # operator is still working on the state they saw), otherwise the ones of the saved account.
  def self.tokens_for(account, submitted = nil)
    current = new(Account.find_by(id: account.id) || account).tokens
    drawn = submitted_tokens(submitted)
    drawn ? drawn.merge(current) { |_section, drawn_token, current_token| drawn_token || current_token } : current
  end

  # The sections the account has left since the form was drawn. A request without tokens (a script, an old page) is
  # not checked; tokens that cannot be read count as stale everywhere, so nothing is written on their word.
  def self.stale_sections(account, submitted)
    return [] if submitted.nil?

    drawn = submitted_tokens(submitted)
    return SECTIONS.dup if drawn.nil?

    current = new(account).tokens
    SECTIONS.reject { |section| drawn[section].nil? || drawn[section] == current[section] }
  end

  # { 'main' => token, ... } when the value holds a token for every section (a later section may have none: nil); nil otherwise
  def self.submitted_tokens(value)
    value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    return unless value.is_a?(Hash)

    tokens = SECTIONS.index_with { |section| value[section] || value[section.to_sym] }
    tokens if tokens.all? { |section, token| acceptable_token?(section, token) }
  end

  # A token as the form draws it, or no token at all for a section added after the page was drawn
  def self.acceptable_token?(section, token)
    well_formed?(token) || (token.nil? && LATER_SECTIONS.include?(section))
  end

  def self.well_formed?(token)
    token.is_a?(String) && token.length <= TOKEN_LENGTH
  end

  def initialize(account)
    @account = account
  end

  def tokens
    SECTIONS.index_with { |section| digest(state_of(section)) }
  end

  private

  def digest(state)
    Digest::SHA256.hexdigest(JSON.generate(state))[0, TOKEN_LENGTH]
  end

  def state_of(section)
    case section
    when 'main' then [@account.name, @account.locale]
    when 'limits' then [sorted(@account.limits), Accounts::LimitSettings.marks_in(@account.custom_attributes).sort.to_h, excluded_user_ids]
    # The clinic context: the prompts-v2 rake writes it too, and a form opened before must not put the old text back
    when 'ai' then [@account.captain_clinic_context]
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
