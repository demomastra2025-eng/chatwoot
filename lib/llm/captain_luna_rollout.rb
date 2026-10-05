# frozen_string_literal: true

# The reviewed cut-over of the whole platform to Luna 6 (agent, editor, copilot, label hints, image recognition and
# the OpenRouter voice agents) that can be put back exactly as it was.
#
#   plan = Llm::CaptainLunaRollout.plan            # read only; Snapshot.write(plan, path) keeps it as a 0600 file
#   Llm::CaptainLunaRollout.apply!(plan)           # one transaction, rows and accounts locked, refuses a stale plan
#   Llm::CaptainLunaRollout.rollback!(plan)        # restores exactly the old rows, account choices and voice models
#
# The account-level model choices and the model an agent stores in its own config are cleared rather than set, so an
# account and an agent follow the platform default (the CAPTAIN_DEFAULT_MODEL row, editable in Super Admin) and one edit
# of that row moves every account and agent back as well.
# Both directions accept a state that is already done and refuse anything that is neither the snapshot state nor the
# done state, so running either twice is harmless. See script/onelink/LUNA_CUTOVER_RUNBOOK.md.
class Llm::CaptainLunaRollout
  TARGET_MODEL = 'openai/gpt-6-luna'
  # The model the quick rollback (Super Admin default) goes back to; it must stay selectable.
  ROLLBACK_MODEL = Llm::OpenRouterRoutingProfile::LUNA_FALLBACK_MODEL
  INSTALLATION_CONFIG = 'CAPTAIN_AI_AGENT_DEFAULT_MODEL'
  SNAPSHOT_VERSION = 3
  # The chat features whose account-level choice is cleared.
  FEATURES = %w[assistant editor copilot image_recognition label_suggestion].freeze
  # name => whether the cut-over creates the row when it is absent. The agent-only default is only moved when it exists:
  # the general default already covers the agent, and a second row would be a second switch to remember.
  INSTALLATION_ROWS = {
    'CAPTAIN_DEFAULT_MODEL' => true,
    INSTALLATION_CONFIG => false,
    'CAPTAIN_IMAGE_RECOGNITION_MODEL' => true,
    'CAPTAIN_LABEL_SUGGESTION_MODEL' => true
  }.freeze
  DEFAULT_ROWS = ['CAPTAIN_DEFAULT_MODEL', INSTALLATION_CONFIG].freeze

  class StalePlan < StandardError; end

  # Everything a cut-over or a rollback writes, locked in this fixed order: installation rows, accounts, voice stores, agents.
  Locked = Struct.new(:configs, :accounts, :records, :agents)

  class << self
    def plan(scope: Account.all)
      rows = installation_rows.snapshot
      effective = effective_models
      ensure_not_cut_over!(rows, effective)
      verify_target!
      accounts = scope.order(:id).to_a
      verify_accounts!(accounts)

      {
        version: SNAPSHOT_VERSION,
        target_model: TARGET_MODEL,
        created_at: Time.current.utc.iso8601,
        effective_before: effective,
        installation: rows,
        accounts: overrides.snapshot(accounts),
        voice: voice_stores.snapshot(accounts.map(&:id)),
        agents: agent_models.snapshot(accounts.map(&:id))
      }
    end

    def apply!(snapshot, scope: Account.all)
      plan = validated_plan(snapshot)
      verify_target!

      Account.transaction do
        locked = lock_all(plan, scope.order(:id))
        verify_state!(plan, locked)
        agent_models.verify_complete!(locked.accounts.map(&:id), plan[:agents])
        verify_accounts!(locked.accounts)

        changed = write_target!(plan, locked)
        verify_effective_models!(locked.accounts)
        changed
      end
    end

    def rollback!(snapshot)
      plan = validated_plan(snapshot)

      Account.transaction do
        locked = lock_all(plan, Account.where(id: plan[:accounts].pluck(:account_id)).order(:id))
        live = without_deleted(plan, locked)
        verify_state!(live, locked)

        restore_state!(live, locked)
      end
    end

    # What differs from the effective installation-level models the snapshot was taken with; empty when all is as
    # before. Meant for the check after a rollback: it reports, it does not block.
    def restored_differences(snapshot)
      expected = validated_plan(snapshot)[:effective_before].to_h.stringify_keys
      effective_models.stringify_keys.filter_map do |feature, model|
        "#{feature}: #{model.inspect}, the snapshot had #{expected[feature].inspect}" if expected[feature] != model
      end
    end

    private

    def installation_rows
      Llm::CaptainLunaRollout::InstallationRows.new(rows: INSTALLATION_ROWS, target: TARGET_MODEL)
    end

    def overrides
      Llm::CaptainLunaRollout::AccountOverrides.new(features: FEATURES)
    end

    def voice_stores
      Llm::CaptainLunaRollout::VoiceStores.new(target: TARGET_MODEL)
    end

    def agent_models
      Llm::CaptainLunaRollout::AgentModels.new
    end

    def effective_models
      FEATURES.index_with { |feature| Llm::Config.model_for(feature: feature, fallback: nil) }
    end

    # The snapshot has to be taken before the cut-over: afterwards it could not tell what to go back to.
    def ensure_not_cut_over!(rows, effective)
      installed = rows.any? { |row| DEFAULT_ROWS.include?(row[:name]) && row[:before] == TARGET_MODEL }
      raise StalePlan, 'The Luna 6 default is already installed; the snapshot has to be taken before it' if installed
      return if effective['assistant'].present? && effective['assistant'] != TARGET_MODEL

      raise StalePlan, 'The previous installation-level agent model is unknown or already Luna 6; set CAPTAIN_DEFAULT_MODEL first'
    end

    def validated_plan(snapshot)
      plan = snapshot.to_h.deep_symbolize_keys
      raise StalePlan, 'Wrong rollout target' unless plan[:target_model] == TARGET_MODEL
      raise StalePlan, 'Unsupported snapshot version' unless plan[:version] == SNAPSHOT_VERSION

      %i[installation accounts voice agents].each { |key| raise StalePlan, "Snapshot has no #{key}" unless plan[key].is_a?(Array) }
      validate_snapshot_entries!(plan)
      plan
    end

    def validate_snapshot_entries!(plan)
      account_ids = plan[:accounts].pluck(:account_id)
      raise StalePlan, 'Duplicate account in snapshot' unless account_ids.uniq.size == account_ids.size

      row_names = plan[:installation].pluck(:name)
      raise StalePlan, 'Snapshot installation rows do not match this release' unless row_names.sort == INSTALLATION_ROWS.keys.sort

      overrides = plan[:accounts].flat_map { |entry| entry[:overrides].pluck(:feature) }
      raise StalePlan, 'Snapshot names a feature this release does not move' unless (overrides - FEATURES).empty?
    end

    # An account or an agent deleted since the cut-over has nothing left to restore, and must not block the rollback.
    def lock_all(plan, account_scope)
      Locked.new(installation_rows.lock, account_scope.lock.to_a, voice_stores.lock(plan[:voice]), agent_models.lock(plan[:agents]))
    end

    def without_deleted(plan, locked)
      account_ids = locked.accounts.map(&:id)
      plan.merge(
        accounts: plan[:accounts].select { |entry| account_ids.include?(entry[:account_id]) },
        voice: plan[:voice].select { |entry| locked.records.key?([entry[:store], entry[:id]]) },
        agents: plan[:agents].select { |entry| locked.agents.key?(entry[:id]) }
      )
    end

    def verify_state!(plan, locked)
      installation_rows.verify!(plan[:installation], locked.configs)
      overrides.verify!(locked.accounts, plan[:accounts])
      voice_stores.verify!(plan[:voice], locked.records)
      agent_models.verify!(plan[:agents], locked.agents)
    end

    # Returns the number of accounts that were written.
    def write_target!(plan, locked)
      installation_rows.apply!(plan[:installation], locked.configs)
      voice_stores.apply!(plan[:voice], locked.records)
      agent_models.clear!(plan[:agents], locked.agents)
      overrides.clear!(locked.accounts, plan[:accounts])
    end

    def restore_state!(live, locked)
      installation_rows.restore!(live[:installation], locked.configs)
      voice_stores.restore!(live[:voice], locked.records)
      agent_models.restore!(live[:agents], locked.agents)
      overrides.restore!(locked.accounts, live[:accounts])
    end

    # Luna 6 has to be usable for every feature it takes over, and the allowlist has to keep both it and the model the
    # quick rollback returns to, otherwise Super Admin could not set that model back.
    def verify_target!
      raise StalePlan, 'Luna 6 is absent from the model catalog' unless Llm::Models.configured_models.key?(TARGET_MODEL)

      unsuitable = FEATURES.reject { |feature| Llm::Models.model_allowed_for_feature?(feature, TARGET_MODEL) }
      raise StalePlan, "Luna 6 does not fit these features: #{unsuitable.join(', ')}" if unsuitable.any?

      allowlist = Llm::Models.configured_model_allowlist
      return if allowlist.blank? || ([TARGET_MODEL, ROLLBACK_MODEL] - allowlist).empty?

      raise StalePlan, "The model allowlist must keep #{TARGET_MODEL} and #{ROLLBACK_MODEL}"
    end

    def verify_accounts!(accounts)
      accounts.each do |account|
        unless Llm::Config.provider_available?('openrouter', account: account)
          raise StalePlan, "OpenRouter is not configured for account #{account.id}"
        end
        raise StalePlan, "Luna 6 provider/model fallback is unavailable for account #{account.id}" unless luna_route_available?(account)
      end
    end

    def luna_route_available?(account)
      profile = Llm::OpenRouterRoutingProfile.for(feature: :captain_agent, model: TARGET_MODEL, account: account)
      profile.models == [TARGET_MODEL, Llm::OpenRouterRoutingProfile::LUNA_FALLBACK_MODEL] &&
        profile.provider_preferences[:allow_fallbacks] == true &&
        profile.provider_preferences[:sort] == { by: 'latency', partition: 'model' }
    end

    # Inside the transaction, after the writes: whatever is not Luna 6 now rolls the whole cut-over back.
    def verify_effective_models!(accounts)
      wrong = effective_models.reject { |_feature, model| model == TARGET_MODEL }
      raise StalePlan, "The installation-level #{wrong.keys.join(', ')} model is not Luna 6 after the cut-over" if wrong.any?

      wrong_account = accounts.find { |account| Llm::Config.model_for(feature: :assistant, account: account) != TARGET_MODEL }
      raise StalePlan, 'An account still resolves another agent model after the cut-over' if wrong_account

      verify_agents_resolve_target!(accounts)
    end

    # The model an agent really runs on (its own stored model first, then the account and the installation), which the
    # account-level check above cannot see.
    def verify_agents_resolve_target!(accounts)
      Llm::Config.with_runtime_cache do
        Captain::Assistant.where(account_id: accounts.map(&:id)).find_each do |agent|
          next if agent.resolved_agent_model == TARGET_MODEL

          raise StalePlan, "Agent #{agent.id} still resolves another model after the cut-over"
        end
      end
    end
  end
end
