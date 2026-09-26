# frozen_string_literal: true

class Llm::CaptainLunaRollout
  TARGET_MODEL = 'openai/gpt-6-luna'
  INSTALLATION_CONFIG = 'CAPTAIN_AI_AGENT_DEFAULT_MODEL'

  class StalePlan < StandardError; end

  class << self
    def plan(scope: Account.all)
      installation = InstallationConfig.find_by(name: INSTALLATION_CONFIG)
      raise StalePlan, 'Capture the snapshot before installing the Luna 6 default' if installation&.value == TARGET_MODEL

      {
        target_model: TARGET_MODEL,
        installation_default: { before: installation&.value, was_present: installation.present? },
        entries: scope.order(:id).map do |account|
          models = account.captain_models.to_h.stringify_keys
          effective_model = Llm::Config.model_for(feature: :assistant, account: account)
          if !models.key?('assistant') && (effective_model.blank? || effective_model == TARGET_MODEL)
            raise StalePlan, 'Previous effective assistant model is unavailable for an unset account'
          end

          { account_id: account.id, before: models['assistant'], was_present: models.key?('assistant'), before_effective: effective_model }
        end
      }
    end

    def apply!(snapshot, scope: Account.all)
      plan = validated_plan(snapshot)
      entries = plan[:entries]
      raise StalePlan, 'Luna 6 is absent from the model catalog' unless Llm::Models.configured_models.key?(TARGET_MODEL)

      Account.transaction do
        installation = locked_installation
        verify_installation!(installation, plan[:installation_default])
        accounts = scope.order(:id).lock.to_a
        verify_accounts!(accounts, entries)
        install_target_default!(installation)
        apply_to_accounts!(accounts)
      end
    end

    def rollback!(snapshot)
      plan = validated_plan(snapshot)
      entries = plan[:entries].reject { |entry| entry[:was_present] && entry[:before] == TARGET_MODEL }

      Account.transaction do
        installation = locked_installation
        raise StalePlan, 'Agent-only default changed since rollout' unless installation&.value == TARGET_MODEL

        restore_accounts!(entries, installation, plan[:installation_default])
      end
    end

    private

    def validated_plan(snapshot)
      plan = snapshot.to_h.deep_symbolize_keys
      raise StalePlan, 'Wrong rollout target' unless plan[:target_model] == TARGET_MODEL

      entries = plan.fetch(:entries)
      validate_snapshot_entries!(entries)
      installation = plan.fetch(:installation_default)
      raise StalePlan, 'Invalid installation snapshot' unless [true, false].include?(installation[:was_present])
      raise StalePlan, 'Snapshot was taken after Luna 6 default' if installation[:before] == TARGET_MODEL

      plan
    end

    def validate_snapshot_entries!(entries)
      ids = entries.pluck(:account_id)
      raise StalePlan, 'Duplicate account in snapshot' unless ids.uniq.size == ids.size
      return unless entries.any? { |entry| !entry[:was_present] && entry[:before_effective].blank? }

      raise StalePlan, 'Previous effective assistant model is missing from snapshot'
    end

    def locked_installation
      InstallationConfig.where(name: INSTALLATION_CONFIG).lock.first
    end

    def install_target_default!(installation)
      if installation
        installation.update!(value: TARGET_MODEL)
      else
        InstallationConfig.create!(name: INSTALLATION_CONFIG, value: TARGET_MODEL)
      end
    end

    def apply_to_accounts!(accounts)
      accounts.count do |account|
        models = account.captain_models.to_h.stringify_keys
        next false if models['assistant'] == TARGET_MODEL

        account.update!(captain_models: models.merge('assistant' => TARGET_MODEL))
        true
      end
    end

    def restore_accounts!(entries, installation, snapshot)
      accounts = Account.where(id: entries.pluck(:account_id)).order(:id).lock.to_a
      raise StalePlan, 'Account list changed' unless accounts.map(&:id) == entries.pluck(:account_id)

      restore_installation!(installation, snapshot)
      accounts.each_with_index { |account, index| restore_account!(account, entries[index]) }
      accounts.size
    end

    def verify_installation!(installation, snapshot)
      return if installation.present? == snapshot[:was_present] && installation&.value == snapshot[:before]

      raise StalePlan, 'Agent-only default changed since snapshot'
    end

    def restore_installation!(installation, snapshot)
      if snapshot[:was_present]
        installation.update!(value: snapshot[:before])
      else
        installation.destroy!
      end
    end

    def verify_accounts!(accounts, entries)
      raise StalePlan, 'Account list changed' unless accounts.map(&:id) == entries.pluck(:account_id)

      accounts.each_with_index do |account, index|
        models = account.captain_models.to_h.stringify_keys
        original = entries[index]
        raise StalePlan, 'Assistant model changed since snapshot' unless matches_snapshot?(models, original)
        raise StalePlan, 'OpenRouter is not configured for account' unless Llm::Config.provider_available?('openrouter', account: account)
        raise StalePlan, 'Luna 6 provider/model fallback is unavailable for account' unless luna_route_available?(account)
      end
    end

    def luna_route_available?(account)
      profile = Llm::OpenRouterRoutingProfile.for(feature: :captain_agent, model: TARGET_MODEL, account: account)
      profile.models == [TARGET_MODEL, Llm::OpenRouterRoutingProfile::LUNA_FALLBACK_MODEL] &&
        profile.provider_preferences[:allow_fallbacks] == true &&
        profile.provider_preferences[:sort] == { by: 'latency', partition: 'model' }
    end

    def matches_snapshot?(models, original)
      models.key?('assistant') == original[:was_present] && models['assistant'] == original[:before]
    end

    def restore_account!(account, original)
      models = account.captain_models.to_h.stringify_keys
      raise StalePlan, 'Assistant model changed since rollout' unless models['assistant'] == TARGET_MODEL

      if original[:was_present]
        models['assistant'] = original[:before]
      else
        models.delete('assistant')
      end
      account.update!(captain_models: models)
      return if original[:was_present]
      return if Llm::Config.model_for(feature: :assistant, account: account.reload) == original[:before_effective]

      account.update!(captain_models: models.merge('assistant' => original[:before_effective]))
      return if Llm::Config.model_for(feature: :assistant, account: account.reload) == original[:before_effective]

      raise StalePlan, 'Cannot restore the previous effective assistant model'
    end
  end
end
