# frozen_string_literal: true

# The text of a dry run of the prompt migration: per agent the status, the unified diffs of the description and the routing
# description, and the lint; then the agents without a proposal, the competence cards of each account as the router would read
# them after the migration, the platform prompts, a summary and the digest to confirm with.
class Captain::PromptMigration::Report
  def initialize(plan)
    @plan = plan
  end

  def to_s
    [header, *@plan.entries.map { |entry| entry_section(entry) }, unproposed_section, card_section, platform_section, summary]
      .compact_blank.join("\n\n")
  end

  private

  def header
    "Prompt migration #{@plan.migration}: #{@plan.entries.size} proposals"
  end

  def entry_section(entry)
    lines = ["== account #{entry.account_id} / assistant #{entry.assistant_id} #{entry.name} [#{entry.status.upcase}]"]
    lines.concat(entry.notes.map { |note| "  note: #{note}" })
    lines.concat(diffs(entry)) if entry.current
    lines.concat(finding_lines(entry.findings))
    lines.compact_blank.join("\n")
  end

  def diffs(entry)
    %i[description routing_description].map do |field|
      Captain::PromptMigration::TextDiff.unified(entry.current[field], entry.proposed[field], label: field.to_s)
    end
  end

  def unproposed_section
    return if @plan.unproposed.empty?

    rows = @plan.unproposed.map do |entry|
      findings = finding_lines(entry.findings)
      ["-- account #{entry.account_id} / assistant #{entry.assistant_id} #{entry.name} (no proposal)", *findings].join("\n")
    end
    ['== Agents of multi-agent accounts without a proposal (current text, nothing changes)', *rows].join("\n")
  end

  # The cards after the migration: the proposed routing descriptions where there is a proposal, the stored ones elsewhere.
  def card_section
    accounts = (@plan.entries + @plan.unproposed).select(&:current).group_by(&:account_id)
    rows = accounts.filter_map do |account_id, entries|
      candidates = entries.map do |entry|
        Captain::Routing::Candidate.new(id: entry.assistant_id, name: entry.name, routing_description: entry.proposed[:routing_description],
                                        tool_ids: tool_ids(entry.assistant_id))
      end
      findings = Captain::Routing::CardLint.call(candidates)
      ["-- account #{account_id}", *findings.map { |finding| "  #{finding.severity}: #{finding.code}: #{finding.message}" }].join("\n")
    end
    ['== Competence cards after the migration', *rows].join("\n") if rows.any?
  end

  def platform_section
    return if @plan.platform_findings.empty?

    ['== Platform prompts (changed only by hand)', *finding_lines(@plan.platform_findings)].join("\n")
  end

  def summary
    counts = @plan.entries.group_by(&:status).transform_values(&:size)
    ['== Summary', *counts.sort.map { |status, count| "  #{status}: #{count}" }, "  lint errors: #{@plan.error_count}",
     "  plan digest: #{@plan.digest}"].join("\n")
  end

  def finding_lines(findings)
    Array(findings).map { |finding| "  #{finding[:severity]}: #{finding[:field]}: #{finding[:code]}: #{finding[:message]}" }
  end

  def tool_ids(assistant_id)
    Array(Captain::Assistant.find_by(id: assistant_id)&.selected_agent_tool_ids).map(&:to_s)
  end
end
