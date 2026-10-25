# frozen_string_literal: true

# One agent the router can choose for a patient turn, as plain data: the live graph builds it from a Captain::Assistant, the
# evaluation harness from an exported graph. Both go through the same competence card and the same criteria.
Captain::Routing::Candidate = Struct.new(:id, :name, :routing_description, :tool_ids, keyword_init: true) do
  def self.from_assistant(assistant)
    new(id: assistant.id, name: assistant.name.to_s, routing_description: assistant.routing_description.to_s,
        tool_ids: Array(assistant.selected_agent_tool_ids).map(&:to_s))
  end

  # A row of clinic_graphs.json: id, name, routing_description, enabled_tool_ids.
  def self.from_export(row, routing_description: nil)
    row = row.to_h.with_indifferent_access
    new(id: row[:id].to_i, name: row[:name].to_s, routing_description: (routing_description || row[:routing_description]).to_s,
        tool_ids: Array(row[:enabled_tool_ids] || row[:tool_ids]).map(&:to_s))
  end

  def books_appointments?
    Array(tool_ids).include?(Captain::Routing::CompetenceCard::BOOKING_TOOL)
  end
end
