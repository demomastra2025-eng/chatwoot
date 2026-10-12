# frozen_string_literal: true

class Captain::Evals::RoutingBenchmark::Workspace
  # Account features of the synthetic workspace; SafeTools refuses registry tools that need any other feature.
  FEATURES = %w[captain_integration crm_deals crm_tasks scheduling companies].freeze

  attr_reader :account, :agents, :channels, :contacts

  def initialize(fixture, model:, reasoning:)
    @fixture, @model, @reasoning = fixture, model, reasoning
    @agents, @channels, @contacts = {}, {}, {}
  end

  def create!
    @account = Account.create!(name: "Benchmark #{SecureRandom.uuid}", locale: 'ru',
                               internal_attributes: { 'captain_benchmark_source' => true })
    @account.enable_features!(*FEATURES)
    create_agents!
    create_channels!
    create_contacts!
    create_knowledge!
    create_calendar!
    create_deals!
    self
  end

  def conversation_for(dialogue)
    key = dialogue['channel'] || channels.keys.first
    inbox = channels.fetch(key)
    contact = contacts[dialogue['contact']] || create_contact!('name' => 'Тестовый пациент')
    contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.uuid)
    Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                         status: :pending, additional_attributes: { 'captain_benchmark_source' => true })
  end

  def entry_agent(dialogue)
    inbox = channels.fetch(dialogue['channel'] || channels.keys.first)
    CaptainInbox.find_by!(inbox: inbox).captain_assistant
  end

  private

  def data = @fixture.workspace

  def create_agents!
    data.fetch('agents').each do |row|
      config = { 'model' => @model, 'thinking_effort' => @reasoning,
                 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => row['tool_ids'] } } }
      agents[row.fetch('name')] = Captain::Assistant.create!(
        account: account, name: row.fetch('name'), routing_description: row.fetch('routing_description'),
        description: row.fetch('instructions'), config: config, active: true
      )
    end
    agents.each_value do |actor|
      actor.update!(handoff_agent_ids: agents.values.filter_map { |other| other.id unless other.id == actor.id })
    end
  end

  def create_channels!
    rows = data.fetch('channels', [{ 'key' => 'default', 'entry_agent' => agents.keys.first }])
    rows.each do |row|
      key = row.fetch('key')
      actor = agents.fetch(row.fetch('entry_agent'))
      channel = Channel::Api.create!(account: account, webhook_url: nil)
      inbox = Inbox.create!(account: account, name: "Benchmark #{key}", channel: channel)
      CaptainInbox.create!(captain_assistant: actor, inbox: inbox)
      channels[key] = inbox
    end
  end

  def create_contacts!
    data.fetch('contacts', []).each do |row|
      contacts[row.fetch('key')] = create_contact!(row)
    end
  end

  # Clinics record which resource performs which service (price list / MedElement sync); slot search refuses a
  # service without that link. Fixtures do not list links, so every synthetic resource is linked to every service.
  def link_services_to_resources!
    @services.each_value do |service|
      @resources.each_value do |resource|
        Scheduling::ServicePrice.create!(account: account, service_id: service.id, resource_id: resource.id,
                                         price: service.base_price)
      end
    end
  end

  def create_contact!(row)
    # No Playground marker: Captain::Playground::ExecutionBoundary blocks every tool for a marked
    # record without a live Playground session. The isolated database has no channel webhook or
    # provider integration, and the guard allows HTTP only to OpenRouter.
    Contact.create!(account: account, name: row.fetch('name'),
                    additional_attributes: { 'captain_benchmark_source' => true })
  end

  def create_knowledge!
    data.fetch('knowledge', []).each do |row|
      actor = agents[row['agent']]
      Captain::AssistantResponse.create!(account: account, assistant: actor,
                                         question: row.fetch('question'), answer: row.fetch('answer'), status: :approved)
    end
  end

  def create_calendar!
    @resources = {}
    @services = {}
    data.fetch('resources', []).each do |row|
      @resources[row.fetch('key')] = Scheduling::Resource.create!(
        account: account, name: row.fetch('name'), timezone: row.fetch('timezone', 'Asia/Almaty')
      )
    end
    data.fetch('services', []).each do |row|
      @services[row.fetch('key')] = Scheduling::Service.create!(
        account: account, name: row.fetch('name'), duration_min: row.fetch('duration_min', 30),
        base_price: row.fetch('base_price', 0)
      )
    end
    link_services_to_resources!
    data.fetch('slots', []).each do |row|
      Scheduling::WorkRule.create!(resource: @resources.fetch(row.fetch('resource')),
                                   weekday: row.fetch('weekday'), start_minute: row.fetch('start_minute'),
                                   end_minute: row.fetch('end_minute'))
    end
    data.fetch('appointments', []).each do |row|
      resource = @resources.fetch(row.fetch('resource'))
      service = @services[row['service']]
      contact = contacts.fetch(row.fetch('contact'))
      starts_at = Time.iso8601(row.fetch('starts_at'))
      Scheduling::Appointment.create!(account: account, resource: resource, service: service, contact: contact,
                                      patient_contact: contact, client_name: contact.name, starts_at: starts_at,
                                      ends_at: starts_at + (service&.duration_min || 30).minutes,
                                      duration_min: service&.duration_min || 30)
    end
  end

  def create_deals!
    return if data.fetch('deals', []).empty?

    pipeline = Crm::Pipeline.create!(account: account, name: 'Benchmark', code: 'benchmark')
    stage = Crm::Stage.create!(account: account, pipeline: pipeline, name: 'Новый', code: 'benchmark_new')
    data.fetch('deals').each do |row|
      Crm::Deal.create!(account: account, pipeline: pipeline, stage: stage, title: row.fetch('title'))
    end
  end
end
