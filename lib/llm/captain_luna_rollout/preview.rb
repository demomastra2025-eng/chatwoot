# frozen_string_literal: true

# The text an operator reviews before the Luna 6 cut-over: what changes, counted per feature and old model, with the
# account ids (and nothing else about the accounts).
class Llm::CaptainLunaRollout::Preview
  def initialize(plan, target:, allowlist: nil)
    @plan = plan.to_h.deep_symbolize_keys
    @target = target
    @allowlist = allowlist.presence || Llm::Models.configured_model_allowlist || Llm::Models::DEFAULT_CURATED_MODELS
  end

  def to_s
    [header, installation_lines, account_lines, agent_lines, voice_lines].flatten.join("\n")
  end

  private

  attr_reader :plan, :target, :allowlist

  def header
    effective = plan[:effective_before].to_h.map { |feature, model| "#{feature}=#{model}" }.join(', ')
    "Luna 6 cut-over (target #{target}), snapshot taken #{plan[:created_at]}\n" \
      "Effective installation-level models now: #{effective}"
  end

  def installation_lines
    lines = plan[:installation].map { |row| "  #{row[:name]}: #{installation_change(row)}" }
    ['Installation rows:', *lines]
  end

  def installation_change(row)
    mode = Llm::CaptainLunaRollout::INSTALLATION_ROWS.fetch(row[:name])
    mode == :follow_default ? follow_default_change(row) : target_change(row, mode)
  end

  def target_change(row, mode)
    return "#{row[:before]} (no change)" if row[:was_present] && row[:before] == target
    return "#{row[:before]} -> #{target}" if row[:was_present]

    mode == :target_if_present ? 'absent, stays absent' : "absent -> #{target} (row is created)"
  end

  # A slot that follows CAPTAIN_DEFAULT_MODEL needs no model of its own after the cut-over.
  def follow_default_change(row)
    return 'absent, follows CAPTAIN_DEFAULT_MODEL (no change)' unless row[:was_present]
    return 'blank, follows CAPTAIN_DEFAULT_MODEL (no change)' if row[:before].blank?

    "#{row[:before]} -> blank, follows CAPTAIN_DEFAULT_MODEL"
  end

  def account_lines
    choices = plan[:accounts].flat_map do |entry|
      entry[:overrides].map { |override| { key: [override[:feature], override[:before]], account_id: entry[:account_id] } }
    end
    lines = grouped(choices).map { |(feature, model), group| account_line(feature, model, group.pluck(:account_id)) }
    ["Account model choices to clear, the account then follows the platform default (#{plan[:accounts].size} accounts):",
     *(lines.presence || ['  none'])]
  end

  def account_line(feature, model, ids)
    outside = allowlist.include?(model) ? '' : ' [outside the allowlist]'
    "  #{feature}: #{model.inspect} x#{ids.size}#{outside} accounts #{ids.join(', ')}"
  end

  # The model an agent stores in its own config outranks the account and the installation, so it is cleared as well.
  def agent_lines
    choices = plan[:agents].map { |agent| { key: [agent[:before]], id: agent[:id] } }
    lines = grouped(choices).map do |(model), group|
      outside = allowlist.include?(model) ? '' : ' [outside the allowlist]'
      "  #{model.inspect} x#{group.size}#{outside} agents #{group.pluck(:id).join(', ')}"
    end
    ["Agent models stored in the agent itself to clear, the agent then follows the platform default (#{plan[:agents].size} agents):",
     *(lines.presence || ['  none'])]
  end

  def voice_lines
    stores = plan[:voice].map { |entry| { key: [entry[:store], entry[:provider], entry[:before]], id: entry[:id] } }
    lines = grouped(stores).map do |(store, provider, model), group|
      "  #{store} (#{provider}) #{model} -> #{target}: ids #{group.pluck(:id).join(', ')}"
    end
    ['Stored voice agent models (OpenRouter providers only):', *(lines.presence || ['  none'])]
  end

  def grouped(items)
    items.group_by { |item| item[:key] }.sort_by { |key, _| key.map(&:to_s) }
  end
end
