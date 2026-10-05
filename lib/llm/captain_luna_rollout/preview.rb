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
    [header, installation_lines, account_lines, voice_lines].flatten.join("\n")
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
    return "#{row[:before]} -> #{target}" if row[:was_present]

    row[:name] == Llm::CaptainLunaRollout::INSTALLATION_CONFIG ? 'absent, stays absent' : "absent -> #{target} (row is created)"
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
