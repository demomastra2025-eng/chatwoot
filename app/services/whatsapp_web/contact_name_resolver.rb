class WhatsappWeb::ContactNameResolver
  PHONEBOOK_NAME_KEY = 'phonebook_name'.freeze
  PHONEBOOK_NAME_UPDATED_AT_KEY = 'phonebook_name_updated_at'.freeze

  def initialize(payload:, stored_profiles: [], group: false)
    @payload = payload.to_h.with_indifferent_access
    @stored_profiles = stored_profiles
    @group = group
  end

  def display_name(provider_name:, identity_name:)
    phonebook_attributes[PHONEBOOK_NAME_KEY].presence || provider_name.presence || identity_name
  end

  # Only the provider's explicit saved-name fields establish phonebook provenance.
  # Missing fields in message/avatar updates never erase a previously saved name.
  def phonebook_attributes
    chosen = selected_phonebook_candidate
    return {} unless chosen

    {
      PHONEBOOK_NAME_KEY => chosen[:name],
      PHONEBOOK_NAME_UPDATED_AT_KEY => chosen[:updated_at]&.iso8601(3)
    }.compact
  end

  private

  def selected_phonebook_candidate
    return if @group

    candidates = @stored_profiles.filter_map { |data| phonebook_candidate(data) }
    incoming = phonebook_candidate(
      PHONEBOOK_NAME_KEY => @payload[:phonebookName],
      PHONEBOOK_NAME_UPDATED_AT_KEY => @payload[:phonebookNameUpdatedAt]
    )
    candidates << incoming.merge(incoming: true) if incoming
    winner = candidates.max_by { |candidate| candidate_order(candidate) }
    refine_dated_winner(candidates, winner)
  end

  def refine_dated_winner(candidates, winner)
    return winner unless winner && winner[:updated_at]

    # Refine the original winner only among genuinely equal, valid dates.
    candidates.select { |candidate| candidate[:updated_at] == winner[:updated_at] }
              .min_by { |candidate| candidate[:name].encode(Encoding::UTF_16BE).unpack('n*') }
  end

  def candidate_order(candidate)
    [candidate[:updated_at]&.to_f || 0, candidate[:incoming] ? 1 : 0]
  end

  def phonebook_candidate(data)
    values = data.to_h.with_indifferent_access
    name = values[PHONEBOOK_NAME_KEY].to_s.strip
    return if name.blank?

    { name: name, updated_at: parse_time(values[PHONEBOOK_NAME_UPDATED_AT_KEY]) }
  end

  def parse_time(value)
    Time.iso8601(value.to_s) if value.present?
  rescue ArgumentError
    nil
  end
end
