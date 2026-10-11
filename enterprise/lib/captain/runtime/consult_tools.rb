# frozen_string_literal: true

class Captain::Runtime::ConsultTools
  ALLOWLIST = %w[
    faq_lookup search_documentation get_article
    get_contact get_my_contact search_contacts get_deal get_task get_appointment
    list_my_deals list_my_appointments list_deal_pipelines list_deal_stages
    list_scheduling_services list_scheduling_resources list_captain_documents
    get_scheduling_resource_schedule get_scheduling_resource_availability
    get_appointment_provider_status
    search_available_slots search_appointments search_deals search_tasks
    search_articles search_scheduling_services search_scheduling_resources
  ].freeze

  def self.allowed?(tool)
    canonical = tool.name.to_s.split('__').last.split(':').last
    ALLOWLIST.include?(canonical) && Llm::ToolRiskPolicy.read_only?(tool)
  end
end
