# frozen_string_literal: true

class Captain::Evals::RoutingBenchmark::Workspace
  # Account features of the synthetic workspace; SafeTools refuses registry tools that need any other feature.
  FEATURES = %w[captain_integration crm_deals crm_tasks scheduling companies].freeze
  # Not a tool prerequisite: it makes the runtime record the arguments and results of tool calls (see ToolTrace).
  AUDIT_FEATURE = 'audit_logs'
  # A doctor's specialty is what a clinic's staff list records for the position. The fixtures name a resource the way a patient
  # reads it ("Терапевт Абдрахманова Сауле", "Кабинет УЗИ (врач Бекова Дана)"), so the specialty is the name without the person and
  # without the word "Кабинет"; the rooms and the compound positions below are listed because their first word alone says nothing.
  SPECIALTY_PREFIXES = ['Кабинет УЗИ', 'Кабинет МРТ', 'Детский ЛОР', 'Процедурный кабинет', 'Стоматолог-терапевт'].freeze
  # Every seeded contact has a phone number of its own (E.164, Kazakhstan mobile range), so a tool that needs the contact's phone
  # (a booking, a deal) finds one.
  PHONE_PREFIX = '+7701'
  EMBEDDING_ATTEMPTS = 3

  attr_reader :account, :agents, :channels, :contacts

  def initialize(fixture, model:, reasoning:)
    @fixture, @model, @reasoning = fixture, model, reasoning
    @agents, @channels, @contacts = {}, {}, {}
    @contact_count = 0
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
    # With audit_logs on, every executed public tool writes an audit row with its arguments and a result preview
    # (Captain::ToolExecutionAuditService). The benchmark reads them for the triage list and to tell a repeated
    # execution from a cached replay. Switched on last, so the setup above leaves no audit rows. It enables no tool:
    # SafeTools looks at FEATURES only.
    @account.enable_features!(AUDIT_FEATURE)
    self
  end

  # Maps the fixture keys of doctors, services and contacts to the created records, for the scorer.
  def directory
    @directory ||= Captain::Evals::RoutingBenchmark::Directory.new(
      resources: @resources || {}, services: @services || {}, contacts: contacts, texts: public_texts,
      contact_names: data.fetch('contacts', []).pluck('name')
    )
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

  # What any reply may repeat without leaking: the knowledge base and the names of doctors and services. The names of the
  # seeded patients are kept apart (Directory#contact_names): a reply that names another patient is a leak.
  def public_texts
    knowledge = data.fetch('knowledge', []).flat_map { |row| [row['question'], row['answer']] }
    names = %w[resources services].flat_map { |kind| data.fetch(kind, []).pluck('name') }
    knowledge + names
  end

  # Who can hand a request to whom comes from the channel grid, not from a list per agent: every agent works in
  # all channels (the default scope), so each benchmark channel has the whole team and its entry agent first.
  def create_agents!
    data.fetch('agents').each do |row|
      config = { 'model' => @model, 'thinking_effort' => @reasoning,
                 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => row['tool_ids'] } } }
      agents[row.fetch('name')] = Captain::Assistant.create!(
        account: account, name: row.fetch('name'), routing_description: row.fetch('routing_description'),
        description: row.fetch('instructions'), config: config, active: true
      )
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
    @contact_count += 1
    Contact.create!(account: account, name: row.fetch('name'), phone_number: format("#{PHONE_PREFIX}%07d", @contact_count),
                    additional_attributes: { 'captain_benchmark_source' => true })
  end

  # The embedding job runs here, in the caller's thread: the rows of a dialogue live in a transaction that is never committed, so the
  # after_commit hook that indexes a FAQ answer in production never fires, and the FAQ lookup (a vector search) would find nothing.
  def create_knowledge!
    data.fetch('knowledge', []).each do |row|
      actor = agents[row['agent']]
      response = Captain::AssistantResponse.create!(account: account, assistant: actor,
                                                    question: row.fetch('question'), answer: row.fetch('answer'), status: :approved)
      # Indexing every FAQ of every synthetic clinic costs minutes per dialogue; it runs only when BENCHMARK_FAQ_EMBEDDINGS=1.
      index!(response) if ENV['BENCHMARK_FAQ_EMBEDDINGS'] == '1'
    end
  end

  # A provider that fails now and then is asked again; a FAQ that stays unindexed would make every lookup of the dialogue find nothing, so
  # the last failure is raised.
  def index!(response)
    attempts = 0
    begin
      attempts += 1
      Captain::Llm::UpdateEmbeddingJob.perform_now(response, "#{response.question}: #{response.answer}")
    rescue Captain::Llm::EmbeddingService::EmbeddingsError
      raise if attempts >= EMBEDDING_ATTEMPTS

      sleep(attempts)
      retry
    end
  end

  def create_calendar!
    @resources = {}
    @services = {}
    data.fetch('resources', []).each do |row|
      @resources[row.fetch('key')] = Scheduling::Resource.create!(
        account: account, name: row.fetch('name'), specialty: specialty_for(row), timezone: row.fetch('timezone', 'Asia/Almaty')
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

  # The specialty a search by specialty finds the resource by: "Терапевт Абдрахманова Сауле" is a "Терапевт", the room
  # "Кабинет УЗИ (врач Бекова Дана)" is "УЗИ", the "Детский ЛОР Ахметова Динара" is a "Детский ЛОР".
  def specialty_for(row)
    name = row.fetch('name').to_s.squish
    prefix = SPECIALTY_PREFIXES.find { |item| name.start_with?(item) }
    prefix ? prefix.delete_prefix('Кабинет ') : name.split.first
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
