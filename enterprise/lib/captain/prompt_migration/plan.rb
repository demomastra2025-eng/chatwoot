# frozen_string_literal: true

require 'digest'

# The reviewed prompt migration as a plan: what each proposal (config/captain/router_prompt_migration/*.yml) would change for one
# agent, read from the database and never written. A proposal gives the new routing description (the competence card) and either
# a whole new description or exact edits of the current one (find/replace pairs: the reviewed text is the stored one).
#
# Status of an entry:
#   ok              the change can be applied
#   unchanged       the proposal equals what is stored
#   drift           the stored text changed since the review (base_digest differs): never applied
#   edit_not_found  an edit's find text is not in the stored description: never applied
#   lint_error      the proposed texts still speak of transfers, coordination or other agents (see Lint): never applied
#   missing         no such agent in that account
#
# The digest of the plan covers every applicable change and the stored texts it was computed from: APPLY=1 needs CONFIRM equal to
# it, so only what the owner reviewed in the dry run is written, and a text that changed after the dry run stops the apply.
class Captain::PromptMigration::Plan
  Entry = Struct.new(:account_id, :assistant_id, :name, :status, :current, :proposed, :current_digest, :findings, :notes,
                     keyword_init: true) do
    def applicable? = status == 'ok'
    def errors = Array(findings).select { |finding| finding[:severity] == 'error' }
  end

  attr_reader :migration, :entries, :unproposed, :platform_findings

  def self.digest_of(description, routing_description)
    "sha256:#{Digest::SHA256.hexdigest("#{description}\0#{routing_description}")}"
  end

  # file: the proposal YAML; account_ids: only these accounts (all accounts of the file when empty); include_internal: also the
  # internal assistants (Workspace MCP), which are otherwise reported only.
  def initialize(file:, account_ids: [], include_internal: false)
    data = YAML.safe_load_file(file, permitted_classes: [], aliases: false).to_h
    @migration = data.fetch('migration').to_s
    @account_ids = Array(account_ids).map(&:to_i).compact_blank
    @include_internal = include_internal
    proposals = Array(data['assistants']).map(&:to_h).select { |row| selected_account?(row['account_id'].to_i) }
    @entries = proposals.map { |row| entry_for(row) }
    @unproposed = unproposed_entries(proposals)
    @platform_findings = platform_lint
  end

  def applicable = @entries.select(&:applicable?)

  def digest
    payload = applicable.sort_by(&:assistant_id).map do |entry|
      [entry.account_id, entry.assistant_id, entry.current_digest, entry.proposed[:description], entry.proposed[:routing_description]]
    end
    Digest::SHA256.hexdigest(JSON.generate([@migration, payload]))[0, 16]
  end

  def error_count
    (@entries + @unproposed).sum { |entry| entry.errors.size }
  end

  def drift_count
    @entries.count { |entry| %w[drift edit_not_found missing].include?(entry.status) }
  end

  # The proposals that are not written because their texts still have lint errors.
  def blocked_count
    @entries.count { |entry| entry.status == 'lint_error' }
  end

  private

  def selected_account?(account_id)
    @account_ids.empty? || @account_ids.include?(account_id)
  end

  def entry_for(row)
    assistant = Captain::Assistant.find_by(id: row['assistant_id'], account_id: row['account_id'])
    return Entry.new(account_id: row['account_id'], assistant_id: row['assistant_id'], status: 'missing', findings: [], notes: []) unless assistant

    current = { description: assistant.description.to_s, routing_description: assistant.routing_description.to_s }
    proposed, notes = proposed_texts(row, current)
    findings = Captain::PromptMigration::Lint.call(proposed, others: others_of(assistant), routable: assistant.external_agent?)
    Entry.new(account_id: assistant.account_id, assistant_id: assistant.id, name: assistant.name, current: current, proposed: proposed,
              current_digest: self.class.digest_of(current[:description], current[:routing_description]),
              status: status_for(row, current, proposed, notes, findings), notes: notes, findings: findings)
  end

  def proposed_texts(row, current)
    notes = []
    description = row['description'].presence || apply_edits(current[:description], Array(row['description_edits']), notes)
    routing = row.key?('routing_description') ? row['routing_description'].to_s.strip : current[:routing_description]
    [{ description: description.to_s.strip, routing_description: routing }, notes]
  end

  def apply_edits(text, edits, notes)
    result = text.to_s
    edits.each do |edit|
      find = edit.to_h['find'].to_s
      next notes << "edit not found: #{find.squish.first(80)}" unless find.present? && result.include?(find)

      result = result.sub(find) { edit.to_h['replace'].to_s }
    end
    result
  end

  # A proposal that would still leave transfers, coordination or other agents' names in the prompt is never written: half a
  # migration is worse than none (the agent would speak of transfers that no longer exist).
  def status_for(row, current, proposed, notes, findings)
    base = row['base_digest'].presence
    return 'drift' if base && base != self.class.digest_of(current[:description], current[:routing_description])
    return 'edit_not_found' if notes.any?
    return 'unchanged' if proposed == { description: current[:description].strip, routing_description: current[:routing_description] }
    return 'lint_error' if findings.any? { |finding| finding[:severity] == 'error' }

    'ok'
  end

  def others_of(assistant)
    Captain::Assistant.where(account_id: assistant.account_id).where.not(id: assistant.id).pluck(:id, :name)
  end

  # The agents of the selected multi-agent accounts that have no proposal: their current text is linted, nothing is changed.
  def unproposed_entries(proposals)
    proposed_ids = proposals.map { |row| row['assistant_id'].to_i }
    scope = Captain::Assistant.where(account_id: multi_agent_account_ids).where.not(id: proposed_ids)
    scope = scope.where(usage_mode: 'external_agent') unless @include_internal
    scope.order(:account_id, :id).map do |assistant|
      texts = { description: assistant.description.to_s, routing_description: assistant.routing_description.to_s }
      findings = Captain::PromptMigration::Lint.call(texts, others: others_of(assistant), routable: assistant.external_agent?)
      Entry.new(account_id: assistant.account_id, assistant_id: assistant.id, name: assistant.name, status: 'no_proposal', current: texts,
                proposed: texts, findings: findings, notes: [])
    end
  end

  def multi_agent_account_ids
    counts = Captain::Assistant.entry_eligible.group(:account_id).count
    counts.select { |account_id, count| count > 1 && selected_account?(account_id) }.keys
  end

  # The platform prompts every agent gets (the shared rules and the installation prompts) are checked too; never changed here.
  def platform_lint
    texts = { 'CAPTAIN_AI_AGENT_SYSTEM_PROMPT' => Llm::Config.global_agent_system_prompt.to_s }
    Array(Captain::Assistant.installation_system_prompt_entries).each do |entry|
      entry = entry.to_h.with_indifferent_access
      texts["CAPTAIN_SYSTEM_PROMPTS/#{entry[:id]}"] = entry[:content].to_s
    end
    texts.filter_map do |name, text|
      words = Captain::Routing::CardLint.forbidden_words(text)
      { severity: 'warning', field: name, code: 'handoff_wording', message: "speaks of coordination or transfers: #{words.join(', ')}" } if words.any?
    end
  rescue StandardError => e
    [{ severity: 'warning', field: 'platform', code: 'unreadable', message: e.class.name }]
  end
end
