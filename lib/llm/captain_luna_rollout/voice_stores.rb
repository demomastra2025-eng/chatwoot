# frozen_string_literal: true

# The stored voice-agent settings of the Luna 6 cut-over. The voice context merges the telephony routing policy
# (ai_voice_settings) with the Captain agent (config['voice_settings']), the agent winning, and sends the result to the
# voice runtime. The SIP voice channel keeps a copy of the policy settings (provider_config['ai_voice_settings']) that
# wins over the policy the next time the channel is saved (NumberBinding.sync_from_voice_channel!), so the copy is moved
# together with the policy; otherwise any later channel save would bring the old model back. Only the providers that
# take their LLM from the "model" key (the OpenRouter cascade) are moved; the native speech-to-speech providers keep
# their own models. A store without a "model" key follows the provider default.
class Llm::CaptainLunaRollout::VoiceStores
  CASCADE_PROVIDERS = %w[elevenlabs cartesia fish].freeze
  KINDS = {
    'captain_assistant' => 'Captain::Assistant',
    'routing_policy' => 'Telephony::RoutingPolicy',
    'voice_channel' => 'Channel::Voice'
  }.freeze

  def initialize(target:)
    @target = target
  end

  def snapshot(account_ids)
    KINDS.flat_map do |kind, class_name|
      stores_of(kind, class_name, account_ids).order(:id).filter_map do |record|
        settings = settings_of(kind, record)
        next unless movable?(settings)

        { store: kind, id: record.id, provider: settings['provider'], before: settings['model'] }
      end
    end
  end

  # The records of the entries, locked in a fixed order, as { [kind, id] => record }.
  def lock(entries)
    entries.group_by { |entry| entry[:store] }.sort_by(&:first).flat_map do |kind, kind_entries|
      class_name = KINDS.fetch(kind) { raise Llm::CaptainLunaRollout::StalePlan, "Unknown voice settings store #{kind}" }
      class_name.constantize.where(id: kind_entries.pluck(:id)).order(:id).lock.map { |record| [[kind, record.id], record] }
    end.to_h
  end

  def verify!(entries, records)
    entries.each do |entry|
      record = records[[entry[:store], entry[:id]]]
      settings = record && settings_of(entry[:store], record)
      unless settings && settings['provider'] == entry[:provider] && [entry[:before], @target].include?(settings['model'])
        raise Llm::CaptainLunaRollout::StalePlan, "Voice settings of #{entry[:store]} #{entry[:id]} changed since the snapshot"
      end
    end
  end

  def apply!(entries, records)
    write_models!(entries, records) { |_entry| @target }
  end

  def restore!(entries, records)
    write_models!(entries, records) { |entry| entry[:before] }
  end

  private

  def movable?(settings)
    CASCADE_PROVIDERS.include?(settings['provider']) && settings['model'].present? && settings['model'] != @target
  end

  # Only the SIP channels keep a settings copy: the others have no telephony binding.
  def stores_of(kind, class_name, account_ids)
    scope = class_name.constantize.where(account_id: account_ids)
    kind == 'voice_channel' ? scope.where(provider: Channel::Voice::PROVIDER_OWNED_SIP_PROVIDERS) : scope
  end

  def settings_of(kind, record)
    raw = case kind
          when 'captain_assistant' then record.config.to_h['voice_settings']
          when 'voice_channel' then channel_config(record)['ai_voice_settings']
          else record.ai_voice_settings
          end
    raw.is_a?(Hash) ? raw.deep_stringify_keys : {}
  end

  def channel_config(channel)
    channel.provider_config_hash.to_h.deep_stringify_keys
  rescue JSON::ParserError, TypeError
    {}
  end

  # Each record is re-read first: an agent is also written by the agent-model store of the cut-over.
  def write_models!(entries, records)
    entries.count do |entry|
      record = records.fetch([entry[:store], entry[:id]]).reload
      settings = settings_of(entry[:store], record)
      wanted = yield(entry)
      next false if settings['model'] == wanted

      store!(entry[:store], record, settings.merge('model' => wanted))
      true
    end
  end

  # Saved without validations: the agent validations (rules, tools, voice reference) are not the business of a model
  # switch and must not stop it. The channel copy is written without callbacks, which would re-sync the whole telephony
  # binding of the number for what is only a model id.
  def store!(kind, record, settings)
    case kind
    when 'captain_assistant'
      record.config = record.config.to_h.merge('voice_settings' => settings)
      record.save!(validate: false)
    when 'voice_channel'
      record.update_columns(provider_config: channel_config(record).merge('ai_voice_settings' => settings)) # rubocop:disable Rails/SkipsModelValidations
    else
      record.ai_voice_settings = settings
      record.save!(validate: false)
    end
  end
end
